package daemon

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"vpnks/internal/core"
)

// The daemon runs as a Windows service under LocalSystem. Autostart is a
// setting, not a property of being installed:
//
//	autostart on   the service starts automatically at boot, and the
//	               block it leaves loaded is persistent, so it is in force
//	               from early boot until the daemon decides.
//	autostart off  the service is set to manual and started now.
//
// Either way the recovery actions restart it if it crashes, and the block
// it left loaded stays in force meanwhile (fail closed).

const serviceDescription = "Cuts traffic outside the VPN tunnel the moment the tunnel stops carrying traffic."

func startType(cfg core.Config) uint32 {
	if cfg.Autostart {
		return mgr.StartAutomatic
	}
	return mgr.StartManual
}

// Install copies this binary to InstalledBinary, registers the service and
// starts it. wait=false returns as soon as the service manager has the
// start request: the app confirms the start itself by watching status.json.
func Install(cfg core.Config, wait bool) error {
	if err := core.SecureStateDir(); err != nil {
		return fmt.Errorf("state directory: %w", err)
	}
	// Saved again now that the directory records who may edit it.
	if err := cfg.Save(); err != nil {
		return err
	}
	if _, err := os.Stat(core.EndpointsFile); err == nil {
		core.ShareWithAdmins(core.EndpointsFile)
	}

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("service manager: %w", err)
	}
	defer m.Disconnect()

	// The service holds the binary open; stop it before replacing that.
	// The block it left loaded stays in force while it is down.
	if s, err := m.OpenService(core.ServiceName); err == nil {
		stopService(s)
		s.Close()
	}

	source, err := os.Executable()
	if err != nil {
		return err
	}
	if !strings.EqualFold(filepath.Clean(source), filepath.Clean(core.InstalledBinary)) {
		if err := os.MkdirAll(core.InstallDir, 0o755); err != nil {
			return err
		}
		if err := copyFile(source, core.InstalledBinary); err != nil {
			return fmt.Errorf("copy daemon: %w", err)
		}
	}

	s, err := m.OpenService(core.ServiceName)
	if err != nil {
		s, err = m.CreateService(core.ServiceName, core.InstalledBinary, mgr.Config{
			DisplayName:  "VPN Kill Switch",
			Description:  serviceDescription,
			StartType:    startType(cfg),
			ErrorControl: mgr.ErrorNormal,
		}, "daemon")
		if err != nil {
			return fmt.Errorf("create service: %w", err)
		}
	} else {
		c, err := s.Config()
		if err != nil {
			s.Close()
			return fmt.Errorf("read service: %w", err)
		}
		c.BinaryPathName = syscall.EscapeArg(core.InstalledBinary) + " daemon"
		c.StartType = startType(cfg)
		c.DisplayName = "VPN Kill Switch"
		c.Description = serviceDescription
		if err := s.UpdateConfig(c); err != nil {
			s.Close()
			return fmt.Errorf("update service: %w", err)
		}
	}
	defer s.Close()

	// Restart=always, Windows style: after 2 s, every time. Counting a
	// non-zero exit as a failure covers the daemon stopping by itself.
	restart := mgr.RecoveryAction{Type: mgr.ServiceRestart, Delay: 2 * time.Second}
	if err := s.SetRecoveryActions([]mgr.RecoveryAction{restart, restart, restart}, 60); err != nil {
		core.Logf("WARN: could not set the service's recovery actions: %v", err)
	}
	_ = s.SetRecoveryActionsOnNonCrashFailures(true)

	if err := s.Start(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
		return fmt.Errorf("start service: %w", err)
	}
	if !wait {
		fmt.Println("✓ vpnks installed; starting")
		return nil
	}
	for i := 0; i < 50; i++ {
		if st, err := s.Query(); err == nil && st.State == svc.Running {
			fmt.Printf("✓ vpnks installed and running from %s\n", core.InstalledBinary)
			if cfg.Autostart {
				fmt.Println("  It will also start automatically with Windows.")
			} else {
				fmt.Println("  It will NOT start with Windows (vpnks set autostart 1 to change).")
			}
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("failed to start; see %s and Event Viewer → Windows Logs → System", core.LogFile)
}

// ApplyAutostart changes the service's start type without touching the
// running instance, so flipping it never interrupts protection.
func ApplyAutostart(cfg core.Config) {
	m, err := mgr.Connect()
	if err != nil {
		return
	}
	defer m.Disconnect()
	s, err := m.OpenService(core.ServiceName)
	if err != nil {
		return // not installed yet; Install applies it
	}
	defer s.Close()
	if c, err := s.Config(); err == nil {
		c.StartType = startType(cfg)
		_ = s.UpdateConfig(c)
	}
}

// Uninstall stops the daemon, clears the block and removes the service.
// It never leaves the machine firewalled with nothing left to unfirewall
// it.
func Uninstall() {
	if m, err := mgr.Connect(); err == nil {
		if s, err := m.OpenService(core.ServiceName); err == nil {
			stopService(s)
			_ = s.Delete()
			s.Close()
		}
		m.Disconnect()
	}
	if err := removeAll(); err != nil {
		fmt.Fprintln(os.Stderr, "✗ could not remove the firewall rules:", err)
	}
	// Not the running binary when called from the app's copy; if it is,
	// Windows refuses and the uninstaller removes the folder later.
	_ = os.RemoveAll(core.InstallDir)
	fmt.Println("✓ Removed. Traffic is unblocked.")
}

// stopService asks the service to stop and waits up to 15 seconds.
func stopService(s *mgr.Service) {
	st, err := s.Query()
	if err != nil || st.State == svc.Stopped {
		return
	}
	_, _ = s.Control(svc.Stop)
	for i := 0; i < 150; i++ {
		if st, err := s.Query(); err != nil || st.State == svc.Stopped {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// copyFile replaces dst through a temporary. Retried briefly: the stopped
// service's process can hold the old binary for a moment after it reports
// stopped.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".new"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	for attempt := 0; ; attempt++ {
		err = os.Rename(tmp, dst)
		if err == nil || attempt == 30 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		_ = os.Remove(tmp)
	}
	return err
}

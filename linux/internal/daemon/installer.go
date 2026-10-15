package daemon

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"vpnks/internal/core"
)

// The daemon runs as a systemd service. Autostart is a setting, not a
// property of being installed:
//
//	autostart on   the unit is enabled, so systemd starts it at boot.
//	autostart off  the unit is started for this boot only.
//
// Either way Restart=always brings it back if it crashes, and the block it
// left loaded stays in force meanwhile (fail closed).

func unitText(binary string) string {
	return fmt.Sprintf(`[Unit]
Description=VPN Kill Switch daemon
# Up before the network at boot, so the block is in force before any
# connection can be made.
Wants=network-pre.target
Before=network-pre.target
After=dbus.service

[Service]
Type=simple
ExecStart=%s daemon
Restart=always
RestartSec=2
# Nothing to signal on stop but the daemon itself; it saves its session
# history on SIGTERM and leaves the firewall as it is.
KillMode=process

[Install]
WantedBy=multi-user.target
`, binary)
}

func systemctl(args ...string) (string, error) {
	out, err := exec.Command("systemctl", args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// Install copies this binary to InstalledBinary, writes the unit and
// starts it. wait=false returns as soon as systemd has the job: the app
// confirms the start itself by watching status.json.
func Install(cfg core.Config, wait bool) error {
	if err := os.MkdirAll(core.InstallDir, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(core.StateDir, 0o755); err != nil {
		return err
	}
	source, err := os.Executable()
	if err != nil {
		return err
	}
	source, _ = filepath.EvalSymlinks(source)
	if source != core.InstalledBinary {
		if err := copyFile(source, core.InstalledBinary); err != nil {
			return fmt.Errorf("copy daemon: %w", err)
		}
	}
	_ = os.Chown(core.InstalledBinary, 0, 0)
	_ = os.Chmod(core.InstalledBinary, 0o755)

	if err := os.WriteFile(core.UnitFile, []byte(unitText(core.InstalledBinary)), 0o644); err != nil {
		return err
	}
	if out, err := systemctl("daemon-reload"); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %v %s", err, out)
	}
	applyAutostart(cfg)

	// A daemon started by hand would fight the service over the table.
	stopStray()
	args := []string{"restart", core.UnitName}
	if !wait {
		args = []string{"restart", "--no-block", core.UnitName}
	}
	if out, err := systemctl(args...); err != nil {
		return fmt.Errorf("systemctl restart: %v %s", err, out)
	}
	if !wait {
		fmt.Println("✓ vpnks installed; starting")
		return nil
	}
	time.Sleep(2 * time.Second)
	if out, _ := systemctl("is-active", core.UnitName); out == "active" {
		fmt.Printf("✓ vpnks installed and running from %s\n", core.InstalledBinary)
		if cfg.Autostart {
			fmt.Println("  It will also start automatically at boot.")
		} else {
			fmt.Println("  It will NOT start at boot (vpnks set autostart 1 to change).")
		}
		return nil
	}
	return fmt.Errorf("failed to start; see: journalctl -u %s", core.UnitName)
}

// ApplyAutostart enables or disables the unit without touching the
// running instance, so flipping it never interrupts protection.
func ApplyAutostart(cfg core.Config) {
	if _, err := os.Stat(core.UnitFile); err != nil {
		return // not installed yet; Install applies it
	}
	applyAutostart(cfg)
}

func applyAutostart(cfg core.Config) {
	if cfg.Autostart {
		systemctl("enable", core.UnitName)
	} else {
		systemctl("disable", core.UnitName)
	}
}

// Uninstall stops the daemon, clears the block and removes the unit. It
// never leaves the machine firewalled with nothing left to unfirewall it.
func Uninstall() {
	systemctl("disable", "--now", core.UnitName)
	stopStray()
	Clear()
	_ = os.Remove(core.UnitFile)
	systemctl("daemon-reload")
	systemctl("reset-failed", core.UnitName)
	fmt.Println("✓ Removed. Traffic is unblocked.")
}

// stopStray ends any `vpnks daemon` not run by systemd (started by hand),
// waiting at most a second for it to go.
func stopStray() {
	self := os.Getpid()
	for _, pid := range DaemonPIDs() {
		if pid != self {
			if p, err := os.FindProcess(pid); err == nil {
				p.Signal(os.Interrupt)
			}
		}
	}
	for i := 0; i < 20; i++ {
		alive := false
		for _, pid := range DaemonPIDs() {
			if pid != self {
				alive = true
			}
		}
		if !alive {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// DaemonPIDs lists processes whose command line is "…/vpnks daemon".
func DaemonPIDs() []int {
	var pids []int
	entries, _ := os.ReadDir("/proc")
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		if core.IsDaemonProcess(pid) {
			pids = append(pids, pid)
		}
	}
	return pids
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".new"
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
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
	// Rename rather than overwrite: the running daemon's executable can be
	// replaced this way, but not written into ("text file busy").
	return os.Rename(tmp, dst)
}

package main

import (
	"fmt"
	"os"
	"os/signal"

	"vpnks/internal/core"
	"vpnks/internal/daemon"
)

const (
	platformName  = "Windows"
	adminHint     = "an administrator. Run it from a terminal opened as administrator."
	adminReadHint = "run as administrator to read the firewall"
	serviceKind   = "the Windows service"
)

var emergencyUnblock = "  From a terminal opened as administrator:\n    & \"" + core.InstalledBinary + "\" unblock\n" +
	"  or uninstall VPN Kill Switch (Settings → Apps), which removes every rule."

// runDaemon runs the watcher as the service, or in the foreground (until
// Ctrl-C) when started by hand.
func runDaemon() {
	if daemon.IsService() {
		if err := daemon.RunService(); err != nil {
			core.Logf("ERROR: service: %v", err)
			os.Exit(1)
		}
		return
	}
	requireRoot("daemon")
	_ = os.MkdirAll(core.StateDir, 0o755)
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, os.Interrupt)
	stop := make(chan string, 1)
	go func() { stop <- fmt.Sprint(<-signals) }()
	daemon.New(core.LoadConfig()).Run(stop)
}

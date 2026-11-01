package main

import (
	"os"
	"os/signal"
	"syscall"

	"vpnks/internal/core"
	"vpnks/internal/daemon"
)

const (
	platformName  = "Linux"
	adminHint     = "root. Re-run with sudo."
	adminReadHint = "run with sudo to read the firewall"
	serviceKind   = "the systemd unit"
)

var emergencyUnblock = "  sudo nft delete table inet " + core.TableName

// runDaemon runs the watcher until systemd stops it (SIGTERM), or Ctrl-C
// when run by hand.
func runDaemon() {
	requireRoot("daemon")
	_ = os.MkdirAll(core.StateDir, 0o755)
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	stop := make(chan string, 1)
	go func() { stop <- (<-signals).String() }()
	daemon.New(core.LoadConfig()).Run(stop)
	os.Exit(0)
}

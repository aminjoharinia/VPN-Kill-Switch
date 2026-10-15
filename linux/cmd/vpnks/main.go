// vpnks — the VPN kill switch daemon and its command-line tool (Linux).
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"vpnks/internal/core"
	"vpnks/internal/daemon"
)

func requireRoot(action string) {
	if os.Geteuid() != 0 {
		fmt.Fprintf(os.Stderr, "vpnks: '%s' needs root. Re-run with sudo.\n", action)
		os.Exit(1)
	}
}

func usage() {
	fmt.Printf(`vpnks — VPN kill switch daemon (Linux)

  vpnks daemon              run the watcher in the foreground (root)
  vpnks status              show current state
  vpnks unblock             clear the block immediately (root)
  vpnks install [--autostart|--no-autostart] [--no-wait]
                            install to %s and start (root)
  vpnks uninstall           stop, unblock, remove the systemd unit (root)
  vpnks set <key> <value>   change a setting (root)
  vpnks config              print current configuration
  vpnks sessions            session history with traffic totals
  vpnks endpoints           list VPN server exceptions
  vpnks pin add <ip>        pin an exception so it is never dropped
  vpnks pin remove <ip>     delete an exception
  vpnks probe <iface> <ip>  check the probe is really pinned to an interface
  vpnks --version           print the build version

Emergency unblock without this tool:
  sudo nft delete table inet %s
`, core.InstallDir, core.TableName)
	os.Exit(0)
}

func pad(s string, w int) string {
	if n := len([]rune(s)); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}

func padLeft(s string, w int) string {
	if n := len([]rune(s)); n < w {
		return strings.Repeat(" ", w-n) + s
	}
	return s
}

func human(b uint64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d bytes", b)
	}
	div, exp := uint64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}

func spell(d time.Duration) string {
	t := int(d.Seconds())
	switch {
	case t >= 3600:
		return fmt.Sprintf("%dh %dm", t/3600, (t%3600)/60)
	case t >= 60:
		return fmt.Sprintf("%dm %ds", t/60, t%60)
	}
	return fmt.Sprintf("%ds", t)
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
	}

	switch args[0] {
	case "daemon":
		requireRoot("daemon")
		_ = os.MkdirAll(core.StateDir, 0o755)
		daemon.New(core.LoadConfig()).Run()

	case "--version", "-v", "version":
		fmt.Printf("%s (build %s)\n", core.Version, core.Number)

	case "status":
		cfg := core.LoadConfig()
		snap := daemon.TakeSnapshot()
		tunnels := snap.Tunnels()
		var names []string
		for _, t := range tunnels {
			names = append(names, fmt.Sprintf("%s(%s)", t.Name, t.IPv4))
		}
		fmt.Printf("version:       %s (build %s)\n", core.Version, core.Number)
		fmt.Printf("tunnels:       %s\n", strings.Join(names, " "))
		def := daemon.DefaultInterface(snap)
		if def == "" {
			def = "none"
		}
		fmt.Printf("default route: %s\n", def)
		if len(tunnels) > 0 {
			if app, ok := daemon.DetectVPNApp(tunnels[0].Name, snap); ok {
				fmt.Printf("vpn app:       %s %s\n", app.Name, app.Process)
			}
		}
		fmt.Printf("mode:          %s\n", cfg.Mode)
		fmt.Printf("always armed:  %v\n", cfg.AlwaysArmed)
		fmt.Printf("autostart:     %v\n", cfg.Autostart)
		if os.Geteuid() == 0 {
			fmt.Printf("blocked:       %v\n", daemon.BlockLoaded())
		} else {
			fmt.Println("blocked:       (run with sudo to read the firewall)")
		}
		if s, err := core.ReadStatus(); err == nil && core.IsDaemonProcess(s.PID) {
			fmt.Printf("daemon:        running (pid %d, v%s) — vpn %s, %s\n", s.PID, s.DaemonVersion, s.VPNState, s.Reason)
		} else {
			fmt.Println("daemon:        not running")
		}
		if cfg.ProbeEnabled && len(tunnels) > 0 && os.Geteuid() == 0 {
			ok := daemon.Probe(tunnels[0].Name, cfg.ProbeHost, cfg.ProbePort, cfg.ProbeHostHeader, cfg.ProbePath,
				time.Duration(cfg.ProbeTimeoutSeconds*float64(time.Second)))
			verdict := "DEAD"
			if ok {
				verdict = "alive"
			}
			fmt.Printf("probe:         %s via %s -> %s\n", verdict, tunnels[0].Name, cfg.ProbeHost)
		}
		fmt.Printf("endpoints:     %s\n", strings.Join(core.AllowList(), " "))

	case "probe":
		// `vpnks probe wg0 1.1.1.1` should succeed while
		// `vpnks probe wg0 192.0.2.1` (a black hole) must fail.
		if len(args) < 3 {
			usage()
		}
		requireRoot("probe")
		cfg := core.LoadConfig()
		started := time.Now()
		ok := daemon.Probe(args[1], args[2], cfg.ProbePort, args[2], cfg.ProbePath,
			time.Duration(cfg.ProbeTimeoutSeconds*float64(time.Second)))
		verdict := "DEAD"
		if ok {
			verdict = "alive"
		}
		fmt.Printf("%s  via %s -> %s  (%.3fs)\n", verdict, args[1], args[2], time.Since(started).Seconds())
		if !ok {
			os.Exit(1)
		}

	case "bench":
		const n = 200
		started := time.Now()
		for i := 0; i < n; i++ {
			snap := daemon.TakeSnapshot()
			_ = daemon.DefaultInterface(snap)
			_ = snap.Tunnels()
		}
		fmt.Printf("route lookup + interface scan: %.3f ms per evaluation\n",
			float64(time.Since(started).Microseconds())/n/1000)

	case "sessions":
		sessions := core.LoadSessions()
		if len(sessions) == 0 {
			fmt.Println("No sessions recorded yet.")
			return
		}
		fmt.Println(pad("STARTED", 18) + pad("DURATION", 10) + padLeft("DOWN", 11) + padLeft("UP", 11) + "  TUNNEL")
		for i, s := range sessions {
			if i >= 30 {
				break
			}
			tunnel := s.InterfaceName
			if s.IsActive() {
				tunnel += "  (active)"
			}
			fmt.Println(pad(s.StartedAt.Local().Format("2006-01-02 15:04"), 18) + pad(spell(s.Duration()), 10) +
				padLeft(human(s.BytesIn), 11) + padLeft(human(s.BytesOut), 11) + "  " + tunnel)
		}

	case "endpoints", "pin":
		sub, target := "list", ""
		if len(args) > 1 {
			sub = args[1]
		}
		if len(args) > 2 {
			target = args[2]
		}
		switch sub {
		case "add":
			requireRoot("pin add")
			if !core.AddEndpoint(target, true) {
				fmt.Fprintf(os.Stderr, "not a valid IPv4 address: %s\n", target)
				os.Exit(1)
			}
			fmt.Println("pinned", target)
		case "remove", "rm", "delete":
			requireRoot("pin remove")
			core.RemoveEndpoint(target)
			fmt.Println("removed", target)
		case "keep":
			requireRoot("pin keep")
			core.SetEndpointPinned(target, true)
			fmt.Println("pinned", target)
		case "unkeep", "unpin":
			requireRoot("pin unpin")
			core.SetEndpointPinned(target, false)
			fmt.Println("unpinned", target)
		default:
			all := core.LoadEndpoints()
			if len(all) == 0 {
				fmt.Println("No exceptions recorded yet.")
				return
			}
			allowed := map[string]bool{}
			for _, ip := range core.AllowList() {
				allowed[ip] = true
			}
			sort.SliceStable(all, func(i, j int) bool {
				if all[i].Pinned != all[j].Pinned {
					return all[i].Pinned
				}
				return all[i].Hits > all[j].Hits
			})
			yes := func(b bool) string {
				if b {
					return "yes"
				}
				return "no"
			}
			fmt.Println(pad("ADDRESS", 17) + pad("PINNED", 8) + pad("HITS", 7) + pad("LAST SEEN", 18) + "IN RULES")
			for _, e := range all {
				fmt.Println(pad(e.IP, 17) + pad(yes(e.Pinned), 8) + pad(strconv.Itoa(e.Hits), 7) +
					pad(e.LastSeen.Local().Format("2006-01-02 15:04"), 18) + yes(allowed[e.IP]))
			}
		}

	case "unblock":
		requireRoot("unblock")
		daemon.Clear()
		fmt.Println("Block cleared.")

	case "config":
		data, _ := json.Marshal(core.LoadConfig())
		fmt.Println(string(data))

	case "set":
		requireRoot("set")
		if len(args) < 3 {
			usage()
		}
		cfg := core.LoadConfig()
		key, value := args[1], args[2]
		on := map[string]bool{"1": true, "true": true, "yes": true, "on": true}[strings.ToLower(value)]
		switch key {
		case "mode":
			cfg.Mode = "ALL"
			if strings.ToUpper(value) == "LIST" {
				cfg.Mode = "LIST"
			}
		case "alwaysArmed":
			cfg.AlwaysArmed = on
		case "autostart":
			cfg.Autostart = on
		case "allowLAN":
			cfg.AllowLAN = on
		case "blockDNS":
			cfg.BlockDNS = on
		case "allowVPNReconnect":
			cfg.AllowVPNReconnect = on
		case "requireDefaultRoute":
			cfg.RequireDefaultRoute = on
		case "probeEnabled":
			cfg.ProbeEnabled = on
		case "probeHost":
			cfg.ProbeHost, cfg.ProbeHostHeader = value, value
		case "probeIntervalSeconds":
			cfg.ProbeIntervalSeconds = 1
			if v, err := strconv.ParseFloat(value, 64); err == nil && v > 0 {
				cfg.ProbeIntervalSeconds = v
			}
		case "probeFailThreshold":
			cfg.ProbeFailThreshold = 1
			if v, err := strconv.Atoi(value); err == nil && v > 0 {
				cfg.ProbeFailThreshold = v
			}
		case "vpnInterface":
			cfg.VPNInterface = value
		default:
			fmt.Fprintf(os.Stderr, "unknown key: %s\n", key)
			os.Exit(1)
		}
		if err := cfg.Save(); err != nil {
			fmt.Fprintln(os.Stderr, "vpnks:", err)
			os.Exit(1)
		}
		// Enabling or disabling the unit only; never restarts anything, so
		// flipping it cannot interrupt protection that is already running.
		if key == "autostart" {
			daemon.ApplyAutostart(cfg)
		}
		fmt.Printf("%s = %s\n", key, value)

	case "install":
		requireRoot("install")
		cfg := core.LoadConfig()
		for _, a := range args[1:] {
			switch a {
			case "--autostart":
				cfg.Autostart = true
			case "--no-autostart":
				cfg.Autostart = false
			}
		}
		if err := cfg.Save(); err != nil {
			fmt.Fprintln(os.Stderr, "vpnks:", err)
			os.Exit(1)
		}
		wait := true
		for _, a := range args[1:] {
			if a == "--no-wait" {
				wait = false
			}
		}
		if err := daemon.Install(cfg, wait); err != nil {
			fmt.Fprintln(os.Stderr, "✗", err)
			os.Exit(1)
		}

	case "uninstall":
		requireRoot("uninstall")
		daemon.Uninstall()

	default:
		usage()
	}
}

package daemon

import (
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/windows"

	"vpnks/internal/core"
)

// Windows does not say which process created an adapter — a Wintun or TAP
// device has no file descriptor to trace back as /dev/net/tun has on
// Linux. So the VPN program is found by name among the running processes:
// the engines (cores) that actually carry the traffic, and the apps that
// drive them, which give the more familiar name.
//
// The core's path is what the block lets through by application; if only
// the app is running, the core is built into it, and the app is let
// through instead.
type knownProgram struct {
	exe  string // lower case, with .exe
	name string
}

var vpnCores = []knownProgram{
	{"sing-box.exe", "sing-box"},
	{"xray.exe", "Xray"},
	{"v2ray.exe", "V2Ray"},
	{"mihomo.exe", "Mihomo"},
	{"mihomo-windows-amd64.exe", "Mihomo"},
	{"verge-mihomo.exe", "Mihomo"},
	{"clash.exe", "Clash"},
	{"clash-meta.exe", "Clash Meta"},
	{"hysteria.exe", "Hysteria"},
	{"tuic-client.exe", "TUIC"},
	{"tun2socks.exe", "tun2socks"},
	{"nekobox_core.exe", "NekoBox"},
	{"nekoray_core.exe", "NekoRay"},
	{"hiddifycli.exe", "Hiddify"},
	{"openvpn.exe", "OpenVPN"},
	{"wireguard.exe", "WireGuard"},
	{"outline-service.exe", "Outline"},
	{"tailscaled.exe", "Tailscale"},
}

var vpnApps = []knownProgram{
	{"happ.exe", "Happ"},
	{"v2rayn.exe", "v2rayN"},
	{"hiddify.exe", "Hiddify"},
	{"nekoray.exe", "NekoRay"},
	{"nekobox.exe", "NekoBox"},
	{"clash-verge.exe", "Clash Verge"},
	{"clash verge.exe", "Clash Verge"},
	{"clashn.exe", "ClashN"},
	{"openvpn-gui.exe", "OpenVPN"},
	{"openvpnconnect.exe", "OpenVPN Connect"},
	{"outline.exe", "Outline"},
	{"protonvpn.exe", "Proton VPN"},
	{"nordvpn.exe", "NordVPN"},
	{"windscribe.exe", "Windscribe"},
	{"mullvad vpn.exe", "Mullvad VPN"},
}

type runningProgram struct {
	knownProgram
	pid  uint32
	rank int // position in its list: earlier is likelier to own a tunnel
}

// DetectVPNApp names what owns the tunnel. A program whose name appears in
// the adapter's name wins ("sing-box" adapter, sing-box.exe); otherwise
// the first known core and the first known app.
func DetectVPNApp(tunnel string, snap Snapshot) (VPNApp, bool) {
	if tunnel == "" {
		return VPNApp{}, false
	}
	var cores, apps []runningProgram
	core.EachProcess(func(pid uint32, exe string) bool {
		lower := strings.ToLower(exe)
		for i, p := range vpnCores {
			if p.exe == lower {
				cores = append(cores, runningProgram{p, pid, i})
			}
		}
		for i, p := range vpnApps {
			if p.exe == lower {
				apps = append(apps, runningProgram{p, pid, i})
			}
		}
		return true
	})
	adapter := strings.ToLower(tunnel)
	pick := func(list []runningProgram) *runningProgram {
		var best *runningProgram
		for i := range list {
			p := &list[i]
			stem := strings.TrimSuffix(p.exe, ".exe")
			if strings.Contains(adapter, stem) || strings.Contains(adapter, strings.ToLower(p.name)) {
				return p
			}
			if best == nil || p.rank < best.rank {
				best = p
			}
		}
		return best
	}

	app := VPNApp{}
	carrier := pick(cores)
	if gui := pick(apps); gui != nil {
		app.Name = gui.name
		if carrier == nil {
			carrier = gui
		}
	}
	if carrier != nil {
		if app.Name == "" {
			app.Name = carrier.name
		}
		app.PID = int(carrier.pid)
		app.Path = processPath(carrier.pid)
		shown := app.Path
		if shown == "" {
			shown = carrier.exe
		}
		app.Process = shown + " (pid " + strconv.Itoa(app.PID) + ")"
	}
	if app.Name == "" && strings.Contains(adapter, "wireguard") {
		app.Name = "WireGuard"
	}
	return app, app.Name != ""
}

// processPath is the full path of a running program. The daemon runs as
// LocalSystem, which may query any ordinary process.
func processPath(pid uint32) string {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, windows.MAX_LONG_PATH)
	size := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &size); err != nil {
		return ""
	}
	return filepath.Clean(windows.UTF16ToString(buf[:size]))
}

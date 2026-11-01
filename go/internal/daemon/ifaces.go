// Package daemon is the kill switch for Linux and Windows: it watches the
// tunnel, proves it carries traffic with a pinned probe, and enforces the
// block with the system firewall — an nftables table of its own on Linux,
// a WFP sublayer of its own on Windows.
//
// The state machine (killswitch.go) is shared; each platform supplies the
// same small set of pieces in its _linux.go / _windows.go files:
//
//	Snapshot, TakeSnapshot   the interfaces, and which are tunnels
//	DefaultInterface         where ordinary traffic leaves now
//	Probe binding            pinning the probe socket to the tunnel
//	loadBlock, loadObserve,  the firewall
//	Clear, BlockLoaded
//	DetectVPNApp             what owns the tunnel
//	ServerRoutes,            learning the VPN server's address
//	SocketRemotes, tallied
//	WatchNetwork, WatchPower system events
//	Install, Uninstall       the system service
package daemon

import "strings"

type Tunnel struct {
	Name string
	IPv4 string // may be empty: a tunnel can be IPv6-only or not yet addressed
}

// Name prefixes VPN clients give their interfaces. The link type catches
// the rest (any tun/tap or WireGuard device, whatever it is called).
// Matched without regard to case: Windows adapters are named "WireGuard",
// "Tailscale" and so on.
var tunnelPrefixes = []string{
	"tun", "tap", "wg", "ppp", "ipsec", "utun", "vpn",
	"nordlynx", "proton", "mullvad", "tailscale", "sing", "clash", "nekoray", "xray", "happ",
}

// IsTunnelName judges by name alone, for routes and logs where only the
// name is at hand.
func IsTunnelName(name string) bool {
	lower := strings.ToLower(name)
	for _, p := range tunnelPrefixes {
		if strings.HasPrefix(lower, p) {
			return true
		}
	}
	return false
}

func TunnelNames(tunnels []Tunnel) []string {
	out := make([]string, len(tunnels))
	for i, t := range tunnels {
		out[i] = t.Name
	}
	return out
}

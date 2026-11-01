package daemon

import (
	"sort"

	"golang.zx2c4.com/wireguard/wgctrl"

	"vpnks/internal/core"
)

// Learn observes which public addresses the VPN client reaches over the
// physical interfaces and folds them into the endpoint store. Three
// sources: WireGuard peers, host routes, and the firewall's tally of
// bytes per address (Linux only; Windows has no cheap equivalent, and lets
// the VPN client through by application instead).
func Learn(snap Snapshot) {
	observed := ServerRoutes(snap)
	for ip, w := range wireGuardPeers() {
		observed[ip] += w
	}

	// While a full-tunnel VPN is up ordinary traffic goes into the tunnel,
	// so what leaves directly is the client talking to its server — one
	// flow carrying everything, which dwarfs the rest. Learn it, and
	// anything else of real size, but not every small system service that
	// bypasses the tunnel.
	seen := tallied()
	var largest uint64
	for ip, bytes := range seen {
		if !core.IsPrivate(ip) && bytes > largest {
			largest = bytes
		}
	}
	if largest >= 64*1024 {
		for ip, bytes := range seen {
			if !core.IsPrivate(ip) && (bytes >= 1<<20 || bytes == largest) {
				observed[ip] += 3
			}
		}
	}
	if len(observed) > 0 {
		core.MergeEndpoints(observed)
	}
}

// LearnWhileBlocked uses only the sources that stay valid during a block:
// a client reconnecting to a server it has never used adds a host route,
// sets a WireGuard peer, or — a proxy-style core (Xray, sing-box) — opens a
// socket to it from the process that owns the tunnel (vpnPID). Unless that
// address is picked up now, the block stops the client reaching its server
// and the tunnel never comes back. Returns the addresses the store gained.
func LearnWhileBlocked(snap Snapshot, vpnPID int) []string {
	observed := ServerRoutes(snap)
	for ip, w := range wireGuardPeers() {
		observed[ip] += w
	}
	for ip, n := range SocketRemotes(vpnPID) {
		observed[ip] += n
	}
	if len(observed) == 0 {
		return nil
	}
	known := map[string]bool{}
	for _, e := range core.LoadEndpoints() {
		known[e.IP] = true
	}
	core.MergeEndpoints(observed)
	var added []string
	for ip := range observed {
		if !known[ip] {
			added = append(added, ip)
		}
	}
	sort.Strings(added)
	return added
}

// wireGuardPeers reads the configured peer endpoints of every WireGuard
// device straight from the kernel — the most direct signal there is.
func wireGuardPeers() map[string]int {
	observed := map[string]int{}
	client, err := wgctrl.New()
	if err != nil {
		return observed
	}
	defer client.Close()
	devices, err := client.Devices()
	if err != nil {
		return observed
	}
	for _, d := range devices {
		for _, p := range d.Peers {
			if p.Endpoint == nil {
				continue
			}
			ip := p.Endpoint.IP.String()
			if core.IsValidIPv4(ip) && !core.IsPrivate(ip) {
				observed[ip] += 3
			}
		}
	}
	return observed
}

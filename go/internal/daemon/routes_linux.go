package daemon

import (
	"net"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"

	"vpnks/internal/core"
)

// routeProbeTarget is the address whose route stands for "the default
// route". Asking the kernel for an actual destination, rather than reading
// the main table's 0.0.0.0/0, honours policy routing: wg-quick, sing-box
// and most modern clients leave the main table alone and steer traffic
// with ip rules into a table of their own.
var routeProbeTarget = net.ParseIP("1.1.1.1")

// DefaultInterface is the interface ordinary traffic leaves through now.
func DefaultInterface(snap Snapshot) string {
	routes, err := netlink.RouteGet(routeProbeTarget)
	if err != nil || len(routes) == 0 {
		return ""
	}
	return snap.NameOf(routes[0].LinkIndex)
}

// ServerRoutes are public host routes (/32) pinned to a non-tunnel
// interface, in any table: how OpenVPN and others keep reaching their
// server after taking the default route. Only root can add routes, so a
// public host routed around the tunnel is a VPN client's doing.
func ServerRoutes(snap Snapshot) map[string]int {
	observed := map[string]int{}
	filter := &netlink.Route{Table: unix.RT_TABLE_UNSPEC}
	routes, err := netlink.RouteListFiltered(netlink.FAMILY_V4, filter, netlink.RT_FILTER_TABLE)
	if err != nil {
		return observed
	}
	for _, r := range routes {
		if r.Dst == nil {
			continue
		}
		if ones, bits := r.Dst.Mask.Size(); ones != 32 || bits != 32 {
			continue
		}
		dev := snap.NameOf(r.LinkIndex)
		ip := r.Dst.IP.String()
		if dev == "" || dev == "lo" || snap.IsTunnel(dev) || core.IsPrivate(ip) {
			continue
		}
		// Local and broadcast entries describe this machine, not a server.
		if r.Type == unix.RTN_LOCAL || r.Type == unix.RTN_BROADCAST {
			continue
		}
		observed[ip] += 3
	}
	return observed
}

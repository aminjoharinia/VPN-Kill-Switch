package daemon

import (
	"net"
	"unsafe"

	"golang.org/x/sys/windows"

	"vpnks/internal/core"
)

// routeProbeTarget is the address whose route stands for "the default
// route". Asking for the best interface to an actual destination, rather
// than reading the 0.0.0.0/0 entry, honours the 0.0.0.0/1 + 128.0.0.0/1
// pair that WireGuard and OpenVPN add instead of replacing the default.
var routeProbeTarget = [4]byte{1, 1, 1, 1}

// DefaultInterface is the interface ordinary traffic leaves through now.
func DefaultInterface(snap Snapshot) string {
	var index uint32
	if err := windows.GetBestInterfaceEx(&windows.SockaddrInet4{Addr: routeProbeTarget}, &index); err != nil {
		return ""
	}
	return snap.NameOf(index)
}

const mibIPProtoLocal = 2 // MIB_IPPROTO_LOCAL: routes for this machine's own addresses

// ServerRoutes are public host routes (/32) pinned to a non-tunnel
// interface: how OpenVPN and others keep reaching their server after
// taking the default route. Only an administrator can add routes, so a
// public host routed around the tunnel is a VPN client's doing.
func ServerRoutes(snap Snapshot) map[string]int {
	observed := map[string]int{}
	var table *windows.MibIpForwardTable2
	if err := windows.GetIpForwardTable2(windows.AF_INET, &table); err != nil {
		return observed
	}
	defer windows.FreeMibTable(unsafe.Pointer(table))
	own := snap.addresses()
	for _, r := range table.Rows() {
		if r.DestinationPrefix.PrefixLength != 32 || r.Protocol == mibIPProtoLocal || r.Loopback != 0 {
			continue
		}
		raw := r.DestinationPrefix.Prefix
		if raw.Family != windows.AF_INET {
			continue
		}
		// sockaddr_in: family, port, then the address in network order.
		addr := (*[4]byte)(unsafe.Pointer(&raw.Data[0]))
		ip := net.IP(addr[:]).String()
		dev := snap.NameOf(r.InterfaceIndex)
		if dev == "" || snap.IsTunnel(dev) || core.IsPrivate(ip) || own[ip] || ip == "255.255.255.255" {
			continue
		}
		observed[ip] += 3
	}
	return observed
}

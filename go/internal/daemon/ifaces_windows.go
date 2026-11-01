package daemon

import (
	"net"
	"sort"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Snapshot is one GetAdaptersAddresses call: every adapter with its
// friendly name ("Wi-Fi", "sing-box", "WireGuard"), LUID and first IPv4
// address. One call, no process spawned, so re-evaluating on every network
// event stays cheap.
type Snapshot struct {
	byName  map[string]*adapter
	byIndex map[uint32]string
}

type adapter struct {
	name     string
	luid     uint64
	index    uint32
	ipv4     string
	up       bool
	tunnel   bool
	loopback bool
}

const (
	ifTypePropVirtual = 53 // Wintun, WireGuardNT and most userspace VPNs

	// Tunnel types of Windows' own IPv6 transition adapters, which are
	// IF_TYPE_TUNNEL but carry no VPN.
	tunnelTypeDirect  = 2
	tunnelType6to4    = 11
	tunnelTypeISATAP  = 13
	tunnelTypeTeredo  = 14
	tunnelTypeIPHTTPS = 15
)

// Driver descriptions of VPN adapters that present themselves as Ethernet.
var tunnelDescriptions = []string{
	"wintun", "wireguard", "tap-windows", "tap-win32", "openvpn", "tap adapter",
	"virtual private network", "vpn", "tunnel", "sing-tun",
}

func isTunnelAdapter(a *windows.IpAdapterAddresses, name, description string) bool {
	switch a.IfType {
	case ifTypePropVirtual, windows.IF_TYPE_PPP:
		return true
	case windows.IF_TYPE_TUNNEL:
		switch a.TunnelType {
		case tunnelTypeDirect, tunnelType6to4, tunnelTypeISATAP, tunnelTypeTeredo, tunnelTypeIPHTTPS:
			return false
		}
		return true
	case windows.IF_TYPE_SOFTWARE_LOOPBACK:
		return false
	}
	d := strings.ToLower(description)
	for _, s := range tunnelDescriptions {
		if strings.Contains(d, s) {
			return true
		}
	}
	return IsTunnelName(name)
}

func adapterAddresses() ([]byte, error) {
	size := uint32(16 * 1024)
	for attempt := 0; attempt < 4; attempt++ {
		buf := make([]byte, size)
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC,
			windows.GAA_FLAG_SKIP_ANYCAST|windows.GAA_FLAG_SKIP_MULTICAST|windows.GAA_FLAG_SKIP_DNS_SERVER,
			0, (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])), &size)
		if err == nil {
			return buf, nil
		}
		if err != windows.ERROR_BUFFER_OVERFLOW {
			return nil, err
		}
	}
	return nil, windows.ERROR_BUFFER_OVERFLOW
}

func TakeSnapshot() Snapshot {
	s := Snapshot{byName: map[string]*adapter{}, byIndex: map[uint32]string{}}
	buf, err := adapterAddresses()
	if err != nil {
		return s
	}
	for a := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])); a != nil; a = a.Next {
		name := windows.UTF16PtrToString(a.FriendlyName)
		if name == "" {
			continue
		}
		index := a.IfIndex
		if index == 0 {
			index = a.Ipv6IfIndex
		}
		ad := &adapter{
			name:     name,
			luid:     a.Luid,
			index:    index,
			up:       a.OperStatus == windows.IfOperStatusUp,
			loopback: a.IfType == windows.IF_TYPE_SOFTWARE_LOOPBACK,
		}
		ad.tunnel = isTunnelAdapter(a, name, windows.UTF16PtrToString(a.Description))
		for u := a.FirstUnicastAddress; u != nil; u = u.Next {
			ip := u.Address.IP()
			if v4 := ip.To4(); v4 != nil && !v4.IsLinkLocalUnicast() && !v4.IsLoopback() {
				ad.ipv4 = v4.String()
				break
			}
		}
		s.byName[name] = ad
		s.byIndex[index] = name
		if a.Ipv6IfIndex != 0 && a.Ipv6IfIndex != index {
			s.byIndex[a.Ipv6IfIndex] = name
		}
	}
	return s
}

func (s Snapshot) NameOf(index uint32) string { return s.byIndex[index] }

func (s Snapshot) IsTunnel(name string) bool {
	if a := s.byName[name]; a != nil {
		return a.tunnel
	}
	return IsTunnelName(name)
}

// LUID is what WFP filters name an interface by.
func (s Snapshot) LUID(name string) (uint64, bool) {
	if a := s.byName[name]; a != nil {
		return a.luid, true
	}
	return 0, false
}

func (s Snapshot) addresses() map[string]bool {
	own := map[string]bool{}
	for _, a := range s.byName {
		if a.ipv4 != "" {
			own[a.ipv4] = true
		}
	}
	return own
}

// Tunnels that are up, with or without an address, sorted by name. An
// address-less tunnel still counts: the probe binds by interface, not
// address.
func (s Snapshot) Tunnels() []Tunnel {
	var out []Tunnel
	for _, a := range s.byName {
		if a.tunnel && a.up {
			out = append(out, Tunnel{Name: a.name, IPv4: a.ipv4})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// PhysicalNames are the non-tunnel adapters that are up with IPv4 (Wi-Fi,
// Ethernet, a phone's USB tether…).
func (s Snapshot) PhysicalNames() []string {
	var out []string
	for _, a := range s.byName {
		if a.ipv4 != "" && a.up && !a.loopback && !a.tunnel {
			out = append(out, a.name)
		}
	}
	sort.Strings(out)
	return out
}

// interfaceIndex is for the probe, which has only a name.
func interfaceIndex(name string) (int, bool) {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return 0, false
	}
	return iface.Index, true
}

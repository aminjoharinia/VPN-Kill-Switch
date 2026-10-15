// Package daemon is the Linux kill switch: it watches the tunnel through
// netlink, proves it carries traffic with a pinned probe, and enforces the
// block with an nftables table of its own.
package daemon

import (
	"net"
	"sort"
	"strings"

	"github.com/vishvananda/netlink"
)

type Tunnel struct {
	Name string
	IPv4 string // may be empty: a tunnel can be IPv6-only or not yet addressed
}

// Name prefixes VPN clients give their interfaces. The link type catches
// the rest (any tun/tap or WireGuard device, whatever it is called).
var tunnelPrefixes = []string{
	"tun", "tap", "wg", "ppp", "ipsec", "utun", "vpn",
	"nordlynx", "proton", "mullvad", "tailscale", "sing", "clash", "nekoray", "xray", "happ",
}

var tunnelKinds = map[string]bool{
	"tuntap": true, "wireguard": true, "xfrm": true, "vti": true, "vti6": true,
}

// IsTunnelName judges by name alone, for routes and logs where only the
// name is at hand.
func IsTunnelName(name string) bool {
	for _, p := range tunnelPrefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// Snapshot is one netlink dump of links and their IPv4 addresses. Two
// dumps over a netlink socket, no process spawned: it costs well under a
// millisecond, which is what makes re-evaluating on every event affordable.
type Snapshot struct {
	byIndex map[int]string
	kinds   map[string]string
	ipv4    map[string]string
	up      map[string]bool
}

func TakeSnapshot() Snapshot {
	s := Snapshot{
		byIndex: map[int]string{}, kinds: map[string]string{},
		ipv4: map[string]string{}, up: map[string]bool{},
	}
	links, _ := netlink.LinkList()
	for _, l := range links {
		a := l.Attrs()
		s.byIndex[a.Index] = a.Name
		s.kinds[a.Name] = l.Type()
		s.up[a.Name] = a.Flags&net.FlagUp != 0 || a.OperState == netlink.OperUp
	}
	addrs, _ := netlink.AddrList(nil, netlink.FAMILY_V4)
	for _, a := range addrs {
		name := s.byIndex[a.LinkIndex]
		ip := a.IP.String()
		if name == "" || ip == "127.0.0.1" || strings.HasPrefix(ip, "169.254.") {
			continue
		}
		if _, seen := s.ipv4[name]; !seen {
			s.ipv4[name] = ip
		}
	}
	return s
}

func (s Snapshot) NameOf(index int) string { return s.byIndex[index] }

func (s Snapshot) IsTunnel(name string) bool {
	return tunnelKinds[s.kinds[name]] || IsTunnelName(name)
}

func (s Snapshot) Kind(name string) string { return s.kinds[name] }

// Tunnels that are up, with or without an address, sorted by name. An
// address-less tunnel still counts: the probe binds by device, not address.
func (s Snapshot) Tunnels() []Tunnel {
	var out []Tunnel
	for _, name := range s.byIndex {
		if s.IsTunnel(name) && s.up[name] {
			out = append(out, Tunnel{Name: name, IPv4: s.ipv4[name]})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// PhysicalNames are the non-tunnel interfaces with IPv4 (enp3s0, wlp2s0…).
func (s Snapshot) PhysicalNames() []string {
	var out []string
	for name := range s.ipv4 {
		if name != "lo" && !s.IsTunnel(name) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

func TunnelNames(tunnels []Tunnel) []string {
	out := make([]string, len(tunnels))
	for i, t := range tunnels {
		out[i] = t.Name
	}
	return out
}

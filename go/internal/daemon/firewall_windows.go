package daemon

import (
	"encoding/binary"
	"fmt"
	"net"
	"unsafe"

	"golang.org/x/sys/windows"

	"vpnks/internal/core"
)

// Enforcement through the Windows Filtering Platform, in a provider and
// sublayer of our own: the Windows counterpart of the pf anchor and the
// nftables table. Other software's filters are left alone, and removing
// ours lifts the block.
//
// The sublayer has the highest weight, so it is evaluated first and its
// block is final. Its permits are ordinary ("soft") ones: a stricter rule
// elsewhere — Windows Defender Firewall, another VPN's own kill switch —
// still applies to what we let through.
//
// The filters sit at the ALE connect and receive/accept layers, where
// Windows authorizes each new connection (and each new UDP peer), for both
// IPv4 and IPv6. Like nftables, and unlike pf, nothing outlives a new
// rule: an established flow is re-authorized when the rules change, so an
// in-flight download is cut too.
//
// The filters are not tied to the daemon's session, so a crash leaves the
// block standing (fail closed) until the service restarts. With autostart
// on they are also persistent — kept across a reboot until the daemon,
// started at boot, decides — the Windows form of "before network-pre".

var (
	wfpProviderKey = windows.GUID{Data1: 0x5c0b7a2e, Data2: 0x4d1f, Data3: 0x4e6a, Data4: [8]byte{0x9b, 0x3a, 0x6f, 0x21, 0x8e, 0x47, 0xd2, 0x01}}
	wfpSublayerKey = windows.GUID{Data1: 0x5c0b7a2e, Data2: 0x4d1f, Data3: 0x4e6a, Data4: [8]byte{0x9b, 0x3a, 0x6f, 0x21, 0x8e, 0x47, 0xd2, 0x02}}
	// The final IPv4 block carries a fixed key. Its presence is how the
	// daemon checks that the block is really loaded.
	wfpBlockMarkerKey = windows.GUID{Data1: 0x5c0b7a2e, Data2: 0x4d1f, Data3: 0x4e6a, Data4: [8]byte{0x9b, 0x3a, 0x6f, 0x21, 0x8e, 0x47, 0xd2, 0x10}}
)

const wfpSublayerWeight = 0xFFFF

// Weights inside our sublayer: the highest matching filter decides. The
// order is the Linux rule order.
const (
	weightInfrastructure = 15 // loopback, DHCP, IPv6 neighbour discovery
	weightTunnel         = 14
	weightVPNServer      = 13 // allow-listed servers and the VPN program
	weightDNSAssist      = 12
	weightDNSBlock       = 11
	weightReconnect      = 10 // after the DNS block: it opens the link, not lookups
	weightLAN            = 9
	weightBlockAll       = 0
)

type aleLayer struct {
	key  windows.GUID
	v6   bool
	name string
}

var aleLayers = []aleLayer{
	{layerALEAuthConnectV4, false, "outbound IPv4"},
	{layerALEAuthRecvAcceptV4, false, "inbound IPv4"},
	{layerALEAuthConnectV6, true, "outbound IPv6"},
	{layerALEAuthRecvAcceptV6, true, "inbound IPv6"},
}

func cond(field windows.GUID, match uint32, value fwpValue0) fwpmFilterCondition0 {
	return fwpmFilterCondition0{fieldKey: field, matchType: match, conditionValue: value}
}

func equal(field windows.GUID, value fwpValue0) fwpmFilterCondition0 {
	return cond(field, fwpMatchEqual, value)
}

func uint8Value(v uint8) fwpValue0   { return fwpValue0{typ: fwpUint8, value: uintptr(v)} }
func uint16Value(v uint16) fwpValue0 { return fwpValue0{typ: fwpUint16, value: uintptr(v)} }
func uint32Value(v uint32) fwpValue0 { return fwpValue0{typ: fwpUint32, value: uintptr(v)} }

// ipv4Host is an IPv4 literal as the engine wants it: a host-order uint32.
func ipv4Host(s string) (uint32, bool) {
	ip := net.ParseIP(s).To4()
	if ip == nil {
		return 0, false
	}
	return binary.BigEndian.Uint32(ip), true
}

// buildFilters turns the spec into filters, highest weight first. Pure
// apart from the arena, so the rule set is easy to read in one place.
func buildFilters(a *wfpArena, spec blockSpec, app *fwpByteBlob) []wfpFilter {
	var out []wfpFilter
	add := func(layer aleLayer, weight uint8, action uint32, name string, conds ...fwpmFilterCondition0) {
		out = append(out, wfpFilter{
			name: fmt.Sprintf("VPN Kill Switch: %s (%s)", name, layer.name), layer: layer.key,
			weight: weight, action: action, conditions: conds,
		})
	}
	ifaces := func(names []string) []fwpmFilterCondition0 {
		var c []fwpmFilterCondition0
		for _, n := range names {
			if luid, ok := spec.snap.LUID(n); ok {
				c = append(c, equal(conditionIPLocalInterface, a.uint64(luid)))
			}
		}
		return c
	}
	dnsPorts := []fwpmFilterCondition0{
		equal(conditionIPRemotePort, uint16Value(53)),
		equal(conditionIPRemotePort, uint16Value(853)),
	}

	for _, layer := range aleLayers {
		// Infrastructure that is never a leak: this machine talking to
		// itself, getting an address, finding its router. Linux's DHCP
		// client and neighbour discovery never reach nftables' output hook;
		// on Windows they must be let through explicitly or the machine
		// drops off the network altogether.
		add(layer, weightInfrastructure, fwpActionPermit, "loopback",
			cond(conditionFlags, fwpMatchFlagsAllSet, uint32Value(fwpConditionFlagIsLoopback)))
		if !layer.v6 {
			add(layer, weightInfrastructure, fwpActionPermit, "DHCP",
				equal(conditionIPProtocol, uint8Value(ipprotoUDP)),
				equal(conditionIPLocalPort, uint16Value(68)),
				equal(conditionIPRemotePort, uint16Value(67)))
		} else {
			add(layer, weightInfrastructure, fwpActionPermit, "DHCPv6",
				equal(conditionIPProtocol, uint8Value(ipprotoUDP)),
				equal(conditionIPLocalPort, uint16Value(546)),
				equal(conditionIPRemotePort, uint16Value(547)))
			// Router solicitation and advertisement, neighbour solicitation
			// and advertisement, redirect: link-local by definition.
			ndp := []fwpmFilterCondition0{equal(conditionIPProtocol, uint8Value(ipprotoICMPv6))}
			for _, t := range []uint16{133, 134, 135, 136, 137} {
				ndp = append(ndp, equal(conditionICMPType, uint16Value(t)))
			}
			add(layer, weightInfrastructure, fwpActionPermit, "neighbour discovery", ndp...)
		}

		// Traffic over the tunnels themselves is not a leak: a live tunnel
		// encrypts it, a dead one discards it. It is also what lets our own
		// probe see recovery while the block is on.
		for _, c := range ifaces(spec.tunnels) {
			add(layer, weightTunnel, fwpActionPermit, "tunnel", c)
		}

		if spec.cfg.AllowVPNReconnect {
			if !layer.v6 {
				var servers []fwpmFilterCondition0
				for _, ip := range spec.endpoints {
					if v, ok := ipv4Host(ip); ok {
						servers = append(servers, equal(conditionIPRemoteAddress, uint32Value(v)))
					}
				}
				if len(servers) > 0 {
					add(layer, weightVPNServer, fwpActionPermit, "VPN servers", servers...)
				}
			}
			// The VPN client's own program may reach its server — any
			// server — so switching to one never used before works, and so
			// do clients whose server address cannot be learned (UDP
			// sockets do not show their peer on Windows).
			if app != nil {
				blob := fwpValue0{typ: fwpByteBlobType, value: a.ptr(app, unsafe.Pointer(app))}
				add(layer, weightVPNServer, fwpActionPermit, "VPN app", equal(conditionALEAppID, blob))
			}
		}

		// Before the LAN permit, so lookups cannot leak to the router and on
		// to the ISP.
		if spec.cfg.BlockDNS {
			if assist := ifaces(spec.dnsAssist); len(assist) > 0 {
				add(layer, weightDNSAssist, fwpActionPermit, "DNS (reconnect assist)", append(assist, dnsPorts...)...)
			}
			add(layer, weightDNSBlock, fwpActionBlock, "DNS", dnsPorts...)
		}
		if spec.cfg.AllowVPNReconnect {
			if window := ifaces(spec.reconnect); len(window) > 0 {
				add(layer, weightReconnect, fwpActionPermit, "reconnect window", window...)
			}
		}
		if spec.cfg.AllowLAN {
			var lan []fwpmFilterCondition0
			if !layer.v6 {
				for _, cidr := range lanNets {
					_, n, err := net.ParseCIDR(cidr)
					if err != nil {
						continue
					}
					lan = append(lan, equal(conditionIPRemoteAddress,
						a.v4Net(binary.BigEndian.Uint32(n.IP.To4()), binary.BigEndian.Uint32(n.Mask))))
				}
			} else {
				for _, cidr := range []string{"fe80::/10", "ff00::/8"} {
					_, n, _ := net.ParseCIDR(cidr)
					ones, _ := n.Mask.Size()
					lan = append(lan, equal(conditionIPRemoteAddress, a.v6Net([16]byte(n.IP.To16()), uint8(ones))))
				}
			}
			add(layer, weightLAN, fwpActionPermit, "local network", lan...)
		}

		f := wfpFilter{
			name: "VPN Kill Switch: block (" + layer.name + ")", layer: layer.key,
			weight: weightBlockAll, action: fwpActionBlock,
		}
		if layer.key == layerALEAuthConnectV4 {
			f.key = wfpBlockMarkerKey
		}
		out = append(out, f)
	}
	return out
}

// replaceFilters swaps every filter we own for the given set, atomically.
// An empty set is "no block".
func replaceFilters(build func(a *wfpArena) []wfpFilter, persistent bool) error {
	return engine.transact(func(h windows.Handle) error {
		if err := addProvider(h, wfpProviderKey, core.TableName); err != nil {
			return err
		}
		if err := addSublayer(h, wfpSublayerKey, wfpProviderKey, core.TableName, wfpSublayerWeight); err != nil {
			return err
		}
		old, err := filtersOf(h, wfpProviderKey)
		if err != nil {
			return err
		}
		for _, key := range old {
			if err := deleteFilter(h, key); err != nil {
				return err
			}
		}
		var a wfpArena
		for _, f := range build(&a) {
			if err := addFilter(h, &a, wfpProviderKey, wfpSublayerKey, persistent, f); err != nil {
				return err
			}
		}
		return nil
	})
}

// loadBlock and loadObserve are the firewall as the state machine sees it.
func loadBlock(spec blockSpec) error {
	var app *fwpByteBlob
	if spec.cfg.AllowVPNReconnect && spec.vpnApp.Path != "" {
		blob, err := appID(spec.vpnApp.Path)
		if err != nil {
			core.Logf("WARN: cannot let %s through by program (%v)", spec.vpnApp.Path, err)
		} else {
			app = blob
			defer freeAppID(blob)
		}
	}
	return replaceFilters(func(a *wfpArena) []wfpFilter { return buildFilters(a, spec, app) }, spec.cfg.Autostart)
}

// loadObserve is "no block". Linux loads counting rules here to learn the
// VPN server; WFP has no cheap per-address byte count, so Windows learns
// from host routes and WireGuard peers alone, and lets the VPN program
// through by application while blocked.
func loadObserve(_ []string, _ Snapshot) error {
	return replaceFilters(func(*wfpArena) []wfpFilter { return nil }, false)
}

func tallied() map[string]uint64 { return nil }

// Clear removes every filter we own: nothing of ours filters anything
// afterwards.
func Clear() {
	if err := replaceFilters(func(*wfpArena) []wfpFilter { return nil }, false); err != nil {
		core.Logf("WARN: could not clear the block: %v", err)
	}
}

// removeAll is Clear plus the provider and sublayer, for uninstall.
func removeAll() error {
	return engine.transact(func(h windows.Handle) error {
		keys, err := filtersOf(h, wfpProviderKey)
		if err != nil {
			return err
		}
		for _, key := range keys {
			if err := deleteFilter(h, key); err != nil {
				return err
			}
		}
		for _, step := range []struct {
			proc *windows.LazyProc
			key  windows.GUID
		}{{procFwpmSubLayerDeleteByKey0, wfpSublayerKey}, {procFwpmProviderDeleteByKey0, wfpProviderKey}} {
			key := step.key
			err := wfpCall(step.proc, uintptr(h), uintptr(unsafe.Pointer(&key)))
			if err != nil && !isWFPError(err, fwpENotFound) && !isWFPError(err, fwpEInUse) {
				return err
			}
		}
		return nil
	})
}

// BlockLoaded asks the filtering engine whether the block is in force.
func BlockLoaded() bool {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	h, err := engine.open()
	if err != nil {
		return false
	}
	ok, err := filterExists(h, wfpBlockMarkerKey)
	if err != nil {
		engine.reset()
	}
	return ok
}

package daemon

import (
	"testing"
	"unsafe"

	"vpnks/internal/core"
)

// The C layouts for 64-bit Windows (fwpmtypes.h). A wrong offset here is
// a filter the engine reads differently from what we meant.
func TestWFPLayouts(t *testing.T) {
	var f fwpmFilter0
	offsets := []struct {
		name      string
		got, want uintptr
	}{
		{"FWPM_FILTER0 size", unsafe.Sizeof(f), 200},
		{"displayData", unsafe.Offsetof(f.displayData), 16},
		{"flags", unsafe.Offsetof(f.flags), 32},
		{"providerKey", unsafe.Offsetof(f.providerKey), 40},
		{"providerData", unsafe.Offsetof(f.providerData), 48},
		{"layerKey", unsafe.Offsetof(f.layerKey), 64},
		{"subLayerKey", unsafe.Offsetof(f.subLayerKey), 80},
		{"weight", unsafe.Offsetof(f.weight), 96},
		{"numFilterConditions", unsafe.Offsetof(f.numFilterConditions), 112},
		{"filterCondition", unsafe.Offsetof(f.filterCondition), 120},
		{"action", unsafe.Offsetof(f.action), 128},
		{"providerContextKey", unsafe.Offsetof(f.providerContextKey), 152},
		{"reserved", unsafe.Offsetof(f.reserved), 168},
		{"filterID", unsafe.Offsetof(f.filterID), 176},
		{"effectiveWeight", unsafe.Offsetof(f.effectiveWeight), 184},
		{"FWPM_FILTER_CONDITION0 size", unsafe.Sizeof(fwpmFilterCondition0{}), 40},
		{"FWPM_SESSION0 size", unsafe.Sizeof(fwpmSession0{}), 72},
		{"FWPM_SUBLAYER0 size", unsafe.Sizeof(fwpmSublayer0{}), 72},
		{"FWPM_PROVIDER0 size", unsafe.Sizeof(fwpmProvider0{}), 64},
		{"FWP_V6_ADDR_AND_MASK size", unsafe.Sizeof(fwpV6AddrAndMask{}), 17},
		{"MIB_TCP6ROW_OWNER_PID size", unsafe.Sizeof(tcp6RowOwnerPID{}), 56},
	}
	for _, o := range offsets {
		if o.got != o.want {
			t.Errorf("%s = %d, want %d", o.name, o.got, o.want)
		}
	}
}

// The policy, in order: what each layer gets and at which weight.
func TestBuildFiltersOrder(t *testing.T) {
	snap := Snapshot{byName: map[string]*adapter{
		"WireGuard": {name: "WireGuard", luid: 1, tunnel: true, up: true},
		"Wi-Fi":     {name: "Wi-Fi", luid: 2, ipv4: "192.168.1.5", up: true},
	}}
	spec := blockSpec{
		cfg: core.DefaultConfig(), snap: snap, tunnels: []string{"WireGuard"},
		endpoints: []string{"203.0.113.5"}, dnsAssist: []string{"Wi-Fi"}, reconnect: []string{"Wi-Fi"},
	}
	var a wfpArena
	filters := buildFilters(&a, spec, nil)
	var v4 []wfpFilter
	for _, f := range filters {
		if f.layer == layerALEAuthConnectV4 {
			v4 = append(v4, f)
		}
	}
	want := []struct {
		name   string
		weight uint8
		action uint32
	}{
		{"loopback", weightInfrastructure, fwpActionPermit},
		{"DHCP", weightInfrastructure, fwpActionPermit},
		{"tunnel", weightTunnel, fwpActionPermit},
		{"VPN servers", weightVPNServer, fwpActionPermit},
		{"DNS (reconnect assist)", weightDNSAssist, fwpActionPermit},
		{"DNS", weightDNSBlock, fwpActionBlock},
		{"reconnect window", weightReconnect, fwpActionPermit},
		{"local network", weightLAN, fwpActionPermit},
		{"block", weightBlockAll, fwpActionBlock},
	}
	if len(v4) != len(want) {
		t.Fatalf("outbound IPv4 has %d filters, want %d", len(v4), len(want))
	}
	for i, w := range want {
		if v4[i].name != "VPN Kill Switch: "+w.name+" (outbound IPv4)" || v4[i].weight != w.weight || v4[i].action != w.action {
			t.Errorf("filter %d = %q w%d a%#x, want %q w%d a%#x", i, v4[i].name, v4[i].weight, v4[i].action, w.name, w.weight, w.action)
		}
	}
	if v4[len(v4)-1].key != wfpBlockMarkerKey {
		t.Error("the outbound IPv4 block does not carry the marker key")
	}
}

// TestBlockRoundTrip loads a real block and lifts it. Needs an elevated
// terminal; it leaves nothing behind.
func TestBlockRoundTrip(t *testing.T) {
	if !core.IsAdmin() {
		t.Skip("needs an elevated terminal")
	}
	snap := TakeSnapshot()
	spec := blockSpec{cfg: core.DefaultConfig(), snap: snap, tunnels: TunnelNames(snap.Tunnels()),
		endpoints: []string{"203.0.113.5"}, dnsAssist: snap.PhysicalNames()}
	spec.vpnApp.Path = `C:\Windows\System32\curl.exe`
	defer func() {
		if err := removeAll(); err != nil {
			t.Errorf("removeAll: %v", err)
		}
		if BlockLoaded() {
			t.Error("block still loaded after removeAll")
		}
	}()
	if err := loadBlock(spec); err != nil {
		t.Fatalf("loadBlock: %v", err)
	}
	if !BlockLoaded() {
		t.Fatal("block not loaded after loadBlock")
	}
	// Loading again replaces, it does not stack.
	if err := loadBlock(spec); err != nil {
		t.Fatalf("second loadBlock: %v", err)
	}
	engine.mu.Lock()
	h, _ := engine.open()
	keys, err := filtersOf(h, wfpProviderKey)
	engine.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	var a wfpArena
	if want := len(buildFilters(&a, spec, &fwpByteBlob{})); len(keys) != want {
		t.Errorf("%d filters loaded, want %d", len(keys), want)
	}
	if err := loadObserve(nil, snap); err != nil {
		t.Fatalf("loadObserve: %v", err)
	}
	if BlockLoaded() {
		t.Error("block still loaded after loadObserve")
	}
}

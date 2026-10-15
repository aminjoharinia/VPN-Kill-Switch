package daemon

import (
	"strconv"
	"strings"
	"testing"
	"time"

	"vpnks/internal/core"
)

func TestBuildBlockOrder(t *testing.T) {
	cfg := core.DefaultConfig()
	script := BuildBlock(cfg, []string{"wg0"}, []string{"203.0.113.5"}, []string{"wlp2s0"})

	// Order is the policy: tunnel and VPN server out first, then DNS (the
	// assist's accept before the drop), then the LAN, then the final drop.
	order := []string{
		`oifname "lo" accept`,
		`oifname { "wg0" } accept`,
		`ip daddr { 203.0.113.5 } accept`,
		`oifname { "wlp2s0" } meta l4proto { tcp, udp } th dport { 53, 853 } accept`,
		`meta l4proto { tcp, udp } th dport { 53, 853 } drop`,
		`ip daddr { 10.0.0.0/8`,
		`drop comment "vpnks-block"`,
	}
	at := 0
	for _, want := range order {
		i := strings.Index(script[at:], want)
		if i < 0 {
			t.Fatalf("missing or out of order: %q\n%s", want, script)
		}
		at += i + len(want)
	}
	if !strings.HasPrefix(script, "table inet vpn_kill_switch\ndelete table inet vpn_kill_switch\n") {
		t.Fatalf("script must replace the table atomically:\n%s", script)
	}
}

func TestBuildBlockStrict(t *testing.T) {
	cfg := core.DefaultConfig()
	cfg.AllowLAN, cfg.BlockDNS, cfg.AllowVPNReconnect = false, false, false
	script := BuildBlock(cfg, nil, []string{"203.0.113.5"}, nil)
	for _, unwanted := range []string{"203.0.113.5", "10.0.0.0/8", "dport", `oifname {`} {
		if strings.Contains(script, unwanted) {
			t.Errorf("strict block should not contain %q:\n%s", unwanted, script)
		}
	}
}

func TestParseSeen(t *testing.T) {
	// Captured from nft 1.0.9 on Ubuntu 24.04.
	data := []byte(`{"nftables": [{"metainfo": {"version": "1.0.9", "release_name": "Old Doc Yak #3", "json_schema_version": 1}}, {"set": {"family": "inet", "name": "seen", "table": "vpn_kill_switch", "type": "ipv4_addr", "handle": 3, "size": 4096, "flags": ["timeout", "dynamic"], "timeout": 600, "elem": [{"elem": {"val": "203.0.113.5", "timeout": 600, "expires": 598, "counter": {"packets": 1, "bytes": 60}}}, {"elem": {"val": "198.51.100.7", "counter": {"packets": 900, "bytes": 1300000}}}]}}]}`)
	got := parseSeen(data)
	if got["203.0.113.5"] != 60 || got["198.51.100.7"] != 1300000 || len(got) != 2 {
		t.Fatalf("parseSeen = %v", got)
	}
}

func TestAllowListPrefersRecent(t *testing.T) {
	var all []core.Endpoint
	base := mustTime(t)
	for i := 0; i < core.MaxLearnedEndpoints+4; i++ {
		all = append(all, core.Endpoint{IP: ip4(i), LastSeen: base.AddDate(0, 0, -i), Hits: 1000 - i})
	}
	all = append(all, core.Endpoint{IP: "198.51.100.200", LastSeen: base.AddDate(-1, 0, 0), Hits: 1, Pinned: true})
	list := core.AllowListOf(all)
	if len(list) != core.MaxLearnedEndpoints+1 {
		t.Fatalf("want %d addresses, got %d: %v", core.MaxLearnedEndpoints+1, len(list), list)
	}
	has := map[string]bool{}
	for _, ip := range list {
		has[ip] = true
	}
	if !has["198.51.100.200"] || !has[ip4(0)] || has[ip4(core.MaxLearnedEndpoints)] {
		t.Fatalf("pinned must stay and the oldest learned must go: %v", list)
	}
}

func ip4(i int) string { return "203.0.113." + strconv.Itoa(i+1) }

func mustTime(t *testing.T) time.Time {
	t.Helper()
	return time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
}

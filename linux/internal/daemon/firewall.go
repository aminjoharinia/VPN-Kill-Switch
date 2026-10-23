package daemon

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"vpnks/internal/core"
)

// Enforcement through nftables, in a table of our own (inet family, so one
// ruleset covers IPv4 and IPv6). It is the Linux counterpart of the macOS pf
// anchor: other firewalls' tables are left alone, and deleting ours lifts
// the block.
//
// nftables evaluates every packet against the rules — there is no state
// table that lets an established connection skip them the way pf's does —
// so unlike macOS nothing needs flushing when the block goes up: an
// in-flight download is cut at its next packet.
//
// The rules sit in a regular chain jumped to from both output (this
// machine) and forward (containers and VMs routed through it), so a
// Docker container cannot leak around the block either.

var nftPath = "nft"

func init() {
	for _, p := range []string{"/usr/sbin/nft", "/sbin/nft"} {
		if _, err := exec.LookPath(p); err == nil {
			nftPath = p
			return
		}
	}
}

// Marker comment on the final drop. Its presence is how the daemon checks
// that the block is really loaded.
const blockMarker = "vpnks-block"

var lanNets = []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4"}

func quoteAll(names []string) string {
	q := make([]string, len(names))
	for i, n := range names {
		q[i] = fmt.Sprintf("%q", n)
	}
	return strings.Join(q, ", ")
}

// replaceTable wraps a table body so loading it is one atomic transaction
// that swaps whatever we had loaded for the new rules. The leading empty
// "table" declaration makes the delete succeed even when nothing exists.
func replaceTable(body string) string {
	return fmt.Sprintf("table inet %[1]s\ndelete table inet %[1]s\ntable inet %[1]s {\n%[2]s}\n", core.TableName, body)
}

// hooks jumps from the output and forward hooks into the guard chain.
const hooks = `	chain output {
		type filter hook output priority 0; policy accept;
		jump guard
	}
	chain forward {
		type filter hook forward priority 0; policy accept;
		jump guard
	}
`

// BuildBlock is the block. dnsAssist names the physical interfaces DNS may
// leave through despite blockDNS — the reconnect assist. reconnect names
// the physical interfaces opened while a VPN client connects to a new
// server (see KillSwitch.updateReconnectWindow).
func BuildBlock(cfg core.Config, tunnels, endpoints, dnsAssist, reconnect []string) string {
	var r []string
	r = append(r, `oifname "lo" accept`)

	// Traffic out over the tunnels themselves is not a leak: a live tunnel
	// encrypts it, a dead one discards it. It is also what lets our own
	// probe see recovery while the block is on — without it the switch
	// would stay latched down forever after the first drop.
	if len(tunnels) > 0 {
		r = append(r, fmt.Sprintf("oifname { %s } accept", quoteAll(tunnels)))
	}
	if cfg.AllowVPNReconnect && len(endpoints) > 0 {
		r = append(r, fmt.Sprintf("ip daddr { %s } accept", strings.Join(endpoints, ", ")))
	}
	// Before the LAN accept, so lookups cannot leak to the router and on to
	// the ISP. Local resolvers (systemd-resolved on 127.0.0.53) still work
	// through the loopback accept above.
	if cfg.BlockDNS && len(dnsAssist) > 0 {
		r = append(r, fmt.Sprintf("oifname { %s } meta l4proto { tcp, udp } th dport { 53, 853 } accept", quoteAll(dnsAssist)))
	}
	if cfg.BlockDNS {
		r = append(r, "meta l4proto { tcp, udp } th dport { 53, 853 } drop")
	}
	// After the DNS drop: the window opens the link, not lookups.
	if cfg.AllowVPNReconnect && len(reconnect) > 0 {
		r = append(r, fmt.Sprintf("oifname { %s } accept", quoteAll(reconnect)))
	}
	if cfg.AllowLAN {
		r = append(r, fmt.Sprintf("ip daddr { %s } accept", strings.Join(lanNets, ", ")))
		r = append(r, "ip6 daddr { fe80::/10, ff00::/8 } accept")
	}
	r = append(r, fmt.Sprintf("counter drop comment %q", blockMarker))

	body := "\tchain guard {\n\t\t" + strings.Join(r, "\n\t\t") + "\n\t}\n" + hooks
	return replaceTable(body)
}

// BuildObserve is loaded in place of the block while the VPN is healthy.
// It only ever accepts — traffic behaves exactly as with no table — but it
// counts the bytes exchanged with each public address over the physical
// interfaces. While a full-tunnel VPN is up, what crosses those interfaces
// directly is the VPN client talking to its server, so the biggest talker
// is the server. That is how its address is learned even from clients that
// use an unconnected UDP socket and add no host route.
func BuildObserve(physical []string) string {
	if len(physical) == 0 {
		return replaceTable("\tcomment \"idle\"\n")
	}
	private := strings.Join(append(append([]string{}, lanNets...), "127.0.0.0/8", "0.0.0.0/8"), ", ")
	ifs := quoteAll(physical)
	body := fmt.Sprintf(`	set seen {
		type ipv4_addr
		size 4096
		flags dynamic,timeout
		timeout 10m
	}
	chain observe_out {
		type filter hook output priority 0; policy accept;
		oifname { %[1]s } ip daddr != { %[2]s } meta l4proto { tcp, udp } update @seen { ip daddr counter }
	}
	chain observe_in {
		type filter hook input priority 0; policy accept;
		iifname { %[1]s } ip saddr != { %[2]s } meta l4proto { tcp, udp } update @seen { ip saddr counter }
	}
`, ifs, private)
	return replaceTable(body)
}

// Load applies a script from BuildBlock/BuildObserve atomically.
func Load(script string) error {
	cmd := exec.Command(nftPath, "-f", "-")
	cmd.Stdin = strings.NewReader(script)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(out.String()))
	}
	return nil
}

// Clear deletes the table: nothing of ours filters anything afterwards.
func Clear() {
	_ = exec.Command(nftPath, "delete", "table", "inet", core.TableName).Run()
}

// BlockLoaded asks the kernel whether the block is in force right now.
func BlockLoaded() bool {
	out, err := exec.Command(nftPath, "list", "chain", "inet", core.TableName, "guard").Output()
	return err == nil && bytes.Contains(out, []byte(blockMarker))
}

// SeenRemotes is the observe table's tally: public address → bytes both
// ways over the physical interfaces since the table was loaded.
func SeenRemotes() map[string]uint64 {
	out, err := exec.Command(nftPath, "-j", "list", "set", "inet", core.TableName, "seen").Output()
	if err != nil {
		return nil
	}
	return parseSeen(out)
}

func parseSeen(data []byte) map[string]uint64 {
	var doc struct {
		Nftables []struct {
			Set *struct {
				Elem []json.RawMessage `json:"elem"`
			} `json:"set"`
		} `json:"nftables"`
	}
	if json.Unmarshal(data, &doc) != nil {
		return nil
	}
	totals := map[string]uint64{}
	for _, item := range doc.Nftables {
		if item.Set == nil {
			continue
		}
		for _, raw := range item.Set.Elem {
			// With a counter attached an element is
			// {"elem": {"val": "1.2.3.4", "counter": {"bytes": N, …}, …}};
			// a bare string means no counter (and no use to us).
			var wrapped struct {
				Elem struct {
					Val     string `json:"val"`
					Counter struct {
						Bytes uint64 `json:"bytes"`
					} `json:"counter"`
				} `json:"elem"`
			}
			if json.Unmarshal(raw, &wrapped) == nil && wrapped.Elem.Val != "" {
				totals[wrapped.Elem.Val] += wrapped.Elem.Counter.Bytes
			}
		}
	}
	return totals
}

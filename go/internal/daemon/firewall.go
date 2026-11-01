package daemon

import "vpnks/internal/core"

// blockSpec is everything the block lets through, in the platform's
// firewall's terms: interfaces by name, addresses as IPv4 literals.
type blockSpec struct {
	cfg  core.Config
	snap Snapshot
	// Interfaces traffic may always leave through.
	tunnels []string
	// VPN server addresses (honoured only with AllowVPNReconnect).
	endpoints []string
	// Physical interfaces DNS may leave through despite BlockDNS — the
	// reconnect assist.
	dnsAssist []string
	// Physical interfaces opened while a VPN client connects to a new
	// server (see KillSwitch.updateReconnectWindow).
	reconnect []string
	// The program that owns the tunnel. Windows lets it through by
	// application while AllowVPNReconnect is on; Linux has no use for it.
	vpnApp VPNApp
}

// Private and link-local ranges, plus multicast: what "Allow local network"
// lets through.
var lanNets = []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4"}

package core

import (
	"encoding/json"
	"os"
	"strings"
	"time"
)

// DaemonStatus is the snapshot the daemon publishes for the app. The app
// is unprivileged, and most of this (whether the block is loaded, why) takes
// root to find out, so the daemon writes it world-readable on every change.
//
// Same keys as the macOS status.json. VPNBundleID carries the process that
// owns the tunnel on Linux (there are no bundle ids).
type DaemonStatus struct {
	UpdatedAt         time.Time  `json:"updatedAt"`
	Running           bool       `json:"running"`
	VPNState          string     `json:"vpnState"` // up | down
	Reason            string     `json:"reason"`
	VPNAppName        string     `json:"vpnAppName"`
	VPNBundleID       string     `json:"vpnBundleID"`
	Blocked           bool       `json:"blocked"`
	AlwaysArmed       bool       `json:"alwaysArmed"`
	AllowLAN          bool       `json:"allowLAN"`
	BlockDNS          bool       `json:"blockDNS"`
	AllowVPNReconnect bool       `json:"allowVPNReconnect"`
	Autostart         bool       `json:"autostart"`
	Mode              string     `json:"mode"`
	TunnelInterface   string     `json:"tunnelInterface"`
	TunnelAddress     string     `json:"tunnelAddress"`
	DefaultInterface  string     `json:"defaultInterface"`
	ProbeEnabled      bool       `json:"probeEnabled"`
	ProbeTarget       string     `json:"probeTarget"`
	Endpoints         []string   `json:"endpoints"`
	PID               int        `json:"pid"`
	DaemonVersion     string     `json:"daemonVersion"`
	SessionStartedAt  *time.Time `json:"sessionStartedAt,omitempty"`
	SessionBytesIn    uint64     `json:"sessionBytesIn"`
	SessionBytesOut   uint64     `json:"sessionBytesOut"`
	// Interface counters at the session's start (or last counter reset),
	// plus what was carried over a reset. The app computes live totals from
	// these and the interface's own counters, so this file need not be
	// rewritten every few seconds just to move a number.
	SessionBaseIn     uint64 `json:"sessionBaseIn"`
	SessionBaseOut    uint64 `json:"sessionBaseOut"`
	SessionCarriedIn  uint64 `json:"sessionCarriedIn"`
	SessionCarriedOut uint64 `json:"sessionCarriedOut"`
	// When the current block went up; nil while traffic flows.
	BlockedSince *time.Time `json:"blockedSince,omitempty"`
	// DNS is temporarily allowed so the VPN client can reconnect.
	ReconnectAssist bool `json:"reconnectAssist"`
	// The physical link is briefly open so a VPN client switching servers
	// can reach one it has never used. See KillSwitch.updateReconnectWindow.
	ReconnectWindow bool `json:"reconnectWindow"`
	// The tunnel and VPN app last seen up, kept after they go away so a
	// disconnect reads "WireGuard · wg0 (down)" rather than "not detected".
	LastTunnelInterface string `json:"lastTunnelInterface"`
	LastVPNAppName      string `json:"lastVPNAppName"`
}

// SameContent is equality apart from the fields that move on their own
// without anything the app shows having changed.
func (s DaemonStatus) SameContent(o DaemonStatus) bool {
	a, b := s, o
	a.UpdatedAt, b.UpdatedAt = time.Time{}, time.Time{}
	a.SessionBytesIn, b.SessionBytesIn = 0, 0
	a.SessionBytesOut, b.SessionBytesOut = 0, 0
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}

// Verifying: a tunnel exists but has not passed its first probe yet. That
// is the normal first second of every connection, not a failure.
func (s DaemonStatus) Verifying() bool {
	return s.VPNState != "up" && strings.HasPrefix(s.Reason, "awaiting-first-probe")
}

func ReadStatus() (*DaemonStatus, error) {
	data, err := os.ReadFile(StatusFile)
	if err != nil {
		return nil, err
	}
	var s DaemonStatus
	// Fields default sensibly when an older daemon left them out, so a
	// status feed degrades rather than blanking out.
	s.Running, s.VPNState, s.Mode = true, "down", "ALL"
	s.AllowLAN, s.BlockDNS, s.AllowVPNReconnect, s.ProbeEnabled = true, true, true, true
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// Write publishes the status world-readable: the app runs as the user.
func (s DaemonStatus) Write() error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return WriteAtomic(StatusFile, data, 0o644)
}

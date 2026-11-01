package daemon

// VPNApp names what owns the tunnel.
type VPNApp struct {
	Name    string // "Work VPN", "sing-box", "WireGuard"
	Process string // "/usr/bin/sing-box (pid 1234)"; empty for kernel devices
	PID     int    // the process holding the tun device; 0 for kernel devices
	// Path is the program's executable, set on Windows only, where the
	// block lets that program through by application.
	Path string
}

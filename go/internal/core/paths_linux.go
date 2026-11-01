package core

import (
	"os"
	"os/user"
	"strconv"
)

const (
	StateDir      = "/var/lib/vpn-kill-switch"
	ConfigFile    = StateDir + "/config.json"
	StatusFile    = StateDir + "/status.json"
	LogFile       = StateDir + "/kill_switch.log"
	SessionsFile  = StateDir + "/sessions.json"
	EndpointsFile = StateDir + "/endpoints.json"

	// The daemon runs from its own copy, so installing a newer app never
	// swaps the binary under a running daemon (same split as macOS).
	InstallDir      = "/usr/local/lib/vpn-kill-switch"
	InstalledBinary = InstallDir + "/vpnks"
	// Where the .deb puts the copy that ships with the app.
	PackagedDir    = "/usr/lib/vpn-kill-switch"
	PackagedBinary = PackagedDir + "/vpnks"

	UnitName = "vpn-kill-switch.service"
	UnitFile = "/etc/systemd/system/" + UnitName

	// nftables table that holds every rule this project loads. A table of
	// its own is the Linux counterpart of the pf anchor: other firewalls'
	// tables are never touched, and deleting ours clears the block.
	TableName = "vpn_kill_switch"
)

// AdminGroupID is the group whose members may tune settings without a
// password prompt: config.json and endpoints.json are left writable to it.
// On Ubuntu that is "sudo"; an admin who can edit those files could just
// as well authenticate, so nothing is given away.
func AdminGroupID() int {
	for _, name := range []string{"sudo", "admin", "wheel"} {
		if g, err := user.LookupGroup(name); err == nil {
			if id, err := strconv.Atoi(g.Gid); err == nil {
				return id
			}
		}
	}
	return 0
}

// ShareWithAdmins makes a daemon-owned file root:<admin group> 0664.
func ShareWithAdmins(path string) {
	_ = os.Chown(path, 0, AdminGroupID())
	_ = os.Chmod(path, 0o664)
}

// CLIName is the daemon's file name, next to the app and installed.
const CLIName = "vpnks"

// IsAdmin reports whether this process may change the firewall.
func IsAdmin() bool { return os.Geteuid() == 0 }

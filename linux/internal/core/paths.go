// Package core holds what the daemon and the app share: file locations,
// the configuration, the status file and the stores the daemon publishes.
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

// ModTime is the file's modification time, zero when it is missing.
func ModTime(path string) (t int64) {
	if info, err := os.Stat(path); err == nil {
		return info.ModTime().UnixNano()
	}
	return 0
}

// WriteInPlace truncates and rewrites an existing file without replacing
// it, so its owner and mode survive. An atomic rename would hand the file
// to whoever wrote it — and the app cannot create files in the root-owned
// state directory anyway.
func WriteInPlace(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// WriteAtomic replaces a file through a temporary in the same directory.
// Only the daemon (root) uses it, for files nobody else writes.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	_ = os.Chmod(tmp, mode)
	return os.Rename(tmp, path)
}

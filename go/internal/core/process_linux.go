package core

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
)

// IsDaemonProcess reads /proc/<pid>/cmdline, which anyone may read. The
// app uses it to tell a live daemon from a stale status file whose pid has
// since been reused by some other process; the status file's age cannot
// tell, since the daemon writes it only when something changes.
func IsDaemonProcess(pid int) bool {
	if pid <= 0 {
		return false
	}
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
	if err != nil {
		return false
	}
	args := bytes.Split(bytes.TrimRight(data, "\x00"), []byte{0})
	return len(args) >= 2 && filepath.Base(string(args[0])) == "vpnks" && string(args[1]) == "daemon"
}

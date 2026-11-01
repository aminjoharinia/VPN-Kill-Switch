package core

import (
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// IsDaemonProcess looks the pid up in the process list, which any user may
// read; opening the daemon itself would need rights over a LocalSystem
// process. The app uses it to tell a live daemon from a stale status file
// whose pid has since been reused by some other process.
func IsDaemonProcess(pid int) bool {
	if pid <= 0 {
		return false
	}
	found := false
	EachProcess(func(id uint32, exe string) bool {
		if int(id) == pid {
			found = strings.EqualFold(exe, CLIName)
			return false
		}
		return true
	})
	return found
}

// EachProcess calls visit with every process's pid and executable file
// name (no directory) until visit returns false.
func EachProcess(visit func(pid uint32, exe string) bool) {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return
	}
	defer windows.CloseHandle(snap)
	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	for err = windows.Process32First(snap, &entry); err == nil; err = windows.Process32Next(snap, &entry) {
		if !visit(entry.ProcessID, windows.UTF16ToString(entry.ExeFile[:])) {
			return
		}
	}
}

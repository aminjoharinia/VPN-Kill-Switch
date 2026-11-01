package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

func isExecutable(info fs.FileInfo) bool {
	return strings.EqualFold(filepath.Ext(info.Name()), ".exe")
}

var (
	modshell32          = windows.NewLazySystemDLL("shell32.dll")
	procShellExecuteExW = modshell32.NewProc("ShellExecuteExW")
)

// SHELLEXECUTEINFOW, 64-bit layout.
type shellExecuteInfo struct {
	size       uint32
	mask       uint32
	hwnd       uintptr
	verb       *uint16
	file       *uint16
	parameters *uint16
	directory  *uint16
	show       int32
	instApp    uintptr
	idList     uintptr
	class      *uint16
	keyClass   uintptr
	hotKey     uint32
	icon       uintptr
	process    windows.Handle
}

const (
	seeMaskNoCloseProcess = 0x40
	seeMaskNoAsync        = 0x100
	seeMaskFlagNoUI       = 0x400
	swHide                = 0
)

// runPrivileged runs the CLI elevated through UAC: Windows shows its own
// consent prompt (or asks for an administrator's password on a standard
// account). The app holds no rights itself and installs no helper.
//
// An elevated process gets no pipes back to us, so the CLI writes its
// output to a file we name (--report), read once it exits.
func runPrivileged(cli string, args ...string) (outcome, string) {
	report, err := os.CreateTemp("", "vpnks-*.txt")
	if err != nil {
		return failed, err.Error()
	}
	reportPath := report.Name()
	report.Close()
	defer os.Remove(reportPath)

	quoted := []string{"--report", syscall.EscapeArg(reportPath)}
	for _, a := range args {
		quoted = append(quoted, syscall.EscapeArg(a))
	}
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(cli)
	params, _ := windows.UTF16PtrFromString(strings.Join(quoted, " "))
	info := shellExecuteInfo{
		mask:       seeMaskNoCloseProcess | seeMaskNoAsync | seeMaskFlagNoUI,
		verb:       verb,
		file:       file,
		parameters: params,
		show:       swHide,
	}
	info.size = uint32(unsafe.Sizeof(info))
	if r, _, callErr := procShellExecuteExW.Call(uintptr(unsafe.Pointer(&info))); r == 0 {
		// The consent prompt was declined: nothing changed.
		if errors.Is(callErr, windows.ERROR_CANCELLED) {
			return cancelled, ""
		}
		return failed, callErr.Error()
	}
	defer windows.CloseHandle(info.process)
	if _, err := windows.WaitForSingleObject(info.process, windows.INFINITE); err != nil {
		return failed, err.Error()
	}
	var code uint32
	if err := windows.GetExitCodeProcess(info.process, &code); err != nil {
		return failed, err.Error()
	}
	if code == 0 {
		return done, ""
	}
	data, _ := os.ReadFile(reportPath)
	text := strings.TrimSpace(string(data))
	if text == "" {
		text = fmt.Sprintf("vpnks exited with code %d.", code)
	}
	return failed, text
}

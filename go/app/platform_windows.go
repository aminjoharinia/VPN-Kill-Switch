package main

import (
	"syscall"

	"vpnks/internal/core"
)

var platform = PlatformText{
	OS:              "windows",
	BuildLead:       "Reinstall VPN Kill Switch, or build it from the project folder:",
	BuildCommand:    "build.cmd",
	UnblockLead:     "Turning the kill switch off restores traffic. From a terminal opened as administrator:",
	UnblockCommand:  asAdmin(core.InstalledBinary, "unblock"),
	AutostartTitle:  "Start with Windows",
	AutostartDetail: "Asks for permission — the service then starts with Windows, and the block stays in force across restarts.",
	TrayTitle:       "Notification area icon",
	TrayDetail:      "Shows the state on an amber-and-black plate, like the app icon, so it stands out among the other icons.",
}

// asAdmin is a command line to paste into an elevated PowerShell.
func asAdmin(cli string, args ...string) string {
	line := "& " + syscall.EscapeArg(cli)
	for _, a := range args {
		line += " " + a
	}
	return line
}

const serviceLogHint = "Check Activity, or Event Viewer → Windows Logs → System for messages from the Service Control Manager."

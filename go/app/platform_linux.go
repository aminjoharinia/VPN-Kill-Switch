package main

import (
	"strings"

	"vpnks/internal/core"
)

var platform = PlatformText{
	OS:              "linux",
	BuildLead:       "Build the daemon first, then press Turn On:",
	BuildCommand:    "./build.sh",
	UnblockLead:     "Turning the kill switch off restores traffic. From any terminal:",
	UnblockCommand:  "sudo nft delete table inet " + core.TableName,
	AutostartTitle:  "Start at boot",
	AutostartDetail: "Requires your password — it enables a system service, so protection is up before the network.",
	TrayTitle:       "Tray icon",
	TrayDetail:      "Shows the state on an amber-and-black plate, like the app icon, so it stands out in a busy top bar.",
}

// asAdmin is a command line to run by hand as an administrator.
func asAdmin(cli string, args ...string) string {
	return "sudo " + cli + " " + strings.Join(args, " ")
}

const serviceLogHint = "Check Activity, or the service log:\n\n    journalctl -u " + core.UnitName + " -n 50"

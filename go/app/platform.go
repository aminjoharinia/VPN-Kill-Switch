package main

// PlatformText is what the window says differently on each platform:
// commands to type, and the names of things.
type PlatformText struct {
	OS string `json:"os"` // linux | windows
	// When the daemon is missing next to the app.
	BuildLead    string `json:"buildLead"`
	BuildCommand string `json:"buildCommand"`
	// "Stuck offline?": how to lift the block without the app.
	UnblockLead     string `json:"unblockLead"`
	UnblockCommand  string `json:"unblockCommand"`
	AutostartTitle  string `json:"autostartTitle"`
	AutostartDetail string `json:"autostartDetail"`
	TrayTitle       string `json:"trayTitle"`
	TrayDetail      string `json:"trayDetail"`
}

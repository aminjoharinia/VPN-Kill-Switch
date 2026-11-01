package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Prefs are this app's own display preferences, not the daemon's, so
// they work while the kill switch is off and need no password.
type Prefs struct {
	Appearance  string `json:"appearance"`  // auto | light | dark
	TrayStripes bool   `json:"trayStripes"` // hazard-stripe tray icon
}

func prefsPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = filepath.Join(os.Getenv("HOME"), ".config")
	}
	return filepath.Join(dir, "vpn-kill-switch", "prefs.json")
}

func loadPrefs() Prefs {
	p := Prefs{Appearance: "auto", TrayStripes: true}
	if data, err := os.ReadFile(prefsPath()); err == nil {
		_ = json.Unmarshal(data, &p)
	}
	switch p.Appearance {
	case "auto", "light", "dark":
	default:
		p.Appearance = "auto"
	}
	return p
}

func (p Prefs) save() {
	path := prefsPath()
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	data, _ := json.MarshalIndent(p, "", "  ")
	_ = os.WriteFile(path, data, 0o644)
}

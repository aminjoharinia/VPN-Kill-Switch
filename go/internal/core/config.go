package core

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Config uses the same keys as the macOS daemon's config.json.
type Config struct {
	Mode                 string  `json:"mode"`         // ALL | LIST
	VPNInterface         string  `json:"vpnInterface"` // "" = auto-track
	ProbeEnabled         bool    `json:"probeEnabled"`
	ProbeHost            string  `json:"probeHost"` // IP literal: no DNS needed
	ProbePort            uint16  `json:"probePort"`
	ProbeHostHeader      string  `json:"probeHostHeader"`
	ProbePath            string  `json:"probePath"`
	ProbeTimeoutSeconds  float64 `json:"probeTimeoutSeconds"`
	ProbeIntervalSeconds float64 `json:"probeIntervalSeconds"`
	ProbeFailThreshold   int     `json:"probeFailThreshold"`
	RequireDefaultRoute  bool    `json:"requireDefaultRoute"`
	AllowLAN             bool    `json:"allowLAN"`
	BlockDNS             bool    `json:"blockDNS"`
	AllowVPNReconnect    bool    `json:"allowVPNReconnect"`
	AlwaysArmed          bool    `json:"alwaysArmed"`
	Autostart            bool    `json:"autostart"`
}

func DefaultConfig() Config {
	return Config{
		Mode:                 "ALL",
		ProbeEnabled:         true,
		ProbeHost:            "1.1.1.1",
		ProbePort:            80,
		ProbeHostHeader:      "1.1.1.1",
		ProbePath:            "/",
		ProbeTimeoutSeconds:  3,
		ProbeIntervalSeconds: 1,
		ProbeFailThreshold:   1,
		RequireDefaultRoute:  true,
		AllowLAN:             true,
		BlockDNS:             true,
		AllowVPNReconnect:    true,
	}
}

func LoadConfig() Config {
	if c, ok := LoadConfigIfValid(); ok {
		return c
	}
	return DefaultConfig()
}

// LoadConfigIfValid reports false when the file is absent or does not
// parse. The reload path uses it so catching the file mid-write keeps the
// current settings instead of resetting every one of them to defaults.
// Keys missing from the file keep their defaults.
func LoadConfigIfValid() (Config, bool) {
	data, err := os.ReadFile(ConfigFile)
	if err != nil {
		return Config{}, false
	}
	c := DefaultConfig()
	if err := json.Unmarshal(data, &c); err != nil {
		return Config{}, false
	}
	return c, true
}

// Save writes the config root:<admins> 0664, so the app can toggle a
// setting with a plain file write instead of a password prompt each time.
// Starting, stopping and clearing a block still need root.
func (c Config) Save() error {
	if err := os.MkdirAll(filepath.Dir(ConfigFile), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if _, err := os.Stat(ConfigFile); err == nil {
		if err := WriteInPlace(ConfigFile, data); err != nil {
			return err
		}
	} else if err := os.WriteFile(ConfigFile, data, 0o664); err != nil {
		return err
	}
	ShareWithAdmins(ConfigFile)
	return nil
}

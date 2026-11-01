package main

import (
	"os"
	"path/filepath"

	"vpnks/internal/core"
)

type outcome int

const (
	done outcome = iota
	cancelled
	failed
)

// resolvedCLI prefers the copy shipped with this app, NOT the installed
// one: invoking the installed binary would reinstall itself (source ==
// destination) and the daemon could never be upgraded.
func resolvedCLI() string {
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), core.CLIName))
	}
	candidates = append(candidates, core.PackagedBinary, core.InstalledBinary)
	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && !info.IsDir() && isExecutable(info) {
			return c
		}
	}
	return ""
}

package main

import (
	"bytes"
	"errors"
	"io/fs"
	"os/exec"
	"strings"
)

func isExecutable(info fs.FileInfo) bool { return info.Mode()&0o111 != 0 }

// runPrivileged runs the CLI as root through pkexec. polkit shows its own
// password dialog — the one GNOME uses for every administrative action —
// with the message from the policy the package installs. The app holds no
// rights itself and installs no helper.
func runPrivileged(cli string, args ...string) (outcome, string) {
	pkexec, err := exec.LookPath("pkexec")
	if err != nil {
		return failed, "pkexec was not found. Install polkit (sudo apt install pkexec), or run this from a terminal:\n\n    sudo " + cli + " " + strings.Join(args, " ")
	}
	cmd := exec.Command(pkexec, append([]string{cli}, args...)...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err = cmd.Run()
	if err == nil {
		return done, ""
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		switch exit.ExitCode() {
		// 126: the dialog was dismissed. 127: not authorised, or no
		// polkit agent to ask. Neither changed anything.
		case 126:
			return cancelled, ""
		case 127:
			text := strings.TrimSpace(out.String())
			if strings.Contains(text, "dismissed") || text == "" {
				return cancelled, ""
			}
			return failed, text
		}
	}
	text := strings.TrimSpace(out.String())
	if text == "" {
		text = err.Error()
	}
	return failed, text
}

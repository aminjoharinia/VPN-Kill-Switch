package daemon

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// DetectVPNApp looks, in order of how readable the answer is, at:
//
//  1. NetworkManager's active connection on that device — the name the
//     user gave it;
//  2. the process holding the device open, from /proc/<pid>/fdinfo, which
//     names the tun interface each /dev/net/tun descriptor is attached to;
//  3. the link type, for kernel devices with no process (WireGuard).
func DetectVPNApp(tunnel string, snap Snapshot) (VPNApp, bool) {
	if tunnel == "" {
		return VPNApp{}, false
	}
	app := VPNApp{}
	if pid, exe, comm := tunOwner(tunnel); pid > 0 {
		app.Name = comm
		app.Process = exe + " (pid " + strconv.Itoa(pid) + ")"
		app.PID = pid
	}
	if name := networkManagerName(tunnel); name != "" {
		app.Name = name
	}
	if app.Name == "" && snap.Kind(tunnel) == "wireguard" {
		app.Name = "WireGuard"
	}
	return app, app.Name != ""
}

func networkManagerName(device string) string {
	nmcli, err := exec.LookPath("nmcli")
	if err != nil {
		return ""
	}
	out, err := exec.Command(nmcli, "-t", "-f", "NAME,DEVICE", "connection", "show", "--active").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		// Terse output escapes ':' inside fields as '\:'.
		i := lastUnescapedColon(line)
		if i < 0 {
			continue
		}
		if line[i+1:] == device {
			return strings.ReplaceAll(line[:i], `\:`, ":")
		}
	}
	return ""
}

func lastUnescapedColon(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == ':' && (i == 0 || s[i-1] != '\\') {
			return i
		}
	}
	return -1
}

// tunOwner finds the process with a /dev/net/tun descriptor attached to
// the interface. The kernel reports it as "iff:\t<name>" in fdinfo.
func tunOwner(iface string) (pid int, exe, comm string) {
	procs, _ := os.ReadDir("/proc")
	want := []byte("iff:\t" + iface + "\n")
	for _, p := range procs {
		id, err := strconv.Atoi(p.Name())
		if err != nil {
			continue
		}
		fdDir := filepath.Join("/proc", p.Name(), "fd")
		fds, err := os.ReadDir(fdDir)
		if err != nil {
			continue
		}
		for _, fd := range fds {
			target, err := os.Readlink(filepath.Join(fdDir, fd.Name()))
			if err != nil || target != "/dev/net/tun" {
				continue
			}
			info, err := os.ReadFile(filepath.Join("/proc", p.Name(), "fdinfo", fd.Name()))
			if err != nil || !bytes.Contains(info, want) {
				continue
			}
			exe, _ = os.Readlink(filepath.Join("/proc", p.Name(), "exe"))
			comm = readComm(p.Name())
			return id, exe, comm
		}
	}
	return 0, "", ""
}

func readComm(pid string) string {
	f, err := os.Open(filepath.Join("/proc", pid, "comm"))
	if err != nil {
		return ""
	}
	defer f.Close()
	line, _ := bufio.NewReader(f).ReadString('\n')
	return strings.TrimSpace(line)
}

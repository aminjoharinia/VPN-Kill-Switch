package daemon

import (
	"bufio"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"vpnks/internal/core"
)

// SocketRemotes is the public IPv4 addresses the process's own sockets are
// connected — or still trying to connect — to, with a count of sockets per
// address.
//
// This is what lets proxy-style clients (Xray, sing-box, Happ…) reconnect
// through a block. Their core reaches its server through an ordinary socket
// on the physical interface: no host route, no WireGuard peer. If the block
// went up before the server was ever seen healthy (the switch was turned on
// first, or the client moved to a new server), nothing else names it — the
// core's connection attempt is dropped, the probe fails forever, and traffic
// stays cut. The attempt itself is visible here, as a socket in SYN_SENT.
//
// Only the process that owns the tunnel is read, and DNS ports are skipped
// (the reconnect assist handles lookups).
func SocketRemotes(pid int) map[string]int {
	observed := map[string]int{}
	if pid <= 0 {
		return observed
	}
	proc := filepath.Join("/proc", strconv.Itoa(pid))
	inodes := map[string]bool{}
	fds, err := os.ReadDir(filepath.Join(proc, "fd"))
	if err != nil {
		return observed
	}
	for _, fd := range fds {
		target, err := os.Readlink(filepath.Join(proc, "fd", fd.Name()))
		if err == nil && strings.HasPrefix(target, "socket:[") {
			inodes[strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]")] = true
		}
	}
	if len(inodes) == 0 {
		return observed
	}
	// The process's own network namespace's tables.
	for _, table := range []string{"tcp", "tcp6", "udp", "udp6"} {
		f, err := os.Open(filepath.Join(proc, "net", table))
		if err != nil {
			continue
		}
		scanner := bufio.NewScanner(f)
		scanner.Scan() // header
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			if len(fields) < 10 || !inodes[fields[9]] {
				continue
			}
			ip, port, ok := parseProcAddress(fields[2])
			if !ok || port == 0 || port == 53 || port == 853 || core.IsPrivate(ip) {
				continue
			}
			observed[ip]++
		}
		f.Close()
	}
	return observed
}

// parseProcAddress decodes a /proc/net address such as "0100007F:0035"
// (IPv4) or a 32-digit IPv6 one. The kernel prints each 32-bit word in
// host order, which is little-endian on every platform Ubuntu ships for.
// Only IPv4 — plain or IPv4-mapped — is returned.
func parseProcAddress(field string) (ip string, port int, ok bool) {
	hostHex, portHex, found := strings.Cut(field, ":")
	if !found {
		return "", 0, false
	}
	p, err := strconv.ParseUint(portHex, 16, 16)
	if err != nil {
		return "", 0, false
	}
	raw, err := hex.DecodeString(hostHex)
	if err != nil || (len(raw) != 4 && len(raw) != 16) {
		return "", 0, false
	}
	for i := 0; i+4 <= len(raw); i += 4 {
		raw[i], raw[i+1], raw[i+2], raw[i+3] = raw[i+3], raw[i+2], raw[i+1], raw[i]
	}
	v4 := net.IP(raw).To4()
	if v4 == nil {
		return "", 0, false
	}
	return v4.String(), int(p), true
}

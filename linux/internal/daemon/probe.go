package daemon

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Probe is a real HTTP round trip pinned to one interface.
//
// Not a ping, not a bare TCP connect — both were measured on a live
// transparent-proxy tunnel (sing-box class, the common case):
//
//   - ICMP fails even when the tunnel is healthy, because the proxy does
//     not forward pings. Trusting it means blocking forever.
//   - a TCP connect SUCCEEDS against a black-holed address, because the
//     proxy accepts the socket locally before it has an upstream.
//
// Only bytes coming back from a real server tell those apart. The target
// is an IP literal so no DNS is needed while our own block is in force.
func Probe(iface, host string, port uint16, hostHeader, path string, timeout time.Duration) bool {
	if iface == "" {
		return false
	}
	dialer := net.Dialer{
		Timeout: timeout,
		// SO_BINDTODEVICE pins the socket to the tunnel. Without it the
		// probe would happily succeed over the physical link — precisely
		// the leak it exists to detect. Needs root, which the daemon is.
		Control: func(_, _ string, c syscall.RawConn) error {
			var serr error
			err := c.Control(func(fd uintptr) {
				serr = unix.SetsockoptString(int(fd), unix.SOL_SOCKET, unix.SO_BINDTODEVICE, iface)
			})
			if err != nil {
				return err
			}
			return serr
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	conn, err := dialer.DialContext(ctx, "tcp4", net.JoinHostPort(host, strconv.Itoa(int(port))))
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))

	request := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: vpnks/1.0\r\nConnection: close\r\n\r\n", path, hostHeader)
	if _, err := conn.Write([]byte(request)); err != nil {
		return false
	}
	buf := make([]byte, 256)
	n, err := conn.Read(buf)
	if n <= 0 {
		_ = err
		return false
	}
	// Any well-formed 2xx/3xx proves bytes traversed the tunnel.
	head := string(buf[:min(n, 32)])
	if !strings.HasPrefix(head, "HTTP/1.") {
		return false
	}
	fields := strings.Fields(head)
	if len(fields) < 2 {
		return false
	}
	code, err := strconv.Atoi(fields[1])
	return err == nil && code >= 200 && code < 400
}

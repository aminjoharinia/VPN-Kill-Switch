package daemon

import (
	"syscall"

	"golang.org/x/sys/unix"
)

// bindToInterface pins a socket to the device with SO_BINDTODEVICE. Needs
// root, which the daemon is.
func bindToInterface(iface string) func(network, address string, c syscall.RawConn) error {
	return func(_, _ string, c syscall.RawConn) error {
		var serr error
		err := c.Control(func(fd uintptr) {
			serr = unix.SetsockoptString(int(fd), unix.SOL_SOCKET, unix.SO_BINDTODEVICE, iface)
		})
		if err != nil {
			return err
		}
		return serr
	}
}

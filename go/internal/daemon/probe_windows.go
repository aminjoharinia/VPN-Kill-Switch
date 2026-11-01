package daemon

import (
	"errors"
	"math/bits"
	"syscall"

	"golang.org/x/sys/windows"
)

const ipUnicastIF = 31 // IP_UNICAST_IF

// bindToInterface pins a socket to the adapter with IP_UNICAST_IF, which
// takes the interface index in network byte order for IPv4.
func bindToInterface(iface string) func(network, address string, c syscall.RawConn) error {
	return func(_, _ string, c syscall.RawConn) error {
		index, ok := interfaceIndex(iface)
		if !ok {
			return errors.New("no such interface: " + iface)
		}
		var serr error
		err := c.Control(func(fd uintptr) {
			serr = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, ipUnicastIF,
				int(bits.ReverseBytes32(uint32(index))))
		})
		if err != nil {
			return err
		}
		return serr
	}
}

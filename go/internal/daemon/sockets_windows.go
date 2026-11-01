package daemon

import (
	"encoding/binary"
	"net"
	"unsafe"

	"golang.org/x/sys/windows"

	"vpnks/internal/core"
)

var (
	modiphlpapi             = windows.NewLazySystemDLL("iphlpapi.dll")
	procGetExtendedTcpTable = modiphlpapi.NewProc("GetExtendedTcpTable")
)

const tcpTableOwnerPIDAll = 5

// MIB_TCPROW_OWNER_PID and MIB_TCP6ROW_OWNER_PID.
type tcpRowOwnerPID struct {
	state, localAddr, localPort, remoteAddr, remotePort, owningPID uint32
}

type tcp6RowOwnerPID struct {
	localAddr     [16]byte
	localScopeID  uint32
	localPort     uint32
	remoteAddr    [16]byte
	remoteScopeID uint32
	remotePort    uint32
	state         uint32
	owningPID     uint32
}

func extendedTCPTable(family uint32) []byte {
	size := uint32(64 * 1024)
	for attempt := 0; attempt < 4; attempt++ {
		buf := make([]byte, size)
		r, _, _ := procGetExtendedTcpTable.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)),
			0, uintptr(family), tcpTableOwnerPIDAll, 0)
		switch windows.Errno(r) {
		case 0:
			return buf
		case windows.ERROR_INSUFFICIENT_BUFFER:
			size += 16 * 1024
			continue
		}
		return nil
	}
	return nil
}

// ntohs reads the port the tables keep in network order in a DWORD.
func ntohs(v uint32) int {
	var b [2]byte
	binary.LittleEndian.PutUint16(b[:], uint16(v))
	return int(binary.BigEndian.Uint16(b[:]))
}

// SocketRemotes is the public IPv4 addresses the process's own TCP sockets
// are connected — or still trying to connect — to, with a count of sockets
// per address. The Windows counterpart of the /proc walk on Linux; see
// sockets_linux.go for why it matters.
//
// Only TCP: Windows lists no remote address for UDP sockets. A UDP-based
// client (WireGuard, Hysteria, TUIC) reconnects through the block because
// its program is let through by application instead.
func SocketRemotes(pid int) map[string]int {
	observed := map[string]int{}
	if pid <= 0 {
		return observed
	}
	note := func(ip net.IP, port int) {
		v4 := ip.To4()
		if v4 == nil || port == 0 || port == 53 || port == 853 {
			return
		}
		if s := v4.String(); !core.IsPrivate(s) {
			observed[s]++
		}
	}
	if buf := extendedTCPTable(windows.AF_INET); len(buf) >= 4 {
		n := binary.LittleEndian.Uint32(buf)
		rows := unsafe.Slice((*tcpRowOwnerPID)(unsafe.Pointer(&buf[4])), n)
		for _, r := range rows {
			if int(r.owningPID) == pid {
				var ip [4]byte
				binary.LittleEndian.PutUint32(ip[:], r.remoteAddr)
				note(net.IP(ip[:]), ntohs(r.remotePort))
			}
		}
	}
	// Dual-stack sockets show IPv4 peers here, as IPv4-mapped addresses.
	if buf := extendedTCPTable(windows.AF_INET6); len(buf) >= 8 {
		n := binary.LittleEndian.Uint32(buf)
		rows := unsafe.Slice((*tcp6RowOwnerPID)(unsafe.Pointer(&buf[4])), n)
		for _, r := range rows {
			if int(r.owningPID) == pid {
				note(net.IP(r.remoteAddr[:]), ntohs(r.remotePort))
			}
		}
	}
	return observed
}

package core

import (
	"net"

	"golang.org/x/sys/windows"
)

// InterfaceCounters reads the adapter's byte counters (GetIfEntry2Ex): no
// rights needed, nothing written. The app uses it for live session totals,
// the daemon for session history. Interfaces go by their friendly name
// ("Wi-Fi", "sing-box"), as everywhere else on Windows.
func InterfaceCounters(name string) (Counters, bool) {
	if name == "" {
		return Counters{}, false
	}
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return Counters{}, false
	}
	row := windows.MibIfRow2{InterfaceIndex: uint32(iface.Index)}
	if err := windows.GetIfEntry2Ex(windows.MibIfEntryNormal, &row); err != nil {
		return Counters{}, false
	}
	return Counters{BytesIn: row.InOctets, BytesOut: row.OutOctets}, true
}

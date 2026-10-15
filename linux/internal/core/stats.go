package core

import (
	"os"
	"strconv"
	"strings"
)

// Counters are an interface's byte totals since it was created.
type Counters struct {
	BytesIn  uint64
	BytesOut uint64
}

// InterfaceCounters reads sysfs: no root needed, nothing written. The app
// uses it for live session totals, the daemon for session history.
func InterfaceCounters(name string) (Counters, bool) {
	// Interface names never contain "/"; refusing them keeps a name read
	// from status.json from walking out of sysfs.
	if name == "" || strings.Contains(name, "/") || name == "." || name == ".." {
		return Counters{}, false
	}
	rx, err1 := readUint("/sys/class/net/" + name + "/statistics/rx_bytes")
	tx, err2 := readUint("/sys/class/net/" + name + "/statistics/tx_bytes")
	if err1 != nil || err2 != nil {
		return Counters{}, false
	}
	return Counters{BytesIn: rx, BytesOut: tx}, true
}

func readUint(path string) (uint64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
}

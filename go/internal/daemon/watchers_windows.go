package daemon

import (
	"golang.org/x/sys/windows"

	"vpnks/internal/core"
)

// Handles of the registered notifications, held for the daemon's lifetime.
var networkNotifications []windows.Handle

// WatchNetwork calls notify on every interface, address and route change
// the IP helper reports. The Windows counterpart of netlink; notify must
// not block (the caller coalesces).
func WatchNetwork(notify func()) {
	// One callback serves all three: the arguments are not needed, only
	// that something changed. It runs on a system thread.
	callback := windows.NewCallback(func(context, row, kind uintptr) uintptr {
		notify()
		return 0
	})
	register := []struct {
		name string
		fn   func(uint16, uintptr, *windows.Handle) error
	}{
		{"interface", func(f uint16, cb uintptr, h *windows.Handle) error {
			return windows.NotifyIpInterfaceChange(f, cb, nil, false, h)
		}},
		{"address", func(f uint16, cb uintptr, h *windows.Handle) error {
			return windows.NotifyUnicastIpAddressChange(f, cb, nil, false, h)
		}},
		{"route", func(f uint16, cb uintptr, h *windows.Handle) error {
			return windows.NotifyRouteChange2(f, cb, nil, false, h)
		}},
	}
	for _, r := range register {
		var h windows.Handle
		if err := r.fn(windows.AF_UNSPEC, callback, &h); err != nil {
			core.Logf("WARN: %s events unavailable (%v); relying on the 1s poll", r.name, err)
			continue
		}
		networkNotifications = append(networkNotifications, h)
	}
}

// PowerEvents reports sleep (true) and wake (false). On Windows they come
// from the service control manager (see service_windows.go); a daemon run
// by hand in a terminal gets none and relies on the 1-second poll.
type PowerEvents struct {
	Events chan bool
}

var servicePower = make(chan bool, 4)

func WatchPower() *PowerEvents { return &PowerEvents{Events: servicePower} }

// Release lets a pending sleep go ahead. Windows does not wait for
// services beyond answering the event, so there is nothing to release.
func (p *PowerEvents) Release() {}

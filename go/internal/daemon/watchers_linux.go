package daemon

import (
	"os"

	"github.com/godbus/dbus/v5"
	"github.com/vishvananda/netlink"

	"vpnks/internal/core"
)

// WatchNetwork calls notify on every link, address and route change the
// kernel reports. The Linux counterpart of NWPathMonitor; notify must not
// block (the caller coalesces).
func WatchNetwork(notify func()) {
	done := make(chan struct{}) // never closed: the daemon lives as long as these
	links := make(chan netlink.LinkUpdate, 64)
	addrs := make(chan netlink.AddrUpdate, 64)
	routes := make(chan netlink.RouteUpdate, 64)

	if err := netlink.LinkSubscribe(links, done); err != nil {
		core.Logf("WARN: link events unavailable (%v); relying on the 1s poll", err)
	}
	if err := netlink.AddrSubscribe(addrs, done); err != nil {
		core.Logf("WARN: address events unavailable (%v)", err)
	}
	if err := netlink.RouteSubscribe(routes, done); err != nil {
		core.Logf("WARN: route events unavailable (%v)", err)
	}
	go func() {
		for {
			select {
			case <-links:
			case <-addrs:
			case <-routes:
			}
			notify()
		}
	}()
}

// PowerEvents reports sleep (true) and wake (false) from systemd-logind.
//
// Before sleeping, logind waits for holders of a "delay" inhibitor lock,
// so the daemon holds one and releases it once the session totals are
// saved; it takes a fresh one after waking. Release is called by the
// consumer when it has finished with a sleep event.
type PowerEvents struct {
	Events  chan bool
	conn    *dbus.Conn
	inhibit *os.File
}

func WatchPower() *PowerEvents {
	p := &PowerEvents{Events: make(chan bool, 4)}
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		core.Logf("WARN: no system bus (%v); sleep/wake will be noticed by the poll only", err)
		return p
	}
	p.conn = conn
	if err := conn.AddMatchSignal(
		dbus.WithMatchInterface("org.freedesktop.login1.Manager"),
		dbus.WithMatchMember("PrepareForSleep"),
	); err != nil {
		core.Logf("WARN: cannot watch sleep/wake (%v)", err)
		return p
	}
	p.takeInhibitor()
	signals := make(chan *dbus.Signal, 8)
	conn.Signal(signals)
	go func() {
		for s := range signals {
			if s.Name != "org.freedesktop.login1.Manager.PrepareForSleep" || len(s.Body) < 1 {
				continue
			}
			sleeping, _ := s.Body[0].(bool)
			if !sleeping {
				p.takeInhibitor()
			}
			p.Events <- sleeping
		}
	}()
	return p
}

func (p *PowerEvents) takeInhibitor() {
	if p.conn == nil || p.inhibit != nil {
		return
	}
	obj := p.conn.Object("org.freedesktop.login1", "/org/freedesktop/login1")
	var fd dbus.UnixFD
	err := obj.Call("org.freedesktop.login1.Manager.Inhibit", 0,
		"sleep", "VPN Kill Switch", "Saving session totals", "delay").Store(&fd)
	if err == nil {
		p.inhibit = os.NewFile(uintptr(fd), "inhibit")
	}
}

// Release lets a pending sleep go ahead.
func (p *PowerEvents) Release() {
	if p.inhibit != nil {
		p.inhibit.Close()
		p.inhibit = nil
	}
}

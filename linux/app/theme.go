package main

import (
	"github.com/godbus/dbus/v5"
)

// The desktop's light/dark preference, from the XDG settings portal
// (org.freedesktop.appearance color-scheme: 1 = prefer dark). WebKitGTK
// does not reliably report prefers-color-scheme, so "Auto" asks here and
// listens for changes.
func watchColorScheme(onChange func(dark bool)) (dark bool) {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return false
	}
	portal := conn.Object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop")

	read := func() (bool, bool) {
		var v dbus.Variant
		// ReadOne is the current call; Read (deprecated) wraps the value
		// in one more variant.
		if err := portal.Call("org.freedesktop.portal.Settings.ReadOne", 0,
			"org.freedesktop.appearance", "color-scheme").Store(&v); err == nil {
			return unwrapScheme(v)
		}
		if err := portal.Call("org.freedesktop.portal.Settings.Read", 0,
			"org.freedesktop.appearance", "color-scheme").Store(&v); err == nil {
			return unwrapScheme(v)
		}
		return false, false
	}
	dark, _ = read()

	_ = conn.AddMatchSignal(
		dbus.WithMatchInterface("org.freedesktop.portal.Settings"),
		dbus.WithMatchMember("SettingChanged"),
	)
	signals := make(chan *dbus.Signal, 8)
	conn.Signal(signals)
	go func() {
		for s := range signals {
			if len(s.Body) < 3 {
				continue
			}
			ns, _ := s.Body[0].(string)
			key, _ := s.Body[1].(string)
			if ns != "org.freedesktop.appearance" || key != "color-scheme" {
				continue
			}
			if v, ok := s.Body[2].(dbus.Variant); ok {
				if d, ok := unwrapScheme(v); ok {
					onChange(d)
				}
			}
		}
	}()
	return dark
}

func unwrapScheme(v dbus.Variant) (dark bool, ok bool) {
	for i := 0; i < 3; i++ {
		switch value := v.Value().(type) {
		case dbus.Variant:
			v = value
		case uint32:
			return value == 1, true
		default:
			return false, false
		}
	}
	return false, false
}

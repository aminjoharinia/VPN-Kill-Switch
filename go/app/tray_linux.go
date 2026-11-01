package main

import "github.com/godbus/dbus/v5"

// trayAvailable reports whether a panel is listening for tray items. On a
// desktop without one, hiding the window on close would leave the app
// running with no way back to it short of launching it again.
func trayAvailable() bool {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return false
	}
	var owned bool
	err = conn.BusObject().Call("org.freedesktop.DBus.NameHasOwner", 0, "org.kde.StatusNotifierWatcher").Store(&owned)
	return err == nil && owned
}

// trayImage is the icon as the tray takes it: a StatusNotifierItem takes
// the PNG as it is.
func trayImage(png []byte) []byte { return png }

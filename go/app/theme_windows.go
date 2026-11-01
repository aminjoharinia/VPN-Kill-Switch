package main

import (
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const personalizeKey = `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`

// The Windows light/dark preference for apps (AppsUseLightTheme: 0 means
// dark). "Auto" follows it, and changes are picked up as they happen.
func watchColorScheme(onChange func(dark bool)) (dark bool) {
	read := func() bool {
		k, err := registry.OpenKey(registry.CURRENT_USER, personalizeKey, registry.QUERY_VALUE)
		if err != nil {
			return false
		}
		defer k.Close()
		v, _, err := k.GetIntegerValue("AppsUseLightTheme")
		return err == nil && v == 0
	}
	dark = read()
	go func() {
		k, err := registry.OpenKey(registry.CURRENT_USER, personalizeKey, registry.NOTIFY)
		if err != nil {
			return
		}
		defer k.Close()
		last := dark
		for {
			// Blocks until a value under the key changes.
			if err := windows.RegNotifyChangeKeyValue(windows.Handle(k), false,
				windows.REG_NOTIFY_CHANGE_LAST_SET, 0, false); err != nil {
				return
			}
			if now := read(); now != last {
				last = now
				onChange(now)
			}
		}
	}()
	return dark
}

package main

import (
	"fmt"
	"image/color"
	"strings"
	"sync"

	"fyne.io/systray"
)

// tray is the panel item: state at a glance, plus turn on/off and "clear
// block" without opening the window — what you want from a kill switch
// day to day. On Linux it talks StatusNotifierItem over D-Bus, which
// Ubuntu's panel shows through its built-in AppIndicator extension; on
// Windows it is a notification-area icon.
type tray struct {
	app  *App
	mu   sync.Mutex
	last string

	title, line1, line2 *systray.MenuItem
	open, toggle, clear *systray.MenuItem
	quit                *systray.MenuItem
	icons               map[string][]byte
	end                 func()
	ready               bool
}

func startTray(app *App) *tray {
	t := &tray{app: app, icons: map[string][]byte{}}
	start, end := systray.RunWithExternalLoop(t.onReady, func() {})
	t.end = end
	start()
	return t
}

func (t *tray) stop() {
	if t.end != nil {
		t.end()
	}
}

func (t *tray) onReady() {
	systray.SetTitle("VPN Kill Switch")
	systray.SetTooltip("VPN Kill Switch")
	t.title = systray.AddMenuItem("Not Protected", "")
	t.title.Disable()
	t.line1 = systray.AddMenuItem("", "")
	t.line1.Disable()
	t.line2 = systray.AddMenuItem("", "")
	t.line2.Disable()
	systray.AddSeparator()
	t.open = systray.AddMenuItem("Open VPN Kill Switch", "")
	systray.AddSeparator()
	t.toggle = systray.AddMenuItem("Turn On Kill Switch", "")
	t.clear = systray.AddMenuItem("Clear Block Now", "")
	t.clear.Hide()
	systray.AddSeparator()
	t.quit = systray.AddMenuItem("Quit", "")

	go func() {
		for {
			select {
			case <-t.open.ClickedCh:
				t.app.ShowWindow()
			case <-t.toggle.ClickedCh:
				t.mu.Lock()
				running := strings.HasPrefix(t.last, "on|") || strings.HasPrefix(t.last, "starting|")
				t.mu.Unlock()
				if running {
					t.app.TurnOff()
				} else {
					t.app.TurnOn()
				}
			case <-t.clear.ClickedCh:
				t.app.UnblockNow()
			case <-t.quit.ClickedCh:
				systray.Quit()
				t.app.Quit()
				return
			}
		}
	}()
	t.mu.Lock()
	t.ready = true
	t.mu.Unlock()
}

var protectionTitle = map[string]string{
	"off": "Not Protected", "protected": "Protected", "blocked": "Traffic Blocked", "armed": "Always Armed",
}

func (t *tray) update(s Snapshot) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.ready {
		return
	}

	// Same colour language as the window: green protected, orange held or
	// changing, red unprotected, blue always-armed.
	var tone color.NRGBA
	word := ""
	busy := busyPower(s.Power)
	switch {
	case s.Power == powerOff:
		tone, word = toneDanger, "OFF"
	case busy:
		tone, word = toneCaution, strings.ToUpper(s.Power)
	case s.Protection == "blocked":
		tone, word = toneCaution, "CUT"
	case s.Protection == "armed":
		tone, word = toneArmed, "ARMED"
	default:
		tone, word = toneGood, "ON"
	}

	title := protectionTitle[s.Protection]
	if s.Protection == "blocked" && s.Status != nil && s.Status.Verifying() {
		title = "Verifying Tunnel"
	}
	line1, line2 := "", ""
	if s.DaemonRunning && s.Status != nil {
		app := s.Status.VPNAppName
		if app == "" {
			app = "VPN"
		}
		iface := s.Status.TunnelInterface
		if iface == "" {
			iface = "no tunnel"
		}
		line1 = fmt.Sprintf("%s %s · %s", app, s.Status.VPNState, iface)
		line2 = "Traffic flowing"
		if s.Status.Blocked {
			line2 = "Traffic blocked"
		}
	}
	blocked := s.Status != nil && s.Status.Blocked && s.DaemonRunning

	key := fmt.Sprintf("%s|%s|%v|%s|%s|%s|%v|%v|%v", s.Power, s.Protection, s.Prefs.TrayStripes, title, line1, line2, blocked, s.Installed, s.Busy)
	if key == t.last {
		return
	}
	t.last = key

	hollow := s.Power == powerOff
	iconKey := fmt.Sprintf("%v|%v|%v|%v", tone, busy, hollow, s.Prefs.TrayStripes)
	icon, ok := t.icons[iconKey]
	if !ok {
		icon = trayImage(trayIcon(tone, busy, hollow, s.Prefs.TrayStripes))
		t.icons[iconKey] = icon
	}
	systray.SetIcon(icon)
	systray.SetTooltip("VPN Kill Switch — " + word + " · " + title)

	t.title.SetTitle(title + "  (" + word + ")")
	setLine(t.line1, line1)
	setLine(t.line2, line2)

	if s.DaemonRunning || s.Power == powerStarting {
		t.toggle.SetTitle("Turn Off Kill Switch")
	} else {
		t.toggle.SetTitle("Turn On Kill Switch")
	}
	if busy || s.Busy || (!s.Installed && s.Power == powerOff) {
		t.toggle.Disable()
	} else {
		t.toggle.Enable()
	}
	if blocked {
		t.clear.Show()
	} else {
		t.clear.Hide()
	}
}

func setLine(item *systray.MenuItem, text string) {
	if text == "" {
		item.Hide()
		return
	}
	item.SetTitle(text)
	item.Show()
}

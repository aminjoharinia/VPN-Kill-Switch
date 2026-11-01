package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/runtime"

	"vpnks/internal/core"
)

// The daemon's lifecycle, distinct from whether the VPN is up. Turning it
// on starts a system service and waits for the first status publish, so
// there is a real interval to show rather than a button that seems dead.
const (
	powerOff      = "off"
	powerStarting = "starting"
	powerOn       = "on"
	powerStopping = "stopping"
)

func busyPower(p string) bool { return p == powerStarting || p == powerStopping }

// LiveBytes are the running session's totals, from the tunnel's counters.
type LiveBytes struct {
	Down uint64 `json:"down"`
	Up   uint64 `json:"up"`
}

// Snapshot is everything the window draws, sent whenever it changes.
type Snapshot struct {
	Status            *core.DaemonStatus `json:"status"`
	DaemonRunning     bool               `json:"daemonRunning"`
	Power             string             `json:"power"`
	Protection        string             `json:"protection"` // off | protected | blocked | armed
	Installed         bool               `json:"installed"`
	OutOfDate         bool               `json:"outOfDate"`
	DaemonVersionText string             `json:"daemonVersionText"`
	AppVersion        string             `json:"appVersion"`
	Version           string             `json:"version"`
	Busy              bool               `json:"busy"`
	LastError         string             `json:"lastError"`
	Logs              []string           `json:"logs"`
	Sessions          []core.Session     `json:"sessions"`
	Endpoints         []core.Endpoint    `json:"endpoints"`
	Prefs             Prefs              `json:"prefs"`
	SystemDark        bool               `json:"systemDark"`
	CLIPath           string             `json:"cliPath"`
	TableName         string             `json:"tableName"`
	Platform          PlatformText       `json:"platform"`
}

type App struct {
	ctx context.Context
	mu  sync.Mutex

	status        *core.DaemonStatus
	logs          []string
	sessions      []core.Session
	endpoints     []core.Endpoint
	busy          bool
	lastError     string
	power         string
	live          *LiveBytes
	daemonRunning bool
	prefs         Prefs
	systemDark    bool

	// A transition gives up after 25 s so a failed start cannot leave the
	// button spinning forever. transitionFromPID is the daemon that was
	// running when a start began: Update reinstalls over a live daemon,
	// and its old "up" status must not end Starting before the new one runs.
	transitionStarted time.Time
	transitionFromPID int

	stamps   map[string]stamp
	quitting bool
	lastSent string
	lastLive string
	tray     *tray
}

type stamp struct {
	mod  time.Time
	size int64
}

func NewApp() *App {
	return &App{power: powerOff, stamps: map[string]stamp{}, prefs: loadPrefs()}
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.systemDark = watchColorScheme(func(dark bool) {
		a.mu.Lock()
		a.systemDark = dark
		a.mu.Unlock()
		a.push()
	})
	a.tray = startTray(a)
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			a.refresh()
			a.push()
			<-ticker.C
		}
	}()
}

func (a *App) shutdown(ctx context.Context) {
	if a.tray != nil {
		a.tray.stop()
	}
}

// beforeClose hides the window instead of closing it while a tray item
// can bring it back; without a tray, closing quits as usual.
func (a *App) beforeClose(ctx context.Context) (prevent bool) {
	if a.quitting || !trayAvailable() {
		return false
	}
	runtime.WindowHide(ctx)
	return true
}

func (a *App) onSecondInstance(_ options.SecondInstanceData) { a.ShowWindow() }

// ShowWindow brings the window back from the tray.
func (a *App) ShowWindow() {
	if a.ctx == nil {
		return
	}
	runtime.WindowShow(a.ctx)
	runtime.WindowUnminimise(a.ctx)
}

func (a *App) Quit() {
	a.quitting = true
	runtime.Quit(a.ctx)
}

// MARK: Polling

func (a *App) changed(path string) bool {
	var s stamp
	if info, err := os.Stat(path); err == nil {
		s = stamp{info.ModTime(), info.Size()}
	}
	if old, ok := a.stamps[path]; ok && old == s {
		return false
	}
	a.stamps[path] = s
	return true
}

// refresh re-reads only the files whose stamp moved: a stat, not a read,
// on every tick.
func (a *App) refresh() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.changed(core.StatusFile) {
		s, err := core.ReadStatus()
		if err != nil {
			s = nil
		}
		a.status = s
	}
	if a.changed(core.LogFile) {
		a.logs = recentLog(200)
	}
	if a.changed(core.SessionsFile) {
		a.sessions = core.LoadSessions()
	}
	if a.changed(core.EndpointsFile) {
		a.endpoints = core.LoadEndpoints()
	}
	a.daemonRunning = a.status != nil && a.status.Running && core.IsDaemonProcess(a.status.PID)
	a.updatePower()
	a.updateLive()
}

func (a *App) updatePower() {
	running := a.daemonRunning
	switch a.power {
	case powerStarting:
		if running && a.status.PID != a.transitionFromPID {
			a.power, a.transitionStarted, a.transitionFromPID = powerOn, time.Time{}, 0
		} else if !a.busy && !a.transitionStarted.IsZero() && time.Since(a.transitionStarted) > 25*time.Second {
			a.endTransition()
			a.lastError = a.startFailureMessage(running)
		}
	case powerStopping:
		if !running {
			a.power, a.transitionStarted = powerOff, time.Time{}
		} else if !a.busy && !a.transitionStarted.IsZero() && time.Since(a.transitionStarted) > 25*time.Second {
			a.endTransition()
			a.lastError = "The kill switch did not stop. Check Activity, or run it by hand:\n\n    " + asAdmin(core.InstalledBinary, "uninstall")
		}
	default:
		if running {
			a.power = powerOn
		} else {
			a.power = powerOff
		}
	}
}

func (a *App) endTransition() {
	a.transitionStarted, a.transitionFromPID = time.Time{}, 0
	if a.daemonRunning {
		a.power = powerOn
	} else {
		a.power = powerOff
	}
}

func (a *App) startFailureMessage(oldStillRunning bool) string {
	cli := resolvedCLI()
	if cli == "" {
		cli = core.PackagedBinary
	}
	if oldStillRunning {
		return "The kill switch kept running the previous daemon; the new one did not take over.\n\nCheck Activity, or reinstall by hand:\n\n    " + asAdmin(cli, "install")
	}
	if _, err := os.Stat(core.StatusFile); err == nil && a.status == nil {
		return "The daemon is running but this app cannot read its status.\n\nThat usually means the installed daemon is older than this app. Rebuild both and try again:\n\n    " + platform.BuildCommand
	}
	return "The daemon did not start.\n\n" + serviceLogHint
}

func (a *App) protection() string {
	if !a.daemonRunning || a.status == nil {
		return "off"
	}
	if a.status.AlwaysArmed {
		return "armed"
	}
	if a.status.Blocked {
		return "blocked"
	}
	return "protected"
}

func (a *App) updateLive() {
	s := a.status
	if !a.daemonRunning || s == nil || s.SessionStartedAt == nil || s.TunnelInterface == "" {
		a.live = nil
		return
	}
	cur, ok := core.InterfaceCounters(s.TunnelInterface)
	if !ok {
		a.live = &LiveBytes{Down: s.SessionBytesIn, Up: s.SessionBytesOut}
		return
	}
	// A counter below its base means the interface was recreated and
	// restarted from zero since the daemon last published.
	down, up := cur.BytesIn, cur.BytesOut
	if down >= s.SessionBaseIn {
		down -= s.SessionBaseIn
	}
	if up >= s.SessionBaseOut {
		up -= s.SessionBaseOut
	}
	a.live = &LiveBytes{Down: s.SessionCarriedIn + down, Up: s.SessionCarriedOut + up}
}

func (a *App) snapshotLocked() Snapshot {
	daemonText := "not running"
	if a.daemonRunning && a.status != nil {
		daemonText = a.status.DaemonVersion
	}
	var status *core.DaemonStatus
	if a.status != nil {
		copy := *a.status
		status = &copy
	}
	cli := resolvedCLI()
	return Snapshot{
		Status:            status,
		DaemonRunning:     a.daemonRunning,
		Power:             a.power,
		Protection:        a.protection(),
		Installed:         cli != "",
		OutOfDate:         a.daemonRunning && a.status != nil && a.status.DaemonVersion != core.FullVersion(),
		DaemonVersionText: daemonText,
		AppVersion:        core.FullVersion(),
		Version:           core.Version,
		Busy:              a.busy,
		LastError:         a.lastError,
		Logs:              nonNil(a.logs),
		Sessions:          nonNilSessions(a.sessions),
		Endpoints:         nonNilEndpoints(a.endpoints),
		Prefs:             a.prefs,
		SystemDark:        a.systemDark,
		CLIPath:           cli,
		TableName:         core.TableName,
		Platform:          platform,
	}
}

// push sends the snapshot to the window only when it changed, and the
// live byte counts separately (they move every second while connected).
func (a *App) push() {
	a.mu.Lock()
	snap := a.snapshotLocked()
	live := a.live
	a.mu.Unlock()

	if a.tray != nil {
		a.tray.update(snap)
	}
	if a.ctx == nil {
		return
	}
	data, _ := json.Marshal(snap)
	if string(data) != a.lastSent {
		a.lastSent = string(data)
		runtime.EventsEmit(a.ctx, "snapshot", snap)
	}
	liveData, _ := json.Marshal(live)
	if string(liveData) != a.lastLive {
		a.lastLive = string(liveData)
		runtime.EventsEmit(a.ctx, "live", live)
	}
}

// MARK: Bound to the window

// State is the first full snapshot, asked for when the page loads.
func (a *App) State() map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	return map[string]any{"snapshot": a.snapshotLocked(), "live": a.live}
}

func (a *App) TurnOn() {
	a.mu.Lock()
	a.power = powerStarting
	a.transitionStarted = time.Now()
	a.transitionFromPID = 0
	if a.daemonRunning && a.status != nil {
		a.transitionFromPID = a.status.PID
	}
	a.mu.Unlock()
	a.perform([]string{"install", "--no-wait"}, a.endTransitionUnlessDone)
}

func (a *App) TurnOff() {
	a.mu.Lock()
	a.power = powerStopping
	a.transitionStarted = time.Now()
	a.mu.Unlock()
	a.perform([]string{"uninstall"}, a.endTransitionUnlessDone)
}

// UpdateDaemon reinstalls the bundled daemon over the running one.
func (a *App) UpdateDaemon() { a.TurnOn() }

func (a *App) UnblockNow() { a.perform([]string{"unblock"}, nil) }

func (a *App) DismissError() {
	a.mu.Lock()
	a.lastError = ""
	a.mu.Unlock()
	a.push()
}

func (a *App) SetAppearance(mode string) {
	a.mu.Lock()
	switch mode {
	case "auto", "light", "dark":
		a.prefs.Appearance = mode
	}
	a.prefs.save()
	a.mu.Unlock()
	a.push()
}

func (a *App) SetTrayStripes(on bool) {
	a.mu.Lock()
	a.prefs.TrayStripes = on
	a.prefs.save()
	a.mu.Unlock()
	a.push()
}

// Set changes a daemon setting. Most live only in config.json, which the
// daemon leaves writable to admins and re-reads within a second, so a
// toggle needs no password. autostart changes how the system service
// starts, which does.
func (a *App) Set(key, value string) {
	if key == "autostart" || !writeConfigDirectly(key, value) {
		a.perform([]string{"set", key, value}, nil)
		return
	}
	a.refresh()
	a.push()
}

func writeConfigDirectly(key, value string) bool {
	data, err := os.ReadFile(core.ConfigFile)
	if err != nil {
		return false
	}
	var object map[string]any
	if json.Unmarshal(data, &object) != nil {
		return false
	}
	switch {
	case value == "0" || value == "1":
		object[key] = value == "1"
	default:
		if n, err := strconv.ParseFloat(value, 64); err == nil {
			object[key] = n
		} else {
			object[key] = value
		}
	}
	encoded, err := json.MarshalIndent(object, "", "  ")
	if err != nil {
		return false
	}
	return core.WriteInPlace(core.ConfigFile, append(encoded, '\n')) == nil
}

// MARK: Exceptions — written straight to the store, which the daemon
// watches. Falls back to the privileged CLI if the file is not writable.

func (a *App) AddException(ip string) string {
	ip = strings.TrimSpace(ip)
	if !core.IsValidIPv4(ip) {
		return "Not a valid IPv4 address."
	}
	all := core.LoadEndpoints()
	found := false
	for i := range all {
		if all[i].IP == ip {
			all[i].Pinned, found = true, true
		}
	}
	if !found {
		all = append(all, core.Endpoint{IP: ip, LastSeen: time.Now(), Hits: 1, Pinned: true})
	}
	if core.SaveEndpointsInPlace(all) == nil {
		a.reloadEndpoints()
		return ""
	}
	a.perform([]string{"pin", "add", ip}, nil)
	return ""
}

func (a *App) RemoveException(ip string) {
	all := core.LoadEndpoints()
	kept := all[:0]
	for _, e := range all {
		if e.IP != ip {
			kept = append(kept, e)
		}
	}
	if core.SaveEndpointsInPlace(kept) == nil {
		a.reloadEndpoints()
		return
	}
	a.perform([]string{"pin", "remove", ip}, nil)
}

func (a *App) SetPinned(ip string, pinned bool) {
	all := core.LoadEndpoints()
	for i := range all {
		if all[i].IP == ip {
			all[i].Pinned = pinned
			if core.SaveEndpointsInPlace(all) == nil {
				a.reloadEndpoints()
				return
			}
			verb := "unpin"
			if pinned {
				verb = "keep"
			}
			a.perform([]string{"pin", verb, ip}, nil)
			return
		}
	}
}

func (a *App) reloadEndpoints() {
	a.mu.Lock()
	delete(a.stamps, core.EndpointsFile)
	a.mu.Unlock()
	a.refresh()
	a.push()
}

// MARK: Privileged actions

// perform runs the CLI as an administrator after a polkit or UAC prompt,
// off the UI thread so the window stays live while the dialog is open.
func (a *App) perform(args []string, then func(outcome)) {
	a.mu.Lock()
	a.busy = true
	a.lastError = ""
	a.mu.Unlock()
	a.push()

	go func() {
		cli := resolvedCLI()
		result, message := failed, core.CLIName+" was not found next to the app. "+platform.BuildLead+"\n\n    "+platform.BuildCommand
		if cli != "" {
			result, message = runPrivileged(cli, args...)
		}
		a.mu.Lock()
		a.busy = false
		if result == failed {
			if message == "" {
				message = "Command failed."
			}
			a.lastError = message
		}
		a.stamps = map[string]stamp{}
		a.mu.Unlock()
		if then != nil {
			then(result)
		}
		a.refresh()
		a.push()
	}()
}

// endTransitionUnlessDone: a cancelled or failed prompt changed nothing, so
// go straight back to the state before the click. On success the 25 s
// allowance starts now — time spent typing a password is not time the
// daemon took to start.
func (a *App) endTransitionUnlessDone(o outcome) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if o == done {
		if busyPower(a.power) {
			a.transitionStarted = time.Now()
		}
		return
	}
	a.endTransition()
}

// MARK: Log

// recentLog is the newest lines, newest first. A new file starts each
// month, so early in a month it is topped up from the latest archive.
func recentLog(lines int) []string {
	result := tail(core.LogFile, lines)
	if len(result) < lines {
		if archive := newestLogArchive(); archive != "" {
			result = append(result, tail(archive, lines-len(result))...)
		}
	}
	return result
}

func newestLogArchive() string {
	dir := filepath.Dir(core.LogFile)
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "kill_switch-") && strings.HasSuffix(e.Name(), ".log") {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		return ""
	}
	// yyyy-MM, then -2, -3 for early size rotations.
	sort.Slice(names, func(i, j int) bool { return archiveKey(names[i]) < archiveKey(names[j]) })
	return filepath.Join(dir, names[len(names)-1])
}

func archiveKey(name string) string {
	rest := strings.TrimSuffix(strings.TrimPrefix(name, "kill_switch-"), ".log")
	month, n := rest, 1
	if len(rest) > 7 {
		month = rest[:7]
		n, _ = strconv.Atoi(strings.TrimPrefix(rest[7:], "-"))
	}
	return fmt.Sprintf("%s-%04d", month, n)
}

// tail reads only the last 64 KB: the log is capped at 5 MB, and reading
// all of it every second is what made the macOS app sluggish once.
func tail(path string, lines int) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	const window = 64 * 1024
	info, err := f.Stat()
	if err != nil {
		return nil
	}
	start := int64(0)
	if info.Size() > window {
		start = info.Size() - window
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return nil
	}
	data, _ := io.ReadAll(f)
	text := string(data)
	if start > 0 {
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			text = text[i+1:]
		}
	}
	var all []string
	for _, l := range strings.Split(text, "\n") {
		if l != "" {
			all = append(all, l)
		}
	}
	if len(all) > lines {
		all = all[len(all)-lines:]
	}
	for i, j := 0, len(all)-1; i < j; i, j = i+1, j-1 {
		all[i], all[j] = all[j], all[i]
	}
	return all
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func nonNilSessions(s []core.Session) []core.Session {
	if s == nil {
		return []core.Session{}
	}
	return s
}

func nonNilEndpoints(s []core.Endpoint) []core.Endpoint {
	if s == nil {
		return []core.Endpoint{}
	}
	return s
}

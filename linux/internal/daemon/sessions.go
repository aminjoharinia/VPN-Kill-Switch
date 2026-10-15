package daemon

import (
	"crypto/rand"
	"fmt"
	"time"

	"vpnks/internal/core"
)

// SessionTracker keeps the running session and turns raw interface
// counters into per-session totals.
type SessionTracker struct {
	sessions    []core.Session
	baseline    *core.Counters
	lastSeen    *core.Counters
	carriedIn   uint64 // carried forward when the kernel counter resets
	carriedOut  uint64
	lastPersist time.Time
}

// Crash insurance only: live totals reach the app through status.json's
// counter baseline, so history is not rewritten every few seconds.
const persistInterval = 30 * time.Minute

func NewSessionTracker() *SessionTracker {
	t := &SessionTracker{sessions: core.LoadSessions(), lastPersist: time.Now()}
	// A session left open by a previous run cannot be resumed: its
	// counters are gone. Close it at its last known totals.
	for i := range t.sessions {
		if t.sessions[i].IsActive() {
			end := t.sessions[i].StartedAt.Add(t.sessions[i].Duration())
			t.sessions[i].EndedAt = &end
			core.SaveSessions(t.sessions)
			break
		}
	}
	return t
}

func (t *SessionTracker) activeIndex() int {
	for i := range t.sessions {
		if t.sessions[i].IsActive() {
			return i
		}
	}
	return -1
}

func (t *SessionTracker) Active() *core.Session {
	if i := t.activeIndex(); i >= 0 {
		s := t.sessions[i]
		return &s
	}
	return nil
}

// CounterState: live totals = carried + (interface counter now − base).
func (t *SessionTracker) CounterState() (baseIn, baseOut, carriedIn, carriedOut uint64) {
	if t.activeIndex() < 0 || t.baseline == nil {
		return 0, 0, 0, 0
	}
	return t.baseline.BytesIn, t.baseline.BytesOut, t.carriedIn, t.carriedOut
}

// PersistNow saves the active session's totals — before sleep and on
// shutdown, where waiting for the 30-minute save would lose them.
func (t *SessionTracker) PersistNow() {
	if t.activeIndex() < 0 {
		return
	}
	t.Sample()
	t.lastPersist = time.Now()
	core.SaveSessions(t.sessions)
}

func (t *SessionTracker) Begin(iface, appName string) {
	t.End()
	if c, ok := core.InterfaceCounters(iface); ok {
		t.baseline, t.lastSeen = &c, &c
	} else {
		t.baseline, t.lastSeen = nil, nil
	}
	t.carriedIn, t.carriedOut = 0, 0
	s := core.Session{ID: newID(), StartedAt: time.Now(), InterfaceName: iface, VPNAppName: appName}
	t.sessions = append([]core.Session{s}, t.sessions...)
	core.SaveSessions(t.sessions)
}

func (t *SessionTracker) End() {
	i := t.activeIndex()
	if i < 0 {
		return
	}
	t.Sample()
	now := time.Now()
	t.sessions[i].EndedAt = &now
	t.baseline, t.lastSeen = nil, nil
	core.SaveSessions(t.sessions)
}

func (t *SessionTracker) NoteBlock() {
	if i := t.activeIndex(); i >= 0 {
		t.sessions[i].BlockCount++
	}
}

// Sample updates the active session's totals from the live counters.
func (t *SessionTracker) Sample() {
	i := t.activeIndex()
	if i < 0 {
		return
	}
	now, ok := core.InterfaceCounters(t.sessions[i].InterfaceName)
	if !ok {
		return
	}
	if t.baseline == nil {
		t.baseline, t.lastSeen = &now, &now
		return
	}
	base := *t.baseline
	// A tunnel recreated under the same name restarts its counters at
	// zero. Bank what we had and rebase, or the delta would wrap into an
	// enormous number.
	if prev := t.lastSeen; prev != nil && (now.BytesIn < prev.BytesIn || now.BytesOut < prev.BytesOut) {
		t.carriedIn += prev.BytesIn - base.BytesIn
		t.carriedOut += prev.BytesOut - base.BytesOut
		base = core.Counters{}
		t.baseline = &base
	}
	t.lastSeen = &now
	t.sessions[i].BytesIn = t.carriedIn + (now.BytesIn - base.BytesIn)
	t.sessions[i].BytesOut = t.carriedOut + (now.BytesOut - base.BytesOut)

	if time.Since(t.lastPersist) >= persistInterval {
		t.lastPersist = time.Now()
		core.SaveSessions(t.sessions)
	}
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return fmt.Sprintf("%X-%X-%X-%X-%X", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

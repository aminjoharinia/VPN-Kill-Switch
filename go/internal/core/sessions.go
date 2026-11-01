package core

import (
	"encoding/json"
	"os"
	"time"
)

// Session is one continuous period during which the VPN was up on a tunnel.
type Session struct {
	ID            string     `json:"id"`
	StartedAt     time.Time  `json:"startedAt"`
	EndedAt       *time.Time `json:"endedAt,omitempty"`
	InterfaceName string     `json:"interfaceName"`
	VPNAppName    string     `json:"vpnAppName"`
	BytesIn       uint64     `json:"bytesIn"`
	BytesOut      uint64     `json:"bytesOut"`
	// Times traffic was cut while this session was open.
	BlockCount int `json:"blockCount"`
}

func (s Session) IsActive() bool { return s.EndedAt == nil }

func (s Session) Duration() time.Duration {
	end := time.Now()
	if s.EndedAt != nil {
		end = *s.EndedAt
	}
	return end.Sub(s.StartedAt)
}

const MaxSessions = 200

// LoadSessions returns the history, newest first.
func LoadSessions() []Session {
	data, err := os.ReadFile(SessionsFile)
	if err != nil {
		return nil
	}
	var sessions []Session
	if json.Unmarshal(data, &sessions) != nil {
		return nil
	}
	return sessions
}

// SaveSessions is called when a session starts or ends, before sleep, on
// shutdown and otherwise every 30 minutes — never every few seconds.
func SaveSessions(sessions []Session) {
	if len(sessions) > MaxSessions {
		sessions = sessions[:MaxSessions]
	}
	data, err := json.MarshalIndent(sessions, "", "  ")
	if err != nil {
		return
	}
	_ = WriteAtomic(SessionsFile, data, 0o644)
}

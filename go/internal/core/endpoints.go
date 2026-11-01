package core

import (
	"encoding/json"
	"net"
	"os"
	"sort"
	"time"
)

// Endpoint is one address allowed out through the block so the VPN client
// can reach its server and reconnect.
type Endpoint struct {
	IP       string    `json:"ip"`
	LastSeen time.Time `json:"lastSeen"`
	Hits     int       `json:"hits"`
	// Pinned addresses are never aged out or crowded out by newer ones.
	Pinned bool `json:"pinned"`
}

const (
	// How long an unseen address is kept before being forgotten.
	EndpointRetention = 14 * 24 * time.Hour
	// Cap on automatically learned addresses in the rules. Pinned are extra.
	MaxLearnedEndpoints = 16
	// How stale lastSeen may get before an observation is worth a write.
	EndpointRefreshAfter = time.Hour
)

func LoadEndpoints() []Endpoint {
	data, err := os.ReadFile(EndpointsFile)
	if err != nil {
		return nil
	}
	var all []Endpoint
	if json.Unmarshal(data, &all) != nil {
		return nil
	}
	return all
}

func encodeEndpoints(all []Endpoint) []byte {
	if all == nil {
		all = []Endpoint{}
	}
	data, _ := json.MarshalIndent(all, "", "  ")
	return data
}

// SaveEndpoints is the daemon's write: it creates the file when needed and
// leaves it root:<admins> 0664 so the app can edit it without a prompt.
func SaveEndpoints(all []Endpoint) {
	data := encodeEndpoints(all)
	if _, err := os.Stat(EndpointsFile); err == nil {
		if WriteInPlace(EndpointsFile, data) != nil {
			return
		}
	} else if os.WriteFile(EndpointsFile, data, 0o664) != nil {
		return
	}
	ShareWithAdmins(EndpointsFile)
}

// SaveEndpointsInPlace is the app's write. It fails (and the app falls
// back to the privileged CLI) when the file is missing or not writable.
func SaveEndpointsInPlace(all []Endpoint) error {
	return WriteInPlace(EndpointsFile, encodeEndpoints(all))
}

func newerFirst(list []Endpoint) {
	sort.SliceStable(list, func(i, j int) bool {
		if !list[i].LastSeen.Equal(list[j].LastSeen) {
			return list[i].LastSeen.After(list[j].LastSeen)
		}
		return list[i].Hits > list[j].Hits
	})
}

// AllowList is every pinned address plus the most RECENTLY seen learned
// ones. Ranking by lifetime hits let servers from weeks ago hold every slot
// while the one the VPN moved to yesterday could never get in.
func AllowList() []string { return AllowListOf(LoadEndpoints()) }

func AllowListOf(all []Endpoint) []string {
	set := map[string]bool{}
	var learned []Endpoint
	for _, e := range all {
		if e.Pinned {
			set[e.IP] = true
		} else {
			learned = append(learned, e)
		}
	}
	newerFirst(learned)
	for i, e := range learned {
		if i >= MaxLearnedEndpoints {
			break
		}
		set[e.IP] = true
	}
	out := make([]string, 0, len(set))
	for ip := range set {
		out = append(out, ip)
	}
	sort.Strings(out)
	return out
}

func AddEndpoint(ip string, pinned bool) bool {
	if !IsValidIPv4(ip) {
		return false
	}
	all := LoadEndpoints()
	found := false
	for i := range all {
		if all[i].IP == ip {
			all[i].Pinned = all[i].Pinned || pinned
			all[i].LastSeen = time.Now()
			found = true
		}
	}
	if !found {
		all = append(all, Endpoint{IP: ip, LastSeen: time.Now(), Hits: 1, Pinned: pinned})
	}
	SaveEndpoints(all)
	return true
}

func RemoveEndpoint(ip string) {
	all := LoadEndpoints()
	kept := all[:0]
	for _, e := range all {
		if e.IP != ip {
			kept = append(kept, e)
		}
	}
	SaveEndpoints(kept)
}

func SetEndpointPinned(ip string, pinned bool) {
	all := LoadEndpoints()
	for i := range all {
		if all[i].IP == ip {
			all[i].Pinned = pinned
			SaveEndpoints(all)
			return
		}
	}
}

// MergeEndpoints folds fresh observations into the store: existing entries
// are refreshed, unseen ones kept until they age out, pinned ones never
// touched. It writes only when something that matters changed.
func MergeEndpoints(observed map[string]int) {
	all := LoadEndpoints()
	now := time.Now()
	changed := false

	for ip, hits := range observed {
		if !IsValidIPv4(ip) {
			continue
		}
		found := false
		for i := range all {
			if all[i].IP != ip {
				continue
			}
			found = true
			if now.Sub(all[i].LastSeen) >= EndpointRefreshAfter {
				all[i].Hits += hits
				all[i].LastSeen = now
				changed = true
			}
		}
		if !found {
			all = append(all, Endpoint{IP: ip, LastSeen: now, Hits: hits})
			changed = true
		}
	}

	var pinned, learned []Endpoint
	for _, e := range all {
		switch {
		case e.Pinned:
			pinned = append(pinned, e)
		case now.Sub(e.LastSeen) < EndpointRetention:
			learned = append(learned, e)
		default:
			changed = true // aged out
		}
	}
	newerFirst(learned)
	if len(learned) > MaxLearnedEndpoints*2 {
		learned = learned[:MaxLearnedEndpoints*2]
		changed = true
	}
	if changed {
		SaveEndpoints(append(pinned, learned...))
	}
}

func IsValidIPv4(ip string) bool {
	parsed := net.ParseIP(ip)
	return parsed != nil && parsed.To4() != nil && !containsColon(ip)
}

func containsColon(s string) bool {
	for _, c := range s {
		if c == ':' {
			return true
		}
	}
	return false
}

// IsPrivate covers everything that is never a VPN server on the internet:
// unspecified, private, loopback, link-local, multicast and above.
func IsPrivate(ip string) bool {
	p := net.ParseIP(ip).To4()
	if p == nil {
		return true
	}
	switch {
	case p[0] == 0, p[0] == 10, p[0] == 127:
		return true
	case p[0] == 169 && p[1] == 254:
		return true
	case p[0] == 192 && p[1] == 168:
		return true
	case p[0] == 172 && p[1] >= 16 && p[1] <= 31:
		return true
	case p[0] >= 224:
		return true
	}
	return false
}

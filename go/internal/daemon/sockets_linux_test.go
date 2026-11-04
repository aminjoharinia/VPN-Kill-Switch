package daemon

import "testing"

func TestParseProcAddress(t *testing.T) {
	cases := []struct {
		field string
		ip    string
		port  int
		ok    bool
	}{
		{"0100007F:0035", "127.0.0.1", 53, true},
		{"0101A8C0:01BB", "192.168.1.1", 443, true},
		{"0000000000000000FFFF00000A7100CB:20FB", "203.0.113.10", 8443, true}, // IPv4-mapped
		{"00000000000000000000000001000000:01BB", "", 0, false},                  // ::1
		{"zz:01BB", "", 0, false},
	}
	for _, c := range cases {
		ip, port, ok := parseProcAddress(c.field)
		if ip != c.ip || port != c.port || ok != c.ok {
			t.Errorf("parseProcAddress(%q) = %q %d %v, want %q %d %v", c.field, ip, port, ok, c.ip, c.port, c.ok)
		}
	}
}

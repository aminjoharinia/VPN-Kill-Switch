package core

// Stamped by build.sh through -ldflags, for the daemon and the app in the
// same run, so the app can tell when the running daemon is a different build.
var (
	Version = "dev"
	Number  = "0"
)

// FullVersion is "26.10.15+142233", the form status.json carries.
func FullVersion() string { return Version + "+" + Number }

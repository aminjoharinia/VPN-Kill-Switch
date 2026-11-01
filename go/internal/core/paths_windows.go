package core

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

func envDir(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

var (
	// State lives under ProgramData, readable by every user and writable
	// only by the daemon (LocalSystem) — and, for config.json and
	// endpoints.json, by the user who installed it (see ShareWithAdmins).
	StateDir      = filepath.Join(envDir("ProgramData", `C:\ProgramData`), "VPN Kill Switch")
	ConfigFile    = filepath.Join(StateDir, "config.json")
	StatusFile    = filepath.Join(StateDir, "status.json")
	LogFile       = filepath.Join(StateDir, "kill_switch.log")
	SessionsFile  = filepath.Join(StateDir, "sessions.json")
	EndpointsFile = filepath.Join(StateDir, "endpoints.json")
	// The user SID that may edit settings without a UAC prompt, recorded
	// at install.
	OwnerFile = filepath.Join(StateDir, "owner.sid")

	// Where the installer puts the app and the copy of vpnks that ships
	// with it.
	PackagedDir    = filepath.Join(envDir("ProgramFiles", `C:\Program Files`), "VPN Kill Switch")
	PackagedBinary = filepath.Join(PackagedDir, CLIName)
	// The daemon runs from its own copy, so installing a newer app never
	// swaps the binary under a running daemon (same split as macOS and
	// Linux). Under Program Files, so only administrators can change it.
	InstallDir      = filepath.Join(PackagedDir, "Daemon")
	InstalledBinary = filepath.Join(InstallDir, CLIName)
)

const (
	CLIName     = "vpnks.exe"
	ServiceName = "VPNKillSwitch"
	// The name on the WFP provider and sublayer that hold every filter this
	// project adds — the Windows counterpart of the pf anchor and the
	// nftables table. Other software's filters are never touched.
	TableName = "VPN Kill Switch"
)

// IsAdmin reports whether this process may change the firewall: an
// elevated administrator, or the service running as LocalSystem.
func IsAdmin() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}

// The state directory's access: full control for LocalSystem and
// Administrators, read and list for everyone else. Protected (P), so nothing is
// inherited from ProgramData — which lets any user create files.
const stateDirSDDL = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)"

// SecureStateDir creates the state directory with its access rules and
// records which user may edit the settings: the one running the install,
// elevated through UAC, whose token still names them. An administrator's
// everyday (non-elevated) token has the Administrators group disabled, so
// a grant to that group would not reach the app.
func SecureStateDir() error {
	if err := os.MkdirAll(StateDir, 0o755); err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString(stateDirSDDL)
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	if err := windows.SetNamedSecurityInfo(StateDir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, dacl, nil); err != nil {
		return err
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	sid := user.User.Sid.String()
	// LocalSystem needs no grant: it is the daemon.
	if sid == "S-1-5-18" {
		return nil
	}
	return os.WriteFile(OwnerFile, []byte(sid+"\n"), 0o644)
}

func settingsOwner() string {
	data, err := os.ReadFile(OwnerFile)
	if err != nil {
		return ""
	}
	sid := strings.TrimSpace(string(data))
	if _, err := windows.StringToSid(sid); err != nil {
		return ""
	}
	return sid
}

// ShareWithAdmins lets the user who installed the kill switch modify a
// daemon-owned file, so the app can toggle a setting with a plain file
// write instead of a UAC prompt each time — the Windows form of Linux's
// root:<admin group> 0664. Starting, stopping and clearing a block still
// need an elevated administrator.
func ShareWithAdmins(path string) {
	sid := settingsOwner()
	if sid == "" {
		return
	}
	// Modify, without the rights to change ownership or permissions. The
	// DACL is left unprotected, so the directory's rules still apply.
	sd, err := windows.SecurityDescriptorFromString("D:(A;;0x1301bf;;;" + sid + ")")
	if err != nil {
		return
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return
	}
	_ = windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.UNPROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, dacl, nil)
}

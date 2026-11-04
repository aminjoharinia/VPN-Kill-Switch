# VPN Kill Switch for Windows

The Windows version of the kill switch: it cuts your internet the moment
your VPN stops carrying traffic, and lets it back once the tunnel works
again. Same behaviour, settings and look as the macOS and Linux apps, built
from the same Go code as the Linux version.

It works with any VPN that creates a network adapter: WireGuard, OpenVPN
(TAP or DCO), sing-box, Xray and v2rayN, Clash/Mihomo, Hiddify, Happ, the
built-in Windows VPN, and similar clients.

| Part | What it is | Linux counterpart |
|---|---|---|
| **`vpnks.exe` daemon** | A Windows service (LocalSystem) that watches the tunnel and drives the Windows Filtering Platform. This is what protects you. | `vpnks` (nftables, systemd) |
| **VPN Kill Switch app** | The window and the notification-area icon (Go + [Wails](https://wails.io) on WebView2, in the same *Daftar* design). It only displays state and asks the daemon to change it. | the same app |

Quitting the app never drops your protection. Only **Turn OFF** (or
`vpnks uninstall`) stops the kill switch.

---

## Requirements

- Windows 10 or 11, 64-bit: x64 or ARM. (Tested on Windows 11 ARM.)
- The WebView2 runtime, which Windows 11 and up-to-date Windows 10 already
  have.
- An administrator account. Turning the switch on and off changes the
  firewall, so Windows asks for permission (UAC) each time.

## Build

The Windows version is built on Windows. Install Go 1.26 or later, and optionally NSIS to get an installer too:

```
winget install GoLang.Go
winget install NSIS.NSIS
```

Then, in a new terminal in the project folder:

```
build.cmd
```

It builds for this PC's architecture into `output\windows\`, then offers
to run the installer. `build.cmd arm64` picks the architecture,
`build.cmd -Yes` installs without asking, and `build.cmd -NoInstall` only
builds. The work is done by [`build.ps1`](build.ps1); `build.cmd` runs it
past PowerShell's script policy.

It writes to `output\windows\`:

| File | What it is |
|---|---|
| `VPN-Kill-Switch-<version>-windows-<arch>-setup.exe` | The installer. Built only if NSIS is installed. |
| `VPN-Kill-Switch-<version>-windows-<arch>-portable.zip` | The two programs. Unzip anywhere and open `vpn-kill-switch.exe`; no installer needed. |

Most PCs are `amd64`; Windows on ARM laptops, and Windows in Parallels or
UTM on an Apple Silicon Mac, are `arm64`.

## Install

Run the installer. It puts the app in `C:\Program Files\VPN Kill Switch`
and adds it to the Start menu. Or run `vpn-kill-switch.exe` straight from
the unzipped folder: the first **Turn ON** installs the daemon either way.

Windows SmartScreen may warn about an unknown publisher, because the
programs are not code-signed. Choose **More info → Run anyway**.

---

## Using the app

1. **Open VPN Kill Switch** from the Start menu.
2. **Press Turn ON** and allow the change. The chip goes from *STARTING* to
   *ON*.
3. **Connect your VPN** as usual. The Overview shows *Verifying Tunnel* for
   about a second while the test request runs, then *Protected*.

If the VPN drops, traffic is cut at once and the card turns orange
(*Traffic Blocked*). When the VPN reconnects, traffic comes back by itself.
Closing the window keeps the icon in the notification area (it may sit in
the overflow, behind **^**); its menu turns the switch on and off and
clears a block. **Quit** there ends the app, never the protection.

The pages, settings and colours are the same as on macOS: see the main
[README](../README.md#features). A few things differ on Windows:

- **Start with Windows** sets the service to start automatically, and the
  block becomes persistent: it stays in force through a restart until the
  daemon, starting with Windows, has checked the tunnel. With it off the
  service starts on demand, and a restart clears any block.
- Interfaces go by their adapter names (*Wi-Fi*, *Ethernet*, *sing-box*,
  *WireGuard*), as in Network Connections.
- The Tunnel table shows the **program** that carries the VPN (for example
  `C:\Program Files\v2rayN\bin\xray\xray.exe (pid 4120)`).
- Settings changes need no prompt for the user who turned the switch on.
  Turning it on or off, clearing a block and **Start with Windows** ask
  each time.

### After updating the app

Installing a newer version replaces the app only; the daemon keeps
running from its own copy. The Overview then shows **Daemon is out of
date**. Press **Update** to install the matching daemon.

### Stuck offline?

Turning the kill switch off always restores traffic. Without the app,
from a terminal opened as administrator:

```powershell
& "C:\Program Files\VPN Kill Switch\Daemon\vpnks.exe" unblock
```

That lifts the block at once. The daemon blocks again if the tunnel is
still down, so follow it with `… vpnks.exe uninstall` to stop it
completely. Uninstalling VPN Kill Switch (Settings → Apps) does the same
and removes every rule. If *Start with Windows* is off, restarting Windows
also clears the block.

---

## Command line

`vpnks.exe` takes the same commands as on Linux and macOS. Changes need a
terminal opened as administrator.

| Command | What it does |
|---|---|
| `vpnks status` | Current state (as administrator it adds the firewall and probe checks). |
| `vpnks install [--autostart]` | Install and start the service (optionally with Windows too). |
| `vpnks uninstall` | Stop, unblock, remove the service and every firewall rule. |
| `vpnks unblock` | Clear the block now. |
| `vpnks config` | Print the configuration. |
| `vpnks set <key> <value>` | Change a setting (keys as on macOS). |
| `vpnks sessions` | Session history with traffic totals. |
| `vpnks endpoints` | List the VPN server exceptions. |
| `vpnks pin add <ip>` / `pin remove <ip>` | Pin or delete an exception. |
| `vpnks probe <adapter> <ip>` | Check the probe is really pinned to an adapter. |
| `vpnks --version` | Build version. |

---

## How it works

```
 VPN client ──► adapter (Wintun, WireGuard, TAP…) ──► internet
                   ▲
                   │ HTTP request every second, bound to the adapter (IP_UNICAST_IF)
                   │
          vpnks.exe (Windows service, LocalSystem)
           │   ├─ IP Helper: interface, address and route changes, as they happen
           │   ├─ service control manager: sleep and wake
           │   └─ writes status.json only when something changes
           ▼
   WFP provider and sublayer "VPN Kill Switch"
   (no filters while healthy; the block while the tunnel is down)

 VPN Kill Switch app (you, not elevated)
   ├─ reads status.json, log, sessions        → no prompt to watch
   ├─ writes config.json / endpoints.json     → settings without a prompt
   └─ runs vpnks.exe through UAC              → to turn on, off, clear
```

What maps to what, from Linux:

| Linux | Windows |
|---|---|
| nftables table `inet vpn_kill_switch` | A WFP provider and sublayer of our own, at the highest weight, with filters at the ALE connect and receive/accept layers for IPv4 and IPv6. They are swapped in one transaction, so no packet ever sees a half-loaded set. |
| table survives a daemon crash | filters are not tied to the daemon's session, so a crash leaves the block in force until the service restarts (2 s) |
| systemd `Before=network-pre.target` | with *Start with Windows*, persistent filters, which the filtering engine loads itself at boot, before the service starts |
| netlink subscriptions | `NotifyIpInterfaceChange`, `NotifyUnicastIpAddressChange`, `NotifyRouteChange2` |
| logind sleep signal | `SERVICE_CONTROL_POWEREVENT` |
| `SO_BINDTODEVICE` | `IP_UNICAST_IF` |
| `ip route get 1.1.1.1` | `GetBestInterfaceEx(1.1.1.1)`, which honours the 0/1 + 128/1 routes WireGuard and OpenVPN add |
| the process holding `/dev/net/tun` | running programs matched against known VPN engines and apps (Windows does not say which process created an adapter) |
| learning the server from nftables' byte counts | not available. Instead the VPN program itself is let through by application (WFP app ID) while blocked, so it can reach any server, over TCP or UDP. Host routes, WireGuard peers and the program's TCP connections are still learned as exceptions. |
| polkit (`pkexec`) | UAC (`ShellExecuteEx` with `runas`); the elevated CLI reports back through a file named with `--report` |
| `root:sudo 0664` on the settings | the state folder is read-only to users, except `config.json` and `endpoints.json`, which the user who installed the switch may modify |

Things a firewall cannot see are never blocked: the machine talking to
itself, getting an address (DHCP) and finding its router (IPv6 neighbour
discovery). Linux's DHCP client never reaches nftables; on Windows these
are let through explicitly, or the machine would drop off the network.

### Files

| Path | Contents |
|---|---|
| `C:\Program Files\VPN Kill Switch\` | The app and the daemon shipped with it |
| `C:\Program Files\VPN Kill Switch\Daemon\vpnks.exe` | The installed, running daemon |
| `C:\ProgramData\VPN Kill Switch\config.json` | Settings (the installing user may modify) |
| `C:\ProgramData\VPN Kill Switch\status.json` | Live status for the app |
| `C:\ProgramData\VPN Kill Switch\kill_switch.log` | Activity log for this month |
| `C:\ProgramData\VPN Kill Switch\sessions.json` | Session history |
| `C:\ProgramData\VPN Kill Switch\endpoints.json` | VPN server exceptions (the installing user may modify) |
| `%AppData%\vpn-kill-switch\prefs.json` | The app's appearance and tray style |

To see the rules themselves: `netsh wfp show filters` (as administrator)
writes `filters.xml`; ours are named *VPN Kill Switch: …*.

## Limits

- **Without always-armed mode there is a short window**, as on macOS and
  Linux. **Always armed** closes it.
- **IPv4 exceptions only.**
- **The VPN program is found by name.** A client not in the list in
  `go/internal/daemon/vpnapp_windows.go` still works, but its name is not
  shown and it is not let through by application while blocked; it then
  reconnects through the learned exceptions and the reconnect window, as on
  Linux.
- **Forwarded traffic may get around the block.** The filters cover
  connections made by this machine's programs. Traffic Windows forwards for
  others (Internet Connection Sharing, and possibly WSL 2 or Hyper-V VMs in
  NAT mode) passes a different layer, which has not been tested yet. Linux
  covers this with its `forward` hook.
- **Not code-signed**, so SmartScreen warns on first run.

## Layout

The Go code lives in [`go/`](../go/), shared with Linux: files ending in
`_windows.go` are the Windows parts.

```
go/
  cmd/vpnks/           daemon and CLI entry point (main_windows.go: the service)
  internal/daemon/     wfp_windows.go       the WFP binding (fwpuclnt.dll)
                       firewall_windows.go  the rules
                       ifaces_, routes_, sockets_, probe_, vpnapp_, watchers_,
                       service_, installer_windows.go
  app/                 the Wails app; *_windows.go: UAC, theme, tray icon
  tools/winres/        writes the icon and manifest into the .exe files
windows/
  build.ps1            build, zip, and (with NSIS) the installer; run through build.cmd
  packaging/installer.nsi
```

The WFP tests (`go test ./internal/daemon` on Windows) check the struct
layouts against the C headers and, in a terminal opened as administrator,
load and remove a real block.

# VPN Kill Switch for macOS

A kill switch that cuts your internet the moment your VPN stops carrying
traffic, so nothing ever leaves your Mac over your real IP address. When
the tunnel is healthy again, traffic comes back by itself.

It works with any VPN app that creates a `utun` tunnel interface (Happ,
v2rayN, OpenVPN Connect, WireGuard, Windscribe, sing-box-based clients
and so on). It does not replace your VPN; it guards it.

The project has two parts:

| Part | What it is | Where |
|---|---|---|
| **`vpnks` daemon** | A small root process that watches the tunnel and drives the macOS firewall (`pf`). This is what actually protects you. | [`swift/`](swift/) |
| **VPN Kill Switch.app** | A SwiftUI app for macOS 26: live status, settings, history, activity and a menu bar item. It only displays state and asks the daemon to change it. | [`gui/`](gui/) |

Quitting or rebuilding the app never drops your protection. Only
**Turn Off** in the app, or `sudo vpnks uninstall`, stops the kill switch.

---

## Features

### Protection
- **Leak blocking through the macOS firewall.** When the tunnel dies,
  `pf` rules block all outbound traffic except loopback. Traffic can then
  leave only through the tunnel.
- **A real test that the tunnel works, not a guess.** Every second the
  daemon sends a small HTTP request to `1.1.1.1`, pinned to the tunnel
  interface. Pings are not enough: proxy-style VPNs drop them even when
  healthy. Opening a connection is not enough either: those VPNs accept
  one locally even when the tunnel is dead. Only an actual reply from a
  real server proves traffic is flowing.
- **Fails closed.** When the daemon starts, when the Mac wakes from sleep,
  and when the tunnel changes, traffic stays blocked until a test passes on
  *that* tunnel. Traffic is let through only after the test succeeds.
- **Fast.** The daemon reacts to network changes and sleep/wake events
  directly from the system instead of polling. One check costs about
  0.07 ms, so it re-checks on every event.
- **Always-armed mode** (optional). The block stays loaded permanently and
  only the tunnel is ever allowed out, so there is no reaction delay at
  all. The trade-off: no VPN means no internet until you turn it off.

### While traffic is blocked
- **Local network stays reachable** (optional): printers, file shares,
  other machines at home.
- **DNS is blocked** (optional), so name lookups do not leak to your
  router and on to your ISP.
- **Your VPN can still reconnect.** The daemon learns your VPN server
  addresses while the tunnel is up and keeps them reachable during a
  block. You can pin addresses so they are never forgotten.

### The app
- **Overview:** one status card (Protected / Traffic Blocked / Verifying
  Tunnel / Not Protected), stat tiles for the kill switch, VPN, traffic
  and this session's data, and live tunnel details.
- **Settings:** always-armed, LAN, DNS, reconnect and start-at-login
  toggles, the menu bar style, and recovery actions.
- **Exceptions:** the VPN server addresses allowed through the block, with
  pin, unpin and remove. You can add your own too.
- **History:** every VPN session with duration, download and upload
  totals, and how often traffic was cut.
- **Activity:** the daemon's log, newest first, colour-coded and
  searchable.
- **Menu bar item:** state at a glance (ON / CUT / ARMED / OFF), with
  turn on/off and "clear block" without opening the window. It can show
  an amber-and-black hazard-stripe background (Settings → Menu bar).
- **Light, dark or automatic appearance**, in the *Daftar* design
  language, with an amber accent.
- **One colour language everywhere:** green means protected, orange means
  traffic is held or something is changing, red means unprotected, blue
  means always-armed.

---

## Requirements

- macOS 26 or later (the app uses the macOS 26 SDK).
- Xcode 26 with command-line tools, to build.
- An administrator account. Turning the switch on and off changes the
  system firewall, so macOS asks for your password each time.

---

## Build and install

From the project folder:

```bash
./build.sh
```

This builds the release version of both the daemon and the app, puts the
result in `output/`, and then asks where to install it:

```
Built v26.09.27. Install it?
  1) /Applications        (all users, asks for your password)
  2) ~/Applications       (just you, no password)
  n) No, leave it in output/
Choice [1/2/N]:
```

If you install, it quits the running app first (the kill switch keeps
running), copies in the new version, registers it with Spotlight and the
Dock, and offers to open it. Press Enter to just build without
installing.

To build and install to `/Applications` without any questions:

```bash
./build.sh --yes
```

The version number is the build date (`YY.MM.DD`), e.g. `26.09.27`.

### Other scripts

| Script | Use it for |
|---|---|
| `./build.sh` | Build a release and optionally install it. **Start here.** |
| `./gui/build.sh` | Build only, into `output/`. |
| `./gui/run.sh` | Development: rebuild everything and relaunch the app from the build folder. |
| `./gui/install-app.sh [--system]` | Build and install without asking (`~/Applications`, or `/Applications` with `--system`). |

---

## Using the app

1. **Open VPN Kill Switch** from Applications or Spotlight.
2. **Press Turn On** (top right) and enter your password. The chip next
   to it goes from *STARTING* to *ON*.
3. **Connect your VPN** as usual. The Overview shows *Verifying Tunnel*
   for about a second while the test request runs, then *Protected*.

From then on:

- **If the VPN drops,** traffic is cut straight away. The card turns
  orange (*Traffic Blocked*), and the menu bar shows *CUT*.
- **When the VPN reconnects,** traffic comes back automatically once the
  new tunnel passes its test.
- **To turn it off,** press **Turn Off** and enter your password. This
  stops the daemon, removes the firewall rule and never leaves traffic
  cut.

If you cancel a password prompt, nothing changes and the app goes back to
its previous state.

### After updating the app

The app ships with its own copy of the daemon. If you install a newer app
while an older daemon is running, the Overview shows **Daemon is out of
date**. Press **Update** there to install the matching daemon.

### Stuck offline?

Turning the kill switch off always restores traffic. If the app is
unavailable, run this in Terminal:

```bash
sudo /sbin/pfctl -a vpn_kill_switch -F rules
```

That clears the block immediately. The daemon will block again if the
tunnel is still down, so follow it with `sudo vpnks uninstall` to stop it
completely.

---

## Command line

The daemon is also a command-line tool. Once installed it lives at
`/usr/local/libexec/vpn_kill_switch/vpnks`. A copy is also in `output/`
after a build.

| Command | What it does |
|---|---|
| `vpnks status` | Current state. |
| `sudo vpnks install [--autostart]` | Install and start the daemon (optionally at boot too). |
| `sudo vpnks uninstall` | Stop, unblock, remove the startup item and the firewall anchor. |
| `sudo vpnks unblock` | Clear the block now. |
| `vpnks config` | Print the configuration. |
| `sudo vpnks set <key> <value>` | Change a setting (see below). |
| `vpnks sessions` | Session history with traffic totals. |
| `vpnks endpoints` | List the VPN server exceptions. |
| `sudo vpnks pin add <ip>` / `pin remove <ip>` | Pin or delete an exception. |
| `vpnks --version` | Build version. |

### Settings

| Key | Default | Meaning |
|---|---|---|
| `alwaysArmed` | `0` | Keep the block loaded permanently (zero reaction time, no internet without VPN). |
| `allowLAN` | `1` | Keep the local network reachable while blocked. |
| `blockDNS` | `1` | Block DNS (ports 53 and 853) while blocked. |
| `allowVPNReconnect` | `1` | Keep learned VPN server addresses reachable while blocked. |
| `autostart` | `0` | Start the daemon at boot. |
| `probeEnabled` | `1` | Test that the tunnel carries traffic, not just that it exists. |
| `probeHost` | `1.1.1.1` | Server the test request goes to (an IP address, so no DNS is needed). |
| `probeIntervalSeconds` | `1` | Seconds between test requests. |
| `probeFailThreshold` | `1` | Failed tests before blocking. |
| `requireDefaultRoute` | `1` | Block if the default route leaves the tunnel. |
| `vpnInterface` | *(auto)* | Pin a specific `utun` interface instead of tracking it automatically. |

Most settings apply within a second. The app changes them without a
password prompt; `autostart` needs one because it installs a system
startup item.

---

## How it works

```
 VPN app ──► utun tunnel ──► internet
                 ▲
                 │ test request every second, pinned to the tunnel
                 │
          vpnks daemon (root, launchd)
           │   ├─ reacts to network changes, sleep and wake
           │   └─ writes status.json once a second
           ▼
   pf firewall anchor "vpn_kill_switch"
   (empty while healthy; the block rules while the tunnel is down)

 VPN Kill Switch.app (you, unprivileged)
   ├─ reads status.json, log, sessions      → no password to watch
   └─ runs vpnks through the password prompt → to turn on, off, clear
```

- **Blocking.** The daemon loads the block rules into its own firewall
  anchor (a separate slot in `pf`, so it doesn't touch your other
  firewall rules) and empties the anchor again when the tunnel is
  healthy.
- **The app never has root rights.** It reads the files the daemon
  publishes, and every change goes through a macOS password prompt you
  can decline. There is no privileged helper installed behind your back.

### Files

| Path | Contents |
|---|---|
| `/usr/local/libexec/vpn_kill_switch/vpnks` | Installed daemon |
| `/usr/local/var/vpn_kill_switch/config.json` | Settings |
| `/usr/local/var/vpn_kill_switch/status.json` | Live status for the app |
| `/usr/local/var/vpn_kill_switch/kill_switch.log` | Activity log (capped at 5 MB) |
| `/usr/local/var/vpn_kill_switch/sessions.json` | Session history |
| `/usr/local/var/vpn_kill_switch/endpoints.json` | VPN server exceptions |
| `/etc/pf.anchors/vpn_kill_switch` | Firewall rules |

---

## Limits

- **Without always-armed mode, there is a short window.** Between the
  tunnel failing and the block landing, packets can leave. For a tunnel
  that disappears, that is well under a millisecond. For a tunnel that
  stays up but stops passing traffic, it is up to about a second while
  the test request fails. **Always-armed** closes the gap entirely.
- **The daemon and the legacy shell script must not run together.** The
  older `vpn_kill_switch.sh` in this repo drives the same firewall slot,
  and the two would fight over it.
- **IPv4 exceptions only.** VPN server exceptions are IPv4 addresses.

---

## Project layout

```
build.sh                 build a release and optionally install it
swift/                   vpnks daemon and CLI (Swift package)
gui/                     macOS app (Xcode project)
  VPNKillSwitch/         SwiftUI sources; Daftar.swift holds the design system
  Icon/                  app icon source (AppIcon.svg) and renderer
  build.sh, run.sh, install-app.sh
vpn_kill_switch.sh       original shell version (superseded by vpnks)
output/                  build results (created by the build)
```

More detail: [`swift/README.md`](swift/README.md) covers the daemon's design
and measurements; [`gui/README.md`](gui/README.md) covers the app.

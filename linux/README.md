# VPN Kill Switch for Linux (Ubuntu)

The Linux version of the kill switch: it cuts your internet the moment your
VPN stops carrying traffic, and lets it back once the tunnel works again.
Same behaviour, settings and look as the macOS app, rebuilt for Linux in Go.

It works with any VPN that creates a tunnel interface: WireGuard (`wg0`),
OpenVPN (`tun0`), sing-box, Xray, Clash, Happ, NetworkManager VPNs and
similar clients.

| Part | What it is | macOS counterpart |
|---|---|---|
| **`vpnks` daemon** | A root systemd service that watches the tunnel and drives the firewall (nftables). This is what protects you. | `vpnks` (pf, launchd) |
| **VPN Kill Switch app** | The window and the tray icon (Go + [Wails](https://wails.io), drawn in the same *Daftar* design). It only displays state and asks the daemon to change it. | the SwiftUI app |

Quitting the app never drops your protection. Only **Turn OFF** (or
`sudo vpnks uninstall`) stops the kill switch.

---

## Requirements

- Ubuntu 22.04 or later (or another distribution with systemd, nftables,
  polkit and WebKitGTK 4.1).
- An administrator account (a member of the `sudo` group). Turning the
  switch on and off changes the firewall, so it asks for your password.
- For the tray icon: Ubuntu's built-in *AppIndicator* extension (on by
  default). Without a tray, closing the window quits the app instead.

## Build and install

On Ubuntu, from the project folder:

```bash
sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev
```

Install Go 1.26 or later (from [go.dev/dl](https://go.dev/dl/)), then:

```bash
./linux/build.sh
```

It builds both programs, packages them as a `.deb` in `output/linux/`, and
asks whether to install it. `./linux/build.sh --yes` installs without
asking.

### Building on a Mac

With Docker running:

```bash
./linux/docker-build.sh
```

That builds the amd64 `.deb` (most PCs) inside an Ubuntu container;
`./linux/docker-build.sh arm64` builds for ARM. Copy the `.deb` to the
Ubuntu machine and install it:

```bash
sudo apt install ./VPN-Kill-Switch-26.10.15-linux-amd64.deb
```

The version is the build date (`YY.MM.DD`) plus the time of the build.

---

## Using the app

1. **Open VPN Kill Switch** from the app grid (or run `vpn-kill-switch`).
2. **Press Turn ON** and enter your password. The chip goes from
   *STARTING* to *ON*.
3. **Connect your VPN** as usual. The Overview shows *Verifying Tunnel* for
   about a second while the test request runs, then *Protected*.

From then on, if the VPN drops, traffic is cut at once: the card turns
orange (*Traffic Blocked*) and the tray dot turns orange. When the VPN
reconnects, traffic comes back by itself.

The tray icon shows the state at a glance. Its dot is green when protected,
orange when traffic is held, blue when always-armed, a red ring when off,
and three dots while it is changing. Its menu turns the switch on and off
and clears a block without opening the window.

The pages, settings and colours are the same as on macOS: see the main
[README](../README.md#features). A few things differ on Linux:

- **Start at boot** enables the systemd service, so the block is in force
  before the network comes up.
- **Tray icon** (Settings) replaces *Menu bar*: the hazard-stripe plate or a
  plain dot.
- The Tunnel table shows the **process** that owns the tunnel (for example
  `/usr/bin/sing-box (pid 2214)`) where macOS shows a bundle ID.

### After updating the app

Installing a newer `.deb` replaces the app only; the daemon keeps running
from its own copy. The Overview then shows **Daemon is out of date**. Press
**Update** to install the matching daemon.

### Stuck offline?

Turning the kill switch off always restores traffic. Without the app:

```bash
sudo nft delete table inet vpn_kill_switch
```

That lifts the block immediately. The daemon blocks again if the tunnel is
still down, so follow it with `sudo vpnks uninstall` to stop it completely.
Removing the package (`sudo apt remove vpn-kill-switch`) also uninstalls the
daemon and lifts the block.

---

## Command line

The package puts `vpnks` on your PATH. The commands are the same as on
macOS:

| Command | What it does |
|---|---|
| `vpnks status` | Current state (`sudo` adds the firewall and probe checks). |
| `sudo vpnks install [--autostart]` | Install and start the daemon (optionally at boot too). |
| `sudo vpnks uninstall` | Stop, unblock, remove the systemd unit and the firewall table. |
| `sudo vpnks unblock` | Clear the block now. |
| `vpnks config` | Print the configuration. |
| `sudo vpnks set <key> <value>` | Change a setting (keys as on macOS). |
| `vpnks sessions` | Session history with traffic totals. |
| `vpnks endpoints` | List the VPN server exceptions. |
| `sudo vpnks pin add <ip>` / `pin remove <ip>` | Pin or delete an exception. |
| `sudo vpnks probe <iface> <ip>` | Check the probe is really pinned to an interface. |
| `vpnks --version` | Build version. |

---

## How it works

```
 VPN client ──► tunnel (wg0, tun0…) ──► internet
                   ▲
                   │ HTTP request every second, bound to the tunnel (SO_BINDTODEVICE)
                   │
          vpnks daemon (root, systemd)
           │   ├─ netlink: link, address and route changes, as they happen
           │   ├─ logind: sleep and wake
           │   └─ writes status.json only when something changes
           ▼
   nftables table "inet vpn_kill_switch"
   (counting-only rules while healthy; the block while the tunnel is down)

 VPN Kill Switch app (you, unprivileged)
   ├─ reads status.json, log, sessions        → no password to watch
   ├─ writes config.json / endpoints.json     → settings without a password
   └─ runs vpnks through pkexec (polkit)      → to turn on, off, clear
```

What maps to what, from the macOS daemon:

| macOS | Linux |
|---|---|
| pf anchor `vpn_kill_switch` | nftables table `inet vpn_kill_switch`, with hooks on output **and forward** (so Docker containers and VMs cannot leak around it) |
| `NWPathMonitor`, routing socket | netlink link/address/route subscriptions; `ip route get` semantics, so policy routing (wg-quick, sing-box) is honoured |
| `IORegisterForSystemPower` | logind `PrepareForSleep`, with a delay lock so session totals are saved before sleep |
| `IP_BOUND_IF` | `SO_BINDTODEVICE` |
| pf state table (learning the VPN server) | a counting set in the pass-only table, plus WireGuard peers read from the kernel and /32 host routes |
| `scutil --nc list` | NetworkManager's active connection, or the process holding the tun device (`/proc/*/fdinfo`) |
| launchd + Authorization Services | systemd + polkit (`pkexec`) |

Unlike pf, nftables keeps no state that lets an established connection
skip the rules, so nothing needs flushing when the block goes up: an
in-flight download is cut at its next packet.

### Files

| Path | Contents |
|---|---|
| `/usr/lib/vpn-kill-switch/` | The app and the daemon shipped with it (from the `.deb`) |
| `/usr/local/lib/vpn-kill-switch/vpnks` | The installed, running daemon |
| `/etc/systemd/system/vpn-kill-switch.service` | The service, written by `vpnks install` |
| `/var/lib/vpn-kill-switch/config.json` | Settings (root:sudo 0664) |
| `/var/lib/vpn-kill-switch/status.json` | Live status for the app |
| `/var/lib/vpn-kill-switch/kill_switch.log` | Activity log for this month |
| `/var/lib/vpn-kill-switch/sessions.json` | Session history |
| `/var/lib/vpn-kill-switch/endpoints.json` | VPN server exceptions (root:sudo 0664) |
| `~/.config/vpn-kill-switch/prefs.json` | The app's appearance and tray style |

## Limits

- **Without always-armed mode there is a short window**, as on macOS:
  under a millisecond for a tunnel that disappears, up to about a second
  for one that stays up but stops passing traffic. **Always armed** closes
  it.
- **IPv4 exceptions only.**
- **Split-tunnel VPNs** that leave ordinary traffic outside the tunnel are
  reported as down (the default route is not the tunnel). Set
  `requireDefaultRoute 0` if that is what you use.

## Layout

The Go code is shared with the [Windows version](../windows/README.md): files
ending in `_linux.go` are the Linux parts, `_windows.go` the Windows ones,
and the rest (the state machine, the app's controller and the whole
frontend) is common.

```
go/
  cmd/vpnks/           daemon and CLI entry point
  internal/core/       config, status, sessions, endpoints, log (shared with the app)
  internal/daemon/     state machine; nftables, netlink, probe, systemd installer (_linux.go)
  app/                 the Wails app: Go controller, tray, and frontend/dist (HTML/CSS/JS)
linux/
  packaging/           .desktop entry, polkit policy, icons, build container
  build.sh             build + .deb (on Ubuntu)
  docker-build.sh      the same from macOS, in a container
```

To work on the app's look without Linux, open
`go/app/frontend/dist/index.html` through any static web server: with no
Go backend it runs on built-in sample data. Add `?state=blocked`
(`protected`, `verifying`, `armed`, `off`, `starting`) and
`&appearance=dark` to see the other states.

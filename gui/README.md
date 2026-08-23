# VPN Kill Switch — macOS app

SwiftUI front end for the `vpnks` daemon. Built against the macOS 26 SDK
using the system design language: Liquid Glass surfaces, an inspector-style
`NavigationSplitView`, grouped `Form` sections, and a `MenuBarExtra`.

## Build

```
./gui/build.sh
open "gui/.build/Build/Products/Release/VPN Kill Switch.app"
```

The script builds the daemon, builds the app, copies the daemon into
`Contents/Resources/`, and re-signs the bundle (adding a file breaks the
existing seal, and macOS refuses to launch an app with a broken seal).
The result is self-contained — no separate CLI install needed first.

Or open `gui/VPNKillSwitch.xcodeproj` in Xcode and press Run. Build the
daemon once first (`cd swift && swift build -c release`) so the app can
find it.

## How privilege works

The app is **unprivileged** and installs **no privileged helper**.

- **Reading state** — the root daemon publishes
  `/usr/local/var/vpn_kill_switch/status.json` (world-readable) roughly
  once a second and immediately on every transition. The app polls that
  file, so displaying status never prompts for a password.
- **Changing state** — turning the switch on/off, toggling settings and
  clearing a block run the `vpnks` CLI through
  `do shell script … with administrator privileges`. Each is an explicit
  macOS authorisation prompt you can decline.

A proper `SMAppService` helper would avoid repeat prompts, but it
requires a Developer ID certificate and an Apple-granted entitlement,
so it is deliberately not used here.

## Panels

**Overview** — hero status card tinted by state (grey / green / orange /
blue), live tunnel facts, and the learned VPN-server exceptions. Those
exceptions are shown rather than hidden because they are a deliberate
hole in the firewall and you should be able to see exactly how wide it is.

**Settings** — *Always armed* (zero-latency mode) and *Start at login*,
each with a footer explaining the trade-off rather than just a label.
Plus recovery actions.

**Activity** — searchable live tail of the daemon log, newest first, with
severity colouring. Newest-first because when something has just gone
wrong, the relevant line should already be on screen.

**Menu bar** — a shield icon reflecting current state, with turn on/off
and clear-block, so you do not need the window open day to day.

## Design notes

The status card is the only element with a tinted glass background, so
state is readable across the room without reading a word. Everything
else uses standard system chrome.

While traffic is cut, an escape-hatch panel appears with the raw pfctl
command. A kill switch that strands you with no obvious way out is a
worse failure than one that reacts a second late.

`isFresh` treats a status file older than 8 seconds as "daemon not
running" — a stale file must never be shown as live protection.

## What is verified, and what is not

Verified on macOS 26.5.2 / Xcode 26.1.1: clean release build with no
warnings; the app launches without crashing and opens an 810x551 window;
the bundled daemon runs from inside the bundle; the code signature stays
valid after bundling; and the daemon→app `status.json` contract decodes
correctly, including stale-file detection.

Not verified: the privileged actions (Turn On/Off, toggles, Clear Block)
all require an authorisation prompt that cannot be driven from a script,
so they are written but unproven. If one fails, the app surfaces the
error in an alert — and the same command run by hand in Terminal will
show the same message.

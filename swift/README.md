# vpnks — Swift VPN kill switch daemon (macOS)

The event-driven daemon behind VPN Kill Switch on macOS. The app in
[`../gui`](../gui) is the friendlier control surface; the CLI below is
for scripting and debugging.

## Build & install

```
swift build -c release
sudo .build/release/vpnks install            # start now, not at boot
sudo .build/release/vpnks install --autostart # also start at boot
```

Do **not** run this and the shell daemon at once — they drive the same
pf anchor and will fight over it. Stop the shell one first (`f` in its
menu).

## Commands

| command | what it does |
|---|---|
| `vpnks status` | current state, no root needed for most of it |
| `vpnks probe utun7 1.1.1.1` | prove the probe is really pinned to an interface |
| `vpnks bench` | cost of one structural evaluation |
| `vpnks set <key> <value>` | change a setting |
| `vpnks unblock` | clear the block now |
| `vpnks uninstall` | stop, unblock, remove launchd + pf anchor |

Emergency unblock without the tool:

```
sudo /sbin/pfctl -a vpn_kill_switch -F rules
```

## What it does differently from the shell version

**Three real event sources instead of one polled pipe.**

- `NWPathMonitor` — kernel-coalesced network path changes, replacing
  `route -n monitor` piped through a FIFO.
- `IORegisterForSystemPower` — genuine sleep/wake notifications. The
  shell version could only *infer* suspension afterwards, by noticing
  its own loop had not run for a while.
- A 1s backstop timer, for the one case no event can report: a VPN
  process dying quietly while its interface and routes stay put.

**No forking.** Route lookups go through `RTM_GET` on a routing socket
and interfaces through `getifaddrs(3)`. Measured: **0.07 ms** per
structural evaluation versus **3.8 ms** for the shell equivalent — 54x
cheaper. That is what makes it affordable to re-evaluate on every single
event rather than rationing checks to twice a second to keep CPU down.

**The probe never blocks detection.** It runs on its own queue; the
state machine reads only its cached result. Inline probing meant a 3s
network timeout stalled every structural check behind it.

**Fail closed on startup and on wake.** State begins as "blocked" and
only lifts once a probe proves the tunnel carries traffic.

## What is identical, and why

Enforcement is still `pfctl`, driving the same `vpn_kill_switch` anchor
with the same rules. Filtering packets from Swift directly would require
a NetworkExtension system extension plus an Apple-granted entitlement —
Swift buys nothing here.

The probe is still an HTTP round trip, for reasons measured on a live
transparent-proxy tunnel:

- bound **ICMP fails even when the tunnel is healthy** (the proxy does
  not forward pings) — trusting it means blocking forever;
- a bound **TCP connect succeeds against a black-holed address**,
  because the proxy accepts the socket before it has an upstream —
  trusting it means never noticing a dead tunnel.

Only bytes returning from a real server tell those apart. The target is
an IP literal (`http://1.1.1.1/`, which answers 301) so the probe needs
no DNS and keeps working while our own block is in force.

## The honest limit

Reactive blocking always has a window. Between the kernel moving the
default route and any userspace process reacting, packets can leave. This
daemon shrinks that window to well under a millisecond, but cannot make
it zero.

`vpnks set alwaysArmed 1` does make it zero: the block stays loaded
permanently and traffic is only ever allowed out over the tunnel, so
there is nothing to detect and nothing to race. The cost is that you
cannot reach the network at all without the VPN. That is how commercial
kill switches work.

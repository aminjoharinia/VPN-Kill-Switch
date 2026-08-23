#!/bin/bash
#
# vpn_kill_switch.sh — VPN kill switch for macOS
#
# Watches VPN connectivity. The moment the tunnel stops carrying traffic,
# it blocks outbound traffic via pf so nothing leaks over your real IP.
#
#   ALL   — block all outbound traffic except loopback (true kill switch)
#   LIST  — block only a domain/IP list (best effort, see notes in the UI)
#
# Emergency unblock, if anything ever goes wrong:
#
#     sudo /sbin/pfctl -a vpn_kill_switch -F rules
#
# Usage:
#   chmod +x vpn_kill_switch.sh
#   ./vpn_kill_switch.sh
#
# ---------------------------------------------------------------------

set -o pipefail

SCRIPT_VERSION="2026-08-23-hardened-v4"

# ---------------------------------------------------------------------
# Paths.
#
# These are FIXED, ABSOLUTE and ROOT-OWNED on purpose. The previous
# version derived them from the invoking user's home directory, via
# `stat -f%Su /dev/console` when running as root. At boot — before
# anybody logs in — /dev/console is owned by _windowserver, whose home
# is /var/empty. So every launchd-started daemon computed
# /var/empty/.vpn_kill_switch, failed to create it, never loaded its
# config, never created its FIFO, and spun in a tight error loop
# forever without ever touching pf. That is why it "stopped working
# after a reboot or sleep". Nothing here may depend on $HOME or on who
# is logged in.
# ---------------------------------------------------------------------
LIBEXEC_DIR="/usr/local/libexec/vpn_kill_switch"
INSTALLED_SCRIPT="$LIBEXEC_DIR/vpn_kill_switch.sh"
STATE_DIR="/usr/local/var/vpn_kill_switch"
CONFIG_FILE="$STATE_DIR/config.conf"
PROFILES_DIR="$STATE_DIR/profiles"
LOG_FILE="$STATE_DIR/kill_switch.log"
DAEMON_OUT_LOG="$STATE_DIR/daemon.out.log"
DAEMON_ERR_LOG="$STATE_DIR/daemon.err.log"
FIFO="$STATE_DIR/route.fifo"
ENDPOINTS_FILE="$STATE_DIR/vpn_endpoints"

PLIST_LABEL="com.user.vpnkillswitch"
PLIST_BOOT="/Library/LaunchDaemons/${PLIST_LABEL}.plist"
PLIST_MANUAL="$STATE_DIR/${PLIST_LABEL}.plist"

PF_ANCHOR_NAME="vpn_kill_switch"
PF_ANCHOR_FILE="/etc/pf.anchors/vpn_kill_switch"
PF_CONF="/etc/pf.conf"
PF_CONF_BAK="/etc/pf.conf.vpnks.bak"
PF_MARK="# --- vpn_kill_switch (managed) ---"

LOG_MAX_BYTES=$((5 * 1024 * 1024))

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

priv() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  if [[ -w "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  else
    printf '%s\n' "$line" | priv tee -a "$LOG_FILE" >/dev/null 2>&1
  fi
}

# Keep every log we own bounded. The old version had no rotation at all,
# which is how launchd.err.log reached 18 GB.
rotate_log() {
  local f="$1" sz
  [[ -f "$f" ]] || return 0
  sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
  if [[ "$sz" -gt "$LOG_MAX_BYTES" ]]; then
    cp -f "$f" "$f.1" 2>/dev/null
    : > "$f" 2>/dev/null      # truncate in place: launchd holds these open
  fi
}

# ---------- colors ----------
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[38;5;203m'; GREEN='\033[38;5;114m'; YELLOW='\033[38;5;221m'
BLUE='\033[38;5;75m'; MAGENTA='\033[38;5;176m'; CYAN='\033[38;5;80m'
GRAY='\033[38;5;244m'

hr() { printf "${GRAY}%s${RESET}\n" "────────────────────────────────────────────────────────────"; }

header() {
  clear
  printf "${BOLD}${RED}"
  cat << 'ASCII_EOF'
   _   __ ___   _  __   __ __ _  __  __     ____         _  __       __
  | | / // _ \ / |/ /  / //_/(_)/ / / /    / __/ _    __(_)/ /_ ____/ /_
  | |/ // ___//    /  / ,<  / // /_/ /    _\ \  | |/|/ // // __// __/ __ \
  |___//_/   /_/|_/  /_/|_|/_//_/\____/  /___/  |__,__//_/ \__/\__/_/ /_/
ASCII_EOF
  printf "${RESET}${DIM}  blocks traffic the moment your VPN tunnel stops carrying it${RESET}\n\n"
}

press_enter() { printf "\n${GRAY}Press Enter to continue...${RESET}"; read -r; }

# ---------------------------------------------------------------------
# Config
#
# Parsed with a strict key whitelist and value validation, never with
# `source`. The daemon runs as root and reads this file every second;
# sourcing it meant anyone who could write the file got root.
# ---------------------------------------------------------------------
set_config_defaults() {
  VPN_INTERFACE=""
  VPN_APP_NAME=""
  MODE="ALL"
  ACTIVE_PROFILE="claude"
  CONFIG_VERSION=0

  # Liveness probing. A tunnel interface that still holds an IP proves
  # nothing — a crashed VPN app leaves exactly that behind. The probe is
  # always BOUND TO THE TUNNEL, so it fails on a dead tunnel even while
  # the machine still has internet over the physical interface.
  #
  # PROBE_MODE=http is the default and the only reliable option for
  # transparent/fake-IP TUN proxies (sing-box, Happ, Hiddify, clash...).
  # Measured on exactly that kind of tunnel:
  #   - bound ICMP fails even when the tunnel is perfectly healthy
  #     (the proxy does not forward pings) -> would block you forever
  #   - a bound TCP connect SUCCEEDS against a black-holed address,
  #     because the local proxy accepts before it has an upstream
  #     -> would never notice a dead tunnel
  # Only a real HTTP round trip proves bytes came back from a real
  # server through the tunnel.
  # Measured on a live tunnel: a healthy probe returns in ~0.5s and a
  # dead one fails in ~0.5s too (the proxy rejects immediately rather
  # than hitting the timeout). So probing every tick is affordable, and
  # one failure is enough to act on. Worst-case detection is ~1.5s, and
  # a false block clears itself on the next successful probe ~1s later.
  # A kill switch should err toward blocking, never toward waiting.
  PROBE_ENABLED=1
  PROBE_MODE="http"
  PROBE_URL="http://captive.apple.com/hotspot-detect.html"
  PROBE_HOST="1.1.1.1"
  PROBE_TIMEOUT_SECONDS=3
  PROBE_INTERVAL_SECONDS=1
  PROBE_FAIL_THRESHOLD=1

  # Zero-latency mode. When on, the physical-interface block stays
  # loaded permanently and traffic is only ever allowed out over the
  # tunnel (plus LAN and the learned VPN server). Nothing has to be
  # detected, so nothing can leak during detection — but you cannot get
  # online without the VPN while it is on.
  ALWAYS_ARMED=0

  # Require the default route to point into the tunnel. Correct for
  # full-tunnel VPNs; turn off for split-tunnel setups.
  REQUIRE_DEFAULT_ROUTE=1

  # Block rule shaping.
  ALLOW_LAN=1              # keep LAN/printers/local DNS reachable while blocked
  BLOCK_DNS=1              # ...but still block DNS off-box, so queries can't leak
  ALLOW_VPN_RECONNECT=1    # permit traffic to learned VPN server IPs, so the
                           # VPN can actually reconnect while the block is on

  # Start the kill switch automatically at boot. Off by default: the
  # daemon is started and stopped from this menu.
  AUTOSTART=0
}

config_value_ok() {
  local key="$1" val="$2"
  case "$key" in
    VPN_INTERFACE)          [[ "$val" =~ ^[a-z]+[0-9]*$ || -z "$val" ]] ;;
    VPN_APP_NAME)           [[ "$val" =~ ^[A-Za-z0-9\ ._-]*$ ]] ;;
    MODE)                   [[ "$val" == "ALL" || "$val" == "LIST" ]] ;;
    ACTIVE_PROFILE)         [[ "$val" =~ ^[A-Za-z0-9._-]+$ ]] ;;
    CONFIG_VERSION)         [[ "$val" =~ ^[0-9]+$ ]] ;;
    PROBE_HOST)             [[ "$val" =~ ^[A-Za-z0-9._:-]*$ ]] ;;
    PROBE_MODE)             [[ "$val" == "http" || "$val" == "icmp" ]] ;;
    PROBE_URL)              local _re='^https?://[A-Za-z0-9._:/~%?=&-]+$'
                            [[ "$val" =~ $_re ]] ;;
    PROBE_ENABLED|REQUIRE_DEFAULT_ROUTE|ALLOW_LAN|BLOCK_DNS|ALLOW_VPN_RECONNECT|AUTOSTART|ALWAYS_ARMED)
                            [[ "$val" =~ ^[01]$ ]] ;;
    PROBE_TIMEOUT_SECONDS|PROBE_INTERVAL_SECONDS|PROBE_FAIL_THRESHOLD)
                            [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]] ;;
    *) return 1 ;;
  esac
}

load_config() {
  set_config_defaults
  [[ -r "$CONFIG_FILE" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      \#*|"") continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    [[ "$key" == "$line" ]] && continue
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    val="${val%\"}"; val="${val#\"}"
    if config_value_ok "$key" "$val"; then
      eval "$key=\$val"
    fi
  done < "$CONFIG_FILE"

  # Migration. A config written by an earlier build carries that build's
  # slower probe timings, and a stored value always beats a new default
  # — so without this the faster detection would never reach an existing
  # install.
  if [[ "${CONFIG_VERSION:-0}" -lt 2 ]]; then
    PROBE_TIMEOUT_SECONDS=3
    PROBE_INTERVAL_SECONDS=1
    PROBE_FAIL_THRESHOLD=1
    CONFIG_VERSION=2
    CONFIG_MIGRATED=1
  fi
}

save_config() {
  local tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" << CFG_EOF
# vpn_kill_switch configuration — parsed with a strict whitelist,
# never executed. Unknown keys and malformed values are ignored.
VPN_INTERFACE="$VPN_INTERFACE"
VPN_APP_NAME="$VPN_APP_NAME"
MODE="$MODE"
ACTIVE_PROFILE="$ACTIVE_PROFILE"
CONFIG_VERSION=2
PROBE_ENABLED=$PROBE_ENABLED
PROBE_MODE="$PROBE_MODE"
PROBE_URL="$PROBE_URL"
PROBE_HOST="$PROBE_HOST"
PROBE_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
PROBE_INTERVAL_SECONDS=$PROBE_INTERVAL_SECONDS
PROBE_FAIL_THRESHOLD=$PROBE_FAIL_THRESHOLD
REQUIRE_DEFAULT_ROUTE=$REQUIRE_DEFAULT_ROUTE
ALLOW_LAN=$ALLOW_LAN
BLOCK_DNS=$BLOCK_DNS
ALLOW_VPN_RECONNECT=$ALLOW_VPN_RECONNECT
ALWAYS_ARMED=$ALWAYS_ARMED
AUTOSTART=$AUTOSTART
CFG_EOF
  priv mkdir -p "$STATE_DIR" 2>/dev/null
  priv cp "$tmp" "$CONFIG_FILE" 2>/dev/null
  priv chown root:wheel "$CONFIG_FILE" 2>/dev/null
  priv chmod 644 "$CONFIG_FILE" 2>/dev/null
  rm -f "$tmp"
}

default_profile() {
  local name="$1" tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" << 'PROF_EOF'
# One domain or IP per line. Comments start with #.
claude.ai
api.anthropic.com
console.anthropic.com
PROF_EOF
  priv mkdir -p "$PROFILES_DIR" 2>/dev/null
  priv cp "$tmp" "$PROFILES_DIR/$name.conf" 2>/dev/null
  priv chmod 644 "$PROFILES_DIR/$name.conf" 2>/dev/null
  rm -f "$tmp"
}

# ---------------------------------------------------------------------
# Interface / tunnel detection
# ---------------------------------------------------------------------
tunnel_interfaces() {
  ifconfig 2>/dev/null | awk '
    /^[a-z]/ { iface=$1; sub(":", "", iface) }
    /^[[:space:]]*inet / && iface ~ /^(utun|ppp|ipsec|tun|tap)[0-9]*$/ {
      if ($2 != "127.0.0.1" && $2 !~ /^169\.254\./) print iface, $2
    }
  '
}

interface_ipv4() {
  [[ -z "$1" ]] && return 1
  local ip
  ip=$(ifconfig "$1" 2>/dev/null | awk '
    /^[[:space:]]*inet / { if ($2 != "127.0.0.1" && $2 !~ /^169\.254\./) { print $2; exit } }
  ')
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip"
}

is_tunnel_name() { [[ "$1" =~ ^(utun|ppp|ipsec|tun|tap)[0-9]*$ ]]; }

# Sorted list of tunnel interfaces currently present. The block ruleset
# names them explicitly, so if the set changes while we are blocked the
# rules have to be rebuilt (see check_and_react).
tunnel_sig() { tunnel_interfaces | awk '{print $1}' | sort -u | tr '\n' ',' ; }

default_route_interface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

# ---------------------------------------------------------------------
# Liveness probe.
#
# Always BOUND to the tunnel interface. The previous version fell back
# to an unbound ping when the bound one failed — but an unbound ping
# succeeding while the bound one fails is the definition of a leak, and
# it was being reported as "tunnel healthy". That fallback is gone.
#
# ICMP first; if the tunnel drops ICMP, a bound TCP connect to :443 is
# tried instead before declaring the tunnel dead.
# ---------------------------------------------------------------------
probe_tunnel() {
  local iface="$1"
  local t="${PROBE_TIMEOUT_SECONDS:-5}"
  [[ -n "$iface" ]] || return 1

  if [[ "$PROBE_MODE" == "icmp" ]]; then
    ping -c 1 -t "$t" -b "$iface" "${PROBE_HOST:-1.1.1.1}" >/dev/null 2>&1
    return $?
  fi

  # HTTP: the only check that proves end-to-end delivery. A bound TCP
  # connect is NOT sufficient — transparent proxies accept the socket
  # locally before they have an upstream, so a connect succeeds even
  # against a black-holed address. Requiring a real status code back
  # means real bytes traversed the tunnel.
  local code
  code=$(curl --interface "$iface" -s -m "$t" -o /dev/null \
              -w '%{http_code}' "${PROBE_URL:-http://captive.apple.com/hotspot-detect.html}" 2>/dev/null)
  [[ "$code" =~ ^[23] ]]
}

# ---------------------------------------------------------------------
# Master VPN state check.
#
# The old logic short-circuited on "the configured interface has an IP"
# before the probe could ever run, so the documented stale-interface fix
# was unreachable dead code. Here the probe gates EVERY path.
#
# Structural failures (no tunnel, default route left the tunnel) block
# immediately — they are unambiguous. Only probe failures get a
# consecutive-failure threshold, so a single dropped packet does not
# flap the block.
# ---------------------------------------------------------------------
VPN_CHECK_REASON=""
VPN_LIVE_IFACE=""
VPN_LIVE_IP=""
PROBE_FAILS=0
LAST_PROBE_TS=0
LAST_PROBE_OK=1

vpn_is_connected() {
  local iface="" ip="" def_if cand cand_ip now

  VPN_LIVE_IFACE=""
  VPN_LIVE_IP=""
  def_if=$(default_route_interface)

  # 1. configured interface, if it currently holds a usable address
  if [[ -n "$VPN_INTERFACE" ]]; then
    ip=$(interface_ipv4 "$VPN_INTERFACE") && iface="$VPN_INTERFACE"
  fi
  # 2. whatever the default route points at, if it is a tunnel
  if [[ -z "$iface" ]] && is_tunnel_name "$def_if"; then
    ip=$(interface_ipv4 "$def_if") && iface="$def_if"
  fi
  # 3. any live tunnel interface
  if [[ -z "$iface" ]]; then
    while read -r cand cand_ip; do
      [[ -n "$cand" ]] || continue
      iface="$cand"; ip="$cand_ip"; break
    done < <(tunnel_interfaces)
  fi

  if [[ -z "$iface" ]]; then
    VPN_CHECK_REASON="no-tunnel-interface"
    PROBE_FAILS=0
    return 1
  fi

  # Structural: for a full-tunnel VPN the default route must be in the
  # tunnel. If it snapped back to Wi-Fi/Ethernet, traffic is already
  # leaving in the clear — block now, no grace period.
  if [[ "$REQUIRE_DEFAULT_ROUTE" == "1" ]] && ! is_tunnel_name "$def_if"; then
    VPN_CHECK_REASON="default-route-not-tunnel(${def_if:-none})"
    PROBE_FAILS=0
    return 1
  fi

  # Liveness: is the tunnel actually carrying packets?
  if [[ "$PROBE_ENABLED" == "1" ]]; then
    now=$(date +%s)
    if [[ $((now - LAST_PROBE_TS)) -ge ${PROBE_INTERVAL_SECONDS:-5} || "$LAST_PROBE_OK" == "0" ]]; then
      if probe_tunnel "$iface"; then
        PROBE_FAILS=0; LAST_PROBE_OK=1
      else
        PROBE_FAILS=$((PROBE_FAILS + 1)); LAST_PROBE_OK=0
      fi
      LAST_PROBE_TS=$now
    fi
    if [[ "$PROBE_FAILS" -ge "${PROBE_FAIL_THRESHOLD:-2}" ]]; then
      VPN_CHECK_REASON="probe-failed-${PROBE_FAILS}x-on-${iface}(stale/dead tunnel)"
      return 1
    fi
  fi

  VPN_LIVE_IFACE="$iface"
  VPN_LIVE_IP="$ip"
  VPN_CHECK_REASON="up(iface=$iface,route=${def_if:-none},probe=$([[ "$PROBE_ENABLED" == "1" ]] && echo ok || echo off))"
  printf '%s\n' "$iface"
  return 0
}

detect_interface_owner() {
  local iface="$1" owner="" iface_ip candidate

  owner=$(scutil --nc list 2>/dev/null | grep -E '\(Connected\).*\[VPN:' | sed -E 's/^.*"([^"]+)".*$/\1/' | head -n 1)

  if [[ -z "$owner" && -n "$iface" ]]; then
    iface_ip=$(interface_ipv4 "$iface")
    if [[ -n "$iface_ip" ]]; then
      owner=$(lsof -i "@$iface_ip" -sTCP:ESTABLISHED 2>/dev/null | awk 'NR==2{print $1}')
    fi
  fi

  if [[ -z "$owner" ]]; then
    for candidate in \
      "Happ" "Hiddify" "v2RayTun" "WireGuard" "wg-quick" \
      "Outline" "TrustTunnel" "Amnezia" "OpenVPN" "NordVPN" "ExpressVPN" \
      "Surfshark" "ProtonVPN" "Mullvad" "TunnelBear" "Tailscale" \
      "Cloudflare WARP" "Private Internet Access" "Cisco AnyConnect" \
      "sing-box" "clash" "xray"
    do
      if pgrep -fi "$candidate" > /dev/null 2>&1; then
        owner="$candidate"
        break
      fi
    done
  fi

  printf '%s\n' "${owner:-unknown}"
}

# ---------------------------------------------------------------------
# VPN server endpoint learning.
#
# Without this, ALL mode blocks the VPN client's own handshake, so once
# the switch fires the VPN can never reconnect and the machine is
# offline until a human intervenes. While the tunnel is healthy we
# record which public IPs the VPN reaches over the PHYSICAL interface,
# and punch those through the block.
#
# Set ALLOW_VPN_RECONNECT=0 for strict mode (nothing gets out, ever).
# ---------------------------------------------------------------------
learn_vpn_endpoints() {
  [[ "$ALLOW_VPN_RECONNECT" == "1" ]] || return 0
  local tmp phys pair lip rip
  tmp=$(mktemp) || return 0

  # Which addresses live on PHYSICAL interfaces right now.
  phys=$(ifconfig 2>/dev/null | awk '
    /^[a-z]/ { iface=$1; sub(":", "", iface) }
    /^[[:space:]]*inet / {
      if (iface !~ /^(utun|ppp|ipsec|tun|tap|lo)/ && $2 != "127.0.0.1" && $2 !~ /^169\.254\./) print $2
    }')
  [[ -n "$phys" ]] || { rm -f "$tmp"; return 0; }

  # Signal 1: a /32 route pinned to a NON-tunnel interface. This is how
  # most VPN clients keep reaching their own server after handing the
  # default route to the tunnel.
  netstat -rn -f inet 2>/dev/null | awk '
    NF >= 4 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $4 !~ /^(utun|ipsec|ppp|tun|tap|lo)/ { print $1 }
  ' >> "$tmp" 2>/dev/null

  # Signal 2: established sockets whose LOCAL address is a physical
  # interface address. While a full-tunnel VPN is up, essentially all
  # ordinary traffic is bound to the tunnel address instead — so what
  # is left on the physical address is the VPN client talking to its
  # own server.
  #
  # NOTE: `lsof -p PID -i` ORs those selectors rather than ANDing them,
  # so it returns every socket on the machine. That would have punched
  # holes through the block for unrelated hosts. Filtering on the local
  # address avoids depending on process identification entirely.
  while read -r pair; do
    lip="${pair%%->*}"; lip="${lip%%:*}"
    rip="${pair##*->}"; rip="${rip%%:*}"
    printf '%s\n' "$phys" | grep -qx "$lip" || continue
    printf '%s\n' "$rip" >> "$tmp"
  done < <(lsof -nP -i 2>/dev/null \
            | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+->[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+')

  # Rank by how many sockets point at each remote and keep only the top
  # few. A VPN client holds many concurrent connections to its server,
  # while an app that merely bypasses the tunnel holds one or two — so
  # this keeps the hole narrow and aimed at the actual server.
  local merged
  merged=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$tmp" 2>/dev/null \
    | grep -vE '^(0\.|10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|22[4-9]\.|23[0-9]\.|24[0-9]\.|25[0-5]\.)' \
    | sort | uniq -c | sort -rn | head -6 | awk '{print $2}')
  rm -f "$tmp"

  if [[ -n "$merged" ]]; then
    printf '%s\n' "$merged" | priv tee "$ENDPOINTS_FILE" >/dev/null 2>&1
    priv chmod 644 "$ENDPOINTS_FILE" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------
# pf enforcement
# ---------------------------------------------------------------------
pf_enabled() {
  priv /sbin/pfctl -s info 2>/dev/null | head -1 | grep -q "Enabled"
}

anchor_registered() {
  priv /sbin/pfctl -s Anchors 2>/dev/null | grep -q "$PF_ANCHOR_NAME"
}

anchor_rule_count() {
  priv /sbin/pfctl -a "$PF_ANCHOR_NAME" -s rules 2>/dev/null | grep -c '^block'
}

# Is the block genuinely in force right now? Checked every tick while
# the VPN is down. The old version only acted on state TRANSITIONS, so
# anything that flushed pf underneath it — waking from sleep, another
# app reloading /etc/pf.conf, Docker, Little Snitch — silently removed
# the block and it was never reapplied.
block_is_enforced() {
  pf_enabled || return 1
  anchor_registered || return 1
  local n
  n=$(anchor_rule_count)
  [[ "${n:-0}" -gt 0 ]]
}

# Register our anchor inside /etc/pf.conf itself rather than replacing
# the main ruleset with our own synthetic one. The old approach wrote a
# private pf_main.conf listing only Apple's anchors plus ours, so
# loading it silently dropped every other tool's anchors — and any tool
# reloading the real /etc/pf.conf silently dropped ours.
ensure_anchor_registered() {
  priv mkdir -p "$(dirname "$PF_ANCHOR_FILE")" 2>/dev/null
  [[ -f "$PF_ANCHOR_FILE" ]] || printf '# vpn_kill_switch anchor\n' | priv tee "$PF_ANCHOR_FILE" >/dev/null 2>&1

  if ! grep -q "load anchor \"$PF_ANCHOR_NAME\"" "$PF_CONF" 2>/dev/null; then
    [[ -f "$PF_CONF_BAK" ]] || priv cp "$PF_CONF" "$PF_CONF_BAK" 2>/dev/null
    {
      printf '\n%s\n' "$PF_MARK"
      printf 'anchor "%s"\n' "$PF_ANCHOR_NAME"
      printf 'load anchor "%s" from "%s"\n' "$PF_ANCHOR_NAME" "$PF_ANCHOR_FILE"
    } | priv tee -a "$PF_CONF" >/dev/null 2>&1
    log "registered pf anchor in $PF_CONF (backup at $PF_CONF_BAK)"
  fi

  priv /sbin/pfctl -f "$PF_CONF" >/dev/null 2>&1
}

unregister_anchor() {
  [[ -f "$PF_CONF" ]] || return 0
  local tmp
  tmp=$(mktemp) || return 1
  grep -v -e "^${PF_MARK}$" \
          -e "^anchor \"$PF_ANCHOR_NAME\"$" \
          -e "^load anchor \"$PF_ANCHOR_NAME\"" "$PF_CONF" > "$tmp" 2>/dev/null
  priv cp "$tmp" "$PF_CONF" 2>/dev/null
  rm -f "$tmp"
  priv /sbin/pfctl -f "$PF_CONF" >/dev/null 2>&1
}

BLOCK_TUNNEL_SIG=""
build_rules_all() {
  local out="$1" ip
  BLOCK_TUNNEL_SIG="$(tunnel_sig)"
  {
    echo "pass out quick on lo0 all"

    # Allow traffic out over the tunnel interfaces themselves.
    #
    # This is NOT a leak: anything handed to a live tunnel leaves
    # encrypted, and anything handed to a dead tunnel is discarded by
    # the kernel because no process is reading the other end. Traffic
    # only leaks when it exits a PHYSICAL interface, and the final
    # block rule still catches that.
    #
    # It is also required for recovery. Without it the block would also
    # block our own liveness probe, the probe could never succeed
    # again, and the switch would stay latched down forever after the
    # first drop.
    local _tif
    for _tif in $(tunnel_interfaces | awk '{print $1}' | sort -u); do
      echo "pass out quick on $_tif all"
    done

    if [[ "$ALLOW_VPN_RECONNECT" == "1" && -s "$ENDPOINTS_FILE" ]]; then
      while IFS= read -r ip; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        echo "pass out quick on ! lo0 to $ip"
      done < "$ENDPOINTS_FILE"
    fi

    # Blocked before the LAN passes below, so DNS cannot leak to the
    # router (and from there to the ISP) while the tunnel is down.
    # Loopback resolvers still work — the lo0 pass above is quick.
    if [[ "$BLOCK_DNS" == "1" ]]; then
      echo "block drop out quick proto tcp from any to any port 53"
      echo "block drop out quick proto udp from any to any port 53"
      echo "block drop out quick proto tcp from any to any port 853"
      echo "block drop out quick proto udp from any to any port 853"
    fi

    if [[ "$ALLOW_LAN" == "1" ]]; then
      echo "pass out quick on ! lo0 to 10.0.0.0/8"
      echo "pass out quick on ! lo0 to 172.16.0.0/12"
      echo "pass out quick on ! lo0 to 192.168.0.0/16"
      echo "pass out quick on ! lo0 to 169.254.0.0/16"
      echo "pass out quick on ! lo0 to 224.0.0.0/4"
      echo "pass out quick on ! lo0 inet6 to fe80::/10"
      echo "pass out quick on ! lo0 inet6 to ff00::/8"
    fi

    echo "block drop out quick on ! lo0 all"
  } > "$out"
}

build_rules_list() {
  local out="$1" profile="$2"
  local profile_file="$PROFILES_DIR/$profile.conf"
  local entry ip
  : > "$out"
  [[ -f "$profile_file" ]] || return 0
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%%#*}"
    entry=$(printf '%s' "$entry" | sed 's/[[:space:]]*$//;s/^[[:space:]]*//')
    [[ -z "$entry" ]] && continue
    if [[ "$entry" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
      echo "block drop out quick from any to $entry" >> "$out"
    else
      for ip in $(dig +short "$entry" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); do
        echo "block drop out quick from any to $ip" >> "$out"
      done
    fi
  done < "$profile_file"
}

# $1: "flush" to also drop existing pf states.
#
# Flushing states matters: pf keeps state for connections established
# before the block, so without this an in-flight download or open
# WebSocket keeps streaming over your real IP after the VPN drops. We
# only flush on the transition into blocked, never on re-assert, so we
# do not tear down LAN connections once a second.
apply_block() {
  local flush="$1"
  local tmp_rules
  tmp_rules=$(mktemp) || return 1

  if [[ "$MODE" == "ALL" ]]; then
    build_rules_all "$tmp_rules"
  else
    build_rules_list "$tmp_rules" "$ACTIVE_PROFILE"
    if [[ ! -s "$tmp_rules" ]]; then
      log "WARN: LIST profile '$ACTIVE_PROFILE' produced zero rules — nothing blocked"
    fi
  fi

  priv cp "$tmp_rules" "$PF_ANCHOR_FILE" 2>/dev/null
  priv chmod 644 "$PF_ANCHOR_FILE" 2>/dev/null
  rm -f "$tmp_rules"

  anchor_registered || ensure_anchor_registered

  if ! priv /sbin/pfctl -a "$PF_ANCHOR_NAME" -f "$PF_ANCHOR_FILE" >/dev/null 2>&1; then
    log "ERROR: pfctl failed to load anchor rules"
    return 1
  fi

  pf_enabled || priv /sbin/pfctl -e >/dev/null 2>&1

  if [[ "$flush" == "flush" ]]; then
    priv /sbin/pfctl -F states >/dev/null 2>&1
    log "flushed pf state table (kills connections established before the block)"
  fi

  log "block applied (mode=$MODE, rules=$(anchor_rule_count))"
}

clear_block() {
  printf '# vpn_kill_switch anchor (idle)\n' | priv tee "$PF_ANCHOR_FILE" >/dev/null 2>&1
  priv /sbin/pfctl -a "$PF_ANCHOR_NAME" -F rules >/dev/null 2>&1
  log "block cleared"
}

# ---------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------
MON_PID=""

start_route_monitor() {
  if [[ -n "$MON_PID" ]]; then
    pkill -P "$MON_PID" 2>/dev/null
    kill "$MON_PID" 2>/dev/null
  fi
  # stdout of the whole loop is opened on the FIFO once, not reopened
  # per line. We hold the read end (fd 3) open for the process lifetime,
  # so this open never blocks.
  {
    /sbin/route -n monitor 2>/dev/null | while read -r _; do echo "CHANGE"; done > "$FIFO"
  } &
  MON_PID=$!
}

daemon_self_check() {
  local p mode_bits
  for p in "$0" "$CONFIG_FILE"; do
    [[ -e "$p" ]] || continue
    if [[ "$(stat -f%u "$p" 2>/dev/null)" != "0" ]]; then
      echo "REFUSING TO RUN: $p is not owned by root" >&2
      return 1
    fi
    mode_bits=$(stat -f%Lp "$p" 2>/dev/null)
    if [[ "$mode_bits" =~ [2367]$ || "$mode_bits" =~ [2367].$ ]]; then
      echo "REFUSING TO RUN: $p is group- or world-writable ($mode_bits)" >&2
      return 1
    fi
  done
  return 0
}

run_daemon() {
  load_config
  if [[ "${CONFIG_MIGRATED:-0}" == "1" ]]; then
    save_config
    log "config migrated to v2: probe interval=1s threshold=1 timeout=3s"
  fi

  mkdir -p "$STATE_DIR" "$PROFILES_DIR" 2>/dev/null
  touch "$LOG_FILE" 2>/dev/null
  rotate_log "$LOG_FILE"
  rotate_log "$DAEMON_ERR_LOG"
  rotate_log "$DAEMON_OUT_LOG"

  # If the state directory is not there, something is fundamentally
  # wrong with the install. Fail loudly and let launchd throttle us,
  # rather than spinning silently (the 18 GB error-log failure mode).
  if [[ ! -d "$STATE_DIR" ]]; then
    echo "FATAL: state dir $STATE_DIR missing — reinstall from the menu" >&2
    sleep 10
    exit 78
  fi

  daemon_self_check || { sleep 30; exit 77; }

  {
    echo "================================================================"
    echo "DAEMON STARTED $(date '+%Y-%m-%d %H:%M:%S') pid=$$ uid=$(id -u)"
    echo "version=$SCRIPT_VERSION mode=$MODE iface=${VPN_INTERFACE:-auto}"
    echo "probe=${PROBE_ENABLED} host=${PROBE_HOST} interval=${PROBE_INTERVAL_SECONDS}s threshold=${PROBE_FAIL_THRESHOLD}"
    echo "require_default_route=$REQUIRE_DEFAULT_ROUTE allow_lan=$ALLOW_LAN block_dns=$BLOCK_DNS allow_reconnect=$ALLOW_VPN_RECONNECT"
    echo "autostart=$AUTOSTART"
    echo "================================================================"
  } >> "$LOG_FILE"

  ensure_anchor_registered

  rm -f "$FIFO" 2>/dev/null
  mkfifo -m 600 "$FIFO" 2>/dev/null || { echo "FATAL: cannot create $FIFO" >&2; sleep 10; exit 78; }
  chown root:wheel "$FIFO" 2>/dev/null

  # THE fix for the stalled loop. Opening a FIFO read-only blocks in
  # open() until a writer appears, and `read -t 1` times out the read,
  # not the open — so the old "1s fail-safe poll" never ran between
  # route events, and when the writer died it busy-spun instead.
  # Opening read-write never blocks and never sees EOF.
  exec 3<> "$FIFO"

  start_route_monitor
  log "route monitor started (pid ${MON_PID:-?}), 1s poll active"

  local last_state="" ev now last_tick last_sec ticks_this_sec
  local last_endpoint_scan=0 last_idle_audit=0 loop_count=0 force_reassert=0
  local last_heartbeat=0
  last_tick=$(date +%s)
  last_sec="$last_tick"
  ticks_this_sec=0

  check_and_react() {
    local state want_block

    if vpn_is_connected >/dev/null 2>&1; then
      state="up"
      if [[ -n "$VPN_LIVE_IFACE" && "$VPN_LIVE_IFACE" != "$VPN_INTERFACE" ]]; then
        log "interface tracking: ${VPN_INTERFACE:-none} -> $VPN_LIVE_IFACE"
        VPN_INTERFACE="$VPN_LIVE_IFACE"
        VPN_APP_NAME=$(detect_interface_owner "$VPN_LIVE_IFACE")
        save_config
      fi
    else
      state="down"
    fi

    if [[ "$ALWAYS_ARMED" == "1" ]]; then
      want_block=1
    elif [[ "$state" == "down" ]]; then
      want_block=1
    else
      want_block=0
    fi

    if [[ "$state" != "$last_state" ]]; then
      log "event: vpn -> $state (reason=$VPN_CHECK_REASON, default_if=$(default_route_interface))"
      last_state="$state"
      if [[ "$want_block" == "1" ]]; then
        # Flush states only when we are newly blocking, so we do not
        # tear down healthy connections on every transition.
        if block_is_enforced; then apply_block; else apply_block flush; fi
      else
        clear_block
      fi
      force_reassert=0
      return
    fi

    # Re-assert every tick: desired state is checked against reality,
    # not just against the last transition. This is what survives
    # sleep/wake and third parties reloading pf.
    if [[ "$want_block" == "1" ]]; then
      if [[ "$force_reassert" == "1" ]] || ! block_is_enforced; then
        log "re-asserting block (missing or forced; reason=$VPN_CHECK_REASON)"
        apply_block
      elif [[ "$MODE" == "ALL" && "$(tunnel_sig)" != "$BLOCK_TUNNEL_SIG" ]]; then
        # A utun appeared or vanished (VPN reconnecting). The ruleset
        # names tunnels explicitly, so rebuild — otherwise the probe on
        # the new tunnel stays blocked and recovery is never detected.
        log "tunnel set changed ($BLOCK_TUNNEL_SIG -> $(tunnel_sig)) — rebuilding rules"
        apply_block
      fi
    else
      if [[ "$force_reassert" == "1" ]]; then
        ensure_anchor_registered
      fi
      if [[ $((now - last_idle_audit)) -ge 15 ]]; then
        last_idle_audit=$now
        if block_is_enforced; then
          log "WARN: block was active while VPN is up — clearing"
          clear_block
        fi
      fi
    fi

    # Learn the VPN server endpoints whenever the tunnel is healthy.
    # Required for reconnection once the block is on.
    if [[ "$state" == "up" && $((now - last_endpoint_scan)) -ge 30 ]]; then
      last_endpoint_scan=$now
      learn_vpn_endpoints
    fi
    force_reassert=0
  }

  now=$(date +%s)
  check_and_react

  while true; do
    # Returns within 1s whether or not a route event arrives.
    read -t 1 -r ev <&3

    now=$(date +%s)

    # Sleep/wake detection: a long gap between ticks means the machine
    # was suspended. On wake, the network stack, the route monitor and
    # pf may all be in a different state than when we went down, so
    # force a full re-assert instead of trusting cached state.
    if [[ $((now - last_tick)) -gt 10 ]]; then
      log "WAKE: $((now - last_tick))s gap (sleep/suspend) — forcing full re-assert"
      force_reassert=1
      PROBE_FAILS=0; LAST_PROBE_TS=0; LAST_PROBE_OK=1
      start_route_monitor
    fi
    last_tick=$now

    # Rate limit. Proxy-type VPNs rewrite routes continuously, so
    # route -n monitor is a firehose, not an occasional nudge. Measured
    # on a live setup: an 8/sec cap let the loop run at 6.5 ticks/sec
    # and cost ~20% CPU permanently. Two checks per second keeps the
    # worst-case reaction to a route event at 0.5s while cutting the
    # fork rate by more than 3x. The 1s poll below is unaffected.
    if [[ "$now" == "$last_sec" ]]; then
      ticks_this_sec=$((ticks_this_sec + 1))
      [[ "$ticks_this_sec" -gt 2 ]] && continue
    else
      last_sec="$now"
      ticks_this_sec=1
    fi

    # Restart the monitor if it died; the poll keeps working regardless.
    if [[ -n "$MON_PID" ]] && ! kill -0 "$MON_PID" 2>/dev/null; then
      start_route_monitor
      log "route monitor restarted (pid ${MON_PID:-?})"
    fi

    check_and_react

    if [[ $((now - last_heartbeat)) -ge 300 ]]; then
      last_heartbeat=$now
      log "heartbeat: state=${last_state:-unknown} iface=${VPN_INTERFACE:-none} default_if=$(default_route_interface) blocked=$(block_is_enforced && echo yes || echo no) ticks=${loop_count} ver=$SCRIPT_VERSION"
      loop_count=0
      rotate_log "$LOG_FILE"
      rotate_log "$DAEMON_ERR_LOG"
    fi
    loop_count=$((loop_count + 1))
  done
}

# ---------------------------------------------------------------------
# Install / start / stop
#
# Autostart is a setting, not a fact of installation:
#
#   AUTOSTART=1  plist lives in /Library/LaunchDaemons -> launchd starts
#                it at boot.
#   AUTOSTART=0  plist lives in the state dir and is bootstrapped only
#                for the current boot. Nothing starts on its own.
#
# Either way the daemon runs as root under launchd, so KeepAlive still
# restarts it if it crashes.
# ---------------------------------------------------------------------
active_plist_path() {
  if [[ "$AUTOSTART" == "1" ]]; then printf '%s\n' "$PLIST_BOOT"; else printf '%s\n' "$PLIST_MANUAL"; fi
}

daemon_process_running() { pgrep -f "vpn_kill_switch.sh --daemon" >/dev/null 2>&1; }
service_loaded() { priv launchctl print "system/$PLIST_LABEL" >/dev/null 2>&1; }
autostart_armed() { [[ -f "$PLIST_BOOT" ]]; }

install_files() {
  priv mkdir -p "$LIBEXEC_DIR" "$STATE_DIR" "$PROFILES_DIR" "$(dirname "$PF_ANCHOR_FILE")" 2>/dev/null
  priv cp "$SELF_PATH" "$INSTALLED_SCRIPT" || return 1
  priv chown root:wheel "$INSTALLED_SCRIPT"
  priv chmod 755 "$INSTALLED_SCRIPT"
  priv chown root:wheel "$STATE_DIR" "$PROFILES_DIR"
  priv chmod 755 "$STATE_DIR" "$PROFILES_DIR"
  priv touch "$LOG_FILE"
  priv chmod 644 "$LOG_FILE"
  save_config
  [[ -f "$PROFILES_DIR/claude.conf" ]] || default_profile "claude"
}

write_plist() {
  local path="$1" tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALLED_SCRIPT}</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>UserName</key><string>root</string>
    <key>StandardOutPath</key><string>${DAEMON_OUT_LOG}</string>
    <key>StandardErrorPath</key><string>${DAEMON_ERR_LOG}</string>
</dict>
</plist>
PLIST_EOF
  priv mkdir -p "$(dirname "$path")" 2>/dev/null
  priv cp "$tmp" "$path" || { rm -f "$tmp"; return 1; }
  priv chown root:wheel "$path"
  priv chmod 644 "$path"
  rm -f "$tmp"
}

stop_daemon() {
  priv launchctl bootout "system/$PLIST_LABEL" >/dev/null 2>&1
  priv launchctl unload "$PLIST_BOOT" >/dev/null 2>&1
  priv launchctl unload "$PLIST_MANUAL" >/dev/null 2>&1
  priv pkill -f "vpn_kill_switch.sh --daemon" >/dev/null 2>&1
  sleep 1
  priv pkill -9 -f "vpn_kill_switch.sh --daemon" >/dev/null 2>&1
  # Never leave the machine firewalled with nothing left to unfirewall it.
  clear_block
}

start_daemon() {
  local plist rc

  install_files || { printf "  ${RED}✗ Could not install to %s${RESET}\n" "$LIBEXEC_DIR"; return 1; }

  # Make the plist location match the autostart setting.
  if [[ "$AUTOSTART" == "1" ]]; then
    priv rm -f "$PLIST_MANUAL" 2>/dev/null
  else
    priv rm -f "$PLIST_BOOT" 2>/dev/null
  fi
  plist="$(active_plist_path)"

  priv launchctl bootout "system/$PLIST_LABEL" >/dev/null 2>&1
  priv pkill -9 -f "vpn_kill_switch.sh --daemon" >/dev/null 2>&1
  sleep 1

  write_plist "$plist" || { printf "  ${RED}✗ Could not write %s${RESET}\n" "$plist"; return 1; }

  priv launchctl bootstrap system "$plist" >/dev/null 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    priv launchctl load -w "$plist" >/dev/null 2>&1
    rc=$?
  fi
  sleep 2

  if daemon_process_running; then
    return 0
  fi
  return 1
}

restart_daemon_if_running() {
  if daemon_process_running || service_loaded; then
    start_daemon >/dev/null 2>&1
  fi
}

uninstall_all() {
  stop_daemon
  priv rm -f "$PLIST_BOOT" "$PLIST_MANUAL" 2>/dev/null
  unregister_anchor
  priv rm -f "$PF_ANCHOR_FILE" 2>/dev/null
  priv rm -f "$FIFO" 2>/dev/null
}

# ---------------------------------------------------------------------
# Interactive UI
# ---------------------------------------------------------------------
detect_interface_interactive() {
  header
  printf "${BOLD}DETECT VPN INTERFACE${RESET}\n"; hr
  printf "  ${DIM}Snapshot tunnel interfaces before/after you toggle your VPN.${RESET}\n\n"
  printf "  Step 1: Turn your VPN OFF, then press Enter.\n"
  read -r
  local before after new_iface owner manual
  before=$(tunnel_interfaces | awk '{print $1}' | sort)

  printf "  Step 2: Turn your VPN ON, wait for it to connect, then press Enter.\n"
  read -r
  after=$(tunnel_interfaces | awk '{print $1}' | sort)

  new_iface=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n 1)

  if [[ -n "$new_iface" ]]; then
    owner=$(detect_interface_owner "$new_iface")
    printf "\n  ${GREEN}✓ Detected interface: %s${RESET}\n" "$new_iface"
    printf "  ${GREEN}✓ Likely app/service: %s${RESET}\n" "$owner"
    VPN_INTERFACE="$new_iface"
    VPN_APP_NAME="$owner"
    save_config
    printf "\n  ${DIM}Testing tunnel liveness probe through %s...${RESET}\n" "$new_iface"
    if probe_tunnel "$new_iface"; then
      printf "  ${GREEN}✓ Probe OK — liveness detection will work.${RESET}\n"
    else
      printf "  ${YELLOW}⚠ Probe failed even though the VPN is up.${RESET}\n"
      printf "  ${YELLOW}  Pick a different probe host in Settings, or the switch${RESET}\n"
      printf "  ${YELLOW}  will block while you are actually connected.${RESET}\n"
    fi
    restart_daemon_if_running
  else
    printf "\n  ${RED}Could not auto-detect a new interface.${RESET}\n"
    printf "  Active tunnel-like interfaces currently up:\n\n"
    tunnel_interfaces | sed 's/^/    /'
    printf "\n  Enter the interface name manually (or blank to cancel): "
    read -r manual
    if [[ -n "$manual" ]]; then
      VPN_INTERFACE="$manual"
      VPN_APP_NAME=$(detect_interface_owner "$manual")
      save_config
      restart_daemon_if_running
      printf "\n  ${GREEN}✓ Saved: %s${RESET}\n" "$manual"
    fi
  fi
  press_enter
}

screen_manual_interface() {
  header
  printf "${BOLD}SET VPN INTERFACE MANUALLY${RESET}\n"; hr
  printf "  Active tunnel-like interfaces right now:\n\n"
  local iface ip owner manual
  while read -r iface ip; do
    [[ -z "$iface" ]] && continue
    owner=$(detect_interface_owner "$iface")
    printf "    ${CYAN}%-8s${RESET} %-16s ${DIM}%s${RESET}\n" "$iface" "$ip" "$owner"
  done < <(tunnel_interfaces)
  printf "\n  ${DIM}Leave blank to auto-track whichever tunnel is live (recommended —${RESET}\n"
  printf "  ${DIM}utun numbers change on every reconnect).${RESET}\n"
  printf "\n  Enter interface name (e.g. utun4), or blank to clear: "
  read -r manual
  VPN_INTERFACE="$manual"
  [[ -n "$manual" ]] && VPN_APP_NAME=$(detect_interface_owner "$manual")
  save_config
  restart_daemon_if_running
  printf "\n${GREEN}✓ Saved: %s${RESET}\n" "${manual:-<auto>}"
  press_enter
}

screen_set_mode() {
  header
  printf "${BOLD}SET MODE${RESET}\n"; hr
  printf "  [1] ALL   — block all outbound traffic when the tunnel dies\n"
  printf "  [2] LIST  — block only a domain/IP profile\n"
  printf "\n  ${DIM}LIST mode is best effort only: it resolves the domains once, at${RESET}\n"
  printf "  ${DIM}block time. Anything using a different IP, DNS-over-HTTPS, or a${RESET}\n"
  printf "  ${DIM}CDN that rotates addresses will get through. Use ALL if you need${RESET}\n"
  printf "  ${DIM}an actual guarantee.${RESET}\n"
  printf "\n  [0] Cancel\n\n  > "
  local c
  read -r c
  case "$c" in
    1) MODE="ALL"; save_config; restart_daemon_if_running; printf "\n${GREEN}✓ Mode set to ALL.${RESET}\n" ;;
    2) MODE="LIST"; save_config; printf "\n${GREEN}✓ Mode set to LIST.${RESET}\n"; screen_choose_profile; restart_daemon_if_running ;;
  esac
  press_enter
}

# bash 3.2 on macOS has no associative arrays; the old `declare -A` here
# errored out on every run. Parallel indexed arrays instead.
screen_choose_profile() {
  header
  printf "${BOLD}PROFILES${RESET}\n"; hr
  local p name marker i=0 c
  local names=()
  for p in "$PROFILES_DIR"/*.conf; do
    [[ -f "$p" ]] || continue
    name=$(basename "$p" .conf)
    i=$((i + 1))
    names[$i]="$name"
    marker=""
    [[ "$name" == "$ACTIVE_PROFILE" ]] && marker=" (active)"
    printf "  [%d] %s%s\n" "$i" "$name" "$marker"
  done
  printf "  [n] Create new profile\n  [0] Cancel\n\n  > "
  read -r c
  if [[ "$c" == "n" ]]; then
    local newname tmp
    printf "  Profile name: "
    read -r newname
    [[ "$newname" =~ ^[A-Za-z0-9._-]+$ ]] || { printf "\n${RED}Invalid name.${RESET}\n"; return; }
    default_profile "$newname"
    tmp=$(mktemp); cp "$PROFILES_DIR/$newname.conf" "$tmp" 2>/dev/null
    printf "\n  Opening editor — one domain or IP per line, save & exit.\n"
    sleep 1
    ${EDITOR:-nano} "$tmp"
    priv cp "$tmp" "$PROFILES_DIR/$newname.conf"; priv chmod 644 "$PROFILES_DIR/$newname.conf"; rm -f "$tmp"
    ACTIVE_PROFILE="$newname"
    save_config
    printf "\n${GREEN}✓ Created and activated profile: %s${RESET}\n" "$newname"
  elif [[ "$c" =~ ^[0-9]+$ && -n "${names[$c]}" ]]; then
    ACTIVE_PROFILE="${names[$c]}"
    save_config
    printf "\n${GREEN}✓ Active profile set to: %s${RESET}\n" "$ACTIVE_PROFILE"
  fi
}

screen_edit_profile() {
  screen_choose_profile
  printf "\n  Edit the active profile (%s) now? [y/N]: " "$ACTIVE_PROFILE"
  local yn tmp
  read -r yn
  if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
    tmp=$(mktemp)
    cp "$PROFILES_DIR/$ACTIVE_PROFILE.conf" "$tmp" 2>/dev/null
    ${EDITOR:-nano} "$tmp"
    priv cp "$tmp" "$PROFILES_DIR/$ACTIVE_PROFILE.conf"
    priv chmod 644 "$PROFILES_DIR/$ACTIVE_PROFILE.conf"
    rm -f "$tmp"
    restart_daemon_if_running
    printf "\n${GREEN}✓ Saved.${RESET}\n"
  fi
  press_enter
}

toggle() { [[ "$1" == "1" ]] && printf "1" || printf "0"; }
onoff()  { [[ "$1" == "1" ]] && printf "${GREEN}on${RESET}" || printf "${GRAY}off${RESET}"; }

screen_settings() {
  local c
  while true; do
    header
    printf "${BOLD}SETTINGS${RESET}\n"; hr
    printf "  ${BOLD}[a]${RESET} Start at boot .................. %b\n" "$(onoff "$AUTOSTART")"
    printf "      ${DIM}off = the switch only runs when you turn it on from this menu${RESET}\n\n"
    printf "  ${BOLD}[p]${RESET} Tunnel liveness probe .......... %b\n" "$(onoff "$PROBE_ENABLED")"
    printf "  ${BOLD}[m]${RESET} Probe method ................... ${CYAN}%s${RESET}%b\n" "$PROBE_MODE" \
      "$([[ "$PROBE_MODE" == "icmp" ]] && printf " ${YELLOW}(unreliable on proxy-type VPNs)${RESET}" || printf "")"
    printf "  ${BOLD}[h]${RESET} Probe target ................... ${CYAN}%s${RESET}\n" \
      "$([[ "$PROBE_MODE" == "icmp" ]] && printf '%s' "$PROBE_HOST" || printf '%s' "$PROBE_URL")"
    printf "  ${BOLD}[i]${RESET} Probe interval ................. ${CYAN}%ss${RESET}\n" "$PROBE_INTERVAL_SECONDS"
    printf "  ${BOLD}[t]${RESET} Probe timeout .................. ${CYAN}%ss${RESET}\n" "$PROBE_TIMEOUT_SECONDS"
    printf "  ${BOLD}[n]${RESET} Failures before blocking ....... ${CYAN}%s${RESET}\n\n" "$PROBE_FAIL_THRESHOLD"
    printf "  ${BOLD}[r]${RESET} Require default route in tunnel  %b\n" "$(onoff "$REQUIRE_DEFAULT_ROUTE")"
    printf "      ${DIM}turn off only for split-tunnel VPNs${RESET}\n\n"
    printf "  ${BOLD}[l]${RESET} Allow LAN while blocked ........ %b\n" "$(onoff "$ALLOW_LAN")"
    printf "  ${BOLD}[d]${RESET} Block DNS while blocked ........ %b\n" "$(onoff "$BLOCK_DNS")"
    printf "  ${BOLD}[v]${RESET} Allow VPN to reconnect ......... %b\n" "$(onoff "$ALLOW_VPN_RECONNECT")"
    printf "      ${DIM}off = strict; nothing gets out, including your VPN client,${RESET}\n"
    printf "      ${DIM}so you must clear the block by hand to get back online${RESET}\n\n"
    printf "  ${BOLD}[k]${RESET} Always armed (zero latency) .... %b\n" "$(onoff "$ALWAYS_ARMED")"
    printf "      ${DIM}on  = the block never comes down; traffic is only ever let out${RESET}\n"
    printf "      ${DIM}      over the tunnel, so there is no detection delay at all —${RESET}\n"
    printf "      ${DIM}      but you cannot get online at all without the VPN${RESET}\n"
    printf "      ${DIM}off = block is applied reactively when the tunnel dies (~1.5s)${RESET}\n"
    hr
    printf "  ${BOLD}[0]${RESET} Back\n\n  > "
    read -r c
    case "$c" in
      a) AUTOSTART=$((1 - AUTOSTART))
         save_config
         if [[ "$AUTOSTART" == "1" ]]; then
           if daemon_process_running; then start_daemon >/dev/null 2>&1; fi
           printf "\n  ${GREEN}✓ Will start at boot.${RESET}\n"
           [[ -f "$PLIST_BOOT" ]] || printf "  ${DIM}Takes effect once you turn the switch on.${RESET}\n"
         else
           priv rm -f "$PLIST_BOOT" 2>/dev/null
           if daemon_process_running; then start_daemon >/dev/null 2>&1; fi
           printf "\n  ${GREEN}✓ Will NOT start at boot.${RESET}\n"
         fi
         sleep 1 ;;
      p) PROBE_ENABLED=$((1 - PROBE_ENABLED)); save_config; restart_daemon_if_running ;;
      r) REQUIRE_DEFAULT_ROUTE=$((1 - REQUIRE_DEFAULT_ROUTE)); save_config; restart_daemon_if_running ;;
      l) ALLOW_LAN=$((1 - ALLOW_LAN)); save_config; restart_daemon_if_running ;;
      d) BLOCK_DNS=$((1 - BLOCK_DNS)); save_config; restart_daemon_if_running ;;
      v) ALLOW_VPN_RECONNECT=$((1 - ALLOW_VPN_RECONNECT)); save_config; restart_daemon_if_running ;;
      k) ALWAYS_ARMED=$((1 - ALWAYS_ARMED)); save_config; restart_daemon_if_running
         if [[ "$ALWAYS_ARMED" == "1" ]]; then
           printf "\n  ${YELLOW}Always armed: traffic will ONLY be allowed over the tunnel.${RESET}\n"
           printf "  ${DIM}If your VPN cannot connect, turn the switch off with [f] to${RESET}\n"
           printf "  ${DIM}get back online, or run: sudo %s --unblock${RESET}\n" "$INSTALLED_SCRIPT"
           sleep 3
         fi ;;
      m) [[ "$PROBE_MODE" == "http" ]] && PROBE_MODE="icmp" || PROBE_MODE="http"
         save_config; restart_daemon_if_running ;;
      h) if [[ "$PROBE_MODE" == "icmp" ]]; then
           printf "\n  New probe host (IP): "
         else
           printf "\n  New probe URL: "
         fi
         local nh; read -r nh
         if [[ -n "$nh" ]]; then
           if [[ "$PROBE_MODE" == "icmp" ]]; then PROBE_HOST="$nh"; else PROBE_URL="$nh"; fi
           save_config; restart_daemon_if_running
           printf "  Testing through %s... " "${VPN_INTERFACE:-current tunnel}"
           if probe_tunnel "${VPN_INTERFACE:-$(tunnel_interfaces | awk 'NR==1{print $1}')}"; then
             printf "${GREEN}reachable${RESET}\n"
           else
             printf "${YELLOW}not reachable right now${RESET}\n"
           fi
           sleep 2
         fi ;;
      i) printf "\n  Probe interval in seconds: "; local ni; read -r ni
         [[ "$ni" =~ ^[0-9]+$ && "$ni" -gt 0 ]] && { PROBE_INTERVAL_SECONDS="$ni"; save_config; restart_daemon_if_running; } ;;
      t) printf "\n  Probe timeout in seconds: "; local nt; read -r nt
         [[ "$nt" =~ ^[0-9]+$ && "$nt" -gt 0 ]] && { PROBE_TIMEOUT_SECONDS="$nt"; save_config; restart_daemon_if_running; } ;;
      n) printf "\n  Consecutive probe failures before blocking: "; local nf; read -r nf
         [[ "$nf" =~ ^[0-9]+$ && "$nf" -gt 0 ]] && { PROBE_FAIL_THRESHOLD="$nf"; save_config; restart_daemon_if_running; } ;;
      0|"") return ;;
    esac
  done
}

screen_about() {
  header
  printf "${BOLD}HOW DETECTION WORKS${RESET}\n"; hr
  printf "  The daemon re-evaluates every ${CYAN}1 second${RESET}, and ${CYAN}route -n monitor${RESET}\n"
  printf "  wakes it immediately on any route/interface change.\n\n"
  printf "  The VPN counts as ${GREEN}UP${RESET} only if ${BOLD}all${RESET} of these hold:\n\n"
  printf "    1. a tunnel interface (utun/ipsec/ppp/tun) has a real IPv4\n"
  printf "    2. the default route points into a tunnel  ${DIM}(if enabled)${RESET}\n"
  printf "    3. an HTTP request bound to that tunnel comes back  ${DIM}(if enabled)${RESET}\n\n"
  printf "  ${YELLOW}Why #3 matters:${RESET} when a VPN app crashes it usually leaves the\n"
  printf "  utun interface behind, still holding a valid-looking IP. Checks 1\n"
  printf "  and 2 can both pass against that corpse. Only a probe ${BOLD}bound to${RESET}\n"
  printf "  ${BOLD}the interface${RESET} can tell a live tunnel from a dead one — an\n"
  printf "  unbound ping would succeed over your real connection and report\n"
  printf "  'healthy' while you are leaking.\n\n"
  printf "  ${YELLOW}Why the probe is HTTP, not ping:${RESET} on transparent/fake-IP TUN\n"
  printf "  proxies (Happ, sing-box, Hiddify, clash) a bound ping fails even\n"
  printf "  when the tunnel is perfectly healthy, and a bound TCP connect\n"
  printf "  succeeds even against a black-holed address, because the local\n"
  printf "  proxy accepts the socket before it has an upstream. Only a real\n"
  printf "  HTTP round trip proves bytes came back through the tunnel.\n\n"
  printf "  Structural failures (1 and 2) block ${BOLD}immediately${RESET}. Probe failures\n"
  printf "  need ${CYAN}%s${RESET} consecutive misses, so one dropped packet does not flap\n" "$PROBE_FAIL_THRESHOLD"
  printf "  the block.\n\n"
  printf "  Blocking also flushes the pf state table, which terminates\n"
  printf "  connections opened before the drop. Without that, an in-flight\n"
  printf "  download keeps streaming over your real IP.\n\n"
  printf "  The block is re-verified every tick, not just on state changes,\n"
  printf "  so it survives sleep/wake and other software reloading pf.\n"
  press_enter
}

screen_logs() {
  header
  printf "${BOLD}LOGS${RESET}\n"; hr
  printf "  ${BOLD}Kill switch log${RESET} ${DIM}(%s)${RESET}\n" "$LOG_FILE"
  tail -n 25 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
  hr
  printf "  ${BOLD}Daemon stderr${RESET} ${DIM}(%s)${RESET}\n" "$DAEMON_ERR_LOG"
  tail -n 8 "$DAEMON_ERR_LOG" 2>/dev/null | sed 's/^/  /'
  hr
  printf "\n  [f] Live tail (Ctrl+C to stop)   [Enter] Back\n  > "
  local c
  read -r c
  if [[ "$c" == "f" ]]; then
    printf "\n${DIM}Live tailing... Ctrl+C to stop.${RESET}\n\n"
    tail -f "$LOG_FILE"
  fi
}

screen_test_block() {
  header
  printf "${BOLD}TEST BLOCK / UNBLOCK${RESET}\n"; hr
  printf "  Verify pf enforcement independently of VPN state.\n\n"
  printf "  ${DIM}If anything ever goes wrong and you are stuck offline, this${RESET}\n"
  printf "  ${DIM}always works from any terminal:${RESET}\n"
  printf "  ${CYAN}sudo /sbin/pfctl -a %s -F rules${RESET}\n\n" "$PF_ANCHOR_NAME"
  printf "  [1] Force BLOCK now (mode: %s)\n" "$MODE"
  printf "  [2] Force UNBLOCK now\n"
  printf "  [0] Back\n\n  > "
  local c
  read -r c
  case "$c" in
    1)
      ensure_anchor_registered
      apply_block flush
      printf "\n${RED}Block applied.${RESET} Load a website — it should fail.\n"
      printf "${DIM}Note: if the daemon is running and your VPN is up, it will clear${RESET}\n"
      printf "${DIM}this within ~15s, since it re-asserts the correct state.${RESET}\n"
      ;;
    2)
      clear_block
      printf "\n${GREEN}Block cleared.${RESET}\n"
      ;;
  esac
  press_enter
}

screen_diagnostics() {
  header
  printf "${BOLD}DEEP DIAGNOSTICS${RESET}  ${DIM}v%s${RESET}\n" "$SCRIPT_VERSION"; hr

  printf "  ${BOLD}1. Daemon process${RESET}\n"
  local proc_line
  proc_line=$(ps aux | grep "[v]pn_kill_switch.sh --daemon")
  if [[ -n "$proc_line" ]]; then
    printf "     ${GREEN}running${RESET}\n     %s\n" "$proc_line"
  else
    printf "     ${RED}not running${RESET}\n"
  fi

  printf "\n  ${BOLD}2. Install paths${RESET}\n"
  printf "     script:  %s %s\n" "$INSTALLED_SCRIPT" "$([[ -f "$INSTALLED_SCRIPT" ]] && echo "(present)" || echo "(MISSING)")"
  printf "     state:   %s %s\n" "$STATE_DIR" "$([[ -d "$STATE_DIR" ]] && echo "(present)" || echo "(MISSING)")"
  printf "     config:  %s %s\n" "$CONFIG_FILE" "$([[ -f "$CONFIG_FILE" ]] && echo "(present)" || echo "(MISSING)")"

  printf "\n  ${BOLD}3. Autostart${RESET}\n"
  printf "     setting: %s\n" "$([[ "$AUTOSTART" == "1" ]] && echo enabled || echo disabled)"
  printf "     boot plist %s: %s\n" "$PLIST_BOOT" "$([[ -f "$PLIST_BOOT" ]] && echo present || echo absent)"
  printf "     session plist %s: %s\n" "$PLIST_MANUAL" "$([[ -f "$PLIST_MANUAL" ]] && echo present || echo absent)"

  printf "\n  ${BOLD}4. pf${RESET}\n"
  printf "     enabled:    %s\n" "$(pf_enabled && echo yes || echo NO)"
  printf "     registered: %s\n" "$(anchor_registered && echo yes || echo "NO — blocks would be inert")"
  printf "     block rules in anchor: %s\n" "$(anchor_rule_count)"

  printf "\n  ${BOLD}5. VPN detection right now${RESET}\n"
  printf "     configured iface: %s\n" "${VPN_INTERFACE:-<auto>}"
  printf "     tunnels up:       %s\n" "$(tunnel_interfaces | tr '\n' ' ')"
  printf "     default route if: %s\n" "$(default_route_interface)"
  if vpn_is_connected >/dev/null 2>&1; then
    printf "     verdict: ${GREEN}UP${RESET} (%s)\n" "$VPN_CHECK_REASON"
  else
    printf "     verdict: ${RED}DOWN — should be blocking${RESET} (%s)\n" "$VPN_CHECK_REASON"
  fi

  printf "\n  ${BOLD}6. Learned VPN server endpoints${RESET} ${DIM}(passed through the block)${RESET}\n"
  if [[ -s "$ENDPOINTS_FILE" ]]; then
    sed 's/^/     /' "$ENDPOINTS_FILE"
  else
    printf "     ${DIM}none yet — learned while the VPN is up${RESET}\n"
  fi

  printf "\n  ${BOLD}7. Last 15 log lines${RESET}\n"
  tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/     /'

  printf "\n  ${BOLD}8. Heartbeat${RESET}\n"
  if grep -q "heartbeat:" "$LOG_FILE" 2>/dev/null; then
    printf "     %s\n" "$(grep "heartbeat:" "$LOG_FILE" | tail -1)"
  else
    printf "     ${YELLOW}none yet${RESET} (appears ~5 min after start)\n"
  fi

  press_enter
}

# ---------- live status ----------
# Privileged lookups are cached so the once-a-second redraw does not
# fork sudo three times per second.
STATUS_CACHE_TS=0
STATUS_RUNNING="" STATUS_BLOCKED="" STATUS_VPN="" STATUS_REASON=""

refresh_status() {
  local now
  # Shorter timeout and longer interval than the daemon uses: this runs
  # on the once-a-second menu redraw, and a full-length probe would
  # freeze the UI while it waited.
  local PROBE_TIMEOUT_SECONDS=2
  local PROBE_INTERVAL_SECONDS=10
  now=$(date +%s)
  [[ $((now - STATUS_CACHE_TS)) -lt 3 ]] && return
  STATUS_CACHE_TS=$now
  daemon_process_running && STATUS_RUNNING=yes || STATUS_RUNNING=no
  block_is_enforced && STATUS_BLOCKED=yes || STATUS_BLOCKED=no
  if vpn_is_connected >/dev/null 2>&1; then STATUS_VPN=up; else STATUS_VPN=down; fi
  STATUS_REASON="$VPN_CHECK_REASON"
}

# Short human label for whatever the probe is currently aimed at.
probe_label() {
  if [[ "$PROBE_ENABLED" != "1" ]]; then printf 'off'; return; fi
  if [[ "$PROBE_MODE" == "icmp" ]]; then printf 'icmp %s' "$PROBE_HOST"; return; fi
  local h="${PROBE_URL#*://}"
  printf 'http %s' "${h%%/*}"
}

print_live_status_block() {
  refresh_status

  if [[ "$STATUS_RUNNING" == "yes" ]]; then
    printf "  Kill switch: ${GREEN}● ON${RESET}"
  else
    printf "  Kill switch: ${RED}● OFF${RESET}"
  fi
  if [[ "$AUTOSTART" == "1" ]]; then
    printf "  ${DIM}(starts at boot)${RESET}"
  else
    printf "  ${DIM}(manual start)${RESET}"
  fi

  if [[ "$STATUS_VPN" == "up" ]]; then
    printf "   VPN: ${GREEN}up${RESET}"
  else
    printf "   VPN: ${RED}down${RESET}"
  fi
  if [[ "$STATUS_BLOCKED" == "yes" ]]; then
    printf "   Traffic: ${RED}BLOCKED${RESET}\n"
  else
    printf "   Traffic: ${GREEN}flowing${RESET}\n"
  fi

  printf "  ${DIM}%s${RESET}\n" "${STATUS_REASON:-checking...}"
  printf "  Mode: ${YELLOW}%s${RESET}" "$MODE"
  [[ "$MODE" == "LIST" ]] && printf " (%s)" "$ACTIVE_PROFILE"
  printf "   Interface: ${CYAN}%s${RESET} ${DIM}(%s)${RESET}   Probe: ${CYAN}%s${RESET}\n" \
    "${VPN_INTERFACE:-auto}" "${VPN_APP_NAME:-unknown}" "$(probe_label)"
  printf "  ${DIM}[o] turn on   [f] turn off   [r] restart${RESET}\n"
}

print_menu_options() {
  hr
  printf "  ${BOLD}[1]${RESET} Auto-detect VPN interface\n"
  printf "  ${BOLD}[2]${RESET} Set VPN interface manually\n"
  printf "  ${BOLD}[3]${RESET} Set mode (ALL traffic / LIST profile)\n"
  printf "  ${BOLD}[4]${RESET} Manage profiles\n"
  printf "  ${BOLD}[5]${RESET} How detection works\n"
  printf "  ${BOLD}[6]${RESET} Settings (autostart, probe, block shaping)\n"
  printf "  ${BOLD}[7]${RESET} View logs\n"
  printf "  ${BOLD}[8]${RESET} Test block/unblock manually\n"
  printf "  ${BOLD}[9]${RESET} Deep diagnostics\n"
  printf "  ${BOLD}[u]${RESET} Uninstall completely\n"
  printf "  ${BOLD}[0]${RESET} Quit\n"
  hr
  printf "  choice > "
}

# In-place refresh of the status + menu.
#
# The previous version counted logical lines and moved the cursor up by
# that many. It was off by one, because the trailing "choice > " prompt
# counts as a line but emits no newline — so every refresh climbed one
# row too far and ate the bottom of the logo. Counting also breaks
# outright as soon as any line wraps in a narrow window.
#
# Save/restore the cursor position instead: the terminal remembers the
# exact spot, so wrapping and line-count changes cannot desynchronise it.
MENU_ANCHOR_SET=0

# Rows the whole screen needs: logo block + status + menu. If the window
# is shorter than this the draw scrolls, which would invalidate the saved
# anchor, so we skip in-place refreshes and update on keypress instead.
#
# NOTE: `tput lines` is read here via the controlling terminal rather
# than plain command substitution. Inside $(...) tput's stdout is a
# pipe, so it cannot ioctl the terminal for its real size and quietly
# falls back to the terminfo default (24) — which made this guard
# report "does not fit" on a perfectly large window.
term_rows() {
  local r
  r=$(stty size < /dev/tty 2>/dev/null | awk '{print $1}')
  [[ "$r" =~ ^[0-9]+$ ]] || r=$(tput lines 2>/dev/null)
  [[ "$r" =~ ^[0-9]+$ ]] || r="${LINES:-24}"
  printf '%s\n' "$r"
}

menu_fits() {
  local rows
  rows=$(term_rows)
  [[ "$rows" -ge 26 ]]
}

draw_full_menu() {
  header
  if menu_fits; then
    tput sc 2>/dev/null && MENU_ANCHOR_SET=1 || MENU_ANCHOR_SET=0
  else
    MENU_ANCHOR_SET=0
  fi
  print_live_status_block
  print_menu_options
}

redraw_status_block() {
  [[ "$MENU_ANCHOR_SET" == "1" ]] || return 0
  menu_fits || return 0
  tput rc 2>/dev/null || return 0
  tput ed 2>/dev/null
  print_live_status_block
  print_menu_options
}
turn_on() {
  printf "\n  ${DIM}Installing to %s and starting as root...${RESET}\n" "$LIBEXEC_DIR"
  if start_daemon; then
    printf "\n${GREEN}✓ Kill switch is ON.${RESET}\n"
    if [[ "$AUTOSTART" == "1" ]]; then
      printf "${DIM}  It will also start automatically at boot.${RESET}\n"
    else
      printf "${DIM}  It will NOT start at boot — enable that in Settings [6] if you want it.${RESET}\n"
    fi
  else
    printf "\n${RED}✗ Failed to start. Check:${RESET}\n"
    printf "  tail -n 40 %s\n" "$DAEMON_ERR_LOG"
    printf "  tail -n 40 %s\n" "$LOG_FILE"
  fi
}

turn_off() {
  printf "\n  ${DIM}Stopping and clearing any active block...${RESET}\n"
  stop_daemon
  if [[ "$AUTOSTART" == "1" ]]; then
    printf "\n${YELLOW}✓ Kill switch stopped. It is still set to start at boot.${RESET}\n"
  else
    printf "\n${YELLOW}✓ Kill switch stopped.${RESET}\n"
  fi
}

screen_uninstall() {
  header
  printf "${BOLD}UNINSTALL${RESET}\n"; hr
  printf "  This stops the daemon, clears any block, removes the launchd\n"
  printf "  entries, and un-registers the pf anchor from %s.\n\n" "$PF_CONF"
  printf "  Config and logs in %s are kept.\n\n" "$STATE_DIR"
  printf "  Type 'yes' to confirm: "
  local c
  read -r c
  if [[ "$c" == "yes" ]]; then
    uninstall_all
    printf "\n${GREEN}✓ Removed. Traffic is unblocked.${RESET}\n"
  else
    printf "\n${DIM}Cancelled.${RESET}\n"
  fi
  press_enter
}

main_menu() {
  draw_full_menu
  local key
  while true; do
    if read -t 1 -r -n 1 key; then
      case "$key" in
        o|O) if daemon_process_running; then printf "\n${DIM}Already on.${RESET}\n"; else turn_on; fi
             press_enter; draw_full_menu ;;
        f|F) if daemon_process_running || service_loaded; then turn_off; else printf "\n${DIM}Already off.${RESET}\n"; fi
             press_enter; draw_full_menu ;;
        r|R) printf "\n"; turn_on; press_enter; draw_full_menu ;;
        1) printf "\n"; detect_interface_interactive; draw_full_menu ;;
        2) printf "\n"; screen_manual_interface; draw_full_menu ;;
        3) printf "\n"; screen_set_mode; draw_full_menu ;;
        4) printf "\n"; screen_edit_profile; draw_full_menu ;;
        5) printf "\n"; screen_about; draw_full_menu ;;
        6) printf "\n"; screen_settings; draw_full_menu ;;
        7) printf "\n"; screen_logs; draw_full_menu ;;
        8) printf "\n"; screen_test_block; draw_full_menu ;;
        9) printf "\n"; screen_diagnostics; draw_full_menu ;;
        u|U) printf "\n"; screen_uninstall; draw_full_menu ;;
        0) printf "\n\n${DIM}bye.${RESET}\n"; exit 0 ;;
        *) ;;
      esac
    else
      redraw_status_block
    fi
  done
}

# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------
case "$1" in
  --daemon)
    run_daemon
    exit 0
    ;;
  --unblock)
    load_config
    clear_block
    echo "Block cleared."
    exit 0
    ;;
  --status)
    load_config
    echo "version:   $SCRIPT_VERSION"
    echo "daemon:    $(daemon_process_running && echo running || echo stopped)"
    echo "autostart: $([[ "$AUTOSTART" == "1" ]] && echo enabled || echo disabled)"
    if vpn_is_connected >/dev/null 2>&1; then echo "vpn:       up ($VPN_CHECK_REASON)"; else echo "vpn:       down ($VPN_CHECK_REASON)"; fi
    echo "blocked:   $(block_is_enforced && echo yes || echo no)"
    exit 0
    ;;
  --version)
    echo "$SCRIPT_VERSION"
    exit 0
    ;;
esac

load_config

if [[ "$(id -u)" != "0" ]]; then
  printf "${DIM}This tool manages a root-level firewall daemon; sudo is required.${RESET}\n"
  sudo -v || { printf "${RED}sudo is required.${RESET}\n"; exit 1; }
fi

main_menu

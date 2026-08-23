#!/bin/bash
#
# vpn_kill_switch.sh — interactive VPN kill switch for macOS
#
# Watches VPN connectivity. The instant the VPN drops, it blocks network
# traffic via pf so nothing leaks over your real IP. Two modes:
#
#   ALL   — blocks all outbound internet traffic except localhost
#           (true kill switch)
#   LIST  — blocks only a domain/IP list you define (saved profile)
#
# Traffic is restored automatically the moment the VPN comes back up.
#
# Usage:
#   chmod +x vpn_kill_switch.sh
#   ./vpn_kill_switch.sh
#
# ---------------------------------------------------------------------

set -o pipefail

# Bump this whenever you ship a fix. Status/diagnostics print it so you
# can confirm the running copy is actually the new one.
SCRIPT_VERSION="2026-08-08-fix-detection-v3"

# CRITICAL: when launchd runs us as root, $HOME is empty/root's home,
# NOT the real user's home. Every path we use must be anchored to the
# real user's home directory regardless of who's executing us right
# now, or paths silently break (e.g. "$HOME/.vpn_kill_switch" becomes
# "/.vpn_kill_switch" under root with no HOME set).
if [[ -n "$SUDO_USER" ]]; then
  REAL_USER="$SUDO_USER"
elif [[ "$(id -u)" == "0" ]]; then
  REAL_USER=$(stat -f%Su /dev/console 2>/dev/null)
else
  REAL_USER="$(whoami)"
fi
REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[[ -z "$REAL_HOME" ]] && REAL_HOME="/Users/$REAL_USER"

APP_DIR="$REAL_HOME/.vpn_kill_switch"
CONFIG_FILE="$APP_DIR/config.conf"
PROFILES_DIR="$APP_DIR/profiles"
LOG_FILE="$APP_DIR/kill_switch.log"
PLIST_LABEL="com.user.vpnkillswitch"
PLIST_PATH="/Library/LaunchDaemons/${PLIST_LABEL}.plist"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PF_ANCHOR_NAME="vpn_kill_switch"
PF_ANCHOR_FILE="/etc/pf.anchors/vpn_kill_switch"

mkdir -p "$APP_DIR" "$PROFILES_DIR"
touch "$LOG_FILE"

SAFE_SCRIPT_PATH="$APP_DIR/vpn_kill_switch.sh"
CURRENT_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

case "$CURRENT_SCRIPT_PATH" in
  */Downloads/*|*/Desktop/*|*/Documents/*)
    if [[ "$1" != "--daemon" ]]; then
      cp "$CURRENT_SCRIPT_PATH" "$SAFE_SCRIPT_PATH"
      chmod +x "$SAFE_SCRIPT_PATH"
      echo -e "\033[38;5;221m⚠ Running from a protected folder (Downloads/Desktop/Documents).\033[0m"
      echo -e "\033[38;5;114m✓ Copied to $SAFE_SCRIPT_PATH — relaunching from there.\033[0m"
      echo ""
      exec bash "$SAFE_SCRIPT_PATH" "$@"
    fi
    ;;
esac

SCRIPT_PATH="$SAFE_SCRIPT_PATH"

priv() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# ---------- colors ----------
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[38;5;203m'; GREEN='\033[38;5;114m'; YELLOW='\033[38;5;221m'
BLUE='\033[38;5;75m'; MAGENTA='\033[38;5;176m'; CYAN='\033[38;5;80m'
GRAY='\033[38;5;244m'

hr() { printf "${GRAY}%s${RESET}\n" "────────────────────────────────────────────────"; }

header() {
  clear
  printf "${BOLD}${RED}"
  cat << 'EOF'
   _   __ ___   _  __   __ __ _  __  __     ____         _  __       __ 
  | | / // _ \ / |/ /  / //_/(_)/ / / /    / __/ _    __(_)/ /_ ____/ /_
  | |/ // ___//    /  / ,<  / // /_/ /    _\ \  | |/|/ // // __// __/ __ \
  |___//_/   /_/|_/  /_/|_|/_//_/\____/  /___/  |__,__//_/ \__/\__/_/ /_/
EOF
  printf "${RESET}${DIM}  blocks traffic instantly if your VPN interface drops${RESET}\n\n"
}

# ---------- config defaults ----------
default_config() {
  cat > "$CONFIG_FILE" << EOF
VPN_INTERFACE=""
VPN_APP_NAME=""
CHECK_INTERVAL_SECONDS=2
MODE="ALL"
ACTIVE_PROFILE="claude"
# Host used to actively verify the tunnel is really carrying traffic,
# not just that an interface with an IP happens to exist. Should be an
# address that is ONLY reachable through your VPN (e.g. your VPN
# provider's gateway, or an internal-only host). Leave blank to disable
# active probing and fall back to interface/route/scutil checks only.
PROBE_HOST=""
PROBE_TIMEOUT_SECONDS=2
EOF
}
[[ -f "$CONFIG_FILE" ]] || default_config
source "$CONFIG_FILE"

save_config() {
  cat > "$CONFIG_FILE" << EOF
VPN_INTERFACE="$VPN_INTERFACE"
VPN_APP_NAME="$VPN_APP_NAME"
CHECK_INTERVAL_SECONDS=$CHECK_INTERVAL_SECONDS
MODE="$MODE"
ACTIVE_PROFILE="$ACTIVE_PROFILE"
PROBE_HOST="$PROBE_HOST"
PROBE_TIMEOUT_SECONDS=${PROBE_TIMEOUT_SECONDS:-2}
EOF
}

default_profile() {
  local name="$1"
  cat > "$PROFILES_DIR/$name.conf" << 'PEOF'
# One domain or IP per line. Comments start with #.
claude.ai
api.anthropic.com
console.anthropic.com
PEOF
}
[[ -f "$PROFILES_DIR/claude.conf" ]] || default_profile "claude"

# ---------- interface detection ----------
list_candidate_interfaces() {
  ifconfig 2>/dev/null | awk '
    /^[a-z]/ { iface=$1; sub(":", "", iface) }
    /inet / && iface ~ /^(utun|ppp|ipsec|tun|tap)/ { print iface, $2 }
  '
}

press_enter() { printf "\n${GRAY}Press Enter to continue...${RESET}"; read -r; }

detect_interface_interactive() {
  header
  printf "${BOLD}DETECT VPN INTERFACE${RESET}\n"; hr
  printf "  ${DIM}We'll snapshot tunnel interfaces before/after you toggle your VPN.${RESET}\n\n"
  printf "  Step 1: Turn your VPN OFF, then press Enter.\n"
  read -r
  before=$(list_candidate_interfaces | awk '{print $1}' | sort)

  printf "  Step 2: Turn your VPN ON, wait for it to connect, then press Enter.\n"
  read -r
  after=$(list_candidate_interfaces | awk '{print $1}' | sort)

  new_iface=$(comm -13 <(echo "$before") <(echo "$after") | head -n 1)

  if [[ -n "$new_iface" ]]; then
    owner=$(detect_interface_owner "$new_iface")
    printf "\n  ${GREEN}✓ Detected interface: %s${RESET}\n" "$new_iface"
    printf "  ${GREEN}✓ Likely app/service: %s${RESET}\n" "$owner"
    VPN_INTERFACE="$new_iface"
    VPN_APP_NAME="$owner"
    save_config
  else
    printf "\n  ${RED}Could not auto-detect a new interface.${RESET}\n"
    printf "  Active tunnel-like interfaces currently up:\n\n"
    list_candidate_interfaces | sed 's/^/    /'
    printf "\n  Enter the interface name manually (or blank to cancel): "
    read -r manual
    if [[ -n "$manual" ]]; then
      VPN_INTERFACE="$manual"
      save_config
      printf "\n  ${GREEN}✓ Saved: %s${RESET}\n" "$manual"
    fi
  fi

  printf "\n  Want to set a probe host now? This actively verifies the tunnel is\n"
  printf "  really carrying traffic instead of trusting the interface alone —\n"
  printf "  strongly recommended (e.g. your VPN gateway IP, or an internal-only\n"
  printf "  host that's ONLY reachable while connected). Leave blank to skip.\n"
  printf "  Probe host: "
  read -r probe
  if [[ -n "$probe" ]]; then
    PROBE_HOST="$probe"
    save_config
    printf "\n  ${GREEN}✓ Probe host saved: %s${RESET}\n" "$probe"
  fi
  press_enter
}

interface_is_up() {
  local iface="$1"
  [[ -z "$iface" ]] && return 1
  ifconfig "$iface" 2>/dev/null | awk '
    /inet / {
      ip=$2
      if (ip != "127.0.0.1" && ip !~ /^169\.254\./) found=1
    }
    END { exit found ? 0 : 1 }
  '
}

default_route_interface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

default_route_is_tunnel() {
  local def_if
  def_if=$(default_route_interface)
  [[ "$def_if" =~ ^(utun|ipsec|ppp|tun|tap)[0-9]*$ ]]
}

any_scutil_vpn_connected() {
  scutil --nc list 2>/dev/null | grep -qE '\(Connected\).*\[VPN:'
}

# Active check: does traffic actually flow through the tunnel right now?
# This is the piece that was missing before. A utun interface can be left
# behind with a live-looking IPv4 after a VPN app crashes or reconnects
# badly — interface_is_up() alone can't tell the difference between a
# healthy tunnel and a stale, dead one.
probe_tunnel_alive() {
  local iface="$1"
  [[ -z "$PROBE_HOST" ]] && return 2   # 2 = no probe configured
  local timeout="${PROBE_TIMEOUT_SECONDS:-2}"
  if [[ -n "$iface" ]]; then
    ping -c 1 -t "$timeout" -b "$iface" "$PROBE_HOST" >/dev/null 2>&1 && return 0
    ping -c 1 -t "$timeout" "$PROBE_HOST" >/dev/null 2>&1 && return 0
  else
    ping -c 1 -t "$timeout" "$PROBE_HOST" >/dev/null 2>&1 && return 0
  fi
  return 1
}

find_live_tunnel_interface() {
  local iface def_if

  if [[ -n "$VPN_INTERFACE" ]] && interface_is_up "$VPN_INTERFACE"; then
    echo "$VPN_INTERFACE"
    return 0
  fi

  def_if=$(default_route_interface)
  if [[ "$def_if" =~ ^(utun|ipsec|ppp|tun|tap)[0-9]*$ ]] && interface_is_up "$def_if"; then
    echo "$def_if"
    return 0
  fi

  while read -r iface _; do
    if interface_is_up "$iface"; then
      echo "$iface"
      return 0
    fi
  done < <(list_candidate_interfaces)

  return 1
}

# Master VPN-up check.
#
# FIX: the old version treated "some tunnel interface exists with a real
# IPv4" as sufficient proof of "up" on its own. That's wrong — a VPN app
# can crash or reconnect badly and leave a stale utunN interface behind
# with a real-looking IPv4. That stale interface kept satisfying this
# check forever, which is why the kill switch stopped engaging after
# roughly an hour: the daemon kept believing the VPN was "up" via a
# corpse interface that was no longer carrying any traffic.
#
# Now, if the only evidence is "a tunnel interface exists" (signals #1-3
# below are all false), we don't trust it blindly:
#   - if PROBE_HOST is set, we actively ping through it to confirm real
#     connectivity before calling it "up"
#   - if PROBE_HOST is NOT set, we treat this ambiguous case as DOWN
#     (fail closed) — a kill switch should never guess "safe" without
#     evidence
VPN_CHECK_REASON=""

vpn_is_connected() {
  local live

  if [[ -n "$VPN_INTERFACE" ]] && interface_is_up "$VPN_INTERFACE"; then
    VPN_CHECK_REASON="configured-interface-up"
    echo "$VPN_INTERFACE"
    return 0
  fi

  if default_route_is_tunnel; then
    VPN_CHECK_REASON="default-route-is-tunnel"
    default_route_interface
    return 0
  fi

  if any_scutil_vpn_connected; then
    VPN_CHECK_REASON="scutil-connected"
    echo "${VPN_INTERFACE:-}"
    return 0
  fi

  live=$(find_live_tunnel_interface 2>/dev/null) || live=""
  if [[ -n "$live" ]]; then
    if [[ -n "$PROBE_HOST" ]]; then
      if probe_tunnel_alive "$live"; then
        VPN_CHECK_REASON="tunnel-interface+probe-ok"
        echo "$live"
        return 0
      else
        VPN_CHECK_REASON="tunnel-interface-but-probe-FAILED(stale?)"
        return 1
      fi
    else
      VPN_CHECK_REASON="tunnel-interface-only-NO-PROBE-configured(unverified,failing-closed)"
      return 1
    fi
  fi

  VPN_CHECK_REASON="no-signal"
  return 1
}

detect_interface_owner() {
  local iface="$1"
  local owner=""

  owner=$(scutil --nc list 2>/dev/null | grep -E '\(Connected\).*\[VPN:' | sed -E 's/^.*"([^"]+)".*$/\1/' | head -n 1)

  if [[ -z "$owner" ]]; then
    owner=$(scutil --nc list 2>/dev/null | grep -i "${iface}" | sed -E 's/^.*"([^"]+)".*$/\1/' | head -n 1)
  fi

  if [[ -z "$owner" ]]; then
    local iface_ip
    iface_ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
    if [[ -n "$iface_ip" ]]; then
      owner=$(lsof -i "@$iface_ip" -sTCP:ESTABLISHED 2>/dev/null | awk 'NR==2{print $1}')
    fi
  fi

  if [[ -z "$owner" ]]; then
    local candidate
    for candidate in \
      "Happ" "Hiddify" "v2RayTun" "v2raytun" "WireGuard" "wg-quick" \
      "Outline" "TrustTunnel" "Amnezia" "OpenVPN" "NordVPN" "ExpressVPN" \
      "Surfshark" "ProtonVPN" "Mullvad" "TunnelBear" "Tailscale" "Warp" \
      "Cloudflare WARP" "Private Internet Access" "Cisco AnyConnect" \
      "snimask" "SSHTunnel" "sfavt" "sing-box" "clash"
    do
      if pgrep -fi "$candidate" > /dev/null 2>&1; then
        owner="$candidate"
        break
      fi
    done
  fi

  echo "${owner:-unknown}"
}

# ---------- daemon mode ----------
run_daemon() {
  source "$CONFIG_FILE"
  {
    echo "================================================================"
    echo "DAEMON STARTED: $(date '+%Y-%m-%d %H:%M:%S') pid=$$ uid=$(id -u)"
    echo "SCRIPT_VERSION=$SCRIPT_VERSION"
    echo "LOG_FILE=$LOG_FILE"
    echo "CONFIG_FILE=$CONFIG_FILE"
    echo "VPN_INTERFACE=$VPN_INTERFACE MODE=$MODE PROBE_HOST=${PROBE_HOST:-<none>}"
    echo "================================================================"
  } >> "$LOG_FILE"

  if [[ ! -f "$PF_ANCHOR_FILE" ]]; then
    echo "# vpn_kill_switch anchor" | priv tee "$PF_ANCHOR_FILE" >/dev/null 2>>"$LOG_FILE"
  fi
  ensure_anchor_registered

  local last_state=""
  local last_iface_seen="${VPN_INTERFACE:-}"

  check_and_react() {
    source "$CONFIG_FILE" 2>>"$LOG_FILE"

    local current_state live_iface=""
    if live_iface=$(vpn_is_connected 2>/dev/null); then
      current_state="up"
      if [[ -n "$live_iface" && "$live_iface" != "$VPN_INTERFACE" ]]; then
        echo "$(date '+%H:%M:%S') interface tracking: ${VPN_INTERFACE:-none} -> $live_iface (reason=$VPN_CHECK_REASON)" >> "$LOG_FILE"
        VPN_INTERFACE="$live_iface"
        VPN_APP_NAME=$(detect_interface_owner "$live_iface")
        save_config
        last_iface_seen="$live_iface"
      fi
    else
      current_state="down"
      live_iface=""
    fi

    if [[ "$current_state" != "$last_state" ]]; then
      echo "$(date '+%H:%M:%S') event: vpn -> $current_state (reason=$VPN_CHECK_REASON, iface=${VPN_INTERFACE:-none}, default_if=$(default_route_interface))" >> "$LOG_FILE"
      if [[ "$current_state" == "up" ]]; then
        clear_block
        echo "$(date '+%H:%M:%S') VPN UP -> traffic UNBLOCKED" >> "$LOG_FILE"
      else
        apply_block "$MODE" "$ACTIVE_PROFILE"
        echo "$(date '+%H:%M:%S') VPN DOWN -> traffic BLOCKED (mode=$MODE)" >> "$LOG_FILE"
      fi
      last_state="$current_state"
    fi
  }

  check_and_react

  # ------------------------------------------------------------------
  # Event loop design (bash 3.2 / macOS):
  #
  # PREVIOUS BUG: `monitor_pid=$(start_monitor)` ran the background
  # `route -n monitor` pipeline inside a command substitution, which made
  # bash wait for it forever — the daemon hung right after the initial
  # check_and_react and never reacted to VPN drops.
  #
  # FIX: never start long-lived background jobs inside $(); redirect
  # their stdout explicitly; keep a reliable 1s poll as the fail-safe
  # primary loop, with route -n monitor only as a fast-wake optimization.
  #
  # SECOND BUG (this fix): route -n monitor only fires on route table
  # changes. A VPN app that dies quietly and leaves a stale utunN
  # interface behind produces NO route change — so neither the fast
  # wakeup nor the old detection logic ever caught it, and the block
  # never re-armed. That's the "works, then stops cutting off traffic
  # after about an hour" symptom. Fixed in vpn_is_connected() above by
  # no longer trusting a lone stale interface as proof of "up" — the 1s
  # poll now catches this correctly on its own even without a route
  # event.
  # ------------------------------------------------------------------
  local fifo="$APP_DIR/scutil.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  chmod 666 "$fifo" 2>/dev/null || true

  local monitor_pid=""
  start_monitor() {
    (
      /sbin/route -n monitor 2>>"$LOG_FILE" \
        | while read -r _; do
            echo "CHANGE" > "$fifo" 2>/dev/null
          done
      echo "EOF" > "$fifo" 2>/dev/null
    ) >/dev/null 2>>"$LOG_FILE" &
    monitor_pid=$!
  }

  start_monitor
  echo "$(date '+%H:%M:%S') route monitor started (pid ${monitor_pid:-?})" >> "$LOG_FILE"
  echo "$(date '+%H:%M:%S') primary poll loop every 1s (fail-safe)" >> "$LOG_FILE"

  local loop_count=0
  while true; do
    if read -t 1 -r line < "$fifo" 2>/dev/null; then
      if [[ "$line" == "EOF" ]]; then
        echo "$(date '+%H:%M:%S') route monitor ended, restarting in 1s" >> "$LOG_FILE"
        sleep 1
        start_monitor
        echo "$(date '+%H:%M:%S') route monitor restarted (pid ${monitor_pid:-?})" >> "$LOG_FILE"
      fi
    fi

    check_and_react

    loop_count=$((loop_count + 1))
    if (( loop_count % 60 == 0 )); then
      echo "$(date '+%H:%M:%S') heartbeat: state=${last_state:-unknown} iface=${VPN_INTERFACE:-none} default_if=$(default_route_interface) ver=$SCRIPT_VERSION" >> "$LOG_FILE"
    fi
  done
}

apply_block() {
  local mode="$1" profile="$2"
  local tmp_rules
  tmp_rules=$(mktemp)

  if [[ "$mode" == "ALL" ]]; then
    cat > "$tmp_rules" << 'PEOF'
pass out quick on lo0 all
pass out quick on ! lo0 to 10.0.0.0/8
pass out quick on ! lo0 to 172.16.0.0/12
pass out quick on ! lo0 to 192.168.0.0/16
pass out quick on ! lo0 to 169.254.0.0/16
pass out quick on ! lo0 to 224.0.0.0/24
block drop out quick on ! lo0 all
PEOF
  else
    local profile_file="$PROFILES_DIR/$profile.conf"
    : > "$tmp_rules"
    if [[ -f "$profile_file" ]]; then
      while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        entry=$(echo "$entry" | sed 's/[[:space:]]*$//;s/^[[:space:]]*//')
        [[ -z "$entry" ]] && continue
        if [[ "$entry" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
          echo "block drop out quick proto tcp from any to $entry port {80,443}" >> "$tmp_rules"
          echo "block drop out quick proto udp from any to $entry port {80,443}" >> "$tmp_rules"
        else
          local ip
          for ip in $(dig +short "$entry" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); do
            echo "block drop out quick proto tcp from any to $ip port {80,443}" >> "$tmp_rules"
            echo "block drop out quick proto udp from any to $ip port {80,443}" >> "$tmp_rules"
          done
        fi
      done < "$profile_file"
    fi
    if [[ ! -s "$tmp_rules" ]]; then
      echo "$(date '+%H:%M:%S') WARN: LIST profile '$profile' produced zero rules — nothing blocked" >> "$LOG_FILE"
    fi
  fi

  priv cp "$tmp_rules" "$PF_ANCHOR_FILE" 2>>"$LOG_FILE"
  priv chmod 644 "$PF_ANCHOR_FILE" 2>>"$LOG_FILE"
  rm -f "$tmp_rules"

  ensure_anchor_registered
  if ! priv /sbin/pfctl -a "$PF_ANCHOR_NAME" -f "$PF_ANCHOR_FILE" >>"$LOG_FILE" 2>&1; then
    echo "$(date '+%H:%M:%S') ERROR: pfctl failed to load anchor rules" >> "$LOG_FILE"
  fi
  priv /sbin/pfctl -e >>"$LOG_FILE" 2>&1

  local loaded
  loaded=$(priv /sbin/pfctl -a "$PF_ANCHOR_NAME" -s rules 2>/dev/null | grep -c "block" || true)
  echo "$(date '+%H:%M:%S') pf anchor loaded, block rules visible: ${loaded:-0}" >> "$LOG_FILE"
}

ensure_anchor_registered() {
  local marker_file="$APP_DIR/pf_registered.marker"
  local main_conf="$APP_DIR/pf_main.conf"

  cat > "$main_conf" << PEOF
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
rdr-anchor "com.apple/*"
dummynet-anchor "com.apple/*"
anchor "com.apple/*"
anchor "${PF_ANCHOR_NAME}"
load anchor "${PF_ANCHOR_NAME}" from "${PF_ANCHOR_FILE}"
PEOF

  priv /sbin/pfctl -f "$main_conf" 2>>"$LOG_FILE"
  touch "$marker_file"
}

clear_block() {
  priv /sbin/pfctl -a "$PF_ANCHOR_NAME" -F rules 2>>"$LOG_FILE"
}

if [[ "$1" == "--daemon" ]]; then
  run_daemon
  exit 0
fi

# ---------- interactive helpers ----------
is_watcher_loaded() { sudo launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; }
daemon_process_running() { pgrep -f "vpn_kill_switch.sh --daemon" >/dev/null 2>&1; }

write_plist() {
  sudo mkdir -p "$(dirname "$PLIST_PATH")"
  sudo bash -c "cat > '$PLIST_PATH'" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_PATH}</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>UserName</key><string>root</string>
    <key>StandardOutPath</key><string>${APP_DIR}/launchd.out.log</string>
    <key>StandardErrorPath</key><string>${APP_DIR}/launchd.err.log</string>
</dict>
</plist>
PEOF
  sudo chown root:wheel "$PLIST_PATH"
  sudo chmod 644 "$PLIST_PATH"
}

install_watcher() {
  printf "\n  ${DIM}This needs sudo to install a system-level daemon (required so it${RESET}\n"
  printf "  ${DIM}can control the firewall without prompting you every time).${RESET}\n\n"

  cp "$CURRENT_SCRIPT_PATH" "$SAFE_SCRIPT_PATH" 2>/dev/null || cp "${BASH_SOURCE[0]}" "$SAFE_SCRIPT_PATH"
  chmod +x "$SAFE_SCRIPT_PATH"

  old_pids=$(pgrep -f "vpn_kill_switch.sh --daemon" 2>/dev/null)
  if [[ -n "$old_pids" ]]; then
    printf "  ${YELLOW}Found existing daemon process(es): %s — stopping.${RESET}\n" "$old_pids"
  fi
  sudo launchctl bootout system "$PLIST_PATH" 2>/dev/null
  sudo launchctl unload "$PLIST_PATH" 2>/dev/null
  sudo launchctl remove "$PLIST_LABEL" 2>/dev/null
  sudo pkill -9 -f "vpn_kill_switch.sh --daemon" 2>/dev/null
  sudo pkill -9 -f "route -n monitor" 2>/dev/null
  sleep 1
  still_running=$(pgrep -f "vpn_kill_switch.sh --daemon" 2>/dev/null)
  if [[ -n "$still_running" ]]; then
    printf "  ${RED}Warning: process %s survived teardown, force killing again.${RESET}\n" "$still_running"
    sudo kill -9 $still_running 2>/dev/null
    sleep 1
  fi

  write_plist
  sudo launchctl load -w "$PLIST_PATH" 2>&1 | tee -a "$LOG_FILE"
  sleep 2

  if sudo launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
    exit_status=$(sudo launchctl list "$PLIST_LABEL" 2>/dev/null | grep "LastExitStatus" | grep -oE '[0-9]+')
    if [[ -n "$exit_status" && "$exit_status" != "0" ]]; then
      printf "\n${RED}✗ Daemon loaded but exited immediately (exit status %s).${RESET}\n" "$exit_status"
      printf "  Check: cat %s/launchd.err.log\n" "$APP_DIR"
    else
      printf "\n${GREEN}✓ Kill switch installed and running (as root), from: %s${RESET}\n" "$SAFE_SCRIPT_PATH"
      printf "${DIM}  It will auto-start at boot and react instantly to VPN drops.${RESET}\n"
    fi
    running_path=$(ps aux | grep "[v]pn_kill_switch.sh --daemon" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}')
    if [[ -n "$running_path" ]]; then
      printf "  ${GREEN}✓ Confirmed running from: %s${RESET}\n" "$running_path"
    else
      printf "  ${YELLOW}⚠ Could not find the daemon process — check logs.${RESET}\n"
    fi
  else
    printf "\n${RED}✗ Something went wrong loading the daemon. Check:${RESET}\n"
    printf "  sudo launchctl list | grep vpnkillswitch\n"
    printf "  cat %s/launchd.err.log\n" "$APP_DIR"
  fi
}

uninstall_watcher() {
  sudo launchctl unload "$PLIST_PATH" 2>/dev/null
  sudo rm -f "$PLIST_PATH"
  sudo /sbin/pfctl -a "$PF_ANCHOR_NAME" -F rules 2>/dev/null
  printf "\n${YELLOW}✓ Kill switch stopped and removed. Any active block was cleared.${RESET}\n"
}

# ---------- screens ----------

# Compact live status block, printed directly under the logo on the
# main menu (not a separate numbered screen). Always exactly
# STATUS_BLOCK_LINE_COUNT lines — keep that constant in sync if you
# change the number of printf lines below. It's a fixed constant
# (not computed via command substitution) because capturing this
# function's return value with $(...) would swallow its printf output
# instead of letting it print live to the terminal.
STATUS_BLOCK_LINE_COUNT=3

print_live_status_block() {
  if daemon_process_running; then
    printf "  Kill switch:  ${GREEN}● ON${RESET}   "
  elif is_watcher_loaded; then
    printf "  Kill switch:  ${YELLOW}● loaded, no process${RESET}   "
  else
    printf "  Kill switch:  ${RED}● OFF${RESET}   "
  fi

  if live_now=$(vpn_is_connected 2>/dev/null); then
    printf "VPN: ${GREEN}up${RESET} ${DIM}(%s)${RESET}   " "${live_now:-$VPN_CHECK_REASON}"
  else
    printf "VPN: ${RED}down${RESET} ${DIM}(%s)${RESET}   " "$VPN_CHECK_REASON"
  fi

  block_active=$(sudo /sbin/pfctl -a "$PF_ANCHOR_NAME" -s rules 2>/dev/null | grep -c "block drop")
  if [[ "${block_active:-0}" -gt 0 ]]; then
    printf "Block: ${RED}ACTIVE${RESET}\n"
  else
    printf "Block: ${GREEN}inactive${RESET}\n"
  fi

 printf "  Mode: ${YELLOW}%s${RESET}" "$MODE"
  [[ "$MODE" == "LIST" ]] && printf " (%s)" "$ACTIVE_PROFILE"
  printf "   Interface: ${CYAN}%s${RESET} ${DIM}(%s)${RESET}   Probe: ${CYAN}%s${RESET}\n" \
    "${VPN_INTERFACE:-<not set>}" "${VPN_APP_NAME:-unknown}" "${PROBE_HOST:-<none>}"

  printf "  ${DIM}[o] on  [f] off  [r] restart${RESET}\n"
}

screen_set_mode() {
  header
  printf "${BOLD}SET MODE${RESET}\n"; hr
  printf "  [1] ALL   — block all internet traffic when VPN drops\n"
  printf "  [2] LIST  — block only a domain/IP profile when VPN drops\n"
  printf "  [0] Cancel\n\n  > "
  read -r c
  case "$c" in
    1) MODE="ALL"; save_config; printf "\n${GREEN}✓ Mode set to ALL.${RESET}\n" ;;
    2) MODE="LIST"; save_config; printf "\n${GREEN}✓ Mode set to LIST.${RESET}\n"; screen_choose_profile ;;
  esac
  press_enter
}

screen_choose_profile() {
  header
  printf "${BOLD}PROFILES${RESET}\n"; hr
  local profiles=("$PROFILES_DIR"/*.conf)
  local i=1
  declare -A idx_map
  for p in "${profiles[@]}"; do
    name=$(basename "$p" .conf)
    marker=""
    [[ "$name" == "$ACTIVE_PROFILE" ]] && marker=" (active)"
    printf "  [%d] %s%s\n" "$i" "$name" "$marker"
    idx_map[$i]="$name"
    ((i++))
  done
  printf "  [n] Create new profile\n  [0] Cancel\n\n  > "
  read -r c
  if [[ "$c" == "n" ]]; then
    printf "  Profile name: "
    read -r newname
    [[ -z "$newname" ]] && return
    default_profile "$newname"
    printf "\n  Opening editor — add one domain or IP per line, save & exit.\n"
    sleep 1
    ${EDITOR:-nano} "$PROFILES_DIR/$newname.conf"
    ACTIVE_PROFILE="$newname"
    save_config
    printf "\n${GREEN}✓ Created and activated profile: %s${RESET}\n" "$newname"
  elif [[ -n "${idx_map[$c]}" ]]; then
    ACTIVE_PROFILE="${idx_map[$c]}"
    save_config
    printf "\n${GREEN}✓ Active profile set to: %s${RESET}\n" "$ACTIVE_PROFILE"
  fi
}

screen_edit_profile() {
  screen_choose_profile
  printf "\n  Edit the active profile (%s) now? [y/N]: " "$ACTIVE_PROFILE"
  read -r yn
  if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
    ${EDITOR:-nano} "$PROFILES_DIR/$ACTIVE_PROFILE.conf"
    printf "\n${GREEN}✓ Saved.${RESET}\n"
  fi
  press_enter
}

screen_detect() { detect_interface_interactive; }

screen_manual_interface() {
  header
  printf "${BOLD}SET VPN INTERFACE MANUALLY${RESET}\n"; hr
  printf "  Active tunnel-like interfaces right now:\n\n"
  while read -r iface ip; do
    [[ -z "$iface" ]] && continue
    owner=$(detect_interface_owner "$iface")
    printf "    ${CYAN}%-8s${RESET} %-16s ${DIM}%s${RESET}\n" "$iface" "$ip" "$owner"
  done < <(list_candidate_interfaces)
  printf "\n  Enter interface name (e.g. utun4), or blank to cancel: "
  read -r manual
  if [[ -n "$manual" ]]; then
    VPN_INTERFACE="$manual"
    VPN_APP_NAME=$(detect_interface_owner "$manual")
    save_config
    printf "\n${GREEN}✓ Saved: %s (%s)${RESET}\n" "$manual" "$VPN_APP_NAME"
  fi
  press_enter
}

screen_probe_host() {
  header
  printf "${BOLD}PROBE HOST (active tunnel verification)${RESET}\n"; hr
  printf "  Without a probe host, the daemon has one weak fallback signal:\n"
  printf "  'a tunnel interface exists with an IP'. That can be TRUE even\n"
  printf "  after your VPN app dies and leaves a stale interface behind —\n"
  printf "  which is the most likely reason the kill switch stops engaging\n"
  printf "  after your VPN has been up a while.\n\n"
  printf "  Setting a probe host fixes this: the daemon actively pings it\n"
  printf "  to confirm the tunnel really carries traffic before trusting\n"
  printf "  that lone signal. Good choices: your VPN provider's gateway IP,\n"
  printf "  or any host only reachable while the VPN is connected.\n\n"
  printf "  Current probe host: ${CYAN}%s${RESET}\n\n" "${PROBE_HOST:-<none>}"
  printf "  Enter new probe host (blank to clear, or Enter alone to keep as-is): "
  read -r newhost
  if [[ -n "$newhost" ]]; then
    PROBE_HOST="$newhost"
    save_config
    printf "\n${GREEN}✓ Probe host set to: %s${RESET}\n" "$PROBE_HOST"
    printf "  Testing now...\n"
    if probe_tunnel_alive "$VPN_INTERFACE"; then
      printf "  ${GREEN}✓ Probe succeeded — host is reachable.${RESET}\n"
    else
      printf "  ${YELLOW}⚠ Probe failed right now. If your VPN is connected, double-check${RESET}\n"
      printf "  ${YELLOW}  the host is correct and reachable only via the tunnel.${RESET}\n"
    fi
  fi
  press_enter
}

screen_install() {
  header
  printf "${BOLD}INSTALL / MANAGE KILL SWITCH DAEMON${RESET}\n"; hr
  printf "  ${DIM}Tip: press [o]/[f] on the main menu to turn the daemon on/off directly.${RESET}\n\n"
  if [[ -z "$VPN_INTERFACE" ]]; then
    printf "  ${YELLOW}No VPN interface saved yet.${RESET}\n"
    printf "  ${DIM}That's OK — the daemon also detects VPN via default route and scutil.${RESET}\n"
    printf "  ${DIM}Auto-detect (menu [1]) while connected still helps Status display.${RESET}\n\n"
  fi
  if [[ -z "$PROBE_HOST" ]]; then
    printf "  ${YELLOW}No probe host set — recommended for reliable long-run detection.${RESET}\n"
    printf "  ${DIM}See menu option [p] to set one up.${RESET}\n\n"
  fi
  if is_watcher_loaded || daemon_process_running; then
    printf "  Currently ${GREEN}running${RESET}.\n\n  [1] Restart (apply latest config)\n  [2] Stop and remove\n  [0] Back\n\n  > "
    read -r c
    case "$c" in
      1) install_watcher ;;
      2) uninstall_watcher ;;
    esac
  else
    printf "  Not running.\n\n"
    printf "  Watching: ${CYAN}%s${RESET}   Mode: ${YELLOW}%s${RESET}\n\n" "$VPN_INTERFACE" "$MODE"
    printf "  [1] Install and start now\n  [0] Back\n\n  > "
    read -r c
    [[ "$c" == "1" ]] && install_watcher
  fi
  press_enter
}

screen_logs() {
  header
  printf "${BOLD}LOGS${RESET}\n"; hr
  printf "  ${BOLD}Our app log${RESET} ${DIM}(%s)${RESET}\n" "$LOG_FILE"
  tail -n 20 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
  hr
  printf "  ${BOLD}launchd stdout${RESET} ${DIM}(%s/launchd.out.log)${RESET}\n" "$APP_DIR"
  tail -n 10 "$APP_DIR/launchd.out.log" 2>/dev/null | sed 's/^/  /'
  hr
  printf "  ${BOLD}launchd stderr${RESET} ${DIM}(%s/launchd.err.log)${RESET}\n" "$APP_DIR"
  tail -n 10 "$APP_DIR/launchd.err.log" 2>/dev/null | sed 's/^/  /'
  hr
  printf "\n  [f] Live tail (Ctrl+C to stop)   [Enter] Back\n  > "
  read -r c
  if [[ "$c" == "f" ]]; then
    printf "\n${DIM}Live tailing... Ctrl+C to stop.${RESET}\n\n"
    tail -f "$LOG_FILE"
  fi
}

screen_test_block() {
  header
  printf "${BOLD}TEST BLOCK / UNBLOCK${RESET}\n"; hr
  printf "  Use this to verify pf enforcement works, independent of VPN state.\n\n"
  printf "  [1] Force BLOCK now (mode: %s)\n" "$MODE"
  printf "  [2] Force UNBLOCK now\n"
  printf "  [0] Back\n\n  > "
  read -r c
  case "$c" in
    1)
      apply_block "$MODE" "$ACTIVE_PROFILE"
      printf "\n${RED}Block applied.${RESET} Try loading a website now — it should fail.\n"
      printf "Run: ${CYAN}sudo pfctl -a %s -s rules${RESET} to see active rules.\n" "$PF_ANCHOR_NAME"
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
  printf "${BOLD}DEEP DIAGNOSTICS${RESET}\n"; hr

  printf "  ${BOLD}1. Is the daemon process actually running?${RESET}\n"
  proc_line=$(ps aux | grep "[v]pn_kill_switch.sh --daemon")
  if [[ -n "$proc_line" ]]; then
    printf "     ${GREEN}yes${RESET} -> %s\n" "$proc_line"
  else
    printf "     ${RED}NO — daemon is not actually running despite launchctl saying so${RESET}\n"
  fi

  printf "\n  ${BOLD}2. What script path is the plist pointing to?${RESET}\n"
  if [[ -f "$PLIST_PATH" ]]; then
    grep -A4 "ProgramArguments" "$PLIST_PATH" | sed 's/^/     /'
  else
    printf "     ${RED}plist not found at %s${RESET}\n" "$PLIST_PATH"
  fi

  printf "\n  ${BOLD}3. This script's own path:${RESET}\n"
  printf "     %s\n" "$SCRIPT_PATH"

  printf "\n  ${BOLD}4. Current pf anchor rules:${RESET}\n"
  sudo /sbin/pfctl -a "$PF_ANCHOR_NAME" -s rules 2>&1 | sed 's/^/     /'

  printf "\n  ${BOLD}5. Is our anchor registered in the main pf ruleset?${RESET}\n"
  if sudo /sbin/pfctl -s Anchors 2>&1 | grep -q "$PF_ANCHOR_NAME"; then
    printf "     ${GREEN}yes, anchor is registered${RESET}\n"
  else
    printf "     ${RED}NO — anchor is not registered, blocks would be inert${RESET}\n"
  fi

  printf "\n  ${BOLD}6. VPN detection right now:${RESET}\n"
  printf "     configured iface: %s (up=%s)\n" "${VPN_INTERFACE:-none}" "$(interface_is_up "$VPN_INTERFACE" && echo yes || echo no)"
  printf "     default route if: %s (tunnel=%s)\n" "$(default_route_interface)" "$(default_route_is_tunnel && echo yes || echo no)"
  printf "     scutil Connected: %s\n" "$(any_scutil_vpn_connected && echo yes || echo no)"
  printf "     probe host:       %s\n" "${PROBE_HOST:-<none configured>}"
  if live=$(vpn_is_connected 2>/dev/null); then
    printf "     vpn_is_connected:  ${GREEN}YES${RESET} (%s, reason=%s)\n" "${live:-unknown-iface}" "$VPN_CHECK_REASON"
  else
    printf "     vpn_is_connected:  ${RED}NO — should be blocking${RESET} (reason=%s)\n" "$VPN_CHECK_REASON"
  fi

  printf "\n  ${BOLD}7. Last 15 raw log lines:${RESET}\n"
  tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/     /'

  printf "\n  ${BOLD}8. Full launchctl status:${RESET}\n"
  sudo launchctl list "$PLIST_LABEL" 2>&1 | sed 's/^/     /'

  printf "\n  ${BOLD}9. Heartbeat present (loop alive)?${RESET}\n"
  if grep -q "heartbeat:" "$LOG_FILE" 2>/dev/null; then
    printf "     ${GREEN}yes${RESET} — last: %s\n" "$(grep "heartbeat:" "$LOG_FILE" | tail -1)"
  else
    printf "     ${YELLOW}none yet${RESET} (shows up ~60s after start on v2+)\n"
  fi

  press_enter
}

screen_interval() {
  header
  printf "${BOLD}DETECTION METHOD${RESET}\n"; hr
  printf "  The daemon checks VPN state every ${CYAN}1 second${RESET} (fail-safe poll).\n"
  printf "  In parallel, ${CYAN}route -n monitor${RESET} wakes it immediately on any\n"
  printf "  interface/route change so drops are usually caught in well under\n"
  printf "  a second.\n\n"
  printf "  VPN is considered UP if any of these are true, checked in order:\n"
  printf "    1. the configured tunnel interface has a real IPv4\n"
  printf "    2. the default route points at a utun/ipsec/ppp interface\n"
  printf "    3. scutil reports a VPN service as Connected\n"
  printf "    4. some tunnel interface has a real IPv4 ${BOLD}AND${RESET} (if a probe\n"
  printf "       host is set) an active ping through it succeeds\n\n"
  printf "  ${YELLOW}Why #4 needs a probe:${RESET} a VPN app can crash or reconnect badly\n"
  printf "  and leave a dead utunN interface behind with a real-looking IP.\n"
  printf "  Trusting that alone made the kill switch silently stop engaging\n"
  printf "  after the VPN had been up a while. Now, if only #4 applies and no\n"
  printf "  probe host is set, the daemon treats state as DOWN (fail closed)\n"
  printf "  rather than trusting an unverified interface.\n\n"
  printf "  Interface numbers (utun12, utun23, …) change every reconnect on\n"
  printf "  modern VPN apps — the daemon tracks that automatically.\n\n"
  printf "  Set a probe host from the main menu [p] for the most reliable\n"
  printf "  long-running detection.\n"
  press_enter
}

# Prints the numbered menu options + separators. Shared by draw_full_menu
# and redraw_status_block so both stay in sync. Always exactly
# MENU_OPTIONS_LINE_COUNT lines (13: hr, 11 items, hr) plus a final
# "choice > " prompt printed without a trailing newline.
MENU_OPTIONS_LINE_COUNT=13

print_menu_options() {
  hr
  printf "  ${BOLD}[1]${RESET} Auto-detect VPN interface\n"
  printf "  ${BOLD}[2]${RESET} Set VPN interface manually\n"
  printf "  ${BOLD}[3]${RESET} Set mode (ALL traffic / LIST profile)\n"
  printf "  ${BOLD}[4]${RESET} Manage profiles (create/edit/select)\n"
  printf "  ${BOLD}[5]${RESET} About detection method\n"
  printf "  ${BOLD}[6]${RESET} Install / manage kill switch daemon (advanced)\n"
  printf "  ${BOLD}[7]${RESET} View logs\n"
  printf "  ${BOLD}[8]${RESET} Test block/unblock manually\n"
  printf "  ${BOLD}[p]${RESET} Set probe host (fixes stale-interface false positives)\n"
  printf "  ${BOLD}[d]${RESET} Deep diagnostics (find why it's not working)\n"
  printf "  ${BOLD}[0]${RESET} Quit\n"
  hr
  printf "  choice > "
}

# Redraws the whole menu screen (logo, status block, options) from
# scratch. Called once when entering main_menu and again any time we
# return from a submenu, since those may have scrolled/printed output.
draw_full_menu() {
  header
  print_live_status_block
  print_menu_options
}

# Moves the cursor back up to the start of the status block and
# redraws just those lines in place, leaving the logo above untouched
# — this is what makes status feel "live" without clearing or
# scrolling the terminal. Uses the fixed STATUS_BLOCK_LINE_COUNT
# rather than capturing the block's output, since capturing via $(...)
# would swallow the printf calls instead of letting them reach the
# terminal live.
redraw_status_block() {
  local new_status
  new_status=$(print_live_status_block)
  local new_menu
  new_menu=$(print_menu_options)

  # Move cursor up, then SNAP to the left edge of the terminal (\r)
  tput cuu "$((STATUS_BLOCK_LINE_COUNT + MENU_OPTIONS_LINE_COUNT))" 2>/dev/null
  printf "\r"
  
  # Now clear down and print instantly
  tput ed 2>/dev/null
  printf "%s\n%s" "$new_status" "$new_menu"
}

main_menu() {
  draw_full_menu

  while true; do
    # Wait up to 1s for a keypress; on timeout, just refresh the status
    # block in place (no full clear, no scrolling) and keep waiting.
    if read -t 1 -r -n 1 key; then
      case "$key" in
        o|O)
          if daemon_process_running || is_watcher_loaded; then
            printf "\n${DIM}Already on.${RESET}\n"
          else
            printf "\n"
            install_watcher
          fi
          printf "\n${GRAY}Press Enter to continue...${RESET}"; read -r
          draw_full_menu
          ;;
        f|F)
          if daemon_process_running || is_watcher_loaded; then
            printf "\n"
            uninstall_watcher
          else
            printf "\n${DIM}Already off.${RESET}\n"
          fi
          printf "\n${GRAY}Press Enter to continue...${RESET}"; read -r
          draw_full_menu
          ;;
        r|R)
          if daemon_process_running || is_watcher_loaded; then
            printf "\n"
            install_watcher
            printf "\n${GRAY}Press Enter to continue...${RESET}"; read -r
            draw_full_menu
          fi
          ;;
        1) printf "\n"; screen_detect; draw_full_menu ;;
        2) printf "\n"; screen_manual_interface; draw_full_menu ;;
        3) printf "\n"; screen_set_mode; draw_full_menu ;;
        4) printf "\n"; screen_edit_profile; draw_full_menu ;;
        5) printf "\n"; screen_interval; draw_full_menu ;;
        6) printf "\n"; screen_install; draw_full_menu ;;
        7) printf "\n"; screen_logs; draw_full_menu ;;
        8) printf "\n"; screen_test_block; draw_full_menu ;;
        p|P) printf "\n"; screen_probe_host; draw_full_menu ;;
        d) printf "\n"; screen_diagnostics; draw_full_menu ;;
        0) printf "\n\n${DIM}bye.${RESET}\n"; exit 0 ;;
        *) ;;
      esac
    else
      redraw_status_block
    fi
  done
}

main_menu
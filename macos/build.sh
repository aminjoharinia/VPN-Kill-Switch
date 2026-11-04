#!/bin/bash
# Builds the macOS version of VPN Kill Switch, then asks whether to put
# it in Applications.
#
#   ./macos/build.sh           build, then ask
#   ./macos/build.sh --yes     build and install to /Applications without asking
#
# Installing only replaces the app. The kill switch daemon is a separate
# root process and keeps running; if the app then reports "Daemon is out
# of date", press Update in it to install the matching daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VPN Kill Switch.app"
BUILT="$ROOT/output/$APP_NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$ROOT/gui/build.sh"
[[ -d "$BUILT" ]] || { echo "Build failed: $BUILT not found"; exit 1; }

VERSION="$(defaults read "$BUILT/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"

# Which copy is installed now, if any, so the question can say what it replaces.
installed_version() {
    [[ -d "$1/$APP_NAME" ]] || return 0
    defaults read "$1/$APP_NAME/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?"
}
SYSTEM_VER="$(installed_version /Applications)"
USER_VER="$(installed_version "$HOME/Applications")"

choice=""
if [[ "${1:-}" == "--yes" ]]; then
    choice=1
elif [[ -t 0 ]]; then
    echo
    echo "Built v$VERSION. Install it?"
    echo "  1) /Applications        (all users, asks for your password)${SYSTEM_VER:+  — replaces v$SYSTEM_VER}"
    echo "  2) ~/Applications       (just you, no password)${USER_VER:+  — replaces v$USER_VER}"
    echo "  n) No, leave it in output/"
    read -r -p "Choice [1/2/N]: " choice
else
    echo "Not running in a terminal; skipping the install question."
fi

case "$choice" in
    1) DEST="/Applications"; SUDO="sudo" ;;
    2) DEST="$HOME/Applications"; SUDO="" ; mkdir -p "$DEST" ;;
    *)
        echo
        echo "Not installed. The build is at:"
        echo "  $BUILT"
        echo "Run it with:  open '$BUILT'"
        exit 0
        ;;
esac

# Quit the running app first so the bundle is not replaced underneath it.
# Only the GUI quits — protection stays on.
if pgrep -f "$APP_NAME/Contents/MacOS" >/dev/null; then
    echo "==> Quitting the running app (the kill switch keeps running)"
    osascript -e 'quit app "VPN Kill Switch"' 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -f "$APP_NAME/Contents/MacOS" >/dev/null || break
        sleep 0.5
    done
    pkill -f "$APP_NAME/Contents/MacOS" 2>/dev/null || true
fi

echo "==> Installing v$VERSION to $DEST"
$SUDO rm -rf "$DEST/$APP_NAME"
$SUDO ditto "$BUILT" "$DEST/$APP_NAME"

# Register with LaunchServices so Spotlight and the Dock pick up the new
# version and its icon straight away.
"$LSREGISTER" -f "$DEST/$APP_NAME" >/dev/null 2>&1 || true

# Two installed copies means Spotlight and the Dock may open the old one.
OTHER="$HOME/Applications"; [[ "$DEST" == "$HOME/Applications" ]] && OTHER="/Applications"
if [[ -d "$OTHER/$APP_NAME" ]]; then
    echo
    echo "Note: an older copy is still in $OTHER — Spotlight may open that one."
    if [[ "$OTHER" == "/Applications" ]]; then
        echo "      Remove it with:  sudo rm -rf '/Applications/$APP_NAME'"
    else
        echo "      Remove it with:  rm -rf '$OTHER/$APP_NAME'"
    fi
fi

echo
echo "Installed: $DEST/$APP_NAME  (v$VERSION)"
if [[ -t 0 ]]; then
    read -r -p "Open it now? [Y/n]: " open_now
    [[ "$open_now" =~ ^[Nn] ]] || open "$DEST/$APP_NAME"
fi

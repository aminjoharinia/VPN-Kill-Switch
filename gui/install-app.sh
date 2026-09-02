#!/bin/bash
# Builds and installs the app so it behaves like any other Mac app —
# double-clickable, in Spotlight, in Launchpad.
#
#   ./gui/install-app.sh          -> ~/Applications  (no password)
#   ./gui/install-app.sh --system -> /Applications   (asks for password)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/gui/build.sh"
SRC="$ROOT/output/VPN Kill Switch.app"

if [[ "${1:-}" == "--system" ]]; then
    DEST="/Applications"
    echo "==> Installing to $DEST (needs your password)"
    osascript -e "do shell script \"rm -rf '/Applications/VPN Kill Switch.app' && ditto '$SRC' '/Applications/VPN Kill Switch.app'\" with administrator privileges"
else
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "==> Installing to $DEST"
    rm -rf "$DEST/VPN Kill Switch.app"
    ditto "$SRC" "$DEST/VPN Kill Switch.app"
fi

# Register with LaunchServices so Spotlight and the Dock pick up the app
# and its icon immediately instead of whenever the cache next refreshes.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST/VPN Kill Switch.app" >/dev/null 2>&1 || true

echo
echo "Installed: $DEST/VPN Kill Switch.app"
echo "Launch it from Spotlight (Cmd-Space, \"VPN Kill Switch\") or:"
echo "  open '$DEST/VPN Kill Switch.app'"

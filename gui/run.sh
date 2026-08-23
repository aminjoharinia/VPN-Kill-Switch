#!/bin/bash
# Rebuild everything and relaunch the app. Safe to run repeatedly.
#
# Only the GUI is restarted. The kill switch daemon is a separate root
# process under launchd — quitting or rebuilding the app never drops your
# protection. Use the app's Turn Off (or `sudo vpnks uninstall`) for that.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Quitting the running app (daemon keeps running)"
osascript -e 'quit app "VPN Kill Switch"' 2>/dev/null || true
pkill -f "VPN Kill Switch.app/Contents/MacOS" 2>/dev/null || true
sleep 1

"$ROOT/gui/build.sh"

APP="$ROOT/gui/.build/Build/Products/Release/VPN Kill Switch.app"
echo "==> Launching"
open "$APP"

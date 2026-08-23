#!/bin/bash
# Builds the daemon CLI and the GUI, then bundles the CLI inside the app
# so a single .app can install everything it needs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building vpnks daemon (release)"
cd "$ROOT/swift"
swift build -c release
CLI="$ROOT/swift/.build/release/vpnks"

echo "==> Building VPN Kill Switch.app (release)"
cd "$ROOT"
xcodebuild -project gui/VPNKillSwitch.xcodeproj \
           -scheme VPNKillSwitch \
           -configuration Release \
           -derivedDataPath gui/.build \
           build > /dev/null

APP="$ROOT/gui/.build/Build/Products/Release/VPN Kill Switch.app"
[[ -d "$APP" ]] || { echo "build failed: app not found"; exit 1; }

echo "==> Bundling the daemon inside the app"
cp "$CLI" "$APP/Contents/Resources/vpnks"
chmod +x "$APP/Contents/Resources/vpnks"

# Re-sign ad-hoc: adding a file to the bundle invalidates the signature,
# and macOS refuses to launch an app whose seal is broken.
codesign --force --deep --sign - "$APP" 2>/dev/null

# macOS caches app icons by bundle path; nudge LaunchServices so a changed
# icon actually shows up in the Dock and Finder.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo
echo "Built: $APP"
echo "Open with:  open '$APP'"

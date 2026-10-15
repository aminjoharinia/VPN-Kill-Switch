#!/bin/bash
# Builds the Linux version — the vpnks daemon and the VPN Kill Switch app —
# and packages both as a .deb, then asks whether to install it.
#
#   ./linux/build.sh              build, package, then ask
#   ./linux/build.sh --yes        build, package and install without asking
#   ./linux/build.sh --no-install build and package only
#
# Runs on Ubuntu 22.04 or later. Needs Go 1.26+ and the GTK/WebKit headers:
#   sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev
# From macOS, use ./linux/docker-build.sh instead.
#
# Installing only replaces the app. The daemon runs from its own copy and
# keeps protecting you; if the app then says "Daemon is out of date", press
# Update in it to install the matching daemon.
set -euo pipefail
LINUX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LINUX/.." && pwd)"

# Version is the build date, YY.MM.DD, as on macOS; the time of day keeps
# repeated builds on one date in order. Override with VPNKS_VERSION=….
VERSION="${VPNKS_VERSION:-$(date +%y.%m.%d)}"
BUILD_NUM="${VPNKS_BUILD:-$(date +%H%M%S)}"
ARCH="$(go env GOARCH)"
DEB_ARCH="$ARCH"   # Go and Debian agree on amd64 and arm64
echo "==> Version $VERSION (build $BUILD_NUM), $ARCH"

for pc in gtk+-3.0 webkit2gtk-4.1; do
    pkg-config --exists "$pc" || {
        echo "Missing $pc. Install the build dependencies:"
        echo "  sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev"
        exit 1
    }
done

OUT="$ROOT/output/linux"
mkdir -p "$OUT"
LDFLAGS="-s -w -X vpnks/internal/core.Version=$VERSION -X vpnks/internal/core.Number=$BUILD_NUM"

cd "$LINUX"
echo "==> Building vpnks daemon"
CGO_ENABLED=0 go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/vpnks" ./cmd/vpnks

echo "==> Building VPN Kill Switch app"
# The Wails tags a manual build needs: desktop + production, and WebKitGTK
# 4.1 (Ubuntu 22.04 and later).
CGO_ENABLED=1 go build -trimpath -tags desktop,production,webkit2_41 -ldflags "$LDFLAGS" \
    -o "$OUT/vpn-kill-switch" ./app

echo "==> Packaging"
PKG="$OUT/pkg"
rm -rf "$PKG"
install -Dm755 "$OUT/vpnks"            "$PKG/usr/lib/vpn-kill-switch/vpnks"
install -Dm755 "$OUT/vpn-kill-switch"  "$PKG/usr/lib/vpn-kill-switch/vpn-kill-switch"
mkdir -p "$PKG/usr/bin"
ln -s ../lib/vpn-kill-switch/vpn-kill-switch "$PKG/usr/bin/vpn-kill-switch"
ln -s ../lib/vpn-kill-switch/vpnks           "$PKG/usr/bin/vpnks"
install -Dm644 "$LINUX/packaging/vpn-kill-switch.desktop" "$PKG/usr/share/applications/vpn-kill-switch.desktop"
install -Dm644 "$LINUX/packaging/com.vpnkillswitch.policy" "$PKG/usr/share/polkit-1/actions/com.vpnkillswitch.policy"
for size in 32 64 128 256 512; do
    install -Dm644 "$LINUX/packaging/icons/$size.png" \
        "$PKG/usr/share/icons/hicolor/${size}x${size}/apps/vpn-kill-switch.png"
done

mkdir -p "$PKG/DEBIAN"
SIZE_KB="$(du -sk "$PKG/usr" | cut -f1)"
cat > "$PKG/DEBIAN/control" <<EOF
Package: vpn-kill-switch
Version: $VERSION+$BUILD_NUM
Architecture: $DEB_ARCH
Maintainer: VPN Kill Switch <noreply@localhost>
Installed-Size: $SIZE_KB
Depends: nftables, systemd, pkexec | policykit-1, libgtk-3-0t64 | libgtk-3-0, libwebkit2gtk-4.1-0
Recommends: gnome-shell-extension-appindicator
Section: net
Priority: optional
Description: Cuts your internet the moment your VPN stops carrying traffic
 A kill switch for any VPN that creates a tunnel interface (WireGuard,
 OpenVPN, sing-box, Xray and similar clients). A small root daemon proves
 the tunnel carries traffic every second and blocks everything else with
 nftables the moment it does not. The app shows live status, settings,
 history and activity, with a tray icon.
EOF

# Removing the package must never leave the machine firewalled with
# nothing left to unfirewall it. Upgrades leave the daemon running.
cat > "$PKG/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    /usr/lib/vpn-kill-switch/vpnks uninstall >/dev/null 2>&1 || true
    rm -rf /usr/local/lib/vpn-kill-switch
fi
exit 0
EOF
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
exit 0
EOF
cat > "$PKG/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "purge" ]; then
    rm -rf /var/lib/vpn-kill-switch
fi
exit 0
EOF
chmod 755 "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"

DEB="$OUT/vpn-kill-switch_${VERSION}+${BUILD_NUM}_${DEB_ARCH}.deb"
rm -f "$OUT"/vpn-kill-switch_*_"$DEB_ARCH".deb
dpkg-deb --root-owner-group --build "$PKG" "$DEB" >/dev/null
rm -rf "$PKG"

echo
echo "Output:  $DEB"
echo "         $OUT/vpn-kill-switch   (app)"
echo "         $OUT/vpnks             (daemon CLI)"

choice=""
case "${1:-}" in
    --yes) choice=y ;;
    --no-install) exit 0 ;;
    *)
        if [[ -t 0 ]]; then
            read -r -p "Install it now (asks for your password)? [y/N]: " choice
        fi
        ;;
esac
if [[ "$choice" =~ ^[Yy] ]]; then
    # Quit the running app first; the kill switch keeps running.
    pkill -x vpn-kill-switch 2>/dev/null || true
    sudo apt-get install -y --reinstall "$DEB"
    echo
    echo "Installed. Open VPN Kill Switch from the app grid, or run: vpn-kill-switch"
else
    echo "Install it with:  sudo apt install '$DEB'"
fi

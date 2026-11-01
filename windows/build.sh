#!/bin/bash
# Builds the Windows version — the vpnks daemon and the VPN Kill Switch app —
# by cross-compiling from macOS or Linux. Nothing needs to run on Windows.
#
#   ./windows/build.sh              amd64 and arm64
#   ./windows/build.sh amd64        one architecture (amd64 or arm64)
#
# For each architecture it writes to output/windows/:
#   VPN-Kill-Switch-<version>-<arch>.zip        the two programs; runs from
#                                               any folder
#   VPN-Kill-Switch-Setup-<version>-<arch>.exe  an installer, if NSIS is
#                                               installed (brew install makensis)
#
# Needs Go 1.26+. No cgo and no Windows SDK: the app's webview (WebView2)
# and every system call are reached from pure Go.
set -euo pipefail
WIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$WIN/.." && pwd)"
GO_SRC="$ROOT/go"
ICONS="$ROOT/linux/packaging/icons"

# Version is the build date, YY.MM.DD, as on macOS and Linux; the time of
# day keeps repeated builds on one date in order. Override with VPNKS_VERSION=….
VERSION="${VPNKS_VERSION:-$(date +%y.%m.%d)}"
BUILD_NUM="${VPNKS_BUILD:-$(date +%H%M%S)}"
ARCHES=("${@:-amd64 arm64}")
# shellcheck disable=SC2206
ARCHES=(${ARCHES[*]})
echo "==> Version $VERSION (build $BUILD_NUM): ${ARCHES[*]}"

OUT="$ROOT/output/windows"
mkdir -p "$OUT"
LDFLAGS="-s -w -X vpnks/internal/core.Version=$VERSION -X vpnks/internal/core.Number=$BUILD_NUM"
ICON_PNGS=("$ICONS/32.png" "$ICONS/64.png" "$ICONS/128.png" "$ICONS/256.png")

cd "$GO_SRC"
for ARCH in "${ARCHES[@]}"; do
    case "$ARCH" in amd64|arm64) ;; *) echo "Unknown architecture: $ARCH (amd64 or arm64)"; exit 1 ;; esac
    BIN="$OUT/$ARCH"
    rm -rf "$BIN"
    mkdir -p "$BIN"

    echo "==> [$ARCH] Resources (icon, manifest)"
    go run ./tools/winres -arch "$ARCH" -manifest gui -out "app/rsrc_windows_$ARCH.syso" \
        -ico "$OUT/vpn-kill-switch.ico" "${ICON_PNGS[@]}"
    go run ./tools/winres -arch "$ARCH" -manifest cli -out "cmd/vpnks/rsrc_windows_$ARCH.syso" "${ICON_PNGS[@]}"

    echo "==> [$ARCH] Building vpnks daemon"
    GOOS=windows GOARCH="$ARCH" CGO_ENABLED=0 go build -trimpath -ldflags "$LDFLAGS" \
        -o "$BIN/vpnks.exe" ./cmd/vpnks

    echo "==> [$ARCH] Building VPN Kill Switch app"
    # The Wails tags a manual build needs; -H windowsgui: no console window.
    GOOS=windows GOARCH="$ARCH" CGO_ENABLED=0 go build -trimpath -tags desktop,production \
        -ldflags "$LDFLAGS -H windowsgui" -o "$BIN/vpn-kill-switch.exe" ./app

    ZIP="$OUT/VPN-Kill-Switch-$VERSION-$ARCH.zip"
    rm -f "$ZIP"
    (cd "$BIN" && zip -q -X "$ZIP" vpn-kill-switch.exe vpnks.exe)
    echo "    $ZIP"

    if command -v makensis >/dev/null 2>&1; then
        echo "==> [$ARCH] Installer"
        SETUP="$OUT/VPN-Kill-Switch-Setup-$VERSION-$ARCH.exe"
        makensis -V2 \
            -DARCH="$ARCH" -DVERSION="$VERSION" -DBUILD="$BUILD_NUM" \
            -DBINDIR="$BIN" -DICON="$OUT/vpn-kill-switch.ico" -DOUTFILE="$SETUP" \
            "$WIN/packaging/installer.nsi"
        echo "    $SETUP"
    fi
done

echo
if ! command -v makensis >/dev/null 2>&1; then
    echo "No installer built: NSIS is not installed (brew install makensis, or apt install nsis)."
    echo "The .zip runs from any folder: unzip it and open vpn-kill-switch.exe."
fi
echo "On Apple Silicon, Windows in Parallels or UTM is arm64; most PCs are amd64."

#!/bin/bash
# Builds VPN Kill Switch for the system you are on, then offers to install it.
#
#   ./build.sh                  this computer's system (macOS or Linux)
#   ./build.sh macos  [--yes]   macOS app        (on a Mac, with Xcode)
#   ./build.sh linux  [--yes]   Linux .deb       (on Ubuntu; from a Mac, in Docker)
#   ./build.sh windows [arch]   Windows programs (cross-compiled from macOS or Linux)
#
# On Windows, run build.cmd instead; it builds natively with PowerShell.
# Each system's own script does the work: macos/build.sh, linux/build.sh,
# windows/build.sh. Anything after the system name is passed on to it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
    Darwin) HOST=macos ;;
    Linux) HOST=linux ;;
    MINGW*|MSYS*|CYGWIN*) HOST=windows ;;
    *) HOST=unknown ;;
esac

TARGET="$HOST"
case "${1:-}" in
    macos|mac) TARGET=macos; shift ;;
    linux) TARGET=linux; shift ;;
    windows|win) TARGET=windows; shift ;;
    -h|--help)
        sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac

case "$TARGET/$HOST" in
    macos/macos)     exec "$ROOT/macos/build.sh" "$@" ;;
    macos/*)
        echo "The macOS app can only be built on a Mac (it needs Xcode)."
        exit 1 ;;
    linux/linux)     exec "$ROOT/linux/build.sh" "$@" ;;
    linux/*)
        echo "==> Not on Linux: building the .deb in an Ubuntu container (Docker)"
        exec "$ROOT/linux/docker-build.sh" "$@" ;;
    windows/windows)
        echo "On Windows, run build.cmd (it builds natively with PowerShell)."
        exit 1 ;;
    windows/*)       exec "$ROOT/windows/build.sh" "$@" ;;
    *)
        echo "Unknown system. Choose one: ./build.sh macos | linux | windows"
        exit 1 ;;
esac

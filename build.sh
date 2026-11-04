#!/bin/bash
# Builds VPN Kill Switch for the system you are on, then offers to install it.
#
#   ./build.sh          on macOS: the Mac app    (macos/build.sh)
#                       on Linux: the .deb       (linux/build.sh)
#   ./build.sh --yes    the same, installing without asking
#
# On Windows, run build.cmd instead. Each system builds its own version;
# there is no cross-compiling. Arguments are passed on to the system's script.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
    Darwin) exec "$ROOT/macos/build.sh" "$@" ;;
    Linux) exec "$ROOT/linux/build.sh" "$@" ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "On Windows, run build.cmd instead."
        exit 1 ;;
    *)
        echo "Unsupported system: $(uname -s). VPN Kill Switch builds on macOS, Linux and Windows."
        exit 1 ;;
esac

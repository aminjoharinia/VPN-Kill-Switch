#!/bin/bash
# Builds the Linux .deb inside an Ubuntu 24.04 container, for building on
# macOS (or anywhere without the GTK/WebKit headers).
#
#   ./linux/docker-build.sh              amd64 (most Ubuntu PCs)
#   ./linux/docker-build.sh arm64        ARM machines
#
# The result lands in output/linux/. Needs Docker; amd64 on Apple Silicon
# runs under emulation and takes a few minutes the first time.
set -euo pipefail
LINUX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LINUX/.." && pwd)"
ARCH="${1:-amd64}"
IMAGE="vpnks-linux-builder:$ARCH"

echo "==> Preparing the build image ($ARCH)"
docker build --platform "linux/$ARCH" -q -t "$IMAGE" -f "$LINUX/packaging/Dockerfile.build" "$LINUX/packaging" >/dev/null

# Module and build caches survive between runs in named volumes.
docker run --rm --platform "linux/$ARCH" \
    -e VPNKS_VERSION="${VPNKS_VERSION:-$(date +%y.%m.%d)}" \
    -e VPNKS_BUILD="${VPNKS_BUILD:-$(date +%H%M%S)}" \
    -v "$ROOT:/src" \
    -v "vpnks-gomod-$ARCH:/root/go/pkg/mod" \
    -v "vpnks-gocache-$ARCH:/root/.cache/go-build" \
    "$IMAGE" ./linux/build.sh --no-install

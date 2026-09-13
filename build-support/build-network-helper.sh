#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT="${1:?usage: build-network-helper.sh OUTPUT}"
command -v go >/dev/null 2>&1 || { echo "Go 1.25 or newer is required for VPN-compatible networking" >&2; exit 1; }
mkdir -p "$(dirname -- "$OUTPUT")"
cd "$ROOT_DIR/network-helper"
# Darwin's native resolver follows scoped system/VPN DNS. Do not build netgo.
CGO_ENABLED=1 go build -mod=readonly -trimpath -ldflags='-s -w' -o "$OUTPUT" .

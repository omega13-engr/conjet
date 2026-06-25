#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/build-support/conjet-debug.entitlements"

if [ ! -x "$ROOT/.build/debug/conjet" ] || [ ! -x "$ROOT/.build/debug/conjetd" ]; then
  echo "debug binaries are missing; run swift build first" >&2
  exit 1
fi

codesign --force --sign - --entitlements "$ENTITLEMENTS" "$ROOT/.build/debug/conjet"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$ROOT/.build/debug/conjetd"
for jetstream in "$ROOT/target/debug/jetstream" "$ROOT/target/release/jetstream"; do
  if [ -x "$jetstream" ]; then
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$jetstream"
  fi
done

codesign -dvvv --entitlements :- "$ROOT/.build/debug/conjetd" >/dev/null 2>&1
echo "signed debug Conjet tools with development virtualization entitlements"

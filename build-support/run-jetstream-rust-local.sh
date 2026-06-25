#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_BASE="/Volumes/ExternalSSD/dev_workspace/tmp"
if [ ! -d "$TMP_BASE" ]; then
  TMP_BASE="/tmp"
fi
QA_ROOT="$(mktemp -d "$TMP_BASE/conjet-jetstream-rust.XXXXXX")"

echo "jetstream-rust: qa root: $QA_ROOT"
cargo test --manifest-path "$ROOT/jetstream/Cargo.toml" --target-dir "$QA_ROOT/target"
cargo build --manifest-path "$ROOT/jetstream/Cargo.toml" --target-dir "$QA_ROOT/target"

if [ "${CONJET_RUN_HVF_SMOKE:-0}" = "1" ]; then
  codesign --force --sign - --entitlements "$ROOT/build-support/conjet-debug.entitlements" "$QA_ROOT/target/debug/jetstream" >/dev/null
  "$QA_ROOT/target/debug/jetstream" smoke --json > "$QA_ROOT/hvf-smoke.json"
  cat "$QA_ROOT/hvf-smoke.json"
else
  echo "jetstream-rust: skipping HVF smoke; set CONJET_RUN_HVF_SMOKE=1 to require Hypervisor.framework entitlement"
fi

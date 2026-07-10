#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: run-rust-vmm-memory-qa.sh --manifest PATH [options]

Boot an isolated Rust HVF Conjet Core VM, exercise the live memory-control
socket, and record host RSS/physical-footprint evidence before and after a
balloon shrink.

Required:
  --manifest PATH              VM asset manifest for scratch/isolated assets

Options:
  --vmm PATH                   Rust VMM binary (default: build under QA root)
  --qa-root DIR                Artifact directory (default: mktemp under /Volumes/ExternalSSD/dev_workspace/tmp)
  --memory-mib N               Configured guest memory MiB (default: 8192)
  --cpus N                     vCPU count (default: 4)
  --target-mib N               Live target MiB after shrink (default: 4096)
  --timeout-seconds N          Readiness timeout (default: 600)
  --settle-seconds N           Seconds to wait after shrink (default: 45)
  --min-footprint-drop-mib N   Optional required footprint drop (default: 0)
  --max-footprint-over-target-mib N
                               Allowed footprint above target (default: 1024)
  --max-shared-memory-regions N
                               Maximum post-reclaim VM map regions (default: 512)
  --no-build                   Do not build the default Rust VMM first
  --skip-sign                  Do not ad-hoc sign the Rust VMM with debug entitlements
  -h, --help                   Show this help

The manifest must already point at scratch disks, logs, and sockets. This script
does not stop, restart, or inspect any live Conjet app/daemon/VM.
USAGE
}

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEFAULT_TMP_PARENT="/Volumes/ExternalSSD/dev_workspace/tmp"
if [ ! -d "$DEFAULT_TMP_PARENT" ]; then
  DEFAULT_TMP_PARENT="/tmp"
fi

MANIFEST=""
VMM=""
QA_ROOT=""
MEMORY_MIB=8192
CPUS=4
TARGET_MIB=4096
TIMEOUT_SECONDS=600
SETTLE_SECONDS=45
MIN_FOOTPRINT_DROP_MIB=0
MAX_FOOTPRINT_OVER_TARGET_MIB=1024
MAX_SHARED_MEMORY_REGIONS=512
BUILD_VMM=1
SIGN_VMM=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      MANIFEST="${2:?missing value for --manifest}"
      shift 2
      ;;
    --vmm)
      VMM="${2:?missing value for --vmm}"
      shift 2
      ;;
    --qa-root)
      QA_ROOT="${2:?missing value for --qa-root}"
      shift 2
      ;;
    --memory-mib)
      MEMORY_MIB="${2:?missing value for --memory-mib}"
      shift 2
      ;;
    --cpus)
      CPUS="${2:?missing value for --cpus}"
      shift 2
      ;;
    --target-mib)
      TARGET_MIB="${2:?missing value for --target-mib}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:?missing value for --timeout-seconds}"
      shift 2
      ;;
    --settle-seconds)
      SETTLE_SECONDS="${2:?missing value for --settle-seconds}"
      shift 2
      ;;
    --min-footprint-drop-mib)
      MIN_FOOTPRINT_DROP_MIB="${2:?missing value for --min-footprint-drop-mib}"
      shift 2
      ;;
    --max-footprint-over-target-mib)
      MAX_FOOTPRINT_OVER_TARGET_MIB="${2:?missing value for --max-footprint-over-target-mib}"
      shift 2
      ;;
    --max-shared-memory-regions)
      MAX_SHARED_MEMORY_REGIONS="${2:?missing value for --max-shared-memory-regions}"
      shift 2
      ;;
    --no-build)
      BUILD_VMM=0
      shift
      ;;
    --skip-sign)
      SIGN_VMM=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$MANIFEST" ]; then
  echo "--manifest is required" >&2
  usage
  exit 2
fi
if [ ! -f "$MANIFEST" ]; then
  echo "manifest does not exist: $MANIFEST" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi
if ! command -v nc >/dev/null 2>&1; then
  echo "nc is required" >&2
  exit 1
fi

case "$MEMORY_MIB:$CPUS:$TARGET_MIB:$TIMEOUT_SECONDS:$SETTLE_SECONDS:$MIN_FOOTPRINT_DROP_MIB:$MAX_FOOTPRINT_OVER_TARGET_MIB:$MAX_SHARED_MEMORY_REGIONS" in
  *[!0-9:]*)
    echo "numeric options must be positive integers" >&2
    exit 2
    ;;
esac

if [ -z "$QA_ROOT" ]; then
  QA_ROOT="$(mktemp -d "$DEFAULT_TMP_PARENT/conjet-rust-memory-qa.XXXXXX")"
else
  mkdir -p "$QA_ROOT"
fi

if [ -z "$VMM" ]; then
  VMM="$QA_ROOT/cargo-target/debug/jetstream"
  if [ "$BUILD_VMM" -eq 1 ]; then
    cargo build --manifest-path "$ROOT_DIR/jetstream/Cargo.toml" --target-dir "$QA_ROOT/cargo-target"
  fi
fi
if [ ! -x "$VMM" ]; then
  echo "Rust VMM is not executable: $VMM" >&2
  exit 1
fi
if [ "$SIGN_VMM" -eq 1 ]; then
  ENTITLEMENTS="$ROOT_DIR/build-support/conjet-debug.entitlements"
  if [ ! -f "$ENTITLEMENTS" ]; then
    echo "entitlements file does not exist: $ENTITLEMENTS" >&2
    exit 1
  fi
  if ! /usr/bin/codesign -d --entitlements :- "$VMM" 2>/dev/null \
      | grep -q "com.apple.security.hypervisor"; then
    /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$VMM" >/dev/null
  fi
fi

DOCKER_SOCKET="$(jq -r '.dockerSocketPath' "$MANIFEST")"
SERIAL_LOG="$(jq -r '.serialLogPath' "$MANIFEST")"
if [ -z "$DOCKER_SOCKET" ] || [ "$DOCKER_SOCKET" = "null" ]; then
  echo "manifest is missing dockerSocketPath" >&2
  exit 1
fi
if [ -z "$SERIAL_LOG" ] || [ "$SERIAL_LOG" = "null" ]; then
  echo "manifest is missing serialLogPath" >&2
  exit 1
fi

RUN_DIR="$(dirname -- "$DOCKER_SOCKET")"
MEMORY_SOCKET="$RUN_DIR/memory.sock"
CONTROL_SOCKET="$RUN_DIR/rust-memory-control.sock"
if [ "$(printf '%s' "$CONTROL_SOCKET" | wc -c | tr -d ' ')" -ge 104 ]; then
  CONTROL_SOCKET="/tmp/conjet-rust-memory-qa-$$/rust-memory-control.sock"
fi
STDOUT_LOG="$QA_ROOT/jetstream-boot.stdout.json"
STDERR_LOG="$QA_ROOT/jetstream-boot.stderr.log"
PID_FILE="$QA_ROOT/jetstream.pid"
SUMMARY_JSON="$QA_ROOT/rust-memory-qa-summary.json"

mkdir -p "$RUN_DIR" "$(dirname -- "$SERIAL_LOG")"
rm -f "$DOCKER_SOCKET" "$MEMORY_SOCKET" "$CONTROL_SOCKET" "$STDOUT_LOG" "$STDERR_LOG"

VMM_PID=""
cleanup() {
  if [ -n "$VMM_PID" ] && kill -0 "$VMM_PID" >/dev/null 2>&1; then
    kill "$VMM_PID" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$VMM_PID" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    if kill -0 "$VMM_PID" >/dev/null 2>&1; then
      kill -9 "$VMM_PID" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

nohup "$VMM" boot \
  --manifest "$MANIFEST" \
  --memory-mib "$MEMORY_MIB" \
  --cpus "$CPUS" \
  --max-exits 18446744073709551615 \
  --max-runtime-ms 0 \
  --host-tick-ms 25 \
  --require-docker-ready \
  --docker-probe-timeout-ms "$((TIMEOUT_SECONDS * 1000))" \
  --hold-after-ready-forever \
  --memory-control-socket "$CONTROL_SOCKET" \
  --json >"$STDOUT_LOG" 2>"$STDERR_LOG" &
VMM_PID=$!
printf '%s\n' "$VMM_PID" >"$PID_FILE"

wait_for_socket() {
  local label="$1"
  local socket_path="$2"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [ "$SECONDS" -le "$deadline" ]; do
    if [ -S "$socket_path" ]; then
      return 0
    fi
    if ! kill -0 "$VMM_PID" >/dev/null 2>&1; then
      echo "Rust VMM exited before $label socket was ready" >&2
      cat "$STDERR_LOG" >&2 || true
      cat "$STDOUT_LOG" >&2 || true
      return 1
    fi
    sleep 0.5
  done
  echo "timed out waiting for $label socket: $socket_path" >&2
  return 1
}

control_request() {
  local request="$1"
  printf '%s\n' "$request" | nc -U "$CONTROL_SOCKET"
}

http_unix_get() {
  local socket_path="$1"
  local path="$2"
  printf 'GET %s HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n' "$path" \
    | nc -U "$socket_path" \
    | awk 'found { print } /^\r?$/ { found=1 }'
}

wait_for_docker_ping() {
  local output_path="$1"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [ "$SECONDS" -le "$deadline" ]; do
    if [ -S "$DOCKER_SOCKET" ]; then
      if printf 'GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n' \
          | nc -U "$DOCKER_SOCKET" >"$output_path" 2>/dev/null \
          && grep -q 'OK' "$output_path"; then
        return 0
      fi
    fi
    if ! kill -0 "$VMM_PID" >/dev/null 2>&1; then
      echo "Rust VMM exited before Docker API was ready" >&2
      cat "$STDERR_LOG" >&2 || true
      cat "$STDOUT_LOG" >&2 || true
      return 1
    fi
    sleep 0.5
  done
  echo "timed out waiting for Docker API readiness: $DOCKER_SOCKET" >&2
  return 1
}

wait_for_guest_metrics() {
  local output_path="$1"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [ "$SECONDS" -le "$deadline" ]; do
    if [ -S "$MEMORY_SOCKET" ]; then
      if http_unix_get "$MEMORY_SOCKET" "/conjet-memory-metrics" >"$output_path" 2>/dev/null \
          && jq -e '(.mem_available // .mem_available_bytes // null) != null' "$output_path" >/dev/null 2>&1; then
        return 0
      fi
    fi
    if ! kill -0 "$VMM_PID" >/dev/null 2>&1; then
      echo "Rust VMM exited before guest memory metrics were ready" >&2
      cat "$STDERR_LOG" >&2 || true
      cat "$STDOUT_LOG" >&2 || true
      return 1
    fi
    sleep 0.5
  done
  echo "timed out waiting for guest memory metrics: $MEMORY_SOCKET" >&2
  return 1
}

wait_for_socket "memory-control" "$CONTROL_SOCKET"
CONTROL_BEFORE="$QA_ROOT/control-before.json"
control_request '{"command":"metrics"}' >"$CONTROL_BEFORE"
jq -e '.ok == true' "$CONTROL_BEFORE" >/dev/null

DOCKER_PING="$QA_ROOT/docker-ping.txt"
wait_for_docker_ping "$DOCKER_PING"

GUEST_METRICS_BEFORE="$QA_ROOT/guest-memory-before.json"
wait_for_guest_metrics "$GUEST_METRICS_BEFORE"

CONTROL_SET="$QA_ROOT/control-set-target.json"
control_request "{\"command\":\"set_target_mib\",\"target_mib\":$TARGET_MIB}" >"$CONTROL_SET"
jq -e '.ok == true' "$CONTROL_SET" >/dev/null

sleep "$SETTLE_SECONDS"

GUEST_METRICS_AFTER="$QA_ROOT/guest-memory-after.json"
CONTROL_AFTER="$QA_ROOT/control-after.json"
VMMAP_AFTER="$QA_ROOT/vmmap-after.txt"
http_unix_get "$MEMORY_SOCKET" "/conjet-memory-metrics" >"$GUEST_METRICS_AFTER"
control_request '{"command":"metrics"}' >"$CONTROL_AFTER"
vmmap -summary "$VMM_PID" >"$VMMAP_AFTER"

before_footprint="$(jq -r '.host_memory.physical_footprint_bytes // 0' "$CONTROL_BEFORE")"
after_footprint="$(jq -r '.host_memory.physical_footprint_bytes // 0' "$CONTROL_AFTER")"
before_rss="$(jq -r '.host_memory.resident_bytes // 0' "$CONTROL_BEFORE")"
after_rss="$(jq -r '.host_memory.resident_bytes // 0' "$CONTROL_AFTER")"
reported_free_reclaimed="$(jq -r '.balloon.reported_free_reclaimed_bytes // 0' "$CONTROL_AFTER")"
balloon_reclaimed="$(jq -r '.balloon.reclaimed_bytes // 0' "$CONTROL_AFTER")"
target_after="$(jq -r '.target_mib' "$CONTROL_AFTER")"
memory_ledger_ok="$(jq -r '.memory_ledger.ok // false' "$CONTROL_AFTER")"
shared_memory_regions="$(awk '$1 == "shared" && $2 == "memory" { print $NF }' "$VMMAP_AFTER" | tail -1)"
if ! [[ "$shared_memory_regions" =~ ^[0-9]+$ ]]; then
  shared_memory_regions=0
fi

footprint_drop_mib=0
if [ "$before_footprint" -gt "$after_footprint" ]; then
  footprint_drop_mib=$(( (before_footprint - after_footprint) / 1024 / 1024 ))
fi
rss_drop_mib=0
if [ "$before_rss" -gt "$after_rss" ]; then
  rss_drop_mib=$(( (before_rss - after_rss) / 1024 / 1024 ))
fi
footprint_over_target_mib=0
target_bytes=$(( TARGET_MIB * 1024 * 1024 ))
if [ "$after_footprint" -gt "$target_bytes" ]; then
  footprint_over_target_mib=$(( (after_footprint - target_bytes) / 1024 / 1024 ))
fi

jq -n \
  --arg qa_root "$QA_ROOT" \
  --argjson memory_mib "$MEMORY_MIB" \
  --argjson target_mib "$TARGET_MIB" \
  --argjson target_after "$target_after" \
  --argjson before_footprint "$before_footprint" \
  --argjson after_footprint "$after_footprint" \
  --argjson footprint_drop_mib "$footprint_drop_mib" \
  --argjson before_rss "$before_rss" \
  --argjson after_rss "$after_rss" \
  --argjson rss_drop_mib "$rss_drop_mib" \
  --argjson reported_free_reclaimed "$reported_free_reclaimed" \
  --argjson balloon_reclaimed "$balloon_reclaimed" \
  --argjson min_footprint_drop_mib "$MIN_FOOTPRINT_DROP_MIB" \
  --argjson footprint_over_target_mib "$footprint_over_target_mib" \
  --argjson max_footprint_over_target_mib "$MAX_FOOTPRINT_OVER_TARGET_MIB" \
  --argjson shared_memory_regions "$shared_memory_regions" \
  --argjson max_shared_memory_regions "$MAX_SHARED_MEMORY_REGIONS" \
  --argjson memory_ledger_ok "$memory_ledger_ok" \
  --arg vmmap_path "$VMMAP_AFTER" \
  '{
    ok: (
      $target_after == $target_mib and
      $balloon_reclaimed > 0 and
      $memory_ledger_ok and
      ($min_footprint_drop_mib == 0 or $footprint_drop_mib >= $min_footprint_drop_mib) and
      $footprint_over_target_mib <= $max_footprint_over_target_mib and
      $shared_memory_regions > 0 and
      $shared_memory_regions <= $max_shared_memory_regions
    ),
    qa_root: $qa_root,
    configured_mib: $memory_mib,
    requested_target_mib: $target_mib,
    observed_target_mib: $target_after,
    host_memory: {
      before_physical_footprint_bytes: $before_footprint,
      after_physical_footprint_bytes: $after_footprint,
      physical_footprint_drop_mib: $footprint_drop_mib,
      before_resident_bytes: $before_rss,
      after_resident_bytes: $after_rss,
      resident_drop_mib: $rss_drop_mib,
      footprint_over_target_mib: $footprint_over_target_mib,
      max_footprint_over_target_mib: $max_footprint_over_target_mib
    },
    balloon: {
      reclaimed_bytes: $balloon_reclaimed,
      reported_free_reclaimed_bytes: $reported_free_reclaimed
    },
    memory_ledger_ok: $memory_ledger_ok,
    shared_memory_regions: $shared_memory_regions,
    max_shared_memory_regions: $max_shared_memory_regions,
    vmmap_path: $vmmap_path
  }' >"$SUMMARY_JSON"

cat "$SUMMARY_JSON"
jq -e '.ok == true' "$SUMMARY_JSON" >/dev/null

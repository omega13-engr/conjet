#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: run-chum-mem-memory-trace.sh --manifest PATH [options]

Boot an isolated bundled Conjet Core VMM, run a chum-mem import workload through
that VM's Docker socket, and write a JSONL memory trace.

Required:
  --manifest PATH              VM asset manifest for scratch/isolated assets

Options:
  --vmm PATH                   Conjet Core VMM binary (default: bundled dist app)
  --qa-root DIR                Artifact directory (default: mktemp under /Volumes/ExternalSSD/dev_workspace/tmp)
  --chum-mem-dir DIR           chum-mem checkout (default: /Users/sly/Workspace/Org/chum-mem)
  --project-id UUID            chum-mem project id (default: .chum-mem in this repo, then chum-mem dir)
  --import-command COMMAND     Command to run from chum-mem dir during trace
  --import-max-files N         Default importer max files (default: 25)
  --api-host-port N            Local proxy port for guest chum-mem API (default: 63001)
  --sample-interval SECONDS    Trace sample interval (default: 1)
  --pre-import-idle-seconds N  Idle observation before the workload (default: 0)
  --post-import-settle-seconds N
                               Idle observation period after the workload (default: 90)
  --internal-ready-probe       Probe /ready from inside the isolated API container
                               during the live-services settle period
  --internal-ready-probe-interval N
                               Seconds between internal probes (default: 1)
  --internal-ready-probe-timeout N
                               Per-probe timeout in seconds (default: 5)
  --expect-core-idle-target-mib N
                               Require Jetstream to return to this target after idle
  --expect-core-workload-expansions N
                               Require at least this many Core workload expansions
  --expect-core-service-shrinks N
                               Require at least this many live-service target shrinks
  --require-core-capacity-during-import
                               Require Core to retain configured capacity after workload expansion
                               until the import command exits
  --max-core-post-idle-probes N
                               Fail if Jetstream exceeds this probe budget after reaching idle
  --max-final-physical-footprint-mib N
                               Fail if the final Core physical footprint exceeds this limit
  --max-final-core-target-mib N
                               Fail if the final Jetstream target exceeds this limit
  --max-final-half-footprint-slope-mib-per-min N
                               Fail if the absolute final-half footprint slope exceeds this limit
  --min-ready-probe-samples N  Require at least this many internal readiness samples
  --max-ready-probe-p95-ms N   Fail if final-half readiness p95 exceeds this limit
  --max-ready-probe-p99-ms N   Fail if final-half readiness p99 exceeds this limit
  --max-service-pgmajfault-delta N
                               Fail if service major faults grow by more than this during settle
  --max-service-psi-full-total-delta-us N
                               Fail if service full-PSI time grows by more than this during settle
  --require-mglru              Require MGLRU and complete service telemetry during settle
  --memory-mib N               Configured guest memory MiB (default: 8192)
  --cpus N                     vCPU count (default: 4)
  --timeout-seconds N          Readiness timeout (default: 900)
  --skip-compose-up            Do not run docker compose up; trace settle as post-import idle
  --reset-compose-volumes      Remove isolated Compose containers and volumes first
  --stop-compose-after-import  Run docker compose stop after the workload and trace idle return
  --skip-api-forward           Do not proxy localhost API traffic into guest Docker
  --skip-sign                  Do not ad-hoc sign VMM with debug entitlements
  -h, --help                   Show this help

Trace output:
  $qa_root/chum-mem-memory-trace.jsonl
  $qa_root/chum-mem-memory-trace-summary.json
  $qa_root/chum-mem-ready-probe.jsonl (when enabled)

The manifest must point at scratch disks, logs, and sockets. This script does
not stop, restart, or inspect any live Conjet app/daemon/VM.
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
CHUM_MEM_DIR="/Users/sly/Workspace/Org/chum-mem"
PROJECT_ID=""
IMPORT_COMMAND=""
IMPORT_MAX_FILES=25
API_HOST_PORT=63001
SAMPLE_INTERVAL=1
PRE_IMPORT_IDLE_SECONDS=0
POST_IMPORT_SETTLE_SECONDS=90
RUN_INTERNAL_READY_PROBE=0
INTERNAL_READY_PROBE_INTERVAL=1
INTERNAL_READY_PROBE_TIMEOUT=5
EXPECT_CORE_IDLE_TARGET_MIB=""
EXPECT_CORE_WORKLOAD_EXPANSIONS=""
EXPECT_CORE_SERVICE_SHRINKS=""
REQUIRE_CORE_CAPACITY_DURING_IMPORT=0
MAX_CORE_POST_IDLE_PROBES=""
MAX_FINAL_PHYSICAL_FOOTPRINT_MIB=""
MAX_FINAL_CORE_TARGET_MIB=""
MAX_FINAL_HALF_FOOTPRINT_SLOPE_MIB_PER_MIN=""
MIN_READY_PROBE_SAMPLES=""
MAX_READY_PROBE_P95_MS=""
MAX_READY_PROBE_P99_MS=""
MAX_SERVICE_PGMAJFAULT_DELTA=""
MAX_SERVICE_PSI_FULL_TOTAL_DELTA_US=""
REQUIRE_MGLRU=0
MEMORY_MIB=8192
CPUS=4
TIMEOUT_SECONDS=900
RUN_COMPOSE_UP=1
RESET_COMPOSE_VOLUMES=0
STOP_COMPOSE_AFTER_IMPORT=0
RUN_API_FORWARD=1
SIGN_VMM=1
CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES=$((64 * 1024 * 1024))
CONTAINER_ZRAM_SWAP_BUDGET_BYTES=$((8 * 1024 * 1024))
GLOBAL_PSI_SOME_AVG10_LIMIT=5.0
GLOBAL_PSI_FULL_AVG10_LIMIT=0.5
SERVICE_PSI_SOME_AVG10_LIMIT=1.0
SERVICE_PSI_FULL_AVG10_LIMIT=0.05

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
    --chum-mem-dir)
      CHUM_MEM_DIR="${2:?missing value for --chum-mem-dir}"
      shift 2
      ;;
    --project-id)
      PROJECT_ID="${2:?missing value for --project-id}"
      shift 2
      ;;
    --import-command)
      IMPORT_COMMAND="${2:?missing value for --import-command}"
      shift 2
      ;;
    --import-max-files)
      IMPORT_MAX_FILES="${2:?missing value for --import-max-files}"
      shift 2
      ;;
    --api-host-port)
      API_HOST_PORT="${2:?missing value for --api-host-port}"
      shift 2
      ;;
    --sample-interval)
      SAMPLE_INTERVAL="${2:?missing value for --sample-interval}"
      shift 2
      ;;
    --pre-import-idle-seconds)
      PRE_IMPORT_IDLE_SECONDS="${2:?missing value for --pre-import-idle-seconds}"
      shift 2
      ;;
    --post-import-settle-seconds)
      POST_IMPORT_SETTLE_SECONDS="${2:?missing value for --post-import-settle-seconds}"
      shift 2
      ;;
    --internal-ready-probe)
      RUN_INTERNAL_READY_PROBE=1
      shift
      ;;
    --internal-ready-probe-interval)
      INTERNAL_READY_PROBE_INTERVAL="${2:?missing value for --internal-ready-probe-interval}"
      shift 2
      ;;
    --internal-ready-probe-timeout)
      INTERNAL_READY_PROBE_TIMEOUT="${2:?missing value for --internal-ready-probe-timeout}"
      shift 2
      ;;
    --expect-core-idle-target-mib)
      EXPECT_CORE_IDLE_TARGET_MIB="${2:?missing value for --expect-core-idle-target-mib}"
      shift 2
      ;;
    --expect-core-workload-expansions)
      EXPECT_CORE_WORKLOAD_EXPANSIONS="${2:?missing value for --expect-core-workload-expansions}"
      shift 2
      ;;
    --expect-core-service-shrinks)
      EXPECT_CORE_SERVICE_SHRINKS="${2:?missing value for --expect-core-service-shrinks}"
      shift 2
      ;;
    --require-core-capacity-during-import)
      REQUIRE_CORE_CAPACITY_DURING_IMPORT=1
      shift
      ;;
    --max-core-post-idle-probes)
      MAX_CORE_POST_IDLE_PROBES="${2:?missing value for --max-core-post-idle-probes}"
      shift 2
      ;;
    --max-final-physical-footprint-mib)
      MAX_FINAL_PHYSICAL_FOOTPRINT_MIB="${2:?missing value for --max-final-physical-footprint-mib}"
      shift 2
      ;;
    --max-final-core-target-mib)
      MAX_FINAL_CORE_TARGET_MIB="${2:?missing value for --max-final-core-target-mib}"
      shift 2
      ;;
    --max-final-half-footprint-slope-mib-per-min)
      MAX_FINAL_HALF_FOOTPRINT_SLOPE_MIB_PER_MIN="${2:?missing value for --max-final-half-footprint-slope-mib-per-min}"
      shift 2
      ;;
    --min-ready-probe-samples)
      MIN_READY_PROBE_SAMPLES="${2:?missing value for --min-ready-probe-samples}"
      shift 2
      ;;
    --max-ready-probe-p95-ms)
      MAX_READY_PROBE_P95_MS="${2:?missing value for --max-ready-probe-p95-ms}"
      shift 2
      ;;
    --max-ready-probe-p99-ms)
      MAX_READY_PROBE_P99_MS="${2:?missing value for --max-ready-probe-p99-ms}"
      shift 2
      ;;
    --max-service-pgmajfault-delta)
      MAX_SERVICE_PGMAJFAULT_DELTA="${2:?missing value for --max-service-pgmajfault-delta}"
      shift 2
      ;;
    --max-service-psi-full-total-delta-us)
      MAX_SERVICE_PSI_FULL_TOTAL_DELTA_US="${2:?missing value for --max-service-psi-full-total-delta-us}"
      shift 2
      ;;
    --require-mglru)
      REQUIRE_MGLRU=1
      shift
      ;;
    --memory-mib)
      MEMORY_MIB="${2:?missing value for --memory-mib}"
      shift 2
      ;;
    --cpus)
      CPUS="${2:?missing value for --cpus}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:?missing value for --timeout-seconds}"
      shift 2
      ;;
    --skip-compose-up)
      RUN_COMPOSE_UP=0
      shift
      ;;
    --reset-compose-volumes)
      RESET_COMPOSE_VOLUMES=1
      shift
      ;;
    --stop-compose-after-import)
      STOP_COMPOSE_AFTER_IMPORT=1
      shift
      ;;
    --skip-api-forward)
      RUN_API_FORWARD=0
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
if [ ! -d "$CHUM_MEM_DIR" ]; then
  echo "chum-mem dir does not exist: $CHUM_MEM_DIR" >&2
  exit 1
fi
for tool in jq nc docker; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required" >&2
    exit 1
  fi
done

if [ "$RUN_API_FORWARD" -eq 1 ] && ! command -v socat >/dev/null 2>&1; then
  echo "socat is required unless --skip-api-forward is used" >&2
  exit 1
fi

normalize_nonnegative_integer() {
  local option="$1"
  local variable="$2"
  local value="${!variable}"
  case "$value" in
    ""|*[!0-9]*)
      echo "$option must be a non-negative integer" >&2
      exit 2
      ;;
  esac
  printf -v "$variable" '%d' "$((10#$value))"
  if [ "${!variable}" -lt 0 ]; then
    echo "$option is too large" >&2
    exit 2
  fi
}

normalize_positive_integer() {
  local option="$1"
  local variable="$2"
  local value="${!variable}"
  case "$value" in
    ""|*[!0-9]*)
      echo "$option must be a positive integer" >&2
      exit 2
      ;;
  esac
  printf -v "$variable" '%d' "$((10#$value))"
  if [ "${!variable}" -le 0 ]; then
    echo "$option must be a positive integer" >&2
    exit 2
  fi
}

normalize_optional_nonnegative_integer() {
  local option="$1"
  local variable="$2"
  if [ -n "${!variable}" ]; then
    normalize_nonnegative_integer "$option" "$variable"
  fi
}

normalize_optional_positive_integer() {
  local option="$1"
  local variable="$2"
  if [ -n "${!variable}" ]; then
    normalize_positive_integer "$option" "$variable"
  fi
}

normalize_positive_integer --memory-mib MEMORY_MIB
normalize_positive_integer --cpus CPUS
normalize_positive_integer --timeout-seconds TIMEOUT_SECONDS
normalize_positive_integer --import-max-files IMPORT_MAX_FILES
normalize_positive_integer --api-host-port API_HOST_PORT
normalize_positive_integer --sample-interval SAMPLE_INTERVAL
normalize_nonnegative_integer --pre-import-idle-seconds PRE_IMPORT_IDLE_SECONDS
normalize_nonnegative_integer --post-import-settle-seconds POST_IMPORT_SETTLE_SECONDS
normalize_positive_integer --internal-ready-probe-interval INTERNAL_READY_PROBE_INTERVAL
normalize_positive_integer --internal-ready-probe-timeout INTERNAL_READY_PROBE_TIMEOUT
normalize_optional_positive_integer --expect-core-idle-target-mib EXPECT_CORE_IDLE_TARGET_MIB
normalize_optional_nonnegative_integer --expect-core-workload-expansions EXPECT_CORE_WORKLOAD_EXPANSIONS
normalize_optional_nonnegative_integer --expect-core-service-shrinks EXPECT_CORE_SERVICE_SHRINKS
normalize_optional_nonnegative_integer --max-core-post-idle-probes MAX_CORE_POST_IDLE_PROBES
normalize_optional_positive_integer --max-final-physical-footprint-mib MAX_FINAL_PHYSICAL_FOOTPRINT_MIB
normalize_optional_positive_integer --max-final-core-target-mib MAX_FINAL_CORE_TARGET_MIB
normalize_optional_nonnegative_integer --max-final-half-footprint-slope-mib-per-min MAX_FINAL_HALF_FOOTPRINT_SLOPE_MIB_PER_MIN
normalize_optional_nonnegative_integer --min-ready-probe-samples MIN_READY_PROBE_SAMPLES
normalize_optional_nonnegative_integer --max-ready-probe-p95-ms MAX_READY_PROBE_P95_MS
normalize_optional_nonnegative_integer --max-ready-probe-p99-ms MAX_READY_PROBE_P99_MS
normalize_optional_nonnegative_integer --max-service-pgmajfault-delta MAX_SERVICE_PGMAJFAULT_DELTA
normalize_optional_nonnegative_integer --max-service-psi-full-total-delta-us MAX_SERVICE_PSI_FULL_TOTAL_DELTA_US

if [ "$API_HOST_PORT" -gt 65535 ]; then
  echo "--api-host-port must be at most 65535" >&2
  exit 2
fi
if [ "$RUN_INTERNAL_READY_PROBE" -eq 1 ] && [ "$POST_IMPORT_SETTLE_SECONDS" -le 0 ]; then
  echo "--internal-ready-probe requires a non-zero --post-import-settle-seconds" >&2
  exit 2
fi
if [ "$RUN_INTERNAL_READY_PROBE" -eq 1 ] && [ "$STOP_COMPOSE_AFTER_IMPORT" -eq 1 ]; then
  echo "--internal-ready-probe cannot be combined with --stop-compose-after-import" >&2
  exit 2
fi
if [ "$RUN_INTERNAL_READY_PROBE" -eq 0 ] &&
  { [ -n "$MIN_READY_PROBE_SAMPLES" ] ||
    [ -n "$MAX_READY_PROBE_P95_MS" ] ||
    [ -n "$MAX_READY_PROBE_P99_MS" ]; }; then
  echo "ready-probe gates require --internal-ready-probe" >&2
  exit 2
fi

if [ -z "$QA_ROOT" ]; then
  QA_ROOT="$(mktemp -d "$DEFAULT_TMP_PARENT/conjet-chum-mem-trace.XXXXXX")"
else
  mkdir -p "$QA_ROOT"
fi

if [ -z "$VMM" ]; then
  bundled="$ROOT_DIR/dist/Conjet.app/Contents/Resources/ConjetTools/ConjetCoreVMM/Conjet Core"
  if [ -x "$bundled" ]; then
    VMM="$bundled"
  else
    echo "bundled Conjet Core VMM not found; pass --vmm PATH" >&2
    exit 1
  fi
fi
if [ ! -x "$VMM" ]; then
  echo "VMM is not executable: $VMM" >&2
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

project_id_from_file() {
  local file="$1"
  if [ -f "$file" ]; then
    jq -r '.projectId // empty' "$file" 2>/dev/null || true
  fi
}

if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID="$(project_id_from_file "$ROOT_DIR/.chum-mem")"
fi
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID="$(project_id_from_file "$CHUM_MEM_DIR/.chum-mem")"
fi
if [ -z "$PROJECT_ID" ]; then
  echo "project id is required; pass --project-id or provide .chum-mem" >&2
  exit 1
fi

if [ -z "$IMPORT_COMMAND" ]; then
  IMPORT_COMMAND="pnpm sessions:import -- --server-url http://127.0.0.1:$API_HOST_PORT --project-id '$PROJECT_ID' --max-files $IMPORT_MAX_FILES --concurrency 1 --yes"
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
  CONTROL_DIR="/tmp/conjet-chum-mem-trace-$$"
  mkdir -p "$CONTROL_DIR"
  CONTROL_SOCKET="$CONTROL_DIR/rust-memory-control.sock"
fi

STDOUT_LOG="$QA_ROOT/conjet-core.stdout.json"
STDERR_LOG="$QA_ROOT/conjet-core.stderr.log"
PID_FILE="$QA_ROOT/conjet-core.pid"
TRACE_JSONL="$QA_ROOT/chum-mem-memory-trace.jsonl"
SUMMARY_JSON="$QA_ROOT/chum-mem-memory-trace-summary.json"
COMPOSE_LOG="$QA_ROOT/chum-mem-compose.log"
COMPOSE_STOP_LOG="$QA_ROOT/chum-mem-compose-stop.log"
IMPORT_LOG="$QA_ROOT/chum-mem-import.log"
API_FORWARD_LOG="$QA_ROOT/chum-mem-api-forward.log"
VMMAP_FINAL="$QA_ROOT/conjet-core-vmmap-final.txt"
FOOTPRINT_FINAL="$QA_ROOT/conjet-core-footprint-final.txt"
READY_PROBE_JSONL="$QA_ROOT/chum-mem-ready-probe.jsonl"
READY_PROBE_LOG="$QA_ROOT/chum-mem-ready-probe.log"
TRACE_STOP="$QA_ROOT/trace.stop"

mkdir -p "$RUN_DIR" "$(dirname -- "$SERIAL_LOG")"
rm -f "$DOCKER_SOCKET" "$MEMORY_SOCKET" "$CONTROL_SOCKET" "$STDOUT_LOG" "$STDERR_LOG" "$TRACE_JSONL" "$SUMMARY_JSON" "$COMPOSE_STOP_LOG" "$READY_PROBE_LOG" "$TRACE_STOP"
: >"$READY_PROBE_JSONL"

VMM_PID=""
SAMPLER_PID=""
SAMPLER_FAILURES=0
API_FORWARD_PID=""
cleanup() {
  if [ -n "$API_FORWARD_PID" ] && kill -0 "$API_FORWARD_PID" >/dev/null 2>&1; then
    kill "$API_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$API_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$SAMPLER_PID" ] && kill -0 "$SAMPLER_PID" >/dev/null 2>&1; then
    : >"$TRACE_STOP"
    local sampler_deadline=$((SECONDS + 30))
    while kill -0 "$SAMPLER_PID" >/dev/null 2>&1 && [ "$SECONDS" -lt "$sampler_deadline" ]; do
      sleep 0.1
    done
    if kill -0 "$SAMPLER_PID" >/dev/null 2>&1; then
      kill -9 "$SAMPLER_PID" >/dev/null 2>&1 || true
    fi
    wait "$SAMPLER_PID" >/dev/null 2>&1 || true
  fi
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
      echo "Conjet Core exited before $label socket was ready" >&2
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
  printf '%s\n' "$request" | nc -w 5 -U "$CONTROL_SOCKET"
}

http_unix_get() {
  local socket_path="$1"
  local path="$2"
  printf 'GET %s HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n' "$path" \
    | nc -w 5 -U "$socket_path" \
    | awk 'found { print } /^\r?$/ { found=1 }'
}

wait_for_docker_ping() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [ "$SECONDS" -le "$deadline" ]; do
    if [ -S "$DOCKER_SOCKET" ] &&
      printf 'GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n' \
        | nc -w 5 -U "$DOCKER_SOCKET" 2>/dev/null \
        | grep 'OK' >/dev/null; then
      return 0
    fi
    if ! kill -0 "$VMM_PID" >/dev/null 2>&1; then
      echo "Conjet Core exited before Docker API was ready" >&2
      return 1
    fi
    sleep 0.5
  done
  echo "timed out waiting for Docker API readiness: $DOCKER_SOCKET" >&2
  return 1
}

wait_for_guest_metrics() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [ "$SECONDS" -le "$deadline" ]; do
    if [ -S "$MEMORY_SOCKET" ] &&
      http_unix_get "$MEMORY_SOCKET" "/conjet-memory-metrics" \
        | jq -e '(.mem_available // null) != null' >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$VMM_PID" >/dev/null 2>&1; then
      echo "Conjet Core exited before guest memory metrics were ready" >&2
      return 1
    fi
    sleep 0.5
  done
  echo "timed out waiting for guest memory metrics: $MEMORY_SOCKET" >&2
  return 1
}

start_api_forward() {
  if [ "$RUN_API_FORWARD" -ne 1 ]; then
    return 0
  fi
  if lsof -nP -iTCP:"$API_HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "localhost port $API_HOST_PORT is already in use; pass --api-host-port or --skip-api-forward" >&2
    return 1
  fi
  local network="${COMPOSE_PROJECT_NAME}_default"
  local helper="$QA_ROOT/api-forward-command.sh"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'set -eu'
    printf "export DOCKER_HOST='%s'\n" "$DOCKER_HOST"
    printf "exec docker run --rm -i --network '%s' alpine/socat - TCP:api:63001\n" "$network"
  } >"$helper"
  chmod +x "$helper"
  docker pull alpine/socat >"$API_FORWARD_LOG" 2>&1 || {
    echo "failed to pull alpine/socat for API forward; see $API_FORWARD_LOG" >&2
    return 1
  }
  socat \
    "TCP-LISTEN:$API_HOST_PORT,bind=127.0.0.1,fork,reuseaddr" \
    "EXEC:$helper" >>"$API_FORWARD_LOG" 2>&1 &
  API_FORWARD_PID=$!
}

start_internal_ready_probe() {
  local container_trace="/tmp/conjet-ready-probe-${VMM_PID}.jsonl"
  local container_done="${container_trace}.done"
  printf '%s\n' "$container_trace" >"$QA_ROOT/internal-ready-probe-path.txt"
  (
    cd "$CHUM_MEM_DIR"
    docker compose exec -T -d api sh -c '
      output_file="$1"
      done_file="$2"
      interval="$3"
      duration="$4"
      request_timeout="$5"
      finish_probe() {
        : >"$done_file"
      }
      trap finish_probe EXIT HUP INT TERM
      rm -f "$output_file" "$done_file"
      deadline=$(($(date +%s) + duration))
      sequence=0
      while [ "$(date +%s)" -lt "$deadline" ]; do
        timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        result=$(curl -sS -o /dev/null --max-time "$request_timeout" \
          -w "%{http_code} %{time_total}" http://127.0.0.1:63001/ready 2>/dev/null)
        curl_exit_code=$?
        http_status=${result%% *}
        latency_seconds=${result#* }
        case "$http_status" in
          [0-9][0-9][0-9]) ;;
          *) http_status=0 ;;
        esac
        case "$latency_seconds" in
          ""|*[!0-9.]*) latency_seconds=0 ;;
        esac
        ok=false
        case "$http_status" in
          2??)
            if [ "$curl_exit_code" -eq 0 ]; then
              ok=true
            fi
            ;;
        esac
        printf "{\"sequence\":%s,\"timestamp\":\"%s\",\"latency_seconds\":%s,\"http_status\":%s,\"curl_exit_code\":%s,\"ok\":%s}\n" \
          "$sequence" "$timestamp" "$latency_seconds" "$http_status" "$curl_exit_code" "$ok" \
          >>"$output_file"
        sequence=$((sequence + 1))
        sleep "$interval"
      done
    ' conjet-ready-probe \
      "$container_trace" \
      "$container_done" \
      "$INTERNAL_READY_PROBE_INTERVAL" \
      "$POST_IMPORT_SETTLE_SECONDS" \
      "$INTERNAL_READY_PROBE_TIMEOUT"
  ) >"$READY_PROBE_LOG" 2>&1
}

retrieve_internal_ready_probe() {
  local container_trace
  local container_done
  local retrieve_wait_seconds=$((INTERNAL_READY_PROBE_INTERVAL + INTERNAL_READY_PROBE_TIMEOUT + 10))
  container_trace="$(cat "$QA_ROOT/internal-ready-probe-path.txt")"
  container_done="${container_trace}.done"
  (
    cd "$CHUM_MEM_DIR"
    docker compose exec -T api sh -c '
      output_file="$1"
      done_file="$2"
      wait_seconds="$3"
      deadline=$(($(date +%s) + wait_seconds))
      while [ ! -f "$done_file" ] && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 1
      done
      if [ ! -f "$done_file" ] || [ ! -f "$output_file" ]; then
        exit 1
      fi
      cat "$output_file"
    ' conjet-ready-probe-retrieve \
      "$container_trace" \
      "$container_done" \
      "$retrieve_wait_seconds"
  ) >"$READY_PROBE_JSONL" 2>>"$READY_PROBE_LOG"
}

sample_trace() {
  local stage="$1"
  local control_file="$QA_ROOT/control-sample.json"
  local metrics_file="$QA_ROOT/guest-memory-sample.json"
  local slices_file="$QA_ROOT/service-slices-sample.json"
  local reclaim_status_file="$QA_ROOT/guest-reclaim-status-sample.json"
  control_request '{"command":"metrics"}' >"$control_file" 2>/dev/null || return 1
  jq -e '
    .ok == true and
    (.host_memory.physical_footprint_bytes | type == "number") and
    .host_memory.physical_footprint_bytes > 0 and
    (.target_pages | type == "number") and
    (.balloon.actual_pages | type == "number")
  ' "$control_file" >/dev/null 2>&1 || return 1
  http_unix_get "$MEMORY_SOCKET" "/conjet-memory-metrics" >"$metrics_file" 2>/dev/null || return 1
  jq -e '
    type == "object" and
    (.mem_available | type == "number") and
    (.service_cgroup_memory_current | type == "number")
  ' "$metrics_file" >/dev/null 2>&1 || return 1
  if ! http_unix_get "$MEMORY_SOCKET" "/conjet-memory-service-slices" >"$slices_file" 2>/dev/null ||
    ! jq -e 'type == "object" and (.slices | type == "array")' "$slices_file" >/dev/null 2>&1; then
    printf '{"version":1,"slices":[],"source":"unavailable"}\n' >"$slices_file"
  fi
  if ! http_unix_get "$MEMORY_SOCKET" "/conjet-memory-reclaim/status" >"$reclaim_status_file" 2>/dev/null ||
    ! jq -e 'type == "object"' "$reclaim_status_file" >/dev/null 2>&1; then
    printf '{}\n' >"$reclaim_status_file"
  fi
  jq -c -n \
    --arg stage "$stage" \
    --slurpfile control "$control_file" \
    --slurpfile metrics "$metrics_file" \
    --slurpfile slices "$slices_file" \
    --slurpfile reclaim_status "$reclaim_status_file" \
    '($control[0] // {}) as $control |
     ($metrics[0] // {}) as $metrics |
     ($slices[0] // {"slices":[]}) as $slices |
     ($reclaim_status[0] // {}) as $reclaim_status |
     {
       timestamp: (now | todateiso8601),
       stage: $stage,
       per_slice: [
         ($slices.slices // [])[] |
         . + {
           memory_current: (.memory_current // 0),
           inactive_file: (.inactive_file // 0),
           slab_reclaimable: (.slab_reclaimable // 0),
           working_set: (.working_set // 0),
           reclaimable: (.reclaimable // 0),
           populated: (.populated // false)
         }
       ],
       psi: {
         some_avg10: ($metrics.psi_some_avg10 // 0),
         full_avg10: ($metrics.psi_full_avg10 // 0)
       },
       guest: ($metrics + {
         container_memory_current: ($metrics.container_memory_current // 0),
         daemon_cgroup_memory_current: ($metrics.daemon_cgroup_memory_current // 0),
         daemon_cgroup_working_set: ($metrics.daemon_cgroup_working_set // 0),
         daemon_cgroup_inactive_file: ($metrics.daemon_cgroup_inactive_file // 0),
         daemon_cgroup_populated: ($metrics.daemon_cgroup_populated // false),
         daemon_cgroup_population_known: ($metrics.daemon_cgroup_population_known // false),
         service_cgroup_memory_current: ($metrics.service_cgroup_memory_current // 0),
         service_cgroup_working_set: ($metrics.service_cgroup_working_set // 0),
         service_cgroup_populated: ($metrics.service_cgroup_populated // false),
         service_cgroup_population_known: ($metrics.service_cgroup_population_known // false)
       }),
       balloon: (($control.balloon // {}) + {
         actual_pages: ($control.balloon.actual_pages // 0),
         inflate_pages: ($control.balloon.inflate_pages // 0),
         deflate_pages: ($control.balloon.deflate_pages // 0),
         reported_free_pages: ($control.balloon.reported_free_pages // 0),
         reclaimed_bytes: ($control.balloon.reclaimed_bytes // 0),
         reported_free_reclaimed_bytes: ($control.balloon.reported_free_reclaimed_bytes // 0),
         reusable_reclaimed_bytes: ($control.balloon.reusable_reclaimed_bytes // 0),
         reusable_restored_bytes: ($control.balloon.reusable_restored_bytes // 0),
         current_balloon_reusable_bytes: ($control.balloon.current_balloon_reusable_bytes // 0),
         host_granule_eligible_bytes: ($control.balloon.host_granule_eligible_bytes // 0),
         partial_host_granule_bytes: ($control.balloon.partial_host_granule_bytes // 0),
         current_fully_owned_host_granules: ($control.balloon.current_fully_owned_host_granules // 0),
         current_partially_owned_host_granules: ($control.balloon.current_partially_owned_host_granules // 0),
         zero_swept_bytes: ($control.balloon.zero_swept_bytes // 0),
         zero_sweep_failed_bytes: ($control.balloon.zero_sweep_failed_bytes // 0),
         reuse_failures: ($control.balloon.reuse_failures // 0),
         reclaim_failures: ($control.balloon.reclaim_failures // 0)
       }),
       vmm: {
         target_mib: ($control.target_mib // 0),
         target_pages: ($control.target_pages // 0)
       },
       core_memory: (($control.core_memory // {}) + {
         enabled: ($control.core_memory.enabled // false),
         idle_target_mib: ($control.core_memory.idle_target_mib // 0),
         current_target_mib: ($control.core_memory.current_target_mib // 0),
         pending_idle_probe: ($control.core_memory.pending_idle_probe // false),
         idle_probe_inflight: ($control.core_memory.idle_probe_inflight // false),
         workload_expansions: ($control.core_memory.workload_expansions // 0),
         idle_shrinks: ($control.core_memory.idle_shrinks // 0),
         idle_deferrals: ($control.core_memory.idle_deferrals // 0),
         idle_probes: ($control.core_memory.idle_probes // 0),
         transport_activity_events: ($control.core_memory.transport_activity_events // 0),
         transport_quiet_transitions: ($control.core_memory.transport_quiet_transitions // 0),
         transport_quiet_reclaims: ($control.core_memory.transport_quiet_reclaims // 0),
         idle_backing_compactions: ($control.core_memory.idle_backing_compactions // 0),
         idle_backing_hard_decommitted_bytes: ($control.core_memory.idle_backing_hard_decommitted_bytes // 0),
         idle_backing_compaction_failures: ($control.core_memory.idle_backing_compaction_failures // 0),
         last_reason: ($control.core_memory.last_reason // null),
         last_error: ($control.core_memory.last_error // null)
       }),
       event_reclaim: {
         requests: ($control.event_reclaim.requests // 0),
         successes: ($control.event_reclaim.successes // 0),
         errors: ($control.event_reclaim.errors // 0),
         last_reason: ($control.event_reclaim.last_reason // null),
         last_error: ($control.event_reclaim.last_error // null),
         guest_status: $reclaim_status
       },
       host: {
         resident_bytes: ($control.host_memory.resident_bytes // 0),
         physical_footprint_bytes: ($control.host_memory.physical_footprint_bytes // 0)
       }
     }' >>"$TRACE_JSONL"
}

sample_loop() {
  local stage="$1"
  while [ ! -f "$TRACE_STOP" ]; do
    sample_trace "$stage"
    sleep "$SAMPLE_INTERVAL"
  done
}

finish_sampler() {
  local pid="$SAMPLER_PID"
  local deadline=$((SECONDS + 30))
  local failed=0
  while kill -0 "$pid" >/dev/null 2>&1 && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.1
  done
  if kill -0 "$pid" >/dev/null 2>&1; then
    failed=1
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
  fi
  if ! wait "$pid" >/dev/null 2>&1; then
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    SAMPLER_FAILURES=$((SAMPLER_FAILURES + 1))
  fi
  SAMPLER_PID=""
}

wait_for_socket "memory-control" "$CONTROL_SOCKET"
wait_for_docker_ping
wait_for_guest_metrics
sample_trace "boot-ready"

if [ "$PRE_IMPORT_IDLE_SECONDS" -gt 0 ]; then
  rm -f "$TRACE_STOP"
  sample_loop "pre-import-idle" &
  SAMPLER_PID=$!
  sleep "$PRE_IMPORT_IDLE_SECONDS"
  : >"$TRACE_STOP"
  finish_sampler
  sample_trace "pre-import-idle"
fi

export DOCKER_HOST="unix://$DOCKER_SOCKET"
export COMPOSE_PROJECT_NAME="chum-mem"

if [ "$RUN_COMPOSE_UP" -eq 1 ]; then
  (
    cd "$CHUM_MEM_DIR"
    if [ "$RESET_COMPOSE_VOLUMES" -eq 1 ]; then
      docker compose down --volumes --remove-orphans
    fi
    docker compose up -d --build postgres api worker
  ) >"$COMPOSE_LOG" 2>&1
  sample_trace "compose-ready"
fi

start_api_forward
rm -f "$TRACE_STOP"
sample_loop "chum-mem-import" &
SAMPLER_PID=$!
import_rc=0
(
  cd "$CHUM_MEM_DIR"
  bash -lc "$IMPORT_COMMAND"
) >"$IMPORT_LOG" 2>&1 || import_rc=$?
: >"$TRACE_STOP"
finish_sampler
sample_trace "import-finished"
compose_stop_rc=0
if [ "$STOP_COMPOSE_AFTER_IMPORT" -eq 1 ]; then
  rm -f "$TRACE_STOP"
  sample_loop "compose-stop" &
  SAMPLER_PID=$!
  (
    cd "$CHUM_MEM_DIR"
    docker compose stop
  ) >"$COMPOSE_STOP_LOG" 2>&1 || compose_stop_rc=$?
  : >"$TRACE_STOP"
  finish_sampler
  sample_trace "compose-stopped"
fi
SETTLE_STAGE="live-services"
if [ "$STOP_COMPOSE_AFTER_IMPORT" -eq 1 ] || [ "$RUN_COMPOSE_UP" -eq 0 ]; then
  SETTLE_STAGE="post-import-idle"
fi
ready_probe_start_rc=0
ready_probe_retrieve_rc=0
if [ "$RUN_INTERNAL_READY_PROBE" -eq 1 ]; then
  start_internal_ready_probe || ready_probe_start_rc=$?
fi
if [ "$POST_IMPORT_SETTLE_SECONDS" -gt 0 ]; then
  rm -f "$TRACE_STOP"
  sample_loop "$SETTLE_STAGE" &
  SAMPLER_PID=$!
  sleep "$POST_IMPORT_SETTLE_SECONDS"
  : >"$TRACE_STOP"
  finish_sampler
fi
sample_trace "$SETTLE_STAGE"
vmmap -summary "$VMM_PID" >"$VMMAP_FINAL" 2>&1 || true
footprint "$VMM_PID" >"$FOOTPRINT_FINAL" 2>&1 || true
if [ "$RUN_INTERNAL_READY_PROBE" -eq 1 ] && [ "$ready_probe_start_rc" -eq 0 ]; then
  retrieve_internal_ready_probe || ready_probe_retrieve_rc=$?
fi

EXPECTED_CORE_IDLE_TARGET_JSON="null"
if [ -n "$EXPECT_CORE_IDLE_TARGET_MIB" ]; then
  EXPECTED_CORE_IDLE_TARGET_JSON="$EXPECT_CORE_IDLE_TARGET_MIB"
fi
MAX_CORE_POST_IDLE_PROBES_JSON="null"
if [ -n "$MAX_CORE_POST_IDLE_PROBES" ]; then
  MAX_CORE_POST_IDLE_PROBES_JSON="$MAX_CORE_POST_IDLE_PROBES"
fi
EXPECTED_CORE_WORKLOAD_EXPANSIONS_JSON="null"
if [ -n "$EXPECT_CORE_WORKLOAD_EXPANSIONS" ]; then
  EXPECTED_CORE_WORKLOAD_EXPANSIONS_JSON="$EXPECT_CORE_WORKLOAD_EXPANSIONS"
fi
EXPECTED_CORE_SERVICE_SHRINKS_JSON="null"
if [ -n "$EXPECT_CORE_SERVICE_SHRINKS" ]; then
  EXPECTED_CORE_SERVICE_SHRINKS_JSON="$EXPECT_CORE_SERVICE_SHRINKS"
fi
REQUIRE_CORE_CAPACITY_DURING_IMPORT_JSON=false
if [ "$REQUIRE_CORE_CAPACITY_DURING_IMPORT" -eq 1 ]; then
  REQUIRE_CORE_CAPACITY_DURING_IMPORT_JSON=true
fi
STOP_COMPOSE_AFTER_IMPORT_JSON=false
if [ "$STOP_COMPOSE_AFTER_IMPORT" -eq 1 ]; then
  STOP_COMPOSE_AFTER_IMPORT_JSON=true
fi
MAX_FINAL_PHYSICAL_FOOTPRINT_MIB_JSON="null"
if [ -n "$MAX_FINAL_PHYSICAL_FOOTPRINT_MIB" ]; then
  MAX_FINAL_PHYSICAL_FOOTPRINT_MIB_JSON="$MAX_FINAL_PHYSICAL_FOOTPRINT_MIB"
fi
MAX_FINAL_CORE_TARGET_MIB_JSON="null"
if [ -n "$MAX_FINAL_CORE_TARGET_MIB" ]; then
  MAX_FINAL_CORE_TARGET_MIB_JSON="$MAX_FINAL_CORE_TARGET_MIB"
fi
RUN_INTERNAL_READY_PROBE_JSON=false
if [ "$RUN_INTERNAL_READY_PROBE" -eq 1 ]; then
  RUN_INTERNAL_READY_PROBE_JSON=true
fi
REQUIRE_MGLRU_JSON=false
if [ "$REQUIRE_MGLRU" -eq 1 ]; then
  REQUIRE_MGLRU_JSON=true
fi
EXPECTED_SETTLE_SAMPLES=0
MIN_SETTLE_SAMPLES=0
if [ "$POST_IMPORT_SETTLE_SECONDS" -gt 0 ]; then
  EXPECTED_SETTLE_SAMPLES=$(((POST_IMPORT_SETTLE_SECONDS + SAMPLE_INTERVAL - 1) / SAMPLE_INTERVAL))
  MIN_SETTLE_SAMPLES=$(((EXPECTED_SETTLE_SAMPLES * 80 + 99) / 100))
fi
MIN_READY_PROBE_SAMPLES_JSON="null"
if [ -n "$MIN_READY_PROBE_SAMPLES" ]; then
  MIN_READY_PROBE_SAMPLES_JSON="$MIN_READY_PROBE_SAMPLES"
elif [ "$RUN_INTERNAL_READY_PROBE" -eq 1 ]; then
  expected_ready_samples=$(((POST_IMPORT_SETTLE_SECONDS + INTERNAL_READY_PROBE_INTERVAL - 1) / INTERNAL_READY_PROBE_INTERVAL))
  MIN_READY_PROBE_SAMPLES_JSON=$(((expected_ready_samples * 80 + 99) / 100))
fi
MAX_READY_PROBE_P95_MS_JSON="null"
if [ -n "$MAX_READY_PROBE_P95_MS" ]; then
  MAX_READY_PROBE_P95_MS_JSON="$MAX_READY_PROBE_P95_MS"
fi
MAX_READY_PROBE_P99_MS_JSON="null"
if [ -n "$MAX_READY_PROBE_P99_MS" ]; then
  MAX_READY_PROBE_P99_MS_JSON="$MAX_READY_PROBE_P99_MS"
fi
MAX_FINAL_HALF_FOOTPRINT_SLOPE_JSON="null"
if [ -n "$MAX_FINAL_HALF_FOOTPRINT_SLOPE_MIB_PER_MIN" ]; then
  MAX_FINAL_HALF_FOOTPRINT_SLOPE_JSON="$MAX_FINAL_HALF_FOOTPRINT_SLOPE_MIB_PER_MIN"
fi
MAX_SERVICE_PGMAJFAULT_DELTA_JSON="null"
if [ -n "$MAX_SERVICE_PGMAJFAULT_DELTA" ]; then
  MAX_SERVICE_PGMAJFAULT_DELTA_JSON="$MAX_SERVICE_PGMAJFAULT_DELTA"
fi
MAX_SERVICE_PSI_FULL_TOTAL_DELTA_US_JSON="null"
if [ -n "$MAX_SERVICE_PSI_FULL_TOTAL_DELTA_US" ]; then
  MAX_SERVICE_PSI_FULL_TOTAL_DELTA_US_JSON="$MAX_SERVICE_PSI_FULL_TOTAL_DELTA_US"
fi

jq -s \
  --arg qa_root "$QA_ROOT" \
  --arg trace_jsonl "$TRACE_JSONL" \
  --arg import_log "$IMPORT_LOG" \
  --arg compose_log "$COMPOSE_LOG" \
  --arg compose_stop_log "$COMPOSE_STOP_LOG" \
  --arg api_forward_log "$API_FORWARD_LOG" \
  --arg vmmap_final "$VMMAP_FINAL" \
  --arg footprint_final "$FOOTPRINT_FINAL" \
  --arg ready_probe_jsonl "$READY_PROBE_JSONL" \
  --arg ready_probe_log "$READY_PROBE_LOG" \
  --arg settle_stage "$SETTLE_STAGE" \
  --argjson import_exit_code "$import_rc" \
  --argjson expected_core_idle_target_mib "$EXPECTED_CORE_IDLE_TARGET_JSON" \
  --argjson max_core_post_idle_probes "$MAX_CORE_POST_IDLE_PROBES_JSON" \
  --argjson expected_core_workload_expansions "$EXPECTED_CORE_WORKLOAD_EXPANSIONS_JSON" \
  --argjson expected_core_service_shrinks "$EXPECTED_CORE_SERVICE_SHRINKS_JSON" \
  --argjson require_core_capacity_during_import "$REQUIRE_CORE_CAPACITY_DURING_IMPORT_JSON" \
  --argjson stop_compose_after_import "$STOP_COMPOSE_AFTER_IMPORT_JSON" \
  --argjson compose_stop_exit_code "$compose_stop_rc" \
  --argjson configured_memory_mib "$MEMORY_MIB" \
  --argjson max_final_physical_footprint_mib "$MAX_FINAL_PHYSICAL_FOOTPRINT_MIB_JSON" \
  --argjson max_final_core_target_mib "$MAX_FINAL_CORE_TARGET_MIB_JSON" \
  --argjson internal_ready_probe_enabled "$RUN_INTERNAL_READY_PROBE_JSON" \
  --argjson ready_probe_start_exit_code "$ready_probe_start_rc" \
  --argjson ready_probe_retrieve_exit_code "$ready_probe_retrieve_rc" \
  --argjson sampler_failures "$SAMPLER_FAILURES" \
  --argjson expected_settle_samples "$EXPECTED_SETTLE_SAMPLES" \
  --argjson min_settle_samples "$MIN_SETTLE_SAMPLES" \
  --argjson require_mglru "$REQUIRE_MGLRU_JSON" \
  --argjson min_ready_probe_samples "$MIN_READY_PROBE_SAMPLES_JSON" \
  --argjson max_ready_probe_p95_ms "$MAX_READY_PROBE_P95_MS_JSON" \
  --argjson max_ready_probe_p99_ms "$MAX_READY_PROBE_P99_MS_JSON" \
  --argjson max_final_half_footprint_slope_mib_per_min "$MAX_FINAL_HALF_FOOTPRINT_SLOPE_JSON" \
  --argjson max_service_pgmajfault_delta "$MAX_SERVICE_PGMAJFAULT_DELTA_JSON" \
  --argjson max_service_psi_full_total_delta_us "$MAX_SERVICE_PSI_FULL_TOTAL_DELTA_US_JSON" \
  --argjson control_plane_zram_swap_budget_bytes "$CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES" \
  --argjson container_zram_swap_budget_bytes "$CONTAINER_ZRAM_SWAP_BUDGET_BYTES" \
  --argjson global_psi_some_avg10_limit "$GLOBAL_PSI_SOME_AVG10_LIMIT" \
  --argjson global_psi_full_avg10_limit "$GLOBAL_PSI_FULL_AVG10_LIMIT" \
  --argjson service_psi_some_avg10_limit "$SERVICE_PSI_SOME_AVG10_LIMIT" \
  --argjson service_psi_full_avg10_limit "$SERVICE_PSI_FULL_AVG10_LIMIT" \
  --slurpfile ready_probe "$READY_PROBE_JSONL" \
  'def percentile($values; $quantile):
     ($values | length) as $count |
     if $count == 0 then null
     else $values[((($count * $quantile) | ceil) - 1) | if . < 0 then 0 else . end]
     end;
   def linear_slope:
     length as $count |
     if $count < 2 then null
     else
       (map(.x) | add / $count) as $mean_x |
       (map(.y) | add / $count) as $mean_y |
       (map((.x - $mean_x) * (.y - $mean_y)) | add) as $numerator |
       (map((.x - $mean_x) * (.x - $mean_x)) | add) as $denominator |
       if $denominator == 0 then null else $numerator / $denominator end
     end;
   def absolute: if . < 0 then -. else . end;
   def disk_swap_used:
     [(.guest.disk_swap_used // 0),
      ((.guest.disk_swap_total // 0) - (.guest.disk_swap_free // 0) | if . < 0 then 0 else . end)]
     | max;
   def total_swap_used:
     ((.guest.swap_total // 0) - (.guest.swap_free // 0)) |
     if . < 0 then 0 else . end;
   def counters_non_decreasing($samples; $fields):
     if ($samples | length) < 2 then true
     else
       ([range(1; ($samples | length)) as $index |
         $fields[] as $field |
         (($samples[$index].guest[$field] // 0) >=
          ($samples[$index - 1].guest[$field] // 0))] | all)
     end;
   ($expected_core_idle_target_mib == null or
      ((.[-1].vmm.target_mib // -1) == $expected_core_idle_target_mib and
       (.[-1].core_memory.enabled // false) and
       (.[-1].core_memory.idle_shrinks // 0) > 0)) as $core_idle_target_ok |
   ([.[].core_memory.idle_shrinks] | max // 0) as $final_idle_shrink_count |
   ([.[] | select(
      $final_idle_shrink_count > 0 and
      (.core_memory.idle_shrinks // 0) == $final_idle_shrink_count
    )] | first) as $first_final_idle_sample |
   (if $first_final_idle_sample == null then null
    else ((.[-1].core_memory.idle_probes // 0) - ($first_final_idle_sample.core_memory.idle_probes // 0))
    end) as $post_idle_probe_count |
   ($max_core_post_idle_probes == null or
      ($post_idle_probe_count != null and $post_idle_probe_count <= $max_core_post_idle_probes))
      as $core_post_idle_probe_budget_ok |
   ($expected_core_workload_expansions == null or
      (([.[].core_memory.workload_expansions] | max // 0) >= $expected_core_workload_expansions))
      as $core_workload_expansion_ok |
   ([.[].core_memory.service_shrinks] | max // 0) as $max_core_service_shrinks |
   ($expected_core_service_shrinks == null or
      $max_core_service_shrinks >= $expected_core_service_shrinks)
      as $core_service_shrink_ok |
   ([.[] | select(
      .stage == "chum-mem-import" and
      (.core_memory.workload_expansions // 0) > 0
    )]) as $import_workload_samples |
   ($require_core_capacity_during_import | not or
      (($import_workload_samples | length) > 0 and
       ($import_workload_samples |
        all(.[]; (.vmm.target_mib // 0) == $configured_memory_mib))))
      as $core_capacity_during_import_ok |
   (.[-1].host.physical_footprint_bytes // 0) as $final_physical_footprint_bytes |
   ($final_physical_footprint_bytes > 0 and
      ($max_final_physical_footprint_mib == null or
       $final_physical_footprint_bytes <= ($max_final_physical_footprint_mib * 1024 * 1024)))
      as $final_physical_footprint_ok |
   (.[-1].vmm.target_mib // 0) as $final_core_target_mib |
   ($final_core_target_mib > 0 and
      ($max_final_core_target_mib == null or
       $final_core_target_mib <= $max_final_core_target_mib))
      as $final_core_target_ok |
   ($ready_probe | map(select(.ok == true) | (.latency_seconds // 0) * 1000) | sort)
      as $successful_ready_probe_latency_ms |
   ($ready_probe | map(select(.ok != true)) | length) as $ready_probe_failures |
   ($ready_probe[(($ready_probe | length) / 2 | floor):] |
      map(select(.ok == true) | (.latency_seconds // 0) * 1000) | sort)
      as $final_half_ready_probe_latency_ms |
   (percentile($final_half_ready_probe_latency_ms; 0.95)) as $final_half_ready_probe_p95_ms |
   (percentile($final_half_ready_probe_latency_ms; 0.99)) as $final_half_ready_probe_p99_ms |
   ($internal_ready_probe_enabled | not or
      ($ready_probe_start_exit_code == 0 and
       $ready_probe_retrieve_exit_code == 0 and
       ($successful_ready_probe_latency_ms | length) >= ($min_ready_probe_samples // 1) and
       $ready_probe_failures == 0 and
       ($max_ready_probe_p95_ms == null or
        ($final_half_ready_probe_p95_ms != null and
         $final_half_ready_probe_p95_ms <= $max_ready_probe_p95_ms)) and
       ($max_ready_probe_p99_ms == null or
        ($final_half_ready_probe_p99_ms != null and
         $final_half_ready_probe_p99_ms <= $max_ready_probe_p99_ms))))
      as $internal_ready_probe_ok |
   ([.[] | select(.stage == $settle_stage)]) as $settle_trace_samples |
   ($settle_trace_samples | map(
      {
        x: (.timestamp | fromdateiso8601),
        y: ((.host.physical_footprint_bytes // 0) / 1048576)
      })) as $settle_samples |
   ($settle_samples | length) as $settle_sample_count |
   ($settle_samples[($settle_sample_count / 2 | floor):]) as $final_half_settle_samples |
   ($settle_trace_samples[($settle_sample_count / 2 | floor):]) as $final_half_settle_trace_samples |
   ($final_half_settle_samples | linear_slope |
      if . == null then null else . * 60 end) as $final_half_physical_footprint_slope_mib_per_min |
   ($settle_sample_count >= $min_settle_samples and $sampler_failures == 0)
      as $settle_sample_coverage_ok |
   ($max_final_half_footprint_slope_mib_per_min == null or
      ($final_half_physical_footprint_slope_mib_per_min != null and
       ($final_half_physical_footprint_slope_mib_per_min | absolute) <=
         $max_final_half_footprint_slope_mib_per_min)) as $footprint_slope_ok |
   ((.[-1].balloon.actual_pages // -1) == (.[-1].vmm.target_pages // -2))
      as $balloon_converged_ok |
   ($require_mglru | not or
      (($final_half_settle_trace_samples | length) > 0 and
       ($final_half_settle_trace_samples |
        all(.[];
          (.guest.service_cgroup_telemetry_complete // false) and
          (.guest.mem_available_known // false) and
          (.guest.swap_telemetry_complete // false) and
          (.guest.disk_swap_telemetry_complete // false) and
          (.guest.global_psi_telemetry_complete // false) and
          ((.psi.some_avg10 // 100) <= $global_psi_some_avg10_limit) and
          ((.psi.full_avg10 // 100) <= $global_psi_full_avg10_limit) and
          ((.guest.service_cgroup_psi_some_avg10 // 100) <= $service_psi_some_avg10_limit) and
          ((.guest.service_cgroup_psi_full_avg10 // 100) <= $service_psi_full_avg10_limit) and
          (disk_swap_used == 0) and
          (.guest.mglru_enabled // false)))))
      as $settle_telemetry_pressure_ok |
   ($settle_trace_samples[0] // null) as $first_settle_sample |
   ($settle_trace_samples[-1] // null) as $last_settle_sample |
   ([$settle_trace_samples[] | total_swap_used] | max // 0)
      as $max_settle_total_swap_used_bytes |
   ([$settle_trace_samples[] | (.guest.container_swap_current // 0)] | max // 0)
      as $max_settle_container_swap_current_bytes |
   (["service_cgroup_memory_events_high",
     "service_cgroup_memory_events_max",
     "service_cgroup_memory_events_oom",
     "service_cgroup_memory_events_oom_kill",
     "service_cgroup_memory_events_oom_group_kill",
     "service_cgroup_memory_events_local_high",
     "service_cgroup_memory_events_local_max",
     "service_cgroup_memory_events_local_oom",
     "service_cgroup_memory_events_local_oom_kill",
     "service_cgroup_memory_events_local_oom_group_kill"]) as $service_event_fields |
   ($service_event_fields + [
      "service_cgroup_pgmajfault",
      "service_cgroup_psi_full_total_us"
    ]) as $service_monotonic_counter_fields |
   ($first_settle_sample != null and
      $last_settle_sample != null and
      (($first_settle_sample.guest.service_cgroup_cgroup_id // 0) != 0) and
      ($settle_trace_samples |
       all(.[];
         (.guest.service_cgroup_telemetry_complete // false) and
         (.guest.service_cgroup_population_known // false) and
         (.guest.service_cgroup_populated // false) and
         ((.guest.service_cgroup_cgroup_id // 0) ==
          ($first_settle_sample.guest.service_cgroup_cgroup_id // -1)))))
      as $service_cgroup_identity_stable |
   (counters_non_decreasing($settle_trace_samples; $service_monotonic_counter_fields))
      as $service_counter_reset_free |
   (if $first_settle_sample == null or $last_settle_sample == null then {}
    else
      reduce $service_event_fields[] as $field ({};
        .[$field] = (($last_settle_sample.guest[$field] // 0) -
                     ($first_settle_sample.guest[$field] // 0)))
    end) as $service_memory_event_deltas |
   (if $service_cgroup_identity_stable and $service_counter_reset_free then
      (($last_settle_sample.guest.service_cgroup_pgmajfault // 0) -
       ($first_settle_sample.guest.service_cgroup_pgmajfault // 0))
    else null end) as $service_pgmajfault_delta |
   (if $service_cgroup_identity_stable and $service_counter_reset_free then
      (($last_settle_sample.guest.service_cgroup_psi_full_total_us // 0) -
       ($first_settle_sample.guest.service_cgroup_psi_full_total_us // 0))
    else null end) as $service_psi_full_total_delta_us |
   ($settle_stage != "live-services" or
      ($service_cgroup_identity_stable and
       $service_counter_reset_free and
       ([$service_event_fields[] as $field |
          (($last_settle_sample.guest[$field] // 0) <=
           ($first_settle_sample.guest[$field] // 0))] | all) and
       $max_settle_total_swap_used_bytes <= $control_plane_zram_swap_budget_bytes and
       ($last_settle_sample | disk_swap_used) <= ($first_settle_sample | disk_swap_used) and
       $max_settle_container_swap_current_bytes <= $container_zram_swap_budget_bytes))
      as $service_memory_events_ok |
   ($max_service_pgmajfault_delta == null or
      ($settle_stage == "live-services" and
       $settle_sample_count >= 2 and
       $service_pgmajfault_delta != null and
       $service_pgmajfault_delta <= $max_service_pgmajfault_delta))
      as $service_pgmajfault_ok |
   ($max_service_psi_full_total_delta_us == null or
      ($settle_stage == "live-services" and
       $settle_sample_count >= 2 and
       $service_psi_full_total_delta_us != null and
       $service_psi_full_total_delta_us <= $max_service_psi_full_total_delta_us))
      as $service_psi_full_total_ok |
   ($settle_stage != "live-services" or
      ($first_settle_sample != null and
       $last_settle_sample != null and
       (($last_settle_sample.balloon.hard_decommitted_bytes // 0) ==
        ($first_settle_sample.balloon.hard_decommitted_bytes // 0)) and
       (($last_settle_sample.balloon.idle_hard_decommitted_bytes // 0) ==
        ($first_settle_sample.balloon.idle_hard_decommitted_bytes // 0)) and
       (($last_settle_sample.core_memory.idle_backing_hard_decommitted_bytes // 0) ==
        ($first_settle_sample.core_memory.idle_backing_hard_decommitted_bytes // 0))))
      as $active_service_hard_decommit_ok |
   {
    ok: ($import_exit_code == 0 and $compose_stop_exit_code == 0 and length > 0 and
      $core_idle_target_ok and $core_post_idle_probe_budget_ok and
      $core_workload_expansion_ok and $core_service_shrink_ok and
      $core_capacity_during_import_ok and $final_physical_footprint_ok and
      $final_core_target_ok and $internal_ready_probe_ok and
      $settle_sample_coverage_ok and $footprint_slope_ok and
      $balloon_converged_ok and $settle_telemetry_pressure_ok and
      $service_memory_events_ok and $service_pgmajfault_ok and
      $service_psi_full_total_ok and $active_service_hard_decommit_ok),
    qa_root: $qa_root,
    trace_jsonl: $trace_jsonl,
    import_log: $import_log,
    compose_log: $compose_log,
    compose_stop_log: $compose_stop_log,
    api_forward_log: $api_forward_log,
    vmmap_final: $vmmap_final,
    footprint_final: $footprint_final,
    settle_stage: $settle_stage,
    sampler_failures: $sampler_failures,
    expected_settle_samples: $expected_settle_samples,
    min_settle_samples: $min_settle_samples,
    settle_sample_count: $settle_sample_count,
    settle_sample_coverage_ok: $settle_sample_coverage_ok,
    final_half_physical_footprint_slope_mib_per_min: $final_half_physical_footprint_slope_mib_per_min,
    final_half_physical_footprint_slope_samples: ($final_half_settle_samples | length),
    max_final_half_footprint_slope_mib_per_min: $max_final_half_footprint_slope_mib_per_min,
    footprint_slope_ok: $footprint_slope_ok,
    balloon_converged_ok: $balloon_converged_ok,
    require_mglru: $require_mglru,
    psi_avg10_limits: {
      global_some: $global_psi_some_avg10_limit,
      global_full: $global_psi_full_avg10_limit,
      service_some: $service_psi_some_avg10_limit,
      service_full: $service_psi_full_avg10_limit
    },
    settle_telemetry_pressure_ok: $settle_telemetry_pressure_ok,
    service_cgroup_identity_stable: $service_cgroup_identity_stable,
    service_counter_reset_free: $service_counter_reset_free,
    service_memory_event_deltas: $service_memory_event_deltas,
    control_plane_zram_swap_budget_bytes: $control_plane_zram_swap_budget_bytes,
    max_settle_total_swap_used_bytes: $max_settle_total_swap_used_bytes,
    container_zram_swap_budget_bytes: $container_zram_swap_budget_bytes,
    max_settle_container_swap_current_bytes: $max_settle_container_swap_current_bytes,
    service_memory_events_ok: $service_memory_events_ok,
    max_service_pgmajfault_delta: $max_service_pgmajfault_delta,
    service_pgmajfault_delta: $service_pgmajfault_delta,
    service_pgmajfault_ok: $service_pgmajfault_ok,
    max_service_psi_full_total_delta_us: $max_service_psi_full_total_delta_us,
    service_psi_full_total_delta_us: $service_psi_full_total_delta_us,
    service_psi_full_total_ok: $service_psi_full_total_ok,
    active_service_hard_decommit_ok: $active_service_hard_decommit_ok,
    internal_ready_probe: {
      enabled: $internal_ready_probe_enabled,
      ok: $internal_ready_probe_ok,
      trace_jsonl: $ready_probe_jsonl,
      log: $ready_probe_log,
      start_exit_code: $ready_probe_start_exit_code,
      retrieve_exit_code: $ready_probe_retrieve_exit_code,
      samples: ($ready_probe | length),
      min_samples: $min_ready_probe_samples,
      successes: ($successful_ready_probe_latency_ms | length),
      failures: $ready_probe_failures,
      latency_ms: {
        p50: percentile($successful_ready_probe_latency_ms; 0.50),
        p95: percentile($successful_ready_probe_latency_ms; 0.95),
        p99: percentile($successful_ready_probe_latency_ms; 0.99),
        final_half_p95: $final_half_ready_probe_p95_ms,
        final_half_p99: $final_half_ready_probe_p99_ms,
        max_final_half_p95: $max_ready_probe_p95_ms,
        max_final_half_p99: $max_ready_probe_p99_ms
      }
    },
    import_exit_code: $import_exit_code,
    stop_compose_after_import: $stop_compose_after_import,
    compose_stop_exit_code: $compose_stop_exit_code,
    expected_core_idle_target_mib: $expected_core_idle_target_mib,
    core_idle_target_ok: $core_idle_target_ok,
    max_core_post_idle_probes: $max_core_post_idle_probes,
    post_idle_probe_count: $post_idle_probe_count,
    core_post_idle_probe_budget_ok: $core_post_idle_probe_budget_ok,
    expected_core_workload_expansions: $expected_core_workload_expansions,
    core_workload_expansion_ok: $core_workload_expansion_ok,
    expected_core_service_shrinks: $expected_core_service_shrinks,
    max_core_service_shrinks: $max_core_service_shrinks,
    core_service_shrink_ok: $core_service_shrink_ok,
    require_core_capacity_during_import: $require_core_capacity_during_import,
    core_capacity_during_import_ok: $core_capacity_during_import_ok,
    max_final_physical_footprint_mib: $max_final_physical_footprint_mib,
    final_physical_footprint_bytes: $final_physical_footprint_bytes,
    final_physical_footprint_ok: $final_physical_footprint_ok,
    max_final_core_target_mib: $max_final_core_target_mib,
    final_core_target_mib: $final_core_target_mib,
    final_core_target_ok: $final_core_target_ok,
    samples: length,
    first: (.[0] // null),
    last: (.[-1] // null),
    max_physical_footprint_bytes: ([.[].host.physical_footprint_bytes] | max // 0),
    min_physical_footprint_bytes: ([.[].host.physical_footprint_bytes] | min // 0),
    max_resident_bytes: ([.[].host.resident_bytes] | max // 0),
    min_resident_bytes: ([.[].host.resident_bytes] | min // 0),
    max_reported_free_reclaimed_bytes: ([.[].balloon.reported_free_reclaimed_bytes] | max // 0),
    max_balloon_reclaimed_bytes: ([.[].balloon.reclaimed_bytes] | max // 0),
    max_reusable_reclaimed_bytes: ([.[].balloon.reusable_reclaimed_bytes] | max // 0),
    max_reusable_restored_bytes: ([.[].balloon.reusable_restored_bytes] | max // 0),
    max_current_balloon_reusable_bytes: ([.[].balloon.current_balloon_reusable_bytes] | max // 0),
    max_host_granule_eligible_bytes: ([.[].balloon.host_granule_eligible_bytes] | max // 0),
    max_partial_host_granule_bytes: ([.[].balloon.partial_host_granule_bytes] | max // 0),
    max_current_fully_owned_host_granules: ([.[].balloon.current_fully_owned_host_granules] | max // 0),
    max_current_partially_owned_host_granules: ([.[].balloon.current_partially_owned_host_granules] | max // 0),
    max_zero_swept_bytes: ([.[].balloon.zero_swept_bytes] | max // 0),
    max_zero_sweep_failed_bytes: ([.[].balloon.zero_sweep_failed_bytes] | max // 0),
    max_hard_decommitted_bytes: ([.[].balloon.hard_decommitted_bytes] | max // 0),
    max_idle_hard_decommitted_bytes: ([.[].balloon.idle_hard_decommitted_bytes] | max // 0),
    max_reuse_failures: ([.[].balloon.reuse_failures] | max // 0),
    max_core_workload_expansions: ([.[].core_memory.workload_expansions] | max // 0),
    max_core_idle_shrinks: ([.[].core_memory.idle_shrinks] | max // 0),
    max_core_idle_deferrals: ([.[].core_memory.idle_deferrals] | max // 0),
    max_core_idle_probes: ([.[].core_memory.idle_probes] | max // 0),
    max_core_transport_activity_events: ([.[].core_memory.transport_activity_events] | max // 0),
    max_core_transport_quiet_transitions: ([.[].core_memory.transport_quiet_transitions] | max // 0),
    max_core_transport_quiet_reclaims: ([.[].core_memory.transport_quiet_reclaims] | max // 0),
    max_core_idle_backing_compactions: ([.[].core_memory.idle_backing_compactions] | max // 0),
    max_core_idle_backing_hard_decommitted_bytes: ([.[].core_memory.idle_backing_hard_decommitted_bytes] | max // 0),
    max_core_idle_backing_compaction_failures: ([.[].core_memory.idle_backing_compaction_failures] | max // 0),
    max_event_reclaim_requests: ([.[].event_reclaim.requests] | max // 0),
    max_event_reclaim_successes: ([.[].event_reclaim.successes] | max // 0),
    max_event_reclaim_errors: ([.[].event_reclaim.errors] | max // 0)
  }' "$TRACE_JSONL" >"$SUMMARY_JSON"

cat "$SUMMARY_JSON"
if [ "$import_rc" -ne 0 ]; then
  exit "$import_rc"
fi
if [ "$compose_stop_rc" -ne 0 ]; then
  exit "$compose_stop_rc"
fi
if ! jq -e '.ok == true' "$SUMMARY_JSON" >/dev/null; then
  exit 1
fi
exit 0

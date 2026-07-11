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
  --expect-core-idle-target-mib N
                               Require Jetstream to return to this target after idle
  --expect-core-workload-expansions N
                               Require at least this many Core workload expansions
  --require-core-capacity-during-import
                               Require Core to retain configured capacity after workload expansion
                               until the import command exits
  --max-core-post-idle-probes N
                               Fail if Jetstream exceeds this probe budget after reaching idle
  --max-final-physical-footprint-mib N
                               Fail if the final Core physical footprint exceeds this limit
  --memory-mib N               Configured guest memory MiB (default: 8192)
  --cpus N                     vCPU count (default: 4)
  --timeout-seconds N          Readiness timeout (default: 900)
  --skip-compose-up            Do not run docker compose up before import
  --reset-compose-volumes      Remove isolated Compose containers and volumes first
  --stop-compose-after-import  Run docker compose stop after the workload and trace idle return
  --skip-api-forward           Do not proxy localhost API traffic into guest Docker
  --skip-sign                  Do not ad-hoc sign VMM with debug entitlements
  -h, --help                   Show this help

Trace output:
  $qa_root/chum-mem-memory-trace.jsonl
  $qa_root/chum-mem-memory-trace-summary.json

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
EXPECT_CORE_IDLE_TARGET_MIB=""
EXPECT_CORE_WORKLOAD_EXPANSIONS=""
REQUIRE_CORE_CAPACITY_DURING_IMPORT=0
MAX_CORE_POST_IDLE_PROBES=""
MAX_FINAL_PHYSICAL_FOOTPRINT_MIB=""
MEMORY_MIB=8192
CPUS=4
TIMEOUT_SECONDS=900
RUN_COMPOSE_UP=1
RESET_COMPOSE_VOLUMES=0
STOP_COMPOSE_AFTER_IMPORT=0
RUN_API_FORWARD=1
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
    --expect-core-idle-target-mib)
      EXPECT_CORE_IDLE_TARGET_MIB="${2:?missing value for --expect-core-idle-target-mib}"
      shift 2
      ;;
    --expect-core-workload-expansions)
      EXPECT_CORE_WORKLOAD_EXPANSIONS="${2:?missing value for --expect-core-workload-expansions}"
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

case "$MEMORY_MIB:$CPUS:$TIMEOUT_SECONDS:$IMPORT_MAX_FILES:$API_HOST_PORT:$PRE_IMPORT_IDLE_SECONDS:$POST_IMPORT_SETTLE_SECONDS" in
  *[!0-9:]*)
    echo "numeric options must be positive integers" >&2
    exit 2
    ;;
esac
if [ -n "$EXPECT_CORE_IDLE_TARGET_MIB" ]; then
  case "$EXPECT_CORE_IDLE_TARGET_MIB" in
    *[!0-9]*|"")
      echo "--expect-core-idle-target-mib must be a positive integer" >&2
      exit 2
      ;;
  esac
  if [ "$EXPECT_CORE_IDLE_TARGET_MIB" -le 0 ]; then
    echo "--expect-core-idle-target-mib must be a positive integer" >&2
    exit 2
  fi
fi
if [ -n "$EXPECT_CORE_WORKLOAD_EXPANSIONS" ]; then
  case "$EXPECT_CORE_WORKLOAD_EXPANSIONS" in
    *[!0-9]*|"")
      echo "--expect-core-workload-expansions must be a non-negative integer" >&2
      exit 2
      ;;
  esac
fi
if [ -n "$MAX_CORE_POST_IDLE_PROBES" ]; then
  case "$MAX_CORE_POST_IDLE_PROBES" in
    *[!0-9]*|"")
      echo "--max-core-post-idle-probes must be a non-negative integer" >&2
      exit 2
      ;;
  esac
fi
if [ -n "$MAX_FINAL_PHYSICAL_FOOTPRINT_MIB" ]; then
  case "$MAX_FINAL_PHYSICAL_FOOTPRINT_MIB" in
    *[!0-9]*|"")
      echo "--max-final-physical-footprint-mib must be a positive integer" >&2
      exit 2
      ;;
  esac
  if [ "$MAX_FINAL_PHYSICAL_FOOTPRINT_MIB" -le 0 ]; then
    echo "--max-final-physical-footprint-mib must be a positive integer" >&2
    exit 2
  fi
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
TRACE_STOP="$QA_ROOT/trace.stop"

mkdir -p "$RUN_DIR" "$(dirname -- "$SERIAL_LOG")"
rm -f "$DOCKER_SOCKET" "$MEMORY_SOCKET" "$CONTROL_SOCKET" "$STDOUT_LOG" "$STDERR_LOG" "$TRACE_JSONL" "$SUMMARY_JSON" "$COMPOSE_STOP_LOG" "$TRACE_STOP"

VMM_PID=""
SAMPLER_PID=""
API_FORWARD_PID=""
cleanup() {
  if [ -n "$API_FORWARD_PID" ] && kill -0 "$API_FORWARD_PID" >/dev/null 2>&1; then
    kill "$API_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$API_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$SAMPLER_PID" ] && kill -0 "$SAMPLER_PID" >/dev/null 2>&1; then
    : >"$TRACE_STOP"
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
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [ "$SECONDS" -le "$deadline" ]; do
    if [ -S "$DOCKER_SOCKET" ] &&
      printf 'GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n' \
        | nc -U "$DOCKER_SOCKET" 2>/dev/null \
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

sample_trace() {
  local stage="$1"
  local control_file="$QA_ROOT/control-sample.json"
  local metrics_file="$QA_ROOT/guest-memory-sample.json"
  local slices_file="$QA_ROOT/service-slices-sample.json"
  control_request '{"command":"metrics"}' >"$control_file" 2>/dev/null || return 0
  http_unix_get "$MEMORY_SOCKET" "/conjet-memory-metrics" >"$metrics_file" 2>/dev/null || return 0
  if ! http_unix_get "$MEMORY_SOCKET" "/conjet-memory-service-slices" >"$slices_file" 2>/dev/null ||
    ! jq -e 'type == "object" and (.slices | type == "array")' "$slices_file" >/dev/null 2>&1; then
    printf '{"version":1,"slices":[],"source":"unavailable"}\n' >"$slices_file"
  fi
  jq -c -n \
    --arg stage "$stage" \
    --slurpfile control "$control_file" \
    --slurpfile metrics "$metrics_file" \
    --slurpfile slices "$slices_file" \
    '($control[0] // {}) as $control |
     ($metrics[0] // {}) as $metrics |
     ($slices[0] // {"slices":[]}) as $slices |
     {
       timestamp: (now | todateiso8601),
       stage: $stage,
       per_slice: [
         ($slices.slices // [])[] |
         {
           key,
           path,
           memory_current,
           inactive_file,
           slab_reclaimable,
           working_set,
           reclaimable,
           populated
         }
       ],
       psi: {
         some_avg10: ($metrics.psi_some_avg10 // 0),
         full_avg10: ($metrics.psi_full_avg10 // 0)
       },
       guest: {
         container_memory_current: ($metrics.container_memory_current // 0),
         service_cgroup_memory_current: ($metrics.service_cgroup_memory_current // 0),
         service_cgroup_working_set: ($metrics.service_cgroup_working_set // 0),
         service_cgroup_populated: ($metrics.service_cgroup_populated // false),
         service_cgroup_population_known: ($metrics.service_cgroup_population_known // false)
       },
       balloon: {
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
       },
       vmm: {
         target_mib: ($control.target_mib // 0),
         target_pages: ($control.target_pages // 0)
       },
       core_memory: {
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
        last_reason: ($control.core_memory.last_reason // null),
         last_error: ($control.core_memory.last_error // null)
       },
       event_reclaim: {
         requests: ($control.event_reclaim.requests // 0),
         successes: ($control.event_reclaim.successes // 0),
         errors: ($control.event_reclaim.errors // 0),
         last_reason: ($control.event_reclaim.last_reason // null),
         last_error: ($control.event_reclaim.last_error // null)
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
  wait "$SAMPLER_PID" >/dev/null 2>&1 || true
  SAMPLER_PID=""
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
wait "$SAMPLER_PID" >/dev/null 2>&1 || true
SAMPLER_PID=""
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
  wait "$SAMPLER_PID" >/dev/null 2>&1 || true
  SAMPLER_PID=""
  sample_trace "compose-stopped"
fi
if [ "$POST_IMPORT_SETTLE_SECONDS" -gt 0 ]; then
  rm -f "$TRACE_STOP"
  sample_loop "post-import-idle" &
  SAMPLER_PID=$!
  sleep "$POST_IMPORT_SETTLE_SECONDS"
  : >"$TRACE_STOP"
  wait "$SAMPLER_PID" >/dev/null 2>&1 || true
  SAMPLER_PID=""
fi
sample_trace "post-import-idle"
vmmap -summary "$VMM_PID" >"$VMMAP_FINAL" 2>&1 || true
footprint "$VMM_PID" >"$FOOTPRINT_FINAL" 2>&1 || true

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

jq -s \
  --arg qa_root "$QA_ROOT" \
  --arg trace_jsonl "$TRACE_JSONL" \
  --arg import_log "$IMPORT_LOG" \
  --arg compose_log "$COMPOSE_LOG" \
  --arg compose_stop_log "$COMPOSE_STOP_LOG" \
  --arg api_forward_log "$API_FORWARD_LOG" \
  --arg vmmap_final "$VMMAP_FINAL" \
  --arg footprint_final "$FOOTPRINT_FINAL" \
  --argjson import_exit_code "$import_rc" \
  --argjson expected_core_idle_target_mib "$EXPECTED_CORE_IDLE_TARGET_JSON" \
  --argjson max_core_post_idle_probes "$MAX_CORE_POST_IDLE_PROBES_JSON" \
  --argjson expected_core_workload_expansions "$EXPECTED_CORE_WORKLOAD_EXPANSIONS_JSON" \
  --argjson require_core_capacity_during_import "$REQUIRE_CORE_CAPACITY_DURING_IMPORT_JSON" \
  --argjson stop_compose_after_import "$STOP_COMPOSE_AFTER_IMPORT_JSON" \
  --argjson compose_stop_exit_code "$compose_stop_rc" \
  --argjson configured_memory_mib "$MEMORY_MIB" \
  --argjson max_final_physical_footprint_mib "$MAX_FINAL_PHYSICAL_FOOTPRINT_MIB_JSON" \
  '($expected_core_idle_target_mib == null or
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
   ($max_final_physical_footprint_mib == null or
      $final_physical_footprint_bytes <= ($max_final_physical_footprint_mib * 1024 * 1024))
      as $final_physical_footprint_ok |
   {
    ok: ($import_exit_code == 0 and $compose_stop_exit_code == 0 and length > 0 and $core_idle_target_ok and $core_post_idle_probe_budget_ok and $core_workload_expansion_ok and $core_capacity_during_import_ok and $final_physical_footprint_ok),
    qa_root: $qa_root,
    trace_jsonl: $trace_jsonl,
    import_log: $import_log,
    compose_log: $compose_log,
    compose_stop_log: $compose_stop_log,
    api_forward_log: $api_forward_log,
    vmmap_final: $vmmap_final,
    footprint_final: $footprint_final,
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
    require_core_capacity_during_import: $require_core_capacity_during_import,
    core_capacity_during_import_ok: $core_capacity_during_import_ok,
    max_final_physical_footprint_mib: $max_final_physical_footprint_mib,
    final_physical_footprint_bytes: $final_physical_footprint_bytes,
    final_physical_footprint_ok: $final_physical_footprint_ok,
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
    max_reuse_failures: ([.[].balloon.reuse_failures] | max // 0),
    max_core_workload_expansions: ([.[].core_memory.workload_expansions] | max // 0),
    max_core_idle_shrinks: ([.[].core_memory.idle_shrinks] | max // 0),
    max_core_idle_deferrals: ([.[].core_memory.idle_deferrals] | max // 0),
    max_core_idle_probes: ([.[].core_memory.idle_probes] | max // 0),
    max_core_transport_activity_events: ([.[].core_memory.transport_activity_events] | max // 0),
    max_core_transport_quiet_transitions: ([.[].core_memory.transport_quiet_transitions] | max // 0),
    max_core_transport_quiet_reclaims: ([.[].core_memory.transport_quiet_reclaims] | max // 0),
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

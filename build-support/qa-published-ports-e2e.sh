#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: qa-published-ports-e2e.sh [options]

Run live Docker published-port QA against an already-running Conjet Docker
socket. The script does not start, stop, or restart Conjet. It creates only
uniquely named QA containers and a uniquely named Compose project, then removes
them on exit.

Options:
  --docker-host HOST          Docker host, e.g. unix:///path/to/docker.sock
                              (default: DOCKER_HOST or unix://$CONJET_HOME/run/docker.sock)
  --conjet PATH              Conjet CLI for diagnostics (default: conjet on PATH)
  --conjet-home PATH         CONJET_HOME to use for diagnostics and default socket
  --qa-root DIR              Artifact directory (default: mktemp under /Volumes/ExternalSSD/dev_workspace/tmp)
  --image IMAGE              Test image (default: python:3.12-alpine)
  --extra-high-ports N       Additional docker-run high ports to publish (default: 3)
  --stress-requests N        Requests per published URL during stress (default: 80)
  --stress-parallel N        Parallel stress workers (default: 16)
  --timeout-seconds N        Per-readiness timeout (default: 45)
  --include-low-ports        Also publish and validate 127.0.0.1:80 and :443
  --skip-compose             Skip Docker Compose validation
  --keep-containers          Leave QA containers/project running after failure
  -h, --help                 Show this help

Low-port validation is intentionally opt-in because it requires cached sudo for
Conjet's privileged helper and briefly occupies localhost ports 80 and 443.
USAGE
}

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEFAULT_TMP_PARENT="/Volumes/ExternalSSD/dev_workspace/tmp"
if [ ! -d "$DEFAULT_TMP_PARENT" ]; then
  DEFAULT_TMP_PARENT="/tmp"
fi

CONJET_HOME_VALUE="${CONJET_HOME:-}"
DOCKER_HOST_VALUE="${DOCKER_HOST:-}"
CONJET_BIN="${CONJET_BIN:-}"
QA_ROOT=""
IMAGE="python:3.12-alpine"
EXTRA_HIGH_PORTS=3
STRESS_REQUESTS=80
STRESS_PARALLEL=16
TIMEOUT_SECONDS=45
INCLUDE_LOW_PORTS=0
SKIP_COMPOSE=0
KEEP_CONTAINERS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --docker-host)
      DOCKER_HOST_VALUE="${2:?missing value for --docker-host}"
      shift 2
      ;;
    --conjet)
      CONJET_BIN="${2:?missing value for --conjet}"
      shift 2
      ;;
    --conjet-home)
      CONJET_HOME_VALUE="${2:?missing value for --conjet-home}"
      shift 2
      ;;
    --qa-root)
      QA_ROOT="${2:?missing value for --qa-root}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --extra-high-ports)
      EXTRA_HIGH_PORTS="${2:?missing value for --extra-high-ports}"
      shift 2
      ;;
    --stress-requests)
      STRESS_REQUESTS="${2:?missing value for --stress-requests}"
      shift 2
      ;;
    --stress-parallel)
      STRESS_PARALLEL="${2:?missing value for --stress-parallel}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:?missing value for --timeout-seconds}"
      shift 2
      ;;
    --include-low-ports)
      INCLUDE_LOW_PORTS=1
      shift
      ;;
    --skip-compose)
      SKIP_COMPOSE=1
      shift
      ;;
    --keep-containers)
      KEEP_CONTAINERS=1
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

case "$EXTRA_HIGH_PORTS:$STRESS_REQUESTS:$STRESS_PARALLEL:$TIMEOUT_SECONDS" in
  *[!0-9:]*)
    echo "numeric options must be non-negative integers" >&2
    exit 2
    ;;
esac
if [ "$STRESS_REQUESTS" -lt 1 ] || [ "$STRESS_PARALLEL" -lt 1 ] || [ "$TIMEOUT_SECONDS" -lt 1 ]; then
  echo "stress and timeout options must be positive" >&2
  exit 2
fi

if [ -z "$QA_ROOT" ]; then
  QA_ROOT="$(mktemp -d "$DEFAULT_TMP_PARENT/conjet-published-ports-e2e.XXXXXX")"
else
  mkdir -p "$QA_ROOT"
fi
LOG_DIR="$QA_ROOT/logs"
mkdir -p "$LOG_DIR"

if [ -z "$DOCKER_HOST_VALUE" ]; then
  if [ -n "$CONJET_HOME_VALUE" ]; then
    DOCKER_HOST_VALUE="unix://$CONJET_HOME_VALUE/run/docker.sock"
  else
    DOCKER_HOST_VALUE="unix://$HOME/.conjet/run/docker.sock"
  fi
fi

if [ -z "$CONJET_BIN" ]; then
  if command -v conjet >/dev/null 2>&1; then
    CONJET_BIN="$(command -v conjet)"
  else
    CONJET_BIN=""
  fi
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

require_command docker
require_command python3
require_command curl

RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
RUN_NAME="conjet-port-qa-run-$RUN_ID"
LOW_NAME="conjet-port-qa-low-$RUN_ID"
COMPOSE_PROJECT="conjetportqa$RUN_ID"
COMPOSE_FILE="$QA_ROOT/compose.yaml"
SUMMARY="$QA_ROOT/summary.txt"

docker_cmd() {
  docker --host "$DOCKER_HOST_VALUE" "$@"
}

run_conjet() {
  if [ -z "$CONJET_BIN" ]; then
    return 127
  fi
  if [ -n "$CONJET_HOME_VALUE" ]; then
    CONJET_HOME="$CONJET_HOME_VALUE" "$CONJET_BIN" "$@"
  else
    "$CONJET_BIN" "$@"
  fi
}

cleanup() {
  if [ "$KEEP_CONTAINERS" -eq 1 ]; then
    return
  fi
  set +e
  docker_cmd rm -f "$RUN_NAME" "$LOW_NAME" >/dev/null 2>&1
  if [ -f "$COMPOSE_FILE" ]; then
    docker_cmd compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" down -v --remove-orphans \
      >"$LOG_DIR/compose-down.log" 2>&1
  fi
}
trap cleanup EXIT

reserve_ports() {
  python3 - "$1" <<'PY'
import socket
import sys

count = int(sys.argv[1])
sockets = []
try:
    for _ in range(count):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind(("127.0.0.1", 0))
        sockets.append(sock)
    for sock in sockets:
        print(sock.getsockname()[1])
finally:
    for sock in sockets:
        sock.close()
PY
}

stress_url() {
  local label="$1"
  local url="$2"
  local log="$LOG_DIR/stress-$label.log"
  python3 - "$url" "$STRESS_REQUESTS" "$STRESS_PARALLEL" "$TIMEOUT_SECONDS" >"$log" <<'PY'
import concurrent.futures
import sys
import urllib.request

url = sys.argv[1]
requests = int(sys.argv[2])
parallel = int(sys.argv[3])
timeout = int(sys.argv[4])

def fetch(index):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read(256)
            if response.status < 200 or response.status >= 300:
                return f"FAILED {index}: HTTP {response.status}"
            if not body:
                return f"FAILED {index}: empty response"
            return None
    except Exception as exc:
        return f"FAILED {index}: {exc}"

failures = []
with concurrent.futures.ThreadPoolExecutor(max_workers=parallel) as executor:
    for result in executor.map(fetch, range(requests)):
        if result is not None:
            failures.append(result)

for failure in failures:
    print(failure)
sys.exit(1 if failures else 0)
PY
}

wait_http() {
  local label="$1"
  local url="$2"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local log="$LOG_DIR/readiness-$label.log"
  : >"$log"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 "$url" >"$log" 2>"$LOG_DIR/readiness-$label.stderr"; then
      return 0
    fi
    sleep 0.25
  done
  curl -v --max-time 5 "$url" >"$log" 2>"$LOG_DIR/readiness-$label.stderr" || true
  echo "service did not become reachable: $label $url" >&2
  echo "see $log and $LOG_DIR/readiness-$label.stderr" >&2
  return 1
}

diagnose_port() {
  local port="$1"
  local label="$2"
  if [ -z "$CONJET_BIN" ]; then
    return 0
  fi
  run_conjet port diagnose "$port/tcp" >"$LOG_DIR/diagnose-$label.txt" 2>&1 || true
}

check_low_port_preflight() {
  local port="$1"
  python3 - "$port" <<'PY'
import errno
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("127.0.0.1", port))
except PermissionError:
    sys.exit(0)
except OSError as exc:
    if exc.errno == errno.EADDRINUSE:
        print(f"localhost:{port} is already in use", file=sys.stderr)
        sys.exit(2)
    print(f"localhost:{port} preflight failed: {exc}", file=sys.stderr)
    sys.exit(1)
else:
    print(f"localhost:{port} is directly bindable; privileged helper path will not be exercised", file=sys.stderr)
    sys.exit(0)
finally:
    sock.close()
PY
}

write_summary_header() {
  {
    echo "qa_root=$QA_ROOT"
    echo "docker_host=$DOCKER_HOST_VALUE"
    echo "conjet_bin=$CONJET_BIN"
    echo "conjet_home=$CONJET_HOME_VALUE"
    echo "image=$IMAGE"
    echo "stress_requests=$STRESS_REQUESTS"
    echo "stress_parallel=$STRESS_PARALLEL"
    echo "include_low_ports=$INCLUDE_LOW_PORTS"
    echo "note=no screenshots: this validates localhost network reachability, not a visual UI surface"
  } >"$SUMMARY"
}

append_summary() {
  printf '%s\n' "$1" >>"$SUMMARY"
}

write_summary_header

echo "qa-published-ports-e2e: qa root: $QA_ROOT"
docker_cmd version >"$LOG_DIR/docker-version.txt" 2>&1
if [ -n "$CONJET_BIN" ]; then
  run_conjet network status --json >"$LOG_DIR/network-status-before.json" 2>&1 || true
fi

RUN_PORTS=()
while IFS= read -r port; do
  RUN_PORTS+=("$port")
done < <(reserve_ports "$((EXTRA_HIGH_PORTS + 1))")
RUN_ARGS=(run --rm -d --name "$RUN_NAME")
for port in "${RUN_PORTS[@]}"; do
  RUN_ARGS+=(-p "127.0.0.1:$port:8000")
done
RUN_ARGS+=("$IMAGE" python -u -m http.server 8000)

docker_cmd "${RUN_ARGS[@]}" >"$LOG_DIR/docker-run-container-id.txt" 2>"$LOG_DIR/docker-run.stderr"
for port in "${RUN_PORTS[@]}"; do
  label="run-$port"
  wait_http "$label" "http://127.0.0.1:$port/"
  stress_url "$label" "http://127.0.0.1:$port/"
  diagnose_port "$port" "$label"
  append_summary "docker_run_port_$port=ok"
done

if [ "$SKIP_COMPOSE" -eq 0 ]; then
  docker_cmd compose version >"$LOG_DIR/docker-compose-version.txt" 2>&1
  COMPOSE_PORT="$(reserve_ports 1)"
  cat >"$COMPOSE_FILE" <<YAML
services:
  web:
    image: "$IMAGE"
    command: ["python", "-u", "-m", "http.server", "8000"]
    ports:
      - "127.0.0.1:$COMPOSE_PORT:8000"
YAML
  docker_cmd compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d \
    >"$LOG_DIR/compose-up.log" 2>"$LOG_DIR/compose-up.stderr"
  wait_http "compose-$COMPOSE_PORT" "http://127.0.0.1:$COMPOSE_PORT/"
  stress_url "compose-$COMPOSE_PORT" "http://127.0.0.1:$COMPOSE_PORT/"
  diagnose_port "$COMPOSE_PORT" "compose-$COMPOSE_PORT"
  append_summary "compose_port_$COMPOSE_PORT=ok"
fi

if [ "$INCLUDE_LOW_PORTS" -eq 1 ]; then
  check_low_port_preflight 80
  check_low_port_preflight 443
  if ! sudo -n true >"$LOG_DIR/sudo-n.log" 2>&1; then
    echo "low-port QA requires cached sudo for conjet-port-helper; see $LOG_DIR/sudo-n.log" >&2
    exit 1
  fi
  docker_cmd run --rm -d --name "$LOW_NAME" \
    -p "127.0.0.1:80:8000" \
    -p "127.0.0.1:443:8000" \
    "$IMAGE" python -u -m http.server 8000 \
    >"$LOG_DIR/docker-low-container-id.txt" 2>"$LOG_DIR/docker-low.stderr"
  for port in 80 443; do
    label="low-$port"
    wait_http "$label" "http://127.0.0.1:$port/"
    stress_url "$label" "http://127.0.0.1:$port/"
    diagnose_port "$port" "$label"
    append_summary "low_port_$port=ok"
  done
fi

if [ -n "$CONJET_BIN" ]; then
  run_conjet network status --json >"$LOG_DIR/network-status-after.json" 2>&1 || true
fi

append_summary "result=ok"
echo "qa-published-ports-e2e: success"
echo "qa-published-ports-e2e: summary: $SUMMARY"

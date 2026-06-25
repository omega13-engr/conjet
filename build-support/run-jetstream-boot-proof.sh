#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONJET="$ROOT/.build/debug/conjet"
SIGN_DEBUG="$ROOT/build-support/sign-debug.sh"

qa_root=""
kernel=""
initrd=""
phase9_manifest=""
timeout_ms="30000"
max_exits="200000"
memory_mib="512"
require_init_ready="0"
build_ready_initrd="0"
skip_build="0"
skip_sign="0"
check_tools="0"
preflight_only="0"

usage() {
  cat <<'USAGE'
Usage:
  build-support/run-jetstream-boot-proof.sh --kernel PATH [--initrd PATH] [options]
  build-support/run-jetstream-boot-proof.sh --phase9-manifest PATH [options]
  build-support/run-jetstream-boot-proof.sh --check-tools

Runs the Phase 2 Jetstream direct-kernel boot proof in an isolated CONJET_HOME.
The script does not start, stop, or contact the user's live Conjet daemon,
VM, Docker socket, containers, or vmnet state. When real boot assets are
provided it starts only a transient HVF boot-attempt process from the signed
debug CLI.

Options:
  --kernel PATH             Direct uncompressed ARM64 Linux Image to import.
  --initrd PATH             Optional initramfs for --kernel.
  --phase9-manifest PATH    Portable phase9-network-proof-assets.json bundle.
                            Full runs require CONJET_INIT_READY automatically.
  --qa-root DIR             Output root; defaults to /tmp/conjet-phase2-boot-proof.XXXXXX.
  --timeout-ms N            boot-attempt timeout in milliseconds (default: 30000).
  --max-exits N             boot-attempt HVF exit budget (default: 200000).
  --memory-mib N            boot-attempt memory limit (default: 512).
  --require-init-ready      Require CONJET_INIT_READY/conjet-init ready marker.
  --build-ready-initrd      Generate a Conjet-ready initramfs under the QA root.
                            Implies --require-init-ready for --kernel runs.
  --preflight-only          Stop after isolated import, entitlement check, and boot-plan.
                            Writes jetstream-boot-proof-summary.json.
  --skip-build              Do not run swift build before signing.
  --skip-sign               Do not run build-support/sign-debug.sh; still verify entitlement.
  --check-tools             Validate local prerequisites only; do not build, sign, or boot.
  -h, --help                Show this help.
USAGE
}

die() {
  echo "run-jetstream-boot-proof: $*" >&2
  exit 1
}

print_failure_context() {
  status="$?"
  if [ "$status" -ne 0 ] && [ -n "$qa_root" ]; then
    {
      echo "run-jetstream-boot-proof: failed with exit $status"
      echo "run-jetstream-boot-proof: qa root: $qa_root"
      echo "run-jetstream-boot-proof: isolated CONJET_HOME: $qa_root/home"
    } >&2
  fi
}

trap print_failure_context EXIT

need_value() {
  flag="$1"
  shift
  if [ "$#" -eq 0 ] || [ -z "${1:-}" ]; then
    die "$flag requires a value"
  fi
  printf '%s\n' "$1"
}

require_executable() {
  path="$1"
  message="$2"
  [ -x "$path" ] || die "$message: $path"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kernel)
      kernel="$(need_value "$1" "${2:-}")"
      shift 2
      ;;
    --initrd)
      initrd="$(need_value "$1" "${2:-}")"
      shift 2
      ;;
    --phase9-manifest)
      phase9_manifest="$(need_value "$1" "${2:-}")"
      shift 2
      ;;
    --qa-root)
      qa_root="$(need_value "$1" "${2:-}")"
      shift 2
      ;;
    --timeout-ms)
      timeout_ms="$(need_value "$1" "${2:-}")"
      shift 2
      ;;
    --max-exits)
      max_exits="$(need_value "$1" "${2:-}")"
      shift 2
      ;;
    --memory-mib)
      memory_mib="$(need_value "$1" "${2:-}")"
      shift 2
      ;;
    --require-init-ready)
      require_init_ready="1"
      shift
      ;;
    --build-ready-initrd)
      build_ready_initrd="1"
      shift
      ;;
    --preflight-only)
      preflight_only="1"
      shift
      ;;
    --skip-build)
      skip_build="1"
      shift
      ;;
    --skip-sign)
      skip_sign="1"
      shift
      ;;
    --check-tools)
      check_tools="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option '$1'"
      ;;
  esac
done

require_command swift
require_command codesign
require_command mktemp
require_executable "$SIGN_DEBUG" "missing signing helper"

if [ "$check_tools" -eq 1 ]; then
  echo "Phase 2 boot proof harness prerequisites OK"
  exit 0
fi

if [ -n "$phase9_manifest" ] && { [ -n "$kernel" ] || [ -n "$initrd" ]; }; then
  die "use either --phase9-manifest or --kernel/--initrd, not both"
fi
if [ "$build_ready_initrd" -eq 1 ] && [ -n "$phase9_manifest" ]; then
  die "--build-ready-initrd is only valid with --kernel"
fi
if [ "$build_ready_initrd" -eq 1 ] && [ -n "$initrd" ]; then
  die "use either --build-ready-initrd or --initrd, not both"
fi
if [ -z "$phase9_manifest" ] && [ -z "$kernel" ]; then
  die "provide --kernel PATH or --phase9-manifest PATH"
fi
if [ -n "$kernel" ] && [ ! -f "$kernel" ]; then
  die "kernel not found: $kernel"
fi
if [ -n "$initrd" ] && [ ! -f "$initrd" ]; then
  die "initrd not found: $initrd"
fi
if [ -n "$phase9_manifest" ] && [ ! -f "$phase9_manifest" ]; then
  die "phase9 manifest not found: $phase9_manifest"
fi

case "$timeout_ms" in *[!0-9]*|"") die "--timeout-ms must be a positive integer" ;; esac
case "$max_exits" in *[!0-9]*|"") die "--max-exits must be a positive integer" ;; esac
case "$memory_mib" in *[!0-9]*|"") die "--memory-mib must be a positive integer" ;; esac

if [ -n "$phase9_manifest" ]; then
  require_init_ready="1"
fi
if [ "$build_ready_initrd" -eq 1 ]; then
  require_init_ready="1"
fi

if [ "$require_init_ready" -eq 1 ] && [ -z "$phase9_manifest" ] && [ -z "$initrd" ] && [ "$build_ready_initrd" -eq 0 ]; then
  die "--require-init-ready requires --initrd PATH or --build-ready-initrd when importing with --kernel"
fi

if [ -z "$qa_root" ]; then
  qa_root="$(mktemp -d /tmp/conjet-phase2-boot-proof.XXXXXX)"
fi
mkdir -p "$qa_root"

export CONJET_HOME="$qa_root/home"
mkdir -p "$CONJET_HOME"

if [ "$skip_build" -eq 0 ]; then
  (cd "$ROOT" && swift build)
fi
require_executable "$CONJET" "debug conjet CLI is missing; run swift build first"

if [ "$skip_sign" -eq 0 ]; then
  "$SIGN_DEBUG" >"$qa_root/sign-debug.log" 2>&1
fi

entitlements="$qa_root/conjet-entitlements.plist"
if ! codesign -d --entitlements :- "$CONJET" >"$entitlements" 2>"$qa_root/codesign-entitlements.log"; then
  die "could not inspect conjet entitlements; see $qa_root/codesign-entitlements.log"
fi
if ! grep -q "com.apple.security.hypervisor" "$entitlements"; then
  die "debug conjet CLI is missing com.apple.security.hypervisor entitlement; see $entitlements"
fi

import_json="$qa_root/import.json"
boot_plan_json="$qa_root/boot-plan.json"
boot_attempt_json="$qa_root/boot-attempt.json"
readiness_json="$qa_root/readiness-phase2.json"
console_log="$qa_root/console.log"
evidence_json="$qa_root/phase2-evidence.json"
dtb_name="jetstream-phase2.dtb"
if [ -n "$phase9_manifest" ]; then
  dtb_name="jetstream-phase9.dtb"
fi
dtb_path="$qa_root/$dtb_name"
run_summary_json="$qa_root/jetstream-boot-proof-summary.json"
initrd_build_json="$qa_root/initramfs-build.json"
generated_initrd="$qa_root/conjet-ready-initramfs.cpio.gz"
backend_set_json="$qa_root/backend-set.json"

json_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_run_summary() {
  mode="$1"
  hvf_started="$2"
  phase9_bundle="false"
  init_ready_required="false"
  ready_initrd_generated="false"
  if [ -n "$phase9_manifest" ]; then
    phase9_bundle="true"
  fi
  if [ "$require_init_ready" -eq 1 ]; then
    init_ready_required="true"
  fi
  if [ "$build_ready_initrd" -eq 1 ]; then
    ready_initrd_generated="true"
  fi
  initrd_build_json_value="null"
  if [ "$build_ready_initrd" -eq 1 ]; then
    initrd_build_json_value="\"$(json_string "$initrd_build_json")\""
  fi
  cat >"$run_summary_json" <<EOF
{
  "schemaVersion": 1,
  "mode": "$(json_string "$mode")",
  "qaRoot": "$(json_string "$qa_root")",
  "conjetHome": "$(json_string "$CONJET_HOME")",
  "phase9Bundle": $phase9_bundle,
  "initReadyRequired": $init_ready_required,
  "readyInitrdGenerated": $ready_initrd_generated,
  "hvfStarted": $hvf_started,
  "initrd": "$(json_string "$initrd")",
  "initrdBuild": $initrd_build_json_value,
  "import": "$(json_string "$import_json")",
  "backendSet": "$(json_string "$backend_set_json")",
  "bootPlan": "$(json_string "$boot_plan_json")",
  "dtb": "$(json_string "$dtb_path")",
  "bootAttempt": "$(json_string "$boot_attempt_json")",
  "consoleLog": "$(json_string "$console_log")",
  "evidence": "$(json_string "$evidence_json")",
  "readiness": "$(json_string "$readiness_json")"
}
EOF
}

if [ -n "$phase9_manifest" ]; then
  "$CONJET" --json vm import-phase9-network-proof \
    --manifest "$phase9_manifest" >"$import_json"
else
  if [ "$build_ready_initrd" -eq 1 ]; then
    "$CONJET" --json vm build-initramfs \
      --conjet-ready-probe \
      --output "$generated_initrd" >"$initrd_build_json"
    initrd="$generated_initrd"
  fi
  if [ -n "$initrd" ]; then
    "$CONJET" --json vm init \
      --kernel "$kernel" \
      --initrd "$initrd" >"$import_json"
  else
    "$CONJET" --json vm init \
      --kernel "$kernel" >"$import_json"
  fi
fi

"$CONJET" --json vm backend set hvf-experimental >"$backend_set_json"

"$CONJET" --json vm backend boot-plan \
  --dtb "$dtb_path" >"$boot_plan_json"

if [ "$preflight_only" -eq 1 ]; then
  "$CONJET" --json vm backend readiness >"$readiness_json"
  write_run_summary "preflight" "false"
  echo "Conjet Phase 2 Jetstream boot preflight completed"
  echo "  qa root: $qa_root"
  echo "  isolated CONJET_HOME: $CONJET_HOME"
  echo "  import: $import_json"
  if [ "$build_ready_initrd" -eq 1 ]; then
    echo "  initrd build: $initrd_build_json"
  else
    echo "  initrd build: not generated"
  fi
  echo "  boot plan: $boot_plan_json"
  echo "  dtb: $dtb_path"
  echo "  readiness: $readiness_json"
  echo "  summary: $run_summary_json"
  echo "  boot attempt: skipped by --preflight-only"
  exit 0
fi

if [ "$require_init_ready" -eq 1 ]; then
  "$CONJET" --json vm backend boot-attempt \
    --timeout-ms "$timeout_ms" \
    --max-exits "$max_exits" \
    --memory-mib "$memory_mib" \
    --require-init-ready \
    --console-log "$console_log" \
    --record-evidence \
    --evidence "$evidence_json" \
    --evidence-artifact "$console_log" >"$boot_attempt_json"
else
  "$CONJET" --json vm backend boot-attempt \
    --timeout-ms "$timeout_ms" \
    --max-exits "$max_exits" \
    --memory-mib "$memory_mib" \
    --console-log "$console_log" \
    --record-evidence \
    --evidence "$evidence_json" \
    --evidence-artifact "$console_log" >"$boot_attempt_json"
fi

"$CONJET" --json vm backend readiness \
  --evidence "$evidence_json" \
  --require-phase 2 >"$readiness_json"

write_run_summary "boot-proof" "true"

echo "Conjet Phase 2 Jetstream boot proof completed"
echo "  qa root: $qa_root"
echo "  isolated CONJET_HOME: $CONJET_HOME"
echo "  import: $import_json"
if [ "$build_ready_initrd" -eq 1 ]; then
  echo "  initrd build: $initrd_build_json"
else
  echo "  initrd build: not generated"
fi
echo "  boot plan: $boot_plan_json"
echo "  dtb: $dtb_path"
echo "  boot attempt: $boot_attempt_json"
echo "  console log: $console_log"
echo "  evidence: $evidence_json"
echo "  readiness: $readiness_json"
echo "  summary: $run_summary_json"

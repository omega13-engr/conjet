#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build the complete Conjet Phase 9 network-proof asset bundle.

Usage:
  guest/kernel/scripts/build-phase9-network-proof-assets.sh [options]

Options:
  --check-tools              Validate prerequisites without downloading or building.
  --output-dir DIR           Bundle output directory. Default: guest/kernel/dist/phase9-network-proof
  --proof-url URL            Guest outbound HTTP proof URL. Default: http://example.com
  --guest-service-port PORT  BusyBox httpd proof service port. Default: 8080
  -h, --help                 Show this help.

Environment overrides:
  KERNEL_VERSION             Forwarded to build-linux.sh.
  BUSYBOX_VERSION            Forwarded to build-busybox.sh.
  OUT_DIR                    Output directory if --output-dir is not provided.
  WORK_DIR                   Forwarded to the kernel and BusyBox builders.
  MAKE_FLAGS                 Forwarded to the kernel and BusyBox builders.
  CROSS_COMPILE              Forwarded to build-busybox.sh.
  CONJET_PHASE9_LINUX_BUILDER
  CONJET_PHASE9_BUSYBOX_BUILDER
  CONJET_PHASE9_INITRAMFS_BUILDER
  CONJET_PHASE9_BUNDLE_VERIFIER
                             Internal test hooks for substituting builders.

Output:
  <OUT_DIR>/Image
  <OUT_DIR>/kernel-build-manifest.json
  <OUT_DIR>/busybox
  <OUT_DIR>/conjet-network-proof-initramfs.cpio.gz
  <OUT_DIR>/phase9-network-proof-assets.json

The script does not start a Conjet VM, conjetd, Docker, or vmnet. It only builds
and validates the assets required before `conjet vm backend phase9-network-proof`.
USAGE
}

check_only=false
proof_url="${PROOF_URL:-http://example.com}"
guest_service_port="${GUEST_SERVICE_PORT:-8080}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
kernel_root="${repo_root}/guest/kernel"
scripts_dir="${kernel_root}/scripts"
bundle_out_dir="${OUT_DIR:-${kernel_root}/dist/phase9-network-proof}"
phase9_work_dir="${WORK_DIR:-${kernel_root}/.build}/phase9-network-proof-assets"
phase9_linux_out_dir="${phase9_work_dir}/linux"
phase9_busybox_out_dir="${phase9_work_dir}/busybox"
linux_builder="${CONJET_PHASE9_LINUX_BUILDER:-${scripts_dir}/build-linux.sh}"
busybox_builder="${CONJET_PHASE9_BUSYBOX_BUILDER:-${scripts_dir}/build-busybox.sh}"
initramfs_builder="${CONJET_PHASE9_INITRAMFS_BUILDER:-${scripts_dir}/build-network-proof-initramfs.sh}"
bundle_verifier="${CONJET_PHASE9_BUNDLE_VERIFIER:-${scripts_dir}/verify-phase9-network-proof-assets.pl}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-tools)
      check_only=true
      shift
      ;;
    --output-dir)
      if [ "$#" -lt 2 ]; then
        echo "error: --output-dir requires a value" >&2
        exit 64
      fi
      bundle_out_dir="$2"
      shift 2
      ;;
    --proof-url)
      if [ "$#" -lt 2 ]; then
        echo "error: --proof-url requires a value" >&2
        exit 64
      fi
      proof_url="$2"
      shift 2
      ;;
    --guest-service-port)
      if [ "$#" -lt 2 ]; then
        echo "error: --guest-service-port requires a value" >&2
        exit 64
      fi
      guest_service_port="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

require_command() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "error: required command not found: ${name}" >&2
    exit 69
  fi
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "error: shasum or sha256sum is required." >&2
    exit 69
  fi
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1"
}

validate_common_tools() {
  for command_name in awk cp date mkdir mktemp perl sed tail tee; do
    require_command "${command_name}"
  done
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "error: shasum or sha256sum is required." >&2
    exit 69
  fi
}

validate_port() {
  case "${guest_service_port}" in
    ''|*[!0-9]*)
      echo "error: --guest-service-port must be numeric" >&2
      exit 64
      ;;
  esac
  if [ "${guest_service_port}" -lt 1 ] || [ "${guest_service_port}" -gt 65535 ]; then
    echo "error: --guest-service-port must be 1...65535" >&2
    exit 64
  fi
}

validate_common_tools
validate_port

run_prerequisite_check() {
  if [ "${check_only}" = true ]; then
    "$@"
  else
    "$@" >&2
  fi
}

run_prerequisite_check "${linux_builder}" --check-tools
run_prerequisite_check "${busybox_builder}" --check-tools
run_prerequisite_check "${initramfs_builder}" --check-tools
run_prerequisite_check "${bundle_verifier}" --check-tools

if [ "${check_only}" = true ]; then
  printf 'Conjet Phase 9 network-proof asset prerequisites OK\n'
  exit 0
fi

mkdir -p "${bundle_out_dir}"
mkdir -p "${phase9_linux_out_dir}" "${phase9_busybox_out_dir}"

run_builder_and_capture_path() {
  local label="$1"
  shift
  local log_path output_path status
  log_path="$(mktemp "${TMPDIR:-/tmp}/conjet-${label}.XXXXXX.log")"

  set +e
  "$@" 2>&1 | tee "${log_path}" >&2
  status="${PIPESTATUS[0]}"
  set -e

  if [ "${status}" -ne 0 ]; then
    echo "error: ${label} builder failed; log follows from ${log_path}" >&2
    tail -n 200 "${log_path}" >&2
    exit 65
  fi
  output_path="$(awk 'NF { line = $0 } END { print line }' "${log_path}")"
  rm -f "${log_path}"
  if [ -z "${output_path}" ] || [ ! -e "${output_path}" ]; then
    echo "error: ${label} builder did not finish with an existing artifact path: ${output_path:-<empty>}" >&2
    exit 65
  fi
  printf '%s\n' "${output_path}"
}

kernel_image="$(run_builder_and_capture_path build-linux env OUT_DIR="${phase9_linux_out_dir}" "${linux_builder}")"
busybox_bin="$(run_builder_and_capture_path build-busybox env OUT_DIR="${phase9_busybox_out_dir}" "${busybox_builder}")"
kernel_manifest_src="$(dirname "${kernel_image}")/manifest.json"
bundle_kernel="${bundle_out_dir}/Image"
bundle_kernel_manifest="${bundle_out_dir}/kernel-build-manifest.json"
bundle_busybox="${bundle_out_dir}/busybox"
bundle_initramfs="${bundle_out_dir}/conjet-network-proof-initramfs.cpio.gz"
bundle_manifest="${bundle_out_dir}/phase9-network-proof-assets.json"

if [ ! -f "${kernel_manifest_src}" ]; then
  echo "error: kernel builder did not emit manifest.json next to ${kernel_image}" >&2
  exit 65
fi

cp "${kernel_image}" "${bundle_kernel}"
cp "${kernel_manifest_src}" "${bundle_kernel_manifest}"
cp "${busybox_bin}" "${bundle_busybox}"
chmod 0755 "${bundle_busybox}"

"${initramfs_builder}" \
  --busybox "${bundle_busybox}" \
  --proof-url "${proof_url}" \
  --guest-service-port "${guest_service_port}" \
  --output "${bundle_initramfs}" > "${bundle_out_dir}/initramfs-build.json"

cat > "${bundle_manifest}" <<MANIFEST
{
  "schemaVersion": 1,
  "name": "conjet-phase9-network-proof-assets",
  "architecture": "arm64",
  "createdAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "kernelImage": "Image",
  "kernelImageSha256": "$(sha256 "${bundle_kernel}")",
  "kernelBuildManifest": "kernel-build-manifest.json",
  "kernelBuildManifestSha256": "$(sha256 "${bundle_kernel_manifest}")",
  "busybox": "busybox",
  "busyboxSha256": "$(sha256 "${bundle_busybox}")",
  "initramfs": "conjet-network-proof-initramfs.cpio.gz",
  "initramfsSha256": "$(sha256 "${bundle_initramfs}")",
  "proofURL": "$(json_escape "${proof_url}")",
  "guestServicePort": ${guest_service_port}
}
MANIFEST

"${bundle_verifier}" --manifest "${bundle_manifest}" >&2

printf '%s\n' "${bundle_manifest}"

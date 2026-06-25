#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build the ARM64 Linux kernel Image used by Conjet's direct-kernel VM lane.

Usage:
  guest/kernel/scripts/build-linux.sh [--check-tools|--validate-config]

Options:
  --check-tools       Validate host/toolchain prerequisites without downloading or building.
  --validate-config   Resolve the final Linux .config and validate required built-ins only.
  -h, --help          Show this help.

Environment overrides:
  KERNEL_VERSION      Linux release to build. Default: 6.12.86
  KERNEL_URL          Source tarball URL. Default: official kernel.org tarball
  KERNEL_SHA256       Expected source tarball SHA-256. Default: parsed from kernel.org sha256sums.asc
  KERNEL_SHA256_URL   SHA-256 manifest URL. Default: kernel.org sha256sums.asc for the major series
  KERNEL_BASE_CONFIG  Base Kconfig target. Default: allnoconfig. Optional: defconfig
  MAKE                GNU Make command. Default: make
  HOSTCC              Host C compiler used by Linux Kconfig tools. Default: gcc
  OUT_DIR             Output directory. Default: profile-derived dist path
  WORK_DIR            Scratch/source directory. Default: guest/kernel/.build
  KERNEL_PROFILE      Kernel profile: docker or fast. Default: docker
  CONFIG_FRAGMENT     Kernel config fragment. Default: profile-derived fragment
  MAKE_FLAGS          Extra make flags. Default: -j<host-cpu-count> LLVM=1

This builder is intentionally Linux-hosted. Set
CONJET_ALLOW_NON_LINUX_KERNEL_BUILD=1 only for controlled experiments with a
known-compatible cross build environment.
USAGE
}

check_only=false
validate_config_only=false
case "${1:-}" in
  "")
    ;;
  "--check-tools")
    check_only=true
    ;;
  "--validate-config")
    validate_config_only=true
    ;;
  "-h"|"--help")
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 64
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
kernel_root="${repo_root}/guest/kernel"

kernel_version="${KERNEL_VERSION:-6.12.86}"
kernel_major="${KERNEL_MAJOR:-${kernel_version%%.*}.x}"
kernel_url="${KERNEL_URL:-https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}/linux-${kernel_version}.tar.xz}"
kernel_sha256_url="${KERNEL_SHA256_URL:-https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}/sha256sums.asc}"
work_dir="${WORK_DIR:-${kernel_root}/.build}"
source_dir="${work_dir}/linux-${kernel_version}"
tarball="${work_dir}/linux-${kernel_version}.tar.xz"
checksum_file="${tarball}.sha256sums.asc"
kernel_profile="${KERNEL_PROFILE:-docker}"
case "${kernel_profile}" in
  docker|debug)
    default_config_fragment="${kernel_root}/config/conjet-arm64.config"
    out_dir_default="${kernel_root}/dist/linux-${kernel_version}-conjet-arm64"
    ;;
  fast|pulse-fast)
    kernel_profile="fast"
    default_config_fragment="${kernel_root}/config/conjet-fast-arm64.config"
    out_dir_default="${kernel_root}/dist/linux-${kernel_version}-conjet-fast-arm64"
    ;;
  *)
    echo "error: unsupported KERNEL_PROFILE: ${kernel_profile}" >&2
    echo "supported values: docker, debug, fast, pulse-fast" >&2
    exit 64
    ;;
esac
out_dir="${OUT_DIR:-${out_dir_default}}"
config_fragment="${CONFIG_FRAGMENT:-${default_config_fragment}}"
make_cmd="${MAKE:-make}"
host_cc="${HOSTCC:-gcc}"
default_make_jobs() {
  local jobs max_jobs
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
  case "${jobs}" in
    ''|*[!0-9]*) jobs=4 ;;
  esac
  max_jobs="${CONJET_KERNEL_MAX_JOBS:-2}"
  case "${max_jobs}" in
    ''|*[!0-9]*) max_jobs=2 ;;
  esac
  if [ "${jobs}" -gt "${max_jobs}" ]; then
    jobs="${max_jobs}"
  fi
  printf '%s\n' "${jobs}"
}

if [ "${MAKE_FLAGS+x}" = x ]; then
  make_flags="${MAKE_FLAGS}"
else
  make_flags="-j$(default_make_jobs) LLVM=1"
fi
kernel_base_config="${KERNEL_BASE_CONFIG:-allnoconfig}"

raise_file_descriptor_limit() {
  local desired current
  desired="${CONJET_KERNEL_NOFILE_LIMIT:-65536}"
  case "${desired}" in
    ''|*[!0-9]*) desired=65536 ;;
  esac
  current="$(ulimit -n 2>/dev/null || echo 0)"
  case "${current}" in
    ''|*[!0-9]*) current=0 ;;
  esac
  if [ "${current}" -lt "${desired}" ]; then
    ulimit -n "${desired}" 2>/dev/null || true
  fi
}

raise_file_descriptor_limit

require_command() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "error: required command not found: ${name}" >&2
    exit 69
  fi
}

require_checksum_tool() {
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "error: shasum or sha256sum is required to verify Linux source." >&2
    exit 69
  fi
}

require_gnu_make() {
  require_command "${make_cmd}"

  local first_line version major
  first_line="$("${make_cmd}" --version 2>/dev/null | head -n 1 || true)"
  if [[ ! "${first_line}" =~ GNU[[:space:]]Make[[:space:]]([0-9]+)(\.([0-9]+))? ]]; then
    echo "error: GNU Make >= 4.0 is required; '${make_cmd}' reported: ${first_line:-<empty>}" >&2
    exit 69
  fi

  major="${BASH_REMATCH[1]}"
  if [ "${major}" -lt 4 ]; then
    version="${BASH_REMATCH[1]}${BASH_REMATCH[2]:-}"
    echo "error: GNU Make >= 4.0 is required; '${make_cmd}' reported ${version}" >&2
    exit 69
  fi
}

require_host_c_compiler() {
  require_command "${host_cc}"
}

check_tools() {
  if [ "$(uname -s)" != "Linux" ] && [ "${CONJET_ALLOW_NON_LINUX_KERNEL_BUILD:-0}" != "1" ]; then
    cat >&2 <<'ERROR'
error: Conjet Linux kernel builds must run in a Linux builder.

Use a Linux builder with the LLVM kernel toolchain, or set
CONJET_ALLOW_NON_LINUX_KERNEL_BUILD=1 only for controlled experiments.
ERROR
    exit 69
  fi

  for command_name in curl tar; do
    require_command "${command_name}"
  done
  require_gnu_make
  require_host_c_compiler
  require_checksum_tool

  if [ ! -f "${config_fragment}" ]; then
    echo "error: kernel config fragment not found: ${config_fragment}" >&2
    exit 66
  fi

  case " ${make_flags} " in
    *" LLVM=1 "*|*" LLVM=1"*)
      for command_name in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf; do
        require_command "${command_name}"
      done
      ;;
  esac
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "error: shasum or sha256sum is required to verify Linux source." >&2
    exit 69
  fi
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1"
}

download() {
  local url="$1"
  local path="$2"
  if [ -f "${path}" ]; then
    return
  fi
  curl -fL "${url}" -o "${path}"
}

expected_kernel_sha256() {
  if [ -n "${KERNEL_SHA256:-}" ]; then
    printf '%s\n' "${KERNEL_SHA256}"
    return
  fi

  download "${kernel_sha256_url}" "${checksum_file}"
  awk -v name="linux-${kernel_version}.tar.xz" '
    {
      candidate = $2
      sub(/^\*/, "", candidate)
      sub(/^\.\//, "", candidate)
      if (candidate == name) {
        print $1
        exit
      }
    }
  ' "${checksum_file}"
}

verify_tarball() {
  local expected actual
  expected="$(expected_kernel_sha256)"
  actual="$(sha256 "${tarball}")"
  if [ -z "${expected}" ] || [ "${expected}" != "${actual}" ]; then
    cat >&2 <<ERROR
error: Linux source checksum mismatch.
  expected: ${expected:-<empty>}
  actual:   ${actual}
ERROR
    exit 65
  fi
}

required_config_builtins() {
  awk -F= '/^CONFIG_[A-Za-z0-9_]+=y$/ { print $1 }' "${config_fragment}"
}

validate_required_config_builtins() {
  local missing=0
  local option
  while IFS= read -r option; do
    if ! grep -q "^${option}=y$" "${source_dir}/.config"; then
      local actual
      actual="$(grep -E "^(# )?${option}(=| is not set)" "${source_dir}/.config" || true)"
      echo "error: kernel .config did not keep required built-in ${option} (actual: ${actual:-missing})" >&2
      missing=1
    fi
  done < <(required_config_builtins)
  if [ "${missing}" -ne 0 ]; then
    exit 65
  fi
}

required_config_builtins_json() {
  local first=true
  local option
  printf '[\n'
  while IFS= read -r option; do
    if [ "${first}" = true ]; then
      first=false
    else
      printf ',\n'
    fi
    printf '    "%s"' "${option}"
  done < <(required_config_builtins)
  printf '\n  ]'
}

configure_kernel() {
  case "${kernel_base_config}" in
    allnoconfig|minimal)
      "${make_cmd}" -C "${source_dir}" \
        ARCH=arm64 \
        ${make_flags} \
        KCONFIG_ALLCONFIG="${config_fragment}" \
        allnoconfig
      ;;
    defconfig)
      "${make_cmd}" -C "${source_dir}" ARCH=arm64 ${make_flags} defconfig
      "${source_dir}/scripts/kconfig/merge_config.sh" \
        -m \
        -O "${source_dir}" \
        "${source_dir}/.config" \
        "${config_fragment}"
      ;;
    *)
      echo "error: unsupported KERNEL_BASE_CONFIG: ${kernel_base_config}" >&2
      echo "supported values: allnoconfig, minimal, defconfig" >&2
      exit 64
      ;;
  esac
  "${make_cmd}" -C "${source_dir}" ARCH=arm64 ${make_flags} olddefconfig
}

check_tools

if [ "${check_only}" = true ]; then
  printf 'Conjet kernel build prerequisites OK for %s profile=%s\n' "${kernel_version}" "${kernel_profile}"
  exit 0
fi

mkdir -p "${work_dir}" "${out_dir}"

download "${kernel_url}" "${tarball}"
verify_tarball

if [ ! -d "${source_dir}" ]; then
  tar -C "${work_dir}" -xf "${tarball}"
fi

configure_kernel
validate_required_config_builtins

if [ "${validate_config_only}" = true ]; then
  printf 'Conjet kernel config OK for %s profile=%s: %s/.config\n' "${kernel_version}" "${kernel_profile}" "${source_dir}"
  exit 0
fi

"${make_cmd}" -C "${source_dir}" ARCH=arm64 ${make_flags} Image vmlinux

if [ ! -f "${source_dir}/System.map" ]; then
  echo "error: kernel builder did not emit System.map after building vmlinux" >&2
  exit 65
fi

cp "${source_dir}/arch/arm64/boot/Image" "${out_dir}/Image"
cp "${source_dir}/.config" "${out_dir}/.config"
cp "${source_dir}/System.map" "${out_dir}/System.map"
cp "${source_dir}/vmlinux" "${out_dir}/vmlinux"

source_sha256="$(sha256 "${tarball}")"
image_sha256="$(sha256 "${out_dir}/Image")"
config_sha256="$(sha256 "${out_dir}/.config")"
system_map_sha256="$(sha256 "${out_dir}/System.map")"
vmlinux_sha256="$(sha256 "${out_dir}/vmlinux")"
required_builtins_json="$(required_config_builtins_json)"

cat > "${out_dir}/manifest.json" <<MANIFEST
{
  "schemaVersion": 1,
  "name": "conjet-linux",
  "version": "${kernel_version}",
  "architecture": "arm64",
  "profile": "$(json_escape "${kernel_profile}")",
  "baseConfig": "$(json_escape "${kernel_base_config}")",
  "image": "$(json_escape "${out_dir}/Image")",
  "imageSha256": "${image_sha256}",
  "config": "$(json_escape "${out_dir}/.config")",
  "configSha256": "${config_sha256}",
  "systemMapSha256": "${system_map_sha256}",
  "vmlinuxSha256": "${vmlinux_sha256}",
  "source": "$(json_escape "${kernel_url}")",
  "sourceSha256": "${source_sha256}",
  "requiredBuiltIns": ${required_builtins_json}
}
MANIFEST

printf '%s\n' "${out_dir}/Image"

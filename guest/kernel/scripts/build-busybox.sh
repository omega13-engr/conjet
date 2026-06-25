#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build the static ARM64 BusyBox binary used by the Conjet Phase 9 network-proof initramfs.

Usage:
  guest/kernel/scripts/build-busybox.sh [--check-tools]

Options:
  --check-tools       Validate host/toolchain prerequisites without downloading or building.
  -h, --help          Show this help.

Environment overrides:
  BUSYBOX_VERSION      BusyBox release to build. Default: 1.38.0
  BUSYBOX_URL          Source tarball URL. Default: official busybox.net tarball
  OUT_DIR              Output directory. Default: guest/kernel/dist/busybox-<version>-conjet-arm64
  WORK_DIR             Scratch/source directory. Default: guest/kernel/.build
  CROSS_COMPILE        Cross compiler prefix. Default: native gcc on ARM64 Linux,
                       otherwise first available aarch64-linux-musl- or aarch64-linux-gnu-
  MAKE_FLAGS           Extra make flags. Default: -j<host-cpu-count>

Output:
  <OUT_DIR>/busybox
  <OUT_DIR>/.config
  <OUT_DIR>/busybox.file.txt
  <OUT_DIR>/manifest.json
USAGE
}

check_only=false

case "${1:-}" in
  "")
    ;;
  "--check-tools")
    check_only=true
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

busybox_version="${BUSYBOX_VERSION:-1.38.0}"
busybox_url="${BUSYBOX_URL:-https://busybox.net/downloads/busybox-${busybox_version}.tar.bz2}"
out_dir="${OUT_DIR:-${kernel_root}/dist/busybox-${busybox_version}-conjet-arm64}"
work_dir="${WORK_DIR:-${kernel_root}/.build}"
source_dir="${work_dir}/busybox-${busybox_version}"
tarball="${work_dir}/busybox-${busybox_version}.tar.bz2"
checksum_file="${tarball}.sha256"
make_jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
if [ "${MAKE_FLAGS+x}" = x ]; then
  make_flags="${MAKE_FLAGS}"
else
  make_flags="-j${make_jobs}"
fi

choose_cross_compile() {
  if [ -n "${CROSS_COMPILE:-}" ]; then
    if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
      cat >&2 <<ERROR
error: CROSS_COMPILE is set but ${CROSS_COMPILE}gcc was not found.

Set CROSS_COMPILE to a prefix that resolves to an ARM64 Linux compiler, for
example /opt/toolchains/aarch64-linux-musl/bin/aarch64-linux-musl-.
ERROR
      exit 69
    fi
    printf '%s\n' "${CROSS_COMPILE}"
    return
  fi

  for prefix in aarch64-linux-musl- aarch64-linux-gnu-; do
    if command -v "${prefix}gcc" >/dev/null 2>&1; then
      printf '%s\n' "${prefix}"
      return
    fi
  done

  case "$(uname -s):$(uname -m)" in
    Linux:aarch64|Linux:arm64)
      if command -v gcc >/dev/null 2>&1; then
        printf '\n'
        return
      fi
      ;;
  esac

  cat >&2 <<'ERROR'
error: no ARM64 Linux cross compiler found.

Install gcc on a native ARM64 Linux builder, install a toolchain that provides
aarch64-linux-musl-gcc or aarch64-linux-gnu-gcc, or set
CROSS_COMPILE=/path-or-prefix/to/aarch64-linux-gnu-.
ERROR
  exit 69
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    cat >&2 <<'ERROR'
error: shasum or sha256sum is required to verify BusyBox source.
ERROR
    exit 69
  fi
}

download() {
  local url="$1"
  local path="$2"
  if [ -f "${path}" ]; then
    return
  fi
  curl -fL "${url}" -o "${path}"
}

verify_tarball() {
  local expected actual
  download "${busybox_url}.sha256" "${checksum_file}"
  expected="$(awk 'NR == 1 {print $1}' "${checksum_file}")"
  actual="$(sha256 "${tarball}")"
  if [ -z "${expected}" ] || [ "${expected}" != "${actual}" ]; then
    cat >&2 <<ERROR
error: BusyBox source checksum mismatch.
  expected: ${expected:-<empty>}
  actual:   ${actual}
ERROR
    exit 65
  fi
}

config_enable() {
  printf 'CONFIG_%s=y\n' "$1" >> "${minimal_config}"
}

require_config() {
  local name="$1"
  if ! grep -q "^CONFIG_${name}=y$" "${source_dir}/.config"; then
    echo "error: BusyBox config did not enable CONFIG_${name}" >&2
    exit 65
  fi
}

set_config_enabled() {
  local name="$1"
  local key="CONFIG_${name}"
  local config="${source_dir}/.config"
  if grep -q "^${key}=" "${config}"; then
    sed -i "s/^${key}=.*/${key}=y/" "${config}"
  elif grep -q "^# ${key} is not set$" "${config}"; then
    sed -i "s/^# ${key} is not set$/${key}=y/" "${config}"
  else
    printf '%s=y\n' "${key}" >> "${config}"
  fi
}

apply_minimal_config() {
  local applet
  for applet in \
    BUSYBOX STATIC ASH SH_IS_ASH ASH_ECHO ASH_PRINTF ASH_TEST TEST ECHO CAT \
    MOUNT MKDIR SLEEP IFCONFIG ROUTE IP FEATURE_IP_ADDRESS FEATURE_IP_LINK \
    FEATURE_IP_ROUTE UDHCPC NSLOOKUP WGET FEATURE_WGET_TIMEOUT HTTPD
  do
    set_config_enabled "${applet}"
  done
}

oldconfig_with_defaults() {
  set +o pipefail
  yes "" 2>/dev/null | make -C "${source_dir}" ARCH=arm64 CROSS_COMPILE="${cross_compile}" oldconfig
  local oldconfig_status="${PIPESTATUS[1]}"
  set -o pipefail
  if [ "${oldconfig_status}" -ne 0 ]; then
    exit "${oldconfig_status}"
  fi
}

write_minimal_config() {
  minimal_config="${source_dir}/conjet-minimal-busybox.config"
  : > "${minimal_config}"
  for applet in \
    BUSYBOX STATIC ASH SH_IS_ASH ASH_ECHO ASH_PRINTF ASH_TEST TEST ECHO CAT \
    MOUNT MKDIR SLEEP IFCONFIG ROUTE IP FEATURE_IP_ADDRESS FEATURE_IP_LINK \
    FEATURE_IP_ROUTE UDHCPC NSLOOKUP WGET FEATURE_WGET_TIMEOUT HTTPD
  do
    config_enable "${applet}"
  done
}

cross_compile="$(choose_cross_compile)"
cross_compile_display="${cross_compile:-<native-arm64-gcc>}"

if [ "${check_only}" = true ]; then
  for command_name in bzip2 curl tar make yes; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "error: required command not found: ${command_name}" >&2
      exit 69
    fi
  done
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "error: shasum or sha256sum is required to verify BusyBox source." >&2
    exit 69
  fi
  if ! command -v file >/dev/null 2>&1; then
    echo "error: file(1) is required to verify the BusyBox binary." >&2
    exit 69
  fi
  printf 'Conjet BusyBox build prerequisites OK for %s with CROSS_COMPILE=%s\n' \
    "${busybox_version}" \
    "${cross_compile_display}"
  exit 0
fi

mkdir -p "${work_dir}" "${out_dir}"
download "${busybox_url}" "${tarball}"
verify_tarball

if [ ! -d "${source_dir}" ]; then
  tar -C "${work_dir}" -xf "${tarball}"
fi

make -C "${source_dir}" distclean
write_minimal_config
make -C "${source_dir}" \
  ARCH=arm64 \
  CROSS_COMPILE="${cross_compile}" \
  KCONFIG_ALLCONFIG="${minimal_config}" \
  allnoconfig
apply_minimal_config
oldconfig_with_defaults

for applet in \
  BUSYBOX STATIC ASH SH_IS_ASH ASH_ECHO ASH_PRINTF ASH_TEST TEST ECHO CAT \
  MOUNT MKDIR SLEEP IFCONFIG ROUTE IP FEATURE_IP_ADDRESS FEATURE_IP_LINK \
  FEATURE_IP_ROUTE UDHCPC NSLOOKUP WGET HTTPD
do
  require_config "${applet}"
done

make -C "${source_dir}" ARCH=arm64 CROSS_COMPILE="${cross_compile}" ${make_flags} busybox

cp "${source_dir}/busybox" "${out_dir}/busybox"
chmod 0755 "${out_dir}/busybox"
cp "${source_dir}/.config" "${out_dir}/.config"

if command -v file >/dev/null 2>&1; then
  file "${out_dir}/busybox" > "${out_dir}/busybox.file.txt"
  if ! grep -q "statically linked" "${out_dir}/busybox.file.txt"; then
    cat >&2 <<ERROR
error: built BusyBox is not statically linked.
$(cat "${out_dir}/busybox.file.txt")
ERROR
    exit 65
  fi
else
  printf 'file(1) not available; static-link verification skipped\n' > "${out_dir}/busybox.file.txt"
fi

busybox_sha256="$(sha256 "${out_dir}/busybox")"
source_sha256="$(sha256 "${tarball}")"

cat > "${out_dir}/manifest.json" <<MANIFEST
{
  "schemaVersion": 1,
  "name": "conjet-busybox-network-proof",
  "version": "${busybox_version}",
  "architecture": "arm64",
  "busybox": "${out_dir}/busybox",
  "busyboxSha256": "${busybox_sha256}",
  "config": "${out_dir}/.config",
  "source": "${busybox_url}",
  "sourceSha256": "${source_sha256}",
  "crossCompile": "${cross_compile_display}"
}
MANIFEST

printf '%s\n' "${out_dir}/busybox"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build the static ARM64 Linux conjet-init PID 1 used by the Pulse initramfs.

Usage:
  guest/init/build-conjet-init.sh [--check-tools]

Environment overrides:
  CC             ARM64 Linux C compiler. Default: first available
                 aarch64-linux-musl-gcc, aarch64-linux-gnu-gcc, or native gcc
                 on ARM64 Linux.
  OUT_DIR        Output directory. Default: guest/init/dist/conjet-init-arm64
  SOURCE         Source file. Default: guest/init/conjet-init.c
  CFLAGS         Extra C flags appended to the hardened defaults.
  LDFLAGS        Extra linker flags appended to -static.
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

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
init_root="${repo_root}/guest/init"
source_path="${SOURCE:-${init_root}/conjet-init.c}"
out_dir="${OUT_DIR:-${init_root}/dist/conjet-init-arm64}"
output_path="${out_dir}/conjet-init"

choose_cc() {
  if [ -n "${CC:-}" ]; then
    command -v "${CC}" >/dev/null 2>&1 || {
      echo "error: CC is set but not found: ${CC}" >&2
      exit 69
    }
    printf '%s\n' "${CC}"
    return
  fi

  for candidate in aarch64-linux-musl-gcc aarch64-linux-gnu-gcc; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  case "$(uname -s):$(uname -m)" in
    Linux:aarch64|Linux:arm64)
      if command -v gcc >/dev/null 2>&1; then
        printf '%s\n' gcc
        return
      fi
      ;;
  esac

  cat >&2 <<'ERROR'
error: no ARM64 Linux C compiler found.

Install aarch64-linux-musl-gcc, aarch64-linux-gnu-gcc, use a native ARM64 Linux
builder with gcc, or set CC to a compatible compiler.
ERROR
  exit 69
}

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

cc="$(choose_cc)"
base_cflags=(
  -std=c11
  -Os
  -pipe
  -Wall
  -Wextra
  -Werror
  -fno-plt
  -fstack-protector-strong
  -D_FORTIFY_SOURCE=3
)
base_ldflags=(-static)

if [ "${check_only}" = true ]; then
  require_command "${cc}"
  require_command file
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "error: shasum or sha256sum is required." >&2
    exit 69
  fi
  test -f "${source_path}" || {
    echo "error: source not found: ${source_path}" >&2
    exit 66
  }
  printf 'Conjet init build prerequisites OK with CC=%s\n' "${cc}"
  exit 0
fi

require_command "${cc}"
require_command file
test -f "${source_path}" || {
  echo "error: source not found: ${source_path}" >&2
  exit 66
}

mkdir -p "${out_dir}"
"${cc}" \
  "${base_cflags[@]}" \
  ${CFLAGS:-} \
  "${source_path}" \
  -o "${output_path}" \
  "${base_ldflags[@]}" \
  ${LDFLAGS:-}

file_output="$(file "${output_path}")"
case "${file_output}" in
  *"ELF 64-bit"*"ARM aarch64"*|*"ELF 64-bit"*"ARM64"*)
    ;;
  *)
    echo "error: conjet-init is not an ARM64 Linux ELF: ${file_output}" >&2
    exit 65
    ;;
esac

case "${file_output}" in
  *"statically linked"*)
    ;;
  *)
    echo "error: conjet-init must be statically linked: ${file_output}" >&2
    exit 65
    ;;
esac

cat > "${out_dir}/manifest.json" <<MANIFEST
{
  "schemaVersion": 1,
  "name": "conjet-init",
  "architecture": "arm64",
  "source": "$(json_escape "${source_path}")",
  "sourceSha256": "$(sha256 "${source_path}")",
  "binary": "$(json_escape "${output_path}")",
  "binarySha256": "$(sha256 "${output_path}")",
  "compiler": "$(json_escape "${cc}")",
  "file": "$(json_escape "${file_output}")"
}
MANIFEST

printf '%s\n' "${output_path}"

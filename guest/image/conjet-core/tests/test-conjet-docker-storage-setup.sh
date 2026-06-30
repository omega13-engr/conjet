#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/.." && pwd)"
script="${root_dir}/scripts/conjet-docker-storage-setup.sh"
image_script="${root_dir}/scripts/image.sh"
qa_root="$(mktemp -d "${TMPDIR:-/tmp}/conjet-docker-storage.XXXXXX")"
trap 'rm -rf "${qa_root}"' EXIT

sh -n "${script}"

fake_dev="${qa_root}/fake-data.raw"
touch "${fake_dev}"

export CONJET_DOCKER_STORAGE_SOURCE_ONLY=1
export CONJET_DOCKER_STORAGE_ALLOW_REGULAR_DEVICE=1
export CONJET_DOCKER_STORAGE_DEVICES="${fake_dev}"
. "${script}"

candidate="$(storage_candidate)"
if [ "${candidate}" != "${fake_dev}" ]; then
  echo "expected storage_candidate to select ${fake_dev}, got ${candidate}" >&2
  exit 1
fi

small_fallback="${qa_root}/small-fallback.raw"
large_fallback="${qa_root}/large-fallback.raw"
truncate -s 1048576 "${small_fallback}"
truncate -s 3145728 "${large_fallback}"

unset CONJET_DOCKER_STORAGE_DEVICES
export CONJET_DOCKER_STORAGE_MIN_FALLBACK_BYTES=2097152
export CONJET_DOCKER_STORAGE_RUST_HVF_FALLBACK_DEVICES="${small_fallback} ${large_fallback}"

candidate="$(storage_candidate)"
if [ "${candidate}" != "${large_fallback}" ]; then
  echo "expected storage_candidate to skip small fallback and select ${large_fallback}, got ${candidate}" >&2
  exit 1
fi

attempts_file="${qa_root}/wait-attempts"
printf '0\n' >"${attempts_file}"
storage_candidate() {
  attempts="$(cat "${attempts_file}")"
  attempts=$((attempts + 1))
  printf '%s\n' "${attempts}" >"${attempts_file}"
  if [ "${attempts}" -gt 1 ]; then
    printf '%s\n' "${large_fallback}"
  fi
}

export CONJET_DOCKER_STORAGE_DEVICE_WAIT_SECONDS=1
candidate="$(storage_candidate_with_wait 2>"${qa_root}/wait.log")"
if [ "${candidate}" != "${large_fallback}" ]; then
  echo "expected storage_candidate_with_wait to return only ${large_fallback}, got ${candidate}" >&2
  cat "${qa_root}/wait.log" >&2
  exit 1
fi
if ! grep -q "waiting up to 1s for Docker data disk discovery" "${qa_root}/wait.log"; then
  echo "expected wait log entry on stderr" >&2
  cat "${qa_root}/wait.log" >&2
  exit 1
fi
unset -f storage_candidate

if ! supported_filesystem ext4; then
  echo "expected ext4 to be supported" >&2
  exit 1
fi

if supported_filesystem apfs; then
  echo "expected apfs to be rejected" >&2
  exit 1
fi
unset CONJET_DOCKER_STORAGE_SOURCE_ONLY
unset CONJET_DOCKER_STORAGE_ALLOW_REGULAR_DEVICE
unset CONJET_DOCKER_STORAGE_DEVICE_WAIT_SECONDS
unset CONJET_DOCKER_STORAGE_MIN_FALLBACK_BYTES
unset CONJET_DOCKER_STORAGE_RUST_HVF_FALLBACK_DEVICES

run_dir="${qa_root}/run"
docker_dir="${qa_root}/docker"
temp_mount="${qa_root}/mnt"
mkdir -p "${docker_dir}"
echo rootfs-docker-state >"${docker_dir}/sentinel"

CONJET_RUN_DIR="${run_dir}" \
CONJET_DOCKER_DIR="${docker_dir}" \
CONJET_DOCKER_STORAGE_TEMP_MOUNT="${temp_mount}" \
CONJET_DOCKER_STORAGE_DEVICE_WAIT_SECONDS=0 \
CONJET_DOCKER_STORAGE_SKIP_XATTR_PROBE=1 \
CONJET_DOCKER_STORAGE_DEVICES="${qa_root}/missing-device" \
"${script}"

if ! grep -q "dedicated Docker data disk not present" "${run_dir}/docker-storage-setup.log"; then
  echo "expected missing data disk log entry" >&2
  cat "${run_dir}/docker-storage-setup.log" >&2
  exit 1
fi

if [ "$(cat "${docker_dir}/sentinel")" != "rootfs-docker-state" ]; then
  echo "storage setup changed rootfs Docker state when no data disk was present" >&2
  exit 1
fi

grep -q "conjet-docker-storage-setup.sh" "${image_script}"
grep -q "conjet-docker-storage.service" "${image_script}"
grep -q "security.capability xattrs" "${script}"
grep -q "CONFIG_SECURITY=y" "${script}"
grep -q "CONFIG_EXT4_FS_SECURITY=y" "${script}"

echo "conjet-docker-storage setup tests passed"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Run the Conjet Core Jetstream release workflow commands in a local Linux container.

Usage:
  build-support/run-conjet-core-release-local.sh [options]

Options:
  --version VERSION        Conjet Core semantic version. Default: guest/image/conjet-core/VERSION
  --kernel-version X.Y.Z   Linux kernel version. Default: 6.12.86
  --root-disk-gb GB        Rootfs appliance disk size. Default: 16
  --qa-root PATH           Existing QA root. Default: mktemp under CONJET_QA_ROOT_BASE or /tmp
  --docker-host URI        Docker host. Default: active Docker context endpoint, otherwise /var/run/docker.sock
  -h, --help               Show this help.

The script copies the current working tree to <qa-root>/worktree before running
the container, so generated artifacts stay under the QA root and the active
checkout is left untouched. The Core release lane emits both the custom
Jetstream Linux kernel triplet and the Conjet-owned Docker rootfs appliance
triplet required for direct-kernel boot.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' < "${repo_root}/guest/image/conjet-core/VERSION")"
kernel_version="6.12.86"
root_disk_gb="16"
qa_root=""
docker_host=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      version="${2:?--version requires a value}"
      shift 2
      ;;
    --kernel-version)
      kernel_version="${2:?--kernel-version requires a value}"
      shift 2
      ;;
    --root-disk-gb)
      root_disk_gb="${2:?--root-disk-gb requires a value}"
      shift 2
      ;;
    --qa-root)
      qa_root="${2:?--qa-root requires a value}"
      shift 2
      ;;
    --docker-host)
      docker_host="${2:?--docker-host requires a value}"
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

if ! printf '%s\n' "${version}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "invalid Conjet Core semantic version: ${version}" >&2
  exit 64
fi

if ! printf '%s\n' "${kernel_version}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "--kernel-version must be X.Y.Z" >&2
  exit 64
fi

if ! printf '%s\n' "${root_disk_gb}" | grep -Eq '^[0-9]+$'; then
  echo "--root-disk-gb must be an integer" >&2
  exit 64
fi

if [ -z "${docker_host}" ] && [ -n "${DOCKER_HOST:-}" ]; then
  docker_host="${DOCKER_HOST}"
fi
if [ -z "${docker_host}" ]; then
  docker_host="$(docker context inspect --format '{{ .Endpoints.docker.Host }}' 2>/dev/null || true)"
fi
if [ -z "${docker_host}" ]; then
  docker_host="unix:///var/run/docker.sock"
fi

case "${docker_host}" in
  unix://*) docker_socket="${docker_host#unix://}" ;;
  *)
    echo "only unix:// Docker hosts are supported for local workflow rehearsal" >&2
    exit 64
    ;;
esac

if [ ! -S "${docker_socket}" ]; then
  echo "Docker socket is not available: ${docker_socket}" >&2
  exit 69
fi

if [ -z "${qa_root}" ]; then
  qa_root_base="${CONJET_QA_ROOT_BASE:-/tmp}"
  mkdir -p "${qa_root_base}"
  qa_root="$(mktemp -d "${qa_root_base%/}/conjet-core-release-local.XXXXXX")"
else
  mkdir -p "${qa_root}"
fi

worktree="${qa_root}/worktree"
log_dir="${qa_root}/logs"
artifact_dir="${qa_root}/release-assets"
mkdir -p "${worktree}" "${log_dir}" "${artifact_dir}"

latest_path="${CONJET_CORE_RELEASE_LOCAL_LATEST_PATH:-${qa_root%/*}/conjet-core-release-local-latest}"
mkdir -p "$(dirname "${latest_path}")"
echo "${qa_root}" > "${latest_path}"

rsync -a --delete \
  --delete-excluded \
  --exclude '.git' \
  --exclude '.build' \
  --exclude 'target/***' \
  --exclude 'graphify-out/***' \
  --exclude 'benchmarks/***' \
  --exclude 'dist/***' \
  --exclude 'guest/kernel/.build' \
  --exclude 'guest/kernel/dist' \
  --exclude 'guest/image/conjet-core/dist' \
  "${repo_root}/" "${worktree}/"

container_platform="linux/arm64"

echo "qa_root=${qa_root}"
echo "docker_host=${docker_host}"
echo "workflow_arch=aarch64"
echo "version=${version}"
echo "kernel_version=${kernel_version}"
echo "root_disk_gb=${root_disk_gb}"

docker --host "${docker_host}" info > "${log_dir}/docker-info.log"
daemon_name="$(docker --host "${docker_host}" info --format '{{.Name}}')"
image_builder_cgroup_parent=""
if [ "${daemon_name}" = "conjet-core" ]; then
  # A currently running Core image from before the cgroup-parent correction
  # needs an explicit valid slice while it builds its replacement rootfs.
  image_builder_cgroup_parent="conjet-build.slice"
fi

# Transfer the source snapshot and completed outputs through the Docker API.
# This avoids assuming that arbitrary host paths are bind-mountable by the
# selected daemon. The inner Docker client still receives the daemon's native
# socket for the rootfs appliance build.
container_worktree="/worktree"
container_artifact_dir="/release-assets"
container_log_dir="/release-logs"
container_name="conjet-core-release-local-${$}-${RANDOM}"
container_id=""

cleanup_container() {
  if [ -n "${container_id}" ]; then
    docker --host "${docker_host}" rm -f "${container_id}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_container EXIT

kernel_asset_name="conjet-linux-${kernel_version}-aarch64-Image"
rootfs_asset_name="conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz"
release_artifacts=(
  "${kernel_asset_name}"
  "${kernel_asset_name}.json"
  "${kernel_asset_name}.sha512sum"
  "${rootfs_asset_name}"
  "${rootfs_asset_name}.json"
  "${rootfs_asset_name}.sha512sum"
)

verify_release_checksum() {
  local checksum_name="$1"
  if command -v sha512sum >/dev/null 2>&1; then
    (
      cd "${artifact_dir}"
      sha512sum -c "${checksum_name}"
    )
  else
    (
      cd "${artifact_dir}"
      shasum -a 512 -c "${checksum_name}"
    )
  fi
}

copy_release_artifacts() {
  local attempt artifact
  for attempt in 1 2 3; do
    rm -f "${release_artifacts[@]/#/${artifact_dir}/}"
    if (
      set -e
      for artifact in "${release_artifacts[@]}"; do
        docker --host "${docker_host}" cp \
          "${container_id}:${container_artifact_dir}/${artifact}" \
          "${artifact_dir}/${artifact}"
        test -s "${artifact_dir}/${artifact}"
      done
      verify_release_checksum "${kernel_asset_name}.sha512sum"
      verify_release_checksum "${rootfs_asset_name}.sha512sum"
    ); then
      return 0
    fi

    if [ "${attempt}" -lt 3 ]; then
      echo "release artifact transfer attempt ${attempt} failed; retrying" >&2
    fi
  done

  echo "failed to transfer and verify the complete Core release artifact set" >&2
  return 1
}

container_id="$(docker --host "${docker_host}" create \
  --name "${container_name}" \
  --ulimit nofile=65536:65536 \
  --platform "${container_platform}" \
  --workdir "${container_worktree}" \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --env DOCKER_HOST=unix:///var/run/docker.sock \
  --env CONJET_CORE_VERSION="${version}" \
  --env KERNEL_VERSION="${kernel_version}" \
  --env ROOT_DISK_GB="${root_disk_gb}" \
  --env ARTIFACT_DIR="${container_artifact_dir}" \
  --env LOG_DIR="${container_log_dir}" \
  --env CONJET_IMAGE_BUILDER_CGROUP_PARENT="${image_builder_cgroup_parent}" \
  --env DEBIAN_FRONTEND=noninteractive \
  "ubuntu:24.04" \
  bash -lc '
    set -euo pipefail

    mkdir -p "${ARTIFACT_DIR}" "${LOG_DIR}"

    apt-get update
    apt-get install -y --no-install-recommends \
      bc \
      bison \
      bzip2 \
      ca-certificates \
      clang \
      curl \
      docker.io \
      dwarves \
      flex \
      gcc \
      gzip \
      libelf-dev \
      libssl-dev \
      lld \
      llvm \
      make \
      perl \
      rsync \
      tar \
      xz-utils

    actual="$(tr -d "[:space:]" < guest/image/conjet-core/VERSION)"
    if [ "${actual}" != "${CONJET_CORE_VERSION}" ]; then
      echo "guest/image/conjet-core/VERSION=${actual}, expected ${CONJET_CORE_VERSION}" >&2
      exit 1
    fi

    docker info >"${LOG_DIR}/container-docker-info.log"

    kernel_out="${ARTIFACT_DIR}/kernel-work/conjet-linux-${KERNEL_VERSION}-aarch64"
    jobs="${CONJET_KERNEL_MAX_JOBS:-2}"
    case "${jobs}" in
      ""|*[!0-9]*) jobs=2 ;;
    esac
    host_jobs="$(nproc)"
    if [ "${jobs}" -gt "${host_jobs}" ]; then
      jobs="${host_jobs}"
    fi
    ulimit -n 65536 2>/dev/null || true
    export MAKE_FLAGS="-j${jobs} LLVM=1"
    OUT_DIR="${kernel_out}" KERNEL_VERSION="${KERNEL_VERSION}" guest/kernel/scripts/build-linux.sh

    mkdir -p "${ARTIFACT_DIR}"
    kernel_asset="${ARTIFACT_DIR}/conjet-linux-${KERNEL_VERSION}-aarch64-Image"
    cp "${kernel_out}/Image" "${kernel_asset}"
    cp "${kernel_out}/manifest.json" "${kernel_asset}.json"
    (
      cd "$(dirname "${kernel_asset}")"
      sha512sum "$(basename "${kernel_asset}")" > "$(basename "${kernel_asset}").sha512sum"
    )

    make -C guest/image/conjet-core image \
      OS_ARCH=aarch64 \
      CONJET_CORE_VERSION="${CONJET_CORE_VERSION}" \
      ROOT_DISK_GB="${ROOT_DISK_GB}" \
      RUNTIME=docker
    cp guest/image/conjet-core/dist/out/*.raw.gz \
      guest/image/conjet-core/dist/out/*.raw.gz.sha512sum \
      guest/image/conjet-core/dist/out/*.raw.gz.json \
      "${ARTIFACT_DIR}/"

    find "${ARTIFACT_DIR}" -maxdepth 1 -type f -print | sort
  ')"

if command -v bsdtar >/dev/null 2>&1; then
  (
    cd "${qa_root}"
    bsdtar --no-xattrs -cf - worktree
  ) | docker --host "${docker_host}" cp - "${container_id}:/"
else
  (
    cd "${qa_root}"
    tar --no-xattrs -cf - worktree
  ) | docker --host "${docker_host}" cp - "${container_id}:/"
fi

container_status=0
docker --host "${docker_host}" start -a "${container_id}" \
  | tee "${log_dir}/container-release-rehearsal.log" || container_status=$?

docker --host "${docker_host}" cp "${container_id}:${container_log_dir}/." "${log_dir}" || true

if [ "${container_status}" -ne 0 ]; then
  exit "${container_status}"
fi

copy_release_artifacts

find "${artifact_dir}" -maxdepth 1 -type f -print | sort > "${qa_root}/artifact-list.txt"
echo "artifact_dir=${artifact_dir}"

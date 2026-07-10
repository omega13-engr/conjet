#!/usr/bin/env bash
set -euo pipefail

: "${ARCH:?ARCH must be set to arm64 or amd64}"
: "${OS_ARCH:?OS_ARCH must be set to aarch64 or x86_64}"

UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-noble}"
ROOTFS_MIRROR="${ROOTFS_MIRROR:-}"
ROOT_DISK_GB="${ROOT_DISK_GB:-16}"
RUNTIME="${RUNTIME:-docker}"
DOCKER_PACKAGE="${DOCKER_PACKAGE:-docker.io}"
CONJET_CORE_VERSION="${CONJET_CORE_VERSION:-1.0.0}"
BUILDER_CGROUP_PARENT="${CONJET_IMAGE_BUILDER_CGROUP_PARENT:-}"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required to build the Conjet core image" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Docker bind-mount paths are resolved by the daemon, which is not necessarily
# this client's filesystem. Transfer the compact image-builder source through
# the Docker API instead, then copy the completed appliance artifacts back.
builder_name="conjet-core-image-${$}-${RANDOM}"
builder_id=""
builder_cgroup_args=()
if [ -n "${BUILDER_CGROUP_PARENT}" ]; then
    builder_cgroup_args+=(--cgroup-parent "${BUILDER_CGROUP_PARENT}")
fi

cleanup_builder() {
    if [ -n "${builder_id}" ]; then
        docker rm -f "${builder_id}" >/dev/null 2>&1 || true
    fi
}
trap cleanup_builder EXIT

builder_id="$(docker create \
    --name "${builder_name}" \
    --privileged \
    --platform "linux/${ARCH}" \
    --workdir /build \
    "${builder_cgroup_args[@]}" \
    --env "ARCH=${ARCH}" \
    --env "OS_ARCH=${OS_ARCH}" \
    --env "UBUNTU_VERSION=${UBUNTU_VERSION}" \
    --env "UBUNTU_CODENAME=${UBUNTU_CODENAME}" \
    --env "ROOTFS_MIRROR=${ROOTFS_MIRROR}" \
    --env "ROOT_DISK_GB=${ROOT_DISK_GB}" \
    --env "RUNTIME=${RUNTIME}" \
    --env "DOCKER_PACKAGE=${DOCKER_PACKAGE}" \
    --env "CONJET_CORE_VERSION=${CONJET_CORE_VERSION}" \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    "ubuntu:${UBUNTU_VERSION}" \
    bash -lc '
        set -eu
        mkdir -p /build
        while [ ! -f /build/.conjet-source-ready ]; do
            sleep 0.1
        done
        rm -f /build/.conjet-source-ready
        exec /build/scripts/image.sh
    ')"

docker start "${builder_id}" >/dev/null
for _ in $(seq 1 50); do
    if docker exec "${builder_id}" test -d /build >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if ! docker exec "${builder_id}" test -d /build >/dev/null 2>&1; then
    echo "image builder did not create /build" >&2
    exit 1
fi

if command -v bsdtar >/dev/null 2>&1; then
    (
        cd "${ROOT_DIR}"
        bsdtar --no-xattrs --exclude dist -cf - .
    ) | docker cp - "${builder_id}:/build"
else
    (
        cd "${ROOT_DIR}"
        tar --no-xattrs --exclude=dist -cf - .
    ) | docker cp - "${builder_id}:/build"
fi

docker exec "${builder_id}" touch /build/.conjet-source-ready
builder_status="$(docker wait "${builder_id}")"
docker logs "${builder_id}"
if [ "${builder_status}" != "0" ]; then
    exit "${builder_status}"
fi

rm -rf "${ROOT_DIR}/dist"
mkdir -p "${ROOT_DIR}/dist"
docker cp "${builder_id}:/build/dist/." "${ROOT_DIR}/dist"

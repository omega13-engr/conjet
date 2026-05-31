#!/usr/bin/env bash
set -euo pipefail

: "${ARCH:?ARCH must be set to arm64 or amd64}"
: "${OS_ARCH:?OS_ARCH must be set to aarch64 or x86_64}"

UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
ROOT_DISK_GB="${ROOT_DISK_GB:-16}"
RUNTIME="${RUNTIME:-docker}"
DOCKER_PACKAGE="${DOCKER_PACKAGE:-docker.io}"
CONJET_CORE_VERSION="${CONJET_CORE_VERSION:-0.1.0}"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required to build the Conjet core image" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

docker run --rm --privileged \
    --platform "linux/${ARCH}" \
    --workdir /build \
    --volume "${ROOT_DIR}:/build" \
    --env "ARCH=${ARCH}" \
    --env "OS_ARCH=${OS_ARCH}" \
    --env "UBUNTU_VERSION=${UBUNTU_VERSION}" \
    --env "ROOT_DISK_GB=${ROOT_DISK_GB}" \
    --env "RUNTIME=${RUNTIME}" \
    --env "DOCKER_PACKAGE=${DOCKER_PACKAGE}" \
    --env "CONJET_CORE_VERSION=${CONJET_CORE_VERSION}" \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    "ubuntu:${UBUNTU_VERSION}" \
    /build/scripts/image.sh

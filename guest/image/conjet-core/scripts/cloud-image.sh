#!/usr/bin/env bash
set -euo pipefail

: "${ARCH:?ARCH must be set to arm64 or amd64}"

UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-noble}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist/img"
BASE_URL="https://cloud-images.ubuntu.com/minimal/releases/${UBUNTU_CODENAME}/release"
IMAGE_NAME="ubuntu-${UBUNTU_VERSION}-minimal-cloudimg-${ARCH}.img"
SUMS_NAME="SHA256SUMS"

mkdir -p "${DIST_DIR}"

download() {
    local url="$1"
    local output="$2"
    local tmp="${output}.download"

    if [ -f "${output}" ]; then
        return
    fi

    rm -f "${tmp}"
    curl -fL --retry 3 --connect-timeout 20 -o "${tmp}" "${url}"
    mv "${tmp}" "${output}"
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{ print $1 }'
    else
        shasum -a 256 "${file}" | awk '{ print $1 }'
    fi
}

image_path="${DIST_DIR}/${IMAGE_NAME}"
sums_path="${DIST_DIR}/${SUMS_NAME}"

download "${BASE_URL}/${SUMS_NAME}" "${sums_path}"
download "${BASE_URL}/${IMAGE_NAME}" "${image_path}"

expected="$(
    awk -v file="${IMAGE_NAME}" '
        {
            name = $2
            sub(/^\*/, "", name)
            if (name == file) {
                print $1
                exit
            }
        }
    ' "${sums_path}"
)"

if [ -z "${expected}" ]; then
    echo "could not find ${IMAGE_NAME} in ${sums_path}" >&2
    exit 1
fi

actual="$(sha256_file "${image_path}")"
if [ "${actual}" != "${expected}" ]; then
    rm -f "${image_path}"
    echo "checksum mismatch for ${IMAGE_NAME}: expected ${expected}, got ${actual}" >&2
    exit 1
fi

printf '%s\n' "${image_path}"

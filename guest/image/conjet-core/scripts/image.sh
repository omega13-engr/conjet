#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "image.sh must run as root inside the privileged build container" >&2
    exit 1
fi

: "${ARCH:?ARCH must be set to arm64 or amd64}"
: "${OS_ARCH:?OS_ARCH must be set to aarch64 or x86_64}"

UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
ROOT_DISK_GB="${ROOT_DISK_GB:-16}"
RUNTIME="${RUNTIME:-docker}"
DOCKER_PACKAGE="${DOCKER_PACKAGE:-docker.io}"

case "${RUNTIME}" in
    docker|none)
        ;;
    *)
        echo "unsupported RUNTIME=${RUNTIME}; expected docker or none" >&2
        exit 1
        ;;
esac

BUILD_DIR="/build"
IMG_DIR="${BUILD_DIR}/dist/img"
WORK_DIR="${BUILD_DIR}/dist/work"
OUT_DIR="${BUILD_DIR}/dist/out"
MOUNT_DIR="/mnt/conjet-core-root"
CLOUD_IMAGE="${IMG_DIR}/ubuntu-${UBUNTU_VERSION}-minimal-cloudimg-${ARCH}.img"
ARTIFACT_BASE="conjet-ubuntu-${UBUNTU_VERSION}-minimal-cloudimg-${OS_ARCH}-${RUNTIME}"
RAW_IMAGE="${WORK_DIR}/${ARTIFACT_BASE}.raw"
OUT_IMAGE="${OUT_DIR}/${ARTIFACT_BASE}.raw.gz"

ROOT_PARTITION_LOOP=""

log() {
    printf 'conjet-core: %s\n' "$*" >&2
}

export DEBIAN_FRONTEND=noninteractive

log "installing host image build tools"
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    cloud-guest-utils \
    curl \
    e2fsprogs \
    file \
    gzip \
    mount \
    parted \
    qemu-utils \
    util-linux

mkdir -p "${WORK_DIR}" "${OUT_DIR}" "${MOUNT_DIR}"

if [ ! -f "${CLOUD_IMAGE}" ]; then
    echo "missing cloud image: ${CLOUD_IMAGE}; run make cloud-image first" >&2
    exit 1
fi

partition_geometry() {
    local image="$1"
    local partition="$2"
    parted -m "${image}" unit B print | awk -F: -v partition="${partition}" '
        $1 == partition {
            start = $2
            end = $3
            gsub(/B/, "", start)
            gsub(/B/, "", end)
            print start, end - start + 1
            exit
        }
    '
}

attach_partition_loop() {
    local image="$1"
    local partition="$2"
    local geometry
    local start
    local size

    geometry="$(partition_geometry "${image}" "${partition}")"
    if [ -z "${geometry}" ]; then
        echo "could not find partition ${partition} in ${image}" >&2
        parted -m "${image}" unit B print >&2 || true
        return 1
    fi

    read -r start size <<<"${geometry}"
    log "attaching partition ${partition} at byte offset ${start}, size ${size}"
    losetup --find --show --offset "${start}" --sizelimit "${size}" "${image}"
}

unmount_if_mounted() {
    local target="$1"
    if mountpoint -q "${target}" 2>/dev/null; then
        umount "${target}" || true
    fi
}

cleanup() {
    set +e
    unmount_if_mounted "${MOUNT_DIR}/dev/pts"
    unmount_if_mounted "${MOUNT_DIR}/dev"
    unmount_if_mounted "${MOUNT_DIR}/proc"
    unmount_if_mounted "${MOUNT_DIR}/sys"
    unmount_if_mounted "${MOUNT_DIR}"
    if [ -n "${ROOT_PARTITION_LOOP}" ]; then
        losetup -d "${ROOT_PARTITION_LOOP}" 2>/dev/null || true
        ROOT_PARTITION_LOOP=""
    fi
}

trap cleanup EXIT

rm -f "${RAW_IMAGE}" "${OUT_IMAGE}" "${OUT_IMAGE}.sha512sum" "${OUT_IMAGE}.json"
log "converting ${CLOUD_IMAGE} to raw"
qemu-img convert -O raw "${CLOUD_IMAGE}" "${RAW_IMAGE}"
log "expanding raw disk to ${ROOT_DISK_GB} GiB"
truncate -s "${ROOT_DISK_GB}G" "${RAW_IMAGE}"

log "growing root partition in raw disk"
growpart "${RAW_IMAGE}" 1
ROOT_PARTITION_LOOP="$(attach_partition_loop "${RAW_IMAGE}" 1)"
log "checking and expanding root filesystem"
e2fsck -fy "${ROOT_PARTITION_LOOP}" || true
resize2fs "${ROOT_PARTITION_LOOP}"

log "mounting root filesystem"
mount "${ROOT_PARTITION_LOOP}" "${MOUNT_DIR}"
mount -t proc proc "${MOUNT_DIR}/proc"
mount -t sysfs sysfs "${MOUNT_DIR}/sys"
mount --bind /dev "${MOUNT_DIR}/dev"
mount --bind /dev/pts "${MOUNT_DIR}/dev/pts"

rm -f "${MOUNT_DIR}/etc/resolv.conf"
cp /etc/resolv.conf "${MOUNT_DIR}/etc/resolv.conf"

cat >"${MOUNT_DIR}/usr/sbin/policy-rc.d" <<'SH'
#!/bin/sh
exit 101
SH
chmod 0755 "${MOUNT_DIR}/usr/sbin/policy-rc.d"

if [ "${RUNTIME}" = "docker" ]; then
    RUNTIME_PACKAGES="${DOCKER_PACKAGE}"
else
    RUNTIME_PACKAGES=""
fi

chroot "${MOUNT_DIR}" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    RUNTIME_PACKAGES="${RUNTIME_PACKAGES}" \
    /bin/bash -s <<'CHROOT'
set -euxo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    cloud-init \
    curl \
    gnupg \
    iproute2 \
    iptables \
    netcat-openbsd \
    netplan.io \
    openssh-server \
    python3 \
    socat \
    vim-tiny \
    ${RUNTIME_PACKAGES}
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

rm -f "${MOUNT_DIR}/usr/sbin/policy-rc.d"

mkdir -p "${MOUNT_DIR}/usr/local/sbin" "${MOUNT_DIR}/etc/systemd/system" \
    "${MOUNT_DIR}/etc/modules-load.d" "${MOUNT_DIR}/etc/netplan" "${MOUNT_DIR}/etc/cloud" \
    "${MOUNT_DIR}/etc/conjet"
install -m 0755 "${BUILD_DIR}/scripts/conjet-docker-vsock-bridge.py" \
    "${MOUNT_DIR}/usr/local/sbin/conjet-docker-vsock-bridge.py"
install -m 0755 "${BUILD_DIR}/scripts/conjet-data-disk.sh" \
    "${MOUNT_DIR}/usr/local/sbin/conjet-data-disk.sh"
install -m 0755 "${BUILD_DIR}/scripts/conjet-boot-diagnostics.sh" \
    "${MOUNT_DIR}/usr/local/sbin/conjet-boot-diagnostics.sh"

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-data-disk.service" <<'UNIT'
[Unit]
Description=Conjet Docker data disk
DefaultDependencies=no
After=systemd-udev-settle.service
Before=local-fs.target containerd.service docker.socket docker.service
Wants=systemd-udev-settle.service
ConditionPathExists=/dev/disk/by-id/virtio-conjet-data

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conjet-data-disk.sh
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-docker-vsock.service" <<'UNIT'
[Unit]
Description=Conjet Docker VSOCK bridge
After=conjet-data-disk.service containerd.service docker.service docker.socket
Wants=conjet-data-disk.service containerd.service docker.service docker.socket

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1
ExecStartPre=/bin/sh -c 'modprobe vmw_vsock_virtio_transport 2>/dev/null || modprobe virtio_vsock 2>/dev/null || true'
ExecStartPre=/bin/sh -c 'mkdir -p /run/conjet; rm -f /run/conjet/docker-vsock-ready'
ExecStart=/bin/sh -c 'mkdir -p /run/conjet; exec /usr/local/sbin/conjet-docker-vsock-bridge.py 2>&1 | /usr/bin/tee -a /run/conjet/docker-vsock.log /dev/hvc0'
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-boot-diagnostics.service" <<'UNIT'
[Unit]
Description=Conjet boot diagnostics
After=systemd-modules-load.service containerd.service docker.socket docker.service conjet-docker-vsock.service
Wants=containerd.service docker.socket docker.service conjet-docker-vsock.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conjet-boot-diagnostics.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "${MOUNT_DIR}/Users" "${MOUNT_DIR}/Volumes"

cat >"${MOUNT_DIR}/etc/systemd/system/Users.mount" <<'UNIT'
[Unit]
Description=Conjet host /Users VirtioFS share
DefaultDependencies=no
After=systemd-modules-load.service
Before=local-fs.target

[Mount]
What=conjethostusers
Where=/Users
Type=virtiofs
Options=rw

[Install]
WantedBy=local-fs.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/Volumes.mount" <<'UNIT'
[Unit]
Description=Conjet host /Volumes VirtioFS share
DefaultDependencies=no
After=systemd-modules-load.service
Before=local-fs.target

[Mount]
What=conjethostvolumes
Where=/Volumes
Type=virtiofs
Options=rw

[Install]
WantedBy=local-fs.target
UNIT

cat >"${MOUNT_DIR}/etc/modules-load.d/conjet-vsock.conf" <<'EOF_MODULES'
virtiofs
vmw_vsock_virtio_transport
EOF_MODULES

cat >"${MOUNT_DIR}/etc/netplan/50-conjet.yaml" <<'EOF_NETPLAN'
network:
  version: 2
  ethernets:
    conjet-nat:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
EOF_NETPLAN
chmod 0600 "${MOUNT_DIR}/etc/netplan/50-conjet.yaml"

rm -f "${MOUNT_DIR}/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "${MOUNT_DIR}/etc/resolv.conf"

touch "${MOUNT_DIR}/etc/cloud/cloud-init.disabled"

cat >"${MOUNT_DIR}/etc/conjet/release" <<EOF_RELEASE
name=conjet-core
ubuntu_version=${UBUNTU_VERSION}
arch=${OS_ARCH}
runtime=${RUNTIME}
docker_package=${DOCKER_PACKAGE}
EOF_RELEASE

if [ -x "${MOUNT_DIR}/usr/bin/unpigz" ]; then
    mv "${MOUNT_DIR}/usr/bin/unpigz" "${MOUNT_DIR}/usr/bin/unpigz.conjet-original" || true
    cat >"${MOUNT_DIR}/usr/bin/unpigz" <<'SH'
#!/bin/sh
exec /bin/gzip -d "$@"
SH
    chmod 0755 "${MOUNT_DIR}/usr/bin/unpigz"
fi

unit_source_path() {
    local unit="$1"
    local unit_path

    for unit_path in \
        "/etc/systemd/system/${unit}" \
        "/lib/systemd/system/${unit}" \
        "/usr/lib/systemd/system/${unit}"; do
        if [ -f "${MOUNT_DIR}${unit_path}" ]; then
            printf '%s\n' "${unit_path}"
            return 0
        fi
    done

    return 1
}

enable_unit() {
    local unit="$1"
    local target="$2"
    local source_path

    source_path="$(unit_source_path "${unit}")" || {
        echo "could not find systemd unit ${unit} in guest image" >&2
        return 1
    }

    mkdir -p "${MOUNT_DIR}/etc/systemd/system/${target}.wants"
    ln -sf "${source_path}" "${MOUNT_DIR}/etc/systemd/system/${target}.wants/${unit}"
}

if [ "${RUNTIME}" = "docker" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --root="${MOUNT_DIR}" enable \
            systemd-resolved.service \
            containerd.service \
            docker.service \
            docker.socket \
            conjet-docker-vsock.service \
            conjet-boot-diagnostics.service || \
            log "systemctl --root enable failed; applying explicit systemd symlinks"
    fi

    enable_unit systemd-resolved.service multi-user.target
    enable_unit conjet-data-disk.service local-fs.target
    enable_unit containerd.service multi-user.target
    enable_unit docker.service multi-user.target
    enable_unit docker.socket sockets.target
    enable_unit conjet-docker-vsock.service multi-user.target
    enable_unit conjet-boot-diagnostics.service multi-user.target
    enable_unit Users.mount local-fs.target
    enable_unit Volumes.mount local-fs.target
fi

chroot "${MOUNT_DIR}" /bin/bash -c 'netplan generate || true'
chroot "${MOUNT_DIR}" /bin/bash -c 'truncate -s 0 /etc/machine-id || true; rm -f /var/lib/dbus/machine-id; ln -sf /etc/machine-id /var/lib/dbus/machine-id'
chroot "${MOUNT_DIR}" /bin/bash -c 'rm -rf /tmp/* /var/tmp/* /var/log/*.log /var/log/journal/* 2>/dev/null || true'

dd if=/dev/zero of="${MOUNT_DIR}/EMPTY" bs=1M status=none || true
rm -f "${MOUNT_DIR}/EMPTY"
sync

cleanup
trap - EXIT
set -euo pipefail

gzip -9 -c "${RAW_IMAGE}" >"${OUT_IMAGE}"
sha512sum "${OUT_IMAGE}" >"${OUT_IMAGE}.sha512sum"

cat >"${OUT_IMAGE}.json" <<EOF_JSON
{
  "name": "conjet-core",
  "ubuntuVersion": "${UBUNTU_VERSION}",
  "architecture": "${OS_ARCH}",
  "runtime": "${RUNTIME}",
  "rootDiskGiB": ${ROOT_DISK_GB},
  "format": "raw.gz",
  "artifact": "$(basename "${OUT_IMAGE}")"
}
EOF_JSON

rm -f "${RAW_IMAGE}"

if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${OUT_DIR}" "${WORK_DIR}" || true
fi

printf '%s\n' "${OUT_IMAGE}"

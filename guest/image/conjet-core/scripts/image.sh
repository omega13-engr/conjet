#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "image.sh must run as root inside the privileged build container" >&2
    exit 1
fi

: "${ARCH:?ARCH must be set to arm64 or amd64}"
: "${OS_ARCH:?OS_ARCH must be set to aarch64 or x86_64}"

UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-noble}"
ROOTFS_MIRROR="${ROOTFS_MIRROR:-}"
ROOT_DISK_GB="${ROOT_DISK_GB:-16}"
RUNTIME="${RUNTIME:-docker}"
DOCKER_PACKAGE="${DOCKER_PACKAGE:-docker.io}"
CONJET_CORE_VERSION="${CONJET_CORE_VERSION:-1.0.0}"

case "${RUNTIME}" in
    docker|none)
        ;;
    *)
        echo "unsupported RUNTIME=${RUNTIME}; expected docker or none" >&2
        exit 1
        ;;
esac

BUILD_DIR="/build"
WORK_DIR="${BUILD_DIR}/dist/work"
OUT_DIR="${BUILD_DIR}/dist/out"
MOUNT_DIR="/mnt/conjet-core-root"
ARTIFACT_BASE="conjet-ubuntu-${UBUNTU_VERSION}-rootfs-${OS_ARCH}-${RUNTIME}"
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
    curl \
    debootstrap \
    e2fsprogs \
    file \
    gzip \
    mount \
    parted \
    util-linux

mkdir -p "${WORK_DIR}" "${OUT_DIR}" "${MOUNT_DIR}"

if [ -z "${ROOTFS_MIRROR}" ]; then
    case "${ARCH}" in
        arm64)
            ROOTFS_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
            ;;
        amd64)
            ROOTFS_MIRROR="http://archive.ubuntu.com/ubuntu"
            ;;
        *)
            echo "unsupported ARCH=${ARCH}; expected arm64 or amd64" >&2
            exit 1
            ;;
    esac
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
log "creating ${ROOT_DISK_GB} GiB raw root disk"
truncate -s "${ROOT_DISK_GB}G" "${RAW_IMAGE}"

log "partitioning raw disk"
parted -s "${RAW_IMAGE}" mklabel gpt
parted -s "${RAW_IMAGE}" mkpart primary ext4 1MiB 100%
ROOT_PARTITION_LOOP="$(attach_partition_loop "${RAW_IMAGE}" 1)"
log "creating root filesystem"
mkfs.ext4 -F -L conjet-root "${ROOT_PARTITION_LOOP}"

log "mounting root filesystem"
mount "${ROOT_PARTITION_LOOP}" "${MOUNT_DIR}"
log "bootstrapping Ubuntu ${UBUNTU_CODENAME} ${ARCH} rootfs from ${ROOTFS_MIRROR}"
debootstrap \
    --arch="${ARCH}" \
    --variant=minbase \
    --include=ca-certificates \
    "${UBUNTU_CODENAME}" \
    "${MOUNT_DIR}" \
    "${ROOTFS_MIRROR}"

cat >"${MOUNT_DIR}/etc/apt/sources.list" <<EOF_SOURCES
deb ${ROOTFS_MIRROR} ${UBUNTU_CODENAME} main universe
deb ${ROOTFS_MIRROR} ${UBUNTU_CODENAME}-updates main universe
deb ${ROOTFS_MIRROR} ${UBUNTU_CODENAME}-security main universe
EOF_SOURCES

printf 'conjet-core\n' >"${MOUNT_DIR}/etc/hostname"
cat >"${MOUNT_DIR}/etc/hosts" <<'EOF_HOSTS'
127.0.0.1 localhost
127.0.1.1 conjet-core
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF_HOSTS
cat >"${MOUNT_DIR}/etc/fstab" <<'EOF_FSTAB'
/dev/vda1 / ext4 defaults 0 1
EOF_FSTAB

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
    curl \
    dbus \
    gcc \
    gnupg \
    iproute2 \
    iptables \
    libc6-dev \
    netcat-openbsd \
    netplan.io \
    openssh-server \
    python3 \
    socat \
    systemd \
    systemd-resolved \
    systemd-sysv \
    udev \
    ${RUNTIME_PACKAGES}
guest_kernel="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1 || true)"
if [ -n "${guest_kernel}" ]; then
    apt-get install -y --no-install-recommends "linux-modules-extra-${guest_kernel}" || \
        apt-get install -y --no-install-recommends linux-modules-extra-virtual || \
        echo "linux zram module package unavailable for ${guest_kernel}; continuing without zram module preload" >&2
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

rm -f "${MOUNT_DIR}/usr/sbin/policy-rc.d"

mkdir -p "${MOUNT_DIR}/usr/local/sbin" "${MOUNT_DIR}/usr/local/src" "${MOUNT_DIR}/etc/systemd/system" \
    "${MOUNT_DIR}/etc/systemd/network" \
    "${MOUNT_DIR}/etc/modules-load.d" "${MOUNT_DIR}/etc/netplan" "${MOUNT_DIR}/etc/cloud" \
    "${MOUNT_DIR}/etc/conjet"
install -m 0755 "${BUILD_DIR}/scripts/conjet-docker-vsock-bridge.py" \
    "${MOUNT_DIR}/usr/local/sbin/conjet-docker-vsock-bridge.py"
install -m 0644 "${BUILD_DIR}/src/conjet-netd.c" \
    "${MOUNT_DIR}/usr/local/src/conjet-netd.c"
install -m 0644 "${BUILD_DIR}/src/conjet-memd.c" \
    "${MOUNT_DIR}/usr/local/src/conjet-memd.c"
install -m 0644 "${BUILD_DIR}/src/conjet-reclaimd.c" \
    "${MOUNT_DIR}/usr/local/src/conjet-reclaimd.c"
install -m 0755 "${BUILD_DIR}/scripts/conjet-docker-service-guard.sh" \
    "${MOUNT_DIR}/usr/local/sbin/conjet-docker-service-guard.sh"
install -m 0755 "${BUILD_DIR}/scripts/conjet-docker-storage-setup.sh" \
    "${MOUNT_DIR}/usr/local/sbin/conjet-docker-storage-setup.sh"
install -m 0755 "${BUILD_DIR}/scripts/conjet-boot-diagnostics.sh" \
    "${MOUNT_DIR}/usr/local/sbin/conjet-boot-diagnostics.sh"
install -m 0755 "${BUILD_DIR}/scripts/conjet-memory-setup.sh" \
    "${MOUNT_DIR}/usr/local/sbin/conjet-memory-setup.sh"

cat >"${MOUNT_DIR}/usr/local/sbin/conjet-init-ready.sh" <<SH
#!/bin/sh
set -eu
runtime="${RUNTIME}"
timeout="\${CONJET_CONTROL_READY_TIMEOUT_SECONDS:-30}"
deadline=\$((\$(date +%s) + timeout))
mkdir -p /run/conjet
if [ "\${runtime}" = "docker" ]; then
    while [ ! -e /run/conjet/docker-vsock-ready ]; do
        if [ "\$(date +%s)" -ge "\${deadline}" ]; then
            printf 'CONJET_CONTROL_READY_TIMEOUT runtime=%s docker_vsock_ready=no docker_api_ready=no\\n' "\${runtime}" >/dev/console 2>/dev/null || true
            exit 1
        fi
        sleep 0.2
    done
fi
/usr/local/sbin/conjet-netd --send-readiness control-ready >/run/conjet/readiness-vector.log 2>&1 || true
docker_vsock_ready=no
if [ -e /run/conjet/docker-vsock-ready ]; then
    docker_vsock_ready=yes
fi
docker_api_ready=no
if [ -S /var/run/docker.sock ] && systemctl is-active --quiet docker.service 2>/dev/null && curl --fail --silent --show-error --max-time 0.5 --unix-socket /var/run/docker.sock http://localhost/_ping >/run/conjet/docker-api-ready 2>/run/conjet/docker-api-ready.err; then
    docker_api_ready=yes
    printf 'CONJET_DOCKER_READY runtime=%s docker_vsock_ready=%s docker_api_ready=yes\\n' "\${runtime}" "\${docker_vsock_ready}" >/run/conjet/docker-ready
    cat /run/conjet/docker-ready >/dev/console 2>/dev/null || true
fi
/usr/local/sbin/conjet-netd --send-readiness process-started >>/run/conjet/readiness-vector.log 2>&1 || true
printf 'CONJET_CONTROL_READY runtime=%s docker_vsock_ready=%s docker_api_ready=%s\\n' "\${runtime}" "\${docker_vsock_ready}" "\${docker_api_ready}" >/run/conjet/control-ready
printf 'CONJET_INIT_READY runtime=%s docker_vsock_ready=%s docker_api_ready=%s\\n' "\${runtime}" "\${docker_vsock_ready}" "\${docker_api_ready}" >/run/conjet/init-ready
cat /run/conjet/control-ready >/dev/console 2>/dev/null || true
cat /run/conjet/init-ready >/dev/console 2>/dev/null || cat /run/conjet/init-ready
SH
chmod 0755 "${MOUNT_DIR}/usr/local/sbin/conjet-init-ready.sh"

cat >"${MOUNT_DIR}/usr/local/sbin/conjet-host-time-sync.sh" <<'SH'
#!/bin/sh
set -eu

BOOT_MOUNT="${CONJET_BOOT_MOUNT:-/mnt/conjetboot}"
SEED_FILE="${CONJET_HOST_EPOCH_MS_FILE:-${BOOT_MOUNT}/host-epoch-ms}"
LOG_FILE="${CONJET_HOST_TIME_LOG:-/run/conjet/host-time-sync.log}"

log() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    printf 'conjet-host-time-sync: %s\n' "$*" >>"${LOG_FILE}"
}

cmdline_epoch_ms() {
    [ -r /proc/cmdline ] || return 1
    for token in $(cat /proc/cmdline); do
        case "${token}" in
            conjet.host_epoch_ms=*)
                printf '%s\n' "${token#conjet.host_epoch_ms=}"
                return 0
                ;;
        esac
    done
    return 1
}

mkdir -p /run/conjet
epoch_ms="$(cmdline_epoch_ms | tr -dc '0-9' | cut -c1-16 || true)"
if [ -z "${epoch_ms}" ]; then
    mkdir -p "${BOOT_MOUNT}"
    if ! mountpoint -q "${BOOT_MOUNT}"; then
        mount -t virtiofs conjetboot "${BOOT_MOUNT}" 2>/dev/null || true
    fi
    if [ ! -r "${SEED_FILE}" ]; then
        log "host epoch seed missing"
        exit 0
    fi
    epoch_ms="$(tr -dc '0-9' <"${SEED_FILE}" | cut -c1-16)"
fi

case "${epoch_ms}" in
    ''|*[!0-9]*)
        log "host epoch seed invalid"
        exit 0
        ;;
esac

seconds=$((epoch_ms / 1000))
milliseconds=$((epoch_ms % 1000))
if [ "${seconds}" -lt 1700000000 ]; then
    log "host epoch seed too old: ${seconds}"
    exit 0
fi

timestamp="${seconds}.$(printf '%03d' "${milliseconds}")"
if date -u -s "@${timestamp}" >/dev/null 2>&1 || date -u -s "@${seconds}" >/dev/null; then
    log "set guest clock from host epoch ${epoch_ms}"
else
    log "failed to set guest clock from host epoch ${epoch_ms}"
    exit 1
fi
SH
chmod 0755 "${MOUNT_DIR}/usr/local/sbin/conjet-host-time-sync.sh"

chroot "${MOUNT_DIR}" /usr/bin/env \
    /usr/bin/gcc -O2 -Wall -Wextra -pthread \
    -o /usr/local/sbin/conjet-netd \
    /usr/local/src/conjet-netd.c
chroot "${MOUNT_DIR}" /usr/local/sbin/conjet-netd --capabilities >/dev/null
chroot "${MOUNT_DIR}" /usr/bin/env \
    /usr/bin/gcc -O2 -Wall -Wextra -pthread \
    -o /usr/local/sbin/conjet-memd \
    /usr/local/src/conjet-memd.c
chroot "${MOUNT_DIR}" /usr/local/sbin/conjet-memd --metrics >/dev/null
chroot "${MOUNT_DIR}" /usr/bin/env \
    /usr/bin/gcc -O2 -Wall -Wextra \
    -o /usr/local/sbin/conjet-reclaimd \
    /usr/local/src/conjet-reclaimd.c
chroot "${MOUNT_DIR}" /usr/local/sbin/conjet-reclaimd --epoch 0 >/dev/null || true

chroot "${MOUNT_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive /bin/bash -s <<'CHROOT'
set -euxo pipefail
purge_candidates=(
    build-essential \
    cloud-init \
    gcc \
    libc6-dev \
    lxd \
    lxd-agent \
    lxd-installer \
    make \
    neofetch \
    snapd \
    unattended-upgrades \
    vim \
    vim-common \
    vim-runtime \
    vim-tiny
)
purge_packages=()
for package in "${purge_candidates[@]}"; do
    if dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q 'install ok installed'; then
        purge_packages+=("${package}")
    fi
done
if [ "${#purge_packages[@]}" -gt 0 ]; then
    apt-get purge -y --auto-remove "${purge_packages[@]}"
fi
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
CHROOT

cat >"${MOUNT_DIR}/usr/local/sbin/conjet-docker-vsock-entrypoint.sh" <<'SH'
#!/bin/sh
set -eu
mkdir -p /run/conjet /mnt/conjetboot /etc/conjet
if ! mountpoint -q /mnt/conjetboot; then
    mount -t virtiofs conjetboot /mnt/conjetboot 2>/dev/null || true
fi
engine="${CONJET_NET_BRIDGE_ENGINE:-$(cat /mnt/conjetboot/network-bridge-engine 2>/dev/null || cat /etc/conjet/network-bridge-engine 2>/dev/null || echo auto)}"
case "${engine}" in
    auto|"")
        if [ -x /usr/local/sbin/conjet-netd ]; then
            exec /usr/local/sbin/conjet-netd
        fi
        exec /usr/local/sbin/conjet-docker-vsock-bridge.py
        ;;
    conjet-netd|conjet-netd-c)
        if [ -x /usr/local/sbin/conjet-netd ]; then
            exec /usr/local/sbin/conjet-netd
        fi
        echo "conjet-netd-c requested but /usr/local/sbin/conjet-netd is missing" >&2
        exit 42
        ;;
    python|python-legacy)
        exec /usr/local/sbin/conjet-docker-vsock-bridge.py
        ;;
    *)
        echo "unsupported CONJET_NET_BRIDGE_ENGINE=${engine}" >&2
        exit 43
        ;;
esac
SH
chmod 0755 "${MOUNT_DIR}/usr/local/sbin/conjet-docker-vsock-entrypoint.sh"

cat >"${MOUNT_DIR}/etc/systemd/system/conjet.slice" <<'UNIT'
[Unit]
Description=Conjet guest workloads

[Slice]
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-daemons.slice" <<'UNIT'
[Unit]
Description=Conjet Docker daemon processes

[Slice]
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-build.slice" <<'UNIT'
[Unit]
Description=Conjet build workloads

[Slice]
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-services.slice" <<'UNIT'
[Unit]
Description=Conjet long-running container services

[Slice]
MemoryLow=512M
UNIT

mkdir -p \
    "${MOUNT_DIR}/etc/systemd/system/containerd.service.d" \
    "${MOUNT_DIR}/etc/systemd/system/docker.service.d"
cat >"${MOUNT_DIR}/etc/systemd/system/containerd.service.d/conjet-cgroup.conf" <<'UNIT'
[Service]
Slice=conjet-daemons.slice
UNIT
cat >"${MOUNT_DIR}/etc/systemd/system/docker.service.d/conjet-cgroup.conf" <<'UNIT'
[Service]
Slice=conjet-daemons.slice
UNIT
cat >"${MOUNT_DIR}/etc/systemd/system/conjet-docker-lifecycle.service" <<'UNIT'
[Unit]
Description=Conjet Docker lifecycle marker
DefaultDependencies=no
Wants=conjet-docker-storage.service
After=conjet-docker-storage.service
Before=containerd.service docker.socket docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conjet-docker-service-guard.sh mark-start
ExecStop=/usr/local/sbin/conjet-docker-service-guard.sh mark-stop
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-docker-storage.service" <<'UNIT'
[Unit]
Description=Conjet Docker dedicated storage mount
DefaultDependencies=no
After=local-fs.target
Before=conjet-docker-lifecycle.service containerd.service docker.socket docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conjet-docker-storage-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=conjet-appliance.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-host-time-sync.service" <<'UNIT'
[Unit]
Description=Conjet host clock seed sync
DefaultDependencies=no
Before=sysinit.target time-set.target time-sync.target systemd-journald.service containerd.service docker.socket docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conjet-host-time-sync.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-docker-vsock.service" <<'UNIT'
[Unit]
Description=Conjet Docker VSOCK bridge
After=conjet-docker-lifecycle.service docker.socket
Wants=conjet-docker-lifecycle.service docker.socket

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'modprobe vmw_vsock_virtio_transport 2>/dev/null || modprobe virtio_vsock 2>/dev/null || true'
ExecStartPre=/bin/sh -c 'if [ "${CONJET_DOCKER_REPAIR_ON_BOOT:-0}" = "1" ]; then exec /usr/local/sbin/conjet-docker-service-guard.sh repair-if-required; fi'
ExecStartPre=/bin/sh -c 'mkdir -p /run/conjet /mnt/conjetboot /etc/conjet; mountpoint -q /mnt/conjetboot || mount -t virtiofs conjetboot /mnt/conjetboot 2>/dev/null || true; rm -f /run/conjet/docker-vsock-ready'
ExecStart=/usr/local/sbin/conjet-docker-vsock-entrypoint.sh
Restart=always
RestartSec=2
StandardOutput=append:/run/conjet/docker-vsock.log
StandardError=append:/run/conjet/docker-vsock.log

[Install]
WantedBy=conjet-appliance.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-memory.service" <<'UNIT'
[Unit]
Description=Conjet memory telemetry VSOCK service
After=conjet-memory-setup.service
Wants=conjet-memory-setup.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'modprobe vmw_vsock_virtio_transport 2>/dev/null || modprobe virtio_vsock 2>/dev/null || true'
ExecStartPre=/bin/sh -c 'mkdir -p /run/conjet; rm -f /run/conjet/memory-vsock-ready'
ExecStart=/usr/local/sbin/conjet-memd
Restart=always
RestartSec=2
StandardOutput=append:/run/conjet/memory-vsock.log
StandardError=append:/run/conjet/memory-vsock.log

[Install]
WantedBy=conjet-appliance.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-memory-setup.service" <<'UNIT'
[Unit]
Description=Conjet zram and fallback swap setup
DefaultDependencies=no
Before=swap.target conjet-memory.service docker.service containerd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conjet-memory-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=conjet-appliance.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-appliance.target" <<'UNIT'
[Unit]
Description=Conjet HVF container appliance
Requires=basic.target
After=basic.target
AllowIsolate=yes
UNIT

ln -sf /etc/systemd/system/conjet-appliance.target "${MOUNT_DIR}/etc/systemd/system/default.target"

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-boot-diagnostics.service" <<'UNIT'
[Unit]
Description=Conjet boot diagnostics
After=containerd.service docker.socket docker.service conjet-docker-vsock.service
Wants=containerd.service docker.socket docker.service conjet-docker-vsock.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conjet-boot-diagnostics.sh
RemainAfterExit=yes

[Install]
WantedBy=conjet-appliance.target
UNIT

cat >"${MOUNT_DIR}/etc/systemd/system/conjet-init-ready.service" <<'UNIT'
[Unit]
Description=Conjet init readiness console marker
After=conjet-docker-vsock.service
Wants=conjet-docker-vsock.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conjet-init-ready.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=conjet-appliance.target
UNIT

mkdir -p "${MOUNT_DIR}/Users" "${MOUNT_DIR}/Volumes"

cat >"${MOUNT_DIR}/etc/systemd/system/Users.mount" <<'UNIT'
[Unit]
Description=Conjet host /Users VirtioFS share
DefaultDependencies=no
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
Before=local-fs.target

[Mount]
What=conjethostvolumes
Where=/Volumes
Type=virtiofs
Options=rw

[Install]
WantedBy=local-fs.target
UNIT

rm -f "${MOUNT_DIR}/etc/modules-load.d/conjet-vsock.conf"

cat >"${MOUNT_DIR}/etc/netplan/50-conjet.yaml" <<'EOF_NETPLAN'
network:
  version: 2
  ethernets:
    conjet-nat:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: false
      optional: true
EOF_NETPLAN
chmod 0600 "${MOUNT_DIR}/etc/netplan/50-conjet.yaml"

cat >"${MOUNT_DIR}/etc/systemd/network/10-conjet-eth0.network" <<'EOF_NETWORKD'
[Match]
Name=eth0

[Network]
DHCP=ipv4
LinkLocalAddressing=ipv6

[DHCP]
RouteMetric=10
UseMTU=true
EOF_NETWORKD

rm -f "${MOUNT_DIR}/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "${MOUNT_DIR}/etc/resolv.conf"

touch "${MOUNT_DIR}/etc/cloud/cloud-init.disabled"

mkdir -p "${MOUNT_DIR}/etc/docker" "${MOUNT_DIR}/etc/sysctl.d"
cat >"${MOUNT_DIR}/etc/docker/daemon.json" <<'EOF_DOCKER'
{
  "cgroup-parent": "conjet-build.slice",
  "features": {
    "buildkit": true
  },
  "iptables": true,
  "ip-forward": true,
  "ip-masq": true,
  "live-restore": false,
  "log-driver": "local",
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 6,
  "storage-driver": "overlay2",
  "userland-proxy": false
}
EOF_DOCKER

cat >"${MOUNT_DIR}/etc/sysctl.d/90-conjet-appliance.conf" <<'EOF_SYSCTL'
fs.inotify.max_user_instances=1024
fs.inotify.max_user_watches=1048576
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
kernel.perf_event_paranoid=3
kernel.unprivileged_bpf_disabled=1
net.core.default_qdisc=fq
net.ipv4.ip_forward=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
vm.swappiness=180
EOF_SYSCTL

if [ -f "${MOUNT_DIR}/etc/fstab" ]; then
    awk '
        /^[[:space:]]*#/ || NF == 0 {
            print
            next
        }
        $2 == "/boot" || $2 == "/boot/" || $2 == "/boot/efi" || $2 == "/boot/efi/" {
            next
        }
        { print }
    ' "${MOUNT_DIR}/etc/fstab" >"${MOUNT_DIR}/etc/fstab.conjet"
    mv "${MOUNT_DIR}/etc/fstab.conjet" "${MOUNT_DIR}/etc/fstab"
fi

cat >"${MOUNT_DIR}/etc/conjet/release" <<EOF_RELEASE
name=conjet-core
version=${CONJET_CORE_VERSION}
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

mask_unit() {
    local unit="$1"
    mkdir -p "${MOUNT_DIR}/etc/systemd/system"
    ln -sf /dev/null "${MOUNT_DIR}/etc/systemd/system/${unit}"
}

if [ "${RUNTIME}" = "docker" ]; then
    enable_unit conjet-host-time-sync.service sysinit.target
    enable_unit systemd-networkd.service conjet-appliance.target
    enable_unit systemd-resolved.service conjet-appliance.target
    enable_unit conjet-docker-storage.service conjet-appliance.target
    enable_unit conjet-docker-lifecycle.service local-fs.target
    enable_unit containerd.service conjet-appliance.target
    enable_unit docker.service conjet-appliance.target
    enable_unit docker.socket sockets.target
    enable_unit docker.socket conjet-appliance.target
    enable_unit conjet-build.slice conjet-appliance.target
    enable_unit conjet-services.slice conjet-appliance.target
    enable_unit conjet-memory-setup.service conjet-appliance.target
    enable_unit conjet-docker-vsock.service conjet-appliance.target
    enable_unit conjet-memory.service conjet-appliance.target
    enable_unit conjet-init-ready.service conjet-appliance.target
fi

enable_unit conjet-init-ready.service conjet-appliance.target

for unit in \
    apt-daily.service \
    apt-daily.timer \
    apt-daily-upgrade.service \
    apt-daily-upgrade.timer \
    cloud-config.service \
    cloud-final.service \
    cloud-init-local.service \
    cloud-init.service \
    console-setup.service \
    cron.service \
    getty-static.service \
    getty.target \
    getty@tty1.service \
    e2scrub_all.timer \
    fstrim.timer \
    fwupd-refresh.service \
    fwupd-refresh.timer \
    keyboard-setup.service \
    logrotate.timer \
    lxd-installer.socket \
    man-db.timer \
    motd-news.service \
    motd-news.timer \
    packagekit.service \
    pollinate.service \
    rsyslog.service \
    serial-getty@ttyAMA0.service \
    setvtrgb.service \
    snapd.seeded.service \
    snapd.service \
    snapd.socket \
    sys-kernel-debug.mount \
    systemd-networkd-wait-online.service \
    systemd-modules-load.service \
    modprobe@configfs.service \
    modprobe@dm_mod.service \
    modprobe@efi_pstore.service \
    modprobe@fuse.service \
    modprobe@loop.service \
    systemd-timesyncd.service \
    unattended-upgrades.service; do
    mask_unit "${unit}"
done

chroot "${MOUNT_DIR}" /bin/bash -c 'netplan generate || true'
chroot "${MOUNT_DIR}" /bin/bash -c 'truncate -s 0 /etc/machine-id || true; rm -f /var/lib/dbus/machine-id; ln -sf /etc/machine-id /var/lib/dbus/machine-id'
chroot "${MOUNT_DIR}" /bin/bash -c 'rm -rf /tmp/* /var/tmp/* /var/log/*.log /var/log/journal/* 2>/dev/null || true'

dd if=/dev/zero of="${MOUNT_DIR}/EMPTY" bs=1M status=none 2>/dev/null || true
rm -f "${MOUNT_DIR}/EMPTY"
sync

cleanup
trap - EXIT
set -euo pipefail

gzip -9 -c "${RAW_IMAGE}" >"${OUT_IMAGE}"
(
    cd "$(dirname "${OUT_IMAGE}")"
    sha512sum "$(basename "${OUT_IMAGE}")" >"$(basename "${OUT_IMAGE}").sha512sum"
)

cat >"${OUT_IMAGE}.json" <<EOF_JSON
{
  "name": "conjet-core",
  "version": "${CONJET_CORE_VERSION}",
  "ubuntuVersion": "${UBUNTU_VERSION}",
  "architecture": "${OS_ARCH}",
  "runtime": "${RUNTIME}",
  "rootDiskGiB": ${ROOT_DISK_GB},
  "format": "raw.gz",
  "systemdDefaultTarget": "conjet-appliance.target",
  "recommendedKernelCommandLine": "console=ttyAMA0 earlycon=pl011,0x09000000 root=/dev/vda1 rw rootwait systemd.unit=conjet-appliance.target",
  "artifact": "$(basename "${OUT_IMAGE}")"
}
EOF_JSON

rm -f "${RAW_IMAGE}"

if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${OUT_DIR}" "${WORK_DIR}" || true
fi

printf '%s\n' "${OUT_IMAGE}"

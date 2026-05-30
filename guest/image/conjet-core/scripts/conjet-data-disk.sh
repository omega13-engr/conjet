#!/bin/sh
set -eu

DEVICE="${CONJET_DATA_DEVICE:-/dev/disk/by-id/virtio-conjet-data}"
MOUNT_DIR="${CONJET_DATA_MOUNT:-/mnt/conjet-data}"
MOUNT_OPTIONS="${CONJET_DATA_MOUNT_OPTIONS:-noatime,nodiratime,lazytime,nodiscard,commit=60}"

log() {
    echo "conjet-data-disk: $*"
}

wait_for_device() {
    attempts=0
    while [ ! -e "${DEVICE}" ]; do
        attempts=$((attempts + 1))
        if [ "${attempts}" -ge 60 ]; then
            echo "conjet-data-disk: ${DEVICE} did not appear" >&2
            return 1
        fi
        sleep 1
    done
}

filesystem_type() {
    blkid -o value -s TYPE "${DEVICE}" 2>/dev/null || true
}

directory_empty() {
    [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

tune_block_devices() {
    for scheduler in /sys/block/vd*/queue/scheduler; do
        [ -e "${scheduler}" ] || continue
        if grep -qw none "${scheduler}"; then
            echo none >"${scheduler}" 2>/dev/null || true
            log "set ${scheduler} to $(cat "${scheduler}")"
        fi
    done
}

mount_data_disk() {
    mkdir -p "${MOUNT_DIR}"
    if mountpoint -q "${MOUNT_DIR}"; then
        mount -o "remount,${MOUNT_OPTIONS}" "${MOUNT_DIR}" || true
        return 0
    fi
    mount -o "${MOUNT_OPTIONS}" "${DEVICE}" "${MOUNT_DIR}"
}

bind_runtime_directory() {
    source_dir="$1"
    target_dir="${MOUNT_DIR}$1"

    mkdir -p "${source_dir}" "${target_dir}"

    if mountpoint -q "${source_dir}"; then
        log "${source_dir} already mounted"
        return 0
    fi

    if ! directory_empty "${source_dir}" && directory_empty "${target_dir}"; then
        log "migrating ${source_dir} to data disk"
        cp -a "${source_dir}/." "${target_dir}/"
    fi

    mount --bind "${target_dir}" "${source_dir}"
    mountpoint -q "${source_dir}"
    log "mounted ${source_dir} on data disk"
}

wait_for_device
tune_block_devices

TYPE="$(filesystem_type)"
if [ -z "${TYPE}" ]; then
    log "formatting ${DEVICE} as ext4"
    mkfs.ext4 -F -L conjet-data "${DEVICE}"
elif [ "${TYPE}" = "ext4" ]; then
    e2fsck -pf "${DEVICE}" || true
    resize2fs "${DEVICE}" || true
fi

mount_data_disk
bind_runtime_directory /var/lib/containerd
bind_runtime_directory /var/lib/docker

log "ready"

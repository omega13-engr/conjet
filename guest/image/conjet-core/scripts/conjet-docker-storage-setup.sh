#!/bin/sh
set -eu

RUN_DIR="${CONJET_RUN_DIR:-/run/conjet}"
LOG="${CONJET_DOCKER_STORAGE_SETUP_LOG:-${RUN_DIR}/docker-storage-setup.log}"
DOCKER_DIR="${CONJET_DOCKER_DIR:-/var/lib/docker}"
TEMP_MOUNT="${CONJET_DOCKER_STORAGE_TEMP_MOUNT:-/mnt/conjet-docker-data}"
FS_LABEL="${CONJET_DOCKER_STORAGE_LABEL:-conjet-dockerfs}"
MOUNT_OPTIONS="${CONJET_DOCKER_STORAGE_MOUNT_OPTIONS:-rw,noatime,discard,commit=30}"
MIN_FALLBACK_BYTES="${CONJET_DOCKER_STORAGE_MIN_FALLBACK_BYTES:-2147483648}"
DEVICE_WAIT_SECONDS="${CONJET_DOCKER_STORAGE_DEVICE_WAIT_SECONDS:-10}"
MARKER=".conjet-dedicated-docker-fs"
SKIP_XATTR_PROBE="${CONJET_DOCKER_STORAGE_SKIP_XATTR_PROBE:-0}"

log() {
    printf 'conjet-docker-storage-setup: %s\n' "$*" >&2
}

storage_candidates() {
    if [ -n "${CONJET_DOCKER_STORAGE_DEVICES:-}" ]; then
        printf '%s\n' ${CONJET_DOCKER_STORAGE_DEVICES}
    fi
    cat <<'EOF'
/dev/disk/by-id/virtio-conjet-data
/dev/disk/by-id/nvme-conjet-data
/dev/disk/by-label/conjet-dockerfs
/dev/disk/by-label/conjet-docker-data
/dev/disk/by-label/conjet-docker-da
/dev/disk/by-label/conjet-data
EOF
}

rust_hvf_fallback_candidates() {
    if [ -n "${CONJET_DOCKER_STORAGE_RUST_HVF_FALLBACK_DEVICES:-}" ]; then
        printf '%s\n' ${CONJET_DOCKER_STORAGE_RUST_HVF_FALLBACK_DEVICES}
        return 0
    fi
    cat <<'EOF'
/dev/disk/by-id/virtio-conjet-blk1
EOF
}

device_exists() {
    dev="$1"
    [ -b "${dev}" ] && return 0
    [ "${CONJET_DOCKER_STORAGE_ALLOW_REGULAR_DEVICE:-0}" = "1" ] && [ -e "${dev}" ]
}

device_size_bytes() {
    dev="$1"
    if command -v blockdev >/dev/null 2>&1; then
        size="$(blockdev --getsize64 "${dev}" 2>/dev/null || true)"
        case "${size}" in
            ''|*[!0-9]*)
                ;;
            *)
                printf '%s\n' "${size}"
                return 0
                ;;
        esac
    fi
    if [ -f "${dev}" ]; then
        wc -c <"${dev}" | tr -d ' '
        return 0
    fi
    return 1
}

fallback_device_large_enough() {
    dev="$1"
    min_bytes="${CONJET_DOCKER_STORAGE_MIN_FALLBACK_BYTES:-${MIN_FALLBACK_BYTES}}"
    size="$(device_size_bytes "${dev}" 2>/dev/null || true)"
    case "${size}" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    [ "${size}" -ge "${min_bytes}" ] 2>/dev/null
}

storage_candidate() {
    candidates="$(storage_candidates)"
    while IFS= read -r dev; do
        [ -n "${dev}" ] || continue
        if device_exists "${dev}"; then
            printf '%s\n' "${dev}"
            return 0
        fi
    done <<EOF_CANDIDATES
${candidates}
EOF_CANDIDATES

    fallback_candidates="$(rust_hvf_fallback_candidates)"
    while IFS= read -r dev; do
        [ -n "${dev}" ] || continue
        if device_exists "${dev}" && fallback_device_large_enough "${dev}"; then
            printf '%s\n' "${dev}"
            return 0
        fi
    done <<EOF_FALLBACK_CANDIDATES
${fallback_candidates}
EOF_FALLBACK_CANDIDATES
}

settle_devices() {
    timeout="$1"
    command -v udevadm >/dev/null 2>&1 || return 0
    udevadm settle --timeout="${timeout}" 2>/dev/null || true
}

storage_candidate_with_wait() {
    wait_seconds="${CONJET_DOCKER_STORAGE_DEVICE_WAIT_SECONDS:-${DEVICE_WAIT_SECONDS}}"
    dev="$(storage_candidate 2>/dev/null || true)"
    if [ -n "${dev}" ]; then
        printf '%s\n' "${dev}"
        return 0
    fi

    case "${wait_seconds}" in
        ''|*[!0-9]*)
            wait_seconds=0
            ;;
    esac

    if [ "${wait_seconds}" -le 0 ] 2>/dev/null; then
        return 0
    fi

    log "waiting up to ${wait_seconds}s for Docker data disk discovery"
    settle_devices "${wait_seconds}"
    attempt=0
    while [ "${attempt}" -lt "${wait_seconds}" ]; do
        dev="$(storage_candidate 2>/dev/null || true)"
        if [ -n "${dev}" ]; then
            printf '%s\n' "${dev}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
}

unit_active() {
    unit="$1"
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "${unit}" 2>/dev/null
}

docker_stack_active() {
    unit_active docker.service || unit_active docker.socket || unit_active containerd.service
}

filesystem_type() {
    blkid -o value -s TYPE "$1" 2>/dev/null || true
}

supported_filesystem() {
    case "$1" in
        ext2|ext3|ext4|xfs|btrfs)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

has_directory_entries() {
    dir="$1"
    find "${dir}" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit 2>/dev/null | grep -q .
}

copy_existing_docker_data_if_needed() {
    if has_directory_entries "${TEMP_MOUNT}"; then
        return 0
    fi
    if ! has_directory_entries "${DOCKER_DIR}"; then
        return 0
    fi
    log "migrating existing ${DOCKER_DIR} contents to dedicated data filesystem"
    cp -a "${DOCKER_DIR}/." "${TEMP_MOUNT}/"
}

mount_device() {
    dev="$1"
    target="$2"
    mkdir -p "${target}"
    mount -o "${MOUNT_OPTIONS}" "${dev}" "${target}"
}

probe_security_capability_xattr() {
    target="$1"
    [ "${SKIP_XATTR_PROBE}" = "1" ] && return 0
    mkdir -p "${target}"
    probe="${target}/.conjet-security-capability-probe.$$"
    rm -f "${probe}"
    : >"${probe}"
    if python3 - "${probe}" <<'PY'
import os
import struct
import sys

path = sys.argv[1]
cap_net_raw = 1 << 13
vfs_cap_revision_2 = 0x02000000
vfs_cap_flags_effective = 0x00000001
value = struct.pack("<IIIII", vfs_cap_revision_2 | vfs_cap_flags_effective, cap_net_raw, 0, 0, 0)

try:
    os.setxattr(path, "security.capability", value, follow_symlinks=False)
    try:
        os.removexattr(path, "security.capability", follow_symlinks=False)
    except OSError:
        pass
except OSError as error:
    print(f"{error.errno}:{error.strerror}", file=sys.stderr)
    sys.exit(1)
PY
    then
        rm -f "${probe}"
        return 0
    fi
    rc=$?
    rm -f "${probe}"
    log "${target} cannot store security.capability xattrs; Docker image layers with file capabilities will fail to unpack. Rebuild Conjet Core with CONFIG_SECURITY=y and CONFIG_EXT4_FS_SECURITY=y."
    return "${rc}"
}

unmount_if_mounted() {
    target="$1"
    if mountpoint -q "${target}" 2>/dev/null; then
        umount "${target}"
    fi
}

main() {
    mkdir -p "${RUN_DIR}"
    {
        log "start"
        if mountpoint -q "${DOCKER_DIR}" 2>/dev/null; then
            probe_security_capability_xattr "${DOCKER_DIR}"
            log "${DOCKER_DIR} is already a mountpoint; leaving it unchanged"
            log "done"
            return 0
        fi

        if docker_stack_active; then
            log "Docker/containerd is already active; refusing live storage switch"
            log "done"
            return 0
        fi

        dev="$(storage_candidate_with_wait 2>/dev/null || true)"
        if [ -z "${dev}" ]; then
            log "dedicated Docker data disk not present; using root filesystem"
            probe_security_capability_xattr "${DOCKER_DIR}"
            log "done"
            return 0
        fi
        real_dev="$(readlink -f "${dev}" 2>/dev/null || printf '%s' "${dev}")"
        log "candidate dev=${dev} real=${real_dev}"

        fs_type="$(filesystem_type "${dev}")"
        if [ -z "${fs_type}" ]; then
            log "formatting blank Docker data disk label=${FS_LABEL}"
            mkfs.ext4 -F -L "${FS_LABEL}" "${dev}" >/dev/null
            fs_type="ext4"
        elif ! supported_filesystem "${fs_type}"; then
            log "unsupported existing filesystem type=${fs_type}; using root filesystem"
            log "done"
            return 0
        else
            log "using existing filesystem type=${fs_type}"
        fi

        mkdir -p "${DOCKER_DIR}" "${TEMP_MOUNT}"
        unmount_if_mounted "${TEMP_MOUNT}"
        mount_device "${dev}" "${TEMP_MOUNT}"
        copy_existing_docker_data_if_needed
        unmount_if_mounted "${TEMP_MOUNT}"

        mount_device "${dev}" "${DOCKER_DIR}"
        mkdir -p "${DOCKER_DIR}"
        probe_security_capability_xattr "${DOCKER_DIR}"
        date -u +%Y-%m-%dT%H:%M:%SZ >"${DOCKER_DIR}/${MARKER}" 2>/dev/null || true
        findmnt -T "${DOCKER_DIR}" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true
        log "done"
    } >>"${LOG}" 2>&1
}

if [ "${CONJET_DOCKER_STORAGE_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi

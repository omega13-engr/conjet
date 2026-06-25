#!/bin/sh
set -eu

RUN_DIR="${CONJET_RUN_DIR:-/run/conjet}"
LOG="${CONJET_MEMORY_SETUP_LOG:-${RUN_DIR}/memory-setup.log}"
ZRAM_ALGO="${CONJET_ZRAM_ALGO:-lz4}"

mkdir -p "${RUN_DIR}"

log() {
    echo "conjet-memory-setup: $*"
}

mem_total_bytes() {
    awk '/^MemTotal:/ { printf "%.0f\n", $2 * 1024; exit }' /proc/meminfo 2>/dev/null || echo 0
}

default_zram_bytes() {
    total="$(mem_total_bytes)"
    if [ "${total}" -le 0 ] 2>/dev/null; then
        echo 536870912
        return
    fi
    echo $((total / 2))
}

wait_for_block() {
    dev="$1"
    i=0
    while [ "${i}" -lt 50 ]; do
        [ -b "${dev}" ] && return 0
        i=$((i + 1))
        sleep 0.02
    done
    return 1
}

is_swap_active() {
    dev="$1"
    real="$(readlink -f "${dev}" 2>/dev/null || printf '%s' "${dev}")"
    awk -v dev="${dev}" -v real="${real}" '
        NR > 1 && ($1 == dev || $1 == real) { found = 1 }
        END { exit found ? 0 : 1 }
    ' /proc/swaps 2>/dev/null
}

setup_zram() {
    size="${CONJET_ZRAM_SIZE_BYTES:-$(default_zram_bytes)}"
    [ "${size}" -gt 0 ] 2>/dev/null || return 0

    modprobe zram num_devices=1 2>/dev/null || true
    if [ -b /dev/zram0 ]; then
        dev="/dev/zram0"
    elif [ -e /sys/class/zram-control/hot_add ]; then
        id="$(cat /sys/class/zram-control/hot_add 2>/dev/null || echo 0)"
        dev="/dev/zram${id}"
    else
        dev="/dev/zram0"
    fi

    if ! wait_for_block "${dev}"; then
        log "zram device did not appear; skipping"
        return 0
    fi

    name="$(basename "${dev}")"
    if is_swap_active "${dev}"; then
        log "zram already enabled dev=${dev}"
        return 0
    fi
    if [ -e "/sys/block/${name}/comp_algorithm" ]; then
        echo "${ZRAM_ALGO}" >"/sys/block/${name}/comp_algorithm" 2>/dev/null || true
    fi
    if [ -e "/sys/block/${name}/disksize" ]; then
        echo "${size}" >"/sys/block/${name}/disksize"
    fi

    mkswap "${dev}" >/dev/null
    swapon -p 32767 "${dev}"
    log "zram enabled dev=${dev} size=${size} priority=32767"
}

swap_candidate() {
    for dev in \
        /dev/disk/by-id/virtio-conjet-swap \
        /dev/disk/by-label/conjet-swap \
        /dev/disk/by-id/virtio-conjet-blk2 \
        /dev/vdc; do
        if [ -b "${dev}" ]; then
            printf '%s\n' "${dev}"
            return 0
        fi
    done
    return 1
}

setup_disk_swap() {
    dev="$(swap_candidate 2>/dev/null || true)"
    [ -n "${dev}" ] || {
        log "dedicated swap disk not present; skipping disk swap"
        return 0
    }

    if ! blkid "${dev}" 2>/dev/null | grep -q 'TYPE="swap"'; then
        mkswap -L conjet-swap "${dev}" >/dev/null
    fi
    if ! is_swap_active "${dev}"; then
        swapon -p 1 "${dev}"
    fi
    log "disk swap enabled dev=${dev} priority=1"
}

setup_memory_sysctls() {
    if [ -w /proc/sys/vm/page-cluster ]; then
        echo 0 >/proc/sys/vm/page-cluster 2>/dev/null || true
        log "sysctl vm.page-cluster=0"
    fi
}

{
    log "start"
    setup_memory_sysctls
    setup_zram
    setup_disk_swap
    log "swaps"
    cat /proc/swaps 2>/dev/null || true
    log "done"
} >>"${LOG}" 2>&1

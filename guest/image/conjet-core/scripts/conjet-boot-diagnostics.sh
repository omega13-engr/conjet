#!/bin/sh
set +e

LOG=/run/conjet/boot-diagnostics.log
mkdir -p /run/conjet

{
    echo "conjet-boot-diagnostics: start $(date -Is 2>/dev/null || date)"
    echo "conjet-boot-diagnostics: uname"
    uname -a

    if [ -f /etc/conjet/release ]; then
        echo "conjet-boot-diagnostics: /etc/conjet/release"
        cat /etc/conjet/release
    fi

    echo "conjet-boot-diagnostics: kernel modules"
    modprobe vmw_vsock_virtio_transport 2>&1 || modprobe virtio_vsock 2>&1 || true
    lsmod | grep -E '(^vsock|vsock|virtio)' || true

    echo "conjet-boot-diagnostics: service states"
    for unit in systemd-resolved.service conjet-memory-setup.service conjet-memory.service conjet-docker-storage.service conjet-docker-lifecycle.service containerd.service docker.socket docker.service conjet-docker-vsock.service; do
        echo "unit=${unit}"
        systemctl is-enabled "${unit}" 2>&1 || true
        systemctl is-active "${unit}" 2>&1 || true
        systemctl --no-pager --full status "${unit}" 2>&1 | sed -n '1,30p' || true
    done

    echo "conjet-boot-diagnostics: memory"
    cat /proc/meminfo 2>&1 | sed -n '1,40p' || true
    cat /proc/swaps 2>&1 || true
    for zram in /sys/block/zram*; do
        [ -e "${zram}" ] || continue
        echo "zram=${zram}"
        cat "${zram}/mm_stat" 2>&1 || true
    done
    tail -n 80 /run/conjet/memory-setup.log 2>&1 || true
    tail -n 80 /run/conjet/memory-vsock.log 2>&1 || true

    echo "conjet-boot-diagnostics: block devices"
    ls -l /dev/disk/by-id 2>&1 || true
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL 2>&1 || true
    findmnt -T /var/lib/docker -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true
    df -T / /var/lib/docker /var/lib/containerd 2>&1 || true
    tail -n 80 /run/conjet/docker-storage-setup.log 2>&1 || true

    echo "conjet-boot-diagnostics: resolver"
    ls -l /etc/resolv.conf 2>&1 || true
    cat /etc/resolv.conf 2>&1 || true
    resolvectl status 2>&1 | sed -n '1,80p' || true

    echo "conjet-boot-diagnostics: sockets"
    ls -l /var/run/docker.sock /run/conjet/docker-vsock-ready 2>&1 || true
    ss -lx 2>&1 | grep -E 'docker|containerd|conjet' || true

    echo "conjet-boot-diagnostics: docker service guard"
    tail -n 80 /run/conjet/docker-service-guard.log 2>&1 || true

    echo "conjet-boot-diagnostics: virtiofs mounts"
    mount | grep -E 'conjethost|conjetboot|virtiofs' || true
    ls -ld /Users /Volumes 2>&1 || true

    echo "conjet-boot-diagnostics: docker ping"
    python3 - <<'PY' 2>&1 || true
import socket
path = "/var/run/docker.sock"
try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(path)
    sock.sendall(b"GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")
    print(sock.recv(4096).decode("utf-8", errors="replace"))
except Exception as exc:
    print(f"docker ping failed: {exc!r}")
finally:
    try:
        sock.close()
    except Exception:
        pass
PY

    echo "conjet-boot-diagnostics: end $(date -Is 2>/dev/null || date)"
} >"${LOG}" 2>&1

for console in /dev/hvc0 /dev/console; do
    [ -w "${console}" ] || continue
    {
        echo "conjet-boot-diagnostics: begin"
        cat "${LOG}"
        echo "conjet-boot-diagnostics: finish"
    } >"${console}" 2>&1 || true
done

exit 0

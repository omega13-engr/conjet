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
    for unit in containerd.service docker.socket docker.service conjet-docker-vsock.service; do
        echo "unit=${unit}"
        systemctl is-enabled "${unit}" 2>&1 || true
        systemctl is-active "${unit}" 2>&1 || true
        systemctl --no-pager --full status "${unit}" 2>&1 | sed -n '1,30p' || true
    done

    echo "conjet-boot-diagnostics: sockets"
    ls -l /var/run/docker.sock /run/conjet/docker-vsock-ready 2>&1 || true
    ss -lx 2>&1 | grep -E 'docker|containerd|conjet' || true

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

if [ -w /dev/hvc0 ]; then
    {
        echo "conjet-boot-diagnostics: begin"
        cat "${LOG}"
        echo "conjet-boot-diagnostics: finish"
    } >/dev/hvc0 2>&1 || true
fi

exit 0

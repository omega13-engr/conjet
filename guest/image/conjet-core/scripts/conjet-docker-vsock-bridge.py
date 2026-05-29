#!/usr/bin/env python3
import os
import signal
import socket
import sys
import threading
import time

DOCKER_SOCKET = os.environ.get("CONJET_DOCKER_SOCKET", "/var/run/docker.sock")
VSOCK_PORT = int(os.environ.get("CONJET_DOCKER_VSOCK_PORT", "2375"))
AF_VSOCK = getattr(socket, "AF_VSOCK", 40)
VMADDR_CID_ANY = getattr(socket, "VMADDR_CID_ANY", 0xFFFFFFFF)
DOCKER_WAIT_LOG_SECONDS = 10
CLIENT_DOCKER_WAIT_SECONDS = 60


def log(message):
    sys.stderr.write(f"conjet-docker-vsock: {message}\n")
    sys.stderr.flush()


def ignore_sigpipe():
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    except (AttributeError, ValueError):
        pass


def close_socket(sock):
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


def shutdown_write(sock):
    try:
        sock.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def write_http_unavailable(client, message):
    body = f"Conjet guest Docker daemon is not ready: {message}\n".encode()
    response = (
        b"HTTP/1.1 503 Service Unavailable\r\n"
        b"Content-Type: text/plain; charset=utf-8\r\n"
        b"Connection: close\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"\r\n" + body
    )
    try:
        client.sendall(response)
    except OSError:
        pass


def pump(source, destination):
    try:
        while True:
            chunk = source.recv(65536)
            if not chunk:
                break
            destination.sendall(chunk)
    except OSError:
        pass
    finally:
        shutdown_write(destination)


def docker_ready_status(timeout=2.0):
    if not os.path.exists(DOCKER_SOCKET):
        return False, f"waiting for {DOCKER_SOCKET}"

    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    upstream.settimeout(timeout)
    try:
        upstream.connect(DOCKER_SOCKET)
        upstream.sendall(
            b"GET /_ping HTTP/1.1\r\n"
            b"Host: docker\r\n"
            b"Connection: close\r\n"
            b"\r\n"
        )
        response = b""
        while True:
            chunk = upstream.recv(4096)
            if not chunk:
                break
            response += chunk
            if b"\r\n\r\nOK" in response or response.rstrip().endswith(b"OK"):
                break
        if b"200 OK" in response and response.rstrip().endswith(b"OK"):
            return True, "Docker API is ready"
        return False, "waiting for Docker API /_ping response"
    except OSError as exc:
        return False, f"waiting for Docker API on {DOCKER_SOCKET}: {exc}"
    finally:
        close_socket(upstream)


def wait_for_docker_ready():
    last_log = 0
    while True:
        now = time.monotonic()
        ready, status = docker_ready_status()
        if ready:
            log(status)
            return

        if now - last_log >= DOCKER_WAIT_LOG_SECONDS:
            log(status)
            last_log = now
        time.sleep(1)


def connect_docker_with_retry(timeout_seconds=CLIENT_DOCKER_WAIT_SECONDS):
    deadline = time.monotonic() + timeout_seconds
    last_error = None
    while True:
        ready, status = docker_ready_status(timeout=1.0)
        if not ready:
            last_error = status
            if time.monotonic() >= deadline:
                raise TimeoutError(status)
            time.sleep(0.25)
            continue

        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            upstream.connect(DOCKER_SOCKET)
            return upstream
        except OSError as exc:
            last_error = exc
            close_socket(upstream)
            if time.monotonic() >= deadline:
                raise TimeoutError(f"could not connect to {DOCKER_SOCKET}: {last_error}")
            time.sleep(0.25)


def handle_client(client):
    try:
        upstream = connect_docker_with_retry()
    except TimeoutError as exc:
        log(str(exc))
        write_http_unavailable(client, str(exc))
        close_socket(client)
        return

    client_to_upstream = threading.Thread(target=pump, args=(client, upstream))
    upstream_to_client = threading.Thread(target=pump, args=(upstream, client))
    client_to_upstream.start()
    upstream_to_client.start()
    client_to_upstream.join()
    upstream_to_client.join()
    close_socket(upstream)
    close_socket(client)


def main():
    ignore_sigpipe()
    os.makedirs("/run/conjet", exist_ok=True)
    try:
        os.unlink("/run/conjet/docker-vsock-ready")
    except FileNotFoundError:
        pass

    log(
        "starting bridge "
        f"python={sys.version.split()[0]} "
        f"af_vsock={AF_VSOCK} cid_any={VMADDR_CID_ANY} "
        f"port={VSOCK_PORT} docker_socket={DOCKER_SOCKET}"
    )

    try:
        listener = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
    except OSError as exc:
        log(f"failed to create VSOCK listener socket: {exc}")
        raise

    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    except OSError:
        pass
    try:
        listener.bind((VMADDR_CID_ANY, VSOCK_PORT))
        listener.listen(128)
    except OSError as exc:
        log(f"failed to bind VSOCK port {VSOCK_PORT}: {exc}")
        raise
    log(f"listening on VSOCK port {VSOCK_PORT}")

    with open("/run/conjet/docker-vsock-ready", "w", encoding="utf-8") as marker:
        marker.write(f"{VSOCK_PORT}\n")

    threading.Thread(target=wait_for_docker_ready, daemon=True).start()

    while True:
        try:
            client, _ = listener.accept()
        except OSError as exc:
            log(f"accept failed on VSOCK port {VSOCK_PORT}: {exc}")
            continue
        threading.Thread(target=handle_client, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()

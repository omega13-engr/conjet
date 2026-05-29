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
CLIENT_DOCKER_WAIT_SECONDS = 30


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
        close_socket(source)
        close_socket(destination)


def docker_api_ping(timeout=2.0):
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
        return b"200 OK" in response and response.rstrip().endswith(b"OK")
    except OSError:
        return False
    finally:
        close_socket(upstream)


def wait_for_docker_ready():
    last_log = 0
    while True:
        now = time.monotonic()
        if not os.path.exists(DOCKER_SOCKET):
            status = f"waiting for {DOCKER_SOCKET}"
        elif docker_api_ping():
            log("Docker API is ready")
            return
        else:
            status = f"waiting for Docker API on {DOCKER_SOCKET}"

        if now - last_log >= DOCKER_WAIT_LOG_SECONDS:
            log(status)
            last_log = now
        time.sleep(1)


def connect_docker_with_retry(timeout_seconds=CLIENT_DOCKER_WAIT_SECONDS):
    deadline = time.monotonic() + timeout_seconds
    last_error = None
    while True:
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

    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


def main():
    ignore_sigpipe()
    os.makedirs("/run/conjet", exist_ok=True)
    try:
        os.unlink("/run/conjet/docker-vsock-ready")
    except FileNotFoundError:
        pass
    wait_for_docker_ready()

    listener = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    except OSError:
        pass
    listener.bind((VMADDR_CID_ANY, VSOCK_PORT))
    listener.listen(128)
    log(f"listening on VSOCK port {VSOCK_PORT}")

    with open("/run/conjet/docker-vsock-ready", "w", encoding="utf-8") as marker:
        marker.write(f"{VSOCK_PORT}\n")

    while True:
        client, _ = listener.accept()
        threading.Thread(target=handle_client, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()

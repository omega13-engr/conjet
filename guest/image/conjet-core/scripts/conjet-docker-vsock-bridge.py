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


def handle_client(client):
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(DOCKER_SOCKET)
    except OSError as exc:
        sys.stderr.write(f"could not connect to {DOCKER_SOCKET}: {exc}\n")
        close_socket(upstream)
        close_socket(client)
        return

    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


def wait_for_docker_socket():
    while not os.path.exists(DOCKER_SOCKET):
        time.sleep(1)


def main():
    ignore_sigpipe()
    os.makedirs("/run/conjet", exist_ok=True)
    wait_for_docker_socket()

    listener = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((VMADDR_CID_ANY, VSOCK_PORT))
    listener.listen(128)

    with open("/run/conjet/docker-vsock-ready", "w", encoding="utf-8") as marker:
        marker.write(f"{VSOCK_PORT}\n")

    while True:
        client, _ = listener.accept()
        threading.Thread(target=handle_client, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()

import ConjetCore
import Foundation

public struct CloudInitSeedBuildResult: Codable, Equatable, Sendable {
    public var outputPath: String
    public var bytes: UInt64
    public var userDataBytes: Int
    public var metaDataBytes: Int

    public init(outputPath: String, bytes: UInt64, userDataBytes: Int, metaDataBytes: Int) {
        self.outputPath = outputPath
        self.bytes = bytes
        self.userDataBytes = userDataBytes
        self.metaDataBytes = metaDataBytes
    }
}

public enum CloudInitSeedBuilder {
    public static func buildDockerBootstrapSeed(
        output: URL,
        instanceID: String = "conjet-local",
        hostName: String = "conjet"
    ) throws -> CloudInitSeedBuildResult {
        try build(
            output: output,
            userData: dockerBootstrapUserData(),
            metaData: """
            instance-id: \(instanceID)
            local-hostname: \(hostName)
            """
        )
    }

    public static func build(output: URL, userData: String, metaData: String) throws -> CloudInitSeedBuildResult {
        let manager = FileManager.default
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: output.path) {
            try manager.removeItem(at: output)
        }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-cloud-init-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        let userDataURL = staging.appendingPathComponent("user-data")
        let metaDataURL = staging.appendingPathComponent("meta-data")
        try Data(userData.utf8).write(to: userDataURL, options: .atomic)
        try Data((metaData.hasSuffix("\n") ? metaData : metaData + "\n").utf8).write(to: metaDataURL, options: .atomic)

        let result = try ProcessRunner.run("/usr/bin/hdiutil", [
            "makehybrid",
            "-iso",
            "-joliet",
            "-default-volume-name", "cidata",
            "-o", output.path,
            staging.path
        ])
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        return CloudInitSeedBuildResult(
            outputPath: output.path,
            bytes: try fileSize(output),
            userDataBytes: Data(userData.utf8).count,
            metaDataBytes: Data(metaData.utf8).count
        )
    }

    public static func dockerBootstrapUserData() -> String {
        """
        #cloud-config
        package_update: true
        bootcmd:
          - [ sh, -c, "echo 'Conjet cloud-init bootcmd reached' > /dev/hvc0" ]
        write_files:
          - path: /usr/local/sbin/conjet-docker-bootstrap.sh
            permissions: '0755'
            content: |
              #!/bin/sh
              set -eux
              mkdir -p /run/conjet /mnt/conjetboot /Users /Volumes
              mount -t virtiofs conjetboot /mnt/conjetboot || true
              mount -t virtiofs conjethostusers /Users || true
              mount -t virtiofs conjethostvolumes /Volumes || true
              trap 'status=$?; cp /run/conjet/docker-bootstrap.log /mnt/conjetboot/docker-bootstrap.log 2>/dev/null || true; { echo "Conjet Docker bootstrap exit ${status}"; tail -100 /run/conjet/docker-bootstrap.log 2>/dev/null || true; } >/dev/hvc0 2>/dev/null || true' EXIT
              exec >/run/conjet/docker-bootstrap.log 2>&1
              echo "Conjet Docker bootstrap started"
              if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y ca-certificates curl docker.io e2fsprogs python3 util-linux
              elif command -v dnf >/dev/null 2>&1; then
                dnf install -y ca-certificates curl e2fsprogs moby-engine python3 util-linux || dnf install -y ca-certificates curl docker e2fsprogs python3 util-linux
              elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache ca-certificates curl docker e2fsprogs python3 util-linux
              else
                echo "unsupported package manager for Conjet Docker bootstrap" >&2
                exit 1
              fi
              cat >/usr/local/sbin/conjet-data-disk.sh <<'SH'
              #!/bin/sh
              set -eu
              DEVICE="${CONJET_DATA_DEVICE:-/dev/disk/by-id/virtio-conjet-data}"
              MOUNT_DIR="${CONJET_DATA_MOUNT:-/mnt/conjet-data}"
              MOUNT_OPTIONS="${CONJET_DATA_MOUNT_OPTIONS:-noatime,nodiratime,lazytime,nodiscard,commit=60}"
              log() { echo "conjet-data-disk: $*"; }
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
              filesystem_type() { blkid -o value -s TYPE "${DEVICE}" 2>/dev/null || true; }
              directory_empty() { [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; }
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
                else
                  mount -o "${MOUNT_OPTIONS}" "${DEVICE}" "${MOUNT_DIR}"
                fi
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
              SH
              chmod 0755 /usr/local/sbin/conjet-data-disk.sh
              if command -v systemctl >/dev/null 2>&1; then
                cat >/etc/systemd/system/conjet-data-disk.service <<'UNIT'
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
                systemctl daemon-reload
                systemctl enable --now conjet-data-disk.service
                systemctl enable --now docker || systemctl enable --now docker.service
              else
                /usr/local/sbin/conjet-data-disk.sh || true
                rc-update add docker default || true
                service docker start || true
              fi
              if [ -x /usr/bin/unpigz ]; then
                mv /usr/bin/unpigz /usr/bin/unpigz.conjet-original || true
                cat >/usr/bin/unpigz <<'SH'
              #!/bin/sh
              exec /bin/gzip -d "$@"
              SH
                chmod 0755 /usr/bin/unpigz
              fi
              cat >/usr/local/sbin/conjet-docker-vsock-bridge.py <<'PY'
              #!/usr/bin/env python3
              import os
              import signal
              import socket
              import sys
              import threading
              import time

              DOCKER_SOCKET = "/var/run/docker.sock"
              VSOCK_PORT = 2375
              AF_VSOCK = getattr(socket, "AF_VSOCK", 40)
              VMADDR_CID_ANY = getattr(socket, "VMADDR_CID_ANY", 0xFFFFFFFF)
              DOCKER_WAIT_LOG_SECONDS = 10
              CLIENT_DOCKER_WAIT_SECONDS = 30
              CAPABILITIES_PATH = b"/conjet-bridge-capabilities"
              TCP_PROXY_PREFIX = b"CONJET-TCP "
              UDP_PROXY_PREFIX = b"CONJET-UDP "

              def log(message):
                  sys.stderr.write(f"conjet-docker-vsock: {message}\\n")
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
                  body = f"Conjet guest Docker daemon is not ready: {message}\\n".encode()
                  response = (
                      b"HTTP/1.1 503 Service Unavailable\\r\\n"
                      b"Content-Type: text/plain; charset=utf-8\\r\\n"
                      b"Connection: close\\r\\n"
                      b"Content-Length: " + str(len(body)).encode() + b"\\r\\n"
                      b"\\r\\n" + body
                  )
                  try:
                      client.sendall(response)
                  except OSError:
                      pass

              def write_bridge_capabilities(client):
                  body = (
                      b'{"version":2,'
                      b'"capabilities":{"tcp_proxy":true,"udp_proxy":true,"docker_events":true,'
                      b'"container_ip_lookup":true,"port_probe":true,"proxy_metrics":true,'
                      b'"persistent_vsock":false,"tcp_mux":false,"udp_binary_frames":false,'
                      b'"tcp_binary_frames":false,"persistent_tcp_vsock":false,"tcp_vsock_pool":false,'
                      b'"bridge_engine":"python-legacy"},'
                      b'"lazy_upstream":true,"docker_ready_cache":true,'
                      b'"tcp_proxy":true,"udp_proxy":true,'
                      b'"docker_events":true,"container_ip_lookup":true,'
                      b'"port_probe":true,"proxy_metrics":true}\\n'
                  )
                  response = (
                      b"HTTP/1.1 200 OK\\r\\n"
                      b"Content-Type: application/json\\r\\n"
                      b"Connection: close\\r\\n"
                      b"Content-Length: " + str(len(body)).encode() + b"\\r\\n"
                      b"\\r\\n" + body
                  )
                  try:
                      client.sendall(response)
                  except OSError:
                      pass

              def pump(src, dst):
                  try:
                      while True:
                          data = src.recv(65536)
                          if not data:
                              break
                          dst.sendall(data)
                  except OSError:
                      pass
                  finally:
                      shutdown_write(dst)

              def read_first_client_chunk(client):
                  try:
                      return client.recv(65536)
                  except OSError:
                      return b""

              def is_bridge_capabilities_request(first_chunk):
                  request_line = first_chunk.split(b"\\r\\n", 1)[0]
                  parts = request_line.split()
                  return len(parts) >= 2 and parts[0] == b"GET" and parts[1] == CAPABILITIES_PATH

              def write_tcp_proxy_unavailable(client, message):
                  body = f"Conjet guest TCP proxy is not ready: {message}\\n".encode()
                  response = (
                      b"HTTP/1.1 502 Bad Gateway\\r\\n"
                      b"Content-Type: text/plain; charset=utf-8\\r\\n"
                      b"Connection: close\\r\\n"
                      b"Content-Length: " + str(len(body)).encode() + b"\\r\\n"
                      b"\\r\\n" + body
                  )
                  try:
                      client.sendall(response)
                  except OSError:
                      pass

              def parse_tcp_proxy_request(first_chunk):
                  line, separator, remainder = first_chunk.partition(b"\\n")
                  if not separator or not line.startswith(TCP_PROXY_PREFIX):
                      return None, None, remainder
                  target = line[len(TCP_PROXY_PREFIX):].decode("ascii", errors="ignore").strip()
                  host, separator, port_text = target.rpartition(":")
                  if not separator or host not in ("127.0.0.1", "localhost"):
                      return None, None, remainder
                  try:
                      port = int(port_text)
                  except ValueError:
                      return None, None, remainder
                  if port <= 0 or port > 65535:
                      return None, None, remainder
                  return host, port, remainder

              def parse_udp_proxy_request(first_chunk):
                  line, separator, payload = first_chunk.partition(b"\\n")
                  if not separator or not line.startswith(UDP_PROXY_PREFIX):
                      return None, None, payload
                  target = line[len(UDP_PROXY_PREFIX):].decode("ascii", errors="ignore").strip()
                  host, separator, port_text = target.rpartition(":")
                  if not separator or host not in ("127.0.0.1", "localhost"):
                      return None, None, payload
                  try:
                      port = int(port_text)
                  except ValueError:
                      return None, None, payload
                  if port <= 0 or port > 65535:
                      return None, None, payload
                  return host, port, payload

              def handle_tcp_proxy(client, first_chunk):
                  host, port, remainder = parse_tcp_proxy_request(first_chunk)
                  if host is None:
                      write_tcp_proxy_unavailable(client, "invalid TCP proxy request")
                      close_socket(client)
                      return

                  try:
                      upstream = socket.create_connection((host, port), timeout=10)
                      try:
                          upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                      except OSError:
                          pass
                  except OSError as exc:
                      write_tcp_proxy_unavailable(client, f"could not connect to {host}:{port}: {exc}")
                      close_socket(client)
                      return

                  if remainder:
                      try:
                          upstream.sendall(remainder)
                      except OSError:
                          close_socket(upstream)
                          close_socket(client)
                          return

                  left = threading.Thread(target=pump, args=(client, upstream), daemon=True)
                  right = threading.Thread(target=pump, args=(upstream, client), daemon=True)
                  left.start()
                  right.start()
                  left.join()
                  right.join()
                  close_socket(upstream)
                  close_socket(client)

              def handle_udp_proxy(client, first_chunk):
                  host, port, payload = parse_udp_proxy_request(first_chunk)
                  if host is None:
                      close_socket(client)
                      return

                  upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                  upstream.settimeout(2.0)
                  try:
                      upstream.sendto(payload, (host, port))
                      response, _ = upstream.recvfrom(65507)
                      if response:
                          client.sendall(response)
                  except OSError as exc:
                      log(f"UDP proxy failed for {host}:{port}: {exc}")
                  finally:
                      close_socket(upstream)
                      close_socket(client)

              def docker_api_ping(timeout=2.0):
                  upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                  upstream.settimeout(timeout)
                  try:
                      upstream.connect(DOCKER_SOCKET)
                      upstream.sendall(
                          b"GET /_ping HTTP/1.1\\r\\n"
                          b"Host: docker\\r\\n"
                          b"Connection: close\\r\\n"
                          b"\\r\\n"
                      )
                      response = b""
                      while True:
                          chunk = upstream.recv(4096)
                          if not chunk:
                              break
                          response += chunk
                          if b"\\r\\n\\r\\nOK" in response or response.rstrip().endswith(b"OK"):
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

              def handle(client):
                  first_chunk = read_first_client_chunk(client)
                  if not first_chunk:
                      close_socket(client)
                      return

                  if is_bridge_capabilities_request(first_chunk):
                      write_bridge_capabilities(client)
                      close_socket(client)
                      return

                  if first_chunk.startswith(TCP_PROXY_PREFIX):
                      handle_tcp_proxy(client, first_chunk)
                      return

                  if first_chunk.startswith(UDP_PROXY_PREFIX):
                      handle_udp_proxy(client, first_chunk)
                      return

                  try:
                      upstream = connect_docker_with_retry()
                  except TimeoutError as exc:
                      log(str(exc))
                      write_http_unavailable(client, str(exc))
                      close_socket(client)
                      return
                  try:
                      upstream.sendall(first_chunk)
                  except OSError:
                      close_socket(upstream)
                      close_socket(client)
                      return
                  left = threading.Thread(target=pump, args=(client, upstream), daemon=True)
                  right = threading.Thread(target=pump, args=(upstream, client), daemon=True)
                  left.start()
                  right.start()
                  left.join()
                  right.join()
                  close_socket(upstream)
                  close_socket(client)

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
                  listener.listen(1024)
              log(f"listening on VSOCK port {VSOCK_PORT}")
              open("/run/conjet/docker-vsock-ready", "w").write(str(VSOCK_PORT) + "\\n")
              while True:
                  client, _ = listener.accept()
                  threading.Thread(target=handle, args=(client,), daemon=True).start()
              PY
              chmod 0755 /usr/local/sbin/conjet-docker-vsock-bridge.py
              if command -v systemctl >/dev/null 2>&1; then
                cat >/etc/systemd/system/conjet-docker-vsock.service <<'UNIT'
              [Unit]
              Description=Conjet Docker VSOCK bridge
              After=conjet-data-disk.service containerd.service docker.service docker.socket
              Wants=conjet-data-disk.service containerd.service docker.service docker.socket

              [Service]
              Type=simple
              Environment=PYTHONUNBUFFERED=1
              ExecStartPre=/bin/sh -c 'modprobe vmw_vsock_virtio_transport 2>/dev/null || modprobe virtio_vsock 2>/dev/null || true'
              ExecStartPre=/bin/sh -c 'mkdir -p /run/conjet /mnt/conjetboot /etc/conjet; mountpoint -q /mnt/conjetboot || mount -t virtiofs conjetboot /mnt/conjetboot 2>/dev/null || true; rm -f /run/conjet/docker-vsock-ready'
              ExecStart=/bin/sh -c 'mkdir -p /run/conjet /mnt/conjetboot /etc/conjet; engine="${CONJET_NET_BRIDGE_ENGINE:-$(cat /mnt/conjetboot/network-bridge-engine 2>/dev/null || cat /etc/conjet/network-bridge-engine 2>/dev/null || echo python-legacy)}"; case "$engine" in auto|python|python-legacy|"") exec /usr/local/sbin/conjet-docker-vsock-bridge.py 2>&1 ;; conjet-netd|conjet-netd-c) if [ -x /usr/local/sbin/conjet-netd ]; then exec /usr/local/sbin/conjet-netd 2>&1; else echo "conjet-netd-c requested but /usr/local/sbin/conjet-netd is missing" >&2; exit 42; fi ;; *) echo "unsupported CONJET_NET_BRIDGE_ENGINE=$engine" >&2; exit 43 ;; esac | /usr/bin/tee -a /run/conjet/docker-vsock.log /dev/hvc0'
              Restart=always
              RestartSec=2
              StandardOutput=journal
              StandardError=journal

              [Install]
              WantedBy=multi-user.target
              UNIT
                systemctl daemon-reload
                systemctl enable --now conjet-docker-vsock.service
              else
                nohup /usr/local/sbin/conjet-docker-vsock-bridge.py >/run/conjet/docker-vsock.log 2>&1 &
              fi
              echo ready > /run/conjet/docker-bootstrap-ready
              cp /run/conjet/docker-bootstrap.log /mnt/conjetboot/docker-bootstrap.log 2>/dev/null || true
              echo "Conjet Docker bootstrap ready" >/dev/hvc0 2>/dev/null || true
        runcmd:
          - [ /usr/local/sbin/conjet-docker-bootstrap.sh ]
        final_message: "Conjet cloud-init Docker bootstrap finished"
        """
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? UInt64 ?? 0
    }
}

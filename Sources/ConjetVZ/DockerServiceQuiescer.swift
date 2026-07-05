import ConjetCore
import Foundation

struct DockerServiceQuiescer {
    private static let helperImage = "ubuntu:24.04"

    var socketPath: String
    var dockerExecutable: String = "/usr/bin/env"
    var runner: (String, [String], TimeInterval) throws -> ProcessResult = { executable, arguments, timeout in
        try ProcessRunner.run(executable, arguments, timeoutSeconds: timeout)
    }

    func quiesceForVMStop(timeoutSeconds: TimeInterval = 8) throws {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return
        }

        let result = try runner(
            dockerExecutable,
            dockerRunArguments(script: Self.quiesceScript),
            timeoutSeconds
        )

        guard result.succeeded || Self.isExpectedDockerShutdown(result) else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }

        waitUntilDockerStops(timeoutSeconds: max(1, timeoutSeconds - 1))
    }

    func ensureGuestMemorySetup(timeoutSeconds: TimeInterval = 18) throws -> String {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return "guest Docker socket is unavailable; skipped guest memory setup"
        }

        let result = try runner(
            dockerExecutable,
            dockerRunArguments(script: Self.memorySetupScript, pullPolicy: "missing"),
            timeoutSeconds
        )

        guard result.succeeded else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "guest memory setup skipped: helper exited with code \(result.exitCode)"
            }
            return "guest memory setup skipped: \(detail)"
        }

        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dockerRunArguments(script: String, pullPolicy: String? = nil) -> [String] {
        var arguments = [
            "docker",
            "--host", "unix://\(socketPath)",
            "run",
            "--rm",
            "--privileged",
            "--pid=host",
            "--net=host",
            "--ipc=host",
            "--uts=host",
        ]
        if let pullPolicy {
            arguments += ["--pull", pullPolicy]
        }
        arguments += [
            Self.helperImage,
            "nsenter",
            "-t", "1",
            "-m",
            "-u",
            "-i",
            "-n",
            "-p",
            "--",
            "sh",
            "-lc",
            script
        ]
        return arguments
    }

    private func waitUntilDockerStops(timeoutSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let result = try? runner(
                dockerExecutable,
                [
                    "docker",
                    "--host", "unix://\(socketPath)",
                    "info"
                ],
                1
            )
            if result?.succeeded != true {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func isExpectedDockerShutdown(_ result: ProcessResult) -> Bool {
        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        return output.contains("cannot connect to the docker daemon")
            || output.contains("connection refused")
            || output.contains("connection reset")
            || output.contains("broken pipe")
            || output.contains("no such file or directory")
    }

    private static let quiesceScript = """
    set -eu
    cat >/run/conjet-docker-quiesce.sh <<'SH'
    #!/bin/sh
    set +e
    emit() {
      action="$1"
      id="$2"
      reason="$3"
      backup="${4:-}"
      printf 'conjet-docker-metadata\t%s\t%s\t%s\t%s\n' "$action" "$id" "$reason" "$backup"
    }
    containerd_has_container_or_task() {
      id="$1"
      ctr -n moby containers info "$id" >/dev/null 2>&1 && return 0
      ctr -n moby tasks ls 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fx "$id" >/dev/null 2>&1
    }
    repair_stale_metadata() {
      containers_dir="/var/lib/docker/containers"
      [ -d "$containers_dir" ] || return 0
      command -v docker >/dev/null 2>&1 || return 0
      command -v ctr >/dev/null 2>&1 || return 0
      candidate_file="$(mktemp)"
      repaired_file="$(mktemp)"
      docker ps -a --no-trunc --format '{{.ID}}' >"$candidate_file" 2>/dev/null || {
        rm -f "$candidate_file" "$repaired_file"
        return 0
      }
      [ -s "$candidate_file" ] || {
        rm -f "$candidate_file" "$repaired_file"
        return 0
      }
      backup_base="$containers_dir/.conjet-stale-backup/$(date -u +%Y%m%dT%H%M%SZ)"
      sort -u "$candidate_file" | while IFS= read -r id; do
        [ -n "$id" ] || continue
        case "$id" in
          *[!0123456789abcdefABCDEF]*)
            emit skipped "$id" invalid-container-id ""
            continue
            ;;
        esac
        docker inspect "$id" >/dev/null 2>&1 && {
          emit healthy "$id" inspect-ok ""
          continue
        }
        containerd_has_container_or_task "$id" && {
          emit skipped "$id" containerd-object-present ""
          continue
        }
        dir="$containers_dir/$id"
        [ -d "$dir" ] || {
          emit skipped "$id" docker-container-dir-missing ""
          continue
        }
        mkdir -p "$backup_base"
        backup="$backup_base/$id.tgz"
        tar -czf "$backup" -C "$containers_dir" "$id"
        rm -rf "$dir"
        printf '.\n' >>"$repaired_file"
        emit repaired "$id" backed-up-and-removed-stale-docker-metadata "$backup"
      done
      repaired="$(wc -l <"$repaired_file" | tr -d ' ')"
      rm -f "$candidate_file" "$repaired_file"
      [ "$repaired" -gt 0 ] && echo "conjet-docker-quiesce: repaired $repaired stale Docker metadata record(s)"
      return 0
    }
    mkdir -p /run/conjet /var/lib/docker
    repair_stale_metadata >>/run/conjet/docker-quiesce.log 2>&1
    if [ -x /usr/local/sbin/conjet-docker-service-guard.sh ]; then
      /usr/local/sbin/conjet-docker-service-guard.sh mark-stop
    else
      date -u +%Y-%m-%dT%H:%M:%SZ >/var/lib/docker/.conjet-clean-shutdown
    fi
    systemctl stop docker.socket docker.service containerd.service
    SH
    chmod 0755 /run/conjet-docker-quiesce.sh
    if command -v systemd-run >/dev/null 2>&1; then
      systemd-run --unit=conjet-docker-quiesce --collect --no-block /run/conjet-docker-quiesce.sh
    else
      nohup /run/conjet-docker-quiesce.sh >/run/conjet/docker-quiesce.log 2>&1 &
    fi
    """

    private static let memorySetupScript = """
    set +e
    mkdir -p /run/conjet
    log=/run/conjet/memory-setup.log
    zram_result=skipped
    disk_swap_result=missing

    log_line() {
      printf 'conjet-memory-setup: %s\\n' "$*" >>"$log" 2>/dev/null
    }

    mem_total_bytes() {
      awk '/^MemTotal:/ { printf "%.0f\\n", $2 * 1024; exit }' /proc/meminfo 2>/dev/null || echo 0
    }

    default_zram_bytes() {
      total="$(mem_total_bytes)"
      if [ "$total" -le 0 ] 2>/dev/null; then
        echo 1073741824
      else
        echo "$total"
      fi
    }

    wait_for_block() {
      dev="$1"
      i=0
      while [ "$i" -lt 50 ]; do
        [ -b "$dev" ] && return 0
        i=$((i + 1))
        sleep 0.02
      done
      return 1
    }

    is_swap_active() {
      dev="$1"
      real="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"
      awk -v dev="$dev" -v real="$real" 'NR > 1 && ($1 == dev || $1 == real) { found = 1 } END { exit found ? 0 : 1 }' /proc/swaps 2>/dev/null
    }

    setup_zram() {
      size="${CONJET_ZRAM_SIZE_BYTES:-$(default_zram_bytes)}"
      [ "$size" -gt 0 ] 2>/dev/null || {
        zram_result=disabled
        return
      }

      modprobe zram num_devices=1 >/dev/null 2>&1
      if [ -b /dev/zram0 ]; then
        dev=/dev/zram0
      elif [ -e /sys/class/zram-control/hot_add ]; then
        id="$(cat /sys/class/zram-control/hot_add 2>/dev/null || echo 0)"
        dev="/dev/zram${id}"
      else
        zram_result=unavailable
        return
      fi

      if ! wait_for_block "$dev"; then
        zram_result=unavailable
        return
      fi
      if is_swap_active "$dev"; then
        zram_result=already-active
        return
      fi

      name="$(basename "$dev")"
      if [ -e "/sys/block/${name}/comp_algorithm" ]; then
        echo "${CONJET_ZRAM_ALGO:-lz4}" >"/sys/block/${name}/comp_algorithm" 2>/dev/null || true
      fi
      if ! echo "$size" >"/sys/block/${name}/disksize" 2>/dev/null; then
        zram_result=configure-failed
        return
      fi
      if mkswap "$dev" >/dev/null 2>&1 && swapon -p 32767 "$dev" >/dev/null 2>&1; then
        zram_result=enabled
      else
        zram_result=failed
      fi
    }

    swap_candidate() {
      for dev in /dev/disk/by-id/virtio-conjet-swap /dev/disk/by-label/conjet-swap; do
        if [ -b "$dev" ]; then
          printf '%s\\n' "$dev"
          return 0
        fi
      done
      return 1
    }

    setup_disk_swap() {
      dev="$(swap_candidate 2>/dev/null || true)"
      [ -n "$dev" ] || {
        disk_swap_result=missing
        return
      }
      if is_swap_active "$dev"; then
        disk_swap_result=already-active
        return
      fi
      if ! blkid "$dev" 2>/dev/null | grep -q 'TYPE="swap"'; then
        if ! mkswap -L conjet-swap "$dev" >/dev/null 2>&1; then
          disk_swap_result=format-failed
          return
        fi
      fi
      if swapon -p 1 "$dev" >/dev/null 2>&1; then
        disk_swap_result=enabled
      else
        disk_swap_result=failed
      fi
    }

    log_line start
    setup_zram
    setup_disk_swap
    {
      printf 'zram=%s disk_swap=%s\\n' "$zram_result" "$disk_swap_result"
      cat /proc/swaps 2>/dev/null
    } >>"$log" 2>/dev/null
    printf 'guest memory setup: zram=%s disk_swap=%s\\n' "$zram_result" "$disk_swap_result"
    """
}

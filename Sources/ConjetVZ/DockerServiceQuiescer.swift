import ConjetCore
import Foundation

struct DockerServiceQuiescer {
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

    func dockerRunArguments(script: String) -> [String] {
        [
            "docker",
            "--host", "unix://\(socketPath)",
            "run",
            "--rm",
            "--privileged",
            "--pid=host",
            "--net=host",
            "--ipc=host",
            "--uts=host",
            "ubuntu:24.04",
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
}

import Foundation

public enum DockerMetadataRepairAction: String, Codable, Equatable, Sendable {
    case healthy
    case stale
    case repaired
    case skipped
}

public struct DockerMetadataRepairRecord: Codable, Equatable, Sendable {
    public var containerID: String
    public var action: DockerMetadataRepairAction
    public var reason: String
    public var backupPath: String?

    public init(
        containerID: String,
        action: DockerMetadataRepairAction,
        reason: String,
        backupPath: String? = nil
    ) {
        self.containerID = containerID
        self.action = action
        self.reason = reason
        self.backupPath = backupPath
    }
}

public struct DockerMetadataRepairResult: Codable, Equatable, Sendable {
    public var dockerContext: String
    public var dryRun: Bool
    public var project: String?
    public var records: [DockerMetadataRepairRecord]
    public var stdoutTail: String
    public var stderrTail: String

    public init(
        dockerContext: String,
        dryRun: Bool,
        project: String?,
        records: [DockerMetadataRepairRecord],
        stdoutTail: String,
        stderrTail: String
    ) {
        self.dockerContext = dockerContext
        self.dryRun = dryRun
        self.project = project
        self.records = records
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }

    public var staleCount: Int {
        records.filter { $0.action == .stale }.count
    }

    public var repairedCount: Int {
        records.filter { $0.action == .repaired }.count
    }
}

public struct DockerMetadataRepairer {
    public var dockerContext: String
    public var dockerExecutable: String

    private let runner: (String, [String]) throws -> ProcessResult

    public init(
        dockerContext: String,
        dockerExecutable: String = "/usr/bin/env",
        runner: @escaping (String, [String]) throws -> ProcessResult = ProcessRunner.run
    ) {
        self.dockerContext = dockerContext
        self.dockerExecutable = dockerExecutable
        self.runner = runner
    }

    public func repair(
        dryRun: Bool = true,
        project: String? = nil,
        containerIDs: [String] = []
    ) throws -> DockerMetadataRepairResult {
        try validate(project: project, containerIDs: containerIDs)
        let result = try runner(dockerExecutable, dockerArguments(dryRun: dryRun, project: project, containerIDs: containerIDs))
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return DockerMetadataRepairResult(
            dockerContext: dockerContext,
            dryRun: dryRun,
            project: project,
            records: Self.parseRecords(result.stdout),
            stdoutTail: tail(result.stdout),
            stderrTail: tail(result.stderr)
        )
    }

    public func dockerArguments(
        dryRun: Bool = true,
        project: String? = nil,
        containerIDs: [String] = []
    ) -> [String] {
        [
            "docker",
            "--context", dockerContext,
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
            "-c",
            Self.repairScript,
            "conjet-docker-metadata-repair",
            dryRun ? "dry-run" : "repair",
            project ?? "-"
        ] + containerIDs
    }

    public static func parseRecords(_ stdout: String) -> [DockerMetadataRepairRecord] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts[0] == "conjet-docker-metadata" else { return nil }
            return DockerMetadataRepairRecord(
                containerID: parts[2],
                action: DockerMetadataRepairAction(rawValue: parts[1]) ?? .skipped,
                reason: parts.count > 3 ? parts[3] : "",
                backupPath: parts.count > 4 && !parts[4].isEmpty ? parts[4] : nil
            )
        }
    }

    private func validate(project: String?, containerIDs: [String]) throws {
        if let project, !project.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) {
            throw ConjetError.invalidArgument("--project may only contain letters, numbers, '.', '_', or '-'")
        }
        for id in containerIDs {
            guard id.count >= 12, id.count <= 64, id.allSatisfy(\.isHexDigit) else {
                throw ConjetError.invalidArgument("--id must be a 12-64 character hexadecimal container id")
            }
        }
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }

    private static let repairScript = """
    set -eu
    mode="${1:-dry-run}"
    project="${2:--}"
    shift 2 || true
    candidate_file="$(mktemp)"
    trap 'rm -f "$candidate_file"' EXIT

    if [ "$#" -gt 0 ]; then
      for id in "$@"; do
        case "$id" in
          *[!0123456789abcdefABCDEF]*|"") continue ;;
        esac
        printf '%s\\n' "$id" >> "$candidate_file"
      done
    elif [ "$project" != "-" ]; then
      docker ps -a --no-trunc --filter "label=com.docker.compose.project=$project" --format '{{.ID}}' > "$candidate_file"
    else
      docker ps -a --no-trunc --format '{{.ID}}' > "$candidate_file"
    fi

    if [ ! -s "$candidate_file" ]; then
      exit 0
    fi

    backup_base="/var/lib/docker/containers/.conjet-stale-backup/$(date -u +%Y%m%dT%H%M%SZ)"
    if ! command -v ctr >/dev/null 2>&1; then
      sort -u "$candidate_file" | while IFS= read -r id; do
        [ -n "$id" ] || continue
        printf 'conjet-docker-metadata\\tskipped\\t%s\\tcontainerd-cli-missing\\t\\n' "$id"
      done
      exit 0
    fi

    sort -u "$candidate_file" | while IFS= read -r id; do
      [ -n "$id" ] || continue
      if docker inspect "$id" >/dev/null 2>&1; then
        printf 'conjet-docker-metadata\\thealthy\\t%s\\tinspect-ok\\t\\n' "$id"
        continue
      fi
      if ctr -n moby containers info "$id" >/dev/null 2>&1; then
        printf 'conjet-docker-metadata\\tskipped\\t%s\\tcontainerd-container-present\\t\\n' "$id"
        continue
      fi
      if ctr -n moby tasks ls 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fx "$id" >/dev/null 2>&1; then
        printf 'conjet-docker-metadata\\tskipped\\t%s\\tcontainerd-task-present\\t\\n' "$id"
        continue
      fi
      dir="/var/lib/docker/containers/$id"
      if [ ! -d "$dir" ]; then
        printf 'conjet-docker-metadata\\tskipped\\t%s\\tdocker-container-dir-missing\\t\\n' "$id"
        continue
      fi
      if [ "$mode" = "dry-run" ]; then
        printf 'conjet-docker-metadata\\tstale\\t%s\\tdocker-list-without-inspect-or-containerd\\t%s/%s.tgz\\n' "$id" "$backup_base" "$id"
        continue
      fi
      mkdir -p "$backup_base"
      tar -czf "$backup_base/$id.tgz" -C /var/lib/docker/containers "$id"
      rm -rf "$dir"
      printf 'conjet-docker-metadata\\trepaired\\t%s\\tbacked-up-and-removed-stale-docker-metadata\\t%s/%s.tgz\\n' "$id" "$backup_base" "$id"
    done
    """
}

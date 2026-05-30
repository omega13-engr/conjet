import Foundation

public struct HostShareMountResult: Codable, Equatable, Sendable {
    public var dockerContext: String
    public var mountedPaths: [String]
    public var stdoutTail: String
    public var stderrTail: String

    public init(dockerContext: String, mountedPaths: [String], stdoutTail: String, stderrTail: String) {
        self.dockerContext = dockerContext
        self.mountedPaths = mountedPaths
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }
}

public struct HostShareMounter {
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

    public func ensureMounted() throws -> HostShareMountResult {
        let result = try runner(dockerExecutable, dockerArguments())
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return HostShareMountResult(
            dockerContext: dockerContext,
            mountedPaths: ["/Users", "/Volumes"],
            stdoutTail: tail(result.stdout),
            stderrTail: tail(result.stderr)
        )
    }

    public func dockerArguments() -> [String] {
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
            Self.mountScript
        ]
    }

    private static let mountScript = """
    set -eu
    mount_share() {
      tag="$1"
      target="$2"
      mkdir -p "$target"
      if mountpoint -q "$target"; then
        echo "$target already mounted"
        return 0
      fi
      mount -t virtiofs "$tag" "$target"
      mountpoint -q "$target"
      echo "$target mounted"
    }
    mount_share conjethostusers /Users
    mount_share conjethostvolumes /Volumes
    """

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

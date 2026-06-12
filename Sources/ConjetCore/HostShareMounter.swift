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
    public var includeRemovableVolumes: Bool
    public var timeoutSeconds: Double?

    private let runner: (String, [String], Double?) throws -> ProcessResult

    public init(
        dockerContext: String,
        dockerExecutable: String = "/usr/bin/env",
        includeRemovableVolumes: Bool = false,
        timeoutSeconds: Double? = 30
    ) {
        self.dockerContext = dockerContext
        self.dockerExecutable = dockerExecutable
        self.includeRemovableVolumes = includeRemovableVolumes
        self.timeoutSeconds = timeoutSeconds
        self.runner = { executable, arguments, timeoutSeconds in
            try ProcessRunner.run(executable, arguments, timeoutSeconds: timeoutSeconds)
        }
    }

    public init(
        dockerContext: String,
        dockerExecutable: String = "/usr/bin/env",
        includeRemovableVolumes: Bool = false,
        timeoutSeconds: Double? = 30,
        runner: @escaping (String, [String]) throws -> ProcessResult
    ) {
        self.dockerContext = dockerContext
        self.dockerExecutable = dockerExecutable
        self.includeRemovableVolumes = includeRemovableVolumes
        self.timeoutSeconds = timeoutSeconds
        self.runner = { executable, arguments, _ in
            try runner(executable, arguments)
        }
    }

    public func ensureMounted() throws -> HostShareMountResult {
        let result = try runner(dockerExecutable, dockerArguments(), timeoutSeconds)
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        var mountedPaths = ["/Users"]
        if includeRemovableVolumes {
            mountedPaths.append("/Volumes")
        }
        return HostShareMountResult(
            dockerContext: dockerContext,
            mountedPaths: mountedPaths,
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
            Self.mountScript(includeRemovableVolumes: includeRemovableVolumes)
        ]
    }

    private static func mountScript(includeRemovableVolumes: Bool) -> String {
        var lines = [
            "set -eu",
            "mount_share() {",
            "  tag=\"$1\"",
            "  target=\"$2\"",
            "  mkdir -p \"$target\"",
            "  if mountpoint -q \"$target\"; then",
            "    echo \"$target already mounted\"",
            "    return 0",
            "  fi",
            "  mount -t virtiofs \"$tag\" \"$target\"",
            "  mountpoint -q \"$target\"",
            "  echo \"$target mounted\"",
            "}",
            "mount_share conjethostusers /Users"
        ]
        if includeRemovableVolumes {
            lines.append("mount_share conjethostvolumes /Volumes")
        }
        return lines.joined(separator: "\n")
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

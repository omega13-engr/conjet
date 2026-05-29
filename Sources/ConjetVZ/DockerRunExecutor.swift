import ConjetCore
import Foundation

public struct DockerRunExecutor: Sendable {
    public var dockerCLIPath: String
    public var socketPath: String

    public init(dockerCLIPath: String = "/opt/homebrew/bin/docker", socketPath: String) {
        self.dockerCLIPath = dockerCLIPath
        self.socketPath = socketPath
    }

    public func run(image: String, command: [String]) throws -> DockerRunResult {
        let dockerHost = "unix://\(socketPath)"
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return DockerRunResult(
                image: image,
                command: command,
                dockerHost: dockerHost,
                exitCode: nil,
                stderrTail: "Conjet Docker socket is not available yet at \(socketPath). Boot the VM and install the guest Docker bridge first."
            )
        }
        guard FileManager.default.isExecutableFile(atPath: dockerCLIPath) else {
            throw ConjetError.unavailable("docker CLI not found at \(dockerCLIPath)")
        }

        let result = try ProcessRunner.run(dockerCLIPath, ["--host", dockerHost, "run", "--rm", image] + command)
        return DockerRunResult(
            image: image,
            command: command,
            dockerHost: dockerHost,
            exitCode: result.exitCode,
            stdoutTail: tail(result.stdout),
            stderrTail: tail(result.stderr)
        )
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

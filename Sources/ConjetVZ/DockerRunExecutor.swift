import ConjetCore
import Foundation

public typealias DockerProcessRunner = @Sendable (String, [String]) throws -> ProcessResult
public typealias DockerComposeSupportChecker = @Sendable (String) -> Bool

public struct DockerCLIInvocation: Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case docker
        case dockerCompose
    }

    public var kind: Kind
    public var executable: String

    public init(kind: Kind, executable: String) {
        self.kind = kind
        self.executable = executable
    }
}

public enum DockerCLIResolver {
    public static func docker(preferredPath: String? = nil) throws -> String {
        if let preferredPath, FileManager.default.isExecutableFile(atPath: preferredPath) {
            return preferredPath
        }

        for candidate in dockerCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        throw ConjetError.unavailable("docker CLI not found; install Docker CLI or add it to a standard Conjet search path")
    }

    public static func compose(
        preferredDockerPath: String? = nil,
        preferredDockerComposePath: String? = nil,
        composeSupportChecker: DockerComposeSupportChecker = DockerCLIResolver.dockerSupportsCompose
    ) throws -> DockerCLIInvocation {
        if let preferredDockerPath,
           FileManager.default.isExecutableFile(atPath: preferredDockerPath),
           composeSupportChecker(preferredDockerPath) {
            return DockerCLIInvocation(kind: .docker, executable: preferredDockerPath)
        }

        if let preferredDockerComposePath,
           FileManager.default.isExecutableFile(atPath: preferredDockerComposePath) {
            return DockerCLIInvocation(kind: .dockerCompose, executable: preferredDockerComposePath)
        }

        for candidate in dockerCandidates
            where FileManager.default.isExecutableFile(atPath: candidate) && composeSupportChecker(candidate) {
            return DockerCLIInvocation(kind: .docker, executable: candidate)
        }

        for candidate in dockerComposeCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return DockerCLIInvocation(kind: .dockerCompose, executable: candidate)
        }

        throw ConjetError.unavailable("docker compose CLI not found; install Docker CLI with compose support")
    }

    public static func dockerSupportsCompose(_ dockerPath: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: dockerPath) else {
            return false
        }
        let result = try? ProcessRunner.run(dockerPath, ["compose", "version"], timeoutSeconds: 2)
        return result?.succeeded == true
    }

    private static let dockerCandidates = [
        "/opt/homebrew/bin/docker",
        "/usr/local/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker"
    ]

    private static let dockerComposeCandidates = [
        "/opt/homebrew/bin/docker-compose",
        "/usr/local/bin/docker-compose",
        "/Applications/Docker.app/Contents/Resources/bin/docker-compose"
    ]
}

public struct DockerRunExecutor: Sendable {
    public var dockerCLIPath: String?
    public var socketPath: String
    public var requestedBackend: ConjetVMBackend
    public var rosettaAvailable: Bool
    private let runner: DockerProcessRunner

    public init(
        dockerCLIPath: String? = nil,
        socketPath: String,
        requestedBackend: ConjetVMBackend = .hvfExperimental,
        rosettaAvailable: Bool = HostCapabilities.detect().rosettaLinuxSupportLikelyAvailable,
        runner: @escaping DockerProcessRunner = ProcessRunner.run
    ) {
        self.dockerCLIPath = dockerCLIPath
        self.socketPath = socketPath
        self.requestedBackend = requestedBackend
        self.rosettaAvailable = rosettaAvailable
        self.runner = runner
    }

    public func run(image: String, command: [String], platform: String? = nil) throws -> DockerRunResult {
        let dockerHost = "unix://\(socketPath)"
        let route = DockerRunPlatformRoute.resolve(
            platform: platform,
            requestedBackend: requestedBackend,
            rosettaAvailable: rosettaAvailable
        )
        if !route.supported || route.fallbackUsed {
            return DockerRunResult(
                image: image,
                command: command,
                dockerHost: dockerHost,
                exitCode: nil,
                stderrTail: dockerRunPlatformRejectionMessage(route)
            )
        }

        guard FileManager.default.fileExists(atPath: socketPath) else {
            return DockerRunResult(
                image: image,
                command: command,
                dockerHost: dockerHost,
                exitCode: nil,
                stderrTail: "Conjet Docker socket is not available yet at \(socketPath). Boot the VM and install the guest Docker bridge first."
            )
        }

        let docker = try DockerCLIResolver.docker(preferredPath: dockerCLIPath)
        let platformArguments = route.dockerPlatformArgument.map { ["--platform", $0] } ?? []
        let result = try runner(docker, ["--host", dockerHost, "run", "--rm"] + platformArguments + [image] + command)
        return DockerRunResult(
            image: image,
            command: command,
            dockerHost: dockerHost,
            exitCode: result.exitCode,
            stdoutTail: dockerOutputTail(result.stdout),
            stderrTail: dockerOutputTail(result.stderr)
        )
    }
}

private func dockerRunPlatformRejectionMessage(_ route: DockerRunPlatformRoute) -> String {
    if route.fallbackUsed {
        return "\(route.message). Switch Conjet to the VZ backend before running linux/amd64 workloads, or use linux/arm64 on Conjet Core Rust HVF."
    }
    return route.message
}

private struct DockerRunPlatformRoute: Equatable, Sendable {
    var dockerPlatformArgument: String?
    var supported: Bool
    var fallbackUsed: Bool
    var message: String

    static func resolve(
        platform: String?,
        requestedBackend: ConjetVMBackend,
        rosettaAvailable: Bool
    ) -> DockerRunPlatformRoute {
        guard let platform, !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DockerRunPlatformRoute(dockerPlatformArgument: nil, supported: true, fallbackUsed: false, message: "native platform")
        }
        switch platform.lowercased() {
        case "linux/arm64", "linux/arm64/v8", "arm64", "aarch64":
            return DockerRunPlatformRoute(dockerPlatformArgument: "linux/arm64", supported: true, fallbackUsed: false, message: "linux/arm64 supported")
        case "linux/amd64", "amd64", "x86_64":
            if requestedBackend == .hvfExperimental {
                return DockerRunPlatformRoute(
                    dockerPlatformArgument: nil,
                    supported: false,
                    fallbackUsed: true,
                    message: "linux/amd64 requires VZ fallback with Rosetta"
                )
            }
            guard rosettaAvailable else {
                return DockerRunPlatformRoute(
                    dockerPlatformArgument: nil,
                    supported: false,
                    fallbackUsed: false,
                    message: "linux/amd64 requires Rosetta support, but Rosetta support was not detected"
                )
            }
            return DockerRunPlatformRoute(dockerPlatformArgument: "linux/amd64", supported: true, fallbackUsed: false, message: "linux/amd64 supported by VZ Rosetta")
        default:
            return DockerRunPlatformRoute(
                dockerPlatformArgument: nil,
                supported: false,
                fallbackUsed: false,
                message: "container platform is unknown or unsupported: \(platform)"
            )
        }
    }
}

public struct DockerComposeExecutor: Sendable {
    public var dockerCLIPath: String?
    public var dockerComposeCLIPath: String?
    public var socketPath: String
    private let composeSupportChecker: DockerComposeSupportChecker
    private let runner: DockerProcessRunner

    public init(
        dockerCLIPath: String? = nil,
        dockerComposeCLIPath: String? = nil,
        socketPath: String,
        composeSupportChecker: @escaping DockerComposeSupportChecker = DockerCLIResolver.dockerSupportsCompose,
        runner: @escaping DockerProcessRunner = ProcessRunner.run
    ) {
        self.dockerCLIPath = dockerCLIPath
        self.dockerComposeCLIPath = dockerComposeCLIPath
        self.socketPath = socketPath
        self.composeSupportChecker = composeSupportChecker
        self.runner = runner
    }

    public func up(arguments: [String]) throws -> DockerComposeResult {
        guard Self.containsUpCommand(arguments) else {
            throw ConjetError.invalidArgument("docker-compose requires an 'up' command")
        }

        let dockerHost = "unix://\(socketPath)"
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return DockerComposeResult(
                arguments: arguments,
                dockerHost: dockerHost,
                executable: "",
                exitCode: nil,
                stderrTail: "Conjet Docker socket is not available yet at \(socketPath). Boot the VM and install the guest Docker bridge first."
            )
        }

        let invocation = try DockerCLIResolver.compose(
            preferredDockerPath: dockerCLIPath,
            preferredDockerComposePath: dockerComposeCLIPath,
            composeSupportChecker: composeSupportChecker
        )
        let processArguments: [String]
        switch invocation.kind {
        case .docker:
            processArguments = ["--host", dockerHost, "compose"] + arguments
        case .dockerCompose:
            processArguments = ["--host", dockerHost] + arguments
        }

        let result = try runner(invocation.executable, processArguments)
        return DockerComposeResult(
            arguments: arguments,
            dockerHost: dockerHost,
            executable: invocation.executable,
            invocationKind: invocation.dockerComposeResultKind,
            exitCode: result.exitCode,
            stdoutTail: dockerOutputTail(result.stdout),
            stderrTail: dockerOutputTail(result.stderr)
        )
    }

    public static func containsUpCommand(_ arguments: [String]) -> Bool {
        arguments.contains("up")
    }
}

private extension DockerCLIInvocation {
    var dockerComposeResultKind: DockerComposeInvocationKind {
        switch kind {
        case .docker:
            return .dockerPlugin
        case .dockerCompose:
            return .dockerCompose
        }
    }
}

private func dockerOutputTail(_ text: String, limit: Int = 4096) -> String {
    if text.count <= limit { return text }
    return String(text.suffix(limit))
}

import Foundation

public enum DockerContextAction: String, Codable, Equatable, Sendable {
    case created
    case updated
    case unchanged
}

public struct DockerContextResult: Codable, Equatable, Sendable {
    public var contextName: String
    public var dockerHost: String
    public var action: DockerContextAction
    public var madeCurrent: Bool
}

public struct DockerContextManager {
    public var contextName: String
    public var runner: (String, [String]) throws -> ProcessResult

    public init(
        contextName: String = "conjet",
        runner: @escaping (String, [String]) throws -> ProcessResult = ProcessRunner.run
    ) {
        self.contextName = contextName
        self.runner = runner
    }

    public func ensureContext(socketPath: String, makeCurrent: Bool = true) throws -> DockerContextResult {
        let dockerHost = "unix://\(socketPath)"
        let action: DockerContextAction
        let inspect = try runDocker(["context", "inspect", contextName, "--format", "{{json .Endpoints.docker.Host}}"])

        if inspect.succeeded {
            let existingHost = dockerHostFromInspectOutput(inspect.stdout)
            if existingHost == dockerHost {
                action = .unchanged
            } else {
                try requireSuccess(runDocker([
                    "context", "update", contextName,
                    "--description", "Conjet",
                    "--docker", "host=\(dockerHost)"
                ]))
                action = .updated
            }
        } else {
            try requireSuccess(runDocker([
                "context", "create", contextName,
                "--description", "Conjet",
                "--docker", "host=\(dockerHost)"
            ]))
            action = .created
        }

        if makeCurrent {
            try requireSuccess(runDocker(["context", "use", contextName]))
        }

        return DockerContextResult(
            contextName: contextName,
            dockerHost: dockerHost,
            action: action,
            madeCurrent: makeCurrent
        )
    }

    private func runDocker(_ arguments: [String]) throws -> ProcessResult {
        try runner("/usr/bin/env", ["docker"] + arguments)
    }

    private func requireSuccess(_ result: ProcessResult) throws {
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    private func dockerHostFromInspectOutput(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else {
            return nil
        }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

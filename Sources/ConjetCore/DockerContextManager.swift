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
    public var buildxBuilderName: String?
    public var buildxBuilderAction: DockerContextAction?
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

    public func ensureContext(
        socketPath: String,
        makeCurrent: Bool = true,
        configureBuildxBuilder: Bool = true
    ) throws -> DockerContextResult {
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
        let buildxBuilder = configureBuildxBuilder
            ? try ensureBuildxBuilder(forContext: contextName, makeCurrent: makeCurrent)
            : nil

        return DockerContextResult(
            contextName: contextName,
            dockerHost: dockerHost,
            action: action,
            madeCurrent: makeCurrent,
            buildxBuilderName: buildxBuilder?.name,
            buildxBuilderAction: buildxBuilder?.action
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

    private func ensureBuildxBuilder(
        forContext contextName: String,
        makeCurrent: Bool
    ) throws -> (name: String, action: DockerContextAction)? {
        guard try buildxIsAvailable() else {
            return nil
        }

        let builderName = contextName
        let inspect = try runDocker(["buildx", "inspect", builderName, "--timeout", "2s"])
        if inspect.succeeded {
            let driver = buildxField(named: "Driver", from: inspect.stdout)
            let endpoint = buildxField(named: "Endpoint", from: inspect.stdout)
            guard driver == "docker",
                  endpoint == nil || endpoint == contextName else {
                throw ConjetError.processFailed(
                    executable: inspect.executable,
                    exitCode: inspect.exitCode,
                    stderr: "Buildx builder \(builderName) is not the Docker driver for context \(contextName)"
                )
            }
            try selectBuildxBuilder(named: builderName, makeCurrent: makeCurrent)
            return (builderName, .unchanged)
        }

        throw ConjetError.processFailed(
            executable: inspect.executable,
            exitCode: inspect.exitCode,
            stderr: inspect.stderr.isEmpty
                ? "Buildx context builder \(builderName) was not available"
                : inspect.stderr
        )
    }

    private func buildxIsAvailable() throws -> Bool {
        let version = try runDocker(["buildx", "version"])
        if version.succeeded {
            return true
        }

        let output = "\(version.stdout)\n\(version.stderr)"
        if output.localizedCaseInsensitiveContains("unknown command") ||
            output.localizedCaseInsensitiveContains("not a docker command") {
            return false
        }

        throw ConjetError.processFailed(
            executable: version.executable,
            exitCode: version.exitCode,
            stderr: version.stderr
        )
    }

    private func selectBuildxBuilder(named builderName: String, makeCurrent: Bool) throws {
        guard makeCurrent else { return }
        try requireSuccess(runDocker(["buildx", "use", "--default", builderName]))
    }

    private func buildxField(named field: String, from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == field else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

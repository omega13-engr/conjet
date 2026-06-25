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
    public var buildkitMaxParallelism: Int
    public var buildkitConfigDirectory: URL?
    public var runner: (String, [String]) throws -> ProcessResult

    public init(
        contextName: String = "conjet",
        buildkitMaxParallelism: Int = DockerContextManager.defaultBuildKitMaxParallelism(),
        buildkitConfigDirectory: URL? = nil,
        runner: @escaping (String, [String]) throws -> ProcessResult = ProcessRunner.run
    ) {
        self.contextName = contextName
        self.buildkitMaxParallelism = max(1, min(buildkitMaxParallelism, 16))
        self.buildkitConfigDirectory = buildkitConfigDirectory
        self.runner = runner
    }

    public static func defaultBuildKitMaxParallelism(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment["CONJET_BUILDKIT_MAX_PARALLELISM"],
              let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0 else {
            return 1
        }
        return min(parsed, 16)
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
    ) throws -> (name: String, action: DockerContextAction) {
        let builderName = "\(contextName)-buildkit"
        let inspect = try runDocker(["buildx", "inspect", builderName, "--timeout", "2s"])
        if inspect.succeeded {
            let driver = buildxField(named: "Driver", from: inspect.stdout)
            let endpoint = buildxField(named: "Endpoint", from: inspect.stdout)
            if driver == "docker-container", endpoint == contextName {
                guard buildxConfigMatchesDesiredMaxParallelism(inspect.stdout) else {
                    try requireSuccess(runDocker(["buildx", "rm", "--force", builderName]))
                    try createBuildxBuilder(named: builderName, forContext: contextName, makeCurrent: makeCurrent)
                    return (builderName, .updated)
                }
                try selectBuildxBuilder(named: builderName, makeCurrent: makeCurrent)
                return (builderName, .unchanged)
            }
            guard driver == "docker",
                  endpoint == nil || endpoint == contextName else {
                throw ConjetError.processFailed(
                    executable: inspect.executable,
                    exitCode: inspect.exitCode,
                    stderr: "Buildx builder \(builderName) is not the Docker driver for context \(contextName)"
                )
            }
            try requireSuccess(runDocker(["buildx", "rm", "--force", builderName]))
            try createBuildxBuilder(named: builderName, forContext: contextName, makeCurrent: makeCurrent)
            return (builderName, .updated)
        }

        try createBuildxBuilder(named: builderName, forContext: contextName, makeCurrent: makeCurrent)
        return (builderName, .created)
    }

    private func selectBuildxBuilder(named builderName: String, makeCurrent: Bool) throws {
        guard makeCurrent else { return }
        try requireSuccess(runDocker(["buildx", "use", "--default", builderName]))
    }

    private func createBuildxBuilder(named builderName: String, forContext contextName: String, makeCurrent: Bool) throws {
        let configURL = try writeBuildKitConfig(named: builderName)
        var arguments = [
            "buildx", "create",
            "--name", builderName,
            "--driver", "docker-container",
            "--buildkitd-config", configURL.path,
            "--bootstrap"
        ]
        if makeCurrent {
            arguments.append("--use")
        }
        arguments.append(contextName)
        try requireSuccess(runDocker(arguments))
        try selectBuildxBuilder(named: builderName, makeCurrent: makeCurrent)
    }

    private func writeBuildKitConfig(named builderName: String) throws -> URL {
        let directory = buildkitConfigDirectory ?? defaultBuildKitConfigDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = builderName.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let url = directory.appendingPathComponent("\(String(safeName))-buildkitd.toml")
        let content = """
        [worker.oci]
          max-parallelism = \(buildkitMaxParallelism)

        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func defaultBuildKitConfigDirectory() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Conjet", isDirectory: true)
            .appendingPathComponent("buildkit", isDirectory: true)
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

    private func buildxConfigMatchesDesiredMaxParallelism(_ output: String) -> Bool {
        for line in output.split(separator: "\n") {
            let normalized = line
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard normalized.hasPrefix("max-parallelism") else {
                continue
            }
            let parts = normalized.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let parsed = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            return parsed == buildkitMaxParallelism
        }
        return false
    }
}

import Foundation

public enum ConjetEnvironment {
    public static let forwardedAppKeys: [String] = [
        "CONJET_HOME",
        "CONJET_PROFILE",
        "CONJET_APP_CONJET_PATH",
        "CONJET_APP_CONJET_CORE_PATH",
        "CONJET_APP_DOCKER_PATH",
        "CONJET_CORE_REPOSITORY",
        "CONJET_DISABLE_BACKGROUND_SERVICE_REGISTRATION",
        "CONJET_DISABLE_MENU_BAR_APP",
        "CONJET_ENERGY_MODE",
        "CONJET_MEMORY_PROFILE",
        "CONJET_DOCKER_BUILD_STREAM_LIMIT",
        "CONJET_BUILDKIT_MAX_PARALLELISM",
        "CONJET_NET_BRIDGE_ENGINE",
        "CONJET_NET_PROXY_ENGINE",
        "CONJET_STOP_TIMEOUT_SECONDS",
        "PATH"
    ]

    public static let runtimeBindingKeys: [String] = [
        "CONJET_HOME",
        "CONJET_PROFILE"
    ]

    private static let fallbackExecutableDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    public static func app(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        includeLaunchdEnvironment: Bool = true,
        includePersistedRuntimeEnvironment: Bool = true,
        persistedRuntimeEnvironmentURL: URL? = nil
    ) -> [String: String] {
        var environment = processEnvironment

        if includeLaunchdEnvironment {
            for key in forwardedAppKeys where environment[key]?.isEmpty ?? true {
                if let value = launchdEnvironmentValue(for: key), !value.isEmpty {
                    environment[key] = value
                }
            }
        }

        if includePersistedRuntimeEnvironment {
            mergePersistedRuntimeEnvironment(
                into: &environment,
                from: persistedRuntimeEnvironmentURL ?? defaultPersistedRuntimeEnvironmentURL()
            )
        }

        environment["PATH"] = mergedExecutableSearchPath(environment["PATH"])
        return environment
    }

    public static func mergedExecutableSearchPath(_ path: String?) -> String {
        var seen = Set<String>()
        var directories: [String] = []

        func append(_ directory: String) {
            guard !directory.isEmpty, !seen.contains(directory) else { return }
            seen.insert(directory)
            directories.append(directory)
        }

        path?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .forEach(append)

        fallbackExecutableDirectories.forEach(append)
        return directories.joined(separator: ":")
    }

    public static func forwardedEnvironmentArguments(_ environment: [String: String]) -> [String] {
        forwardedAppKeys.flatMap { key -> [String] in
            guard let value = environment[key], !value.isEmpty else { return [] }
            return ["--env", "\(key)=\(value)"]
        }
    }

    public static func shouldPersistMenuBarRuntimeBinding(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["CONJET_DISABLE_MENU_BAR_APP"] != "1"
    }

    public static func persistRuntimeBinding(
        environment: [String: String],
        to url: URL = defaultPersistedRuntimeEnvironmentURL()
    ) throws {
        let values = runtimeBindingKeys.reduce(into: [String: String]()) { result, key in
            guard let value = environment[key], !value.isEmpty else { return }
            result[key] = value
        }
        guard !values.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = PersistedRuntimeEnvironment(values: values)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }

    public static func defaultPersistedRuntimeEnvironmentURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Conjet", isDirectory: true)
            .appendingPathComponent("runtime-environment.json")
    }

    private static func mergePersistedRuntimeEnvironment(
        into environment: inout [String: String],
        from url: URL
    ) {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(PersistedRuntimeEnvironment.self, from: data) else {
            return
        }
        for key in runtimeBindingKeys where environment[key]?.isEmpty ?? true {
            if let value = payload.values[key], !value.isEmpty {
                environment[key] = value
            }
        }
    }

    private static func launchdEnvironmentValue(for key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", key]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

private struct PersistedRuntimeEnvironment: Codable {
    var values: [String: String]
}

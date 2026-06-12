import Foundation

public enum ConjetEnvironment {
    public static let forwardedAppKeys: [String] = [
        "CONJET_HOME",
        "CONJET_PROFILE",
        "CONJET_APP_CONJET_PATH",
        "CONJET_APP_CONJETD_PATH",
        "CONJET_APP_DOCKER_PATH",
        "CONJET_CORE_REPOSITORY",
        "CONJET_DISABLE_BACKGROUND_SERVICE_REGISTRATION",
        "CONJET_DISABLE_MENU_BAR_APP",
        "CONJET_ENERGY_MODE",
        "CONJET_MEMORY_PROFILE",
        "CONJET_NET_BRIDGE_ENGINE",
        "CONJET_NET_PROXY_ENGINE",
        "CONJET_STOP_TIMEOUT_SECONDS",
        "PATH"
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
        includeLaunchdEnvironment: Bool = true
    ) -> [String: String] {
        var environment = processEnvironment

        if includeLaunchdEnvironment {
            for key in forwardedAppKeys where environment[key]?.isEmpty ?? true {
                if let value = launchdEnvironmentValue(for: key), !value.isEmpty {
                    environment[key] = value
                }
            }
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

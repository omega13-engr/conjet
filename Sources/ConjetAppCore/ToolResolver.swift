import ConjetCore
import Foundation

public struct ResolvedTool: Equatable, Sendable {
    public var executable: String
    public var argumentsPrefix: [String]
    public var source: String

    public init(executable: String, argumentsPrefix: [String] = [], source: String) {
        self.executable = executable
        self.argumentsPrefix = argumentsPrefix
        self.source = source
    }

    public func invocation(
        arguments: [String],
        displayName: String? = nil,
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Double? = nil
    ) -> CommandInvocation {
        CommandInvocation(
            executable: executable,
            arguments: argumentsPrefix + arguments,
            displayName: displayName,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }
}

public enum ConjetToolResolver {
    public static func conjet(environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedTool {
        if let override = executableOverride("CONJET_APP_CONJET_PATH", environment: environment) {
            return ResolvedTool(executable: override, source: "CONJET_APP_CONJET_PATH")
        }
        if let bundled = bundledTool(named: "conjet") {
            return ResolvedTool(executable: bundled, source: "app bundle")
        }
        if let local = localBuildTool(named: "conjet") {
            return ResolvedTool(executable: local, source: "SwiftPM build")
        }
        if let path = findExecutable(named: "conjet", environment: environment) {
            return ResolvedTool(executable: path, source: "PATH")
        }
        return ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["conjet"], source: "env fallback")
    }

    public static func conjetd(environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedTool {
        if let override = executableOverride("CONJET_APP_CONJETD_PATH", environment: environment) {
            return ResolvedTool(executable: override, source: "CONJET_APP_CONJETD_PATH")
        }
        if let bundled = bundledTool(named: "conjetd") {
            return ResolvedTool(executable: bundled, source: "app bundle")
        }
        if let local = localBuildTool(named: "conjetd") {
            return ResolvedTool(executable: local, source: "SwiftPM build")
        }
        if let path = findExecutable(named: "conjetd", environment: environment) {
            return ResolvedTool(executable: path, source: "PATH")
        }
        return ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["conjetd"], source: "env fallback")
    }

    public static func docker(environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedTool {
        if let override = executableOverride("CONJET_APP_DOCKER_PATH", environment: environment) {
            return ResolvedTool(executable: override, source: "CONJET_APP_DOCKER_PATH")
        }
        if let path = findExecutable(named: "docker", environment: environment) {
            return ResolvedTool(executable: path, source: "PATH")
        }
        return ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["docker"], source: "env fallback")
    }

    public static func findExecutable(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let searchPath = ConjetEnvironment.mergedExecutableSearchPath(environment["PATH"])
        for directory in searchPath.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func executableOverride(_ key: String, environment: [String: String]) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return FileManager.default.isExecutableFile(atPath: value) ? value : nil
    }

    private static func bundledTool(named name: String) -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourceURL
            .appendingPathComponent("ConjetTools", isDirectory: true)
            .appendingPathComponent(name)
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func localBuildTool(named name: String) -> String? {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let candidates = [
            current.appendingPathComponent(".build/debug/\(name)").path,
            current.appendingPathComponent(".build/arm64-apple-macosx/debug/\(name)").path,
            current.appendingPathComponent(".build/release/\(name)").path,
            current.appendingPathComponent(".build/arm64-apple-macosx/release/\(name)").path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

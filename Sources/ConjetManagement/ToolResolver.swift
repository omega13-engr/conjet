import ConjetCore
import Foundation
#if os(macOS)
import Darwin
#endif

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

    public var executableURL: URL? {
        guard argumentsPrefix.isEmpty else { return nil }
        return URL(fileURLWithPath: executable)
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
        if let sibling = siblingTool(named: "conjet", environment: environment) {
            return ResolvedTool(executable: sibling, source: "sibling executable")
        }
        if let local = localBuildTool(named: "conjet") {
            return ResolvedTool(executable: local, source: "SwiftPM build")
        }
        if let path = findExecutable(named: "conjet", environment: environment) {
            return ResolvedTool(executable: path, source: "PATH")
        }
        return ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["conjet"], source: "env fallback")
    }

    public static func conjetCore(environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedTool {
        if let override = executableOverride("CONJET_APP_CONJET_CORE_PATH", environment: environment) {
            return ResolvedTool(executable: override, source: "CONJET_APP_CONJET_CORE_PATH")
        }
        if let bundled = bundledTool(named: "conjetd") {
            return ResolvedTool(executable: bundled, source: "app bundle")
        }
        if let bundled = bundledTool(named: "Conjet Core") {
            return ResolvedTool(executable: bundled, source: "legacy app bundle")
        }
        if let sibling = siblingTool(named: "conjetd", environment: environment) {
            return ResolvedTool(executable: sibling, source: "sibling executable")
        }
        if let sibling = siblingTool(named: "Conjet Core", environment: environment) {
            return ResolvedTool(executable: sibling, source: "legacy sibling executable")
        }
        if let local = localBuildTool(named: "conjetd") {
            return ResolvedTool(executable: local, source: "SwiftPM build")
        }
        if let local = localBuildTool(named: "Conjet Core") {
            return ResolvedTool(executable: local, source: "legacy SwiftPM build")
        }
        if let path = findExecutable(named: "conjetd", environment: environment) {
            return ResolvedTool(executable: path, source: "PATH")
        }
        if let path = findExecutable(named: "Conjet Core", environment: environment) {
            return ResolvedTool(executable: path, source: "legacy PATH")
        }
        return ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["conjetd"], source: "env fallback")
    }

    public static func conjetCoreVMM(environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedTool {
        if let override = executableOverride("CONJET_CORE_VMM_PATH", environment: environment) {
            return ResolvedTool(executable: override, source: "CONJET_CORE_VMM_PATH")
        }
        if let bundled = bundledNestedTool(components: ["ConjetCoreVMM", "Conjet Core"]) {
            return ResolvedTool(executable: bundled, source: "app bundle")
        }
        if let bundled = bundledNestedTool(components: ["ConjetCoreVMM", "jetstream"]) {
            return ResolvedTool(executable: bundled, source: "legacy app bundle")
        }
        if let sibling = siblingNestedTool(components: ["ConjetCoreVMM", "Conjet Core"], environment: environment) {
            return ResolvedTool(executable: sibling, source: "sibling executable")
        }
        if let sibling = siblingNestedTool(components: ["ConjetCoreVMM", "jetstream"], environment: environment) {
            return ResolvedTool(executable: sibling, source: "legacy sibling executable")
        }
        if let local = localCargoTool(named: "jetstream") {
            return ResolvedTool(executable: local, source: "Cargo build")
        }
        if let path = findExecutable(named: "jetstream", environment: environment) {
            return ResolvedTool(executable: path, source: "PATH")
        }
        return ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["jetstream"], source: "env fallback")
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

    public static func jetstream(environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedTool {
        if let override = executableOverride("CONJET_JETSTREAM_PATH", environment: environment) {
            return ResolvedTool(executable: override, source: "CONJET_JETSTREAM_PATH")
        }
        if let bundled = bundledTool(named: "jetstream") {
            return ResolvedTool(executable: bundled, source: "app bundle")
        }
        if let sibling = siblingTool(named: "jetstream", environment: environment) {
            return ResolvedTool(executable: sibling, source: "sibling executable")
        }
        if let local = localCargoTool(named: "jetstream") {
            return ResolvedTool(executable: local, source: "Cargo build")
        }
        if let path = findExecutable(named: "jetstream", environment: environment) {
            return ResolvedTool(executable: path, source: "PATH")
        }
        return ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["jetstream"], source: "env fallback")
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

    private static func bundledNestedTool(components: [String]) -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        var candidate = resourceURL.appendingPathComponent("ConjetTools", isDirectory: true)
        for component in components {
            candidate.appendPathComponent(component)
        }
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate.path : nil
    }

    private static func siblingTool(named name: String, environment: [String: String]) -> String? {
        let manager = FileManager.default
        let executables = ([currentExecutableURL(), Bundle.main.executableURL] + commandLineExecutableCandidates(environment: environment).map(Optional.some))
            .compactMap { $0 }
        var seen = Set<String>()
        for executable in executables {
            for candidate in siblingCandidates(named: name, nextTo: executable) {
                let path = candidate.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                if manager.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private static func siblingNestedTool(components: [String], environment: [String: String]) -> String? {
        let manager = FileManager.default
        let executables = ([currentExecutableURL(), Bundle.main.executableURL] + commandLineExecutableCandidates(environment: environment).map(Optional.some))
            .compactMap { $0 }
        var seen = Set<String>()
        for executable in executables {
            let standardized = executable.standardizedFileURL
            let resolved = standardized.resolvingSymlinksInPath()
            for base in [standardized.deletingLastPathComponent(), resolved.deletingLastPathComponent()] {
                var candidate = base
                for component in components {
                    candidate.appendPathComponent(component)
                }
                let path = candidate.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                if manager.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private static func localBuildTool(named name: String) -> String? {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let directories = [
            current.appendingPathComponent(".build/debug", isDirectory: true),
            current.appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true),
            current.appendingPathComponent(".build/release", isDirectory: true),
            current.appendingPathComponent(".build/arm64-apple-macosx/release", isDirectory: true)
        ]
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private static func localCargoTool(named name: String) -> String? {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let directories = [
            current.appendingPathComponent("target/debug", isDirectory: true),
            current.appendingPathComponent("target/release", isDirectory: true),
            current.appendingPathComponent("jetstream/target/debug", isDirectory: true),
            current.appendingPathComponent("jetstream/target/release", isDirectory: true)
        ]
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private static func siblingCandidates(named name: String, nextTo executable: URL) -> [URL] {
        let standardized = executable.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        let raw = standardized.deletingLastPathComponent().appendingPathComponent(name)
        let resolvedCandidate = resolved.deletingLastPathComponent().appendingPathComponent(name)
        return raw.path == resolvedCandidate.path ? [raw] : [raw, resolvedCandidate]
    }

    private static func currentExecutableURL() -> URL? {
        #if os(macOS)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        guard _NSGetExecutablePath(buffer, &size) == 0 else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: buffer))
        #else
        return nil
        #endif
    }

    private static func commandLineExecutableCandidates(environment: [String: String]) -> [URL] {
        guard let arg0 = CommandLine.arguments.first, !arg0.isEmpty else {
            return []
        }
        if arg0.contains("/") {
            return [URL(fileURLWithPath: arg0)]
        }
        if let executable = findExecutable(named: arg0, environment: environment) {
            return [URL(fileURLWithPath: executable)]
        }
        return []
    }
}

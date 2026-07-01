import ConjetCore
import Foundation
#if os(macOS)
import Darwin
#endif

public struct ConjetRuntimeContext: Sendable {
    public var environment: [String: String]
    public var conjetTool: ResolvedTool
    public var conjetCoreTool: ResolvedTool
    public var dockerTool: ResolvedTool
    public var paths: ConjetPaths

    public init(
        environment: [String: String],
        conjetTool: ResolvedTool,
        conjetCoreTool: ResolvedTool,
        dockerTool: ResolvedTool,
        paths: ConjetPaths
    ) {
        self.environment = environment
        self.conjetTool = conjetTool
        self.conjetCoreTool = conjetCoreTool
        self.dockerTool = dockerTool
        self.paths = paths
    }
}

public struct ConjetProfileStatus: Codable, Equatable, Sendable {
    public var profile: String
    public var home: String
    public var config: ConjetConfig

    public init(profile: String, home: String, config: ConjetConfig) {
        self.profile = profile
        self.home = home
        self.config = config
    }
}

public struct ConjetProfileConfigResult: Codable, Equatable, Sendable {
    public var profile: String
    public var home: String
    public var configPath: String
    public var config: ConjetConfig

    public init(profile: String, home: String, configPath: String, config: ConjetConfig) {
        self.profile = profile
        self.home = home
        self.configPath = configPath
        self.config = config
    }
}

public struct ConjetProfileActivationResult: Codable, Equatable, Sendable {
    public var profile: String
    public var home: String
    public var rootHome: String
    public var dockerSocketPath: String
    public var daemonSocketPath: String
    public var previousProfile: String
    public var previousHome: String
    public var bindingPath: String

    public init(
        profile: String,
        home: String,
        rootHome: String,
        dockerSocketPath: String,
        daemonSocketPath: String,
        previousProfile: String,
        previousHome: String,
        bindingPath: String
    ) {
        self.profile = profile
        self.home = home
        self.rootHome = rootHome
        self.dockerSocketPath = dockerSocketPath
        self.daemonSocketPath = daemonSocketPath
        self.previousProfile = previousProfile
        self.previousHome = previousHome
        self.bindingPath = bindingPath
    }
}

public struct ConjetRuntimeStatusResult: Sendable {
    public var paths: ConjetPaths
    public var config: ConjetConfig
    public var socketPath: String
    public var response: DaemonResponse

    public init(paths: ConjetPaths, config: ConjetConfig, socketPath: String, response: DaemonResponse) {
        self.paths = paths
        self.config = config
        self.socketPath = socketPath
        self.response = response
    }
}

public struct ConjetRestartResult: Codable, Equatable, Sendable {
    public var pruned: DaemonResponse?
    public var stopped: DaemonResponse?
    public var started: DaemonResponse

    public init(pruned: DaemonResponse?, stopped: DaemonResponse?, started: DaemonResponse) {
        self.pruned = pruned
        self.stopped = stopped
        self.started = started
    }
}

public final class ConjetRuntimeManagementService: @unchecked Sendable {
    private let baseEnvironment: [String: String]
    private let conjetToolOverride: ResolvedTool?
    private let conjetCoreToolOverride: ResolvedTool?
    private let dockerToolOverride: ResolvedTool?
    private let persistedRuntimeEnvironmentURL: URL?
    private let includePersistedRuntimeEnvironment: Bool
    private let executor: any CommandExecuting
    private let runtimeBindingLock = NSLock()
    private var runtimeBindingOverride: [String: String]?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        conjetTool: ResolvedTool? = nil,
        conjetCoreTool: ResolvedTool? = nil,
        dockerTool: ResolvedTool? = nil,
        includeLaunchdEnvironment: Bool = true,
        persistedRuntimeEnvironmentURL: URL? = nil,
        executor: any CommandExecuting = LocalCommandExecutor()
    ) {
        self.baseEnvironment = ConjetEnvironment.app(
            processEnvironment: environment,
            includeLaunchdEnvironment: includeLaunchdEnvironment,
            includePersistedRuntimeEnvironment: false
        )
        self.conjetToolOverride = conjetTool
        self.conjetCoreToolOverride = conjetCoreTool
        self.dockerToolOverride = dockerTool
        self.persistedRuntimeEnvironmentURL = persistedRuntimeEnvironmentURL
        self.includePersistedRuntimeEnvironment = persistedRuntimeEnvironmentURL != nil
            || !Self.hasExplicitRuntimeBinding(environment)
        self.executor = executor
    }

    public func runtimeContext() -> ConjetRuntimeContext {
        var environment = ConjetEnvironment.app(
            processEnvironment: baseEnvironment,
            includeLaunchdEnvironment: false,
            includePersistedRuntimeEnvironment: includePersistedRuntimeEnvironment,
            persistedRuntimeEnvironmentURL: persistedRuntimeEnvironmentURL
        )
        if let override = runtimeBindingOverrideSnapshot() {
            for key in ConjetEnvironment.runtimeBindingKeys {
                if let value = override[key], !value.isEmpty {
                    environment[key] = value
                }
            }
        }
        let conjet = conjetToolOverride ?? ConjetToolResolver.conjet(environment: environment)
        let conjetCore = conjetCoreToolOverride ?? ConjetToolResolver.conjetCore(environment: environment)
        let docker = dockerToolOverride ?? ConjetToolResolver.docker(environment: environment)
        let paths = ConjetPaths.default(environment: environment)
        return ConjetRuntimeContext(
            environment: environment,
            conjetTool: conjet,
            conjetCoreTool: conjetCore,
            dockerTool: docker,
            paths: paths
        )
    }

    public func status(timeoutSeconds: Double = 10) throws -> ConjetRuntimeStatusResult {
        let context = runtimeContext()
        let config = try ConjetConfig.loadOrCreate(paths: context.paths)
        let socketPath = config.socketPath ?? context.paths.socket.path
        do {
            try Self.validateUnixSocketPath(socketPath)
            let response = try UnixSocketClient(socketPath: socketPath)
                .send(DaemonRequest(command: .status), timeoutSeconds: timeoutSeconds)
            return ConjetRuntimeStatusResult(paths: context.paths, config: config, socketPath: socketPath, response: response)
        } catch {
            return ConjetRuntimeStatusResult(
                paths: context.paths,
                config: config,
                socketPath: socketPath,
                response: offlineDaemonResponse(context: context, socketPath: socketPath, error: error)
            )
        }
    }

    public func dashboardDaemonStatus(timeoutSeconds: Double = 2) -> DaemonResponse {
        let context = runtimeContext()
        do {
            let socketPath = try Self.resolvedDaemonSocketPath(paths: context.paths)
            try Self.validateUnixSocketPath(socketPath)
            var response = try UnixSocketClient(socketPath: socketPath)
                .send(DaemonRequest(command: .status), timeoutSeconds: timeoutSeconds)
            if let freshResponse = freshVMStatus(socketPath: response.status?.socketPath, context: context) {
                response.status = freshResponse.status ?? response.status
                response.vm = freshResponse.vm ?? freshResponse.status?.vm ?? response.vm
            }
            return response
        } catch {
            return offlineDaemonResponse(context: context, socketPath: Self.daemonSocketPath(paths: context.paths), error: error)
        }
    }

    public func freshVMStatus(socketPath: String? = nil) -> DaemonResponse? {
        freshVMStatus(socketPath: socketPath, context: runtimeContext())
    }

    public func streamPulse(
        sinceSequence: UInt64 = 0,
        timeoutSeconds: Double? = nil,
        onFrame: (ConjetPulseFrame) throws -> Bool
    ) throws {
        let context = runtimeContext()
        let socketPath = try Self.resolvedDaemonSocketPath(paths: context.paths)
        try Self.validateUnixSocketPath(socketPath)
        try UnixSocketClient(socketPath: socketPath).streamPulse(
            sinceSequence: sinceSequence,
            timeoutSeconds: timeoutSeconds,
            onFrame: onFrame
        )
    }

    public func profileStatus() throws -> ConjetProfileStatus {
        let context = runtimeContext()
        let config = try ConjetConfig.loadOrCreate(paths: context.paths)
        return ConjetProfileStatus(profile: context.paths.profileName, home: context.paths.home.path, config: config)
    }

    public func createProfile(named profileName: String) throws -> ConjetProfileStatus {
        let context = runtimeContext()
        let paths = try Self.profilePaths(named: profileName, rootHome: context.paths.rootHome)
        try paths.ensureBaseDirectories()
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        return ConjetProfileStatus(profile: paths.profileName, home: paths.home.path, config: config)
    }

    public func profileConfig(named profileName: String) throws -> ConjetProfileConfigResult {
        let context = runtimeContext()
        let paths = try Self.profilePaths(named: profileName, rootHome: context.paths.rootHome)
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        return ConjetProfileConfigResult(
            profile: paths.profileName,
            home: paths.home.path,
            configPath: paths.config.path,
            config: config
        )
    }

    public func saveProfileConfig(named profileName: String, config: ConjetConfig) throws -> ConjetProfileConfigResult {
        let context = runtimeContext()
        let paths = try Self.profilePaths(named: profileName, rootHome: context.paths.rootHome)
        let validated = try ConjetConfig.parseTOML(config.renderTOML())
        try validated.save(paths: paths)
        return ConjetProfileConfigResult(
            profile: paths.profileName,
            home: paths.home.path,
            configPath: paths.config.path,
            config: validated
        )
    }

    public func switchProfile(named profileName: String) throws -> ConjetProfileActivationResult {
        let previousContext = runtimeContext()
        let targetPaths = try Self.profilePaths(named: profileName, rootHome: previousContext.paths.rootHome)
        try targetPaths.ensureBaseDirectories()
        _ = try ConjetConfig.loadOrCreate(paths: targetPaths)

        var environment = previousContext.environment
        environment["CONJET_HOME"] = targetPaths.rootHome.path
        environment["CONJET_PROFILE"] = targetPaths.profileName

        let bindingURL = persistedRuntimeEnvironmentURL ?? ConjetEnvironment.defaultPersistedRuntimeEnvironmentURL()
        try ConjetEnvironment.persistRuntimeBinding(environment: environment, to: bindingURL)
        setRuntimeBindingOverride([
            "CONJET_HOME": targetPaths.rootHome.path,
            "CONJET_PROFILE": targetPaths.profileName
        ])

        return ConjetProfileActivationResult(
            profile: targetPaths.profileName,
            home: targetPaths.home.path,
            rootHome: targetPaths.rootHome.path,
            dockerSocketPath: targetPaths.dockerSocket.path,
            daemonSocketPath: targetPaths.socket.path,
            previousProfile: previousContext.paths.profileName,
            previousHome: previousContext.paths.home.path,
            bindingPath: bindingURL.path
        )
    }

    public func listProfiles() -> [String] {
        Self.listProfiles(rootHome: runtimeContext().paths.rootHome)
    }

    public static func listProfiles(rootHome: URL) -> [String] {
        var profiles = ["default"]
        let profilesDirectory = rootHome.appendingPathComponent("profiles", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true,
                      ConjetPaths.isValidProfileName(entry.lastPathComponent) else {
                    continue
                }
                profiles.append(entry.lastPathComponent)
            }
        }
        return Array(Set(profiles)).sorted()
    }

    private static func profilePaths(named profileName: String, rootHome: URL) throws -> ConjetPaths {
        guard ConjetPaths.isValidProfileName(profileName) else {
            throw ConjetError.invalidArgument("profile name must contain only letters, numbers, '.', '_' or '-' and cannot start with '.'")
        }
        return ConjetPaths(home: rootHome, profileName: profileName)
    }

    public func stopRuntime(timeout: Double, requireRunning: Bool) throws -> DaemonResponse? {
        let context = runtimeContext()
        let currentSocketPath = try Self.resolvedDaemonSocketPath(paths: context.paths)
        try Self.validateUnixSocketPath(currentSocketPath)
        guard daemonIsRunning(socketPath: currentSocketPath, context: context) else {
            if requireRunning {
                throw ConjetError.unavailable("Conjet Core is not running at \(currentSocketPath)")
            }
            return nil
        }

        let response: DaemonResponse
        do {
            response = try UnixSocketClient(socketPath: currentSocketPath).send(
                DaemonRequest(command: .stop, parameters: ["timeout_seconds": String(timeout)]),
                timeoutSeconds: max(timeout, 1) + 1
            )
        } catch {
            if let pid = runningDaemonPID(socketPath: currentSocketPath, context: context) {
                let termination = try Self.daemonSupervisor(paths: context.paths, socketPath: currentSocketPath)
                    .terminateRunningDaemon(timeoutSeconds: max(timeout, 3))
                let suffix: String
                if let termination {
                    let signalName = Self.daemonTerminationSignalDescription(termination.signal)
                    suffix = " with \(signalName)"
                } else {
                    suffix = ""
                }
                return DaemonResponse(
                    ok: true,
                    message: "Conjet Core pid \(pid) was not answering stop at \(currentSocketPath); terminated\(suffix)"
                )
            }
            throw error
        }
        guard response.ok, !response.message.contains("cleanup still in progress") else {
            throw ConjetError.unavailable(response.message)
        }
        Self.waitForDaemonStop(socketPath: currentSocketPath, timeoutSeconds: max(timeout, 5))
        return response
    }

    public func stopRuntimeCommand(
        timeout: Double,
        requireRunning: Bool = false,
        label: String = "Stop Conjet",
        commandLine: String? = nil
    ) async -> CommandLogEntry {
        let startedAt = Date()
        let renderedCommand = commandLine ?? "conjet stop --timeout \(formatTimeout(timeout)) --json"
        let result = await Task.detached(priority: .utility) {
            do {
                let response = try self.stopRuntime(timeout: timeout, requireRunning: requireRunning)
                    ?? DaemonResponse(ok: true, message: "Conjet Core is not running")
                return (
                    exitCode: Int32(0),
                    stdout: (try? ConjetJSON.string(response)) ?? "{\"ok\":true,\"message\":\"\(response.message)\"}",
                    stderr: ""
                )
            } catch {
                return (exitCode: Int32(1), stdout: "", stderr: String(describing: error))
            }
        }.value
        return CommandLogEntry(
            label: label,
            commandLine: renderedCommand,
            startedAt: startedAt,
            finishedAt: Date(),
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    public func pruneRuntimeCacheIfRunning() throws -> DaemonResponse? {
        let context = runtimeContext()
        let currentSocketPath = try Self.resolvedDaemonSocketPath(paths: context.paths)
        try Self.validateUnixSocketPath(currentSocketPath)
        guard daemonIsRunning(socketPath: currentSocketPath, context: context) else {
            return nil
        }
        let response: DaemonResponse
        do {
            response = try UnixSocketClient(socketPath: currentSocketPath).send(
                DaemonRequest(command: .pruneCache),
                timeoutSeconds: 10
            )
        } catch {
            if runningDaemonPID(socketPath: currentSocketPath, context: context) != nil {
                return nil
            }
            throw error
        }
        if DaemonCompatibility.isUnsupportedCommandResponse(response, command: .pruneCache) {
            return nil
        }
        return response
    }

    public func daemonIsRunning(socketPath: String) -> Bool {
        daemonIsRunning(socketPath: socketPath, context: runtimeContext())
    }

    public func runningDaemonPID(socketPath: String) -> Int32? {
        runningDaemonPID(socketPath: socketPath, context: runtimeContext())
    }

    public func runConjetCompatibility(
        _ arguments: [String],
        label: String,
        timeoutSeconds: Double? = 120
    ) async -> CommandLogEntry {
        let context = runtimeContext()
        return await run(context.conjetTool.invocation(
            arguments: arguments,
            displayName: label,
            environment: context.environment,
            timeoutSeconds: timeoutSeconds
        ), label: label)
    }

    public func runDocker(
        _ arguments: [String],
        label: String,
        workingDirectory: URL? = nil,
        timeoutSeconds: Double? = 120,
        environmentOverrides: [String: String] = [:]
    ) async -> CommandLogEntry {
        let context = runtimeContext()
        let environment = context.environment.merging(environmentOverrides) { _, new in new }
        let invocation = context.dockerTool.invocation(
            arguments: Self.dockerHostArguments(paths: context.paths) + arguments,
            displayName: label,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
        if let failure = Self.dockerSocketPreflightFailure(context: context, invocation: invocation) {
            let now = Date()
            return CommandLogEntry(
                label: label,
                commandLine: invocation.commandLine,
                startedAt: now,
                finishedAt: now,
                exitCode: failure.exitCode,
                stdout: failure.stdout,
                stderr: failure.stderr
            )
        }
        return await run(invocation, label: label)
    }

    public func runCompose(
        _ arguments: [String],
        workingDirectory: URL,
        label: String,
        timeoutSeconds: Double? = 600
    ) async -> CommandLogEntry {
        await runDocker(
            ["compose"] + arguments,
            label: label,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func docker(
        _ arguments: [String],
        timeoutSeconds: Double?,
        context: ConjetRuntimeContext
    ) async -> ProcessResult {
        let invocation = context.dockerTool.invocation(
            arguments: Self.dockerHostArguments(paths: context.paths) + arguments,
            displayName: "Docker",
            environment: context.environment,
            timeoutSeconds: timeoutSeconds
        )
        if let failure = Self.dockerSocketPreflightFailure(context: context, invocation: invocation) {
            return failure
        }
        return await executor.run(invocation)
    }

    public static func dockerHostArguments(paths: ConjetPaths) -> [String] {
        ["--host", "unix://\(paths.dockerSocket.path)"]
    }

    public static func resolvedDaemonSocketPath(paths: ConjetPaths) throws -> String {
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        return config.socketPath ?? paths.socket.path
    }

    public static func daemonSocketPath(paths: ConjetPaths) -> String {
        if let config = try? ConjetConfig.loadOrCreate(paths: paths), let socketPath = config.socketPath {
            return socketPath
        }
        return paths.socket.path
    }

    public static func stopTimeout(
        from value: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Double {
        let text = value ?? environment["CONJET_STOP_TIMEOUT_SECONDS"]
        guard let text else { return 25 }
        guard let timeout = Double(text), timeout > 0 else {
            throw ConjetError.invalidArgument("--timeout must be a positive number of seconds")
        }
        return timeout
    }

    public static func waitForDaemonStop(socketPath: String, timeoutSeconds: Double = 5) {
        guard isValidUnixSocketPath(socketPath) else { return }
        let attempts = max(1, Int((timeoutSeconds / 0.1).rounded(.up)))
        for _ in 0..<attempts {
            let response = try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .ping))
            if response == nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    public static func daemonTerminationSignalDescription(_ signal: Int32) -> String {
        #if os(macOS)
        if signal == SIGTERM {
            return "SIGTERM"
        }
        if signal == SIGKILL {
            return "SIGKILL"
        }
        #endif
        if signal == 0 {
            return "stale pid cleanup"
        }
        return "signal \(signal)"
    }

    public static func daemonSupervisor(paths: ConjetPaths, socketPath: String) -> DaemonProcessSupervisor {
        DaemonProcessSupervisor(
            socketPath: socketPath,
            lockPath: paths.runDirectory.appendingPathComponent("conjetd.lock").path,
            expectedExecutableNames: DaemonProcessSupervisor.executableNamesForTermination
        )
    }

    private func run(_ invocation: CommandInvocation, label: String) async -> CommandLogEntry {
        let startedAt = Date()
        let result = await executor.run(invocation)
        let finishedAt = Date()
        return CommandLogEntry(
            label: label,
            commandLine: invocation.commandLine,
            startedAt: startedAt,
            finishedAt: finishedAt,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    private func freshVMStatus(socketPath: String?, context: ConjetRuntimeContext) -> DaemonResponse? {
        let path = socketPath ?? Self.daemonSocketPath(paths: context.paths)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard Self.isValidUnixSocketPath(path) else { return nil }
        return try? UnixSocketClient(socketPath: path)
            .send(DaemonRequest(command: .vmStatus), timeoutSeconds: 1)
    }

    private func offlineDaemonResponse(context: ConjetRuntimeContext, socketPath: String, error: Error) -> DaemonResponse {
        let supervisor = Self.daemonSupervisor(paths: context.paths, socketPath: socketPath)
        let message: String
        if let pid = supervisor.runningPID() {
            message = "Conjet Core pid \(pid) is running but status failed at \(socketPath): \(error)"
        } else if FileManager.default.fileExists(atPath: socketPath) {
            message = "Conjet Core socket exists but status failed at \(socketPath): \(error)"
        } else {
            message = "Conjet Core is not running at \(socketPath)"
        }
        return DaemonResponse(ok: false, message: message)
    }

    private func daemonIsRunning(socketPath: String, context: ConjetRuntimeContext) -> Bool {
        guard Self.isValidUnixSocketPath(socketPath) else {
            return runningDaemonPID(socketPath: socketPath, context: context) != nil
        }
        if (try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .ping), timeoutSeconds: 1).ok) == true {
            return true
        }
        return runningDaemonPID(socketPath: socketPath, context: context) != nil
    }

    private func runningDaemonPID(socketPath: String, context: ConjetRuntimeContext) -> Int32? {
        Self.daemonSupervisor(paths: context.paths, socketPath: socketPath).runningPID()
    }

    private func formatTimeout(_ timeout: Double) -> String {
        if timeout.rounded() == timeout {
            return String(Int(timeout))
        }
        return String(timeout)
    }

    private func runtimeBindingOverrideSnapshot() -> [String: String]? {
        runtimeBindingLock.lock()
        defer { runtimeBindingLock.unlock() }
        return runtimeBindingOverride
    }

    private func setRuntimeBindingOverride(_ environment: [String: String]) {
        runtimeBindingLock.lock()
        runtimeBindingOverride = environment
        runtimeBindingLock.unlock()
    }

    private static func hasExplicitRuntimeBinding(_ environment: [String: String]) -> Bool {
        for key in ConjetEnvironment.runtimeBindingKeys {
            if environment[key]?.isEmpty == false {
                return true
            }
        }
        return false
    }

    private static func validateUnixSocketPath(_ path: String) throws {
        guard isValidUnixSocketPath(path) else {
            throw ConjetError.socket("Unix socket path is too long: \(path)")
        }
    }

    private static func isValidUnixSocketPath(_ path: String) -> Bool {
        path.utf8CString.count <= 104
    }

    private static func dockerSocketPreflightFailure(
        context: ConjetRuntimeContext,
        invocation: CommandInvocation
    ) -> ProcessResult? {
        let socketPath = context.paths.dockerSocket.path
        guard isValidUnixSocketPath(socketPath) else {
            return preflightFailure(
                invocation: invocation,
                message: "Conjet Docker socket path is too long: \(socketPath)"
            )
        }

        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            return preflightFailure(
                invocation: invocation,
                message: "Conjet Docker socket is not available at \(socketPath). Start or restart Conjet before running Docker commands. CONJET_HOME=\(context.paths.rootHome.path)"
            )
        }

        return nil
    }

    private static func preflightFailure(
        invocation: CommandInvocation,
        message: String
    ) -> ProcessResult {
        ProcessResult(
            executable: invocation.executable,
            arguments: invocation.arguments,
            exitCode: 1,
            stdout: "",
            stderr: message
        )
    }
}

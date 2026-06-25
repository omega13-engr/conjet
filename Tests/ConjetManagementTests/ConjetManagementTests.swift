import ConjetCore
@testable import ConjetManagement
import XCTest

final class ConjetManagementTests: XCTestCase {
    func testCommandInvocationRendersQuotedAuditCommand() {
        let invocation = CommandInvocation(
            executable: "/usr/bin/env",
            arguments: ["docker", "compose", "-f", "compose dev.yml", "up"],
            displayName: "Compose Up"
        )

        XCTAssertEqual(invocation.commandLine, "/usr/bin/env docker compose -f 'compose dev.yml' up")
    }

    func testResolvedToolBuildsInvocationWithPrefix() {
        let tool = ResolvedTool(executable: "/usr/bin/env", argumentsPrefix: ["docker"], source: "test")
        let invocation = tool.invocation(
            arguments: ["ps"],
            displayName: "Docker PS",
            environment: ["CONJET_HOME": "/tmp/conjet-home"]
        )

        XCTAssertEqual(invocation.executable, "/usr/bin/env")
        XCTAssertEqual(invocation.arguments, ["docker", "ps"])
        XCTAssertEqual(invocation.displayName, "Docker PS")
        XCTAssertEqual(invocation.environment["CONJET_HOME"], "/tmp/conjet-home")
    }

    func testFindExecutableUsesProvidedPath() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-management-tool-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("conjet-test-tool")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            ConjetToolResolver.findExecutable(
                named: "conjet-test-tool",
                environment: ["PATH": directory.path]
            ),
            executable.path
        )
    }

    func testConjetCoreResolverUsesCanonicalDaemonProduct() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-management-core-product-\(UUID().uuidString)", isDirectory: true)
        let debugDirectory = root.appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = debugDirectory.appendingPathComponent("conjetd")
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try withCurrentDirectory(root) {
            let resolved = ConjetToolResolver.conjetCore(environment: ["PATH": ""])

            XCTAssertEqual(URL(fileURLWithPath: resolved.executable).lastPathComponent, "conjetd")
            XCTAssertEqual(resolved.source, "SwiftPM build")
        }
    }

    func testConjetCoreResolverPrefersCanonicalDaemonPathName() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-management-core-path-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["conjetd", "Conjet Core"] {
            let executable = binDirectory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        try withCurrentDirectory(root) {
            let resolved = ConjetToolResolver.conjetCore(environment: ["PATH": binDirectory.path])

            XCTAssertEqual(URL(fileURLWithPath: resolved.executable).lastPathComponent, "conjetd")
            XCTAssertEqual(resolved.source, "PATH")
        }
    }

    func testConjetCoreResolverFallsBackToLegacyDaemonName() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-management-core-legacy-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["conjet-core", "Conjet Core"] {
            let executable = binDirectory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        try withCurrentDirectory(root) {
            let resolved = ConjetToolResolver.conjetCore(environment: ["PATH": binDirectory.path])
            let executableName = URL(fileURLWithPath: resolved.executable).lastPathComponent

            XCTAssertEqual(executableName, "Conjet Core")
            XCTAssertEqual(resolved.argumentsPrefix, [])
            XCTAssertEqual(resolved.source, "legacy PATH")
        }
    }

    func testJetstreamResolverUsesLocalCargoBuildProduct() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-management-jetstream-product-\(UUID().uuidString)", isDirectory: true)
        let debugDirectory = root.appendingPathComponent("target/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = debugDirectory.appendingPathComponent("jetstream")
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try withCurrentDirectory(root) {
            let resolved = ConjetToolResolver.jetstream(environment: ["PATH": ""])

            XCTAssertEqual(URL(fileURLWithPath: resolved.executable).lastPathComponent, "jetstream")
            XCTAssertEqual(resolved.source, "Cargo build")
        }
    }

    func testConjetCoreVMMResolverUsesLocalCargoJetstreamForSourceBuild() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-management-vmm-product-\(UUID().uuidString)", isDirectory: true)
        let debugDirectory = root.appendingPathComponent("target/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = debugDirectory.appendingPathComponent("jetstream")
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try withCurrentDirectory(root) {
            let resolved = ConjetToolResolver.conjetCoreVMM(environment: ["PATH": ""])

            XCTAssertEqual(URL(fileURLWithPath: resolved.executable).lastPathComponent, "jetstream")
            XCTAssertEqual(resolved.source, "Cargo build")
        }
    }

    func testRuntimeContextPicksUpPersistedRuntimeBindingAfterServiceCreation() throws {
        let paths = try Self.makeTemporaryConjetPaths()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let persistedEnvironment = paths.rootHome.appendingPathComponent("runtime-environment.json")
        let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")
        let service = ConjetRuntimeManagementService(
            environment: ["PATH": "/usr/bin:/bin"],
            conjetTool: tool,
            conjetCoreTool: tool,
            dockerTool: tool,
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: persistedEnvironment,
            executor: RecordingCommandExecutor { invocation in
                ProcessResult(
                    executable: invocation.executable,
                    arguments: invocation.arguments,
                    exitCode: 0,
                    stdout: "",
                    stderr: ""
                )
            }
        )

        try ConjetEnvironment.persistRuntimeBinding(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": paths.profileName],
            to: persistedEnvironment
        )

        let context = service.runtimeContext()

        XCTAssertEqual(context.paths.rootHome.path, paths.rootHome.path)
        XCTAssertEqual(context.paths.profileName, paths.profileName)
        XCTAssertEqual(context.environment["CONJET_HOME"], paths.rootHome.path)
        XCTAssertEqual(context.environment["CONJET_PROFILE"], paths.profileName)
    }

    func testListProfilesFiltersUnsafeAndHiddenNames() throws {
        let paths = try Self.makeTemporaryConjetPaths()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let profilesDirectory = paths.rootHome.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profilesDirectory.appendingPathComponent("dev", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: profilesDirectory.appendingPathComponent(".hidden", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "not a directory".write(
            to: profilesDirectory.appendingPathComponent("file-profile"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(ConjetRuntimeManagementService.listProfiles(rootHome: paths.rootHome), ["default", "dev"])
    }

    func testCreateProfileInitializesProfileWithoutLaunchingProcesses() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")
        let executor = RecordingCommandExecutor { invocation in
            ProcessResult(
                executable: invocation.executable,
                arguments: invocation.arguments,
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        }
        let service = ConjetRuntimeManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: tool,
            conjetCoreTool: tool,
            dockerTool: tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )

        let status = try service.createProfile(named: "staging")
        let stagingPaths = ConjetPaths(home: paths.rootHome, profileName: "staging")

        XCTAssertEqual(status.profile, "staging")
        XCTAssertEqual(status.home, stagingPaths.home.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPaths.config.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPaths.runDirectory.path))
        XCTAssertEqual(ConjetRuntimeManagementService.listProfiles(rootHome: paths.rootHome), ["default", "staging"])
        let invocations = await executor.invocations
        XCTAssertEqual(invocations, [])
    }

    func testSwitchProfilePersistsBindingWithoutStoppingExistingProfiles() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let persistedEnvironment = paths.rootHome.appendingPathComponent("runtime-environment.json")
        let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")
        let executor = RecordingCommandExecutor { invocation in
            ProcessResult(
                executable: invocation.executable,
                arguments: invocation.arguments,
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        }
        let service = ConjetRuntimeManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": "default"],
            conjetTool: tool,
            conjetCoreTool: tool,
            dockerTool: tool,
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: persistedEnvironment,
            executor: executor
        )

        let activation = try service.switchProfile(named: "staging")
        let stagingPaths = ConjetPaths(home: paths.rootHome, profileName: "staging")
        let context = service.runtimeContext()
        let persisted = ConjetEnvironment.app(
            processEnvironment: ["PATH": "/usr/bin:/bin"],
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: persistedEnvironment
        )

        XCTAssertEqual(activation.profile, "staging")
        XCTAssertEqual(activation.previousProfile, "default")
        XCTAssertEqual(activation.dockerSocketPath, stagingPaths.dockerSocket.path)
        XCTAssertEqual(context.paths.profileName, "staging")
        XCTAssertEqual(context.paths.dockerSocket.path, stagingPaths.dockerSocket.path)
        XCTAssertEqual(persisted["CONJET_HOME"], paths.rootHome.path)
        XCTAssertEqual(persisted["CONJET_PROFILE"], "staging")
        let invocations = await executor.invocations
        XCTAssertEqual(invocations, [])
    }

    func testProfileConfigLoadAndSaveUsesNamedProfileWithoutLaunchingProcesses() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")
        let executor = RecordingCommandExecutor { invocation in
            ProcessResult(
                executable: invocation.executable,
                arguments: invocation.arguments,
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        }
        let service = ConjetRuntimeManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path, "CONJET_PROFILE": "default"],
            conjetTool: tool,
            conjetCoreTool: tool,
            dockerTool: tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )

        var config = ConjetConfig.default
        config.vmCPUs = 6
        config.memoryMiB = 12_288
        config.networkBindPolicy = .lanAllowlist
        config.networkLANAllowedCIDRs = ["192.168.10.0/24"]
        config.networkLANAllowedPorts = [8080, 8443]
        let saved = try service.saveProfileConfig(named: "staging", config: config)
        let loaded = try service.profileConfig(named: "staging")
        let defaultConfig = try ConjetConfig.loadOrCreate(paths: paths)

        XCTAssertEqual(saved.profile, "staging")
        XCTAssertEqual(loaded.config.vmCPUs, 6)
        XCTAssertEqual(loaded.config.memoryMiB, 12_288)
        XCTAssertEqual(loaded.config.networkBindPolicy, .lanAllowlist)
        XCTAssertEqual(loaded.config.networkLANAllowedCIDRs, ["192.168.10.0/24"])
        XCTAssertEqual(loaded.config.networkLANAllowedPorts, [8080, 8443])
        XCTAssertEqual(defaultConfig.vmCPUs, ConjetConfig.default.vmCPUs)
        let invocations = await executor.invocations
        XCTAssertEqual(invocations, [])
    }

    func testStopTimeoutUsesExplicitValueEnvironmentAndDefault() throws {
        XCTAssertEqual(try ConjetRuntimeManagementService.stopTimeout(from: "10"), 10)
        XCTAssertEqual(
            try ConjetRuntimeManagementService.stopTimeout(
                from: nil,
                environment: ["CONJET_STOP_TIMEOUT_SECONDS": "12.5"]
            ),
            12.5
        )
        XCTAssertEqual(try ConjetRuntimeManagementService.stopTimeout(from: nil, environment: [:]), 25)
        XCTAssertThrowsError(try ConjetRuntimeManagementService.stopTimeout(from: "0"))
    }

    func testDashboardDaemonStatusReportsOfflineWithoutLaunchingCLI() async throws {
        let paths = try Self.makeTemporaryConjetPaths()
        try paths.ensureBaseDirectories()
        defer { try? FileManager.default.removeItem(at: paths.rootHome) }
        let tool = ResolvedTool(executable: "/tmp/conjet-test-tool", source: "test")
        let executor = RecordingCommandExecutor { invocation in
            ProcessResult(
                executable: invocation.executable,
                arguments: invocation.arguments,
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        }
        let service = ConjetRuntimeManagementService(
            environment: ["CONJET_HOME": paths.rootHome.path],
            conjetTool: tool,
            conjetCoreTool: tool,
            dockerTool: tool,
            includeLaunchdEnvironment: false,
            executor: executor
        )

        let response = service.dashboardDaemonStatus(timeoutSeconds: 0.1)

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message.contains("Conjet Core is not running"))
        let invocations = await executor.invocations
        XCTAssertEqual(invocations, [])
    }

    func testLocalCommandExecutorCancelsRunningProcess() async throws {
        let executor = LocalCommandExecutor()
        let startedAt = Date()
        let task = Task {
            await executor.run(CommandInvocation(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while true; do :; done"],
                timeoutSeconds: nil
            ))
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("process cancelled"))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    private static func makeTemporaryConjetPaths() throws -> ConjetPaths {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cj-mg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return ConjetPaths(home: home)
    }

    private func withCurrentDirectory<T>(_ directory: URL, _ body: () throws -> T) throws -> T {
        let original = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { FileManager.default.changeCurrentDirectoryPath(original) }
        return try body()
    }
}

private actor RecordingCommandExecutor: CommandExecuting {
    private var recordedInvocations: [CommandInvocation] = []
    private let handler: @Sendable (CommandInvocation) -> ProcessResult

    init(handler: @escaping @Sendable (CommandInvocation) -> ProcessResult) {
        self.handler = handler
    }

    var invocations: [CommandInvocation] { recordedInvocations }

    func run(_ invocation: CommandInvocation) async -> ProcessResult {
        recordedInvocations.append(invocation)
        return handler(invocation)
    }
}

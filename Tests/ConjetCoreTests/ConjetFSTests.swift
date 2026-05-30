import ConjetCore
import XCTest

final class ConjetFSTests: XCTestCase {
    func testProjectInitCreatesMetadataAndDefaultIgnore() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "conjet".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let fs = ConjetFS(projectRoot: root, paths: ConjetPaths(home: root.appendingPathComponent(".home")))
        let project = try fs.initializeProject()

        XCTAssertEqual(project.name, root.lastPathComponent)
        XCTAssertEqual(project.hostRoot, root.standardizedFileURL.path)
        XCTAssertTrue(project.dockerVolume.hasPrefix("conjetfs-default-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ConjetFS.projectFile(root: root).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".conjetignore").path))
    }

    func testSyncPlanKeepsDependenciesVMNative() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProjectFiles(root: root)

        let fs = ConjetFS(projectRoot: root, paths: ConjetPaths(home: root.appendingPathComponent(".home")))
        let project = try fs.initializeProject()
        let plan = try fs.makePlan(project: project)

        XCTAssertTrue(plan.includedFiles.contains { $0.path == "package.json" })
        XCTAssertTrue(plan.includedFiles.contains { $0.path == "src/index.js" })
        XCTAssertFalse(plan.includedFiles.contains { $0.path.hasPrefix("node_modules/") })
        XCTAssertFalse(plan.includedFiles.contains { $0.path.hasPrefix("target/") })
        XCTAssertTrue(plan.skippedFiles.contains { $0.path == "node_modules" })
        XCTAssertTrue(plan.skippedFiles.contains { $0.path == "target" })
    }

    func testSyncCreatesVolumeCopiesStagingAndTracksDeletedHostFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProjectFiles(root: root)

        let home = root.appendingPathComponent(".home")
        let runner = FakeConjetFSDockerRunner()
        let fs = ConjetFS(
            projectRoot: root,
            paths: ConjetPaths(home: home),
            dockerContext: "conjet",
            runner: runner.run
        )
        let project = try fs.initializeProject()
        let first = try fs.sync(project: project)

        XCTAssertGreaterThanOrEqual(first.includedFiles, 2)
        XCTAssertEqual(first.changedFiles, first.includedFiles)
        XCTAssertGreaterThanOrEqual(first.skippedFiles, 2)
        XCTAssertEqual(first.removedFiles, 0)
        XCTAssertTrue(runner.commands.contains { command in
            command.starts(with: ["docker", "--context", "conjet", "run", "--rm"]) &&
                command.contains(where: { $0.contains("type=bind") && $0.contains("target=/conjetfs-stage") }) &&
                command.contains("type=volume,source=\(project.dockerVolume),target=/workspace")
        })

        try FileManager.default.removeItem(at: root.appendingPathComponent("src/index.js"))
        let second = try fs.sync(project: project)

        XCTAssertEqual(second.removedFiles, 1)
        XCTAssertTrue(runner.commands.contains { command in
            command.joined(separator: " ").contains("rm -f -- 'src/index.js'")
        })
    }

    func testSyncSkipsUnchangedFilesAndTracksModifiedFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProjectFiles(root: root)

        let home = root.appendingPathComponent(".home")
        let runner = FakeConjetFSDockerRunner()
        let fs = ConjetFS(
            projectRoot: root,
            paths: ConjetPaths(home: home),
            dockerContext: "conjet",
            runner: runner.run
        )
        let project = try fs.initializeProject()

        let first = try fs.sync(project: project)
        let copiesAfterFirstSync = runner.copyIntoVolumeCommandCount
        XCTAssertEqual(first.changedFiles, first.includedFiles)

        let cleanStatus = try fs.status(project: project)
        XCTAssertFalse(cleanStatus.dirty)
        XCTAssertEqual(cleanStatus.changedFiles, 0)

        let second = try fs.sync(project: project)
        let copiesAfterSecondSync = runner.copyIntoVolumeCommandCount
        XCTAssertEqual(second.changedFiles, 0)
        XCTAssertEqual(copiesAfterSecondSync, copiesAfterFirstSync)

        Thread.sleep(forTimeInterval: 0.01)
        try "console.log('changed')\n".write(
            to: root.appendingPathComponent("src/index.js"),
            atomically: true,
            encoding: .utf8
        )

        let dirtyStatus = try fs.status(project: project)
        XCTAssertTrue(dirtyStatus.dirty)
        XCTAssertEqual(dirtyStatus.changedFiles, 1)

        let third = try fs.sync(project: project)
        XCTAssertEqual(third.changedFiles, 1)
    }

    func testIncrementalSyncUsesChangedPathsWithoutFullCopyWhenClean() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProjectFiles(root: root)

        let runner = FakeConjetFSDockerRunner()
        let fs = ConjetFS(
            projectRoot: root,
            paths: ConjetPaths(home: root.appendingPathComponent(".home")),
            dockerContext: "conjet",
            runner: runner.run,
            inputRunner: runner.runWithInput
        )
        let project = try fs.initializeProject()
        _ = try fs.sync(project: project)
        let copiesAfterInitialSync = runner.copyIntoVolumeCommandCount

        let clean = try fs.sync(project: project, changedPaths: ["src/index.js"])
        XCTAssertEqual(clean.changedFiles, 0)
        XCTAssertEqual(runner.copyIntoVolumeCommandCount, copiesAfterInitialSync)

        Thread.sleep(forTimeInterval: 0.01)
        try "console.log('incremental')\n".write(
            to: root.appendingPathComponent("src/index.js"),
            atomically: true,
            encoding: .utf8
        )

        let changed = try fs.sync(project: project, changedPaths: ["src/index.js"])
        XCTAssertEqual(changed.changedFiles, 1)
        XCTAssertEqual(changed.removedFiles, 0)
        XCTAssertEqual(runner.copyIntoVolumeCommandCount, copiesAfterInitialSync + 1)

        let status = try fs.status(project: project)
        XCTAssertFalse(status.dirty)
    }

    func testIncrementalSyncRemovesDeletedHostSyncedPathsAndSkipsVMNativePaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProjectFiles(root: root)

        let runner = FakeConjetFSDockerRunner()
        let fs = ConjetFS(
            projectRoot: root,
            paths: ConjetPaths(home: root.appendingPathComponent(".home")),
            dockerContext: "conjet",
            runner: runner.run,
            inputRunner: runner.runWithInput
        )
        let project = try fs.initializeProject()
        _ = try fs.sync(project: project)
        let copiesAfterInitialSync = runner.copyIntoVolumeCommandCount

        try FileManager.default.removeItem(at: root.appendingPathComponent("src/index.js"))
        let deleted = try fs.sync(project: project, changedPaths: ["src/index.js"])
        XCTAssertEqual(deleted.changedFiles, 0)
        XCTAssertEqual(deleted.removedFiles, 1)
        XCTAssertEqual(runner.copyIntoVolumeCommandCount, copiesAfterInitialSync)
        XCTAssertTrue(runner.commands.contains { command in
            command.joined(separator: " ").contains("rm -f -- 'src/index.js'")
        })

        Thread.sleep(forTimeInterval: 0.01)
        try "module.exports = { changed: true }\n".write(
            to: root.appendingPathComponent("node_modules/react/index.js"),
            atomically: true,
            encoding: .utf8
        )
        let vmNative = try fs.sync(project: project, changedPaths: ["node_modules/react/index.js"])
        XCTAssertEqual(vmNative.changedFiles, 0)
        XCTAssertEqual(vmNative.removedFiles, 0)
        XCTAssertEqual(runner.copyIntoVolumeCommandCount, copiesAfterInitialSync)
    }

    func testSyncFallsBackToDockerCPWhenStagingBindIsNotVisibleToDocker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProjectFiles(root: root)

        let runner = FakeConjetFSDockerRunner()
        runner.failFastCopy = true
        let fs = ConjetFS(
            projectRoot: root,
            paths: ConjetPaths(home: root.appendingPathComponent(".home")),
            dockerContext: "conjet",
            runner: runner.run,
            inputRunner: runner.runWithInput
        )
        let project = try fs.initializeProject()
        let result = try fs.sync(project: project)

        XCTAssertGreaterThan(result.changedFiles, 0)
        XCTAssertTrue(runner.commands.contains { command in
            command.starts(with: ["docker", "--context", "conjet", "cp"]) &&
                (command.last?.hasSuffix(":/workspace") ?? false)
        })
    }

    func testIncrementalSyncCanUsePersistentHelperContainer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProjectFiles(root: root)

        let runner = FakeConjetFSDockerRunner()
        let fs = ConjetFS(
            projectRoot: root,
            paths: ConjetPaths(home: root.appendingPathComponent(".home")),
            dockerContext: "conjet",
            runner: runner.run,
            inputRunner: runner.runWithInput,
            streamingHelperFastPath: true
        )
        let project = try fs.initializeProject()
        _ = try fs.sync(project: project)
        let helper = try fs.startSyncHelper(project: project)
        defer { fs.stopSyncHelper(helper) }

        Thread.sleep(forTimeInterval: 0.01)
        try "console.log('helper')\n".write(
            to: root.appendingPathComponent("src/index.js"),
            atomically: true,
            encoding: .utf8
        )
        let result = try fs.sync(project: project, changedPaths: ["src/index.js"], helperContainer: helper)

        XCTAssertEqual(result.changedFiles, 1)
        XCTAssertTrue(runner.commands.contains { command in
            command.starts(with: ["docker", "--context", "conjet", "run", "-d", "--name", helper]) &&
                command.contains("type=volume,source=\(project.dockerVolume),target=/workspace")
        })
        XCTAssertTrue(runner.inputCommands.contains { command in
            command.arguments.starts(with: ["docker", "--context", "conjet", "exec", "-i", helper]) &&
                command.arguments.joined(separator: " ").contains("src/index.js") &&
                command.standardInput == Data("console.log('helper')\n".utf8)
        })
    }

    func testExportCopiesExplicitPathsFromProjectVolume() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProjectFiles(root: root)

        let destination = root.appendingPathComponent("exports", isDirectory: true)
        let runner = FakeConjetFSDockerRunner()
        let fs = ConjetFS(
            projectRoot: root,
            paths: ConjetPaths(home: root.appendingPathComponent(".home")),
            dockerContext: "conjet",
            runner: runner.run
        )
        let project = try fs.initializeProject()
        let result = try fs.export(project: project, paths: ["dist", "/coverage/report.html"], to: destination)

        XCTAssertEqual(result.exportedPaths, ["dist", "coverage/report.html"])
        XCTAssertEqual(result.hostDestination, destination.standardizedFileURL.path)
        XCTAssertTrue(runner.commands.contains(["docker", "--context", "conjet", "volume", "create", project.dockerVolume]))
        XCTAssertTrue(runner.commands.contains { command in
            command.starts(with: ["docker", "--context", "conjet", "cp"]) &&
                command.contains(where: { $0.hasPrefix("conjetfs-export-") && $0.hasSuffix(":/workspace/dist") }) &&
                command.last == destination.standardizedFileURL.path
        })
        XCTAssertTrue(runner.commands.contains { command in
            command.starts(with: ["docker", "--context", "conjet", "rm", "-f"])
        })
    }

    func testWatchBatcherNormalizesAndIgnoresInternalMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var batcher = ConjetFSWatchBatcher(root: root)
        batcher.insert(rawPaths: [
            root.appendingPathComponent("src/index.js").path,
            root.appendingPathComponent(".conjet/project.json").path,
            root.appendingPathComponent("package.json").path,
            "/tmp/outside-conjet-project/file.txt"
        ])

        let event = try XCTUnwrap(batcher.flush())

        XCTAssertEqual(event.root, root.standardizedFileURL.path)
        XCTAssertEqual(event.changedPaths, ["package.json", "src/index.js"])
        XCTAssertNil(batcher.flush())
    }

    func testWatchBatcherRepresentsRootLevelEvents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var batcher = ConjetFSWatchBatcher(root: root)
        batcher.insert(rawPaths: [root.path])

        let event = try XCTUnwrap(batcher.flush())

        XCTAssertEqual(event.changedPaths, ["."])
    }

    private func createProjectFiles(root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules/react", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("target/debug", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"{"name":"conjetfs-test"}"#.write(
            to: root.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        try "console.log('conjet')\n".write(
            to: root.appendingPathComponent("src/index.js"),
            atomically: true,
            encoding: .utf8
        )
        try "module.exports = {}\n".write(
            to: root.appendingPathComponent("node_modules/react/index.js"),
            atomically: true,
            encoding: .utf8
        )
        try "binary\n".write(
            to: root.appendingPathComponent("target/debug/app"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjetfs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class FakeConjetFSDockerRunner {
    private(set) var commands: [[String]] = []
    private(set) var inputCommands: [(arguments: [String], standardInput: Data?)] = []
    var failFastCopy = false

    var copyIntoVolumeCommandCount: Int {
        commands.filter { command in
            command.starts(with: ["docker", "--context", "conjet", "run", "--rm"]) &&
                command.contains(where: { $0.contains("target=/conjetfs-stage") })
        }.count
    }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        commands.append(arguments)
        if failFastCopy, arguments.contains(where: { $0.contains("target=/conjetfs-stage") }) {
            return ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 125,
                stdout: "",
                stderr: "docker: Error response from daemon: invalid mount config for type \"bind\": bind source path does not exist\n"
            )
        }
        let stdout = arguments.contains("-d") ? "conjetfs-test-container\n" : "ok\n"
        return ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: 0,
            stdout: stdout,
            stderr: ""
        )
    }

    func runWithInput(_ executable: String, _ arguments: [String], standardInput: Data?) throws -> ProcessResult {
        inputCommands.append((arguments: arguments, standardInput: standardInput))
        return ProcessResult(
            executable: executable,
            arguments: arguments,
            exitCode: 0,
            stdout: "ok\n",
            stderr: ""
        )
    }
}

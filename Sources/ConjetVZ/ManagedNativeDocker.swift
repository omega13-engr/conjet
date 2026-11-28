import ConjetCore
import CryptoKit
import Darwin
import Foundation

final class ManagedNativeDocker {
    private let paths: ConjetPaths
    private let executable: String
    private let assets: URL
    private let root: URL
    private let state: URL
    private let memoryMiB: Int
    private let enableHostMounts: Bool
    private let qualification: Qualification?
    private var boot: ConjetCoreRustVMMRun?
    private var endpoint: ConjetCoreRustVMMRun?
    private var session: URL?

    init(paths: ConjetPaths, enableHostMounts: Bool, memoryMiB: Int) throws {
        guard let executable = ConjetCoreRustVMMTool.packagedNative() else {
            throw ConjetError.unavailable("The packaged Conjet Core VMM for Native Docker is missing")
        }
        self.memoryMiB = try Self.validateMemoryMiB(memoryMiB)
        self.paths = paths
        self.executable = executable
        self.assets = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("NativeCore")
        self.root = paths.runDirectory.resolvingSymlinksInPath()
        self.state = root.appendingPathComponent("native-data", isDirectory: true)
        self.enableHostMounts = enableHostMounts
        self.qualification = try Qualification.read(paths: paths, state: state)
        guard paths.dockerSocket.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path,
              root.appendingPathComponent("cn-XXXXXX/memory-control.sock").path.utf8CString.count <= 104 else {
            throw ConjetError.unavailable("The profile path is too long for native Docker sockets")
        }
    }

    static func validateMemoryMiB(_ value: Int) throws -> Int {
        guard (512...8192).contains(value) else {
            throw ConjetError.invalidArgument("Native Docker memory must be between 512 and 8192 MiB")
        }
        return value
    }

    var isRunning: Bool { boot?.isRunning == true && endpoint?.isRunning == true }

    func start() throws {
        guard !isRunning else { return }
        let manager = FileManager.default
        try makePrivateDirectory(root)
        try makePrivateDirectory(state)
        let image = try contents(assets.appendingPathComponent("boot-image"))
        guard let digest = image.split(separator: "@").last,
              digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ConjetError.decoding("Invalid packaged native boot image reference")
        }
        let manifestID = digest.dropFirst(7)
        let layout = state.appendingPathComponent("layout-\(manifestID)", isDirectory: true)
        if !manager.fileExists(atPath: layout.path) {
            let temporary = state.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? manager.removeItem(at: temporary) }
            try manager.copyItem(at: assets.appendingPathComponent("BootOCI"), to: temporary)
            try makePrivateDirectory(temporary)
            try manager.moveItem(at: temporary, to: layout)
        }
        try makePrivateDirectory(layout)
        let staged = state.appendingPathComponent("boot-\(manifestID)", isDirectory: true)
        if !manager.fileExists(atPath: staged.path) {
            try check(executable, scoped(["docker-stage", "--layout", layout.path,
                                          "--manifest-digest", String(digest), "--output", staged.path]))
        }
        let receipt = staged.appendingPathComponent("receipt.json")
        let record = try JSONDecoder().decode(BootReceipt.self, from: Data(contentsOf: receipt))
        guard record.manifest_digest == digest else {
            throw ConjetError.decoding("Packaged native boot receipt has a different digest")
        }
        let disk = state.appendingPathComponent("volume.raw")
        if !manager.fileExists(atPath: disk.path) {
            let scratch = state.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try makePrivateDirectory(scratch)
            defer { try? manager.removeItem(at: scratch) }
            try check("/usr/bin/tar", ["-xzf", assets.appendingPathComponent("volume.tar.gz").path,
                                     "-C", scratch.path, "--no-same-owner", "volume.raw"])
            try manager.moveItem(at: scratch.appendingPathComponent("volume.raw"), to: disk)
        }
        let images = state.appendingPathComponent("images", isDirectory: true)
        try makePrivateDirectory(images)
        let buildClient = configureBuildClient()
        let binds = state.appendingPathComponent("binds", isDirectory: true)
        if enableHostMounts { try makePrivateDirectory(binds) }
        let kernel = assets.appendingPathComponent("Image")
        guard let kernelSHA = try contents(assets.appendingPathComponent("kernel.sha512")).split(separator: " ").first else {
            throw ConjetError.decoding("Missing packaged native Core kernel checksum")
        }

        let readyLog = paths.logsDirectory.appendingPathComponent("native-boot.jsonl")
        let boot = try process([
            "docker-boot", "--scratch", root.path,
            "--memory-mib", String(memoryMiB),
            "--kernel", kernel.path, "--kernel-sha512", String(kernelSHA),
            "--oci-package", staged.appendingPathComponent("package.json").path,
            "--sha256", record.package_sha256,
            "--guest-memd", assets.appendingPathComponent("conjet-memd").path,
            "--guest-reclaimd", assets.appendingPathComponent("conjet-reclaimd").path,
            "--core-dynamic-memory", "--volume-disk", disk.path,
            "--build-snapshot-disk", "--disk-image-store"
        ] + (qualification == .pressure ? ["--core-pressure-fixture"] : [])
          + (enableHostMounts ? ["--bind-filesystem"] : []), stdout: readyLog, stderrName: "native-boot.stderr.log")
        self.boot = boot
        do {
            try boot.start()
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, boot.isRunning {
                if let data = try? Data(contentsOf: readyLog), data.count < 64 * 1024,
                   let line = data.split(separator: 10).first,
                   let ready = try? JSONDecoder().decode(BootReady.self, from: line),
                   ready.pid == boot.processIdentifier, ready.owner == "native" {
                    let session = URL(fileURLWithPath: ready.session)
                    guard session.deletingLastPathComponent().path == root.path else {
                        throw ConjetError.unavailable("Native Docker VM reported a session outside its profile")
                    }
                    self.session = session
                    let endpoint = try process([
                        "docker-serve", "--native-session", session.path, "--socket", paths.dockerSocket.path,
                        "--image", image, "--receipt", receipt.path, "--image-store", images.path,
                        "--pinned-public-registry", "--pinned-build-registry"
                    ] + (qualification?.coldImageStore == true ? [] : ["--boot-layout", layout.path])
                      + (qualification?.registryArguments ?? []) + buildClient
                      + (enableHostMounts ? ["--bind-root", binds.path] : []),
                    stdout: paths.logsDirectory.appendingPathComponent("native-docker.jsonl"),
                    stderrName: "native-docker.stderr.log")
                    self.endpoint = endpoint
                    try endpoint.start()
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw ConjetError.unavailable(boot.resultSnapshot()?.message ?? "Native Docker VM did not become ready")
        } catch {
            _ = stop()
            throw error
        }
    }

    func stop() -> Bool {
        let bootWasLost = boot.map { !$0.isRunning } ?? false
        let adapterStopped = endpoint.map { !$0.isRunning || $0.stop(timeoutSeconds: 15) } ?? true
        let bootStopped = boot.map { !$0.isRunning || $0.stop(timeoutSeconds: 15) } ?? true
        guard adapterStopped && bootStopped else { return false }
        if let session, !Self.sessionRemoved(session),
           (!bootWasLost || !Self.reapLostSession(session, in: root)) {
            return false
        }
        endpoint = nil
        boot = nil
        session = nil
        return true
    }

    private static func sessionRemoved(_ session: URL) -> Bool {
        var info = stat()
        return lstat(session.path, &info) == -1 && errno == ENOENT
    }

    static func reapLostSession(_ session: URL, in root: URL) -> Bool {
        guard session.deletingLastPathComponent().path == root.path,
              session.lastPathComponent.hasPrefix("cn-") else { return false }
        var info = stat()
        guard lstat(session.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { return false }
        do {
            try FileManager.default.removeItem(at: session)
            return true
        } catch {
            return false
        }
    }

    var memoryControlSocketPath: String? {
        session?.appendingPathComponent("memory-control.sock").path
    }

    var diagnostic: String? { endpoint?.resultSnapshot()?.message ?? boot?.resultSnapshot()?.message }

    private func configureBuildClient() -> [String] {
        do {
            let dockerPath = try DockerCLIResolver.docker()
            let docker = URL(fileURLWithPath: dockerPath).resolvingSymlinksInPath()
            let dockerConfig = ProcessInfo.processInfo.environment["DOCKER_CONFIG"]
            let configuredPlugin = dockerConfig.flatMap { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path).appendingPathComponent("cli-plugins/docker-buildx") : nil
            }
            let candidates = ([configuredPlugin].compactMap { $0 } + [
                URL(fileURLWithPath: "/opt/homebrew/lib/docker/cli-plugins/docker-buildx"),
                URL(fileURLWithPath: "/usr/local/lib/docker/cli-plugins/docker-buildx"),
                URL(fileURLWithPath: "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-buildx"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/cli-plugins/docker-buildx")
            ]).map { $0.resolvingSymlinksInPath() }
            guard let buildx = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw ConjetError.unavailable("Docker Buildx executable was not found in the standard plugin directories")
            }

            let config = state.appendingPathComponent("build-client", isDirectory: true)
            let plugins = config.appendingPathComponent("cli-plugins", isDirectory: true)
            try makePrivateDirectory(config)
            try makePrivateDirectory(plugins)
            let dockerCopy = config.appendingPathComponent("docker")
            try copyClient(docker, to: dockerCopy, sha256: digest(docker))
            try copyClient(buildx, to: plugins.appendingPathComponent("docker-buildx"), sha256: digest(buildx))
            return ["--build-client-docker", dockerCopy.path, "--build-client-config", config.path]
        } catch {
            NSLog("Native Docker build API unavailable: %@", String(describing: error))
            return []
        }
    }

    private func digest(_ url: URL) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ConjetError.filesystem("Cannot open native Docker client \(url.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let limit = 128 * 1024 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0 || info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0, info.st_mode & 0o111 != 0,
              info.st_size > 0, info.st_size <= limit else {
            throw ConjetError.filesystem("Invalid native Docker client \(url.path)")
        }
        var sha256 = SHA256()
        var remaining = limit
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            remaining -= data.count
            guard remaining >= 0 else { throw ConjetError.filesystem("Native Docker client exceeds its size limit") }
            sha256.update(data: data)
        }
        return sha256.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copyClient(_ source: URL, to destination: URL, sha256: String) throws {
        let manager = FileManager.default
        if manager.isExecutableFile(atPath: destination.path), (try? digest(destination)) == sha256 { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        guard try digest(temporary) == sha256, chmod(temporary.path, 0o500) == 0,
              rename(temporary.path, destination.path) == 0 else {
            throw ConjetError.filesystem("Unable to install verified native Docker build client")
        }
    }

    private func scoped(_ options: [String]) -> [String] { ["native", "--profile-root", root.path] + options }

    private func process(_ options: [String], stdout: URL, stderrName: String) throws -> ConjetCoreRustVMMRun {
        try ConjetCoreRustVMMRun(
            executable: executable, arguments: scoped(options), stdoutPath: stdout.path,
            stderrPath: paths.logsDirectory.appendingPathComponent(stderrName).path,
            environment: ["PATH": "/usr/bin:/bin"]
        )
    }

    private func check(_ executable: String, _ arguments: [String]) throws {
        let result = try ProcessRunner.run(executable, arguments, timeoutSeconds: 30)
        guard result.succeeded else {
            throw ConjetError.processFailed(executable: executable, exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private func makePrivateDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
            throw ConjetError.filesystem("Cannot create native Docker directory \(url.path)")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ConjetError.filesystem("Cannot open native Docker directory \(url.path)") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else {
            throw ConjetError.filesystem("Cannot secure native Docker directory \(url.path)")
        }
    }

    private func contents(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ConjetError.filesystem("Cannot read packaged native Core asset \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private struct BootReceipt: Decodable {
        let manifest_digest: String
        let package_sha256: String
    }

    private struct BootReady: Decodable {
        let pid: Int32
        let owner: String
        let session: String
    }

    private enum Qualification: Equatable {
        case coldPublicBuild
        case registry(UInt16)
        case pressure

        var coldImageStore: Bool { self != .pressure }

        var registryArguments: [String] {
            guard case .registry(let port) = self else { return [] }
            return ["--registry", "127.0.0.1:\(port)"]
        }

        static func read(paths: ConjetPaths, state: URL) throws -> Self? {
            let environment = ProcessInfo.processInfo.environment
            guard let mode = environment["CONJET_NATIVE_QUALIFICATION"] else { return nil }
            let scratch = URL(fileURLWithPath: "/Volumes/ExternalSSD/dev_workspace/tmp").resolvingSymlinksInPath()
            let workspace = paths.home.deletingLastPathComponent()
            let docker = URL(fileURLWithPath: environment["DOCKER_CONFIG"] ?? "")
            func isPrivateScratch(_ path: URL) -> Bool {
                var info = stat()
                return path.path.hasPrefix(scratch.path + "/")
                    && path.resolvingSymlinksInPath().path == path.path
                    && lstat(path.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
                    && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
            }
            var stateInfo = stat()
            guard environment["CONJET_HOME"] == paths.home.path,
                  environment["CONJET_DISABLE_MENU_BAR_APP"] == "1",
                  environment["CONJET_DISABLE_BACKGROUND_SERVICE_REGISTRATION"] == "1",
                  environment["DOCKER_CONFIG"] == docker.path,
                  docker.path.hasPrefix(workspace.path + "/"),
                  isPrivateScratch(workspace),
                  isPrivateScratch(paths.home),
                  isPrivateScratch(docker),
                  lstat(state.path, &stateInfo) == -1 && errno == ENOENT else {
                throw ConjetError.invalidArgument("Native qualification requires a fresh private ExternalSSD profile and Docker configuration")
            }
            switch mode {
            case "cold-public-build": return .coldPublicBuild
            case "pressure": return .pressure
            default:
                if let value = mode.split(separator: ":", maxSplits: 1).last,
                   mode.hasPrefix("registry:"), let port = UInt16(value), port >= 1024 {
                    return .registry(port)
                }
                throw ConjetError.invalidArgument("Unknown native qualification input")
            }
        }
    }
}

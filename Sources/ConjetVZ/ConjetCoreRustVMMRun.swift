import ConjetCore
import Darwin
import Foundation

final class ConjetCoreRustVMMRun: @unchecked Sendable {
    struct ExitResult: Equatable, Sendable {
        var exitCode: Int32?
        var message: String
        var stdoutPath: String
        var stderrPath: String
    }

    private let process: Process
    private let waitSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exitResult: ExitResult?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private let stdoutPath: String
    private let stderrPath: String

    init(
        executable: String,
        arguments: [String],
        stdoutPath: String,
        stderrPath: String
    ) throws {
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        let manager = FileManager.default
        try manager.createDirectory(
            at: URL(fileURLWithPath: stdoutPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: URL(fileURLWithPath: stderrPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        manager.createFile(atPath: stdoutPath, contents: Data())
        manager.createFile(atPath: stderrPath, contents: Data())

        let stdoutHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        let stderrHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        try stdoutHandle.truncate(atOffset: 0)
        try stderrHandle.truncate(atOffset: 0)
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        self.process = process
        process.terminationHandler = { [weak self] process in
            self?.recordExit(process.terminationStatus)
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitResult == nil && process.isRunning
    }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    func start() throws {
        try process.run()
    }

    func stop(timeoutSeconds: TimeInterval) -> Bool {
        if isRunning {
            process.terminate()
        }
        if waitSemaphore.wait(timeout: .now() + max(0.1, timeoutSeconds)) == .timedOut {
            if isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            return waitSemaphore.wait(timeout: .now() + 2) != .timedOut
        }
        return true
    }

    func resultSnapshot() -> ExitResult? {
        lock.lock()
        defer { lock.unlock() }
        return exitResult
    }

    private func recordExit(_ exitCode: Int32) {
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        let diagnostics = Self.exitDiagnostics(stdoutPath: stdoutPath, stderrPath: stderrPath)
        lock.lock()
        if exitResult == nil {
            exitResult = ExitResult(
                exitCode: exitCode,
                message: Self.exitMessage(exitCode: exitCode, diagnostics: diagnostics),
                stdoutPath: stdoutPath,
                stderrPath: stderrPath
            )
        }
        lock.unlock()
        waitSemaphore.signal()
    }

    private static func exitMessage(exitCode: Int32, diagnostics: String) -> String {
        let trimmed = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.contains("0xfae94007") || lowercased.contains("hv_denied") {
            return """
            Conjet Core Rust VMM exited with status \(exitCode): Hypervisor denied VM creation (HV_DENIED/0xfae94007). Verify the Jetstream VMM executable is signed with com.apple.security.hypervisor and com.apple.security.virtualization. \(trimmed)
            """
        }
        guard !trimmed.isEmpty else {
            return "Conjet Core Rust VMM exited with status \(exitCode)"
        }
        return "Conjet Core Rust VMM exited with status \(exitCode): \(trimmed)"
    }

    private static func exitDiagnostics(stdoutPath: String, stderrPath: String) -> String {
        let parts = [
            tail(path: stderrPath, label: "stderr"),
            tail(path: stdoutPath, label: "stdout")
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    private static func tail(path: String, label: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty else {
            return nil
        }
        let suffix = data.suffix(4096)
        let text = String(decoding: suffix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "\(label): \(text)"
    }
}

struct ConjetCoreRustMemoryControlClient: Sendable {
    private let socketPath: String
    private let timeoutSeconds: Int

    init(socketPath: String, timeoutSeconds: Int = 60) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    @discardableResult
    func setTargetBytes(_ targetBytes: UInt64) throws -> Response {
        try request(Request(command: "set_target_bytes", targetBytes: targetBytes))
    }

    func metrics() throws -> Response {
        try request(Request(command: "metrics", targetBytes: nil))
    }

    @discardableResult
    func decommitOfflinedRanges(_ ranges: [ConjetMemoryRange]) throws -> Response {
        try request(Request(command: "decommit_offlined_ranges", ranges: ranges))
    }

    private func request(_ request: Request) throws -> Response {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed: \(Self.lastErrno())")
        }
        do {
            Self.disableSigpipe(fd)
            Self.setTimeout(fd, seconds: timeoutSeconds)
            try Self.withUnixSocketAddress(path: socketPath) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw ConjetError.unavailable("failed to connect to Rust memory control socket \(socketPath): \(Self.lastErrno())")
                }
            }

            var body = try ConjetJSON.encoder(pretty: false).encode(request)
            body.append(0x0A)
            try body.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < body.count {
                    let count = Darwin.write(fd, base.advanced(by: written), body.count - written)
                    if count > 0 {
                        written += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw ConjetError.socket("failed to write Rust memory control request: \(Self.lastErrno())")
                    }
                }
            }

            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while response.count < 1024 * 1024 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                        response.append(buffer, count: newline)
                        break
                    }
                    response.append(buffer, count: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ConjetError.unavailable("timed out reading Rust memory control response")
                } else {
                    break
                }
            }
            let decoded = try ConjetJSON.decoder().decode(Response.self, from: response)
            guard decoded.ok else {
                throw ConjetError.unavailable("Rust memory control rejected request: \(decoded.message)")
            }
            Darwin.close(fd)
            return decoded
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: max(1, seconds), tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { rebound in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, rebound, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, rebound, socklen_t(MemoryLayout<timeval>.size))
            }
        }
    }

    private static func disableSigpipe(_ fd: Int32) {
        var enabled: Int32 = 1
        withUnsafePointer(to: &enabled) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<Int32>.size) { rebound in
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, rebound, socklen_t(MemoryLayout<Int32>.size))
            }
        }
    }

    private static func withUnixSocketAddress<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw ConjetError.socket("Unix socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, length)
            }
        }
    }

    private static func lastErrno() -> String {
        String(cString: strerror(errno))
    }

    private struct Request: Encodable {
        var command: String
        var targetBytes: UInt64?
        var ranges: [ConjetMemoryRange]?

        init(command: String, targetBytes: UInt64? = nil, ranges: [ConjetMemoryRange]? = nil) {
            self.command = command
            self.targetBytes = targetBytes
            self.ranges = ranges
        }

        enum CodingKeys: String, CodingKey {
            case command
            case targetBytes = "target_bytes"
            case ranges
        }
    }

    struct Response: Decodable, Equatable, Sendable {
        var ok: Bool
        var message: String
        var configuredMiB: UInt64
        var targetMiB: UInt64
        var targetPages: UInt32
        var balloon: Balloon
        var hostMemory: HostMemory
        var offlinedMemoryDrop: OfflinedMemoryDrop?

        enum CodingKeys: String, CodingKey {
            case ok
            case message
            case configuredMiB = "configured_mib"
            case targetMiB = "target_mib"
            case targetPages = "target_pages"
            case balloon
            case hostMemory = "host_memory"
            case offlinedMemoryDrop = "offlined_memory_drop"
        }
    }

    struct Balloon: Decodable, Equatable, Sendable {
        var actualPages: UInt64
        var inflatePages: UInt64
        var deflatePages: UInt64
        var reportedFreePages: UInt64
        var reclaimedBytes: UInt64
        var reportedFreeReclaimedBytes: UInt64
        var reclaimFailures: UInt64
        var malformedReports: UInt64

        enum CodingKeys: String, CodingKey {
            case actualPages = "actual_pages"
            case inflatePages = "inflate_pages"
            case deflatePages = "deflate_pages"
            case reportedFreePages = "reported_free_pages"
            case reclaimedBytes = "reclaimed_bytes"
            case reportedFreeReclaimedBytes = "reported_free_reclaimed_bytes"
            case reclaimFailures = "reclaim_failures"
            case malformedReports = "malformed_reports"
        }
    }

    struct HostMemory: Decodable, Equatable, Sendable {
        var residentBytes: UInt64?
        var physicalFootprintBytes: UInt64?

        enum CodingKeys: String, CodingKey {
            case residentBytes = "resident_bytes"
            case physicalFootprintBytes = "physical_footprint_bytes"
        }
    }

    struct OfflinedMemoryDrop: Decodable, Equatable, Sendable {
        var requests: UInt64
        var requestedRanges: UInt64
        var requestedBytes: UInt64
        var appliedRanges: UInt64
        var appliedBytes: UInt64
        var failedBytes: UInt64
        var skippedBytes: UInt64
        var lastRequestedRanges: UInt64
        var lastRequestedBytes: UInt64
        var lastAppliedRanges: UInt64
        var lastAppliedBytes: UInt64
        var lastFailedBytes: UInt64
        var lastSkippedBytes: UInt64
        var lastError: String?

        enum CodingKeys: String, CodingKey {
            case requests
            case requestedRanges = "requested_ranges"
            case requestedBytes = "requested_bytes"
            case appliedRanges = "applied_ranges"
            case appliedBytes = "applied_bytes"
            case failedBytes = "failed_bytes"
            case skippedBytes = "skipped_bytes"
            case lastRequestedRanges = "last_requested_ranges"
            case lastRequestedBytes = "last_requested_bytes"
            case lastAppliedRanges = "last_applied_ranges"
            case lastAppliedBytes = "last_applied_bytes"
            case lastFailedBytes = "last_failed_bytes"
            case lastSkippedBytes = "last_skipped_bytes"
            case lastError = "last_error"
        }
    }
}

enum ConjetCoreRustVMMTool {
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> (path: String, source: String) {
        if let override = environment["CONJET_CORE_VMM_PATH"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return (override, "CONJET_CORE_VMM_PATH")
        }
        if let bundled = bundledTool() {
            return (bundled, "app bundle")
        }
        if let bundled = legacyBundledTool() {
            return (bundled, "legacy app bundle")
        }
        if let sibling = siblingTool(environment: environment) {
            return (sibling, "sibling executable")
        }
        if let sibling = legacySiblingTool(environment: environment) {
            return (sibling, "legacy sibling executable")
        }
        if let local = localCargoTool() {
            return (local, "Cargo build")
        }
        if let path = findExecutable(named: "jetstream", environment: environment) {
            return (path, "PATH")
        }
        return ("/usr/bin/env", "env fallback")
    }

    @discardableResult
    static func ensureHVFEntitlementsIfPossible(
        executable: String,
        source: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        #if os(macOS)
        guard executable != "/usr/bin/env" else {
            return false
        }
        let executableURL = URL(fileURLWithPath: executable).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return false
        }
        if binaryHasHVFEntitlements(executableURL) {
            return false
        }
        if try repairLocalDebugSigningIfPossible(executableURL: executableURL, environment: environment) {
            return true
        }
        throw ConjetError.unavailable(
            """
            Jetstream VMM executable from \(source) is missing Hypervisor entitlements: \(executableURL.path). \
            Sign it with build-support/sign-debug.sh for local source builds, or reinstall a signed Conjet.app.
            """
        )
        #else
        _ = executable
        _ = source
        _ = environment
        return false
        #endif
    }

    #if os(macOS)
    static func isLocalDebugJetstreamExecutableForSigning(
        _ executableURL: URL,
        repositoryRoot: URL
    ) -> Bool {
        let executable = executableURL.standardizedFileURL
        guard executable.lastPathComponent == "jetstream" else {
            return false
        }
        let root = repositoryRoot.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard executable.path.hasPrefix(rootPath) else {
            return false
        }
        let relativePath = String(executable.path.dropFirst(rootPath.count))
        return relativePath == "target/debug/jetstream"
            || relativePath == "target/release/jetstream"
            || relativePath == "jetstream/target/debug/jetstream"
            || relativePath == "jetstream/target/release/jetstream"
    }

    private static func repairLocalDebugSigningIfPossible(
        executableURL: URL,
        environment: [String: String]
    ) throws -> Bool {
        guard let root = repositoryRoot(containing: executableURL, environment: environment),
              isLocalDebugJetstreamExecutableForSigning(executableURL, repositoryRoot: root) else {
            return false
        }
        let entitlements = root.appendingPathComponent("build-support/conjet-debug.entitlements")
        guard FileManager.default.fileExists(atPath: entitlements.path) else {
            return false
        }
        let result = try ProcessRunner.run("/usr/bin/codesign", [
            "--force",
            "--sign", "-",
            "--entitlements", entitlements.path,
            executableURL.path
        ])
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return true
    }

    private static func binaryHasHVFEntitlements(_ executableURL: URL) -> Bool {
        guard let result = try? ProcessRunner.run("/usr/bin/codesign", [
            "-d",
            "--entitlements", ":-",
            executableURL.path
        ]) else {
            return false
        }
        let output = result.stdout + result.stderr
        return output.contains("com.apple.security.hypervisor")
            && output.contains("com.apple.security.virtualization")
    }

    private static func repositoryRoot(
        containing executableURL: URL,
        environment: [String: String]
    ) -> URL? {
        if let explicit = explicitRepositoryRoot(environment: environment) {
            return explicit
        }
        var directory = executableURL.standardizedFileURL.deletingLastPathComponent()
        let manager = FileManager.default
        var visited = Set<String>()
        while directory.path != "/", visited.insert(directory.path).inserted {
            let entitlements = directory.appendingPathComponent("build-support/conjet-debug.entitlements")
            if manager.fileExists(atPath: entitlements.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func explicitRepositoryRoot(environment: [String: String]) -> URL? {
        let candidates = [
            environment["CONJET_SOURCE_ROOT"],
            environment["SWIFT_PACKAGE_DIR"],
            environment["PWD"],
            FileManager.default.currentDirectoryPath
        ].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL
            let entitlements = url.appendingPathComponent("build-support/conjet-debug.entitlements")
            if FileManager.default.fileExists(atPath: entitlements.path) {
                return url
            }
        }
        return nil
    }
    #endif

    private static func bundledTool() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourceURL
            .appendingPathComponent("ConjetTools", isDirectory: true)
            .appendingPathComponent("ConjetCoreVMM", isDirectory: true)
            .appendingPathComponent("Conjet Core")
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func legacyBundledTool() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourceURL
            .appendingPathComponent("ConjetTools", isDirectory: true)
            .appendingPathComponent("ConjetCoreVMM", isDirectory: true)
            .appendingPathComponent("jetstream")
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func siblingTool(environment: [String: String]) -> String? {
        let executables = ([currentExecutableURL(), Bundle.main.executableURL] + commandLineExecutableCandidates(environment: environment).map(Optional.some))
            .compactMap { $0 }
        var seen = Set<String>()
        for executable in executables {
            for base in [
                executable.standardizedFileURL.deletingLastPathComponent(),
                executable.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
            ] {
                let candidate = base
                    .appendingPathComponent("ConjetCoreVMM", isDirectory: true)
                    .appendingPathComponent("Conjet Core")
                    .standardizedFileURL
                    .path
                guard seen.insert(candidate).inserted else { continue }
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func legacySiblingTool(environment: [String: String]) -> String? {
        let executables = ([currentExecutableURL(), Bundle.main.executableURL] + commandLineExecutableCandidates(environment: environment).map(Optional.some))
            .compactMap { $0 }
        var seen = Set<String>()
        for executable in executables {
            for base in [
                executable.standardizedFileURL.deletingLastPathComponent(),
                executable.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
            ] {
                let candidate = base
                    .appendingPathComponent("ConjetCoreVMM", isDirectory: true)
                    .appendingPathComponent("jetstream")
                    .standardizedFileURL
                    .path
                guard seen.insert(candidate).inserted else { continue }
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func localCargoTool() -> String? {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let directories = [
            current.appendingPathComponent("target/release", isDirectory: true),
            current.appendingPathComponent("target/debug", isDirectory: true),
            current.appendingPathComponent("jetstream/target/release", isDirectory: true),
            current.appendingPathComponent("jetstream/target/debug", isDirectory: true)
        ]
        for directory in directories {
            let candidate = directory.appendingPathComponent("jetstream").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        guard _NSGetExecutablePath(buffer, &size) == 0 else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: buffer))
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

    private static func findExecutable(named name: String, environment: [String: String]) -> String? {
        let path = ConjetEnvironment.mergedExecutableSearchPath(environment["PATH"])
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

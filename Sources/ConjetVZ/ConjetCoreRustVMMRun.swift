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
        let message = Self.exitMessage(exitCode: exitCode, stdoutPath: stdoutPath, stderrPath: stderrPath)
        lock.lock()
        if exitResult == nil {
            exitResult = ExitResult(
                exitCode: exitCode,
                message: message,
                stdoutPath: stdoutPath,
                stderrPath: stderrPath
            )
        }
        lock.unlock()
        waitSemaphore.signal()
    }

    private static func exitMessage(exitCode: Int32, stdoutPath: String, stderrPath: String) -> String {
        let base = "Conjet Core Rust VMM exited with status \(exitCode)"
        guard let detail = diagnosticSummary(paths: [stderrPath, stdoutPath]) else {
            return base
        }
        return "\(base): \(detail)"
    }

    private static func diagnosticSummary(paths: [String]) -> String? {
        for path in paths {
            guard let text = tailText(path: path) else { continue }
            let lines = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let error = lines.last(where: { $0.hasPrefix("Error:") }) {
                return error
            }
            if let message = lines.last(where: { $0.contains(#""message""#) || $0.contains(#""detail""#) }) {
                return message
            }
            if let fallback = lines.last(where: { $0 != "}" && $0 != "]" }) {
                return fallback
            }
        }
        return nil
    }

    private static func tailText(path: String, maxBytes: UInt64 = 64 * 1024) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
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

        init(command: String, targetBytes: UInt64? = nil) {
            self.command = command
            self.targetBytes = targetBytes
        }

        enum CodingKeys: String, CodingKey {
            case command
            case targetBytes = "target_bytes"
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
        var memoryLedger: MemoryLedger?

        enum CodingKeys: String, CodingKey {
            case ok
            case message
            case configuredMiB = "configured_mib"
            case targetMiB = "target_mib"
            case targetPages = "target_pages"
            case balloon
            case hostMemory = "host_memory"
            case memoryLedger = "memory_ledger"
        }
    }

    struct Balloon: Decodable, Equatable, Sendable {
        var mustTellHostNegotiated: Bool?
        var pageReportingNegotiated: Bool?
        var reportingQueueReady: Bool?
        var freePageHintNegotiated: Bool?
        var freePageHintQueueReady: Bool?
        var actualPages: UInt64
        var inflatePages: UInt64
        var deflatePages: UInt64
        var reportedFreePages: UInt64
        var reportedFreeBytes: UInt64?
        var softReclaimedBytes: UInt64?
        var reusableReclaimedBytes: UInt64?
        var reusableRestoredBytes: UInt64?
        var currentBalloonReusableBytes: UInt64?
        var zeroSweptBytes: UInt64?
        var zeroSweepFailedBytes: UInt64?
        var hardDecommittedBytes: UInt64?
        var balloonOwnedReclaimedBytes: UInt64?
        var reportInFlightReclaimedBytes: UInt64?
        var reclaimedBytes: UInt64
        var reportedFreeReclaimedBytes: UInt64
        var reclaimFailures: UInt64
        var reuseFailures: UInt64?
        var malformedReports: UInt64

        enum CodingKeys: String, CodingKey {
            case mustTellHostNegotiated = "must_tell_host_negotiated"
            case pageReportingNegotiated = "page_reporting_negotiated"
            case reportingQueueReady = "reporting_queue_ready"
            case freePageHintNegotiated = "free_page_hint_negotiated"
            case freePageHintQueueReady = "free_page_hint_queue_ready"
            case actualPages = "actual_pages"
            case inflatePages = "inflate_pages"
            case deflatePages = "deflate_pages"
            case reportedFreePages = "reported_free_pages"
            case reportedFreeBytes = "reported_free_bytes"
            case softReclaimedBytes = "soft_reclaimed_bytes"
            case reusableReclaimedBytes = "reusable_reclaimed_bytes"
            case reusableRestoredBytes = "reusable_restored_bytes"
            case currentBalloonReusableBytes = "current_balloon_reusable_bytes"
            case zeroSweptBytes = "zero_swept_bytes"
            case zeroSweepFailedBytes = "zero_sweep_failed_bytes"
            case hardDecommittedBytes = "hard_decommitted_bytes"
            case balloonOwnedReclaimedBytes = "balloon_owned_reclaimed_bytes"
            case reportInFlightReclaimedBytes = "report_inflight_reclaimed_bytes"
            case reclaimedBytes = "reclaimed_bytes"
            case reportedFreeReclaimedBytes = "reported_free_reclaimed_bytes"
            case reclaimFailures = "reclaim_failures"
            case reuseFailures = "reuse_failures"
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

    struct MemoryLedger: Decodable, Equatable, Sendable {
        var guestVisibleBytes: UInt64
        var hostGranuleBytes: UInt64
        var hostGranules: UInt64
        var residentBytes: UInt64
        var guestOwnedBytes: UInt64
        var pinnedBytes: UInt64
        var balloonOwnedBytes: UInt64
        var reportInFlightBytes: UInt64
        var discardedSoftBytes: UInt64
        var discardedHardZeroBytes: UInt64
        var cumulativeSoftDiscardedBytes: UInt64
        var cumulativeHardDecommittedBytes: UInt64
        var cumulativeBalloonAuthorizedBytes: UInt64
        var cumulativeReportAuthorizedBytes: UInt64
        var guestOwnedReclaimedBytes: UInt64
        var pinnedReclaimedBytes: UInt64
        var reclaimWithoutAuthorityBytes: UInt64
        var reportAckedBeforeReclaimBytes: UInt64
        var stateSumMismatchBytes: UInt64
        var ok: Bool

        enum CodingKeys: String, CodingKey {
            case guestVisibleBytes = "guest_visible_bytes"
            case hostGranuleBytes = "host_granule_bytes"
            case hostGranules = "host_granules"
            case residentBytes = "resident_bytes"
            case guestOwnedBytes = "guest_owned_bytes"
            case pinnedBytes = "pinned_bytes"
            case balloonOwnedBytes = "balloon_owned_bytes"
            case reportInFlightBytes = "report_inflight_bytes"
            case discardedSoftBytes = "discarded_soft_bytes"
            case discardedHardZeroBytes = "discarded_hard_zero_bytes"
            case cumulativeSoftDiscardedBytes = "cumulative_soft_discarded_bytes"
            case cumulativeHardDecommittedBytes = "cumulative_hard_decommitted_bytes"
            case cumulativeBalloonAuthorizedBytes = "cumulative_balloon_authorized_bytes"
            case cumulativeReportAuthorizedBytes = "cumulative_report_authorized_bytes"
            case guestOwnedReclaimedBytes = "guest_owned_reclaimed_bytes"
            case pinnedReclaimedBytes = "pinned_reclaimed_bytes"
            case reclaimWithoutAuthorityBytes = "reclaim_without_authority_bytes"
            case reportAckedBeforeReclaimBytes = "report_acked_before_reclaim_bytes"
            case stateSumMismatchBytes = "state_sum_mismatch_bytes"
            case ok
        }

        var status: ConjetMemoryLedgerStatus {
            ConjetMemoryLedgerStatus(
                guestVisibleBytes: guestVisibleBytes,
                hostGranuleBytes: hostGranuleBytes,
                hostGranules: hostGranules,
                residentBytes: residentBytes,
                guestOwnedBytes: guestOwnedBytes,
                pinnedBytes: pinnedBytes,
                balloonOwnedBytes: balloonOwnedBytes,
                reportInFlightBytes: reportInFlightBytes,
                discardedSoftBytes: discardedSoftBytes,
                discardedHardZeroBytes: discardedHardZeroBytes,
                cumulativeSoftDiscardedBytes: cumulativeSoftDiscardedBytes,
                cumulativeHardDecommittedBytes: cumulativeHardDecommittedBytes,
                cumulativeBalloonAuthorizedBytes: cumulativeBalloonAuthorizedBytes,
                cumulativeReportAuthorizedBytes: cumulativeReportAuthorizedBytes,
                guestOwnedReclaimedBytes: guestOwnedReclaimedBytes,
                pinnedReclaimedBytes: pinnedReclaimedBytes,
                reclaimWithoutAuthorityBytes: reclaimWithoutAuthorityBytes,
                reportAckedBeforeReclaimBytes: reportAckedBeforeReclaimBytes,
                stateSumMismatchBytes: stateSumMismatchBytes,
                ok: ok
            )
        }
    }
}

extension DynamicMemoryVMMRuntimeMetrics {
    init(_ response: ConjetCoreRustMemoryControlClient.Response) {
        self.init(
            hostResidentBytes: response.hostMemory.residentBytes,
            hostPhysicalFootprintBytes: response.hostMemory.physicalFootprintBytes,
            balloonActualPages: response.balloon.actualPages,
            balloonInflatePages: response.balloon.inflatePages,
            balloonDeflatePages: response.balloon.deflatePages,
            balloonReportedFreePages: response.balloon.reportedFreePages,
            balloonReportedFreeBytes: response.balloon.reportedFreeBytes,
            balloonReclaimedBytes: response.balloon.reclaimedBytes,
            balloonReportedFreeReclaimedBytes: response.balloon.reportedFreeReclaimedBytes,
            balloonSoftReclaimedBytes: response.balloon.softReclaimedBytes,
            balloonReusableReclaimedBytes: response.balloon.reusableReclaimedBytes,
            balloonReusableRestoredBytes: response.balloon.reusableRestoredBytes,
            balloonCurrentReusableBytes: response.balloon.currentBalloonReusableBytes,
            balloonZeroSweptBytes: response.balloon.zeroSweptBytes,
            balloonZeroSweepFailedBytes: response.balloon.zeroSweepFailedBytes,
            balloonHardDecommittedBytes: response.balloon.hardDecommittedBytes,
            balloonOwnedReclaimedBytes: response.balloon.balloonOwnedReclaimedBytes,
            balloonReportInFlightReclaimedBytes: response.balloon.reportInFlightReclaimedBytes,
            balloonReclaimFailures: response.balloon.reclaimFailures,
            balloonReuseFailures: response.balloon.reuseFailures,
            balloonMalformedReports: response.balloon.malformedReports,
            balloonMustTellHostReady: response.balloon.mustTellHostNegotiated,
            balloonPageReportingReady: response.balloon.reportingQueueReady,
            balloonFreePageHintReady: response.balloon.freePageHintQueueReady,
            memoryLedger: response.memoryLedger?.status
        )
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

import ConjetCore
import Darwin
import Foundation

public struct DockerMemoryActivity: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case streamOpened
        case streamClosed
        case streamPhaseFinished
        case workloadStarted
        case workloadFinished
        case containerStarted
        case containerStopped
    }

    public enum Workload: String, Codable, Equatable, Sendable {
        case unknown
        case build
        case pull
        case run
        case start
        case stop
        case events
        case stats
    }

    public var kind: Kind
    public var workload: Workload
    public var activeStreams: Int
    public var pressureStreams: Int
    public var buildLike: Bool

    public init(
        kind: Kind,
        workload: Workload,
        activeStreams: Int,
        pressureStreams: Int? = nil,
        buildLike: Bool
    ) {
        self.kind = kind
        self.workload = workload
        self.activeStreams = activeStreams
        self.pressureStreams = pressureStreams ?? activeStreams
        self.buildLike = buildLike
    }
}

extension DockerMemoryActivity.Workload {
    var isBuildLike: Bool {
        switch self {
        case .build, .pull, .run:
            return true
        case .unknown, .start, .stop, .events, .stats:
            return false
        }
    }

    var countsAsMemoryPressureStream: Bool {
        switch self {
        case .build, .pull, .run, .start, .stop:
            return true
        case .unknown, .events, .stats:
            return false
        }
    }
}

final class GuestMemoryMetricsClient: @unchecked Sendable {
    private let connector: any GuestConnectionConnector

    init(connector: any GuestConnectionConnector) {
        self.connector = connector
    }

    func snapshot() throws -> GuestMemoryMetrics {
        let connection = try connector.connect()
        defer { connection.close() }
        Self.setNoSigpipe(connection.fileDescriptor)
        Self.setSocketTimeout(connection.fileDescriptor, seconds: 5)
        try Self.writeHTTPGet(path: "/conjet-memory-metrics", fd: connection.fileDescriptor)
        let response = try Self.readHTTPResponse(fd: connection.fileDescriptor, maxBytes: 8 * 1024 * 1024)
        guard response.statusCode == 200 else {
            throw ConjetError.unavailable("guest memory metrics endpoint returned HTTP \(response.statusCode)")
        }
        return try ConjetJSON.decoder().decode(GuestMemoryMetrics.self, from: response.body)
    }

    @discardableResult
    func reclaim(reason: String) throws -> GuestMemoryReclaimSubmission {
        let connection = try connector.connect()
        defer { connection.close() }
        Self.setNoSigpipe(connection.fileDescriptor)
        Self.setSocketTimeout(connection.fileDescriptor, seconds: 2)
        let encodedReason = Self.percentEncode(reason)
        try Self.writeHTTPPost(path: "/conjet-memory-reclaim?reason=\(encodedReason)", fd: connection.fileDescriptor)
        let response = try Self.readHTTPResponse(fd: connection.fileDescriptor, maxBytes: 16 * 1024)
        guard response.statusCode == 202 || response.statusCode == 200 else {
            throw ConjetError.unavailable("guest memory reclaim endpoint returned HTTP \(response.statusCode)")
        }
        return try ConjetJSON.decoder().decode(GuestMemoryReclaimSubmission.self, from: response.body)
    }

    @discardableResult
    func reclaimServiceSlice(_ request: GuestServiceMemoryReclaimRequest, reason: String) throws -> GuestMemoryReclaimSubmission {
        let connection = try connector.connect()
        defer { connection.close() }
        Self.setNoSigpipe(connection.fileDescriptor)
        Self.setSocketTimeout(connection.fileDescriptor, seconds: 2)
        let path = "/conjet-memory-reclaim/service"
            + "?reason=\(Self.percentEncode(reason))"
            + "&key=\(Self.percentEncode(request.key))"
            + "&path=\(Self.percentEncode(request.path))"
            + "&bytes=\(request.bytes)"
        try Self.writeHTTPPost(path: path, fd: connection.fileDescriptor)
        let response = try Self.readHTTPResponse(fd: connection.fileDescriptor, maxBytes: 16 * 1024)
        guard response.statusCode == 202 || response.statusCode == 200 else {
            throw ConjetError.unavailable("guest service memory reclaim endpoint returned HTTP \(response.statusCode)")
        }
        return try ConjetJSON.decoder().decode(GuestMemoryReclaimSubmission.self, from: response.body)
    }

    @discardableResult
    func cancelReclaim(before epoch: UInt64) throws -> GuestMemoryReclaimStatus {
        let connection = try connector.connect()
        defer { connection.close() }
        Self.setNoSigpipe(connection.fileDescriptor)
        Self.setSocketTimeout(connection.fileDescriptor, seconds: 2)
        try Self.writeHTTPPost(path: "/conjet-memory-reclaim/cancel-before?epoch=\(epoch)", fd: connection.fileDescriptor)
        let response = try Self.readHTTPResponse(fd: connection.fileDescriptor, maxBytes: 16 * 1024)
        guard response.statusCode == 200 || response.statusCode == 202 else {
            throw ConjetError.unavailable("guest memory reclaim cancel endpoint returned HTTP \(response.statusCode)")
        }
        return try ConjetJSON.decoder().decode(GuestMemoryReclaimStatus.self, from: response.body)
    }

    func reclaimStatus(epoch: UInt64) throws -> GuestMemoryReclaimStatus {
        let connection = try connector.connect()
        defer { connection.close() }
        Self.setNoSigpipe(connection.fileDescriptor)
        Self.setSocketTimeout(connection.fileDescriptor, seconds: 2)
        try Self.writeHTTPGet(path: "/conjet-memory-reclaim/status?epoch=\(epoch)", fd: connection.fileDescriptor)
        let response = try Self.readHTTPResponse(fd: connection.fileDescriptor, maxBytes: 16 * 1024)
        guard response.statusCode == 200 else {
            throw ConjetError.unavailable("guest memory reclaim status endpoint returned HTTP \(response.statusCode)")
        }
        return try ConjetJSON.decoder().decode(GuestMemoryReclaimStatus.self, from: response.body)
    }

    func serviceMemorySlices() throws -> GuestServiceMemorySlices {
        let connection = try connector.connect()
        defer { connection.close() }
        Self.setNoSigpipe(connection.fileDescriptor)
        Self.setSocketTimeout(connection.fileDescriptor, seconds: 2)
        try Self.writeHTTPGet(path: "/conjet-memory-service-slices", fd: connection.fileDescriptor)
        let response = try Self.readHTTPResponse(fd: connection.fileDescriptor, maxBytes: 512 * 1024)
        guard response.statusCode == 200 else {
            throw ConjetError.unavailable("guest memory service slices endpoint returned HTTP \(response.statusCode)")
        }
        return try ConjetJSON.decoder().decode(GuestServiceMemorySlices.self, from: response.body)
    }

    func streamEvents(
        shouldContinue: @escaping @Sendable () -> Bool,
        onConnection: @escaping @Sendable (GuestConnection) -> Void = { _ in },
        onMetrics: @escaping @Sendable (GuestMemoryMetrics) -> Void
    ) throws {
        let connection = try connector.connect()
        onConnection(connection)
        defer { connection.close() }
        Self.setNoSigpipe(connection.fileDescriptor)
        try Self.writeHTTPGet(path: "/conjet-memory-events", fd: connection.fileDescriptor)

        var data = Data()
        var headerParsed = false
        var lineBuffer = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while shouldContinue() {
            let count = Darwin.read(connection.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if !headerParsed {
                    guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
                        if data.count > 32 * 1024 {
                            throw ConjetError.unavailable("guest memory event stream did not return HTTP headers")
                        }
                        continue
                    }
                    let headerData = data[..<range.lowerBound]
                    let headerText = String(data: headerData, encoding: .utf8) ?? ""
                    guard headerText.contains("200 OK") else {
                        throw ConjetError.unavailable("guest memory event stream was not available")
                    }
                    let bodyStart = range.upperBound
                    lineBuffer.append(data[bodyStart...])
                    data.removeAll(keepingCapacity: true)
                    headerParsed = true
                } else {
                    lineBuffer.append(data)
                    data.removeAll(keepingCapacity: true)
                }
                Self.consumeMetricLines(from: &lineBuffer, onMetrics: onMetrics)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private static func consumeMetricLines(
        from data: inout Data,
        onMetrics: @escaping @Sendable (GuestMemoryMetrics) -> Void
    ) {
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[..<newline]
            data.removeSubrange(...newline)
            let trimmed = line.filter { byte in
                byte != 0x0D && byte != 0x20 && byte != 0x09
            }
            guard !trimmed.isEmpty,
                  let metrics = try? ConjetJSON.decoder().decode(GuestMemoryMetrics.self, from: Data(trimmed)) else {
                continue
            }
            onMetrics(metrics)
        }
    }

    private static func writeHTTPGet(path: String, fd: Int32) throws {
        let request = "GET \(path) HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n"
        try writeHTTPRequest(request, fd: fd)
    }

    private static func writeHTTPPost(path: String, fd: Int32) throws {
        let request = "POST \(path) HTTP/1.1\r\nHost: conjet\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        try writeHTTPRequest(request, fd: fd)
    }

    private static func writeHTTPRequest(_ request: String, fd: Int32) throws {
        try request.withCString { pointer in
            var remaining = strlen(pointer)
            var cursor = pointer
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    cursor += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw ConjetError.socket("failed to write guest HTTP request: \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    private static func readHTTPResponse(fd: Int32, maxBytes: Int) throws -> (statusCode: Int, body: Data) {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var parsedHeader: (statusCode: Int, bodyStart: Data.Index, contentLength: Int?)?
        while response.count < maxBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
                if parsedHeader == nil,
                   let range = response.range(of: Data("\r\n\r\n".utf8)) {
                    let headerText = String(data: response[..<range.lowerBound], encoding: .utf8) ?? ""
                    let statusCode = headerText.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                    let contentLength = headerText
                        .split(separator: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { line -> Int? in
                            let value = line.split(separator: ":", maxSplits: 1).dropFirst().first?
                                .trimmingCharacters(in: .whitespaces)
                            return value.flatMap(Int.init)
                        }
                    parsedHeader = (statusCode, range.upperBound, contentLength)
                }
                if let parsedHeader,
                   let contentLength = parsedHeader.contentLength,
                   response.count - parsedHeader.bodyStart >= contentLength {
                    let bodyEnd = parsedHeader.bodyStart + contentLength
                    return (parsedHeader.statusCode, Data(response[parsedHeader.bodyStart..<bodyEnd]))
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw ConjetError.unavailable("timed out reading guest memory metrics")
            } else {
                break
            }
        }
        guard let range = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw ConjetError.unavailable("guest HTTP response did not contain headers")
        }
        let headerText = String(data: response[..<range.lowerBound], encoding: .utf8) ?? ""
        let statusCode = headerText.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return (statusCode, Data(response[range.upperBound...]))
    }

    private static func setSocketTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { rebound in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, rebound, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, rebound, socklen_t(MemoryLayout<timeval>.size))
            }
        }
    }

    private static func setNoSigpipe(_ fd: Int32) {
        var enabled: Int32 = 1
        withUnsafePointer(to: &enabled) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<Int32>.size) { rebound in
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, rebound, socklen_t(MemoryLayout<Int32>.size))
            }
        }
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "unknown"
    }
}

struct GuestMemoryReclaimSubmission: Codable, Equatable, Sendable {
    var accepted: Bool
    var epoch: UInt64
    var state: String
    var source: String
}

struct GuestMemoryReclaimStatus: Codable, Equatable, Sendable {
    var epoch: UInt64
    var state: String
    var requestedBytes: UInt64
    var observedCurrentDropBytes: UInt64
    var source: String?

    enum CodingKeys: String, CodingKey {
        case epoch
        case state
        case requestedBytes = "requested_bytes"
        case observedCurrentDropBytes = "observed_current_drop_bytes"
        case source
    }
}

struct GuestServiceMemoryReclaimRequest: Equatable, Sendable {
    var key: String
    var path: String
    var bytes: UInt64
}

struct GuestServiceMemorySlices: Codable, Equatable, Sendable {
    var version: Int
    var slices: [GuestServiceMemorySlice]
    var source: String
}

struct GuestServiceMemorySlice: Codable, Equatable, Sendable {
    var key: String
    var path: String
    var memoryCurrentBytes: UInt64
    var anonBytes: UInt64
    var fileBytes: UInt64
    var inactiveFileBytes: UInt64
    var activeFileBytes: UInt64
    var slabReclaimableBytes: UInt64
    var slabUnreclaimableBytes: UInt64
    var workingSetBytes: UInt64
    var reclaimableBytes: UInt64
    var populated: Bool

    enum CodingKeys: String, CodingKey {
        case key
        case path
        case memoryCurrentBytes = "memory_current"
        case anonBytes = "anon"
        case fileBytes = "file"
        case inactiveFileBytes = "inactive_file"
        case activeFileBytes = "active_file"
        case slabReclaimableBytes = "slab_reclaimable"
        case slabUnreclaimableBytes = "slab_unreclaimable"
        case workingSetBytes = "working_set"
        case reclaimableBytes = "reclaimable"
        case populated
    }
}

struct DynamicMemoryVMMRuntimeMetrics: Equatable, Sendable {
    var hostResidentBytes: UInt64?
    var hostPhysicalFootprintBytes: UInt64?
    var balloonActualPages: UInt64
    var balloonInflatePages: UInt64
    var balloonDeflatePages: UInt64
    var balloonReportedFreePages: UInt64
    var balloonReportedFreeBytes: UInt64?
    var balloonReclaimedBytes: UInt64
    var balloonReportedFreeReclaimedBytes: UInt64
    var balloonSoftReclaimedBytes: UInt64?
    var balloonReusableReclaimedBytes: UInt64?
    var balloonReusableRestoredBytes: UInt64?
    var balloonCurrentReusableBytes: UInt64?
    var balloonHostGranuleEligibleBytes: UInt64?
    var balloonPartialHostGranuleBytes: UInt64?
    var balloonCurrentFullyOwnedHostGranules: UInt64?
    var balloonCurrentPartiallyOwnedHostGranules: UInt64?
    var balloonZeroSweptBytes: UInt64?
    var balloonZeroSweepFailedBytes: UInt64?
    var balloonHardDecommittedBytes: UInt64?
    var balloonOwnedReclaimedBytes: UInt64?
    var balloonReportInFlightReclaimedBytes: UInt64?
    var balloonReclaimFailures: UInt64
    var balloonReuseFailures: UInt64?
    var balloonMalformedReports: UInt64
    var balloonMustTellHostReady: Bool?
    var balloonPageReportingReady: Bool?
    var balloonFreePageHintReady: Bool?
    var memoryLedger: ConjetMemoryLedgerStatus?
}

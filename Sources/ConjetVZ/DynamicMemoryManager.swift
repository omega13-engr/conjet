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
        case .unknown, .start, .stop, .events:
            return false
        }
    }

    var countsAsMemoryPressureStream: Bool {
        switch self {
        case .build, .pull, .run, .start, .stop:
            return true
        case .unknown, .events:
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

final class DynamicMemoryManager: @unchecked Sendable {
    private let policy: ConjetMemoryPolicy
    private let metricsClient: GuestMemoryMetricsClient
    private let setTargetBytes: @Sendable (UInt64) throws -> Void
    private let hostFootprintBytes: (@Sendable () throws -> UInt64?)?
    private let hostResidentBytes: (@Sendable () throws -> UInt64?)?
    private let hostFootprintConvergenceDelays: [TimeInterval]
    private let activeReclaimFootprintRefreshInterval: TimeInterval
    private var hostPressureSource: DispatchSourceMemoryPressure?
    private let lock = NSLock()
    private var running = false
    private var eventThread: Thread?
    private var eventConnection: GuestConnection?
    private var currentTargetMiB: Int
    private var activeDockerStreams = 0
    private var buildWorkloadActive = false
    private var lastMetrics: GuestMemoryMetrics?
    private var lastMetricsAt: Date?
    private var lastTargetChangeAt: Date?
    private var lastGuestReclaimAt: Date?
    private var reclaimInFlight = false
    private var lastAdjustmentReason: String?
    private var message: String?
    private var trace: [ConjetMemoryTraceEvent] = []
    private var lastHostFootprintBytes: UInt64?
    private var lastHostResidentBytes: UInt64?
    private var lastReclaimFootprintBeforeBytes: UInt64?
    private var lastReclaimFootprintAfterBytes: UInt64?
    private var lastReclaimFootprintDropBytes: UInt64?
    private var reclaimGeneration = 0
    private var activeReclaimEpoch: UInt64?
    private var idleBalloonActive = false
    private var activeServiceLowPressureSinceAt: Date?
    private var pendingReclaimWorkItems: [DispatchWorkItem] = []
    private let activeServiceReclaimDwellSeconds: TimeInterval
    private let maxTraceEvents = 64

    init(
        policy: ConjetMemoryPolicy,
        metricsClient: GuestMemoryMetricsClient,
        setTargetBytes: @escaping @Sendable (UInt64) throws -> Void,
        hostFootprintBytes: (@Sendable () throws -> UInt64?)? = nil,
        hostResidentBytes: (@Sendable () throws -> UInt64?)? = nil,
        hostFootprintConvergenceDelays: [TimeInterval] = [0, 2, 5, 10, 30],
        activeReclaimFootprintRefreshInterval: TimeInterval = 2.0,
        activeServiceReclaimDwellSeconds: TimeInterval = 30.0
    ) {
        self.policy = policy
        self.metricsClient = metricsClient
        self.setTargetBytes = setTargetBytes
        self.hostFootprintBytes = hostFootprintBytes
        self.hostResidentBytes = hostResidentBytes
        self.hostFootprintConvergenceDelays = hostFootprintConvergenceDelays
        self.activeReclaimFootprintRefreshInterval = activeReclaimFootprintRefreshInterval
        self.activeServiceReclaimDwellSeconds = max(0, activeServiceReclaimDwellSeconds)
        self.currentTargetMiB = policy.configuredMemoryMiB
    }

    func start(initialMetrics: GuestMemoryMetrics? = nil) {
        guard policy.dynamicMemoryEnabled else {
            return
        }
        lock.lock()
        running = true
        message = "dynamic memory enabled"
        lock.unlock()
        startHostMemoryPressureSource()

        if let initialMetrics {
            apply(metrics: initialMetrics, reason: "vm.started", at: Date())
        } else {
            requestSnapshot(reason: "vm.started")
        }
        let thread = Thread { [weak self] in
            self?.eventLoop()
        }
        thread.name = "dev.conjet.dynamic-memory"
        lock.lock()
        eventThread = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        activeReclaimEpoch = nil
        reclaimInFlight = false
        idleBalloonActive = false
        activeServiceLowPressureSinceAt = nil
        pendingReclaimWorkItems.forEach { $0.cancel() }
        pendingReclaimWorkItems.removeAll()
        let connection = eventConnection
        eventConnection = nil
        eventThread = nil
        let pressureSource = hostPressureSource
        hostPressureSource = nil
        lock.unlock()
        connection?.close()
        pressureSource?.cancel()
    }

    func forceRecompute(reason: String) throws {
        let metrics = try metricsClient.snapshot()
        apply(metrics: metrics, reason: reason, at: Date())
    }

    func handleHostMemoryPressure(_ pressure: ConjetMemoryPressureState) {
        guard pressure == .elevated || pressure == .high else {
            return
        }
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        message = "host memory pressure \(pressure.rawValue); requesting guest reclaim"
        lock.unlock()
        requestSnapshot(reason: "host.pressure.\(pressure.rawValue)")
    }

    func handleDockerActivity(_ activity: DockerMemoryActivity) {
        var delayedReclaim: (reason: String, generation: Int)?
        var cancelGuestReclaimBefore: UInt64?
        var restoreIdleBalloon = false
        lock.lock()
        activeDockerStreams = max(0, activity.pressureStreams)
        activeServiceLowPressureSinceAt = nil
        switch activity.kind {
        case .streamOpened, .workloadStarted:
            if activity.buildLike {
                buildWorkloadActive = true
            }
            reclaimGeneration += 1
            cancelPendingReclaimWorkItemsLocked()
            cancelGuestReclaimBefore = activeReclaimEpoch.map { $0 + 1 }
            restoreIdleBalloon = idleBalloonActive || currentTargetMiB < policy.configuredMemoryMiB
        case .streamPhaseFinished:
            if activity.buildLike {
                reclaimGeneration += 1
                delayedReclaim = ("docker.streamPhaseFinished.final", reclaimGeneration)
            }
        case .streamClosed, .workloadFinished, .containerStopped:
            if activeDockerStreams == 0 {
                buildWorkloadActive = false
                reclaimGeneration += 1
                delayedReclaim = ("docker.\(activity.kind.rawValue).final", reclaimGeneration)
            }
        case .containerStarted:
            reclaimGeneration += 1
            cancelPendingReclaimWorkItemsLocked()
            cancelGuestReclaimBefore = activeReclaimEpoch.map { $0 + 1 }
            restoreIdleBalloon = idleBalloonActive || currentTargetMiB < policy.configuredMemoryMiB
        }
        lock.unlock()

        if restoreIdleBalloon {
            restoreConfiguredTarget(reason: "docker.\(activity.kind.rawValue).restore")
        }
        if let cancelGuestReclaimBefore {
            cancelGuestReclaim(before: cancelGuestReclaimBefore)
        }
        requestSnapshot(reason: "docker.\(activity.kind.rawValue)")
        if let delayedReclaim {
            schedulePostWorkloadReclaims(reason: delayedReclaim.reason, generation: delayedReclaim.generation)
        }
    }

    func status() -> ConjetMemoryRuntimeStatus {
        lock.lock()
        let metrics = lastMetrics
        let metricsAt = lastMetricsAt
        let target = currentTargetMiB
        let streams = activeDockerStreams
        let build = buildWorkloadActive
            || metrics?.buildWorkloadDetected == true
        let guestWorkload = metrics.map(Self.hasActiveGuestWorkload) == true
        let reason = lastAdjustmentReason
        let targetChange = lastTargetChangeAt
        let statusMessage = message
        let traceSnapshot = trace
        let hostFootprintMiB = lastHostFootprintBytes.map(Self.bytesToMiB)
        let hostResidentMiB = lastHostResidentBytes.map(Self.bytesToMiB)
        let hostReclaimedMiB = lastReclaimFootprintDropBytes.map(Self.bytesToMiB)
        lock.unlock()

        let guestAvailableMiB = metrics.map { Self.bytesToMiB($0.memAvailableBytes) }
        let containerMiB = metrics.map { Self.bytesToMiB($0.containerMemoryCurrentBytes) }
        let buildCgroupMiB = metrics.map { Self.bytesToMiB($0.buildCgroupMemoryCurrentBytes) }
        let daemonCgroupMiB = metrics.map { Self.bytesToMiB($0.daemonCgroupMemoryCurrentBytes) }
        let serviceCgroupMiB = metrics.map { Self.bytesToMiB($0.serviceCgroupMemoryCurrentBytes) }
        let zramUsedMiB = metrics.map { Self.bytesToMiB($0.zramMemUsedTotalBytes) }
        let diskSwapUsedMiB = metrics.map { Self.bytesToMiB($0.diskSwapUsedBytes) }
        let pressure = metrics.map(Self.pressureState) ?? .unknown
        return ConjetMemoryRuntimeStatus(
            dynamicEnabled: policy.dynamicMemoryEnabled,
            mode: policy.profile,
            maxMiB: policy.configuredMemoryMiB,
            minMiB: effectiveMinimumMiB(),
            currentTargetMiB: target,
            balloonedMiB: max(0, policy.configuredMemoryMiB - target),
            hostFootprintMiB: hostFootprintMiB,
            hostResidentMiB: hostResidentMiB,
            hostReclaimedMiB: hostReclaimedMiB,
            guestAvailableMiB: guestAvailableMiB,
            containerMemoryMiB: containerMiB,
            buildCgroupMemoryMiB: buildCgroupMiB,
            daemonCgroupMemoryMiB: daemonCgroupMiB,
            serviceCgroupMemoryMiB: serviceCgroupMiB,
            zramUsedMiB: zramUsedMiB,
            diskSwapUsedMiB: diskSwapUsedMiB,
            pressure: pressure,
            activeDockerStreams: streams,
            buildWorkloadDetected: build,
            guestWorkloadDetected: guestWorkload,
            lastAdjustmentReason: reason,
            lastMetricsAt: metricsAt,
            lastTargetChangeAt: targetChange,
            message: statusMessage,
            trace: traceSnapshot
        )
    }

    private func eventLoop() {
        while isRunning() {
            do {
                try metricsClient.streamEvents(
                    shouldContinue: { [weak self] in self?.isRunning() ?? false },
                    onConnection: { [weak self] connection in
                        self?.setEventConnection(connection)
                    },
                    onMetrics: { [weak self] metrics in
                        self?.apply(metrics: metrics, reason: "guest.event", at: Date())
                    }
                )
                clearEventConnection()
            } catch {
                clearEventConnection()
                lock.lock()
                message = "guest memory event stream unavailable: \(error)"
                lock.unlock()
                restoreConfiguredTarget(reason: "guest.events.unavailable")
                return
            }
        }
    }

    private func startHostMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let pressure: ConjetMemoryPressureState = source.data.contains(.critical) ? .high : .elevated
            self?.handleHostMemoryPressure(pressure)
        }
        lock.lock()
        guard running, hostPressureSource == nil else {
            lock.unlock()
            source.cancel()
            return
        }
        hostPressureSource = source
        lock.unlock()
        source.resume()
    }

    private func requestSnapshot(reason: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, self.isRunning() else { return }
            do {
                let metrics = try self.metricsClient.snapshot()
                self.apply(metrics: metrics, reason: reason, at: Date())
            } catch {
                self.lock.lock()
                self.message = "guest memory metrics unavailable: \(error)"
                self.lock.unlock()
            }
        }
    }

    private func requestSnapshot(reason: String, generation: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldRun = self.running && self.reclaimGeneration == generation
            self.lock.unlock()
            guard shouldRun else { return }
            do {
                let metrics = try self.metricsClient.snapshot()
                self.apply(metrics: metrics, reason: reason, at: Date())
            } catch {
                self.lock.lock()
                self.message = "guest memory metrics unavailable: \(error)"
                self.lock.unlock()
            }
        }
    }

    private func schedulePostWorkloadReclaims(reason: String, generation: Int) {
        for (suffix, delay) in [("quiesced", 0.15), ("observe", 1.0)] {
            let scheduledReason = "\(reason).\(suffix)"
            let item = DispatchWorkItem { [weak self] in
                self?.requestSnapshot(reason: scheduledReason, generation: generation)
            }
            lock.lock()
            if running && reclaimGeneration == generation {
                pendingReclaimWorkItems.append(item)
            }
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func apply(metrics: GuestMemoryMetrics, reason: String, at now: Date) {
        lock.lock()
        lastMetrics = metrics
        lastMetricsAt = now
        let pressure = Self.pressureState(metrics)
        let shouldRestoreIdleBalloon = idleBalloonActive
            && shouldRestoreIdleBalloonLocked(metrics: metrics, pressure: pressure)
        let idleRefinementTargetMiB = idleBalloonRefinementTargetLocked(
            metrics: metrics,
            pressure: pressure
        )
        let activeServiceIdleReclaimReady = activeServiceIdleReclaimReadyLocked(
            metrics: metrics,
            pressure: pressure,
            reason: reason,
            now: now
        )
        let shouldReclaim = shouldRequestGuestReclaimLocked(
            metrics: metrics,
            pressure: pressure,
            reason: reason,
            now: now,
            activeServiceIdleReclaimReady: activeServiceIdleReclaimReady
        )
        let traceTargetMiB = currentTargetMiB
        recordTraceLocked(
            ConjetMemoryTraceEvent(
                timestamp: now,
                targetMiB: traceTargetMiB,
                desiredMiB: traceTargetMiB,
                action: shouldReclaim ? "reclaim" : "observe",
                reason: reason,
                pressure: pressure
            )
        )
        lastAdjustmentReason = reason
        if shouldRestoreIdleBalloon {
            message = "dynamic memory restoring configured memory before new work"
        } else if let idleRefinementTargetMiB {
            message = "demand memory target active; refining idle target to \(idleRefinementTargetMiB) MiB"
        } else if idleBalloonActive {
            message = "demand memory target active; build-like work restores configured maximum"
        } else {
            message = "dynamic memory observing guest free-page reports"
        }
        if shouldReclaim {
            lastGuestReclaimAt = now
            reclaimInFlight = true
        }
        lock.unlock()

        if shouldRestoreIdleBalloon {
            restoreConfiguredTarget(reason: "\(reason).restore")
            return
        }
        if let idleRefinementTargetMiB {
            refineIdleBalloonTarget(targetMiB: idleRefinementTargetMiB, reason: "\(reason).refine")
            return
        }
        guard shouldReclaim else { return }
        let hostFootprintBefore = sampleHostFootprintBytes()
        do {
            let submission = try metricsClient.reclaim(reason: reason)
            lock.lock()
            if submission.accepted {
                activeReclaimEpoch = submission.epoch
            }
            message = submission.accepted
                ? "guest reclaim queued epoch \(submission.epoch); waiting for Linux free-page reporting"
                : "guest reclaim was not accepted; classic balloon target unchanged"
            if !submission.accepted {
                reclaimInFlight = false
                activeReclaimEpoch = nil
            }
            lock.unlock()
            if submission.accepted {
                pollGuestReclaimUntilTerminal(epoch: submission.epoch, hostFootprintBefore: hostFootprintBefore)
            }
        } catch {
            lock.lock()
            reclaimInFlight = false
            activeReclaimEpoch = nil
            message = "guest memory reclaim unavailable: \(error); classic balloon target unchanged"
            lock.unlock()
        }
    }

    private func pollGuestReclaimUntilTerminal(epoch: UInt64, hostFootprintBefore: UInt64?) {
        let deadline = Date().addingTimeInterval(90)
        var lastStatus: GuestMemoryReclaimStatus?
        var lastActiveFootprintRefreshAt = Date.distantPast
        while Date() < deadline {
            lock.lock()
            let stillCurrent = activeReclaimEpoch == epoch
            lock.unlock()
            guard stillCurrent else { return }
            do {
                let status = try metricsClient.reclaimStatus(epoch: epoch)
                lastStatus = status
                if Self.guestReclaimStateIsTerminal(status.state) {
                    let convergence = observeHostFootprintConvergence(
                        epoch: epoch,
                        before: hostFootprintBefore
                    )
                    var shouldAttemptIdleBalloonDrop = false
                    var shouldScheduleHostFootprintRefresh = false
                    lock.lock()
                    if activeReclaimEpoch == epoch {
                        activeReclaimEpoch = nil
                        reclaimInFlight = false
                        lastReclaimFootprintBeforeBytes = hostFootprintBefore
                        lastReclaimFootprintAfterBytes = convergence.after
                        lastReclaimFootprintDropBytes = convergence.drop
                        if hostFootprintBefore != nil || convergence.after != nil || convergence.drop != nil {
                            recordTraceLocked(ConjetMemoryTraceEvent(
                                timestamp: Date(),
                                targetMiB: currentTargetMiB,
                                desiredMiB: currentTargetMiB,
                                action: "reclaim-footprint",
                                reason: "guest.reclaim.epoch.\(epoch)",
                                pressure: .unknown,
                                hostFootprintBeforeBytes: hostFootprintBefore,
                                hostFootprintAfterBytes: convergence.after,
                                hostFootprintDropBytes: convergence.drop
                            ))
                        }
                        let guestDropMiB = Self.bytesToMiB(status.observedCurrentDropBytes)
                        if let footprintDrop = convergence.drop {
                            message = "guest reclaim epoch \(epoch) \(status.state); reported \(guestDropMiB) MiB current drop; host footprint drop \(Self.bytesToMiB(footprintDrop)) MiB"
                        } else {
                            message = "guest reclaim epoch \(epoch) \(status.state); reported \(guestDropMiB) MiB current drop"
                        }
                        shouldAttemptIdleBalloonDrop = shouldAttemptIdleBalloonDropLocked()
                        shouldScheduleHostFootprintRefresh = hostFootprintBefore != nil
                            || convergence.after != nil
                            || convergence.drop != nil
                    }
                    lock.unlock()
                    if shouldScheduleHostFootprintRefresh {
                        scheduleHostFootprintRefreshes(reason: "guest.reclaim.epoch.\(epoch)")
                    }
                    if shouldAttemptIdleBalloonDrop {
                        attemptIdleBalloonDrop(
                            epoch: epoch,
                            footprintAfter: convergence.after,
                            footprintDrop: convergence.drop
                        )
                    }
                    return
                }
                let now = Date()
                if now.timeIntervalSince(lastActiveFootprintRefreshAt) >= activeReclaimFootprintRefreshInterval {
                    lastActiveFootprintRefreshAt = now
                    _ = sampleHostFootprintBytes()
                }
                lock.lock()
                if activeReclaimEpoch == epoch {
                    message = "guest reclaim epoch \(epoch) \(status.state); waiting for free-page reporting"
                }
                lock.unlock()
            } catch {
                lock.lock()
                if activeReclaimEpoch == epoch {
                    activeReclaimEpoch = nil
                    reclaimInFlight = false
                    message = "guest reclaim epoch \(epoch) status unavailable: \(error)"
                }
                lock.unlock()
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        lock.lock()
        if activeReclaimEpoch == epoch {
            activeReclaimEpoch = nil
            reclaimInFlight = false
            let lastState = lastStatus?.state ?? "unknown"
            message = "guest reclaim epoch \(epoch) deadline after state \(lastState)"
        }
        lock.unlock()
    }

    private func sampleHostFootprintBytes() -> UInt64? {
        if let hostResidentBytes {
            do {
                let resident = try hostResidentBytes()
                lock.lock()
                if let resident {
                    lastHostResidentBytes = resident
                }
                lock.unlock()
            } catch {
                lock.lock()
                message = "host resident sample unavailable: \(error)"
                lock.unlock()
            }
        }
        guard let hostFootprintBytes else { return nil }
        do {
            let sample = try hostFootprintBytes()
            lock.lock()
            if let sample {
                lastHostFootprintBytes = sample
            }
            lock.unlock()
            return sample
        } catch {
            lock.lock()
            message = "host footprint sample unavailable: \(error)"
            lock.unlock()
            return nil
        }
    }

    private func scheduleHostFootprintRefreshes(reason: String) {
        guard hostFootprintBytes != nil else { return }
        for delay in [0.5, 2.0, 5.0, 10.0] as [TimeInterval] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning() else { return }
                guard let sample = self.sampleHostFootprintBytes() else { return }
                self.lock.lock()
                self.recordTraceLocked(ConjetMemoryTraceEvent(
                    timestamp: Date(),
                    targetMiB: self.currentTargetMiB,
                    desiredMiB: self.currentTargetMiB,
                    action: "host-footprint-refresh",
                    reason: reason,
                    pressure: .unknown,
                    hostFootprintAfterBytes: sample
                ))
                self.message = "host footprint refreshed after \(reason): \(Self.bytesToMiB(sample)) MiB"
                self.lock.unlock()
            }
        }
    }

    private func observeHostFootprintConvergence(
        epoch: UInt64,
        before: UInt64?
    ) -> (after: UInt64?, drop: UInt64?) {
        guard before != nil || hostFootprintBytes != nil else {
            return (nil, nil)
        }
        var latest: UInt64?
        var previousDelay: TimeInterval = 0
        for delay in hostFootprintConvergenceDelays {
            let waitSeconds = max(0, delay - previousDelay)
            if waitSeconds > 0 && !sleepWhileReclaimCurrent(epoch: epoch, seconds: waitSeconds) {
                break
            }
            guard reclaimEpochIsCurrent(epoch) else {
                break
            }
            latest = sampleHostFootprintBytes() ?? latest
            previousDelay = delay
        }
        let drop: UInt64?
        if let before, let latest {
            drop = before > latest ? before - latest : 0
        } else {
            drop = nil
        }
        return (latest, drop)
    }

    private func sleepWhileReclaimCurrent(epoch: UInt64, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard reclaimEpochIsCurrent(epoch) else { return false }
            Thread.sleep(forTimeInterval: min(0.25, max(0.01, deadline.timeIntervalSinceNow)))
        }
        return reclaimEpochIsCurrent(epoch)
    }

    private func reclaimEpochIsCurrent(_ epoch: UInt64) -> Bool {
        lock.lock()
        let current = activeReclaimEpoch == epoch
        lock.unlock()
        return current
    }

    private func cancelGuestReclaim(before epoch: UInt64) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let status = try self.metricsClient.cancelReclaim(before: epoch)
                self.lock.lock()
                if self.activeReclaimEpoch.map({ $0 < epoch }) == true {
                    self.activeReclaimEpoch = nil
                    self.reclaimInFlight = false
                    self.message = "guest reclaim cancelled before epoch \(epoch); state \(status.state)"
                }
                self.lock.unlock()
            } catch {
                self.lock.lock()
                if self.running {
                    self.message = "guest memory reclaim cancel unavailable: \(error)"
                }
                self.lock.unlock()
            }
        }
    }

    private func shouldRequestGuestReclaimLocked(
        metrics: GuestMemoryMetrics,
        pressure: ConjetMemoryPressureState,
        reason: String,
        now: Date,
        activeServiceIdleReclaimReady: Bool
    ) -> Bool {
        guard !reclaimInFlight,
              !idleBalloonActive,
              pressure == .low,
              metrics.diskSwapUsedBytes <= Self.reclaimSwapNoiseFloorBytes,
              metrics.containerSwapCurrentBytes <= Self.reclaimSwapNoiseFloorBytes,
              metrics.containerOOMKillEvents == 0 else {
            return false
        }
        let streamPhaseFinished = reason == "docker.streamPhaseFinished"
        let hostPressureReclaim = reason.hasPrefix("host.pressure.")
        let strongCompletionReclaim = reason.hasPrefix("manual.")
            || reason == "docker.workloadFinished"
            || reason.hasPrefix("docker.workloadFinished.final.")
            || reason == "docker.containerStopped"
            || reason.hasPrefix("docker.containerStopped.final.")
        let bypassRecentReclaimCooldown = strongCompletionReclaim || hostPressureReclaim
        let activeGuestWorkload = Self.hasActiveGuestWorkload(metrics)
        if !streamPhaseFinished && !strongCompletionReclaim {
            guard !buildWorkloadActive else {
                return false
            }
            if activeGuestWorkload {
                guard activeServiceIdleReclaimReady else {
                    return false
                }
            } else if activeDockerStreams > 0 {
                return false
            }
        }
        let reasonAllowsReclaim = reason.hasPrefix("manual.")
            || streamPhaseFinished
            || reason.hasPrefix("docker.streamPhaseFinished.final.")
            || reason == "docker.streamClosed"
            || reason.hasPrefix("docker.streamClosed.final.")
            || reason == "docker.workloadFinished"
            || reason.hasPrefix("docker.workloadFinished.final.")
            || reason == "docker.containerStopped"
            || reason.hasPrefix("docker.containerStopped.final.")
            || reason == "dynamic.reclaim.idle"
            || (hostPressureReclaim && hasIdleReclaimSurplus(metrics: metrics))
            || (
                reason == "guest.event"
                    && hasIdleReclaimSurplus(metrics: metrics)
                    && (!activeGuestWorkload || activeServiceIdleReclaimReady)
            )
        guard reasonAllowsReclaim else {
            return false
        }
        if hostPressureReclaim {
            return hasIdleReclaimSurplus(metrics: metrics)
        }
        if streamPhaseFinished {
            return hasIdleReclaimSurplus(metrics: metrics)
        }
        if bypassRecentReclaimCooldown {
            return true
        }
        if let lastGuestReclaimAt,
           now.timeIntervalSince(lastGuestReclaimAt) < TimeInterval(policy.dynamicMemoryShrinkCooldownSeconds) {
            return false
        }
        return true
    }

    private func activeServiceIdleReclaimReadyLocked(
        metrics: GuestMemoryMetrics,
        pressure: ConjetMemoryPressureState,
        reason: String,
        now: Date
    ) -> Bool {
        guard reason == "guest.event",
              !idleBalloonActive,
              !reclaimInFlight,
              activeServiceIdleConditionsLocked(metrics: metrics, pressure: pressure),
              idleBalloonTargetMiB(metrics: metrics) < currentTargetMiB else {
            activeServiceLowPressureSinceAt = nil
            return false
        }

        if activeServiceLowPressureSinceAt == nil {
            activeServiceLowPressureSinceAt = now
        }
        guard let since = activeServiceLowPressureSinceAt else {
            return false
        }
        return now.timeIntervalSince(since) >= activeServiceReclaimDwellSeconds
    }

    private func activeServiceIdleConditionsLocked(
        metrics: GuestMemoryMetrics,
        pressure: ConjetMemoryPressureState
    ) -> Bool {
        !buildWorkloadActive
            && pressure == .low
            && !metrics.buildWorkloadDetected
            && Self.hasActiveGuestWorkload(metrics)
            && metrics.diskSwapUsedBytes <= Self.reclaimSwapNoiseFloorBytes
            && metrics.containerSwapCurrentBytes <= Self.reclaimSwapNoiseFloorBytes
            && metrics.containerOOMKillEvents == 0
            && hasIdleReclaimSurplus(metrics: metrics)
    }

    private static func guestReclaimStateIsTerminal(_ state: String) -> Bool {
        switch state {
        case "done", "partial", "cancelled", "error", "deadline":
            return true
        default:
            return false
        }
    }

    private func hasIdleReclaimSurplus(metrics: GuestMemoryMetrics) -> Bool {
        let availableMiB = Self.bytesToMiB(metrics.memAvailableBytes)
        let workingSetMiB = idleWorkingSetMiB(metrics: metrics)
        let surplusMiB = max(0, availableMiB - workingSetMiB)
        let cacheAllowanceMiB = max(128, policy.dynamicMemoryCacheAllowanceMiB)
        return surplusMiB >= cacheAllowanceMiB
    }

    private func idleWorkingSetMiB(metrics: GuestMemoryMetrics) -> Int {
        let workloadMiB = effectiveIdleWorkloadMiB(metrics: metrics)
        let proportionalHeadroomMiB = Int(
            (Double(workloadMiB) * policy.dynamicMemoryHeadroomRatio)
                .rounded(.up)
        )
        let headroomMiB: Int
        if Self.hasActiveGuestWorkload(metrics) || metrics.buildWorkloadDetected || activeDockerStreams > 0 || buildWorkloadActive {
            headroomMiB = max(policy.dynamicMemoryHeadroomMiB, proportionalHeadroomMiB)
        } else if workloadMiB > 0 {
            headroomMiB = max(Self.quietIdleHeadroomMiB, proportionalHeadroomMiB)
        } else {
            headroomMiB = 0
        }
        return Self.saturatingAddMiB(
            effectiveMinimumMiB(),
            Self.saturatingAddMiB(
                workloadMiB,
                Self.saturatingAddMiB(policy.dynamicMemoryBaseOverheadMiB, headroomMiB)
            )
        )
    }

    private func effectiveIdleWorkloadMiB(metrics: GuestMemoryMetrics) -> Int {
        let containerMiB = Self.bytesToMiB(metrics.containerMemoryCurrentBytes)
        let buildMiB = Self.bytesToMiB(metrics.buildCgroupMemoryCurrentBytes)
        let serviceMiB = Self.bytesToMiB(metrics.serviceCgroupMemoryCurrentBytes)
        let daemonMiB = Self.bytesToMiB(metrics.daemonCgroupMemoryCurrentBytes)
        let runtimeServiceMiB = max(containerMiB, serviceMiB)

        guard !Self.hasActiveGuestWorkload(metrics),
              !metrics.buildWorkloadDetected,
              activeDockerStreams == 0,
              !buildWorkloadActive else {
            return Self.saturatingAddMiB(
                Self.saturatingAddMiB(runtimeServiceMiB, buildMiB),
                daemonMiB
            )
        }

        return Self.saturatingAddMiB(
            max(
                max(0, containerMiB - Self.quietIdleContainerNoiseFloorMiB),
                max(0, serviceMiB - Self.quietIdleServiceNoiseFloorMiB)
            ),
            Self.saturatingAddMiB(
                buildMiB,
                max(0, daemonMiB - Self.quietIdleDaemonAllowanceMiB)
            )
        )
    }

    private func idleBalloonTargetMiB(metrics: GuestMemoryMetrics) -> Int {
        let workingSetTarget = Self.roundUpMiB(
            idleWorkingSetMiB(metrics: metrics),
            quantum: 128
        )
        return min(
            policy.configuredMemoryMiB,
            max(effectiveMinimumMiB(), workingSetTarget)
        )
    }

    private func shouldRestoreIdleBalloonLocked(
        metrics: GuestMemoryMetrics,
        pressure: ConjetMemoryPressureState
    ) -> Bool {
        let activeServiceIdle = activeServiceIdleConditionsLocked(metrics: metrics, pressure: pressure)
        return (activeDockerStreams > 0 && !activeServiceIdle)
            || buildWorkloadActive
            || metrics.buildWorkloadDetected
            || idleBalloonTargetMiB(metrics: metrics) > currentTargetMiB
            || metrics.diskSwapUsedBytes > Self.reclaimSwapNoiseFloorBytes
            || metrics.containerSwapCurrentBytes > Self.reclaimSwapNoiseFloorBytes
            || metrics.containerOOMKillEvents > 0
            || pressure == .high
    }

    private func idleBalloonRefinementTargetLocked(
        metrics: GuestMemoryMetrics,
        pressure: ConjetMemoryPressureState
    ) -> Int? {
        guard idleBalloonActive,
              !buildWorkloadActive,
              activeReclaimEpoch == nil,
              !reclaimInFlight,
              pressure == .low,
              !metrics.buildWorkloadDetected else {
            return nil
        }
        let activeGuestWorkload = Self.hasActiveGuestWorkload(metrics)
        if activeGuestWorkload,
           !activeServiceIdleConditionsLocked(metrics: metrics, pressure: pressure) {
            return nil
        }
        if !activeGuestWorkload, activeDockerStreams > 0 {
            return nil
        }
        let targetMiB = idleBalloonTargetMiB(metrics: metrics)
        return targetMiB < currentTargetMiB ? targetMiB : nil
    }

    private func shouldAttemptIdleBalloonDropLocked() -> Bool {
        guard policy.automaticIdleMemoryReclaim,
              !idleBalloonActive,
              !buildWorkloadActive,
              activeReclaimEpoch == nil,
              !reclaimInFlight,
              let metrics = lastMetrics,
              Self.pressureState(metrics) == .low,
              !metrics.buildWorkloadDetected,
              hasIdleReclaimSurplus(metrics: metrics) else {
            return false
        }
        if !Self.hasActiveGuestWorkload(metrics), activeDockerStreams > 0 {
            return false
        }
        return true
    }

    private func refineIdleBalloonTarget(targetMiB: Int, reason: String) {
        do {
            try setTargetBytes(UInt64(targetMiB) * Self.bytesPerMiB)
            var restoreAfterRace = false
            var appliedRefinement = false
            lock.lock()
            if let latestMetrics = lastMetrics,
               idleBalloonActive,
               !buildWorkloadActive,
               activeReclaimEpoch == nil,
               !reclaimInFlight,
               Self.pressureState(latestMetrics) == .low,
               !latestMetrics.buildWorkloadDetected,
               (
                   (!Self.hasActiveGuestWorkload(latestMetrics) && activeDockerStreams == 0)
                       || activeServiceIdleConditionsLocked(metrics: latestMetrics, pressure: .low)
               ),
               targetMiB < currentTargetMiB {
                currentTargetMiB = targetMiB
                lastTargetChangeAt = Date()
                lastAdjustmentReason = reason
                message = "demand memory refined idle target to \(targetMiB) MiB"
                recordTraceLocked(ConjetMemoryTraceEvent(
                    timestamp: Date(),
                    targetMiB: targetMiB,
                    desiredMiB: targetMiB,
                    action: "idle-refine",
                    reason: reason,
                    pressure: .low
                ))
                appliedRefinement = true
            } else {
                restoreAfterRace = true
            }
            lock.unlock()
            if appliedRefinement {
                _ = sampleHostFootprintBytes()
                scheduleHostFootprintRefreshes(reason: reason)
            }
            if restoreAfterRace {
                do {
                    try setTargetBytes(UInt64(policy.configuredMemoryMiB) * Self.bytesPerMiB)
                } catch {
                    lock.lock()
                    message = "idle memory refinement race restore failed: \(error)"
                    lock.unlock()
                }
            }
        } catch {
            lock.lock()
            message = "idle memory refinement target update failed: \(error)"
            lock.unlock()
        }
    }

    private func attemptIdleBalloonDrop(epoch: UInt64, footprintAfter: UInt64?, footprintDrop: UInt64?) {
        lock.lock()
        guard !idleBalloonActive,
              !buildWorkloadActive,
              let metrics = lastMetrics,
              Self.pressureState(metrics) == .low,
              !metrics.buildWorkloadDetected else {
            lock.unlock()
            return
        }
        if !Self.hasActiveGuestWorkload(metrics), activeDockerStreams > 0 {
            lock.unlock()
            return
        }
        let targetMiB = idleBalloonTargetMiB(metrics: metrics)
        guard targetMiB < currentTargetMiB else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            try setTargetBytes(UInt64(targetMiB) * Self.bytesPerMiB)
            var restoreAfterRace = false
            var appliedIdleAutodrop = false
            lock.lock()
            if !buildWorkloadActive,
               activeReclaimEpoch == nil,
               let latestMetrics = lastMetrics,
               Self.pressureState(latestMetrics) == .low,
               !latestMetrics.buildWorkloadDetected,
               (
                   Self.hasActiveGuestWorkload(latestMetrics)
                       || activeDockerStreams == 0
               ) {
                currentTargetMiB = targetMiB
                idleBalloonActive = true
                lastTargetChangeAt = Date()
                lastAdjustmentReason = "guest.reclaim.epoch.\(epoch).autodrop"
                message = "demand memory reclaim lowered guest target to \(targetMiB) MiB after guest reclaim"
                recordTraceLocked(ConjetMemoryTraceEvent(
                    timestamp: Date(),
                    targetMiB: targetMiB,
                    desiredMiB: targetMiB,
                    action: "idle-autodrop",
                    reason: "guest.reclaim.epoch.\(epoch).autodrop",
                    pressure: .low,
                    hostFootprintAfterBytes: footprintAfter,
                    hostFootprintDropBytes: footprintDrop
                ))
                appliedIdleAutodrop = true
            } else {
                restoreAfterRace = true
            }
            lock.unlock()
            if appliedIdleAutodrop {
                _ = sampleHostFootprintBytes()
                scheduleHostFootprintRefreshes(reason: "guest.reclaim.epoch.\(epoch).autodrop")
            }
            if restoreAfterRace {
                do {
                    try setTargetBytes(UInt64(policy.configuredMemoryMiB) * Self.bytesPerMiB)
                } catch {
                    lock.lock()
                    message = "idle memory autodrop race restore failed: \(error)"
                    lock.unlock()
                }
            }
        } catch {
            lock.lock()
            message = "idle memory autodrop target update failed: \(error)"
            lock.unlock()
        }
    }

    private static let reclaimSwapNoiseFloorBytes: UInt64 = 64 * 1024 * 1024
    private static let bytesPerMiB: UInt64 = 1024 * 1024
    private static let quietIdleContainerNoiseFloorMiB = 16
    private static let quietIdleServiceNoiseFloorMiB = 32
    private static let quietIdleDaemonAllowanceMiB = 256
    private static let quietIdleHeadroomMiB = 64

    private func restoreConfiguredTarget(reason: String) {
        lock.lock()
        let shouldRestore = idleBalloonActive || currentTargetMiB < policy.configuredMemoryMiB
        lock.unlock()
        guard shouldRestore else {
            return
        }
        do {
            try setTargetBytes(UInt64(policy.configuredMemoryMiB) * Self.bytesPerMiB)
        } catch {
            lock.lock()
            message = "dynamic memory failed to restore configured maximum: \(error)"
            lock.unlock()
            return
        }
        lock.lock()
        let target = policy.configuredMemoryMiB
        currentTargetMiB = target
        idleBalloonActive = false
        activeServiceLowPressureSinceAt = nil
        lastTargetChangeAt = Date()
        lastAdjustmentReason = reason
        message = "dynamic memory restored to configured maximum"
        recordTraceLocked(ConjetMemoryTraceEvent(
            timestamp: Date(),
            targetMiB: target,
            desiredMiB: target,
            action: "restore",
            reason: reason,
            pressure: .unknown
        ))
        lock.unlock()
    }

    private func recordTraceLocked(_ event: ConjetMemoryTraceEvent) {
        trace.append(event)
        if trace.count > maxTraceEvents {
            trace.removeFirst(trace.count - maxTraceEvents)
        }
    }

    private func cancelPendingReclaimWorkItemsLocked() {
        pendingReclaimWorkItems.forEach { $0.cancel() }
        pendingReclaimWorkItems.removeAll()
    }

    private func effectiveMinimumMiB() -> Int {
        min(max(256, policy.dynamicMemoryMinimumMiB), policy.configuredMemoryMiB)
    }

    private func isRunning() -> Bool {
        lock.lock()
        let value = running
        lock.unlock()
        return value
    }

    private func setEventConnection(_ connection: GuestConnection) {
        lock.lock()
        if running {
            eventConnection = connection
            lock.unlock()
        } else {
            lock.unlock()
            connection.close()
        }
    }

    private func clearEventConnection() {
        lock.lock()
        eventConnection = nil
        lock.unlock()
    }

    private static func pressureState(_ metrics: GuestMemoryMetrics) -> ConjetMemoryPressureState {
        if metrics.containerOOMKillEvents > 0 || metrics.diskSwapUsedBytes > 0 {
            return .high
        }
        if metrics.psiFullAvg10 > 0.05 {
            return .high
        }
        let memTotalMiB = max(1, bytesToMiB(metrics.memTotalBytes))
        let availableMiB = bytesToMiB(metrics.memAvailableBytes)
        let highAvailableFloorMiB = min(512, max(64, memTotalMiB / 8))
        if availableMiB < highAvailableFloorMiB {
            return .high
        }
        if metrics.psiSomeAvg10 > 0.5 {
            return .elevated
        }
        let elevatedAvailableFloorMiB = min(768, max(96, memTotalMiB / 6))
        if availableMiB < elevatedAvailableFloorMiB {
            return .elevated
        }
        return .low
    }

    private static func hasActiveGuestWorkload(_ metrics: GuestMemoryMetrics) -> Bool {
        metrics.buildWorkloadDetected
            || (metrics.activeWorkloads > 0 && bytesToMiB(metrics.containerMemoryCurrentBytes) >= 64)
    }

    private static func bytesToMiB(_ bytes: UInt64) -> Int {
        Int(bytes / 1024 / 1024)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        UInt64.max - lhs < rhs ? UInt64.max : lhs + rhs
    }

    private static func saturatingAddMiB(_ lhs: Int, _ rhs: Int) -> Int {
        Int.max - lhs < rhs ? Int.max : lhs + rhs
    }

    private static func roundUpMiB(_ value: Int, quantum: Int) -> Int {
        guard quantum > 1 else {
            return value
        }
        return ((value + quantum - 1) / quantum) * quantum
    }

}

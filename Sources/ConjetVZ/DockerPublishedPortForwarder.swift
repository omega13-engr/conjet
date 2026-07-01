import ConjetCore
import Darwin
import Foundation
import NIOCore
import NIOPosix

public typealias DockerPublishedPort = ConjetPublishedPortRequest

public final class DockerPublishedPortForwarder: @unchecked Sendable {
    public typealias Runner = @Sendable (String, [String], Double?) throws -> ProcessResult
    public typealias SuccessfulConnectionHandler = @Sendable (DockerPublishedPort) -> Void
    public typealias ActivityHandler = @Sendable (DockerMemoryActivity) -> Void
    private static let maxStatusMessages = 200
    private static let dockerEventsAPIPath =
        "/events?filters=%7B%22type%22:%5B%22container%22,%22network%22%5D,%22event%22:%5B%22create%22,%22start%22,%22restart%22,%22stop%22,%22die%22,%22destroy%22,%22connect%22,%22disconnect%22,%22network_connect%22,%22network_disconnect%22%5D%7D"

    private let socketPath: String
    private let connector: any GuestConnectionConnector
    private let policy: ConjetPortPolicy
    private let configuredProxyEngine: ConjetNetworkProxyEngine
    private let capabilities: ConjetNetworkCapabilities
    private let requestedBridgeEngine: ConjetNetworkBridgeEngine
    private let bridgeFallbackReason: String?
    private let energyMode: ConjetEnergyMode
    private let periodicReconcileIntervalSeconds: TimeInterval
    private let runner: Runner
    private let successfulConnectionHandler: SuccessfulConnectionHandler?
    private let activityHandler: ActivityHandler?
    private let nioGroup: MultiThreadedEventLoopGroup
    private let fastAttachQueue = DispatchQueue(label: "dev.conjet.port-forward.fast-attach", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var eventWatcherRunning = false
    private var targetEventWatcherRunning = false
    private var eventWatcherLastEventAt: Date?
    private var eventWatcherReconnects = 0
    private var targetEventReconnects = 0
    private var lastReconcileAt: Date?
    private var pollThread: Thread?
    private var eventThread: Thread?
    private var targetEventThread: Thread?
    private var tcpListeners: [ForwardKey: any PortListener] = [:]
    private var udpListeners: [ForwardKey: any PortListener] = [:]
    private var startingUDPKeys: Set<ForwardKey> = []
    private var statuses: [ForwardKey: ConjetPortForwardStatus] = [:]
    private var publishedPortCache: [String: Set<DockerPublishedPort>] = [:]
    private var containerTargetIPCache: [String: String] = [:]
    private var containerTargetSnapshotAt: Date?
    private var containerTargetSnapshotKeys: Set<String> = []
    private var containerTargetSnapshotFingerprint: String?
    private var pendingCreatePortsByName: [String: Set<DockerPublishedPort>] = [:]
    private var pendingCreatePortsByID: [String: Set<DockerPublishedPort>] = [:]
    private var pendingAnonymousCreatePorts: [Set<DockerPublishedPort>] = []
    private var messages: [String] = []

    public init(
        socketPath: String,
        connector: any GuestConnectionConnector,
        policy: ConjetPortPolicy = ConjetPortPolicy(),
        proxyEngine: ConjetNetworkProxyEngine = .auto,
        capabilities: ConjetNetworkCapabilities = ConjetNetworkCapabilities(tcpProxy: true),
        requestedBridgeEngine: ConjetNetworkBridgeEngine = .auto,
        bridgeFallbackReason: String? = nil,
        energyMode: ConjetEnergyMode = .balanced,
        periodicReconcileIntervalSeconds: TimeInterval? = nil,
        successfulConnectionHandler: SuccessfulConnectionHandler? = nil,
        activityHandler: ActivityHandler? = nil,
        runner: @escaping Runner = { executable, arguments, timeoutSeconds in
            try ProcessRunner.run(executable, arguments, timeoutSeconds: timeoutSeconds)
        }
    ) {
        self.socketPath = socketPath
        self.connector = connector
        self.policy = policy
        self.configuredProxyEngine = proxyEngine
        self.capabilities = capabilities
        self.requestedBridgeEngine = requestedBridgeEngine
        self.bridgeFallbackReason = bridgeFallbackReason
        self.energyMode = energyMode
        self.periodicReconcileIntervalSeconds = max(5, periodicReconcileIntervalSeconds ?? energyMode.defaultNetworkReconcileIntervalSeconds)
        self.runner = runner
        self.successfulConnectionHandler = successfulConnectionHandler
        self.activityHandler = activityHandler
        self.nioGroup = MultiThreadedEventLoopGroup(numberOfThreads: max(1, min(4, System.coreCount)))
    }

    deinit {
        stop()
        try? nioGroup.syncShutdownGracefully()
    }

    public func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        reconcile()
        startTargetEventWatcher()
        startEventWatcher()
        startPeriodicReconcile()
    }

    public func stop() {
        lock.lock()
        running = false
        targetEventWatcherRunning = false
        let tcp = tcpListeners
        tcpListeners.removeAll()
        let udp = udpListeners
        udpListeners.removeAll()
        startingUDPKeys.removeAll()
        for key in statuses.keys {
            statuses[key]?.state = .stopped
            statuses[key]?.updatedAt = Date()
        }
        lock.unlock()

        tcp.values.forEach { $0.stop() }
        udp.values.forEach { $0.stop() }
    }

    public func isRunning() -> Bool {
        lock.lock()
        let value = running
        lock.unlock()
        return value
    }

    public func repair() {
        lock.lock()
        appendMessage("network repair requested")
        statuses = statuses.filter { _, status in
            status.state != .stale && status.state != .stopped
        }
        lock.unlock()
        reconcile()
        startTargetEventWatcher()
        startEventWatcher()
    }

    public func pruneCache() {
        lock.lock()
        publishedPortCache.removeAll()
        containerTargetIPCache.removeAll()
        containerTargetSnapshotAt = nil
        containerTargetSnapshotKeys.removeAll()
        containerTargetSnapshotFingerprint = nil
        pendingCreatePortsByName.removeAll()
        pendingCreatePortsByID.removeAll()
        pendingAnonymousCreatePorts.removeAll()
        statuses = statuses.filter { _, status in
            status.state != .stale && status.state != .stopped
        }
        appendMessage("network cache pruned")
        lock.unlock()
    }

    public func observeCreatePublicationIntent(_ intent: DockerCreatePublicationIntent) {
        guard !intent.ports.isEmpty else { return }
        lock.lock()
        if let name = intent.containerName, !name.isEmpty {
            pendingCreatePortsByName[name] = intent.ports
        } else {
            pendingAnonymousCreatePorts.append(intent.ports)
        }
        let sortedPorts = intent.ports
            .sorted { lhs, rhs in
                (lhs.hostPort, lhs.protocol.rawValue, lhs.containerPort) < (rhs.hostPort, rhs.protocol.rawValue, rhs.containerPort)
            }
            .map { "\($0.hostPort):\($0.containerPort)/\($0.protocol.rawValue)" }
            .joined(separator: ",")
        appendMessage("observed Docker create port intent \(intent.containerName ?? "<anonymous>") [\(sortedPorts)]")
        lock.unlock()

        prepublishCreateIntent(intent)
    }

    public func resolveCreatePublication(_ resolution: DockerCreatePublicationResolution) {
        guard !resolution.containerID.isEmpty, !resolution.intent.ports.isEmpty else { return }
        let resolvedPorts = Set(resolution.intent.ports.map { port in
            DockerPublishedPort(
                hostIP: port.hostIP,
                hostPort: port.hostPort,
                containerPort: port.containerPort,
                protocol: port.protocol,
                containerID: resolution.containerID,
                containerName: port.containerName ?? resolution.intent.containerName,
                targetIP: port.targetIP
            )
        })
        lock.lock()
        pendingCreatePortsByID[resolution.containerID] = resolvedPorts
        pendingCreatePortsByID[String(resolution.containerID.prefix(12))] = resolvedPorts
        if let name = resolution.intent.containerName {
            pendingCreatePortsByName.removeValue(forKey: name)
        } else if let index = pendingAnonymousCreatePorts.firstIndex(of: resolution.intent.ports) {
            pendingAnonymousCreatePorts.remove(at: index)
        }
        appendMessage("resolved Docker create port intent \(String(resolution.containerID.prefix(12)))")
        lock.unlock()
    }

    public func observeContainerStartIntent(_ request: DockerContainerStartRequest) {
        guard !request.containerID.isEmpty else { return }
        lock.lock()
        let shouldRun = running
        appendMessage("observed Docker container start intent \(String(request.containerID.prefix(12)))")
        lock.unlock()
        guard shouldRun else { return }

        let pending = pendingCreatePorts(for: [request.containerID])
        if !pending.isEmpty {
            let ports = pending.reduce(into: Set<DockerPublishedPort>()) { partial, item in
                partial.formUnion(item.ports)
            }
            lock.lock()
            appendMessage("start-intent used cached create publication \(String(request.containerID.prefix(12)))")
            lock.unlock()
            prepublishPendingTCPPorts(ports)
            return
        }

        let ports: Set<DockerPublishedPort>
        do {
            ports = try inspectConfiguredPublishedPortsViaDockerAPI(
                containerID: request.containerID,
                timeoutSeconds: 0.05
            )
        } catch {
            lock.lock()
            appendMessage("start-intent prepublish inspect failed \(String(request.containerID.prefix(12))): \(error)")
            lock.unlock()
            return
        }
        guard !ports.isEmpty else {
            lock.lock()
            appendMessage("start-intent prepublish found no published ports \(String(request.containerID.prefix(12)))")
            lock.unlock()
            return
        }
        let containerID = ports.compactMap(\.containerID).first ?? request.containerID
        lock.lock()
        pendingCreatePortsByID[containerID] = ports
        pendingCreatePortsByID[String(containerID.prefix(12))] = ports
        appendMessage("prepublished Docker start port intent \(String(containerID.prefix(12)))")
        lock.unlock()
        prepublishPendingTCPPorts(ports)
    }

    public func observeContainerStart(_ request: DockerContainerStartRequest) {
        guard !request.containerID.isEmpty else { return }
        lock.lock()
        let shouldRun = running
        appendMessage("observed Docker container start \(String(request.containerID.prefix(12)))")
        lock.unlock()
        guard shouldRun else { return }

        if hasPendingCreatePorts(for: request.containerID) {
            fastAttachStartedContainer(request.containerID)
        } else {
            fastAttachQueue.async { [weak self] in
                self?.fastAttachStartedContainer(request.containerID)
            }
        }
    }

    public func status() -> ConjetNetworkStatus {
        lock.lock()
        let snapshot = statuses.values.sorted {
            ($0.hostPort, $0.protocol.rawValue, $0.hostIP) < ($1.hostPort, $1.protocol.rawValue, $1.hostIP)
        }
        let activeTCP = snapshot.filter { $0.protocol == .tcp && $0.state == .listening }.count
        let activeUDP = snapshot.filter { $0.protocol == .udp && $0.state == .listening }.count
        let failed = snapshot.filter { $0.state.rawValue.hasPrefix("failed") }.count
        let conflicts = snapshot.filter { $0.state == .failedConflict || $0.state == .failedAddressInUse }.count
        let stale = snapshot.filter { $0.state == .stale }.count
        let eventState = eventWatcherRunning ? "connected" : (running ? "reconnecting" : "stopped")
        let targetEventState: String
        if targetEventWatcherRunning {
            targetEventState = "connected"
        } else if !capabilities.containerIPLookup {
            targetEventState = "unsupported"
        } else if running {
            targetEventState = "reconnecting"
        } else {
            targetEventState = "stopped"
        }
        let result = ConjetNetworkStatus(
            bindPolicy: policy.bindPolicy,
            proxyEngine: actualProxyEngine,
            bridgeEngine: bridgeEngineName,
            tcpMode: tcpModeName,
            udpMode: udpModeName,
            tcpBinaryFrames: capabilities.tcpBinaryFrames,
            persistentTCPVsock: capabilities.persistentTCPVsock,
            tcpVsockPool: capabilities.tcpVsockPool,
            pythonFallbackActive: pythonFallbackActive,
            requestedBridgeEngine: requestedBridgeEngine.rawValue,
            fallbackReason: bridgeFallbackReason,
            eventWatcherState: eventState,
            eventWatcherLastEventAt: eventWatcherLastEventAt,
            eventWatcherReconnects: eventWatcherReconnects,
            targetEventWatcherState: targetEventState,
            targetEventReconnects: targetEventReconnects,
            periodicReconcileIntervalSeconds: periodicReconcileIntervalSeconds,
            capabilities: capabilities,
            activeTCPForwards: activeTCP,
            activeUDPForwards: activeUDP,
            failedForwards: failed,
            conflictCount: conflicts,
            staleForwards: stale,
            vmNetworkMode: "vz-nat",
            turboAvailable: false,
            turboEnabled: false,
            lastReconcileAt: lastReconcileAt,
            forwards: snapshot,
            messages: messages
        )
        lock.unlock()
        return result
    }

    func appendMessagesForTesting(_ values: [String]) {
        lock.lock()
        for value in values {
            appendMessage(value)
        }
        lock.unlock()
    }

    func listenerPortsForTesting() -> Set<Int> {
        lock.lock()
        let ports = Set(tcpListeners.keys.map(\.hostPort)).union(Set(udpListeners.keys.map(\.hostPort)))
        lock.unlock()
        return ports
    }

    func pendingCreatePortsForTesting(containerName: String? = nil) -> Set<DockerPublishedPort> {
        lock.lock()
        let ports: Set<DockerPublishedPort>
        if let containerName {
            ports = pendingCreatePortsByName[containerName] ?? []
        } else {
            ports = pendingAnonymousCreatePorts.reduce(into: Set<DockerPublishedPort>()) { partial, values in
                partial.formUnion(values)
            }
        }
        lock.unlock()
        return ports
    }

    func pendingCreatePortsForTesting(containerID: String) -> Set<DockerPublishedPort> {
        lock.lock()
        let ports = pendingCreatePortsByID.first { cachedID, _ in
            containerIDsMatch(cachedID, containerID)
        }?.value ?? []
        lock.unlock()
        return ports
    }

    func reconcileForTesting(_ ports: Set<DockerPublishedPort>) {
        lock.lock()
        running = true
        lock.unlock()
        reconcile(publishedPorts: ports)
    }

    func discoverPublishedPortsForTesting() -> Set<DockerPublishedPort> {
        discoverPublishedPorts()
    }

    func reconcileContainerIDsForTesting(_ containerIDs: Set<String>) {
        lock.lock()
        running = true
        lock.unlock()
        reconcile(containerIDs: containerIDs)
    }

    func applyContainerTargetSnapshotDataForTesting(_ data: Data) throws {
        try applyContainerTargetSnapshotData(data, source: "test")
    }

    func observeContainerStartForTesting(_ request: DockerContainerStartRequest) {
        lock.lock()
        running = true
        lock.unlock()
        observeContainerStart(request)
    }

    private var actualProxyEngine: String {
        switch configuredProxyEngine {
        case .auto, .gcdFallback:
            return "proxy-gcd-evented"
        case .eventLoop:
            return "proxy-nio"
        case .turbo:
            return "proxy-gcd-turbo-unavailable"
        }
    }

    private var bridgeEngineName: String {
        capabilities.bridgeEngine ?? "python-legacy"
    }

    private var pythonFallbackActive: Bool {
        bridgeEngineName == ConjetNetworkBridgeEngine.pythonLegacy.rawValue
    }

    private var nativeTCPPoolAvailable: Bool {
        bridgeEngineName == ConjetNetworkBridgeEngine.conjetNetdC.rawValue
            && capabilities.binaryFrames
            && capabilities.tcpBinaryFrames
            && capabilities.persistentTCPVsock
            && capabilities.tcpVsockPool
    }

    private var useNativeTCPPoolForPublishedPorts: Bool {
        nativeTCPPoolAvailable
    }

    private var tcpModeName: String {
        useNativeTCPPoolForPublishedPorts ? "persistent-binary-tcp-pool" : "legacy-tcp-proxy"
    }

    private var udpModeName: String {
        capabilities.binaryFrames && capabilities.udpBinaryFrames && capabilities.persistentVsock
            ? "persistent-binary-udp"
            : "legacy-udp-proxy"
    }

    private var useNIOProxy: Bool {
        switch configuredProxyEngine {
        case .eventLoop:
            return true
        case .auto, .gcdFallback, .turbo:
            return false
        }
    }

    private func startPeriodicReconcile() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            while self.isRunning() {
                Thread.sleep(forTimeInterval: self.periodicReconcileIntervalSeconds)
                if self.isRunning() {
                    self.reconcile()
                }
            }
        }
        thread.name = "dev.conjet.network-periodic-reconcile"
        pollThread = thread
        thread.start()
    }

    private func startEventWatcher() {
        lock.lock()
        guard running, eventThread == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.eventLoop()
        }
        thread.name = "dev.conjet.docker-event-watcher"
        eventThread = thread
        thread.start()
    }

    private func startTargetEventWatcher() {
        guard capabilities.containerTargetEvents else { return }
        lock.lock()
        guard running, targetEventThread == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.targetEventLoop()
        }
        thread.name = "dev.conjet.container-target-event-watcher"
        targetEventThread = thread
        thread.start()
    }

    private func targetEventLoop() {
        let baseReconnectDelay = max(0.25, energyMode.eventWatcherReconnectDelaySeconds)
        var reconnectDelay = baseReconnectDelay
        while isRunning() {
            var connected = false
            autoreleasepool {
                connected = runContainerTargetEventStream()
            }
            lock.lock()
            if running {
                targetEventWatcherRunning = false
                targetEventReconnects += 1
                appendMessage("container target event stream reconnecting")
            }
            lock.unlock()
            if isRunning() {
                Thread.sleep(forTimeInterval: reconnectDelay)
                reconnectDelay = connected ? baseReconnectDelay : min(reconnectDelay * 2, 10)
            }
        }
        lock.lock()
        targetEventThread = nil
        targetEventWatcherRunning = false
        lock.unlock()
    }

    private func runContainerTargetEventStream() -> Bool {
        let connection: GuestConnection
        do {
            connection = try connector.connect()
        } catch {
            lock.lock()
            appendMessage("container target event stream failed to connect: \(error)")
            lock.unlock()
            return false
        }
        defer { connection.close() }

        setSocketTimeoutForDockerAPI(connection.fileDescriptor, timeoutSeconds: 5)
        let request = "GET /conjet-container-target-events HTTP/1.1\r\nHost: docker\r\nConnection: keep-alive\r\n\r\n"
        guard writeAllForDockerAPI(Data(request.utf8), to: connection.fileDescriptor) else {
            lock.lock()
            appendMessage("container target event stream request failed")
            lock.unlock()
            return false
        }

        var buffer = Data()
        var headerParsed = false
        var streamConnectedMessageSent = false
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)
        while isRunning() {
            let count = Darwin.read(connection.fileDescriptor, &scratch, scratch.count)
            if count > 0 {
                buffer.append(scratch, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                break
            }

            if !headerParsed {
                let delimiter = Data([13, 10, 13, 10])
                guard let headerRange = buffer.range(of: delimiter) else {
                    continue
                }
                let headerData = buffer[..<headerRange.lowerBound]
                guard let headerText = String(data: headerData, encoding: .utf8),
                      let statusLine = headerText.split(separator: "\r\n").first,
                      statusLine.contains(" 200 ") else {
                    lock.lock()
                    appendMessage("container target event stream returned invalid response")
                    lock.unlock()
                    return false
                }
                buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                headerParsed = true
                lock.lock()
                targetEventWatcherRunning = true
                appendMessage("container target event stream connected")
                lock.unlock()
                streamConnectedMessageSent = true
            }

            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                let trimmed = Data(line).trimmedASCIIWhitespace()
                guard !trimmed.isEmpty else { continue }
                do {
                    try applyContainerTargetSnapshotData(trimmed, source: "event stream")
                } catch {
                    lock.lock()
                    appendMessage("container target event decode failed: \(error)")
                    lock.unlock()
                }
            }
        }

        if headerParsed, !buffer.trimmedASCIIWhitespace().isEmpty {
            do {
                try applyContainerTargetSnapshotData(buffer.trimmedASCIIWhitespace(), source: "event stream")
            } catch {
                lock.lock()
                appendMessage("container target event decode failed: \(error)")
                lock.unlock()
            }
        }
        if streamConnectedMessageSent {
            lock.lock()
            targetEventWatcherRunning = false
            lock.unlock()
        }
        return headerParsed
    }

    private func eventLoop() {
        while isRunning() {
            var connected = false
            autoreleasepool {
                connected = runDockerEventStream()
            }
            lock.lock()
            if running {
                eventWatcherRunning = false
                eventWatcherReconnects += 1
                appendMessage("Docker event watcher reconnecting")
            }
            lock.unlock()
            if isRunning() {
                let reconnectDelay = connected ? energyMode.eventWatcherReconnectDelaySeconds : min(10, energyMode.eventWatcherReconnectDelaySeconds * 2)
                Thread.sleep(forTimeInterval: reconnectDelay)
            }
        }
        lock.lock()
        eventThread = nil
        eventWatcherRunning = false
        lock.unlock()
    }

    private func runDockerEventStream() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            Thread.sleep(forTimeInterval: energyMode.eventWatcherReconnectDelaySeconds)
            return false
        }

        let connection: GuestConnection
        do {
            connection = try connector.connect()
        } catch {
            lock.lock()
            eventWatcherRunning = false
            appendMessage("Docker event stream failed to connect: \(error)")
            lock.unlock()
            return false
        }
        defer { connection.close() }

        setSocketTimeoutForDockerAPI(connection.fileDescriptor, timeoutSeconds: 2)
        let request = "GET \(Self.dockerEventsAPIPath) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        guard writeAllForDockerAPI(Data(request.utf8), to: connection.fileDescriptor) else {
            lock.lock()
            appendMessage("Docker event stream request failed")
            lock.unlock()
            return false
        }

        var buffer = Data()
        var decodedChunkBuffer = Data()
        var headerParsed = false
        var chunked = false
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)
        while isRunning() {
            let count = Darwin.read(connection.fileDescriptor, &scratch, scratch.count)
            if count > 0 {
                buffer.append(scratch, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                break
            }

            if !headerParsed {
                let delimiter = Data([13, 10, 13, 10])
                guard let headerRange = buffer.range(of: delimiter) else {
                    continue
                }
                let headerData = buffer[..<headerRange.lowerBound]
                guard let headerText = String(data: headerData, encoding: .utf8),
                      let header = DockerAPIHTTPResponse.parseHeader(headerText),
                      header.statusCode >= 200,
                      header.statusCode < 300 else {
                    lock.lock()
                    appendMessage("Docker event stream returned invalid response")
                    lock.unlock()
                    return false
                }
                chunked = header.headers["transfer-encoding"]?.lowercased().contains("chunked") == true
                buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                headerParsed = true
                lock.lock()
                eventWatcherRunning = true
                appendMessage("Docker event stream connected")
                lock.unlock()
            }

            if chunked {
                guard drainChunkedDockerEventBuffer(rawBuffer: &buffer, decodedLineBuffer: &decodedChunkBuffer) else {
                    break
                }
            } else {
                drainDockerEventLineBuffer(&buffer)
            }
        }

        if headerParsed {
            if chunked {
                _ = drainChunkedDockerEventBuffer(rawBuffer: &buffer, decodedLineBuffer: &decodedChunkBuffer)
                handleFinalDockerEventLineBuffer(decodedChunkBuffer)
            } else {
                handleFinalDockerEventLineBuffer(buffer)
            }
        }
        lock.lock()
        eventWatcherRunning = false
        lock.unlock()
        return headerParsed
    }

    private func handleEventLine(_ data: Data) {
        let trimmed = data.trimmedASCIIWhitespace()
        guard !trimmed.isEmpty else { return }
        lock.lock()
        eventWatcherLastEventAt = Date()
        lock.unlock()
        guard let event = try? ConjetDockerRuntimeEvent.decode(line: trimmed) else {
            reconcile()
            return
        }

        guard let containerID = event.containerID, !containerID.isEmpty else {
            pruneCache()
            reconcile()
            return
        }

        switch event.eventName {
        case "create", "start", "restart", "connect", "network_connect":
            if event.eventName == "start" || event.eventName == "restart" {
                emitMemoryActivity(
                    kind: .containerStarted,
                    workload: .run,
                    activeStreams: 1,
                    buildLike: true
                )
            }
            reconcile(containerIDs: [containerID])
        case "stop", "die", "destroy":
            emitMemoryActivity(
                kind: .containerStopped,
                workload: .stop,
                activeStreams: 0,
                buildLike: false
            )
            removeForContainer(containerID)
        case "disconnect", "network_disconnect":
            pruneCache()
            reconcile(containerIDs: [containerID])
        default:
            reconcile(containerIDs: [containerID])
        }
    }

    private func emitMemoryActivity(
        kind: DockerMemoryActivity.Kind,
        workload: DockerMemoryActivity.Workload,
        activeStreams: Int,
        buildLike: Bool
    ) {
        activityHandler?(DockerMemoryActivity(
            kind: kind,
            workload: workload,
            activeStreams: activeStreams,
            pressureStreams: activeStreams,
            buildLike: buildLike
        ))
    }

    private func drainDockerEventLineBuffer(_ buffer: inout Data) {
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handleEventLine(Data(line))
        }
    }

    private func handleFinalDockerEventLineBuffer(_ buffer: Data) {
        let trimmed = buffer.trimmedASCIIWhitespace()
        if !trimmed.isEmpty {
            handleEventLine(trimmed)
        }
    }

    private func drainChunkedDockerEventBuffer(rawBuffer: inout Data, decodedLineBuffer: inout Data) -> Bool {
        while true {
            guard let lineEnd = rawBuffer.range(of: Data([13, 10]))?.lowerBound else {
                return true
            }
            guard let sizeLine = String(data: rawBuffer[rawBuffer.startIndex..<lineEnd], encoding: .utf8) else {
                return false
            }
            let sizeText = sizeLine
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                return false
            }
            let chunkStart = lineEnd + 2
            if size == 0 {
                rawBuffer.removeSubrange(rawBuffer.startIndex..<min(chunkStart, rawBuffer.endIndex))
                return false
            }
            let chunkEnd = chunkStart + size
            guard chunkEnd + 2 <= rawBuffer.endIndex else {
                return true
            }
            guard rawBuffer[chunkEnd] == 13, rawBuffer[chunkEnd + 1] == 10 else {
                return false
            }
            decodedLineBuffer.append(rawBuffer[chunkStart..<chunkEnd])
            rawBuffer.removeSubrange(rawBuffer.startIndex..<(chunkEnd + 2))
            drainDockerEventLineBuffer(&decodedLineBuffer)
        }
    }

    private func reconcile() {
        reconcile(publishedPorts: discoverPublishedPorts())
    }

    private func reconcile(containerIDs: Set<String>) {
        guard !containerIDs.isEmpty else { return }
        reconcile(publishedPorts: discoverPublishedPorts(containerIDs: Array(containerIDs)), scopedContainerIDs: containerIDs)
    }

    private func discoverPublishedPorts() -> Set<DockerPublishedPort> {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return []
        }

        do {
            let ps = try runner("/usr/bin/env", ["docker", "--host", "unix://\(socketPath)", "ps", "-q", "--no-trunc"], 3)
            guard ps.succeeded else { return [] }
            let containerIDs = ps.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            guard !containerIDs.isEmpty else { return [] }
            let knownPorts = cachedPublishedPorts(for: Set(containerIDs))
            let missingContainerIDs = uncachedContainerIDs(from: containerIDs)
            guard !missingContainerIDs.isEmpty else {
                prunePublishedPortCache(activeContainerIDs: Set(containerIDs))
                return knownPorts
            }
            let inspectedPorts = try inspectPublishedPorts(containerIDs: missingContainerIDs, timeoutSeconds: 5)
            updatePublishedPortCache(inspectedPorts, for: missingContainerIDs)
            prunePublishedPortCache(activeContainerIDs: Set(containerIDs))
            return knownPorts.union(inspectedPorts)
        } catch {
            lock.lock()
            appendMessage("port reconcile failed: \(error)")
            lock.unlock()
            return []
        }
    }

    private func discoverPublishedPorts(containerIDs: [String]) -> Set<DockerPublishedPort> {
        guard FileManager.default.fileExists(atPath: socketPath), !containerIDs.isEmpty else {
            return []
        }

        let pendingPorts = resolvePendingCreatePorts(containerIDs: containerIDs)
        let pendingContainerIDs = Set(pendingPorts.compactMap(\.containerID))
        let unresolvedContainerIDs = containerIDs.filter { containerID in
            !pendingContainerIDs.contains { pendingID in
                containerIDsMatch(pendingID, containerID)
            }
        }

        if unresolvedContainerIDs.isEmpty {
            updatePublishedPortCache(pendingPorts, for: containerIDs)
            return pendingPorts
        }

        do {
            let ports = try inspectPublishedPorts(containerIDs: unresolvedContainerIDs, timeoutSeconds: 3)
            let allPorts = pendingPorts.union(ports)
            updatePublishedPortCache(allPorts, for: containerIDs)
            return allPorts
        } catch {
            lock.lock()
            appendMessage("targeted port reconcile failed: \(error)")
            lock.unlock()
            return pendingPorts.union(cachedPublishedPorts(for: Set(containerIDs)))
        }
    }

    private func resolvePendingCreatePorts(containerIDs: [String]) -> Set<DockerPublishedPort> {
        let pending = pendingCreatePorts(for: containerIDs)
        guard !pending.isEmpty else { return [] }

        return pending.reduce(into: Set<DockerPublishedPort>()) { resolved, item in
            let targetIP = containerTargetIP(containerID: item.containerID, allowDockerFallback: true)
            for port in item.ports {
                resolved.insert(DockerPublishedPort(
                    hostIP: port.hostIP,
                    hostPort: port.hostPort,
                    containerPort: port.containerPort,
                    protocol: port.protocol,
                    containerID: item.containerID,
                    containerName: port.containerName,
                    targetIP: targetIP
                ))
            }
        }
    }

    private func fastAttachStartedContainer(_ containerID: String) {
        guard isRunning() else { return }

        let deadline = Date().addingTimeInterval(0.035)
        var pending = pendingCreatePorts(for: [containerID])
        if pending.isEmpty {
            fastReconcileViaDockerAPI(containerID: containerID)
            return
        }

        while isRunning() {
            for item in pending {
                if let ports = resolvedPendingCreatePorts(containerID: item.containerID, ports: item.ports) {
                    updatePublishedPortCache(ports, for: [item.containerID])
                    reconcile(publishedPorts: ports, scopedContainerIDs: [item.containerID])
                    waitForTCPPublishedTargetsReady(ports, timeoutSeconds: 0.15)
                    lock.lock()
                    appendMessage("fast-attached published ports for \(String(item.containerID.prefix(12)))")
                    lock.unlock()
                    return
                }
            }

            guard Date() < deadline else { break }
            Thread.sleep(forTimeInterval: 0.001)
            pending = pendingCreatePorts(for: [containerID])
            guard !pending.isEmpty else {
                fastReconcileViaDockerAPI(containerID: containerID)
                return
            }
        }

        reconcile(containerIDs: [containerID])
    }

    private func resolvedPendingCreatePorts(
        containerID: String,
        ports: Set<DockerPublishedPort>
    ) -> Set<DockerPublishedPort>? {
        guard let targetIP = containerTargetIP(containerID: containerID, allowDockerFallback: false) else {
            return nil
        }
        return ports.reduce(into: Set<DockerPublishedPort>()) { resolved, port in
            resolved.insert(DockerPublishedPort(
                hostIP: port.hostIP,
                hostPort: port.hostPort,
                containerPort: port.containerPort,
                protocol: port.protocol,
                containerID: containerID,
                containerName: port.containerName,
                targetIP: targetIP
            ))
        }
    }

    private func fastReconcileViaDockerAPI(containerID: String) {
        guard let ports = try? inspectPublishedPortsViaDockerAPI(containerIDs: [containerID], timeoutSeconds: 0.05),
              !ports.isEmpty else {
            reconcile(containerIDs: [containerID])
            return
        }
        updatePublishedPortCache(ports, for: [containerID])
        reconcile(publishedPorts: ports, scopedContainerIDs: [containerID])
    }

    private func containerTargetIP(containerID: String, allowDockerFallback: Bool) -> String? {
        if let targetIP = cachedContainerTargetIP(containerID: containerID) {
            return targetIP
        }
        guard allowDockerFallback else {
            return nil
        }
        if refreshGuestContainerTargetSnapshot(timeoutSeconds: 0.025),
           let targetIP = cachedContainerTargetIP(containerID: containerID) {
            return targetIP
        }
        return containerTargetIPViaDockerAPI(containerID: containerID)
    }

    private func waitForTCPPublishedTargetsReady(_ ports: Set<DockerPublishedPort>, timeoutSeconds: Double) {
        let tcpTargets = ports.compactMap { port -> (host: String, port: Int)? in
            guard port.protocol == .tcp,
                  let targetIP = port.targetIP,
                  !targetIP.isEmpty else {
                return nil
            }
            return (targetIP, port.containerPort)
        }
        guard !tcpTargets.isEmpty else { return }

        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        for target in tcpTargets {
            while Date() < deadline {
                if guestTCPPortProbe(host: target.host, port: target.port) {
                    break
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    private func guestTCPPortProbe(host: String, port: Int) -> Bool {
        guard capabilities.portProbe else { return false }
        guard port > 0, port <= 65_535 else { return false }
        let escapedHost = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
        return (try? dockerAPIResponseBody(
            path: "/conjet-port-probe?host=\(escapedHost)&port=\(port)",
            timeoutSeconds: 0.02
        )) != nil
    }

    @discardableResult
    private func refreshGuestContainerTargetSnapshot(timeoutSeconds: Double) -> Bool {
        guard capabilities.containerIPLookup else { return false }
        do {
            let data = try dockerAPIResponseBody(
                path: "/conjet-container-targets",
                timeoutSeconds: timeoutSeconds
            )
            try applyContainerTargetSnapshotData(data, source: "snapshot")
            return true
        } catch {
            lock.lock()
            appendMessage("guest container target snapshot failed: \(error)")
            lock.unlock()
            return false
        }
    }

    private func applyContainerTargetSnapshotData(_ data: Data, source: String) throws {
        let containers = try JSONDecoder().decode([DockerContainerTargetSnapshot].self, from: data)
        applyContainerTargetSnapshot(containers, source: source)
    }

    private func applyContainerTargetSnapshot(_ containers: [DockerContainerTargetSnapshot], source: String) {
        let now = Date()
        let activeContainerIDs = Set(containers.map(\.id).filter { !$0.isEmpty })
        var snapshot: [String: String] = [:]
        var attachCandidates: [(containerID: String, targetIP: String)] = []
        var fingerprintRows: [String] = []
        for container in containers {
            guard let targetIP = container.targetIPAddress, !targetIP.isEmpty else {
                continue
            }
            snapshot[container.id] = targetIP
            snapshot[String(container.id.prefix(12))] = targetIP
            attachCandidates.append((container.id, targetIP))
            var aliases = [container.id, String(container.id.prefix(12))]
            for name in container.names ?? [] {
                let trimmedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !trimmedName.isEmpty {
                    snapshot[trimmedName] = targetIP
                    aliases.append(trimmedName)
                }
            }
            fingerprintRows.append("\(container.id)|\(targetIP)|\(aliases.sorted().joined(separator: ","))")
        }
        let snapshotKeys = Set(snapshot.keys)
        let fingerprint = fingerprintRows.sorted().joined(separator: "\n")
        lock.lock()
        let duplicateSnapshot = containerTargetSnapshotFingerprint == fingerprint
        if !duplicateSnapshot {
            for staleKey in containerTargetSnapshotKeys.subtracting(snapshotKeys) {
                containerTargetIPCache.removeValue(forKey: staleKey)
            }
            for (key, value) in snapshot {
                containerTargetIPCache[key] = value
            }
            containerTargetSnapshotKeys = snapshotKeys
            containerTargetSnapshotFingerprint = fingerprint
            containerTargetSnapshotAt = now
            eventWatcherLastEventAt = now
            appendMessage("refreshed guest container target \(source) (\(containers.count) containers)")
        }
        lock.unlock()

        for candidate in attachCandidates {
            attachPendingCreatePortsFromTargetEvent(
                containerID: candidate.containerID,
                targetIP: candidate.targetIP,
                source: source
            )
        }
        if !duplicateSnapshot {
            removeForContainersMissingFromTargetSnapshot(activeContainerIDs: activeContainerIDs)
            if !activeContainerIDs.isEmpty {
                reconcile(containerIDs: activeContainerIDs)
            }
        }
    }

    private func attachPendingCreatePortsFromTargetEvent(
        containerID: String,
        targetIP: String,
        source: String
    ) {
        guard isRunning() else { return }
        let pending = pendingCreatePorts(for: [containerID])
        guard !pending.isEmpty else { return }

        for item in pending {
            let resolvedPorts = item.ports.reduce(into: Set<DockerPublishedPort>()) { resolved, port in
                resolved.insert(DockerPublishedPort(
                    hostIP: port.hostIP,
                    hostPort: port.hostPort,
                    containerPort: port.containerPort,
                    protocol: port.protocol,
                    containerID: item.containerID,
                    containerName: port.containerName,
                    targetIP: targetIP
                ))
            }
            updatePublishedPortCache(resolvedPorts, for: [item.containerID])
            reconcile(publishedPorts: resolvedPorts, scopedContainerIDs: [item.containerID])
            lock.lock()
            appendMessage("target-event attached published ports for \(String(item.containerID.prefix(12))) from \(source)")
            lock.unlock()
        }
    }

    private func removeForContainersMissingFromTargetSnapshot(activeContainerIDs: Set<String>) {
        lock.lock()
        let staleContainerIDs = Set(statuses.values.compactMap { status -> String? in
            guard let containerID = status.containerID, !containerID.isEmpty else {
                return nil
            }
            let isActive = activeContainerIDs.contains { activeContainerID in
                containerIDsMatch(activeContainerID, containerID)
            }
            return isActive ? nil : containerID
        })
        lock.unlock()

        for containerID in staleContainerIDs {
            removeForContainer(containerID)
            lock.lock()
            appendMessage("removed stale published ports for missing container \(String(containerID.prefix(12)))")
            lock.unlock()
        }
    }

    private func cachedContainerTargetIP(containerID: String) -> String? {
        lock.lock()
        let targetIP = containerTargetIPCache.first { cachedID, _ in
            containerIDsMatch(cachedID, containerID)
        }?.value
        lock.unlock()
        return targetIP
    }

    private func pendingCreatePorts(for containerIDs: [String]) -> [(containerID: String, ports: Set<DockerPublishedPort>)] {
        lock.lock()
        let snapshot = pendingCreatePortsByID
        lock.unlock()
        return containerIDs.compactMap { containerID in
            guard let match = snapshot.first(where: { cachedID, _ in
                containerIDsMatch(cachedID, containerID)
            }) else {
                return nil
            }
            let canonicalID = match.value.compactMap(\.containerID).first ?? match.key
            return (containerID: canonicalID, ports: match.value)
        }
    }

    private func hasPendingCreatePorts(for containerID: String) -> Bool {
        !pendingCreatePorts(for: [containerID]).isEmpty
    }

    private func inspectPublishedPorts(containerIDs: [String], timeoutSeconds: Double) throws -> Set<DockerPublishedPort> {
        guard !containerIDs.isEmpty else { return [] }

        if let ports = try? inspectPublishedPortsViaDockerAPI(containerIDs: containerIDs, timeoutSeconds: timeoutSeconds) {
            return ports
        }

        let inspect = try runner("/usr/bin/env", dockerInspectArguments(containerIDs), timeoutSeconds)
        if inspect.succeeded, let data = inspect.stdout.data(using: .utf8) {
            return Self.publishedPorts(fromDockerInspectJSON: data)
        }

        let vanishedContainerIDs = missingContainerIDs(fromDockerInspect: inspect, requestedContainerIDs: containerIDs)
        guard !vanishedContainerIDs.isEmpty else {
            return []
        }

        for containerID in vanishedContainerIDs {
            removeForContainer(containerID)
        }

        let retryContainerIDs = containerIDs.filter { !vanishedContainerIDs.contains($0) }
        guard !retryContainerIDs.isEmpty else {
            return []
        }
        return try retryContainerIDs.reduce(into: Set<DockerPublishedPort>()) { ports, containerID in
            let retry = try runner("/usr/bin/env", dockerInspectArguments([containerID]), timeoutSeconds)
            if retry.succeeded, let data = retry.stdout.data(using: .utf8) {
                ports.formUnion(Self.publishedPorts(fromDockerInspectJSON: data))
            } else if !missingContainerIDs(fromDockerInspect: retry, requestedContainerIDs: [containerID]).isEmpty {
                removeForContainer(containerID)
            }
        }
    }

    private func inspectPublishedPortsViaDockerAPI(
        containerIDs: [String],
        timeoutSeconds: Double
    ) throws -> Set<DockerPublishedPort> {
        try containerIDs.reduce(into: Set<DockerPublishedPort>()) { ports, containerID in
            let container = try inspectContainerViaDockerAPI(containerID: containerID, timeoutSeconds: timeoutSeconds)
            ports.formUnion(Self.publishedPorts(fromDockerInspectContainers: [container], requireRunning: true))
        }
    }

    private func inspectConfiguredPublishedPortsViaDockerAPI(
        containerID: String,
        timeoutSeconds: Double
    ) throws -> Set<DockerPublishedPort> {
        let container = try inspectContainerViaDockerAPI(containerID: containerID, timeoutSeconds: timeoutSeconds)
        return Self.publishedPorts(fromDockerInspectContainers: [container], requireRunning: false)
    }

    private func containerTargetIPViaDockerAPI(containerID: String, timeoutSeconds: Double = 1) -> String? {
        guard let container = try? inspectContainerViaDockerAPI(containerID: containerID, timeoutSeconds: timeoutSeconds),
              container.state?.running == true else {
            return nil
        }
        return selectedDockerTargetIPAddress(from: container.networkSettings?.networks)
    }

    private func inspectContainerViaDockerAPI(
        containerID: String,
        timeoutSeconds: Double
    ) throws -> DockerInspectContainer {
        let data = try dockerAPIResponseBody(
            path: "/containers/\(containerID)/json",
            timeoutSeconds: timeoutSeconds
        )
        return try JSONDecoder().decode(DockerInspectContainer.self, from: data)
    }

    private func dockerAPIResponseBody(path: String, timeoutSeconds: Double) throws -> Data {
        let connection = try connector.connect()
        defer { connection.close() }
        setSocketTimeoutForDockerAPI(connection.fileDescriptor, timeoutSeconds: timeoutSeconds)
        let request = "GET \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        guard writeAllForDockerAPI(Data(request.utf8), to: connection.fileDescriptor) else {
            throw ConjetError.socket("failed to write Docker API request \(path)")
        }
        Darwin.shutdown(connection.fileDescriptor, SHUT_WR)
        let response = readAllForDockerAPI(from: connection.fileDescriptor, maxBytes: 4 * 1024 * 1024)
        guard let parsed = DockerAPIHTTPResponse(data: response) else {
            throw ConjetError.socket("invalid Docker API response for \(path)")
        }
        guard parsed.statusCode >= 200, parsed.statusCode < 300 else {
            throw ConjetError.socket("Docker API \(path) returned HTTP \(parsed.statusCode)")
        }
        return parsed.body
    }

    private func dockerInspectArguments(_ containerIDs: [String]) -> [String] {
        ["docker", "--host", "unix://\(socketPath)", "inspect"] + containerIDs
    }

    private func missingContainerIDs(
        fromDockerInspect result: ProcessResult,
        requestedContainerIDs: [String]
    ) -> Set<String> {
        let output = result.stderr + "\n" + result.stdout
        guard output.range(of: "No such container", options: .caseInsensitive) != nil ||
              output.range(of: "No such object", options: .caseInsensitive) != nil else {
            return []
        }

        let requested = Set(requestedContainerIDs)
        let tokens = output
            .split { character in
                character.isWhitespace || character == ":" || character == "\"" || character == "'" || character == "," || character == "[" || character == "]"
            }
            .map(String.init)
        let matched = Set(tokens.filter { requested.contains($0) })
        return matched.isEmpty ? requested : matched
    }

    private func cachedPublishedPorts(for containerIDs: Set<String>) -> Set<DockerPublishedPort> {
        lock.lock()
        let ports = containerIDs.reduce(into: Set<DockerPublishedPort>()) { partial, containerID in
            partial.formUnion(publishedPortCache[containerID] ?? [])
        }
        lock.unlock()
        return ports
    }

    private func uncachedContainerIDs(from containerIDs: [String]) -> [String] {
        lock.lock()
        let result = containerIDs.filter { publishedPortCache[$0] == nil }
        lock.unlock()
        return result
    }

    private func updatePublishedPortCache(_ ports: Set<DockerPublishedPort>, for containerIDs: [String]) {
        lock.lock()
        for containerID in containerIDs {
            publishedPortCache[containerID] = ports.filter { port in
                guard let portContainerID = port.containerID else { return false }
                return containerIDsMatch(portContainerID, containerID)
            }
        }
        lock.unlock()
    }

    private func prunePublishedPortCache(activeContainerIDs: Set<String>) {
        lock.lock()
        publishedPortCache = publishedPortCache.filter { cachedContainerID, _ in
            activeContainerIDs.contains { activeContainerID in
                containerIDsMatch(activeContainerID, cachedContainerID)
            }
        }
        containerTargetIPCache = containerTargetIPCache.filter { cachedContainerID, _ in
            activeContainerIDs.contains { activeContainerID in
                containerIDsMatch(activeContainerID, cachedContainerID)
            }
        }
        lock.unlock()
    }

    private func removeForContainer(_ containerID: String) {
        lock.lock()
        let keys = statuses.compactMap { key, status -> ForwardKey? in
            guard let statusContainerID = status.containerID else { return nil }
            return containerIDsMatch(statusContainerID, containerID) ? key : nil
        }
        let staleTCP = keys.compactMap { tcpListeners.removeValue(forKey: $0) }
        let staleUDP = keys.compactMap { udpListeners.removeValue(forKey: $0) }
        let now = Date()
        for key in keys {
            statuses[key]?.state = .stale
            statuses[key]?.updatedAt = now
        }
        publishedPortCache = publishedPortCache.filter { cachedContainerID, _ in
            !containerIDsMatch(cachedContainerID, containerID)
        }
        containerTargetIPCache = containerTargetIPCache.filter { cachedContainerID, _ in
            !containerIDsMatch(cachedContainerID, containerID)
        }
        lastReconcileAt = now
        lock.unlock()
        staleTCP.forEach { $0.stop() }
        staleUDP.forEach { $0.stop() }
    }

    private func reconcile(publishedPorts: Set<DockerPublishedPort>, scopedContainerIDs: Set<String>? = nil) {
        var desiredStatuses: [ForwardKey: (DockerPublishedPort, String, String?)] = [:]
        var failedStatuses: [ForwardKey: ConjetPortForwardStatus] = [:]
        let now = Date()

        for publishedPort in publishedPorts {
            let decision = policy.evaluate(publishedPort)
            if !decision.allowed {
                let key = ForwardKey(
                    hostIP: publishedPort.hostIP ?? "0.0.0.0",
                    hostPort: publishedPort.hostPort,
                    proto: publishedPort.protocol
                )
                failedStatuses[key] = status(
                    for: publishedPort,
                    bindAddress: key.hostIP,
                    state: .failedPolicyDenied,
                    error: decision.deniedReason,
                    warning: decision.warning,
                    now: now
                )
                continue
            }
            for bindAddress in decision.bindAddresses {
                let key = ForwardKey(hostIP: bindAddress, hostPort: publishedPort.hostPort, proto: publishedPort.protocol)
                desiredStatuses[key] = (publishedPort, bindAddress, decision.warning)
            }
        }

        lock.lock()
        let existingKeys = Set(tcpListeners.keys).union(Set(udpListeners.keys))
        let knownStatusKeys = Set(statuses.keys)
        let desiredKeys = Set(desiredStatuses.keys)
        let failedKeys = Set(failedStatuses.keys)
        let candidateStaleKeys = existingKeys.union(knownStatusKeys)
        let scopedStaleKeys: Set<ForwardKey>
        if let scopedContainerIDs {
            scopedStaleKeys = Set(candidateStaleKeys.filter { key in
                guard let containerID = statuses[key]?.containerID else { return false }
                return scopedContainerIDs.contains { scopedContainerID in
                    containerIDsMatch(scopedContainerID, containerID)
                }
            })
        } else {
            scopedStaleKeys = candidateStaleKeys
        }
        let staleKeys = scopedStaleKeys.subtracting(desiredKeys).subtracting(failedKeys)
        let staleTCP = staleKeys.compactMap { tcpListeners.removeValue(forKey: $0) }
        let staleUDP = staleKeys.compactMap { udpListeners.removeValue(forKey: $0) }
        for key in staleKeys {
            statuses[key]?.state = .stale
            statuses[key]?.updatedAt = now
        }
        lock.unlock()
        staleTCP.forEach { $0.stop() }
        staleUDP.forEach { $0.stop() }

        for (key, desired) in desiredStatuses {
            switch key.proto {
            case .tcp:
                reconcileTCP(key: key, publishedPort: desired.0, bindAddress: desired.1, warning: desired.2)
            case .udp:
                reconcileUDP(key: key, publishedPort: desired.0, bindAddress: desired.1, warning: desired.2)
            }
        }

        lock.lock()
        for (key, status) in failedStatuses {
            statuses[key] = status
        }
        lastReconcileAt = now
        lock.unlock()
    }

    private func prepublishCreateIntent(_ intent: DockerCreatePublicationIntent) {
        guard capabilities.tcpProxy else { return }
        guard isRunning() else { return }
        prepublishPendingTCPPorts(intent.ports)
    }

    private func prepublishPendingTCPPorts(_ ports: Set<DockerPublishedPort>) {
        guard capabilities.tcpProxy else { return }
        guard isRunning() else { return }

        for publishedPort in ports where publishedPort.protocol == .tcp {
            let decision = policy.evaluate(publishedPort)
            if !decision.allowed {
                let key = ForwardKey(
                    hostIP: publishedPort.hostIP ?? "0.0.0.0",
                    hostPort: publishedPort.hostPort,
                    proto: publishedPort.protocol
                )
                setStatus(for: key, status(
                    for: publishedPort,
                    bindAddress: key.hostIP,
                    state: .failedPolicyDenied,
                    error: decision.deniedReason,
                    warning: decision.warning
                ))
                continue
            }

            for bindAddress in decision.bindAddresses {
                let key = ForwardKey(
                    hostIP: bindAddress,
                    hostPort: publishedPort.hostPort,
                    proto: publishedPort.protocol
                )
                reconcileTCP(
                    key: key,
                    publishedPort: publishedPort,
                    bindAddress: bindAddress,
                    warning: decision.warning,
                    allowPendingTarget: true
                )
            }
        }
    }

    private func reconcileTCP(
        key: ForwardKey,
        publishedPort: DockerPublishedPort,
        bindAddress: String,
        warning: String?,
        allowPendingTarget: Bool = false
    ) {
        guard capabilities.tcpProxy else {
            setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: .failedGuestCapability, error: "guest image does not advertise tcp_proxy", warning: warning))
            return
        }
        lock.lock()
        let existing = tcpListeners[key]
        lock.unlock()
        if let existing {
            if useNativeTCPPoolForPublishedPorts {
                if let target = concreteNativeTCPTarget(for: publishedPort) {
                    existing.updateTarget(host: target.host, port: target.port)
                    setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: .listening, warning: warning))
                } else {
                    setStatus(for: key, status(
                        for: publishedPort,
                        bindAddress: bindAddress,
                        state: .reservedWaitingForTarget,
                        error: noRoutableTargetMessage(port: publishedPort),
                        warning: warning
                    ))
                }
            } else {
                let target = tcpTarget(for: publishedPort)
                existing.updateTarget(host: target.host, port: target.port)
                setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: .listening, warning: warning))
            }
            return
        }

        let listener: any PortListener
        let listenerState: ConjetPortForwardState
        let listenerError: String?
        if useNativeTCPPoolForPublishedPorts {
            let target = concreteNativeTCPTarget(for: publishedPort)
            if target == nil, !allowPendingTarget {
                setStatus(for: key, status(
                    for: publishedPort,
                    bindAddress: bindAddress,
                    state: .failedNoRoutableTarget,
                    error: noRoutableTargetMessage(port: publishedPort),
                    warning: warning
                ))
                return
            }
            listenerState = target == nil ? .reservedWaitingForTarget : .listening
            listenerError = target == nil ? noRoutableTargetMessage(port: publishedPort) : nil
            listener = NativeTCPPooledPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                targetHost: target?.host,
                targetPort: target?.port,
                connector: connector,
                statusHandler: { [weak self] metrics in
                    self?.updateMetrics(key: key, metrics: metrics)
                }
            )
        } else if useNIOProxy {
            let target = tcpTarget(for: publishedPort)
            listenerState = .listening
            listenerError = nil
            listener = NIOTCPPublishedPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                targetHost: target.host,
                targetPort: target.port,
                connector: connector,
                group: nioGroup,
                statusHandler: { [weak self] metrics in
                    self?.updateMetrics(key: key, metrics: metrics)
                }
            )
        } else {
            let target = tcpTarget(for: publishedPort)
            listenerState = .listening
            listenerError = nil
            listener = TCPPublishedPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                targetHost: target.host,
                targetPort: target.port,
                connector: connector,
                statusHandler: { [weak self] metrics in
                    self?.updateMetrics(key: key, metrics: metrics)
                }
            )
        }
        do {
            try listener.start()
            lock.lock()
            if running {
                tcpListeners[key] = listener
                statuses[key] = status(
                    for: publishedPort,
                    bindAddress: bindAddress,
                    state: listenerState,
                    error: listenerError,
                    warning: warning
                )
                if let listenerError {
                    appendMessage(listenerError)
                }
                appendMessage("port forward created \(bindAddress):\(publishedPort.hostPort)/tcp")
                lock.unlock()
            } else {
                lock.unlock()
                listener.stop()
            }
        } catch {
            listener.stop()
            let failure = bindFailureStatus(bindAddress: bindAddress, port: publishedPort.hostPort, proto: .tcp, error: error)
            setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: failure.state, error: failure.message, warning: warning))
        }
    }

    private func tcpTarget(for publishedPort: DockerPublishedPort) -> (host: String, port: Int) {
        // The legacy text TCP proxy runs inside the guest and should enter Docker
        // through the guest's published host port. Deployed bootstrap proxies only
        // accept loopback text targets, and Docker's host-port path preserves
        // compatibility with normal published-port behavior while the binary TCP
        // pool remains disabled for Docker-published ports.
        return ("127.0.0.1", publishedPort.hostPort)
    }

    private func concreteNativeTCPTarget(for publishedPort: DockerPublishedPort) -> (host: String, port: Int)? {
        guard let targetIP = publishedPort.targetIP, !targetIP.isEmpty else {
            return nil
        }
        return (targetIP, publishedPort.containerPort)
    }

    private func reconcileUDP(
        key: ForwardKey,
        publishedPort: DockerPublishedPort,
        bindAddress: String,
        warning: String?
    ) {
        guard capabilities.udpProxy else {
            setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: .failedGuestCapability, error: "guest image does not advertise udp_proxy", warning: warning))
            return
        }
        lock.lock()
        let existing = udpListeners[key]
        let exists = existing != nil || startingUDPKeys.contains(key)
        if !exists {
            startingUDPKeys.insert(key)
        }
        lock.unlock()
        if let existing {
            let target = udpTarget(for: publishedPort, bindAddress: bindAddress)
            existing.updateTarget(host: target.host, port: target.port)
            setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: .listening, warning: warning))
            return
        }
        guard !exists else { return }
        defer {
            lock.lock()
            startingUDPKeys.remove(key)
            lock.unlock()
        }

        let listener: any PortListener
        let binaryUDP = capabilities.binaryFrames && capabilities.udpBinaryFrames
        let portForwardID = binaryPortForwardID(hostPort: publishedPort.hostPort, targetPort: publishedPort.containerPort)
        let target = udpTarget(for: publishedPort, bindAddress: bindAddress)
        if useNIOProxy {
            listener = NIOUDPPublishedPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                targetHost: target.host,
                targetPort: target.port,
                portForwardID: portForwardID,
                useBinaryFrames: binaryUDP,
                connector: connector,
                group: nioGroup,
                statusHandler: { [weak self] metrics in
                    self?.updateMetrics(key: key, metrics: metrics)
                }
            )
        } else {
            listener = UDPPublishedPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                targetHost: target.host,
                targetPort: target.port,
                portForwardID: portForwardID,
                useBinaryFrames: binaryUDP,
                connector: connector,
                statusHandler: { [weak self] metrics in
                    self?.updateMetrics(key: key, metrics: metrics)
                }
            )
        }
        do {
            try listener.start()
            lock.lock()
            if running {
                udpListeners[key] = listener
                statuses[key] = status(for: publishedPort, bindAddress: bindAddress, state: .listening, warning: warning)
                appendMessage("port forward created \(bindAddress):\(publishedPort.hostPort)/udp")
                lock.unlock()
            } else {
                lock.unlock()
                listener.stop()
            }
        } catch {
            listener.stop()
            let failure = bindFailureStatus(bindAddress: bindAddress, port: publishedPort.hostPort, proto: .udp, error: error)
            setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: failure.state, error: failure.message, warning: warning))
        }
    }

    private func udpTarget(for publishedPort: DockerPublishedPort, bindAddress: String) -> (host: String, port: Int) {
        if capabilities.binaryFrames,
           capabilities.udpBinaryFrames,
           bridgeEngineName == ConjetNetworkBridgeEngine.conjetNetdC.rawValue,
           let targetIP = publishedPort.targetIP,
           !targetIP.isEmpty {
            return (targetIP, publishedPort.containerPort)
        }
        if bindAddress == "::1" || publishedPort.hostIP == "::1" {
            return ("::1", publishedPort.hostPort)
        }
        return ("127.0.0.1", publishedPort.hostPort)
    }

    private func status(
        for publishedPort: DockerPublishedPort,
        bindAddress: String,
        state: ConjetPortForwardState,
        error: String? = nil,
        warning: String? = nil,
        now: Date = Date()
    ) -> ConjetPortForwardStatus {
        ConjetPortForwardStatus(
            hostIP: bindAddress,
            hostPort: publishedPort.hostPort,
            protocol: publishedPort.protocol,
            targetIP: publishedPort.targetIP,
            targetPort: publishedPort.containerPort,
            containerID: publishedPort.containerID,
            containerName: publishedPort.containerName,
            state: state,
            error: error,
            warning: warning,
            policy: policy.bindPolicy,
            proxyEngine: actualProxyEngine,
            createdAt: now,
            updatedAt: now
        )
    }

    private func setStatus(for key: ForwardKey, _ status: ConjetPortForwardStatus) {
        lock.lock()
        statuses[key] = status
        if let error = status.error {
            appendMessage(error)
        }
        lock.unlock()
    }

    private func appendMessage(_ message: String) {
        messages.append(message)
        if messages.count > Self.maxStatusMessages {
            messages.removeFirst(messages.count - Self.maxStatusMessages)
        }
    }

    private func updateMetrics(key: ForwardKey, metrics: ProxyMetrics) {
        lock.lock()
        guard var status = statuses[key] else {
            lock.unlock()
            return
        }
        let observedConnectionPort: DockerPublishedPort?
        if metrics.acceptedConnections > status.acceptedConnections {
            observedConnectionPort = DockerPublishedPort(
                hostIP: status.hostIP,
                hostPort: status.hostPort,
                containerPort: status.targetPort,
                protocol: status.protocol,
                containerID: status.containerID,
                containerName: status.containerName,
                targetIP: status.targetIP
            )
        } else {
            observedConnectionPort = nil
        }
        status.acceptedConnections = metrics.acceptedConnections
        status.activeConnections = metrics.activeConnections
        status.closedConnections = metrics.closedConnections
        status.bytesIn = metrics.bytesIn
        status.bytesOut = metrics.bytesOut
        status.connectionErrors = metrics.connectionErrors
        status.udpPacketsIn = metrics.udpPacketsIn
        status.udpPacketsOut = metrics.udpPacketsOut
        status.udpBytesIn = metrics.udpBytesIn
        status.udpBytesOut = metrics.udpBytesOut
        status.udpDroppedPackets = metrics.udpDroppedPackets
        status.updatedAt = Date()
        statuses[key] = status
        lock.unlock()
        if let observedConnectionPort {
            successfulConnectionHandler?(observedConnectionPort)
        }
    }

    private func conflictMessage(bindAddress: String, port: Int, proto: ConjetPortProtocol, error: Error) -> String {
        "Port \(port)/\(proto.rawValue) cannot be published on \(bindAddress) because it is already in use or unavailable. Suggested fix: stop the process using the port or change your Compose port mapping. Detail: \(error)"
    }

    private func noRoutableTargetMessage(port: DockerPublishedPort) -> String {
        let container = port.containerName ?? port.containerID ?? "container"
        return "Port \(port.hostPort)/\(port.protocol.rawValue) is reserved, but \(container) does not have a routable Docker bridge target for \(port.containerPort)/\(port.protocol.rawValue) yet."
    }

    private func bindFailureStatus(
        bindAddress: String,
        port: Int,
        proto: ConjetPortProtocol,
        error: Error
    ) -> (state: ConjetPortForwardState, message: String) {
        if let bindError = error as? HostPortBindError {
            switch bindError.posixCode {
            case EACCES, EPERM:
                if port < 1024 {
                    return (
                        .requiresPrivilegedHelper,
                        "Port \(port)/\(proto.rawValue) on \(bindAddress) requires the Conjet privileged port service. Suggested fix: approve and install the Conjet port helper, or publish a non-privileged host port such as 8080: \(bindError)"
                    )
                }
                return (
                    .failedPermission,
                    "Port \(port)/\(proto.rawValue) cannot be published on \(bindAddress) because macOS denied the bind. Detail: \(bindError)"
                )
            case EADDRINUSE:
                return (
                    .failedAddressInUse,
                    "Port \(port)/\(proto.rawValue) cannot be published on \(bindAddress) because it is already in use. Suggested fix: stop the process using the port or change your Compose port mapping. Detail: \(bindError)"
                )
            case EADDRNOTAVAIL:
                return (
                    .failedAddressUnavailable,
                    "Port \(port)/\(proto.rawValue) cannot be published because bind address \(bindAddress) is not available on this Mac. Suggested fix: use localhost, 0.0.0.0, or a configured interface address. Detail: \(bindError)"
                )
            case EINVAL:
                return (
                    .failedInvalidAddress,
                    "Port \(port)/\(proto.rawValue) cannot be published because bind address \(bindAddress) is invalid. Detail: \(bindError)"
                )
            default:
                break
            }
        }
        return (
            .failedConflict,
            conflictMessage(bindAddress: bindAddress, port: port, proto: proto, error: error)
        )
    }

    private func containerIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    public static func publishedPorts(fromDockerInspectJSON data: Data) -> Set<DockerPublishedPort> {
        guard let containers = try? JSONDecoder().decode([DockerInspectContainer].self, from: data) else {
            return []
        }
        return publishedPorts(fromDockerInspectContainers: containers, requireRunning: true)
    }

    private static func publishedPorts(
        fromDockerInspectContainers containers: [DockerInspectContainer],
        requireRunning: Bool
    ) -> Set<DockerPublishedPort> {
        var ports: Set<DockerPublishedPort> = []
        for container in containers {
            if requireRunning, container.state?.running != true {
                continue
            }
            let networkPorts = container.networkSettings?.ports
            let mappedPorts = networkPorts?.isEmpty == false ? networkPorts : container.hostConfig?.portBindings
            guard let mappedPorts else { continue }
            let targetIP = selectedDockerTargetIPAddress(from: container.networkSettings?.networks)
            for (containerPortKey, bindings) in mappedPorts {
                let keyParts = containerPortKey.split(separator: "/", maxSplits: 1).map(String.init)
                guard keyParts.count == 2,
                      let proto = ConjetPortProtocol(rawValue: keyParts[1]),
                      let containerPort = Int(keyParts[0]),
                      let bindings else {
                    continue
                }
                for binding in bindings {
                    guard let hostPortText = binding.hostPort,
                          let hostPort = Int(hostPortText),
                          hostPort > 0,
                          hostPort <= 65_535 else {
                        continue
                    }
                    ports.insert(DockerPublishedPort(
                        hostIP: binding.hostIP,
                        hostPort: hostPort,
                        containerPort: containerPort,
                        protocol: proto,
                        containerID: container.id,
                        containerName: container.name?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        targetIP: targetIP
                    ))
                }
            }
        }
        return ports
    }
}

private struct ForwardKey: Hashable {
    var hostIP: String
    var hostPort: Int
    var proto: ConjetPortProtocol
}

private extension ConjetEnergyMode {
    var defaultNetworkReconcileIntervalSeconds: TimeInterval {
        switch self {
        case .performance:
            return 45
        case .balanced:
            return 300
        case .eco:
            return 600
        }
    }

    var eventWatcherReconnectDelaySeconds: TimeInterval {
        switch self {
        case .performance:
            return 1
        case .balanced:
            return 3
        case .eco:
            return 10
        }
    }
}

private final class ProxyMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acceptedConnections: UInt64 = 0
    private(set) var activeConnections: UInt64 = 0
    private(set) var closedConnections: UInt64 = 0
    private(set) var bytesIn: UInt64 = 0
    private(set) var bytesOut: UInt64 = 0
    private(set) var connectionErrors: UInt64 = 0
    private(set) var udpPacketsIn: UInt64 = 0
    private(set) var udpPacketsOut: UInt64 = 0
    private(set) var udpBytesIn: UInt64 = 0
    private(set) var udpBytesOut: UInt64 = 0
    private(set) var udpDroppedPackets: UInt64 = 0

    func accepted() { mutate { acceptedConnections += 1; activeConnections += 1 } }
    func closed() { mutate { closedConnections += 1; activeConnections = activeConnections > 0 ? activeConnections - 1 : 0 } }
    func error() { mutate { connectionErrors += 1 } }
    func inBytes(_ count: Int) { mutate { bytesIn += UInt64(max(0, count)) } }
    func outBytes(_ count: Int) { mutate { bytesOut += UInt64(max(0, count)) } }
    func udpIn(_ count: Int) { mutate { udpPacketsIn += 1; udpBytesIn += UInt64(max(0, count)) } }
    func udpOut(_ count: Int) { mutate { udpPacketsOut += 1; udpBytesOut += UInt64(max(0, count)) } }
    func udpDrop() { mutate { udpDroppedPackets += 1 } }
    func shouldReport(every interval: UInt64 = 64) -> Bool {
        lock.lock()
        let total = acceptedConnections + closedConnections + connectionErrors + udpPacketsIn + udpPacketsOut + udpDroppedPackets
        lock.unlock()
        return interval == 0 || total % interval == 0
    }

    private func mutate(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }
}

private protocol PortListener: AnyObject, Sendable {
    func start() throws
    func stop()
    func updateTarget(host: String, port: Int)
}

private extension PortListener {
    func updateTarget(host: String, port: Int) {}
}

private final class MutablePortTarget: @unchecked Sendable {
    private let condition = NSCondition()
    private var target: (host: String, port: Int)?

    init(host: String?, port: Int?) {
        if let host, let port {
            target = (host, port)
        }
    }

    func update(host: String, port: Int) {
        condition.lock()
        target = (host, port)
        condition.broadcast()
        condition.unlock()
    }

    func snapshot() -> (host: String, port: Int)? {
        condition.lock()
        let value = target
        condition.unlock()
        return value
    }

    func wait(timeoutSeconds: TimeInterval) -> (host: String, port: Int)? {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        condition.lock()
        while target == nil {
            let shouldContinue = condition.wait(until: deadline)
            if !shouldContinue || Date() >= deadline {
                break
            }
        }
        let value = target
        condition.unlock()
        return value
    }
}

private final class BinaryUDPGuestSession: @unchecked Sendable {
    private let connector: any GuestConnectionConnector
    private let portForwardID: UInt32
    private let lock = NSLock()
    private var connection: GuestConnection?
    private var nextStreamID: UInt32 = 1

    init(connector: any GuestConnectionConnector, portForwardID: UInt32) {
        self.connector = connector
        self.portForwardID = portForwardID
    }

    deinit {
        close()
    }

    func send(payload: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        do {
            let guest = try activeConnection()
            return try sendLocked(payload: payload, to: guest)
        } catch {
            closeLocked()
            let guest = try activeConnection()
            return try sendLocked(payload: payload, to: guest)
        }
    }

    func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    private func activeConnection() throws -> GuestConnection {
        if let connection {
            return connection
        }
        let guest = try connector.connect()
        disableSigpipeForPortProxy(guest.fileDescriptor)
        connection = guest
        return guest
    }

    private func sendLocked(payload: Data, to guest: GuestConnection) throws -> Data {
        let streamID = nextStreamID
        nextStreamID = nextStreamID == UInt32.max ? 1 : nextStreamID + 1
        return try sendBinaryUDPDatagram(
            payload: payload,
            portForwardID: portForwardID,
            streamID: streamID,
            to: guest.fileDescriptor
        )
    }

    private func closeLocked() {
        connection?.close()
        connection = nil
    }
}

private final class NIOTCPPublishedPortListener: PortListener, @unchecked Sendable {
    private let bindAddress: String
    private let hostPort: Int
    private let target: MutablePortTarget
    private let connector: any GuestConnectionConnector
    private let group: MultiThreadedEventLoopGroup
    private let statusHandler: @Sendable (ProxyMetrics) -> Void
    private let metrics = ProxyMetrics()
    private let lock = NSLock()
    private var channel: Channel?

    init(
        bindAddress: String,
        hostPort: Int,
        targetHost: String,
        targetPort: Int,
        connector: any GuestConnectionConnector,
        group: MultiThreadedEventLoopGroup,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.target = MutablePortTarget(host: targetHost, port: targetPort)
        self.connector = connector
        self.group = group
        self.statusHandler = statusHandler
    }

    deinit { stop() }

    func updateTarget(host: String, port: Int) {
        target.update(host: host, port: port)
    }

    func start() throws {
        lock.lock()
        if channel != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 512)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [connector, metrics, statusHandler, target] channel in
                channel.pipeline.addHandler(NIOTCPProxyHandler(
                    target: target,
                    connector: connector,
                    metrics: metrics,
                    statusHandler: statusHandler
                ))
            }

        let bound = try bootstrap.bind(host: bindAddress, port: hostPort).wait()
        lock.lock()
        channel = bound
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let channel = self.channel
        self.channel = nil
        lock.unlock()
        try? channel?.close(mode: .all).wait()
    }
}

private final class NIOTCPProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let target: MutablePortTarget
    private let connector: any GuestConnectionConnector
    private let metrics: ProxyMetrics
    private let statusHandler: @Sendable (ProxyMetrics) -> Void
    private let lock = NSLock()
    private var guest: GuestConnection?
    private var guestClosed = false

    init(
        target: MutablePortTarget,
        connector: any GuestConnectionConnector,
        metrics: ProxyMetrics,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.target = target
        self.connector = connector
        self.metrics = metrics
        self.statusHandler = statusHandler
    }

    func channelActive(context: ChannelHandlerContext) {
        metrics.accepted()
        statusHandler(metrics)
        do {
            let guest = try connector.connect()
            disableSigpipeForPortProxy(guest.fileDescriptor)
            guard let target = target.snapshot() else {
                metrics.error()
                statusHandler(metrics)
                guest.close()
                context.close(promise: nil)
                return
            }
            let preface = "CONJET-TCP \(target.host):\(target.port)\n"
            guard writeAllBytes(Data(preface.utf8), to: guest.fileDescriptor) else {
                metrics.error()
                statusHandler(metrics)
                guest.close()
                context.close(promise: nil)
                return
            }
            lock.lock()
            self.guest = guest
            lock.unlock()
            startGuestReader(guest: guest, channel: context.channel)
        } catch {
            metrics.error()
            statusHandler(metrics)
            var buffer = context.channel.allocator.buffer(capacity: 128)
            let body = "Conjet published port proxy is unavailable: \(error)\n"
            buffer.writeString("HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        lock.lock()
        let guest = self.guest
        lock.unlock()
        guard let guest else {
            metrics.error()
            statusHandler(metrics)
            context.close(promise: nil)
            return
        }
        let ok = bytes.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return true }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(guest.fileDescriptor, base.advanced(by: written), bytes.count - written)
                if count > 0 {
                    written += count
                    metrics.inBytes(count)
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.0005)
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        if !ok {
            metrics.error()
            statusHandler(metrics)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closeGuest(shutdown: true)
        metrics.closed()
        statusHandler(metrics)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            lock.lock()
            let guest = self.guest
            lock.unlock()
            if let guest {
                Darwin.shutdown(guest.fileDescriptor, SHUT_WR)
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        metrics.error()
        statusHandler(metrics)
        context.close(promise: nil)
    }

    private func startGuestReader(guest: GuestConnection, channel: Channel) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak channel] in
            guard let self, let channel else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(guest.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    let bytes = Array(buffer.prefix(count))
                    metrics.outBytes(count)
                    channel.eventLoop.execute {
                        guard channel.isActive else { return }
                        var out = channel.allocator.buffer(capacity: bytes.count)
                        out.writeBytes(bytes)
                        channel.writeAndFlush(out, promise: nil)
                    }
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.0005)
                    continue
                } else {
                    channel.eventLoop.execute {
                        channel.close(promise: nil)
                    }
                    return
                }
            }
        }
    }

    private func closeGuest(shutdown: Bool) {
        lock.lock()
        if guestClosed {
            lock.unlock()
            return
        }
        guestClosed = true
        let guest = self.guest
        self.guest = nil
        lock.unlock()
        if shutdown, let guest {
            Darwin.shutdown(guest.fileDescriptor, SHUT_RDWR)
        }
        guest?.close()
    }
}

private final class NIOUDPPublishedPortListener: PortListener, @unchecked Sendable {
    private let bindAddress: String
    private let hostPort: Int
    private let target: MutablePortTarget
    private let portForwardID: UInt32
    private let requestedBinaryFrames: Bool
    private let connector: any GuestConnectionConnector
    private let group: MultiThreadedEventLoopGroup
    private let statusHandler: @Sendable (ProxyMetrics) -> Void
    private let metrics = ProxyMetrics()
    private let lock = NSLock()
    private var channel: Channel?
    private var binaryFramesEnabled = false
    private var binarySession: BinaryUDPGuestSession?

    init(
        bindAddress: String,
        hostPort: Int,
        targetHost: String,
        targetPort: Int,
        portForwardID: UInt32,
        useBinaryFrames: Bool,
        connector: any GuestConnectionConnector,
        group: MultiThreadedEventLoopGroup,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.target = MutablePortTarget(host: targetHost, port: targetPort)
        self.portForwardID = portForwardID
        self.requestedBinaryFrames = useBinaryFrames
        self.connector = connector
        self.group = group
        self.statusHandler = statusHandler
    }

    deinit { stop() }

    func updateTarget(host: String, port: Int) {
        target.update(host: host, port: port)
        guard requestedBinaryFrames else { return }
        lock.lock()
        let enabled = binaryFramesEnabled
        lock.unlock()
        if enabled {
            _ = registerBinaryUDPTarget(
                connector: connector,
                portForwardID: portForwardID,
                guestHost: host,
                guestHostPort: port
            )
        }
    }

    func start() throws {
        lock.lock()
        if channel != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let initialTarget = target.snapshot() else {
            throw ConjetError.socket("UDP target is not ready")
        }
        let binaryEnabled = requestedBinaryFrames && registerBinaryUDPTarget(
            connector: connector,
            portForwardID: portForwardID,
            guestHost: initialTarget.host,
            guestHostPort: initialTarget.port
        )
        let session = binaryEnabled ? BinaryUDPGuestSession(
            connector: connector,
            portForwardID: portForwardID
        ) : nil
        lock.lock()
        binaryFramesEnabled = binaryEnabled
        binarySession = session
        lock.unlock()

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [connector, metrics, statusHandler, target, portForwardID, binaryEnabled, session] channel in
                channel.pipeline.addHandler(NIOUDPProxyHandler(
                    target: target,
                    portForwardID: portForwardID,
                    useBinaryFrames: binaryEnabled,
                    binarySession: session,
                    connector: connector,
                    metrics: metrics,
                    statusHandler: statusHandler
                ))
            }
        let bound = try bootstrap.bind(host: bindAddress, port: hostPort).wait()
        lock.lock()
        channel = bound
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let channel = self.channel
        self.channel = nil
        let session = binarySession
        binarySession = nil
        lock.unlock()
        try? channel?.close(mode: .all).wait()
        session?.close()
    }
}

private final class NIOUDPProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let target: MutablePortTarget
    private let portForwardID: UInt32
    private let useBinaryFrames: Bool
    private let binarySession: BinaryUDPGuestSession?
    private let connector: any GuestConnectionConnector
    private let metrics: ProxyMetrics
    private let statusHandler: @Sendable (ProxyMetrics) -> Void

    init(
        target: MutablePortTarget,
        portForwardID: UInt32,
        useBinaryFrames: Bool,
        binarySession: BinaryUDPGuestSession?,
        connector: any GuestConnectionConnector,
        metrics: ProxyMetrics,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.target = target
        self.portForwardID = portForwardID
        self.useBinaryFrames = useBinaryFrames
        self.binarySession = binarySession
        self.connector = connector
        self.metrics = metrics
        self.statusHandler = statusHandler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var envelope = unwrapInboundIn(data)
        guard let bytes = envelope.data.readBytes(length: envelope.data.readableBytes), !bytes.isEmpty else {
            metrics.udpDrop()
            statusHandler(metrics)
            return
        }
        metrics.udpIn(bytes.count)
        if metrics.shouldReport() {
            statusHandler(metrics)
        }
        let remoteAddress = envelope.remoteAddress
        let eventLoop = context.eventLoop
        let allocator = context.channel.allocator
        DispatchQueue.global(qos: .userInitiated).async { [connector, target, useBinaryFrames, binarySession, metrics, statusHandler, weak channel = context.channel] in
            guard let channel else { return }
            do {
                let response: Data
                if useBinaryFrames, let binarySession {
                    response = try binarySession.send(payload: Data(bytes))
                } else {
                    guard let target = target.snapshot() else {
                        metrics.udpDrop()
                        statusHandler(metrics)
                        return
                    }
                    let guest = try connector.connect()
                    disableSigpipeForPortProxy(guest.fileDescriptor)
                    defer { guest.close() }
                    let preface = "CONJET-UDP \(target.host):\(target.port)\n"
                    guard writeAllBytes(Data(preface.utf8) + Data(bytes), to: guest.fileDescriptor) else {
                        metrics.udpDrop()
                        statusHandler(metrics)
                        return
                    }
                    setSocketReadTimeout(guest.fileDescriptor, timeoutSeconds: 1)
                    response = readAllAvailable(from: guest.fileDescriptor, maxBytes: 65_507)
                }
                guard !response.isEmpty else {
                    metrics.udpDrop()
                    statusHandler(metrics)
                    return
                }
                metrics.udpOut(response.count)
                if metrics.shouldReport() {
                    statusHandler(metrics)
                }
                eventLoop.execute {
                    guard channel.isActive else { return }
                    var out = allocator.buffer(capacity: response.count)
                    out.writeBytes(response)
                    channel.writeAndFlush(AddressedEnvelope(remoteAddress: remoteAddress, data: out), promise: nil)
                }
            } catch {
                metrics.udpDrop()
                statusHandler(metrics)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        metrics.udpDrop()
        statusHandler(metrics)
    }
}

private final class NativeTCPPooledPortListener: PortListener, @unchecked Sendable {
    private let bindAddress: String
    private let hostPort: Int
    private let target: MutablePortTarget
    private let connector: any GuestConnectionConnector
    private let statusHandler: @Sendable (ProxyMetrics) -> Void
    private let metrics = ProxyMetrics()
    private let lock = NSLock()
    private var running = false
    private var listenerFD: Int32 = -1
    private var acceptThread: Thread?
    private var pool: NativeTCPBridgePool?

    init(
        bindAddress: String,
        hostPort: Int,
        targetHost: String?,
        targetPort: Int?,
        connector: any GuestConnectionConnector,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.target = MutablePortTarget(host: targetHost, port: targetPort)
        self.connector = connector
        self.statusHandler = statusHandler
    }

    deinit { stop() }

    func updateTarget(host: String, port: Int) {
        target.update(host: host, port: port)
    }

    func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

        let fd = try makeTCPListener(bindAddress: bindAddress, port: hostPort)
        let pool = NativeTCPBridgePool(connector: connector)
        lock.lock()
        listenerFD = fd
        self.pool = pool
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
        thread.name = "dev.conjet.native-tcp-listener.\(hostPort)"
        acceptThread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        let pool = self.pool
        self.pool = nil
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        pool?.close()
    }

    private func acceptLoop(listenerFD: Int32) {
        while isRunning {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.001)
                    continue
                }
                break
            }
            disableSigpipeForPortProxy(clientFD)
            setTCPNoDelayIfSupported(clientFD)
            setNonBlocking(clientFD)
            metrics.accepted()
            statusHandler(metrics)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        let value = running
        lock.unlock()
        return value
    }

    private func handleClient(_ clientFD: Int32) {
        defer {
            metrics.closed()
            statusHandler(metrics)
        }
        lock.lock()
        let pool = self.pool
        lock.unlock()
        guard let pool else {
            metrics.error()
            writeHTTPBadGateway("Conjet native TCP bridge pool is stopped\n", to: clientFD)
            Darwin.close(clientFD)
            return
        }
        guard let target = target.wait(timeoutSeconds: 3) else {
            metrics.error()
            writeHTTPBadGateway("Conjet native TCP target is not ready\n", to: clientFD)
            Darwin.close(clientFD)
            return
        }
        let openDeadline = Date().addingTimeInterval(0.15)
        while true {
            do {
                let connection = try pool.borrow()
                let result = connection.forward(
                    clientFD: clientFD,
                    targetHost: target.host,
                    targetPort: target.port,
                    onClientBytes: { [metrics] count in metrics.inBytes(count) },
                    onTargetBytes: { [metrics] count in metrics.outBytes(count) }
                )
                pool.recycle(connection, reusable: result.reusable)
                if result.opened || Date() >= openDeadline {
                    if result.hadError {
                        metrics.error()
                    }
                    if !result.opened {
                        writeHTTPBadGateway("Conjet native TCP target did not accept the connection yet\n", to: clientFD)
                    }
                    Darwin.close(clientFD)
                    return
                }
                Thread.sleep(forTimeInterval: 0.001)
            } catch {
                metrics.error()
                writeHTTPBadGateway("Conjet native TCP bridge is unavailable: \(error)\n", to: clientFD)
                Darwin.close(clientFD)
                return
            }
        }
    }
}

private final class TCPPublishedPortListener: PortListener, @unchecked Sendable {
    private let bindAddress: String
    private let hostPort: Int
    private let target: MutablePortTarget
    private let connector: any GuestConnectionConnector
    private let statusHandler: @Sendable (ProxyMetrics) -> Void
    private let metrics = ProxyMetrics()
    private let lock = NSLock()
    private var running = false
    private var listenerFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(
        bindAddress: String,
        hostPort: Int,
        targetHost: String,
        targetPort: Int,
        connector: any GuestConnectionConnector,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.target = MutablePortTarget(host: targetHost, port: targetPort)
        self.connector = connector
        self.statusHandler = statusHandler
    }

    deinit { stop() }

    func updateTarget(host: String, port: Int) {
        target.update(host: host, port: port)
    }

    func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

        let fd = try makeTCPListener(bindAddress: bindAddress, port: hostPort)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.acceptAvailable(listenerFD: fd)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        lock.lock()
        listenerFD = fd
        self.source = source
        running = true
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        running = false
        let source = self.source
        self.source = nil
        listenerFD = -1
        lock.unlock()
        source?.cancel()
    }

    private func acceptAvailable(listenerFD: Int32) {
        while true {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                break
            }
            disableSigpipeForPortProxy(clientFD)
            setNonBlocking(clientFD)
            metrics.accepted()
            statusHandler(metrics)
            let thread = Thread { [weak self] in
                self?.handleClient(clientFD)
            }
            thread.name = "dev.conjet.tcp-listener-client.\(hostPort)"
            thread.start()
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer {
            metrics.closed()
            statusHandler(metrics)
        }
        do {
            let guest = try connector.connect()
            guard let target = target.snapshot() else {
                metrics.error()
                guest.close()
                Darwin.close(clientFD)
                return
            }
            let preface = "CONJET-TCP \(target.host):\(target.port)\n"
            guard writeAllBytes(Data(preface.utf8), to: guest.fileDescriptor) else {
                metrics.error()
                guest.close()
                Darwin.close(clientFD)
                return
            }
            pipe(clientFD: clientFD, guest: guest)
        } catch {
            metrics.error()
            writeHTTPBadGateway("Conjet published port proxy is unavailable: \(error)\n", to: clientFD)
            Darwin.close(clientFD)
        }
    }

    private func pipe(clientFD: Int32, guest: GuestConnection) {
        let group = DispatchGroup()
        group.enter()
        let clientToGuest = Thread { [metrics] in
            copyBytes(from: clientFD, to: guest.fileDescriptor) { metrics.inBytes($0) }
            Darwin.shutdown(guest.fileDescriptor, SHUT_WR)
            group.leave()
        }
        clientToGuest.name = "dev.conjet.tcp-client-to-guest"
        clientToGuest.start()
        group.enter()
        let guestToClient = Thread { [metrics] in
            copyBytes(from: guest.fileDescriptor, to: clientFD) { metrics.outBytes($0) }
            Darwin.shutdown(clientFD, SHUT_WR)
            group.leave()
        }
        guestToClient.name = "dev.conjet.tcp-guest-to-client"
        guestToClient.start()
        group.wait()
        guest.close()
        Darwin.close(clientFD)
    }
}

private final class UDPPublishedPortListener: PortListener, @unchecked Sendable {
    private let bindAddress: String
    private let hostPort: Int
    private let target: MutablePortTarget
    private let portForwardID: UInt32
    private let requestedBinaryFrames: Bool
    private let connector: any GuestConnectionConnector
    private let statusHandler: @Sendable (ProxyMetrics) -> Void
    private let metrics = ProxyMetrics()
    private let lock = NSLock()
    private var running = false
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var binaryFramesEnabled = false
    private var binarySession: BinaryUDPGuestSession?

    init(
        bindAddress: String,
        hostPort: Int,
        targetHost: String,
        targetPort: Int,
        portForwardID: UInt32,
        useBinaryFrames: Bool,
        connector: any GuestConnectionConnector,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.target = MutablePortTarget(host: targetHost, port: targetPort)
        self.portForwardID = portForwardID
        self.requestedBinaryFrames = useBinaryFrames
        self.connector = connector
        self.statusHandler = statusHandler
    }

    deinit { stop() }

    func updateTarget(host: String, port: Int) {
        target.update(host: host, port: port)
        guard requestedBinaryFrames else { return }
        lock.lock()
        let enabled = binaryFramesEnabled
        lock.unlock()
        if enabled {
            _ = registerBinaryUDPTarget(
                connector: connector,
                portForwardID: portForwardID,
                guestHost: host,
                guestHostPort: port
            )
        }
    }

    func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

        let initialTarget = target.snapshot()
        guard let initialTarget else {
            throw ConjetError.socket("UDP target is not ready")
        }
        let fd = try makeUDPListener(bindAddress: bindAddress, port: hostPort)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.receiveAvailable(fd: fd)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        lock.lock()
        self.fd = fd
        self.source = source
        running = true
        lock.unlock()
        if requestedBinaryFrames {
            binaryFramesEnabled = registerBinaryUDPTarget(
                connector: connector,
                portForwardID: portForwardID,
                guestHost: initialTarget.host,
                guestHostPort: initialTarget.port
            )
            if binaryFramesEnabled {
                binarySession = BinaryUDPGuestSession(
                    connector: connector,
                    portForwardID: portForwardID
                )
            }
        }
        source.resume()
    }

    func stop() {
        lock.lock()
        running = false
        let source = self.source
        self.source = nil
        let session = binarySession
        binarySession = nil
        fd = -1
        lock.unlock()
        source?.cancel()
        session?.close()
    }

    private func receiveAvailable(fd: Int32) {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buffer = [UInt8](repeating: 0, count: 65_507)
            let count = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    Darwin.recvfrom(fd, &buffer, buffer.count, 0, address, &length)
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                metrics.udpDrop()
                statusHandler(metrics)
                break
            }
            guard count > 0 else { break }
            let payload = Data(buffer.prefix(count))
            metrics.udpIn(count)
            if metrics.shouldReport() {
                statusHandler(metrics)
            }
            let clientStorage = storage
            let clientAddressLength = length
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.forwardDatagram(
                    payload,
                    clientAddress: clientStorage,
                    clientAddressLength: clientAddressLength,
                    fd: fd
                )
            }
        }
    }

    private func forwardDatagram(_ payload: Data, clientAddress: sockaddr_storage, clientAddressLength: socklen_t, fd: Int32) {
        do {
            let response: Data
            if binaryFramesEnabled, let binarySession {
                response = try binarySession.send(payload: payload)
            } else {
                guard let target = target.snapshot() else {
                    metrics.udpDrop()
                    statusHandler(metrics)
                    return
                }
                let guest = try connector.connect()
                defer { guest.close() }
                let preface = "CONJET-UDP \(target.host):\(target.port)\n"
                guard writeAllBytes(Data(preface.utf8) + payload, to: guest.fileDescriptor) else {
                    metrics.udpDrop()
                    statusHandler(metrics)
                    return
                }
                setSocketReadTimeout(guest.fileDescriptor, timeoutSeconds: 2)
                response = readAllAvailable(from: guest.fileDescriptor, maxBytes: 65_507)
            }
            guard !response.isEmpty else {
                metrics.udpDrop()
                statusHandler(metrics)
                return
            }
            var address = clientAddress
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(fd, [UInt8](response), response.count, 0, socketAddress, clientAddressLength)
                }
            }
            if sent > 0 {
                metrics.udpOut(sent)
                if metrics.shouldReport() {
                    statusHandler(metrics)
                }
            } else {
                metrics.udpDrop()
                statusHandler(metrics)
            }
        } catch {
            metrics.udpDrop()
            statusHandler(metrics)
        }
    }
}

private struct DockerInspectContainer: Decodable {
    var id: String?
    var name: String?
    var state: DockerInspectState?
    var hostConfig: DockerInspectHostConfig?
    var networkSettings: DockerInspectNetworkSettings?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case state = "State"
        case hostConfig = "HostConfig"
        case networkSettings = "NetworkSettings"
    }
}

private struct DockerInspectState: Decodable {
    var running: Bool?

    private enum CodingKeys: String, CodingKey {
        case running = "Running"
    }
}

private struct DockerInspectNetworkSettings: Decodable {
    var ports: [String: [DockerInspectPortBinding]?]?
    var networks: [String: DockerInspectNetwork]?

    private enum CodingKeys: String, CodingKey {
        case ports = "Ports"
        case networks = "Networks"
    }
}

private struct DockerInspectHostConfig: Decodable {
    var portBindings: [String: [DockerInspectPortBinding]?]?

    private enum CodingKeys: String, CodingKey {
        case portBindings = "PortBindings"
    }
}

private struct DockerInspectNetwork: Decodable {
    var ipAddress: String?
    var networkID: String?
    var gateway: String?
    var globalIPv6Address: String?

    private enum CodingKeys: String, CodingKey {
        case ipAddress = "IPAddress"
        case networkID = "NetworkID"
        case gateway = "Gateway"
        case globalIPv6Address = "GlobalIPv6Address"
    }
}

private struct DockerInspectPortBinding: Decodable {
    var hostIP: String?
    var hostPort: String?

    private enum CodingKeys: String, CodingKey {
        case hostIP = "HostIp"
        case hostPort = "HostPort"
    }
}

private struct DockerContainerTargetSnapshot: Decodable {
    var id: String
    var names: [String]?
    var networkSettings: DockerInspectNetworkSettings?

    var targetIPAddress: String? {
        selectedDockerTargetIPAddress(from: networkSettings?.networks)
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case networkSettings = "NetworkSettings"
    }
}

private struct DockerTargetCandidate {
    var name: String
    var ipAddress: String
    var networkID: String?
}

private func selectedDockerTargetIPAddress(from networks: [String: DockerInspectNetwork]?) -> String? {
    guard let networks, !networks.isEmpty else { return nil }
    let candidates = networks.compactMap { name, network -> DockerTargetCandidate? in
        guard let ipAddress = network.ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              isUsableDockerTargetIPv4Address(ipAddress) else {
            return nil
        }
        return DockerTargetCandidate(name: name, ipAddress: ipAddress, networkID: network.networkID)
    }
    guard !candidates.isEmpty else { return nil }

    if let bridge = candidates.first(where: { $0.name == "bridge" }) {
        return bridge.ipAddress
    }

    return candidates.sorted(by: isPreferredDockerTargetCandidate).first?.ipAddress
}

private func isPreferredDockerTargetCandidate(
    _ lhs: DockerTargetCandidate,
    _ rhs: DockerTargetCandidate
) -> Bool {
    let lhsRank = dockerTargetCandidateRank(lhs)
    let rhsRank = dockerTargetCandidateRank(rhs)
    if lhsRank != rhsRank {
        return lhsRank < rhsRank
    }
    if lhs.name != rhs.name {
        return lhs.name < rhs.name
    }
    if lhs.ipAddress != rhs.ipAddress {
        return lhs.ipAddress < rhs.ipAddress
    }
    return (lhs.networkID ?? "") < (rhs.networkID ?? "")
}

private func dockerTargetCandidateRank(_ candidate: DockerTargetCandidate) -> Int {
    if candidate.name == "bridge" {
        return 0
    }
    if candidate.name.hasSuffix("_default") {
        return 1
    }
    if candidate.name == "default" {
        return 2
    }
    return 3
}

private func isUsableDockerTargetIPv4Address(_ address: String) -> Bool {
    var parsed = in_addr()
    guard inet_pton(AF_INET, address, &parsed) == 1 else {
        return false
    }
    let value = UInt32(bigEndian: parsed.s_addr)
    let firstOctet = (value >> 24) & 0xff
    let secondOctet = (value >> 16) & 0xff
    if value == 0 || value == UInt32.max {
        return false
    }
    if firstOctet == 127 {
        return false
    }
    if firstOctet == 169 && secondOctet == 254 {
        return false
    }
    return true
}

private struct DockerAPIHTTPResponse {
    var statusCode: Int
    var body: Data

    init?(data: Data) {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        guard let parsedHeader = Self.parseHeader(headerText) else { return nil }
        self.statusCode = parsedHeader.statusCode
        let rawBody = Data(data[headerRange.upperBound...])
        if parsedHeader.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = Self.decodeChunkedBody(rawBody) else { return nil }
            self.body = decoded
        } else {
            self.body = rawBody
        }
    }

    static func parseHeader(_ headerText: String) -> (statusCode: Int, headers: [String: String])? {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return (statusCode, headers)
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        var index = data.startIndex
        var decoded = Data()
        while true {
            guard index < data.endIndex,
                  let lineEnd = data[index...].range(of: Data([13, 10]))?.lowerBound,
                  let line = String(data: data[index..<lineEnd], encoding: .utf8) else {
                return nil
            }
            let sizeText = line
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                return nil
            }
            index = lineEnd + 2
            if size == 0 {
                return decoded
            }
            let chunkEnd = index + size
            guard chunkEnd + 2 <= data.endIndex else {
                return nil
            }
            decoded.append(data[index..<chunkEnd])
            guard data[chunkEnd] == 13, data[chunkEnd + 1] == 10 else {
                return nil
            }
            index = chunkEnd + 2
        }
    }
}

private func setSocketTimeoutForDockerAPI(_ fd: Int32, timeoutSeconds: Double) {
    let seconds = max(0, timeoutSeconds)
    var timeout = timeval(
        tv_sec: Int(seconds),
        tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000)
    )
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func writeAllForDockerAPI(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return true
        }
        var written = 0
        while written < data.count {
            let count = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
            if count > 0 {
                written += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

private func readAllForDockerAPI(from fd: Int32, maxBytes: Int) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count < maxBytes {
        let count = Darwin.read(fd, &buffer, min(buffer.count, maxBytes - data.count))
        if count > 0 {
            data.append(buffer, count: count)
        } else if count < 0, errno == EINTR {
            continue
        } else {
            break
        }
    }
    return data
}

private func makeTCPListener(bindAddress: String, port: Int) throws -> Int32 {
    try DirectHostPortBinder.shared.bind(HostPortBindRequest(
        bindAddress: bindAddress,
        port: port,
        socketType: SOCK_STREAM,
        proto: .tcp
    )).fileDescriptor
}

private func makeUDPListener(bindAddress: String, port: Int) throws -> Int32 {
    try DirectHostPortBinder.shared.bind(HostPortBindRequest(
        bindAddress: bindAddress,
        port: port,
        socketType: SOCK_DGRAM,
        proto: .udp
    )).fileDescriptor
}

private struct HostPortBindRequest {
    var bindAddress: String
    var port: Int
    var socketType: Int32
    var proto: ConjetPortProtocol
}

private struct BoundHostPortSocket {
    var fileDescriptor: Int32
}

private protocol HostPortBinder {
    func bind(_ request: HostPortBindRequest) throws -> BoundHostPortSocket
}

private struct DirectHostPortBinder: HostPortBinder {
    static let shared = DirectHostPortBinder()

    func bind(_ request: HostPortBindRequest) throws -> BoundHostPortSocket {
        let fd: Int32
        if isIPv6BindAddress(request.bindAddress) {
            fd = try makeIPv6Listener(
                type: request.socketType,
                bindAddress: request.bindAddress,
                port: request.port,
                proto: request.proto
            )
        } else {
            fd = try makeIPv4Listener(
                type: request.socketType,
                bindAddress: request.bindAddress,
                port: request.port,
                proto: request.proto
            )
        }
        return BoundHostPortSocket(fileDescriptor: fd)
    }
}

private struct HostPortBindError: Error, CustomStringConvertible {
    enum Operation: String {
        case socket
        case bind
        case listen
        case invalidAddress = "inet_pton"
    }

    var operation: Operation
    var address: String
    var port: Int
    var proto: ConjetPortProtocol
    var posixCode: Int32
    var detail: String

    var description: String {
        if posixCode == 0 {
            return "\(operation.rawValue)(\(address):\(port)/\(proto.rawValue)) failed: \(detail)"
        }
        let reason = String(cString: strerror(posixCode))
        return "\(operation.rawValue)(\(address):\(port)/\(proto.rawValue)) failed: \(reason)"
    }
}

private func makeIPv4Listener(
    type: Int32,
    bindAddress: String,
    port: Int,
    proto: ConjetPortProtocol
) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, type, 0)
    guard fd >= 0 else {
        throw HostPortBindError(
            operation: .socket,
            address: bindAddress,
            port: port,
            proto: proto,
            posixCode: errno,
            detail: "socket(AF_INET)"
        )
    }
    do {
        try configureListenerFD(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        let ip = bindAddress == "localhost" ? "127.0.0.1" : bindAddress
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            throw HostPortBindError(
                operation: .invalidAddress,
                address: bindAddress,
                port: port,
                proto: proto,
                posixCode: 0,
                detail: "invalid IPv4 bind address"
            )
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw HostPortBindError(
                        operation: .bind,
                        address: bindAddress,
                        port: port,
                        proto: proto,
                        posixCode: errno,
                        detail: "bind(AF_INET)"
                    )
                }
            }
        }
        if type == SOCK_STREAM {
            guard Darwin.listen(fd, 128) == 0 else {
                throw HostPortBindError(
                    operation: .listen,
                    address: bindAddress,
                    port: port,
                    proto: proto,
                    posixCode: errno,
                    detail: "listen(AF_INET)"
                )
            }
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func makeIPv6Listener(
    type: Int32,
    bindAddress: String,
    port: Int,
    proto: ConjetPortProtocol
) throws -> Int32 {
    let fd = Darwin.socket(AF_INET6, type, 0)
    guard fd >= 0 else {
        throw HostPortBindError(
            operation: .socket,
            address: bindAddress,
            port: port,
            proto: proto,
            posixCode: errno,
            detail: "socket(AF_INET6)"
        )
    }
    do {
        try configureListenerFD(fd)
        var v6Only: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(port).bigEndian
        let ip = bindAddress == "localhost" ? "::1" : bindAddress
        guard inet_pton(AF_INET6, ip, &address.sin6_addr) == 1 else {
            throw HostPortBindError(
                operation: .invalidAddress,
                address: bindAddress,
                port: port,
                proto: proto,
                posixCode: 0,
                detail: "invalid IPv6 bind address"
            )
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 else {
                    throw HostPortBindError(
                        operation: .bind,
                        address: bindAddress,
                        port: port,
                        proto: proto,
                        posixCode: errno,
                        detail: "bind(AF_INET6)"
                    )
                }
            }
        }
        if type == SOCK_STREAM {
            guard Darwin.listen(fd, 128) == 0 else {
                throw HostPortBindError(
                    operation: .listen,
                    address: bindAddress,
                    port: port,
                    proto: proto,
                    posixCode: errno,
                    detail: "listen(AF_INET6)"
                )
            }
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func isIPv6BindAddress(_ address: String) -> Bool {
    address.contains(":")
}

private func configureListenerFD(_ fd: Int32) throws {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
    disableSigpipeForPortProxy(fd)
    setNonBlocking(fd)
}

private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

private func disableSigpipeForPortProxy(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func setTCPNoDelayIfSupported(_ fd: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func writeHTTPBadGateway(_ message: String, to fd: Int32) {
    let body = Data(message.utf8)
    let response = """
    HTTP/1.1 502 Bad Gateway\r
    Content-Type: text/plain; charset=utf-8\r
    Connection: close\r
    Content-Length: \(body.count)\r
    \r
    \(message)
    """
    _ = response.withCString { pointer in
        Darwin.write(fd, pointer, strlen(pointer))
    }
}

private func writeAllBytes(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
        var written = 0
        while written < data.count {
            let count = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
            if count > 0 {
                written += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

private func copyBytes(from sourceFD: Int32, to destinationFD: Int32, onWrite: (Int) -> Void) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let readCount = Darwin.read(sourceFD, &buffer, buffer.count)
        if readCount > 0 {
            var written = 0
            while written < readCount {
                let writeCount = Darwin.write(destinationFD, buffer.withUnsafeBytes { rawBuffer in
                    rawBuffer.baseAddress!.advanced(by: written)
                }, readCount - written)
                if writeCount > 0 {
                    written += writeCount
                    onWrite(writeCount)
                } else if writeCount < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        } else if readCount < 0, errno == EINTR {
            continue
        } else if readCount < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            Thread.sleep(forTimeInterval: 0.001)
            continue
        } else {
            return
        }
    }
}

private func readAllAvailable(from fd: Int32, maxBytes: Int) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: min(4096, maxBytes))
    while data.count < maxBytes {
        let count = Darwin.read(fd, &buffer, min(buffer.count, maxBytes - data.count))
        if count > 0 {
            data.append(buffer, count: count)
        } else if count < 0, errno == EINTR {
            continue
        } else {
            break
        }
    }
    return data
}

private func setSocketReadTimeout(_ fd: Int32, timeoutSeconds: Double) {
    let seconds = Int(timeoutSeconds)
    let microseconds = Int((timeoutSeconds - Double(seconds)) * 1_000_000)
    var timeout = timeval(tv_sec: seconds, tv_usec: Int32(microseconds))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func binaryPortForwardID(hostPort: Int, targetPort: Int) -> UInt32 {
    UInt32((max(0, min(hostPort, 65_535)) << 16) | max(0, min(targetPort, 65_535)))
}

private func registerBinaryUDPTarget(
    connector: any GuestConnectionConnector,
    portForwardID: UInt32,
    guestHost: String,
    guestHostPort: Int
) -> Bool {
    do {
        let guest = try connector.connect()
        defer { guest.close() }
        setSocketReadTimeout(guest.fileDescriptor, timeoutSeconds: 1)
        let payload = Data("\(portForwardID) udp \(guestHost) \(guestHostPort)".utf8)
        let frame = ConjetBinaryFrame(
            type: .registerTarget,
            streamID: 0,
            portForwardID: portForwardID,
            payload: payload
        )
        guard writeBinaryFrame(frame, to: guest.fileDescriptor),
              let response = try? readBinaryFrame(from: guest.fileDescriptor) else {
            return false
        }
        return response.type == .helloAck
    } catch {
        return false
    }
}

private func sendBinaryUDPDatagram(
    payload: Data,
    portForwardID: UInt32,
    streamID: UInt32,
    to fd: Int32
) throws -> Data {
    setSocketReadTimeout(fd, timeoutSeconds: 1)
    let frame = ConjetBinaryFrame(
        type: .udp,
        streamID: streamID,
        portForwardID: portForwardID,
        payload: payload
    )
    guard writeBinaryFrame(frame, to: fd) else {
        throw ConjetError.socket("failed to write binary UDP frame")
    }
    let response = try readBinaryFrame(from: fd)
    guard response.type == .udp else {
        throw ConjetError.socket("binary UDP frame returned \(response.type)")
    }
    return response.payload
}

private func writeBinaryFrame(_ frame: ConjetBinaryFrame, to fd: Int32) -> Bool {
    guard let data = try? frame.encode() else {
        return false
    }
    return writeAllBytes(data, to: fd)
}

private func readBinaryFrame(from fd: Int32) throws -> ConjetBinaryFrame {
    let header = try readExactData(from: fd, byteCount: ConjetBinaryFrame.headerSize)
    let payloadLength = binaryFramePayloadLength(fromHeader: header)
    if payloadLength > ConjetBinaryFrame.maxPayloadBytes {
        throw ConjetError.socket("binary frame payload too large: \(payloadLength)")
    }
    let payload = payloadLength > 0 ? try readExactData(from: fd, byteCount: payloadLength) : Data()
    return try ConjetBinaryFrame.decode(header + payload)
}

private func readExactData(from fd: Int32, byteCount: Int) throws -> Data {
    var data = Data()
    data.reserveCapacity(byteCount)
    var buffer = [UInt8](repeating: 0, count: min(4096, max(1, byteCount)))
    while data.count < byteCount {
        let count = Darwin.read(fd, &buffer, min(buffer.count, byteCount - data.count))
        if count > 0 {
            data.append(buffer, count: count)
        } else if count < 0, errno == EINTR {
            continue
        } else {
            throw ConjetError.socket("binary frame read failed: \(lastErrnoForPortProxy())")
        }
    }
    return data
}

private func binaryFramePayloadLength(fromHeader header: Data) -> Int {
    guard header.count >= ConjetBinaryFrame.headerSize else {
        return 0
    }
    let start = header.index(header.startIndex, offsetBy: 16)
    let b0 = UInt32(header[start])
    let b1 = UInt32(header[header.index(start, offsetBy: 1)])
    let b2 = UInt32(header[header.index(start, offsetBy: 2)])
    let b3 = UInt32(header[header.index(start, offsetBy: 3)])
    return Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
}

private extension Data {
    func trimmedASCIIWhitespace() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, self[start].isASCIIWhitespace {
            start = index(after: start)
        }
        while end > start {
            let previous = index(before: end)
            guard self[previous].isASCIIWhitespace else { break }
            end = previous
        }
        return Data(self[start..<end])
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool {
        self == 9 || self == 10 || self == 13 || self == 32
    }
}

private func lastErrnoForPortProxy() -> String {
    String(cString: strerror(errno))
}

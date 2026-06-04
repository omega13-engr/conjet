import ConjetCore
import Darwin
import Foundation
import NIOCore
import NIOPosix

public typealias DockerPublishedPort = ConjetPublishedPortRequest

public final class DockerPublishedPortForwarder: @unchecked Sendable {
    public typealias Runner = @Sendable (String, [String], Double?) throws -> ProcessResult

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
    private let nioGroup: MultiThreadedEventLoopGroup
    private let lock = NSLock()
    private var running = false
    private var eventWatcherRunning = false
    private var eventWatcherLastEventAt: Date?
    private var eventWatcherReconnects = 0
    private var lastReconcileAt: Date?
    private var pollThread: Thread?
    private var eventThread: Thread?
    private var eventProcess: Process?
    private var tcpListeners: [ForwardKey: any PortListener] = [:]
    private var udpListeners: [ForwardKey: any PortListener] = [:]
    private var statuses: [ForwardKey: ConjetPortForwardStatus] = [:]
    private var publishedPortCache: [String: Set<DockerPublishedPort>] = [:]
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
        startEventWatcher()
        startPeriodicReconcile()
    }

    public func stop() {
        lock.lock()
        running = false
        let process = eventProcess
        eventProcess = nil
        let tcp = tcpListeners
        tcpListeners.removeAll()
        let udp = udpListeners
        udpListeners.removeAll()
        for key in statuses.keys {
            statuses[key]?.state = .stopped
            statuses[key]?.updatedAt = Date()
        }
        lock.unlock()

        process?.terminate()
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
        messages.append("network repair requested")
        statuses = statuses.filter { _, status in
            status.state != .stale && status.state != .stopped
        }
        lock.unlock()
        reconcile()
        startEventWatcher()
    }

    public func pruneCache() {
        lock.lock()
        publishedPortCache.removeAll()
        statuses = statuses.filter { _, status in
            status.state != .stale && status.state != .stopped
        }
        messages.append("network cache pruned")
        lock.unlock()
    }

    public func status() -> ConjetNetworkStatus {
        lock.lock()
        let snapshot = statuses.values.sorted {
            ($0.hostPort, $0.protocol.rawValue, $0.hostIP) < ($1.hostPort, $1.protocol.rawValue, $1.hostIP)
        }
        let activeTCP = snapshot.filter { $0.protocol == .tcp && $0.state == .listening }.count
        let activeUDP = snapshot.filter { $0.protocol == .udp && $0.state == .listening }.count
        let failed = snapshot.filter { $0.state.rawValue.hasPrefix("failed") }.count
        let conflicts = snapshot.filter { $0.state == .failedConflict }.count
        let stale = snapshot.filter { $0.state == .stale }.count
        let eventState = eventWatcherRunning ? "connected" : (running ? "reconnecting" : "stopped")
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

    func listenerPortsForTesting() -> Set<Int> {
        lock.lock()
        let ports = Set(tcpListeners.keys.map(\.hostPort)).union(Set(udpListeners.keys.map(\.hostPort)))
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

    private var tcpModeName: String {
        nativeTCPPoolAvailable ? "persistent-binary-tcp-pool" : "legacy-tcp-proxy"
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
        guard running, eventProcess == nil else {
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

    private func eventLoop() {
        while isRunning() {
            autoreleasepool {
                runDockerEventStream()
            }
            lock.lock()
            if running {
                eventWatcherRunning = false
                eventWatcherReconnects += 1
                messages.append("Docker event watcher reconnecting")
            }
            lock.unlock()
            if isRunning() {
                Thread.sleep(forTimeInterval: energyMode.eventWatcherReconnectDelaySeconds)
            }
        }
    }

    private func runDockerEventStream() {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            Thread.sleep(forTimeInterval: energyMode.eventWatcherReconnectDelaySeconds)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "docker", "--host", "unix://\(socketPath)", "events",
            "--format", "{{json .}}",
            "--filter", "type=container",
            "--filter", "event=create",
            "--filter", "event=start",
            "--filter", "event=stop",
            "--filter", "event=die",
            "--filter", "event=destroy",
            "--filter", "event=connect",
            "--filter", "event=disconnect",
            "--filter", "event=network_connect",
            "--filter", "event=network_disconnect"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        lock.lock()
        eventProcess = process
        eventWatcherRunning = true
        lock.unlock()
        do {
            try process.run()
        } catch {
            lock.lock()
            eventProcess = nil
            eventWatcherRunning = false
            messages.append("Docker event watcher failed to start: \(error)")
            lock.unlock()
            return
        }

        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while isRunning(), process.isRunning {
            let data = handle.availableData
            if data.isEmpty {
                break
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                handleEventLine(Data(line))
            }
        }

        process.terminate()
        lock.lock()
        if eventProcess === process {
            eventProcess = nil
        }
        eventWatcherRunning = false
        lock.unlock()
    }

    private func handleEventLine(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        eventWatcherLastEventAt = Date()
        lock.unlock()
        guard let event = try? JSONDecoder().decode(DockerEvent.self, from: data),
              let containerID = event.containerID,
              !containerID.isEmpty else {
            reconcile()
            return
        }

        switch event.eventName {
        case "create", "start", "connect", "network_connect":
            reconcile(containerIDs: [containerID])
        case "stop", "die", "destroy", "disconnect", "network_disconnect":
            removeForContainer(containerID)
        default:
            reconcile(containerIDs: [containerID])
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
            messages.append("port reconcile failed: \(error)")
            lock.unlock()
            return []
        }
    }

    private func discoverPublishedPorts(containerIDs: [String]) -> Set<DockerPublishedPort> {
        guard FileManager.default.fileExists(atPath: socketPath), !containerIDs.isEmpty else {
            return []
        }

        do {
            let ports = try inspectPublishedPorts(containerIDs: containerIDs, timeoutSeconds: 3)
            updatePublishedPortCache(ports, for: containerIDs)
            return ports
        } catch {
            lock.lock()
            messages.append("targeted port reconcile failed: \(error)")
            lock.unlock()
            return cachedPublishedPorts(for: Set(containerIDs))
        }
    }

    private func inspectPublishedPorts(containerIDs: [String], timeoutSeconds: Double) throws -> Set<DockerPublishedPort> {
        guard !containerIDs.isEmpty else { return [] }

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

    private func reconcileTCP(
        key: ForwardKey,
        publishedPort: DockerPublishedPort,
        bindAddress: String,
        warning: String?
    ) {
        guard capabilities.tcpProxy else {
            setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: .failedGuestCapability, error: "guest image does not advertise tcp_proxy", warning: warning))
            return
        }
        lock.lock()
        let exists = tcpListeners[key] != nil
        lock.unlock()
        guard !exists else { return }

        let listener: any PortListener
        if nativeTCPPoolAvailable {
            let target = tcpTarget(for: publishedPort)
            listener = NativeTCPPooledPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                targetHost: target.host,
                targetPort: target.port,
                connector: connector,
                statusHandler: { [weak self] metrics in
                    self?.updateMetrics(key: key, metrics: metrics)
                }
            )
        } else if useNIOProxy {
            listener = NIOTCPPublishedPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                guestHostPort: publishedPort.hostPort,
                connector: connector,
                group: nioGroup,
                statusHandler: { [weak self] metrics in
                    self?.updateMetrics(key: key, metrics: metrics)
                }
            )
        } else {
            listener = TCPPublishedPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                guestHostPort: publishedPort.hostPort,
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
                statuses[key] = status(for: publishedPort, bindAddress: bindAddress, state: .listening, warning: warning)
                messages.append("port forward created \(bindAddress):\(publishedPort.hostPort)/tcp")
                lock.unlock()
            } else {
                lock.unlock()
                listener.stop()
            }
        } catch {
            listener.stop()
            setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: .failedConflict, error: conflictMessage(bindAddress: bindAddress, port: publishedPort.hostPort, proto: .tcp, error: error), warning: warning))
        }
    }

    private func tcpTarget(for publishedPort: DockerPublishedPort) -> (host: String, port: Int) {
        if let targetIP = publishedPort.targetIP, !targetIP.isEmpty {
            return (targetIP, publishedPort.containerPort)
        }
        return ("127.0.0.1", publishedPort.hostPort)
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
        let exists = udpListeners[key] != nil
        lock.unlock()
        guard !exists else { return }

        let listener: any PortListener
        let binaryUDP = capabilities.binaryFrames && capabilities.udpBinaryFrames
        let portForwardID = binaryPortForwardID(hostPort: publishedPort.hostPort, targetPort: publishedPort.containerPort)
        if useNIOProxy {
            listener = NIOUDPPublishedPortListener(
                bindAddress: bindAddress,
                hostPort: publishedPort.hostPort,
                guestHostPort: publishedPort.hostPort,
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
                guestHostPort: publishedPort.hostPort,
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
                messages.append("port forward created \(bindAddress):\(publishedPort.hostPort)/udp")
                lock.unlock()
            } else {
                lock.unlock()
                listener.stop()
            }
        } catch {
            listener.stop()
            setStatus(for: key, status(for: publishedPort, bindAddress: bindAddress, state: .failedConflict, error: conflictMessage(bindAddress: bindAddress, port: publishedPort.hostPort, proto: .udp, error: error), warning: warning))
        }
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
            messages.append(error)
        }
        lock.unlock()
    }

    private func updateMetrics(key: ForwardKey, metrics: ProxyMetrics) {
        lock.lock()
        guard var status = statuses[key] else {
            lock.unlock()
            return
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
    }

    private func conflictMessage(bindAddress: String, port: Int, proto: ConjetPortProtocol, error: Error) -> String {
        "Port \(port)/\(proto.rawValue) cannot be published on \(bindAddress) because it is already in use or unavailable. Suggested fix: stop the process using the port or change your Compose port mapping. Detail: \(error)"
    }

    private func containerIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    public static func publishedPorts(fromDockerInspectJSON data: Data) -> Set<DockerPublishedPort> {
        guard let containers = try? JSONDecoder().decode([DockerInspectContainer].self, from: data) else {
            return []
        }

        var ports: Set<DockerPublishedPort> = []
        for container in containers where container.state?.running == true {
            guard let mappedPorts = container.networkSettings?.ports else { continue }
            let targetIP = container.networkSettings?.networks?.values.compactMap(\.ipAddress).first { !$0.isEmpty }
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
            return 90
        case .eco:
            return 180
        }
    }

    var eventWatcherReconnectDelaySeconds: TimeInterval {
        switch self {
        case .performance:
            return 1
        case .balanced:
            return 2
        case .eco:
            return 5
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
    private let guestHostPort: Int
    private let connector: any GuestConnectionConnector
    private let group: MultiThreadedEventLoopGroup
    private let statusHandler: @Sendable (ProxyMetrics) -> Void
    private let metrics = ProxyMetrics()
    private let lock = NSLock()
    private var channel: Channel?

    init(
        bindAddress: String,
        hostPort: Int,
        guestHostPort: Int,
        connector: any GuestConnectionConnector,
        group: MultiThreadedEventLoopGroup,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.guestHostPort = guestHostPort
        self.connector = connector
        self.group = group
        self.statusHandler = statusHandler
    }

    deinit { stop() }

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
            .childChannelInitializer { [connector, metrics, statusHandler, guestHostPort] channel in
                channel.pipeline.addHandler(NIOTCPProxyHandler(
                    guestHostPort: guestHostPort,
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

    private let guestHostPort: Int
    private let connector: any GuestConnectionConnector
    private let metrics: ProxyMetrics
    private let statusHandler: @Sendable (ProxyMetrics) -> Void
    private let lock = NSLock()
    private var guest: GuestConnection?
    private var guestClosed = false

    init(
        guestHostPort: Int,
        connector: any GuestConnectionConnector,
        metrics: ProxyMetrics,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.guestHostPort = guestHostPort
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
            let preface = "CONJET-TCP 127.0.0.1:\(guestHostPort)\n"
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
    private let guestHostPort: Int
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
        guestHostPort: Int,
        portForwardID: UInt32,
        useBinaryFrames: Bool,
        connector: any GuestConnectionConnector,
        group: MultiThreadedEventLoopGroup,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.guestHostPort = guestHostPort
        self.portForwardID = portForwardID
        self.requestedBinaryFrames = useBinaryFrames
        self.connector = connector
        self.group = group
        self.statusHandler = statusHandler
    }

    deinit { stop() }

    func start() throws {
        lock.lock()
        if channel != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let binaryEnabled = requestedBinaryFrames && registerBinaryUDPTarget(
            connector: connector,
            portForwardID: portForwardID,
            guestHostPort: guestHostPort
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
            .channelInitializer { [connector, metrics, statusHandler, guestHostPort, portForwardID, binaryEnabled, session] channel in
                channel.pipeline.addHandler(NIOUDPProxyHandler(
                    guestHostPort: guestHostPort,
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

    private let guestHostPort: Int
    private let portForwardID: UInt32
    private let useBinaryFrames: Bool
    private let binarySession: BinaryUDPGuestSession?
    private let connector: any GuestConnectionConnector
    private let metrics: ProxyMetrics
    private let statusHandler: @Sendable (ProxyMetrics) -> Void

    init(
        guestHostPort: Int,
        portForwardID: UInt32,
        useBinaryFrames: Bool,
        binarySession: BinaryUDPGuestSession?,
        connector: any GuestConnectionConnector,
        metrics: ProxyMetrics,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.guestHostPort = guestHostPort
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
        DispatchQueue.global(qos: .userInitiated).async { [connector, guestHostPort, useBinaryFrames, binarySession, metrics, statusHandler, weak channel = context.channel] in
            guard let channel else { return }
            do {
                let response: Data
                if useBinaryFrames, let binarySession {
                    response = try binarySession.send(payload: Data(bytes))
                } else {
                    let guest = try connector.connect()
                    disableSigpipeForPortProxy(guest.fileDescriptor)
                    defer { guest.close() }
                    let preface = "CONJET-UDP 127.0.0.1:\(guestHostPort)\n"
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
    private let targetHost: String
    private let targetPort: Int
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
        targetHost: String,
        targetPort: Int,
        connector: any GuestConnectionConnector,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.connector = connector
        self.statusHandler = statusHandler
    }

    deinit { stop() }

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
            setNonBlocking(clientFD)
            metrics.accepted()
            statusHandler(metrics)
            let thread = Thread { [weak self] in
                self?.handleClient(clientFD)
            }
            thread.name = "dev.conjet.native-tcp-client.\(hostPort)"
            thread.start()
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
        do {
            let connection = try pool.borrow()
            let result = connection.forward(
                clientFD: clientFD,
                targetHost: targetHost,
                targetPort: targetPort,
                onClientBytes: { [metrics] count in metrics.inBytes(count) },
                onTargetBytes: { [metrics] count in metrics.outBytes(count) }
            )
            if result.hadError {
                metrics.error()
            }
            pool.recycle(connection, reusable: result.reusable)
            Darwin.close(clientFD)
        } catch {
            metrics.error()
            writeHTTPBadGateway("Conjet native TCP bridge is unavailable: \(error)\n", to: clientFD)
            Darwin.close(clientFD)
        }
    }
}

private final class TCPPublishedPortListener: PortListener, @unchecked Sendable {
    private let bindAddress: String
    private let hostPort: Int
    private let guestHostPort: Int
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
        guestHostPort: Int,
        connector: any GuestConnectionConnector,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.guestHostPort = guestHostPort
        self.connector = connector
        self.statusHandler = statusHandler
    }

    deinit { stop() }

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
            let preface = "CONJET-TCP 127.0.0.1:\(guestHostPort)\n"
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
    private let guestHostPort: Int
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
        guestHostPort: Int,
        portForwardID: UInt32,
        useBinaryFrames: Bool,
        connector: any GuestConnectionConnector,
        statusHandler: @escaping @Sendable (ProxyMetrics) -> Void
    ) {
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.guestHostPort = guestHostPort
        self.portForwardID = portForwardID
        self.requestedBinaryFrames = useBinaryFrames
        self.connector = connector
        self.statusHandler = statusHandler
    }

    deinit { stop() }

    func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

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
                guestHostPort: guestHostPort
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
                let guest = try connector.connect()
                defer { guest.close() }
                let preface = "CONJET-UDP 127.0.0.1:\(guestHostPort)\n"
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
    var networkSettings: DockerInspectNetworkSettings?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case state = "State"
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

private struct DockerInspectNetwork: Decodable {
    var ipAddress: String?

    private enum CodingKeys: String, CodingKey {
        case ipAddress = "IPAddress"
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

private struct DockerEvent: Decodable {
    var status: String?
    var action: String?
    var id: String?
    var actor: DockerEventActor?

    var containerID: String? {
        if let id, !id.isEmpty { return id }
        return actor?.id
    }

    var eventName: String {
        action ?? status ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case status = "status"
        case action = "Action"
        case id = "id"
        case actor = "Actor"
    }
}

private struct DockerEventActor: Decodable {
    var id: String?

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
    }
}

private func makeTCPListener(bindAddress: String, port: Int) throws -> Int32 {
    if isIPv6BindAddress(bindAddress) {
        return try makeIPv6Listener(type: SOCK_STREAM, bindAddress: bindAddress, port: port)
    }
    return try makeIPv4Listener(type: SOCK_STREAM, bindAddress: bindAddress, port: port)
}

private func makeUDPListener(bindAddress: String, port: Int) throws -> Int32 {
    if isIPv6BindAddress(bindAddress) {
        return try makeIPv6Listener(type: SOCK_DGRAM, bindAddress: bindAddress, port: port)
    }
    return try makeIPv4Listener(type: SOCK_DGRAM, bindAddress: bindAddress, port: port)
}

private func makeIPv4Listener(type: Int32, bindAddress: String, port: Int) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, type, 0)
    guard fd >= 0 else {
        throw ConjetError.socket("socket(AF_INET) failed: \(lastErrnoForPortProxy())")
    }
    do {
        try configureListenerFD(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        let ip = bindAddress == "localhost" ? "127.0.0.1" : bindAddress
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            throw ConjetError.socket("inet_pton(\(bindAddress)) failed")
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw ConjetError.socket("bind(\(bindAddress):\(port)) failed: \(lastErrnoForPortProxy())")
                }
            }
        }
        if type == SOCK_STREAM {
            guard Darwin.listen(fd, 128) == 0 else {
                throw ConjetError.socket("listen(\(bindAddress):\(port)) failed: \(lastErrnoForPortProxy())")
            }
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func makeIPv6Listener(type: Int32, bindAddress: String, port: Int) throws -> Int32 {
    let fd = Darwin.socket(AF_INET6, type, 0)
    guard fd >= 0 else {
        throw ConjetError.socket("socket(AF_INET6) failed: \(lastErrnoForPortProxy())")
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
            throw ConjetError.socket("inet_pton(\(bindAddress)) failed")
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 else {
                    throw ConjetError.socket("bind([\(bindAddress)]:\(port)) failed: \(lastErrnoForPortProxy())")
                }
            }
        }
        if type == SOCK_STREAM {
            guard Darwin.listen(fd, 128) == 0 else {
                throw ConjetError.socket("listen([\(bindAddress)]:\(port)) failed: \(lastErrnoForPortProxy())")
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
    guestHostPort: Int
) -> Bool {
    do {
        let guest = try connector.connect()
        defer { guest.close() }
        setSocketReadTimeout(guest.fileDescriptor, timeoutSeconds: 1)
        let payload = Data("\(portForwardID) udp 127.0.0.1 \(guestHostPort)".utf8)
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

private func lastErrnoForPortProxy() -> String {
    String(cString: strerror(errno))
}

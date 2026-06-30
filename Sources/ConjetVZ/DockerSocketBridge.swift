import ConjetCore
import Darwin
import Foundation

#if canImport(Virtualization)
@preconcurrency import Virtualization
#endif

public struct GuestBridgeCapabilities: Equatable, Sendable {
    public var version: Int
    public var lazyUpstream: Bool
    public var dockerReadyCache: Bool
    public var tcpProxy: Bool
    public var udpProxy: Bool
    public var dockerEvents: Bool
    public var containerIPLookup: Bool
    public var containerTargetEvents: Bool
    public var portProbe: Bool
    public var proxyMetrics: Bool
    public var guestEcho: Bool
    public var guestMetrics: Bool
    public var binaryFrames: Bool
    public var udpBinaryFrames: Bool
    public var persistentVsock: Bool
    public var tcpBinaryFrames: Bool
    public var persistentTCPVsock: Bool
    public var tcpVsockPool: Bool
    public var guestControl: Bool
    public var bridgeEngine: String?

    public init(
        version: Int = 1,
        lazyUpstream: Bool = false,
        dockerReadyCache: Bool = false,
        tcpProxy: Bool = false,
        udpProxy: Bool = false,
        dockerEvents: Bool = false,
        containerIPLookup: Bool = false,
        containerTargetEvents: Bool = false,
        portProbe: Bool = false,
        proxyMetrics: Bool = false,
        guestEcho: Bool = false,
        guestMetrics: Bool = false,
        binaryFrames: Bool = false,
        udpBinaryFrames: Bool = false,
        persistentVsock: Bool = false,
        tcpBinaryFrames: Bool = false,
        persistentTCPVsock: Bool = false,
        tcpVsockPool: Bool = false,
        guestControl: Bool = false,
        bridgeEngine: String? = nil
    ) {
        self.version = version
        self.lazyUpstream = lazyUpstream
        self.dockerReadyCache = dockerReadyCache
        self.tcpProxy = tcpProxy
        self.udpProxy = udpProxy
        self.dockerEvents = dockerEvents
        self.containerIPLookup = containerIPLookup
        self.containerTargetEvents = containerTargetEvents
        self.portProbe = portProbe
        self.proxyMetrics = proxyMetrics
        self.guestEcho = guestEcho
        self.guestMetrics = guestMetrics
        self.binaryFrames = binaryFrames
        self.udpBinaryFrames = udpBinaryFrames
        self.persistentVsock = persistentVsock
        self.tcpBinaryFrames = tcpBinaryFrames
        self.persistentTCPVsock = persistentTCPVsock
        self.tcpVsockPool = tcpVsockPool
        self.guestControl = guestControl
        self.bridgeEngine = bridgeEngine
    }

    public var conjetNetworkCapabilities: ConjetNetworkCapabilities {
        ConjetNetworkCapabilities(
            version: version,
            tcpProxy: tcpProxy,
            udpProxy: udpProxy,
            dockerEvents: dockerEvents,
            containerIPLookup: containerIPLookup,
            containerTargetEvents: containerTargetEvents,
            portProbe: portProbe,
            proxyMetrics: proxyMetrics,
            guestEcho: guestEcho,
            guestMetrics: guestMetrics,
            binaryFrames: binaryFrames,
            udpBinaryFrames: udpBinaryFrames,
            persistentVsock: persistentVsock,
            tcpBinaryFrames: tcpBinaryFrames,
            persistentTCPVsock: persistentTCPVsock,
            tcpVsockPool: tcpVsockPool,
            bridgeEngine: bridgeEngine
        )
    }
}

public final class GuestConnection: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let closeHandler: @Sendable () -> Void
    private let closeLock = NSLock()
    private var closed = false

    public init(fileDescriptor: Int32, closeHandler: @escaping @Sendable () -> Void) {
        self.fileDescriptor = fileDescriptor
        self.closeHandler = closeHandler
    }

    public func close() {
        closeLock.lock()
        guard !closed else {
            closeLock.unlock()
            return
        }
        closed = true
        closeLock.unlock()
        closeHandler()
    }
}

public protocol GuestConnectionConnector: Sendable {
    func connect() throws -> GuestConnection
}

public struct UnavailableGuestConnectionConnector: GuestConnectionConnector {
    public var message: String

    public init(message: String = "guest Docker bridge is not connected") {
        self.message = message
    }

    public func connect() throws -> GuestConnection {
        throw ConjetError.unavailable(message)
    }
}

public struct UnixSocketGuestConnectionConnector: GuestConnectionConnector {
    private let socketPath: String
    private let timeoutSeconds: Double

    public init(socketPath: String, timeoutSeconds: Double = 5) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func connect() throws -> GuestConnection {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed: \(lastErrno())")
        }
        disableSigpipe(fd)
        do {
            Self.setTimeout(fd, seconds: timeoutSeconds)
            try withUnixSocketAddress(path: socketPath) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw ConjetError.unavailable("failed to connect to guest Unix socket \(socketPath): \(lastErrno())")
                }
            }
            return GuestConnection(fileDescriptor: fd) {
                Darwin.close(fd)
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func setTimeout(_ fd: Int32, seconds: Double) {
        let wholeSeconds = max(1, Int(seconds.rounded(.up)))
        var timeout = timeval(tv_sec: wholeSeconds, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { rebound in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, rebound, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, rebound, socklen_t(MemoryLayout<timeval>.size))
            }
        }
    }
}

public struct RetryingGuestConnectionConnector: GuestConnectionConnector {
    private let base: any GuestConnectionConnector
    private let timeoutSeconds: Double
    private let intervalSeconds: Double

    public init(
        base: any GuestConnectionConnector,
        timeoutSeconds: Double = 90,
        intervalSeconds: Double = 0.5
    ) {
        self.base = base
        self.timeoutSeconds = timeoutSeconds
        self.intervalSeconds = intervalSeconds
    }

    public func connect() throws -> GuestConnection {
        let timeout = max(0, timeoutSeconds)
        let interval = max(0.05, intervalSeconds)
        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0
        var lastError: Error?

        while true {
            attempts += 1
            do {
                return try base.connect()
            } catch {
                lastError = error
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    break
                }
                Thread.sleep(forTimeInterval: min(interval, remaining))
            }
        }

        if let lastError {
            throw ConjetError.unavailable(
                "timed out waiting for guest Docker bridge after \(attempts) attempts: \(lastError)"
            )
        }
        throw ConjetError.unavailable("timed out waiting for guest Docker bridge")
    }
}

public final class PooledGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let base: any GuestConnectionConnector
    private let capacity: Int
    private let refillDelaySeconds: Double
    private let refillQueue = DispatchQueue(label: "dev.conjet.guest-connection-pool", qos: .userInitiated)
    private let lock = NSLock()
    private var idleConnections: [GuestConnection] = []
    private var pendingConnections = 0
    private var stopped = false

    public init(
        base: any GuestConnectionConnector,
        capacity: Int = 4,
        refillDelaySeconds: Double = 0.25
    ) {
        self.base = base
        self.capacity = max(0, capacity)
        self.refillDelaySeconds = max(0.01, refillDelaySeconds)
        scheduleRefill()
    }

    deinit {
        closeIdleConnections()
    }

    public func connect() throws -> GuestConnection {
        lock.lock()
        let connection = idleConnections.popLast()
        lock.unlock()

        if let connection {
            scheduleRefill()
            return connection
        }

        return try base.connect()
    }

    public func closeIdleConnections() {
        lock.lock()
        stopped = true
        let connections = idleConnections
        idleConnections.removeAll()
        lock.unlock()

        for connection in connections {
            connection.close()
        }
    }

    func idleConnectionCountForTesting() -> Int {
        lock.lock()
        let count = idleConnections.count
        lock.unlock()
        return count
    }

    private func scheduleRefill() {
        while true {
            lock.lock()
            if stopped || idleConnections.count + pendingConnections >= capacity {
                lock.unlock()
                return
            }
            pendingConnections += 1
            lock.unlock()

            refillQueue.async { [weak self] in
                self?.makeIdleConnection()
            }
        }
    }

    private func makeIdleConnection() {
        do {
            let connection = try base.connect()
            lock.lock()
            pendingConnections -= 1
            if stopped || idleConnections.count >= capacity {
                lock.unlock()
                connection.close()
                return
            }
            idleConnections.append(connection)
            lock.unlock()
        } catch {
            lock.lock()
            pendingConnections -= 1
            let shouldRetry = !stopped
            lock.unlock()

            if shouldRetry {
                refillQueue.asyncAfter(deadline: .now() + refillDelaySeconds) { [weak self] in
                    self?.scheduleRefill()
                }
            }
        }
    }
}

enum GuestBridgeCapabilityProbe {
    static func capabilities(
        connector: any GuestConnectionConnector,
        timeoutSeconds: Double = 1
    ) -> GuestBridgeCapabilities {
        guard let connection = try? connector.connect() else {
            return GuestBridgeCapabilities()
        }
        defer { connection.close() }

        setSocketTimeout(connection.fileDescriptor, timeoutSeconds: timeoutSeconds)
        let request = "GET /conjet-bridge-capabilities HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n"
        guard writeAll(Data(request.utf8), to: connection.fileDescriptor) else {
            return GuestBridgeCapabilities()
        }
        Darwin.shutdown(connection.fileDescriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 16 * 1024 {
            let count = readIntoBuffer(connection.fileDescriptor, buffer: &buffer)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }

        guard let text = String(data: response, encoding: .utf8),
              text.contains("200 OK") else {
            return GuestBridgeCapabilities()
        }
        return GuestBridgeCapabilities(
            version: bridgeVersion(in: text),
            lazyUpstream: text.contains(#""lazy_upstream":true"#),
            dockerReadyCache: text.contains(#""docker_ready_cache":true"#),
            tcpProxy: text.contains(#""tcp_proxy":true"#),
            udpProxy: text.contains(#""udp_proxy":true"#),
            dockerEvents: text.contains(#""docker_events":true"#),
            containerIPLookup: text.contains(#""container_ip_lookup":true"#),
            containerTargetEvents: text.contains(#""container_target_events":true"#),
            portProbe: text.contains(#""port_probe":true"#),
            proxyMetrics: text.contains(#""proxy_metrics":true"#),
            guestEcho: text.contains(#""guest_echo":true"#),
            guestMetrics: text.contains(#""guest_metrics":true"#),
            binaryFrames: text.contains(#""binary_frames":true"#),
            udpBinaryFrames: text.contains(#""udp_binary_frames":true"#),
            persistentVsock: text.contains(#""persistent_vsock":true"#),
            tcpBinaryFrames: text.contains(#""tcp_binary_frames":true"#),
            persistentTCPVsock: text.contains(#""persistent_tcp_vsock":true"#),
            tcpVsockPool: text.contains(#""tcp_vsock_pool":true"#),
            guestControl: text.contains(#""guest_control":true"#),
            bridgeEngine: bridgeEngine(in: text)
        )
    }

    static func supportsPooledConnections(
        connector: any GuestConnectionConnector,
        timeoutSeconds: Double = 1
    ) -> Bool {
        capabilities(connector: connector, timeoutSeconds: timeoutSeconds).lazyUpstream
    }
}

private func bridgeVersion(in text: String) -> Int {
    if text.contains(#""version":6"#) { return 6 }
    if text.contains(#""version":5"#) { return 5 }
    if text.contains(#""version":4"#) { return 4 }
    if text.contains(#""version":3"#) { return 3 }
    if text.contains(#""version":2"#) { return 2 }
    return 1
}

private func bridgeEngine(in text: String) -> String? {
    guard let range = text.range(of: "\"bridge_engine\":\"") else { return nil }
    let rest = text[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
}

struct GuestControlMountResult: Equatable, Sendable {
    var target: String
    var tag: String
    var mounted: Bool
    var alreadyMounted: Bool
    var body: String
}

struct GuestControlClient: Sendable {
    var connector: any GuestConnectionConnector
    var timeoutSeconds: Double

    init(connector: any GuestConnectionConnector, timeoutSeconds: Double = 2) {
        self.connector = connector
        self.timeoutSeconds = timeoutSeconds
    }

    func ping() throws -> Bool {
        let response = try request(method: "GET", path: "/conjet-control/ping")
        return response.statusCode == 200
    }

    func mounts() throws -> String {
        let response = try request(method: "GET", path: "/conjet-control/mounts")
        guard response.statusCode == 200 else {
            throw ConjetError.unavailable("guest control mounts failed: HTTP \(response.statusCode) \(response.bodyText)")
        }
        return response.bodyText
    }

    @discardableResult
    func mountVirtioFS(forHostPath hostPath: String) throws -> GuestControlMountResult? {
        guard let request = Self.mountRequest(forHostPath: hostPath) else {
            return nil
        }
        return try mountVirtioFS(tag: request.tag, target: request.target)
    }

    @discardableResult
    func mountVirtioFS(tag: String, target: String) throws -> GuestControlMountResult {
        let body = Data(#"{"tag":"\#(tag)","target":"\#(target)"}"#.utf8)
        let response = try request(
            method: "POST",
            path: "/conjet-control/mount-virtiofs",
            body: body,
            contentType: "application/json"
        )
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ConjetError.unavailable(
                "guest control mount-virtiofs failed for \(target): HTTP \(response.statusCode) \(response.bodyText)"
            )
        }
        let text = response.bodyText
        return GuestControlMountResult(
            target: target,
            tag: tag,
            mounted: text.contains(#""mounted":true"#),
            alreadyMounted: text.contains(#""already_mounted":true"#),
            body: text
        )
    }

    static func mountRequest(forHostPath hostPath: String) -> (tag: String, target: String)? {
        let path = URL(fileURLWithPath: hostPath, isDirectory: true).standardized.path
        if path == "/Users" || path.hasPrefix("/Users/") {
            return ("conjethostusers", "/Users")
        }
        if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            return ("conjethostvolumes", "/Volumes")
        }
        return nil
    }

    private func request(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String = "text/plain"
    ) throws -> GuestControlHTTPResponse {
        let connection = try connector.connect()
        defer { connection.close() }
        setSocketTimeout(connection.fileDescriptor, timeoutSeconds: timeoutSeconds)

        var headers = [
            "\(method) \(path) HTTP/1.1",
            "Host: conjet",
            "Connection: close"
        ]
        if let body {
            headers.append("Content-Type: \(contentType)")
            headers.append("Content-Length: \(body.count)")
        } else {
            headers.append("Content-Length: 0")
        }
        let head = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        guard writeAll(head, to: connection.fileDescriptor) else {
            throw ConjetError.socket("failed to write guest control request")
        }
        if let body, !body.isEmpty, !writeAll(body, to: connection.fileDescriptor) {
            throw ConjetError.socket("failed to write guest control request body")
        }
        Darwin.shutdown(connection.fileDescriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 256 * 1024 {
            let count = readIntoBuffer(connection.fileDescriptor, buffer: &buffer)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return try GuestControlHTTPResponse.parse(response)
    }
}

enum GuestDockerAPIReadinessProbe {
    static func waitUntilReady(
        connector: any GuestConnectionConnector,
        timeoutSeconds: TimeInterval,
        intervalSeconds: TimeInterval = 0.25
    ) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?

        repeat {
            do {
                let response = try GuestControlClient(connector: connector, timeoutSeconds: 2)
                    .requestForDockerAPI(method: "GET", path: "/_ping")
                if response.statusCode >= 200 && response.statusCode < 300 {
                    return
                }
                lastError = ConjetError.unavailable("Docker API returned HTTP \(response.statusCode) \(response.bodyText)")
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: min(intervalSeconds, max(0, deadline.timeIntervalSinceNow)))
        } while deadline.timeIntervalSinceNow > 0

        if let lastError {
            throw ConjetError.unavailable("timed out waiting for guest Docker API readiness: \(lastError)")
        }
        throw ConjetError.unavailable("timed out waiting for guest Docker API readiness")
    }
}

private extension GuestControlClient {
    func requestForDockerAPI(method: String, path: String) throws -> GuestControlHTTPResponse {
        let connection = try connector.connect()
        defer { connection.close() }
        setSocketTimeout(connection.fileDescriptor, timeoutSeconds: timeoutSeconds)
        let request = Data("\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        guard writeAll(request, to: connection.fileDescriptor) else {
            throw ConjetError.socket("failed to write guest Docker API readiness request")
        }
        Darwin.shutdown(connection.fileDescriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 64 * 1024 {
            let count = readIntoBuffer(connection.fileDescriptor, buffer: &buffer)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return try GuestControlHTTPResponse.parse(response)
    }
}

private struct GuestControlHTTPResponse {
    var statusCode: Int
    var body: Data

    var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    static func parse(_ data: Data) throws -> GuestControlHTTPResponse {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8),
              let statusLine = headerText.split(separator: "\r\n").first else {
            throw ConjetError.decoding("invalid guest HTTP response")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw ConjetError.decoding("invalid guest HTTP status line")
        }
        return GuestControlHTTPResponse(statusCode: statusCode, body: Data(data[headerRange.upperBound...]))
    }
}

public final class DockerSocketBridge: @unchecked Sendable {
    public typealias CreatePublicationIntentHandler = @Sendable (DockerCreatePublicationIntent) -> Void
    public typealias CreatePublicationResolutionHandler = @Sendable (DockerCreatePublicationResolution) -> Void
    public typealias ContainerStartIntentHandler = @Sendable (DockerContainerStartRequest) -> Void
    public typealias ContainerStartHandler = @Sendable (DockerContainerStartRequest) -> Void
    public typealias ActivityHandler = @Sendable (DockerMemoryActivity) -> Void
    public typealias ManagedHostMountEventHandler = @Sendable (String) -> Void

    public let socketPath: String
    public let guestPort: UInt32

    private let connector: any GuestConnectionConnector
    private let createPublicationIntentHandler: CreatePublicationIntentHandler?
    private let createPublicationResolutionHandler: CreatePublicationResolutionHandler?
    private let containerStartIntentHandler: ContainerStartIntentHandler?
    private let containerStartHandler: ContainerStartHandler?
    private let activityHandler: ActivityHandler?
    private let managedHostMounts: (any DockerManagedHostMounting)?
    private let managedHostMountEventHandler: ManagedHostMountEventHandler?
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var running = false
    private var activeStreams = 0
    private var activePressureStreams = 0
    private var acceptThread: Thread?

    public init(
        socketPath: String,
        guestPort: UInt32 = ConjetRuntimePorts.dockerVsockPort,
        connector: any GuestConnectionConnector,
        createPublicationIntentHandler: CreatePublicationIntentHandler? = nil,
        createPublicationResolutionHandler: CreatePublicationResolutionHandler? = nil,
        containerStartIntentHandler: ContainerStartIntentHandler? = nil,
        containerStartHandler: ContainerStartHandler? = nil,
        activityHandler: ActivityHandler? = nil,
        managedHostMounts: (any DockerManagedHostMounting)? = nil,
        managedHostMountEventHandler: ManagedHostMountEventHandler? = nil
    ) {
        self.socketPath = socketPath
        self.guestPort = guestPort
        self.connector = connector
        self.createPublicationIntentHandler = createPublicationIntentHandler
        self.createPublicationResolutionHandler = createPublicationResolutionHandler
        self.containerStartIntentHandler = containerStartIntentHandler
        self.containerStartHandler = containerStartHandler
        self.activityHandler = activityHandler
        self.managedHostMounts = managedHostMounts
        self.managedHostMountEventHandler = managedHostMountEventHandler
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed: \(lastErrno())")
        }
        disableSigpipe(fd)

        do {
            unlink(socketPath)
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
            try withUnixSocketAddress(path: socketPath) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else {
                    throw ConjetError.socket("bind(\(socketPath)) failed: \(lastErrno())")
                }
            }
            guard Darwin.listen(fd, 1024) == 0 else {
                throw ConjetError.socket("listen() failed: \(lastErrno())")
            }

            lock.lock()
            listenerFD = fd
            running = true
            lock.unlock()

            let thread = Thread { [weak self] in
                self?.acceptLoop(listenerFD: fd)
            }
            thread.name = "dev.conjet.docker-socket-bridge"
            acceptThread = thread
            thread.start()
        } catch {
            Darwin.close(fd)
            unlink(socketPath)
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        running = false
        lock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        unlink(socketPath)
    }

    public func isRunning() -> Bool {
        lock.lock()
        let value = running
        lock.unlock()
        return value
    }

    private func acceptLoop(listenerFD: Int32) {
        while isRunning() {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            disableSigpipe(clientFD)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ clientFD: Int32) {
        do {
            guard var initialClientData = readInitialDockerClientData(from: clientFD) else {
                Darwin.close(clientFD)
                return
            }
            if managedHostMounts != nil {
                initialClientData = Self.forceConnectionCloseForInterceptableRequest(initialClientData)
            }
            let copiedBeforeRemoval = try managedHostMounts?.copyBackBeforeContainerRemoval(requestData: initialClientData) ?? 0
            if copiedBeforeRemoval > 0 {
                managedHostMountEventHandler?(
                    "managed Docker host mount copyback before removal mounts=\(copiedBeforeRemoval)"
                )
            }
            let observedCreateRequest = managedHostMounts != nil
                && Self.looksLikeContainerCreate(initialClientData)
            let managedHostMountRewrite = try managedHostMounts?.rewriteCreateRequest(initialClientData)
            if let managedHostMountRewrite {
                initialClientData = managedHostMountRewrite.requestData
                managedHostMountEventHandler?(
                    "managed Docker host mount rewrite applied mounts=\(managedHostMountRewrite.mounts.count)"
                )
            } else if observedCreateRequest {
                managedHostMountEventHandler?("managed Docker host mount rewrite skipped: no eligible host bind mount")
            }
            initialClientData = Self.addBuildCgroupParentForDockerBuildRequest(initialClientData)
            let activity = beginActivity(initialClientData: initialClientData)
            defer { endActivity(activity) }
            let createIntent = DockerCreateRequestParser.intent(from: initialClientData)
            if let intent = createIntent {
                createPublicationIntentHandler?(intent)
            }
            let startRequest = DockerStartRequestParser.startRequest(from: initialClientData)
            if let startRequest {
                containerStartIntentHandler?(startRequest)
            }
            let waitCopyBackRequestData = managedHostMounts != nil
                && DockerContainerWaitRequestParser.containerID(from: initialClientData) != nil
                ? initialClientData
                : nil
            let streamCopyBackContainerID = managedHostMounts != nil
                ? DockerContainerAttachRequestParser.containerID(from: initialClientData)
                : nil
            let guest = try connector.connect()
            pipe(
                clientFD: clientFD,
                guest: guest,
                initialClientData: initialClientData,
                activity: activity,
                createIntent: createIntent,
                startRequest: startRequest,
                waitCopyBackRequestData: waitCopyBackRequestData,
                streamCopyBackContainerID: streamCopyBackContainerID,
                managedHostMountRewrite: managedHostMountRewrite
            )
        } catch {
            let message = "Conjet guest Docker bridge on VSOCK port \(guestPort) is not ready: \(error)\n"
            writeHTTPUnavailable(message, to: clientFD)
            Darwin.close(clientFD)
        }
    }

    private func pipe(
        clientFD: Int32,
        guest: GuestConnection,
        initialClientData: Data,
        activity: DockerMemoryActivity,
        createIntent: DockerCreatePublicationIntent?,
        startRequest: DockerContainerStartRequest?,
        waitCopyBackRequestData: Data?,
        streamCopyBackContainerID: String?,
        managedHostMountRewrite: DockerManagedHostMountRewriteResult?
    ) {
        guard writeAll(initialClientData, to: guest.fileDescriptor) else {
            guest.close()
            Darwin.close(clientFD)
            return
        }

        if createIntent != nil || managedHostMountRewrite != nil {
            guard let initialGuestData = readInitialDockerCreateResponseData(from: guest.fileDescriptor) else {
                guest.close()
                Darwin.close(clientFD)
                return
            }
            if let containerID = DockerCreateResponseParser.containerID(from: initialGuestData) {
                if let managedHostMountRewrite {
                    managedHostMounts?.register(containerID: containerID, rewrite: managedHostMountRewrite)
                }
                if let createIntent {
                    createPublicationResolutionHandler?(DockerCreatePublicationResolution(
                        intent: createIntent,
                        containerID: containerID
                    ))
                }
            }
            guard writeAll(initialGuestData, to: clientFD) else {
                guest.close()
                Darwin.close(clientFD)
                return
            }
        }

        if let startRequest {
            guard let initialGuestData = readInitialDockerStartResponseData(from: guest.fileDescriptor) else {
                guest.close()
                Darwin.close(clientFD)
                return
            }
            guard writeAll(initialGuestData, to: clientFD) else {
                guest.close()
                Darwin.close(clientFD)
                return
            }
            if DockerStartResponseParser.succeeded(from: initialGuestData) {
                containerStartHandler?(startRequest)
                emitActivity(kind: .containerStarted, workload: .start, buildLike: false)
            }
        }

        if let waitCopyBackRequestData {
            guard let initialGuestData = readInitialDockerCreateResponseData(from: guest.fileDescriptor) else {
                guest.close()
                Darwin.close(clientFD)
                return
            }
            if let statusCode = Self.httpStatusCode(from: initialGuestData),
               statusCode >= 200 && statusCode < 300 {
                do {
                    let copied = try managedHostMounts?.copyBackAfterContainerWait(
                        requestData: waitCopyBackRequestData
                    ) ?? 0
                    if copied > 0 {
                        managedHostMountEventHandler?(
                            "managed Docker host mount copyback after wait mounts=\(copied)"
                        )
                    }
                } catch {
                    let message = "Conjet managed Docker host mount copyback failed: \(error)\n"
                    writeHTTPUnavailable(message, to: clientFD)
                    guest.close()
                    Darwin.close(clientFD)
                    return
                }
            }
            guard writeAll(initialGuestData, to: clientFD) else {
                guest.close()
                Darwin.close(clientFD)
                return
            }
        }

        let group = DispatchGroup()
        let phaseDetector = activity.buildLike
            ? DockerStreamPhaseDetector(workload: activity.workload)
            : nil
        let upgradedStream = Self.looksLikeDockerUpgradeStream(initialClientData)
        let longLivedResponse = upgradedStream || Self.dockerRequestHasLongLivedResponse(initialClientData)
        let pumpClientToGuest = Self.dockerRequestNeedsClientToGuestPump(initialClientData)
        if pumpClientToGuest {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                copyBytes(
                    from: clientFD,
                    to: guest.fileDescriptor,
                    idleTimeoutMilliseconds: longLivedResponse ? nil : 5_000
                )
                if !upgradedStream && !longLivedResponse {
                    Darwin.shutdown(guest.fileDescriptor, SHUT_WR)
                }
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            copyBytes(
                from: guest.fileDescriptor,
                to: clientFD,
                onChunk: { [weak self] bytes in
                    guard let self,
                          let phaseDetector,
                          phaseDetector.feed(bytes: bytes) > 0 else {
                        return
                    }
                    self.emitActivity(
                        kind: .streamPhaseFinished,
                        workload: activity.workload,
                        buildLike: activity.buildLike
                    )
                },
                idleTimeoutMilliseconds: longLivedResponse ? nil : 5_000
            )
            Darwin.shutdown(clientFD, SHUT_WR)
            if upgradedStream {
                Darwin.shutdown(clientFD, SHUT_RDWR)
                Darwin.shutdown(guest.fileDescriptor, SHUT_RDWR)
            }
            group.leave()
        }
        group.wait()
        if let streamCopyBackContainerID {
            do {
                let copied = try managedHostMounts?.copyBack(containerID: streamCopyBackContainerID) ?? 0
                if copied > 0 {
                    managedHostMountEventHandler?(
                        "managed Docker host mount copyback after stream mounts=\(copied)"
                    )
                }
            } catch {
                managedHostMountEventHandler?(
                    "managed Docker host mount copyback after stream failed: \(error)"
                )
            }
        }
        guest.close()
        Darwin.close(clientFD)
    }

    private func beginActivity(initialClientData: Data) -> DockerMemoryActivity {
        let workload = Self.classifyWorkload(initialClientData)
        let pressureStream = workload.countsAsMemoryPressureStream
        lock.lock()
        activeStreams += 1
        if pressureStream {
            activePressureStreams += 1
        }
        let count = activeStreams
        let pressureCount = activePressureStreams
        lock.unlock()
        let activity = DockerMemoryActivity(
            kind: .streamOpened,
            workload: workload,
            activeStreams: count,
            pressureStreams: pressureCount,
            buildLike: workload.isBuildLike
        )
        activityHandler?(activity)
        if workload.isBuildLike {
            activityHandler?(DockerMemoryActivity(
                kind: .workloadStarted,
                workload: workload,
                activeStreams: count,
                pressureStreams: pressureCount,
                buildLike: true
            ))
        }
        return activity
    }

    private func endActivity(_ activity: DockerMemoryActivity) {
        lock.lock()
        activeStreams = max(0, activeStreams - 1)
        if activity.workload.countsAsMemoryPressureStream {
            activePressureStreams = max(0, activePressureStreams - 1)
        }
        let count = activeStreams
        let pressureCount = activePressureStreams
        lock.unlock()
        activityHandler?(DockerMemoryActivity(
            kind: .streamClosed,
            workload: activity.workload,
            activeStreams: count,
            pressureStreams: pressureCount,
            buildLike: activity.buildLike
        ))
        if activity.buildLike {
            activityHandler?(DockerMemoryActivity(
                kind: .workloadFinished,
                workload: activity.workload,
                activeStreams: count,
                pressureStreams: pressureCount,
                buildLike: true
            ))
        }
        if activity.workload == .stop {
            activityHandler?(DockerMemoryActivity(
                kind: .containerStopped,
                workload: .stop,
                activeStreams: count,
                pressureStreams: pressureCount,
                buildLike: false
            ))
        }
    }

    private func emitActivity(
        kind: DockerMemoryActivity.Kind,
        workload: DockerMemoryActivity.Workload,
        buildLike: Bool
    ) {
        lock.lock()
        let count = activeStreams
        let pressureCount = activePressureStreams
        lock.unlock()
        activityHandler?(DockerMemoryActivity(
            kind: kind,
            workload: workload,
            activeStreams: count,
            pressureStreams: pressureCount,
            buildLike: buildLike
        ))
    }

    private static func classifyWorkload(_ data: Data) -> DockerMemoryActivity.Workload {
        let prefix = data.prefix(2048)
        guard let text = String(data: prefix, encoding: .utf8) else {
            return .unknown
        }
        if text.contains(" /build") || text.contains("/build?") || text.contains("/session") {
            return .build
        }
        if text.contains("/images/create") {
            return .pull
        }
        if text.contains("/containers/create") {
            return .run
        }
        if text.contains("/start") {
            return .start
        }
        if text.contains("/stop") || text.contains("/kill") || text.contains("/wait") || text.contains("/delete") {
            return .stop
        }
        if text.contains("/events") {
            return .events
        }
        return .unknown
    }

    private static func looksLikeContainerCreate(_ data: Data) -> Bool {
        let prefix = data.prefix(4096)
        guard let text = String(data: prefix, encoding: .utf8) else {
            return false
        }
        return text.contains("/containers/create")
    }

    private static func looksLikeDockerUpgradeStream(_ data: Data) -> Bool {
        let prefix = data.prefix(4096)
        guard let text = String(data: prefix, encoding: .utf8) else {
            return false
        }
        return text.contains(" /grpc ") ||
            text.localizedCaseInsensitiveContains("Connection: Upgrade") ||
            text.localizedCaseInsensitiveContains("Upgrade: h2c")
    }

    static func dockerRequestNeedsClientToGuestPump(_ data: Data) -> Bool {
        if looksLikeDockerUpgradeStream(data) {
            return true
        }
        guard let request = DockerHTTPRequestEnvelope(data: data) else {
            return true
        }
        if request.isStreamingHTTP {
            return true
        }
        return !request.bodyIsComplete
    }

    static func dockerRequestHasLongLivedResponse(_ data: Data) -> Bool {
        if looksLikeDockerUpgradeStream(data) {
            return true
        }
        return DockerHTTPRequestEnvelope(data: data)?.isStreamingHTTP == true
    }

    static func forceConnectionCloseForInterceptableRequest(_ data: Data) -> Data {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return data
        }
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return data }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2,
              isInterceptableDockerRequestPath(requestParts[1], headers: lines.dropFirst()) else {
            return data
        }

        lines.removeAll { line in
            guard let separator = line.firstIndex(of: ":") else { return false }
            return line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Connection") == .orderedSame
        }
        lines.append("Connection: close")
        var rewritten = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        rewritten.append(data[headerRange.upperBound...])
        return rewritten
    }

    static func addBuildCgroupParentForDockerBuildRequest(_ data: Data) -> Data {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return data
        }

        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return data }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0] == "POST",
              isDockerBuildRequestPath(parts[1]),
              !dockerRequestPathHasQueryParameter(parts[1], name: "cgroupparent") else {
            return data
        }

        let separator = parts[1].contains("?") ? "&" : "?"
        lines[0] = "\(parts[0]) \(parts[1])\(separator)cgroupparent=/conjet.slice/conjet-build.slice \(parts[2])"
        var rewritten = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        rewritten.append(data[headerRange.upperBound...])
        return rewritten
    }

    private static func isDockerBuildRequestPath(_ path: String) -> Bool {
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        if pathOnly == "/build" {
            return true
        }
        guard pathOnly.hasPrefix("/v"),
              pathOnly.hasSuffix("/build") else {
            return false
        }
        let version = pathOnly.dropFirst(2).dropLast("/build".count)
        return !version.isEmpty && version.allSatisfy { character in
            character.isNumber || character == "."
        }
    }

    private static func dockerRequestPathHasQueryParameter(_ path: String, name: String) -> Bool {
        guard let queryStart = path.firstIndex(of: "?") else {
            return false
        }
        let query = path[path.index(after: queryStart)...]
        return query.split(separator: "&", omittingEmptySubsequences: false).contains { item in
            item.lowercased().hasPrefix("\(name.lowercased())=")
        }
    }

    private static func isInterceptableDockerRequestPath<S: Sequence>(
        _ path: String,
        headers: S
    ) -> Bool where S.Element == String {
        let lowercasedPath = path.lowercased()
        if dockerRequestPathHasLongLivedResponse(lowercasedPath)
            || lowercasedPath.contains("/attach")
            || lowercasedPath.contains("/exec/") {
            return false
        }
        for header in headers {
            guard let separator = header.firstIndex(of: ":") else { continue }
            let key = header[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = header[header.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.caseInsensitiveCompare("Connection") == .orderedSame,
               value.lowercased().contains("upgrade") {
                return false
            }
            if key.caseInsensitiveCompare("Upgrade") == .orderedSame {
                return false
            }
        }
        return true
    }

    private static func dockerRequestPathHasLongLivedResponse(_ lowercasedPath: String) -> Bool {
        if lowercasedPath.contains("/events") {
            return true
        }
        if lowercasedPath.contains("/logs"),
           dockerRequestPathHasTruthyQueryParameter(lowercasedPath, name: "follow") {
            return true
        }
        if lowercasedPath.contains("/stats"),
           !dockerRequestPathHasFalseyQueryParameter(lowercasedPath, name: "stream") {
            return true
        }
        return false
    }

    private static func dockerRequestPathHasTruthyQueryParameter(_ path: String, name: String) -> Bool {
        guard let value = dockerRequestPathQueryValue(path, name: name) else {
            return false
        }
        return value == "1" || value == "true"
    }

    private static func dockerRequestPathHasFalseyQueryParameter(_ path: String, name: String) -> Bool {
        guard let value = dockerRequestPathQueryValue(path, name: name) else {
            return false
        }
        return value == "0" || value == "false"
    }

    private static func dockerRequestPathQueryValue(_ path: String, name: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else {
            return nil
        }
        let query = path[path.index(after: queryStart)...]
        for item in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map(String.init) == name else { continue }
            return parts.count > 1 ? String(parts[1]) : ""
        }
        return nil
    }

    private static func httpStatusCode(from data: Data) -> Int? {
        guard let lineEnd = data.range(of: Data([13, 10]))?.lowerBound,
              let statusLine = String(data: data[..<lineEnd], encoding: .utf8) else {
            return nil
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private func readInitialDockerStartResponseData(from fd: Int32) -> Data? {
        let maxBufferedBytes = 1024 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        guard appendRead(from: fd, into: &data, buffer: &buffer) else {
            return data.isEmpty ? nil : data
        }

        while DockerStartResponseParser.headerBytesMissing(in: data), data.count < maxBufferedBytes {
            guard appendRead(from: fd, into: &data, buffer: &buffer) else {
                return data
            }
        }

        return data
    }

    private func readInitialDockerClientData(from fd: Int32) -> Data? {
        let maxBufferedBytes = 1024 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        guard appendRead(from: fd, into: &data, buffer: &buffer) else {
            return data.isEmpty ? nil : data
        }

        while DockerCreateRequestParser.headerBytesMissing(in: data), data.count < maxBufferedBytes {
            guard appendRead(from: fd, into: &data, buffer: &buffer) else {
                return data
            }
        }

        while let missing = DockerCreateRequestParser.additionalBodyBytesNeeded(in: data),
              missing > 0,
              data.count < maxBufferedBytes {
            guard appendRead(from: fd, into: &data, buffer: &buffer, maxBytes: min(missing, buffer.count)) else {
                return data
            }
        }

        return data
    }

    private func readInitialDockerCreateResponseData(from fd: Int32) -> Data? {
        let maxBufferedBytes = 1024 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        guard appendRead(from: fd, into: &data, buffer: &buffer) else {
            return data.isEmpty ? nil : data
        }

        while DockerCreateResponseParser.headerBytesMissing(in: data), data.count < maxBufferedBytes {
            guard appendRead(from: fd, into: &data, buffer: &buffer) else {
                return data
            }
        }

        while let missing = DockerCreateResponseParser.additionalBodyBytesNeeded(in: data),
              missing > 0,
              data.count < maxBufferedBytes {
            guard appendRead(from: fd, into: &data, buffer: &buffer, maxBytes: min(missing, buffer.count)) else {
                return data
            }
        }

        return data
    }

    private func appendRead(
        from fd: Int32,
        into data: inout Data,
        buffer: inout [UInt8],
        maxBytes: Int? = nil
    ) -> Bool {
        let readLimit = max(1, min(maxBytes ?? buffer.count, buffer.count))
        while true {
            let count = readIntoBuffer(fd, buffer: &buffer, maxBytes: readLimit)
            if count > 0 {
                data.append(buffer, count: count)
                return true
            }
            if count < 0 {
                let readErrno = errno
                if readErrno == EINTR {
                    continue
                }
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                    if waitForReadableFD(fd, timeoutMilliseconds: 5_000) {
                        continue
                    }
                }
            }
            return false
        }
    }

    private func writeHTTPUnavailable(_ message: String, to fd: Int32) {
        let response = """
        HTTP/1.1 503 Service Unavailable\r
        Content-Type: text/plain; charset=utf-8\r
        Connection: close\r
        Content-Length: \(Data(message.utf8).count)\r
        \r
        \(message)
        """
        _ = response.withCString { pointer in
            Darwin.write(fd, pointer, strlen(pointer))
        }
    }
}

private struct DockerHTTPRequestEnvelope {
    private static let headerDelimiter = Data([13, 10, 13, 10])

    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init?(data: Data) {
        guard let headerRange = data.range(of: Self.headerDelimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        self.method = requestParts[0]
        self.path = requestParts[1]
        self.headers = headers
        self.body = Data(data[headerRange.upperBound...])
    }

    var bodyIsComplete: Bool {
        if isChunked {
            return Self.decodeChunkedBody(body) != nil
        }
        return body.count >= contentLength
    }

    var isStreamingHTTP: Bool {
        let lowercasedPath = path.lowercased()
        if lowercasedPath.contains("/events") {
            return true
        }
        if lowercasedPath.contains("/stats")
            && !lowercasedPath.contains("stream=0")
            && !lowercasedPath.contains("stream=false") {
            return true
        }
        if lowercasedPath.contains("/logs")
            && (lowercasedPath.contains("follow=1") || lowercasedPath.contains("follow=true")) {
            return true
        }
        return false
    }

    private var contentLength: Int {
        Int(headers["content-length"] ?? "") ?? 0
    }

    private var isChunked: Bool {
        (headers["transfer-encoding"] ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("chunked")
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        var index = data.startIndex
        var decoded = Data()
        while true {
            guard let lineEnd = data[index...].range(of: Data([13, 10]))?.lowerBound else {
                return nil
            }
            let lineData = data[index..<lineEnd]
            guard let line = String(data: lineData, encoding: .utf8) else {
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
                guard data[index...].range(of: Data([13, 10])) != nil else {
                    return nil
                }
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

private final class DockerStreamPhaseDetector: @unchecked Sendable {
    private let workload: DockerMemoryActivity.Workload
    private let lock = NSLock()
    private var pending = Data()

    init(workload: DockerMemoryActivity.Workload) {
        self.workload = workload
    }

    func feed(bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard !bytes.isEmpty else {
            return 0
        }
        lock.lock()
        pending.append(contentsOf: bytes)
        if pending.count > 64 * 1024 {
            pending.removeFirst(pending.count - 64 * 1024)
        }
        var phases = 0
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if Self.isPhaseCompletionLine(line, workload: workload) {
                phases += 1
            }
        }
        lock.unlock()
        return phases
    }

    private static func isPhaseCompletionLine(
        _ line: Data.SubSequence,
        workload: DockerMemoryActivity.Workload
    ) -> Bool {
        guard let text = String(data: Data(line.prefix(4096)), encoding: .utf8) else {
            return false
        }
        switch workload {
        case .build:
            return text.contains(" DONE ")
                || text.contains(" DONE\\n")
                || text.contains(" CACHED")
                || text.contains("\"stream\":\"Successfully built")
                || text.contains("\"aux\":{\"ID\":\"sha256:")
        case .pull:
            return text.contains("\"status\":\"Pull complete\"")
                || text.contains("\"status\":\"Download complete\"")
                || text.contains("\"status\":\"Already exists\"")
                || text.contains("Pull complete")
                || text.contains("Download complete")
                || text.contains("Already exists")
        case .run:
            return text.contains("\"status\":\"Pull complete\"")
                || text.contains("\"status\":\"Download complete\"")
                || text.contains("\"stream\":\"")
        case .unknown, .start, .stop, .events:
            return false
        }
    }
}

private func disableSigpipe(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func setSocketTimeout(_ fd: Int32, timeoutSeconds: Double) {
    let seconds = max(0, timeoutSeconds)
    var timeout = timeval(
        tv_sec: Int(seconds),
        tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000)
    )
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return true
        }
        var written = 0
        while written < data.count {
            let count = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
            if count > 0 {
                written += count
            } else if count < 0 {
                let writeErrno = errno
                if writeErrno == EINTR {
                    continue
                }
                if writeErrno == EAGAIN || writeErrno == EWOULDBLOCK {
                    if waitForWritableFD(fd, timeoutMilliseconds: 5_000) {
                        continue
                    }
                }
                return false
            } else {
                return false
            }
        }
        return true
    }
}

#if canImport(Virtualization)
public final class VZGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let socketDevice: VZVirtioSocketDevice
    private let queue: DispatchQueue
    private let port: UInt32
    private let timeoutSeconds: Double

    public init(
        socketDevice: VZVirtioSocketDevice,
        queue: DispatchQueue,
        port: UInt32 = ConjetRuntimePorts.dockerVsockPort,
        timeoutSeconds: Double = 5
    ) {
        self.socketDevice = socketDevice
        self.queue = queue
        self.port = port
        self.timeoutSeconds = timeoutSeconds
    }

    public func connect() throws -> GuestConnection {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = VZConnectionResultBox()
        queue.async {
            self.socketDevice.connect(toPort: self.port) { result in
                resultBox.set(result)
                semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            throw ConjetError.unavailable("timed out connecting to guest VSOCK port \(port)")
        }

        switch resultBox.get() {
        case .success(let connection):
            let holder = VZConnectionHolder(connection)
            return GuestConnection(fileDescriptor: connection.fileDescriptor) {
                holder.close()
            }
        case .failure(let error):
            throw ConjetError.unavailable("failed to connect to guest VSOCK port \(port): \(error)")
        case .none:
            throw ConjetError.unavailable("guest VSOCK connection completed without a result")
        }
    }
}

private final class VZConnectionResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<VZVirtioSocketConnection, Error>?

    func set(_ result: Result<VZVirtioSocketConnection, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<VZVirtioSocketConnection, Error>? {
        lock.lock()
        let value = result
        lock.unlock()
        return value
    }
}

private final class VZConnectionHolder: @unchecked Sendable {
    private let connection: VZVirtioSocketConnection

    init(_ connection: VZVirtioSocketConnection) {
        self.connection = connection
    }

    func close() {
        connection.close()
    }
}
#endif

private func copyBytes(
    from sourceFD: Int32,
    to destinationFD: Int32,
    onChunk: ((UnsafeBufferPointer<UInt8>) -> Void)? = nil,
    idleTimeoutMilliseconds: Int32? = 5_000
) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let readCount = readIntoBuffer(sourceFD, buffer: &buffer)
        if readCount > 0 {
            if let onChunk {
                buffer.withUnsafeBufferPointer { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return
                    }
                    onChunk(UnsafeBufferPointer(start: baseAddress, count: readCount))
                }
            }
            var written = 0
            while written < readCount {
                let writeCount = Darwin.write(destinationFD, buffer.withUnsafeBytes { rawBuffer in
                    rawBuffer.baseAddress!.advanced(by: written)
                }, readCount - written)
                if writeCount > 0 {
                    written += writeCount
                } else if writeCount < 0, errno == EINTR {
                    continue
                } else if writeCount < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    if !waitForWritableFD(destinationFD, timeoutMilliseconds: 5_000) {
                        return
                    }
                } else {
                    return
                }
            }
        } else if readCount < 0 {
            let readErrno = errno
            if readErrno == EINTR {
                continue
            }
            if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                if let idleTimeoutMilliseconds {
                    if waitForReadableFD(sourceFD, timeoutMilliseconds: idleTimeoutMilliseconds) {
                        continue
                    }
                    return
                }
                if waitForReadableFD(sourceFD, timeoutMilliseconds: 1_000) {
                    continue
                }
                continue
            }
            return
        } else {
            return
        }
    }
}

private func readIntoBuffer(_ fd: Int32, buffer: inout [UInt8], maxBytes: Int? = nil) -> Int {
    let readLimit = max(1, min(maxBytes ?? buffer.count, buffer.count))
    return buffer.withUnsafeMutableBytes { rawBuffer -> Int in
        guard let baseAddress = rawBuffer.baseAddress else {
            return -1
        }
        return Darwin.read(fd, baseAddress, readLimit)
    }
}

private func waitForWritableFD(_ fd: Int32, timeoutMilliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    while true {
        let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
        if result > 0 {
            return (descriptor.revents & Int16(POLLOUT | POLLHUP | POLLERR | POLLNVAL)) != 0
        }
        if result < 0, errno == EINTR {
            continue
        }
        return false
    }
}

private func waitForReadableFD(_ fd: Int32, timeoutMilliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
        if result > 0 {
            return (descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0
        }
        if result < 0, errno == EINTR {
            continue
        }
        return false
    }
}

private func withUnixSocketAddress<Result>(
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

private func lastErrno() -> String {
    String(cString: strerror(errno))
}

import ConjetCore
import Darwin
import Foundation

#if canImport(Virtualization)
@preconcurrency import Virtualization
#endif

public enum ConjetRuntimePorts {
    public static let dockerVsockPort: UInt32 = 2375
}

public final class GuestConnection: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let closeHandler: @Sendable () -> Void

    public init(fileDescriptor: Int32, closeHandler: @escaping @Sendable () -> Void) {
        self.fileDescriptor = fileDescriptor
        self.closeHandler = closeHandler
    }

    public func close() {
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
    static func supportsPooledConnections(
        connector: any GuestConnectionConnector,
        timeoutSeconds: Double = 1
    ) -> Bool {
        guard let connection = try? connector.connect() else {
            return false
        }
        defer { connection.close() }

        setSocketTimeout(connection.fileDescriptor, timeoutSeconds: timeoutSeconds)
        let request = "GET /conjet-bridge-capabilities HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n"
        guard writeAll(Data(request.utf8), to: connection.fileDescriptor) else {
            return false
        }
        Darwin.shutdown(connection.fileDescriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 16 * 1024 {
            let count = Darwin.read(connection.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }

        guard let text = String(data: response, encoding: .utf8) else {
            return false
        }
        return text.contains("200 OK") && text.contains(#""lazy_upstream":true"#)
    }
}

public final class DockerSocketBridge: @unchecked Sendable {
    public let socketPath: String
    public let guestPort: UInt32

    private let connector: any GuestConnectionConnector
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var running = false
    private var acceptThread: Thread?

    public init(
        socketPath: String,
        guestPort: UInt32 = ConjetRuntimePorts.dockerVsockPort,
        connector: any GuestConnectionConnector
    ) {
        self.socketPath = socketPath
        self.guestPort = guestPort
        self.connector = connector
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
            guard Darwin.listen(fd, 64) == 0 else {
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
            let guest = try connector.connect()
            pipe(clientFD: clientFD, guest: guest)
        } catch {
            let message = "Conjet guest Docker bridge on VSOCK port \(guestPort) is not ready: \(error)\n"
            writeHTTPUnavailable(message, to: clientFD)
            Darwin.close(clientFD)
        }
    }

    private func pipe(clientFD: Int32, guest: GuestConnection) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            copyBytes(from: clientFD, to: guest.fileDescriptor)
            Darwin.shutdown(guest.fileDescriptor, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            copyBytes(from: guest.fileDescriptor, to: clientFD)
            Darwin.shutdown(clientFD, SHUT_WR)
            group.leave()
        }
        group.wait()
        guest.close()
        Darwin.close(clientFD)
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
            } else if count < 0, errno == EINTR {
                continue
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

private func copyBytes(from sourceFD: Int32, to destinationFD: Int32) {
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
                } else if writeCount < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        } else if readCount < 0, errno == EINTR {
            continue
        } else {
            return
        }
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

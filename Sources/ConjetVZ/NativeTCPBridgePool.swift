import ConjetCore
import Darwin
import Foundation

struct NativeTCPBridgeForwardResult: Sendable {
    var reusable: Bool
    var hadError: Bool
}

final class NativeTCPBridgePool: @unchecked Sendable {
    private let connector: any GuestConnectionConnector
    private let maxConnections: Int
    private let minimumIdleConnections: Int
    private let refillDelaySeconds: TimeInterval
    private let condition = NSCondition()
    private let refillQueue = DispatchQueue(label: "dev.conjet.native-tcp-vsock-pool", qos: .userInitiated)
    private var idleConnections: [NativeTCPBridgeConnection] = []
    private var totalConnections = 0
    private var stopped = false

    init(
        connector: any GuestConnectionConnector,
        maxConnections: Int = 160,
        minimumIdleConnections: Int = 64,
        refillDelaySeconds: TimeInterval = 0.05
    ) {
        self.connector = connector
        self.maxConnections = max(1, maxConnections)
        self.minimumIdleConnections = max(0, min(minimumIdleConnections, maxConnections))
        self.refillDelaySeconds = max(0.01, refillDelaySeconds)
        scheduleRefill()
    }

    deinit {
        close()
    }

    func borrow(timeoutSeconds: TimeInterval = 2) throws -> NativeTCPBridgeConnection {
        let deadline = Date().addingTimeInterval(max(0.05, timeoutSeconds))
        while true {
            condition.lock()
            if stopped {
                condition.unlock()
                throw ConjetError.unavailable("native TCP bridge pool is stopped")
            }
            if let connection = idleConnections.popLast() {
                condition.unlock()
                scheduleRefill()
                return connection
            }
            if totalConnections < maxConnections {
                totalConnections += 1
                condition.unlock()
                do {
                    return try makeConnection()
                } catch {
                    condition.lock()
                    totalConnections -= 1
                    condition.broadcast()
                    condition.unlock()
                    scheduleRefill()
                    throw error
                }
            }
            let shouldContinue = condition.wait(until: deadline)
            condition.unlock()
            if !shouldContinue || Date() >= deadline {
                throw ConjetError.unavailable("timed out waiting for a native TCP bridge pool connection")
            }
        }
    }

    func recycle(_ connection: NativeTCPBridgeConnection, reusable: Bool) {
        condition.lock()
        if stopped || !reusable {
            totalConnections -= 1
            condition.broadcast()
            condition.unlock()
            connection.close()
            scheduleRefill()
            return
        }
        idleConnections.append(connection)
        condition.broadcast()
        condition.unlock()
        scheduleRefill()
    }

    func close() {
        condition.lock()
        stopped = true
        let idle = idleConnections
        idleConnections.removeAll()
        totalConnections -= idle.count
        condition.broadcast()
        condition.unlock()

        for connection in idle {
            connection.close()
        }
    }

    func idleConnectionCountForTesting() -> Int {
        condition.lock()
        let count = idleConnections.count
        condition.unlock()
        return count
    }

    private func scheduleRefill() {
        while true {
            condition.lock()
            if stopped || totalConnections >= minimumIdleConnections || totalConnections >= maxConnections {
                condition.unlock()
                return
            }
            totalConnections += 1
            condition.unlock()

            refillQueue.async { [weak self] in
                self?.makeIdleConnection()
            }
        }
    }

    private func makeIdleConnection() {
        do {
            let connection = try makeConnection()
            condition.lock()
            if stopped || idleConnections.count >= minimumIdleConnections {
                totalConnections -= 1
                condition.broadcast()
                condition.unlock()
                connection.close()
                return
            }
            idleConnections.append(connection)
            condition.broadcast()
            condition.unlock()
        } catch {
            condition.lock()
            totalConnections -= 1
            let shouldRetry = !stopped
            condition.broadcast()
            condition.unlock()

            if shouldRetry {
                refillQueue.asyncAfter(deadline: .now() + refillDelaySeconds) { [weak self] in
                    self?.scheduleRefill()
                }
            }
        }
    }

    private func makeConnection() throws -> NativeTCPBridgeConnection {
        let guest = try connector.connect()
        nativeTCPDisableSigpipe(guest.fileDescriptor)
        return NativeTCPBridgeConnection(guest: guest)
    }
}

final class NativeTCPBridgeConnection: @unchecked Sendable {
    private let guest: GuestConnection
    private let lock = NSLock()
    private var nextStreamID: UInt32 = 1
    private var closed = false

    init(guest: GuestConnection) {
        self.guest = guest
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        guest.close()
    }

    func forward(
        clientFD: Int32,
        targetHost: String,
        targetPort: Int,
        onClientBytes: @escaping @Sendable (Int) -> Void,
        onTargetBytes: @escaping @Sendable (Int) -> Void
    ) -> NativeTCPBridgeForwardResult {
        let streamID = allocateStreamID()
        var reusable = true
        var hadError = false
        let state = NativeTCPForwardState()

        do {
            let target = try ConjetTCPFrameTarget(host: targetHost, port: targetPort).encode()
            try writeFrame(ConjetBinaryFrame(type: .tcpOpen, streamID: streamID, payload: target))
        } catch {
            return NativeTCPBridgeForwardResult(reusable: false, hadError: true)
        }

        let group = DispatchGroup()
        group.enter()
        let clientReader = Thread { [weak self, state] in
            defer { group.leave() }
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !state.isFinished {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    onClientBytes(count)
                    do {
                        let payload = Data(buffer.prefix(count))
                        try self.writeFrame(ConjetBinaryFrame(type: .tcpData, streamID: streamID, payload: payload))
                    } catch {
                        state.markError()
                        Darwin.shutdown(clientFD, SHUT_RDWR)
                        return
                    }
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.0005)
                    continue
                } else {
                    do {
                        try self.writeFrame(ConjetBinaryFrame(type: .tcpHalfClose, streamID: streamID))
                    } catch {
                        state.markError()
                    }
                    return
                }
            }
        }
        clientReader.name = "dev.conjet.native-tcp-client-reader"
        clientReader.start()

        group.enter()
        let bridgeReader = Thread { [weak self, state] in
            defer { group.leave() }
            guard let self else { return }
            while !state.isFinished {
                do {
                    let frame = try self.readFrame()
                    guard frame.streamID == streamID else {
                        continue
                    }
                    switch frame.type {
                    case .tcpOpen:
                        continue
                    case .tcpData:
                        if !nativeTCPWriteAll(frame.payload, to: clientFD) {
                            state.markError()
                            Darwin.shutdown(clientFD, SHUT_RDWR)
                            return
                        }
                        onTargetBytes(frame.payload.count)
                    case .tcpHalfClose:
                        Darwin.shutdown(clientFD, SHUT_WR)
                    case .tcpClose:
                        state.markFinished()
                        Darwin.shutdown(clientFD, SHUT_RDWR)
                        return
                    case .tcpError:
                        if !state.hasTargetBytes {
                            nativeTCPWriteHTTPBadGateway(frame.payload, to: clientFD)
                        }
                        state.markError()
                        Darwin.shutdown(clientFD, SHUT_RDWR)
                        return
                    default:
                        continue
                    }
                    if frame.type == .tcpData {
                        state.addTargetBytes(frame.payload.count)
                    }
                } catch {
                    state.markError()
                    Darwin.shutdown(clientFD, SHUT_RDWR)
                    return
                }
            }
        }
        bridgeReader.name = "dev.conjet.native-tcp-bridge-reader"
        bridgeReader.start()

        group.wait()
        if state.hasError {
            reusable = false
            hadError = true
        }
        return NativeTCPBridgeForwardResult(reusable: reusable, hadError: hadError)
    }

    private func allocateStreamID() -> UInt32 {
        lock.lock()
        let streamID = nextStreamID
        nextStreamID = nextStreamID == UInt32.max ? 1 : nextStreamID + 1
        lock.unlock()
        return streamID
    }

    private func writeFrame(_ frame: ConjetBinaryFrame) throws {
        guard !isClosed else {
            throw ConjetError.socket("native TCP bridge connection is closed")
        }
        let encoded = try frame.encode()
        guard nativeTCPWriteAll(encoded, to: guest.fileDescriptor) else {
            close()
            throw ConjetError.socket("failed to write native TCP frame")
        }
    }

    private func readFrame() throws -> ConjetBinaryFrame {
        guard !isClosed else {
            throw ConjetError.socket("native TCP bridge connection is closed")
        }
        let header = try nativeTCPReadExact(from: guest.fileDescriptor, byteCount: ConjetBinaryFrame.headerSize)
        let payloadLength = nativeTCPPayloadLength(fromHeader: header)
        if payloadLength > ConjetBinaryFrame.maxPayloadBytes {
            throw ConjetError.socket("native TCP frame payload too large: \(payloadLength)")
        }
        let payload = payloadLength > 0 ? try nativeTCPReadExact(from: guest.fileDescriptor, byteCount: payloadLength) : Data()
        return try ConjetBinaryFrame.decode(header + payload)
    }

    private var isClosed: Bool {
        lock.lock()
        let value = closed
        lock.unlock()
        return value
    }
}

private final class NativeTCPForwardState: @unchecked Sendable {
    private let lock = NSLock()
    private var hadError = false
    private var finished = false
    private var bytesFromTarget = 0

    var isFinished: Bool {
        lock.lock()
        let value = finished
        lock.unlock()
        return value
    }

    var hasError: Bool {
        lock.lock()
        let value = hadError
        lock.unlock()
        return value
    }

    var hasTargetBytes: Bool {
        lock.lock()
        let value = bytesFromTarget > 0
        lock.unlock()
        return value
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func markError() {
        lock.lock()
        hadError = true
        finished = true
        lock.unlock()
    }

    func addTargetBytes(_ count: Int) {
        lock.lock()
        bytesFromTarget += count
        lock.unlock()
    }
}

private func nativeTCPWriteAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
        return nativeTCPWriteAll(baseAddress, count: data.count, to: fd)
    }
}

private func nativeTCPWriteAll(_ pointer: UnsafeRawPointer, count: Int, to fd: Int32) -> Bool {
    var written = 0
    while written < count {
        let result = Darwin.write(fd, pointer.advanced(by: written), count - written)
        if result > 0 {
            written += result
        } else if result < 0, errno == EINTR {
            continue
        } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            Thread.sleep(forTimeInterval: 0.0005)
            continue
        } else {
            return false
        }
    }
    return true
}

private func nativeTCPReadExact(from fd: Int32, byteCount: Int) throws -> Data {
    var data = Data()
    data.reserveCapacity(byteCount)
    var buffer = [UInt8](repeating: 0, count: min(4096, max(1, byteCount)))
    while data.count < byteCount {
        let count = Darwin.read(fd, &buffer, min(buffer.count, byteCount - data.count))
        if count > 0 {
            data.append(buffer, count: count)
        } else if count < 0, errno == EINTR {
            continue
        } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            Thread.sleep(forTimeInterval: 0.0005)
            continue
        } else {
            throw ConjetError.socket("native TCP frame read failed: \(String(cString: strerror(errno)))")
        }
    }
    return data
}

private func nativeTCPPayloadLength(fromHeader header: Data) -> Int {
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

private func nativeTCPDisableSigpipe(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func nativeTCPWriteHTTPBadGateway(_ payload: Data, to fd: Int32) {
    let message = String(data: payload, encoding: .utf8) ?? "native TCP bridge target failed"
    let body = Data("Conjet native TCP bridge is unavailable: \(message)\n".utf8)
    let header = Data("""
    HTTP/1.1 502 Bad Gateway\r
    Content-Type: text/plain; charset=utf-8\r
    Connection: close\r
    Content-Length: \(body.count)\r
    \r

    """.utf8)
    _ = nativeTCPWriteAll(header + body, to: fd)
}

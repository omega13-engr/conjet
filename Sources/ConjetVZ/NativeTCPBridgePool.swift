import ConjetCore
import Darwin
import Foundation

struct NativeTCPBridgeForwardResult: Sendable {
    var reusable: Bool
    var hadError: Bool
    var opened: Bool = true
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
        maxConnections: Int = 96,
        minimumIdleConnections: Int = 8,
        refillDelaySeconds: TimeInterval = 0.01
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
        nativeTCPSetNoDelayIfSupported(guest.fileDescriptor)
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
            guard try waitForOpenAck(streamID: streamID) else {
                return NativeTCPBridgeForwardResult(reusable: true, hadError: true, opened: false)
            }
        } catch {
            return NativeTCPBridgeForwardResult(reusable: false, hadError: true, opened: false)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self, state] in
            defer { group.leave() }
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !state.isFinished {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    onClientBytes(count)
                    do {
                        try writeFrame(
                            type: .tcpData,
                            streamID: streamID,
                            pointer: buffer,
                            count: count
                        )
                    } catch {
                        state.markError()
                        Darwin.shutdown(clientFD, SHUT_RDWR)
                        return
                    }
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    if !nativeTCPWaitForFD(clientFD, events: Int16(POLLIN), timeoutMilliseconds: 5_000) {
                        state.markError()
                        Darwin.shutdown(clientFD, SHUT_RDWR)
                        return
                    }
                    continue
                } else {
                    do {
                        try writeFrame(type: .tcpHalfClose, streamID: streamID)
                    } catch {
                        state.markError()
                    }
                    return
                }
            }
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self, state] in
            defer { group.leave() }
            guard let self else { return }
            while !state.isFinished {
                do {
                    let frame = try readFrame()
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
                        Darwin.shutdown(clientFD, SHUT_WR)
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

        group.wait()
        if state.hasError {
            reusable = false
            hadError = true
        }
        return NativeTCPBridgeForwardResult(reusable: reusable, hadError: hadError)
    }

    private func waitForOpenAck(streamID: UInt32) throws -> Bool {
        while true {
            let frame = try readFrame()
            guard frame.streamID == streamID else {
                continue
            }
            switch frame.type {
            case .tcpOpen:
                return true
            case .tcpError:
                return false
            default:
                continue
            }
        }
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

    private func writeFrame(type: ConjetBinaryFrameType, streamID: UInt32, portForwardID: UInt32 = 0) throws {
        try writeFrame(type: type, streamID: streamID, portForwardID: portForwardID, pointer: nil, count: 0)
    }

    private func writeFrame(
        type: ConjetBinaryFrameType,
        streamID: UInt32,
        portForwardID: UInt32 = 0,
        pointer: UnsafeRawPointer?,
        count: Int
    ) throws {
        guard !isClosed else {
            throw ConjetError.socket("native TCP bridge connection is closed")
        }
        guard count <= ConjetBinaryFrame.maxPayloadBytes else {
            throw ConjetBinaryFrameError.oversizedPayload(count)
        }
        var header = [UInt8](repeating: 0, count: ConjetBinaryFrame.headerSize)
        nativeTCPWriteUInt32BE(ConjetBinaryFrame.magic, into: &header, at: 0)
        header[4] = ConjetBinaryFrame.version
        header[5] = type.rawValue
        nativeTCPWriteUInt16BE(0, into: &header, at: 6)
        nativeTCPWriteUInt32BE(streamID, into: &header, at: 8)
        nativeTCPWriteUInt32BE(portForwardID, into: &header, at: 12)
        nativeTCPWriteUInt32BE(UInt32(count), into: &header, at: 16)

        guard nativeTCPWriteAll(header, to: guest.fileDescriptor) else {
            close()
            throw ConjetError.socket("failed to write native TCP frame header")
        }
        if count > 0 {
            guard let pointer, nativeTCPWriteAll(pointer, count: count, to: guest.fileDescriptor) else {
                close()
                throw ConjetError.socket("failed to write native TCP frame payload")
            }
        }
    }

    private func writeFrame(
        type: ConjetBinaryFrameType,
        streamID: UInt32,
        portForwardID: UInt32 = 0,
        pointer: [UInt8],
        count: Int
    ) throws {
        try pointer.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                try writeFrame(type: type, streamID: streamID, portForwardID: portForwardID)
                return
            }
            try writeFrame(type: type, streamID: streamID, portForwardID: portForwardID, pointer: base, count: count)
        }
    }

    private func readFrame() throws -> NativeTCPFrame {
        guard !isClosed else {
            throw ConjetError.socket("native TCP bridge connection is closed")
        }
        let header = try nativeTCPReadExact(from: guest.fileDescriptor, byteCount: ConjetBinaryFrame.headerSize)
        let decodedHeader = try NativeTCPFrameHeader(header)
        let payloadLength = Int(decodedHeader.payloadLength)
        if payloadLength > ConjetBinaryFrame.maxPayloadBytes {
            throw ConjetError.socket("native TCP frame payload too large: \(payloadLength)")
        }
        let payload = payloadLength > 0 ? try nativeTCPReadExact(from: guest.fileDescriptor, byteCount: payloadLength) : Data()
        return NativeTCPFrame(
            type: decodedHeader.type,
            flags: decodedHeader.flags,
            streamID: decodedHeader.streamID,
            portForwardID: decodedHeader.portForwardID,
            payload: payload
        )
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

private struct NativeTCPFrame {
    var type: ConjetBinaryFrameType
    var flags: UInt16
    var streamID: UInt32
    var portForwardID: UInt32
    var payload: Data
}

private struct NativeTCPFrameHeader {
    var type: ConjetBinaryFrameType
    var flags: UInt16
    var streamID: UInt32
    var portForwardID: UInt32
    var payloadLength: UInt32

    init(_ data: Data) throws {
        guard data.count >= ConjetBinaryFrame.headerSize else {
            throw ConjetBinaryFrameError.truncatedHeader
        }
        let bytes = [UInt8](data)
        let magic = nativeTCPReadUInt32BE(bytes, at: 0)
        guard magic == ConjetBinaryFrame.magic else {
            throw ConjetBinaryFrameError.badMagic
        }
        guard bytes[4] == ConjetBinaryFrame.version else {
            throw ConjetBinaryFrameError.badVersion(bytes[4])
        }
        guard let type = ConjetBinaryFrameType(rawValue: bytes[5]) else {
            throw ConjetBinaryFrameError.unknownType(bytes[5])
        }
        let payloadLength = nativeTCPReadUInt32BE(bytes, at: 16)
        guard payloadLength <= UInt32(ConjetBinaryFrame.maxPayloadBytes) else {
            throw ConjetBinaryFrameError.oversizedPayload(Int(payloadLength))
        }
        self.type = type
        self.flags = nativeTCPReadUInt16BE(bytes, at: 6)
        self.streamID = nativeTCPReadUInt32BE(bytes, at: 8)
        self.portForwardID = nativeTCPReadUInt32BE(bytes, at: 12)
        self.payloadLength = payloadLength
    }
}

private func nativeTCPWriteAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
    bytes.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
        return nativeTCPWriteAll(baseAddress, count: bytes.count, to: fd)
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
            if !nativeTCPWaitForFD(fd, events: Int16(POLLOUT), timeoutMilliseconds: 5_000) {
                return false
            }
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
            guard nativeTCPWaitForFD(fd, events: Int16(POLLIN), timeoutMilliseconds: 5_000) else {
                throw ConjetError.socket("native TCP frame read timed out waiting for data")
            }
            continue
        } else {
            throw ConjetError.socket("native TCP frame read failed: \(String(cString: strerror(errno)))")
        }
    }
    return data
}

private func nativeTCPWaitForFD(_ fd: Int32, events: Int16, timeoutMilliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: events, revents: 0)
    while true {
        let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
        if result > 0 {
            return (descriptor.revents & (events | Int16(POLLHUP) | Int16(POLLERR))) != 0
        }
        if result < 0, errno == EINTR {
            continue
        }
        return false
    }
}

private func nativeTCPReadUInt16BE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
}

private func nativeTCPReadUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
}

private func nativeTCPWriteUInt16BE(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8((value >> 8) & 0xff)
    bytes[offset + 1] = UInt8(value & 0xff)
}

private func nativeTCPWriteUInt32BE(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8((value >> 24) & 0xff)
    bytes[offset + 1] = UInt8((value >> 16) & 0xff)
    bytes[offset + 2] = UInt8((value >> 8) & 0xff)
    bytes[offset + 3] = UInt8(value & 0xff)
}

private func nativeTCPDisableSigpipe(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func nativeTCPSetNoDelayIfSupported(_ fd: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
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

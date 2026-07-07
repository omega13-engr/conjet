import Darwin
import Dispatch
import Foundation

public final class UnixSocketClient {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: DaemonRequest, timeoutSeconds: Double? = nil) throws -> DaemonResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed: \(lastErrno())")
        }
        disableSigpipe(fd)
        if let timeoutSeconds {
            setSocketTimeout(fd, timeoutSeconds: timeoutSeconds)
        }
        defer { Darwin.close(fd) }

        try withUnixSocketAddress(path: socketPath) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                throw ConjetError.socket("connect(\(socketPath)) failed: \(lastErrno())")
            }
        }

        var data = try ConjetJSON.encoder(pretty: false).encode(request)
        data.append(0x0a)
        try writeAll(data, to: fd)

        let responseData = try readLine(from: fd, timeoutSeconds: timeoutSeconds)
        do {
            return try ConjetJSON.decoder().decode(DaemonResponse.self, from: responseData)
        } catch {
            throw ConjetError.decoding("daemon response was not valid JSON: \(error)")
        }
    }

    public func streamPulse(
        sinceSequence: UInt64 = 0,
        timeoutSeconds: Double? = nil,
        onFrame: (ConjetPulseFrame) throws -> Bool
    ) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed: \(lastErrno())")
        }
        disableSigpipe(fd)
        if let timeoutSeconds {
            setSocketTimeout(fd, timeoutSeconds: timeoutSeconds)
        }
        defer { Darwin.close(fd) }

        try withUnixSocketAddress(path: socketPath) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                throw ConjetError.socket("connect(\(socketPath)) failed: \(lastErrno())")
            }
        }

        var data = try ConjetJSON.encoder(pretty: false).encode(DaemonRequest(
            command: .pulseSubscribe,
            parameters: ["since_seq": String(sinceSequence)]
        ))
        data.append(0x0a)
        try writeAll(data, to: fd)

        while true {
            let frameData = try readLine(from: fd, timeoutSeconds: timeoutSeconds)
            let frame: ConjetPulseFrame
            do {
                frame = try ConjetJSON.decoder().decode(ConjetPulseFrame.self, from: frameData)
            } catch {
                throw ConjetError.decoding("daemon pulse frame was not valid JSON: \(error)")
            }
            if try !onFrame(frame) {
                return
            }
        }
    }
}

public final class UnixSocketJSONLineWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()

    fileprivate init(fd: Int32) {
        self.fd = fd
    }

    public func write<T: Encodable>(_ value: T) throws {
        var data = try ConjetJSON.encoder(pretty: false).encode(value)
        data.append(0x0a)
        lock.lock()
        defer { lock.unlock() }
        try writeAll(data, to: fd)
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func listen(
        handler: @escaping @Sendable (DaemonRequest) -> DaemonResponse,
        streamHandler: (@Sendable (DaemonRequest, UnixSocketJSONLineWriter) throws -> Bool)? = nil,
        shouldStop: () -> Bool
    ) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed: \(lastErrno())")
        }
        disableSigpipe(fd)
        setSocketTimeout(fd, timeoutSeconds: 0.25)
        defer {
            Darwin.close(fd)
            unlink(socketPath)
        }

        unlink(socketPath)
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

        try withUnixSocketAddress(path: socketPath) { address, length in
            guard Darwin.bind(fd, address, length) == 0 else {
                throw ConjetError.socket("bind(\(socketPath)) failed: \(lastErrno())")
            }
        }

        guard Darwin.listen(fd, 16) == 0 else {
            throw ConjetError.socket("listen() failed: \(lastErrno())")
        }

        while !shouldStop() {
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw ConjetError.socket("accept() failed: \(lastErrno())")
            }
            disableSigpipe(clientFD)
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleClient(clientFD, handler: handler, streamHandler: streamHandler)
            }
        }
    }

    private func handleClient(
        _ clientFD: Int32,
        handler: @escaping @Sendable (DaemonRequest) -> DaemonResponse,
        streamHandler: (@Sendable (DaemonRequest, UnixSocketJSONLineWriter) throws -> Bool)?
    ) {
        defer { Darwin.close(clientFD) }

        do {
            let response: DaemonResponse
            let requestData = try readLine(from: clientFD)
            let request = try ConjetJSON.decoder().decode(DaemonRequest.self, from: requestData)
            if let streamHandler,
               try streamHandler(request, UnixSocketJSONLineWriter(fd: clientFD)) {
                return
            }
            response = handler(request)
            var responseData = try ConjetJSON.encoder(pretty: false).encode(response)
            responseData.append(0x0a)
            try writeAll(responseData, to: clientFD)
        } catch {
            let response = DaemonResponse(ok: false, message: String(describing: error))
            if let responseData = try? ConjetJSON.encoder(pretty: false).encode(response) {
                var line = responseData
                line.append(0x0a)
                try? writeAll(line, to: clientFD)
            }
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

private func readLine(
    from fd: Int32,
    maxBytes: Int = 1_048_576,
    timeoutSeconds: Double? = nil
) throws -> Data {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(4096)
    var receivedTerminator = false
    let timeout = timeoutSeconds.map { max(0.1, $0) }
    let deadline = timeout.map { Date().addingTimeInterval($0) }

    while bytes.count < maxBytes {
        if let deadline {
            try waitUntilReadable(fd, deadline: deadline, timeoutSeconds: timeout ?? 0)
        }
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        if count == 1 {
            if byte == 0x0a {
                receivedTerminator = true
                break
            }
            bytes.append(byte)
        } else if count == 0 {
            break
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
            if let deadline, Date() >= deadline {
                throw ConjetError.socket("read() timed out after \(formatTimeout(timeout ?? 0))s")
            }
            if let deadline {
                Thread.sleep(forTimeInterval: min(0.01, max(0.001, deadline.timeIntervalSinceNow)))
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
            continue
        } else {
            throw ConjetError.socket("read() failed: \(lastErrno())")
        }
    }

    guard !bytes.isEmpty else {
        throw ConjetError.socket("connection closed without a response")
    }
    guard receivedTerminator || bytes.count < maxBytes else {
        throw ConjetError.socket("daemon response exceeded \(maxBytes) bytes")
    }
    return Data(bytes)
}

private func waitUntilReadable(
    _ fd: Int32,
    deadline: Date,
    timeoutSeconds: Double
) throws {
    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw ConjetError.socket("read() timed out after \(formatTimeout(timeoutSeconds))s")
        }

        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMilliseconds = Int32(max(1, min(1000, (remaining * 1000).rounded(.up))))
        let result = Darwin.poll(&pollFD, 1, timeoutMilliseconds)
        if result > 0 {
            if (pollFD.revents & Int16(POLLNVAL)) != 0 {
                throw ConjetError.socket("read() failed: invalid file descriptor")
            }
            return
        }
        if result == 0 {
            continue
        }
        if errno == EINTR {
            continue
        }
        throw ConjetError.socket("poll() failed: \(lastErrno())")
    }
}

private func setSocketTimeout(_ fd: Int32, timeoutSeconds: Double) {
    let timeout = max(0.1, timeoutSeconds)
    var value = timeval(
        tv_sec: Int(timeout),
        tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
    )
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
}

private func formatTimeout(_ seconds: Double) -> String {
    let rounded = (seconds * 10).rounded() / 10
    if rounded == floor(rounded) {
        return String(Int(rounded))
    }
    return String(format: "%.1f", rounded)
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var written = 0
        while written < data.count {
            let result = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
            if result > 0 {
                written += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw ConjetError.socket("write() failed: \(lastErrno())")
            }
        }
    }
}

private func disableSigpipe(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func lastErrno() -> String {
    String(cString: strerror(errno))
}

import Darwin
import Foundation

public struct DockerSocketReadinessProbe: Sendable {
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func ping(timeoutSeconds: TimeInterval = 1) -> Bool {
        guard let response = try? pingResponse(timeoutSeconds: timeoutSeconds) else {
            return false
        }
        return response.statusCode == 200
            && response.body.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
    }

    public func waitUntilReady(
        timeoutSeconds: TimeInterval,
        intervalSeconds: TimeInterval = 0.25
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        let interval = max(0.05, intervalSeconds)
        repeat {
            if ping(timeoutSeconds: min(1, max(0.1, deadline.timeIntervalSinceNow))) {
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(interval, remaining))
        } while Date() < deadline
        return false
    }

    public func requireReady(
        timeoutSeconds: TimeInterval,
        intervalSeconds: TimeInterval = 0.25
    ) throws {
        guard waitUntilReady(timeoutSeconds: timeoutSeconds, intervalSeconds: intervalSeconds) else {
            throw ConjetError.unavailable("timed out waiting \(Int(timeoutSeconds))s for Conjet Docker API readiness")
        }
    }

    private func pingResponse(timeoutSeconds: TimeInterval) throws -> DockerSocketPingResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed: \(dockerProbeLastErrno())")
        }
        dockerProbeDisableSigpipe(fd)
        dockerProbeSetSocketTimeout(fd, timeoutSeconds: timeoutSeconds)
        defer { Darwin.close(fd) }

        try dockerProbeWithUnixSocketAddress(path: socketPath) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                throw ConjetError.socket("connect(\(socketPath)) failed: \(dockerProbeLastErrno())")
            }
        }

        try dockerProbeWriteAll(
            Data("GET /_ping HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n".utf8),
            to: fd
        )
        let response = try dockerProbeReadAvailable(from: fd)
        return DockerSocketPingResponse(data: response)
    }
}

private struct DockerSocketPingResponse {
    var statusCode: Int?
    var body: String

    init(data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let headers = parts.first ?? ""
        self.body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let statusLine = headers.components(separatedBy: "\r\n").first ?? ""
        let fields = statusLine.split(separator: " ")
        if fields.count >= 2 {
            self.statusCode = Int(fields[1])
        } else {
            self.statusCode = nil
        }
    }
}

private func dockerProbeWithUnixSocketAddress<Result>(
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

private func dockerProbeReadAvailable(from fd: Int32, maxBytes: Int = 8192) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < maxBytes {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
            if data.range(of: Data("\r\n\r\nOK".utf8)) != nil || data.suffix(2) == Data("OK".utf8) {
                break
            }
        } else if count == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            throw ConjetError.socket("read() failed: \(dockerProbeLastErrno())")
        }
    }
    return data
}

private func dockerProbeWriteAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
            let count = Darwin.write(fd, baseAddress.advanced(by: written), rawBuffer.count - written)
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw ConjetError.socket("write() failed: \(dockerProbeLastErrno())")
            }
        }
    }
}

private func dockerProbeSetSocketTimeout(_ fd: Int32, timeoutSeconds: TimeInterval) {
    let bounded = max(0.1, timeoutSeconds)
    let seconds = Int(bounded)
    let microseconds = Int32((bounded - Double(seconds)) * 1_000_000)
    var timeout = timeval(tv_sec: seconds, tv_usec: microseconds)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func dockerProbeDisableSigpipe(_ fd: Int32) {
    var value: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
}

private func dockerProbeLastErrno() -> String {
    String(cString: strerror(errno))
}

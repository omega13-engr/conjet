import Darwin
import Foundation

public struct DockerSocketReadinessProbe: Sendable {
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func ping(timeoutSeconds: TimeInterval = 1) -> Bool {
        guard let response = try? httpResponse(path: "/_ping", timeoutSeconds: timeoutSeconds) else {
            return false
        }
        return response.statusCode == 200
            && response.body.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
    }

    public func isReady(timeoutSeconds: TimeInterval = 1) -> Bool {
        guard ping(timeoutSeconds: timeoutSeconds) else {
            return false
        }
        guard let version = try? httpResponse(path: "/version", timeoutSeconds: timeoutSeconds),
              version.isSuccessfulDockerJSON(requiredFields: ["Version", "ApiVersion"]) else {
            return false
        }
        guard let info = try? httpResponse(path: "/info", timeoutSeconds: timeoutSeconds),
              info.isSuccessfulDockerJSON(requiredFields: ["Containers", "Driver"]) else {
            return false
        }
        return true
    }

    public func waitUntilReady(
        timeoutSeconds: TimeInterval,
        intervalSeconds: TimeInterval = 0.25
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        let interval = max(0.05, intervalSeconds)
        repeat {
            if isReady(timeoutSeconds: min(1, max(0.1, deadline.timeIntervalSinceNow))) {
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

    private func httpResponse(path: String, timeoutSeconds: TimeInterval) throws -> DockerSocketHTTPResponse {
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

        try dockerProbeWriteAll(Data("GET \(path) HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n".utf8), to: fd)
        let response = try dockerProbeReadAvailable(from: fd)
        return DockerSocketHTTPResponse(data: response)
    }
}

private struct DockerSocketHTTPResponse {
    var statusCode: Int?
    var body: String

    init(data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        let headersData: Data
        let bodyData: Data
        if let headerRange = data.range(of: separator) {
            headersData = Data(data[..<headerRange.lowerBound])
            bodyData = Data(data[headerRange.upperBound...])
        } else {
            headersData = data
            bodyData = Data()
        }
        let headers = String(decoding: headersData, as: UTF8.self)
        let decodedBody = Self.headersUseChunkedTransferEncoding(headers)
            ? (Self.decodeChunkedBody(bodyData) ?? bodyData)
            : bodyData
        self.body = String(decoding: decodedBody, as: UTF8.self)
        let statusLine = headers.components(separatedBy: "\r\n").first ?? ""
        let fields = statusLine.split(separator: " ")
        if fields.count >= 2 {
            self.statusCode = Int(fields[1])
        } else {
            self.statusCode = nil
        }
    }

    func isSuccessfulDockerJSON(requiredFields: [String]) -> Bool {
        guard let statusCode, (200..<300).contains(statusCode) else {
            return false
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed != "null" else {
            return false
        }
        guard !trimmed.contains(#""message""#) else {
            return false
        }
        return requiredFields.allSatisfy { trimmed.contains(#""\#($0)""#) }
    }

    private static func headersUseChunkedTransferEncoding(_ headers: String) -> Bool {
        headers
            .split(separator: "\r\n")
            .contains { line in
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return false }
                return parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "transfer-encoding"
                    && parts[1].lowercased().contains("chunked")
            }
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        let crlf = Data("\r\n".utf8)
        var offset = 0
        var decoded = Data()

        while offset < data.count {
            guard let lineRange = data[offset..<data.count].range(of: crlf) else {
                return nil
            }
            let sizeLine = String(decoding: data[offset..<lineRange.lowerBound], as: UTF8.self)
            let sizeText = sizeLine
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                return nil
            }
            offset = lineRange.upperBound
            if size == 0 {
                return decoded
            }

            let chunkEnd = offset + size
            guard chunkEnd <= data.count else {
                return nil
            }
            decoded.append(data[offset..<chunkEnd])
            offset = chunkEnd
            guard offset + crlf.count <= data.count,
                  data[offset..<(offset + crlf.count)].elementsEqual(crlf) else {
                return nil
            }
            offset += crlf.count
        }

        return nil
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

private func dockerProbeReadAvailable(from fd: Int32, maxBytes: Int = 256 * 1024) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < maxBytes {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
            if dockerProbeHasCompleteHTTPResponse(data) ||
                data.range(of: Data("\r\n\r\nOK".utf8)) != nil ||
                data.suffix(2) == Data("OK".utf8) {
                break
            }
        } else if count == 0 {
            break
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK, !data.isEmpty {
            break
        } else {
            throw ConjetError.socket("read() failed: \(dockerProbeLastErrno())")
        }
    }
    return data
}

private func dockerProbeHasCompleteHTTPResponse(_ data: Data) -> Bool {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerEnd = data.range(of: separator)?.upperBound else {
        return false
    }
    let headers = String(decoding: data[..<headerEnd], as: UTF8.self)
    if dockerProbeUsesChunkedTransferEncoding(headers: headers) {
        return dockerProbeHasCompleteChunkedBody(Data(data[headerEnd...]))
    }
    guard let contentLength = dockerProbeContentLength(headers: headers) else {
        return false
    }
    return data.count >= headerEnd + contentLength
}

private func dockerProbeUsesChunkedTransferEncoding(headers: String) -> Bool {
    headers
        .split(separator: "\r\n")
        .contains { line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            return parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "transfer-encoding"
                && parts[1].lowercased().contains("chunked")
        }
}

private func dockerProbeHasCompleteChunkedBody(_ body: Data) -> Bool {
    let finalChunk = Data("\r\n0\r\n\r\n".utf8)
    if body.range(of: finalChunk) != nil {
        return true
    }
    return body.starts(with: Data("0\r\n\r\n".utf8))
}

private func dockerProbeContentLength(headers: String) -> Int? {
    for line in headers.split(separator: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" else {
            continue
        }
        return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
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

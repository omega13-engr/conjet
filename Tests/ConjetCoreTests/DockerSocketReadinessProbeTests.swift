import ConjetCore
import Darwin
import Foundation
import XCTest

final class DockerSocketReadinessProbeTests: XCTestCase {
    func testPingSucceedsForDockerOKResponse() throws {
        let server = try OneShotHTTPUnixSocketServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
        server.start()
        try server.waitForSocket()

        XCTAssertTrue(DockerSocketReadinessProbe(socketPath: server.socketPath).ping(timeoutSeconds: 1))
        XCTAssertNil(server.capturedError())
    }

    func testPingRejectsInitializingResponse() throws {
        let server = try OneShotHTTPUnixSocketServer(response: "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 12\r\n\r\ninitializing")
        server.start()
        try server.waitForSocket()

        XCTAssertFalse(DockerSocketReadinessProbe(socketPath: server.socketPath).ping(timeoutSeconds: 1))
        XCTAssertNil(server.capturedError())
    }

    func testReadinessRequiresPingVersionAndInfo() throws {
        let server = try OneShotHTTPUnixSocketServer(responses: [
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
            #"HTTP/1.1 200 OK\#r\#nContent-Length: 42\#r\#n\#r\#n{"Version":"29.6.1","ApiVersion":"1.52"}"#.httpFixture,
            #"HTTP/1.1 200 OK\#r\#nContent-Length: 47\#r\#n\#r\#n{"Containers":0,"Images":0,"Driver":"overlay2"}"#.httpFixture
        ])
        server.start()
        try server.waitForSocket()

        XCTAssertTrue(DockerSocketReadinessProbe(socketPath: server.socketPath).isReady(timeoutSeconds: 1))
        XCTAssertNil(server.capturedError())
    }

    func testReadinessAcceptsChunkedDockerResponses() throws {
        let server = try OneShotHTTPUnixSocketServer(responses: [
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
            Self.chunkedResponse(body: #"{"Version":"29.6.1","ApiVersion":"1.52"}"#),
            Self.chunkedResponse(body: #"{"Containers":0,"Images":0,"Driver":"overlay2"}"#)
        ])
        server.start()
        try server.waitForSocket()

        XCTAssertTrue(DockerSocketReadinessProbe(socketPath: server.socketPath).isReady(timeoutSeconds: 1))
        XCTAssertNil(server.capturedError())
    }

    func testReadinessRejectsContextCanceledVersionPayload() throws {
        let server = try OneShotHTTPUnixSocketServer(responses: [
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
            #"HTTP/1.1 500 Internal Server Error\#r\#nContent-Length: 30\#r\#n\#r\#n{"message":"context canceled"}"#.httpFixture
        ])
        server.start()
        try server.waitForSocket()

        XCTAssertFalse(DockerSocketReadinessProbe(socketPath: server.socketPath).isReady(timeoutSeconds: 1))
        XCTAssertNil(server.capturedError())
    }

    func testReadinessRejectsNullInfoPayload() throws {
        let server = try OneShotHTTPUnixSocketServer(responses: [
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
            #"HTTP/1.1 200 OK\#r\#nContent-Length: 42\#r\#n\#r\#n{"Version":"29.6.1","ApiVersion":"1.52"}"#.httpFixture,
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnull"
        ])
        server.start()
        try server.waitForSocket()

        XCTAssertFalse(DockerSocketReadinessProbe(socketPath: server.socketPath).isReady(timeoutSeconds: 1))
        XCTAssertNil(server.capturedError())
    }

    private static func chunkedResponse(body: String) -> String {
        let size = String(body.utf8.count, radix: 16)
        return """
        HTTP/1.1 200 OK\r
        Transfer-Encoding: chunked\r
        Content-Type: application/json\r
        \r
        \(size)\r
        \(body)\r
        0\r
        \r
        """
    }
}

private final class OneShotHTTPUnixSocketServer: @unchecked Sendable {
    let socketPath: String
    private let responses: [String]
    private let lock = NSLock()
    private var error: Error?

    convenience init(response: String) throws {
        try self.init(responses: [response])
    }

    init(responses: [String]) throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cjdp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.socketPath = root.appendingPathComponent("docker.sock").path
        self.responses = responses
    }

    func start() {
        Thread { [socketPath, responses] in
            do {
                try runOneShotHTTPUnixSocketServer(socketPath: socketPath, responses: responses)
            } catch {
                self.lock.lock()
                self.error = error
                self.lock.unlock()
            }
        }.start()
    }

    func waitForSocket(timeoutSeconds: TimeInterval = 1) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw ConjetError.socket("timed out waiting for test Docker socket")
    }

    func capturedError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

private func runOneShotHTTPUnixSocketServer(socketPath: String, responses: [String]) throws {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw ConjetError.socket("socket() failed")
    }
    defer {
        Darwin.close(fd)
        unlink(socketPath)
    }
    unlink(socketPath)
    try testDockerProbeWithUnixSocketAddress(path: socketPath) { address, length in
        guard Darwin.bind(fd, address, length) == 0 else {
            throw ConjetError.socket("bind(\(socketPath)) failed")
        }
    }
    guard Darwin.listen(fd, Int32(max(1, responses.count))) == 0 else {
        throw ConjetError.socket("listen() failed")
    }
    for response in responses {
        let clientFD = Darwin.accept(fd, nil, nil)
        guard clientFD >= 0 else {
            throw ConjetError.socket("accept() failed")
        }
        defer { Darwin.close(clientFD) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        _ = Darwin.read(clientFD, &buffer, buffer.count)
        try Data(response.utf8).withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(clientFD, baseAddress.advanced(by: written), rawBuffer.count - written)
                if count > 0 {
                    written += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw ConjetError.socket("write() failed")
                }
            }
        }
    }
}

private extension String {
    var httpFixture: String {
        replacingOccurrences(of: #"\#r"#, with: "\r")
            .replacingOccurrences(of: #"\#n"#, with: "\n")
    }
}

private func testDockerProbeWithUnixSocketAddress<Result>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) throws -> Result {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw ConjetError.socket("Unix socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        rawBuffer.copyBytes(from: pathBytes)
    }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            try body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

import ConjetCore
import Darwin
import Foundation
@testable import ConjetVZ
import XCTest

final class DockerSocketBridgeTests: XCTestCase {
    func testRetryingConnectorEventuallyConnects() throws {
        let connector = FlakyGuestConnectionConnector(failuresBeforeSuccess: 2)
        let retrying = RetryingGuestConnectionConnector(
            base: connector,
            timeoutSeconds: 1,
            intervalSeconds: 0.01
        )

        let connection = try retrying.connect()
        connection.close()
        XCTAssertEqual(connector.attempts, 3)
    }

    func testRetryingConnectorReportsTimeout() {
        let connector = FlakyGuestConnectionConnector(failuresBeforeSuccess: Int.max)
        let retrying = RetryingGuestConnectionConnector(
            base: connector,
            timeoutSeconds: 0.03,
            intervalSeconds: 0.01
        )

        XCTAssertThrowsError(try retrying.connect()) { error in
            XCTAssertTrue(String(describing: error).contains("timed out waiting for guest Docker bridge"))
        }
        XCTAssertGreaterThanOrEqual(connector.attempts, 2)
    }

    func testPooledConnectorServesPreconnectedConnection() throws {
        let connector = NumberedGuestConnectionConnector()
        let pooled = PooledGuestConnectionConnector(
            base: connector,
            capacity: 1,
            refillDelaySeconds: 0.01
        )
        defer { pooled.closeIdleConnections() }

        XCTAssertTrue(waitUntil { pooled.idleConnectionCountForTesting() == 1 })

        let connection = try pooled.connect()
        defer { connection.close() }
        XCTAssertEqual(connection.fileDescriptor, 1)
    }

    func testPooledConnectorFallsBackWhenPoolIsEmpty() throws {
        let connector = NumberedGuestConnectionConnector()
        let pooled = PooledGuestConnectionConnector(
            base: connector,
            capacity: 0,
            refillDelaySeconds: 0.01
        )
        defer { pooled.closeIdleConnections() }

        let connection = try pooled.connect()
        defer { connection.close() }
        XCTAssertEqual(connection.fileDescriptor, 1)
    }

    func testCapabilityProbeEnablesPoolForLazyGuestBridge() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 45\r
        \r
        {"lazy_upstream":true,"docker_ready_cache":true}

        """)

        XCTAssertTrue(GuestBridgeCapabilityProbe.supportsPooledConnections(connector: connector))
    }

    func testCapabilityProbeDetectsPublishedPortTCPProxy() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 67\r
        \r
        {"lazy_upstream":true,"docker_ready_cache":true,"tcp_proxy":true}

        """)

        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: connector)
        XCTAssertTrue(capabilities.lazyUpstream)
        XCTAssertTrue(capabilities.dockerReadyCache)
        XCTAssertTrue(capabilities.tcpProxy)
    }

    func testCapabilityProbeDetectsConjetNetV2Capabilities() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 220\r
        \r
        {"version":2,"capabilities":{"tcp_proxy":true,"udp_proxy":true,"docker_events":true,"container_ip_lookup":true,"port_probe":true,"proxy_metrics":true},"tcp_proxy":true,"udp_proxy":true}

        """)

        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: connector)
        XCTAssertEqual(capabilities.version, 2)
        XCTAssertTrue(capabilities.tcpProxy)
        XCTAssertTrue(capabilities.udpProxy)
        XCTAssertTrue(capabilities.dockerEvents)
        XCTAssertTrue(capabilities.containerIPLookup)
        XCTAssertTrue(capabilities.portProbe)
        XCTAssertTrue(capabilities.proxyMetrics)
    }

    func testCapabilityProbeDetectsConjetNetdCapabilities() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 350\r
        \r
        {"version":5,"capabilities":{"tcp_proxy":true,"udp_proxy":true,"guest_echo":true,"guest_metrics":true,"binary_frames":true,"udp_binary_frames":true,"persistent_vsock":true,"tcp_binary_frames":true,"persistent_tcp_vsock":true,"tcp_vsock_pool":true,"proxy_metrics":true,"bridge_engine":"conjet-netd-c"},"tcp_proxy":true,"udp_proxy":true,"guest_echo":true,"guest_metrics":true,"binary_frames":true,"udp_binary_frames":true,"persistent_vsock":true,"tcp_binary_frames":true,"persistent_tcp_vsock":true,"tcp_vsock_pool":true}

        """)

        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: connector)
        XCTAssertEqual(capabilities.version, 5)
        XCTAssertTrue(capabilities.guestEcho)
        XCTAssertTrue(capabilities.guestMetrics)
        XCTAssertTrue(capabilities.binaryFrames)
        XCTAssertTrue(capabilities.udpBinaryFrames)
        XCTAssertTrue(capabilities.persistentVsock)
        XCTAssertTrue(capabilities.tcpBinaryFrames)
        XCTAssertTrue(capabilities.persistentTCPVsock)
        XCTAssertTrue(capabilities.tcpVsockPool)
        XCTAssertEqual(capabilities.bridgeEngine, "conjet-netd-c")
    }

    func testCapabilityProbeRejectsLegacyDockerForwarder() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 404 Not Found\r
        Content-Type: application/json\r
        Content-Length: 16\r
        \r
        {"message":"404"}

        """)

        XCTAssertFalse(GuestBridgeCapabilityProbe.supportsPooledConnections(connector: connector))
    }

    func testStartAndStopOwnsDockerSocketPath() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: UnavailableGuestConnectionConnector()
        )

        try bridge.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertTrue(bridge.isRunning())

        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertFalse(bridge.isRunning())
    }

    func testUnavailableGuestReturnsHTTP503() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: UnavailableGuestConnectionConnector(message: "guest not booted")
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path)
        XCTAssertTrue(response.contains("503 Service Unavailable"))
        XCTAssertTrue(response.contains("guest not booted"))
    }

    private func sendRawRequest(socketPath: String) throws -> String {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        try withUnixSocketAddress(path: socketPath) { address, length in
            XCTAssertEqual(Darwin.connect(fd, address, length), 0)
        }

        let request = "GET /_ping HTTP/1.1\r\nHost: conjet\r\n\r\n"
        _ = request.withCString { pointer in
            Darwin.write(fd, pointer, strlen(pointer))
        }
        Darwin.shutdown(fd, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func withUnixSocketAddress<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
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

    private func shortID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 1,
        intervalSeconds: TimeInterval = 0.01,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() {
                return true
            }
            Thread.sleep(forTimeInterval: intervalSeconds)
        }
        return predicate()
    }
}

private final class FlakyGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let failuresBeforeSuccess: Int
    private var attemptCount = 0

    var attempts: Int {
        lock.lock()
        let value = attemptCount
        lock.unlock()
        return value
    }

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func connect() throws -> GuestConnection {
        lock.lock()
        attemptCount += 1
        let shouldFail = attemptCount <= failuresBeforeSuccess
        lock.unlock()

        if shouldFail {
            throw ConjetError.unavailable("guest not ready")
        }
        return GuestConnection(fileDescriptor: -1) {}
    }
}

private final class NumberedGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var nextFileDescriptor: Int32 = 1

    func connect() throws -> GuestConnection {
        lock.lock()
        let fileDescriptor = nextFileDescriptor
        nextFileDescriptor += 1
        lock.unlock()

        return GuestConnection(fileDescriptor: fileDescriptor) {}
    }
}

private final class CapabilityResponseGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let response: String

    init(response: String) {
        self.response = response
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        let response = response
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(serverFD, &buffer, buffer.count)
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.close(serverFD)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

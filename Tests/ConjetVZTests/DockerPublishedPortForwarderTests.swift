import ConjetCore
import Darwin
import Foundation
@testable import ConjetVZ
import XCTest

final class DockerPublishedPortForwarderTests: XCTestCase {
    func testParsesDockerInspectPublishedTCPPorts() throws {
        let json = """
        [
          {
            "Id": "abc123",
            "Name": "/web",
            "State": {"Running": true},
            "NetworkSettings": {
              "Ports": {
                "63000/tcp": [{"HostIp": "0.0.0.0", "HostPort": "63000"}],
                "63001/tcp": [{"HostIp": "127.0.0.1", "HostPort": "63001"}],
                "8125/udp": [{"HostIp": "0.0.0.0", "HostPort": "8125"}],
                "9000/tcp": null
              }
            }
          }
        ]
        """

        let ports = DockerPublishedPortForwarder.publishedPorts(fromDockerInspectJSON: Data(json.utf8))

        XCTAssertEqual(ports, [
            DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 63000, containerPort: 63000, protocol: .tcp, containerID: "abc123", containerName: "web"),
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: 63001, containerPort: 63001, protocol: .tcp, containerID: "abc123", containerName: "web"),
            DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 8125, containerPort: 8125, protocol: .udp, containerID: "abc123", containerName: "web")
        ])
    }

    func testDiscoveryCacheKeepsPublishedPortsAcrossFullReconcile() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let fullID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let shortID = String(fullID.prefix(12))
        let inspectJSON = """
        [
          {
            "Id": "\(fullID)",
            "Name": "/api",
            "State": {"Running": true},
            "NetworkSettings": {
              "Ports": {
                "63001/tcp": [{"HostIp": "0.0.0.0", "HostPort": "63001"}]
              },
              "Networks": {
                "default": {"IPAddress": "172.18.0.5"}
              }
            }
          }
        ]
        """

        let runner = DockerDiscoveryRunner(fullID: fullID, shortID: shortID, inspectJSON: inspectJSON)
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: UnavailableGuestConnectionConnector(),
            runner: runner.run
        )
        defer { forwarder.stop() }

        let first = forwarder.discoverPublishedPortsForTesting()
        let second = forwarder.discoverPublishedPortsForTesting()

        XCTAssertEqual(first, [
            DockerPublishedPort(
                hostIP: "0.0.0.0",
                hostPort: 63001,
                containerPort: 63001,
                protocol: .tcp,
                containerID: fullID,
                containerName: "api",
                targetIP: "172.18.0.5"
            )
        ])
        XCTAssertEqual(second, first)
        XCTAssertEqual(runner.inspectCalls, 1)
        XCTAssertTrue(runner.psArguments.allSatisfy { $0.contains("--no-trunc") })
    }

    func testPruneCacheForcesNextDiscoveryToInspectAgain() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let fullID = "bcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789a"
        let shortID = String(fullID.prefix(12))
        let inspectJSON = """
        [
          {
            "Id": "\(fullID)",
            "Name": "/api",
            "State": {"Running": true},
            "NetworkSettings": {
              "Ports": {
                "63002/tcp": [{"HostIp": "0.0.0.0", "HostPort": "63002"}]
              }
            }
          }
        ]
        """

        let runner = DockerDiscoveryRunner(fullID: fullID, shortID: shortID, inspectJSON: inspectJSON)
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: UnavailableGuestConnectionConnector(),
            runner: runner.run
        )
        defer { forwarder.stop() }

        _ = forwarder.discoverPublishedPortsForTesting()
        _ = forwarder.discoverPublishedPortsForTesting()
        XCTAssertEqual(runner.inspectCalls, 1)

        forwarder.pruneCache()
        _ = forwarder.discoverPublishedPortsForTesting()

        XCTAssertEqual(runner.inspectCalls, 2)
        XCTAssertTrue(forwarder.status().messages.contains("network cache pruned"))
    }

    func testTargetedReconcilePrunesContainerWhenInspectReportsNoSuchContainer() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "cab5d0c4e47275282ce694468988ad4c357246db31085e701da6fd4082afb66b"
        let hostPort = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: UnavailableGuestConnectionConnector(),
            runner: DockerNoSuchContainerRunner(containerID: containerID).run
        )
        defer { forwarder.stop() }

        let eventContainerID = String(containerID.prefix(12))
        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 80,
                protocol: .tcp,
                containerID: containerID,
                containerName: "web"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })

        forwarder.reconcileContainerIDsForTesting([eventContainerID])

        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().isEmpty })
        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 0)
        XCTAssertEqual(status.staleForwards, 1)
        XCTAssertEqual(status.forwards.first?.containerID, containerID)
        XCTAssertEqual(status.forwards.first?.state, .stale)
    }

    func testEnergyModeControlsBackgroundReconcileInterval() {
        let balanced = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector(),
            energyMode: .balanced
        )
        let eco = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector(),
            energyMode: .eco
        )
        defer {
            balanced.stop()
            eco.stop()
        }

        XCTAssertEqual(balanced.status().periodicReconcileIntervalSeconds, 90)
        XCTAssertEqual(eco.status().periodicReconcileIntervalSeconds, 180)
    }

    func testReconcileStartsAndStopsListeners() throws {
        let connector = UnavailableGuestConnectionConnector()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector
        )
        defer { forwarder.stop() }

        let port = try reserveLoopbackPort()
        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "0.0.0.0", hostPort: port, containerPort: 80, protocol: .tcp)
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(port) })
        XCTAssertEqual(forwarder.status().activeTCPForwards, 2)

        forwarder.reconcileForTesting([])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().isEmpty })
    }

    func testListenerForwardsThroughGuestTCPProxyProtocol() throws {
        let connector = TCPProxyEchoConnector()
        let port = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector
        )
        defer { forwarder.stop() }
        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 63000, protocol: .tcp)
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(port) })

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }

        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)
        let response = readAllTestBytes(from: fd)

        XCTAssertEqual(String(data: response, encoding: .utf8), "pong")
        XCTAssertTrue(waitUntil { connector.prefaces.contains("CONJET-TCP 127.0.0.1:\(port)") })
    }

    func testUDPPortIsCapabilityGated() throws {
        let port = try reserveUDPPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector(),
            capabilities: ConjetNetworkCapabilities(tcpProxy: true, udpProxy: false)
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 5353, protocol: .udp)
        ])

        let status = forwarder.status()
        XCTAssertEqual(status.activeUDPForwards, 0)
        XCTAssertEqual(status.failedForwards, 1)
        XCTAssertEqual(status.forwards.first?.state, .failedGuestCapability)
    }

    func testUDPListenerUsesBinaryFramePathWhenCapabilitiesAdvertiseIt() throws {
        let connector = BinaryUDPEchoConnector()
        let port = try reserveUDPPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                guestEcho: true,
                guestMetrics: true,
                binaryFrames: true,
                udpBinaryFrames: true,
                persistentVsock: true,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 5353, protocol: .udp)
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeUDPForwards == 1 })

        let response = try sendUDPDatagram(Data("ping".utf8), to: port)

        XCTAssertEqual(String(data: response, encoding: .utf8), "echo:ping")
        XCTAssertTrue(waitUntil { connector.registeredTargets == 1 })
        XCTAssertEqual(connector.udpPayloads.map { String(data: $0, encoding: .utf8) }, ["ping"])
    }

    func testUDPBinaryFramePathReusesPersistentGuestConnection() throws {
        let connector = BinaryUDPEchoConnector()
        let port = try reserveUDPPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                guestEcho: true,
                guestMetrics: true,
                binaryFrames: true,
                udpBinaryFrames: true,
                persistentVsock: true,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 5353, protocol: .udp)
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeUDPForwards == 1 })

        let first = try sendUDPDatagram(Data("one".utf8), to: port)
        let second = try sendUDPDatagram(Data("two".utf8), to: port)

        XCTAssertEqual(String(data: first, encoding: .utf8), "echo:one")
        XCTAssertEqual(String(data: second, encoding: .utf8), "echo:two")
        XCTAssertTrue(waitUntil { connector.udpPayloads.count == 2 })
        XCTAssertEqual(connector.connectionCount, 2, "one registration connection and one persistent UDP data connection should be used")
    }

    func testTCPFallsBackWhenPoolCapabilityIsUnavailable() throws {
        let connector = TCPProxyEchoConnector()
        let port = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                binaryFrames: true,
                udpBinaryFrames: true,
                persistentVsock: true,
                tcpBinaryFrames: true,
                persistentTCPVsock: true,
                tcpVsockPool: false,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 63000, protocol: .tcp)
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(port) })

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)

        XCTAssertEqual(String(data: readAllTestBytes(from: fd), encoding: .utf8), "pong")
        XCTAssertTrue(waitUntil { connector.prefaces.contains("CONJET-TCP 127.0.0.1:\(port)") })
        XCTAssertEqual(forwarder.status().tcpMode, "legacy-tcp-proxy")
    }

    func testNativeTCPBridgePoolSelectedWhenCapabilitiesArePresent() throws {
        let connector = BinaryTCPEchoConnector()
        let port = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: nativeTCPCapabilities()
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: port,
                containerPort: 80,
                protocol: .tcp,
                targetIP: "172.17.0.2"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeTCPForwards == 1 })

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)
        let response = readAllTestBytes(from: fd)

        XCTAssertEqual(String(data: response, encoding: .utf8), "pong")
        XCTAssertTrue(waitUntil { connector.openTargets.contains("172.17.0.2:80") })
        let status = forwarder.status()
        XCTAssertEqual(status.bridgeEngine, "conjet-netd-c")
        XCTAssertEqual(status.tcpMode, "persistent-binary-tcp-pool")
        XCTAssertTrue(status.tcpBinaryFrames)
        XCTAssertTrue(status.persistentTCPVsock)
        XCTAssertTrue(status.tcpVsockPool)
        XCTAssertFalse(status.pythonFallbackActive)
    }

    func testNativeTCPBridgePoolReportsOpenErrors() throws {
        let connector = BinaryTCPEchoConnector(errorOnOpen: true)
        let port = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: nativeTCPCapabilities()
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 63000, protocol: .tcp)
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeTCPForwards == 1 })

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)
        let response = readAllTestBytes(from: fd)

        XCTAssertTrue(String(data: response, encoding: .utf8)?.contains("502 Bad Gateway") == true)
        XCTAssertTrue(waitUntil { forwarder.status().forwards.first?.connectionErrors == 1 })
    }


    private func reserveLoopbackPort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw ConjetError.socket("bind random loopback port failed")
                }
            }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &bound) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.getsockname(fd, socketAddress, &length) == 0 else {
                    throw ConjetError.socket("getsockname failed")
                }
            }
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func reserveUDPPort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw ConjetError.socket("bind random UDP loopback port failed")
                }
            }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &bound) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.getsockname(fd, socketAddress, &length) == 0 else {
                    throw ConjetError.socket("getsockname failed")
                }
            }
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func connectLoopback(port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        do {
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                        throw ConjetError.socket("connect loopback failed")
                    }
                }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func sendUDPDatagram(_ payload: Data, to port: Int) throws -> Data {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard Darwin.sendto(fd, base, payload.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == payload.count else {
                        throw ConjetError.socket("sendto loopback UDP failed")
                    }
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw ConjetError.socket("recv loopback UDP failed")
        }
        return Data(buffer.prefix(count))
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

    private func nativeTCPCapabilities() -> ConjetNetworkCapabilities {
        ConjetNetworkCapabilities(
            tcpProxy: true,
            udpProxy: true,
            guestEcho: true,
            guestMetrics: true,
            binaryFrames: true,
            udpBinaryFrames: true,
            persistentVsock: true,
            tcpBinaryFrames: true,
            persistentTCPVsock: true,
            tcpVsockPool: true,
            bridgeEngine: "conjet-netd-c"
        )
    }
}

private final class DockerDiscoveryRunner: @unchecked Sendable {
    private let fullID: String
    private let shortID: String
    private let inspectJSON: String
    private let lock = NSLock()
    private var recordedInspectCalls = 0
    private var recordedPSArguments: [[String]] = []

    init(fullID: String, shortID: String, inspectJSON: String) {
        self.fullID = fullID
        self.shortID = shortID
        self.inspectJSON = inspectJSON
    }

    var inspectCalls: Int {
        lock.lock()
        let value = recordedInspectCalls
        lock.unlock()
        return value
    }

    var psArguments: [[String]] {
        lock.lock()
        let value = recordedPSArguments
        lock.unlock()
        return value
    }

    func run(executable: String, arguments: [String], timeoutSeconds: Double?) throws -> ProcessResult {
        if arguments.contains("ps") {
            lock.lock()
            recordedPSArguments.append(arguments)
            lock.unlock()
            let id = arguments.contains("--no-trunc") ? fullID : shortID
            return ProcessResult(executable: executable, arguments: arguments, exitCode: 0, stdout: "\(id)\n", stderr: "")
        }
        if arguments.contains("inspect") {
            lock.lock()
            recordedInspectCalls += 1
            lock.unlock()
            return ProcessResult(executable: executable, arguments: arguments, exitCode: 0, stdout: inspectJSON, stderr: "")
        }
        return ProcessResult(executable: executable, arguments: arguments, exitCode: 1, stdout: "", stderr: "unexpected command")
    }
}

private final class DockerNoSuchContainerRunner: @unchecked Sendable {
    private let containerID: String

    init(containerID: String) {
        self.containerID = containerID
    }

    func run(executable: String, arguments: [String], timeoutSeconds: Double?) throws -> ProcessResult {
        if arguments.contains("inspect") {
            return ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 1,
                stdout: "",
                stderr: "Error response from daemon: No such container: \(containerID)"
            )
        }
        return ProcessResult(executable: executable, arguments: arguments, exitCode: 0, stdout: "", stderr: "")
    }
}

private final class BinaryUDPEchoConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var connectionIndex = 0
    private var registrations = 0
    private var payloads: [Data] = []

    var registeredTargets: Int {
        lock.lock()
        let value = registrations
        lock.unlock()
        return value
    }

    var udpPayloads: [Data] {
        lock.lock()
        let value = payloads
        lock.unlock()
        return value
    }

    var connectionCount: Int {
        lock.lock()
        let value = connectionIndex
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        lock.lock()
        connectionIndex += 1
        let index = connectionIndex
        lock.unlock()

        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            while let frame = try? readBinaryTestFrame(from: serverFD) {
                if index == 1, frame.type == .registerTarget {
                    self.lock.lock()
                    self.registrations += 1
                    self.lock.unlock()
                    let response = ConjetBinaryFrame(type: .helloAck, portForwardID: frame.portForwardID)
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                    return
                }
                guard frame.type == .udp else {
                    let response = ConjetBinaryFrame(type: .error, payload: Data("unexpected".utf8))
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                    continue
                }
                self.lock.lock()
                self.payloads.append(frame.payload)
                self.lock.unlock()
                let response = ConjetBinaryFrame(
                    type: .udp,
                    streamID: frame.streamID,
                    portForwardID: frame.portForwardID,
                    payload: Data("echo:".utf8) + frame.payload
                )
                _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
            }
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class TCPProxyEchoConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var seenPrefaces: [String] = []

    var prefaces: [String] {
        lock.lock()
        let value = seenPrefaces
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let preface = readLineTestBytes(from: serverFD)
            self.lock.lock()
            self.seenPrefaces.append(preface)
            self.lock.unlock()

            let request = readAllTestBytes(from: serverFD)
            if String(data: request, encoding: .utf8) == "ping" {
                _ = writeAllTestBytes(Data("pong".utf8), to: serverFD)
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class BinaryTCPEchoConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let errorOnOpen: Bool
    private var targets: [String] = []
    private var payloads: [Data] = []

    init(errorOnOpen: Bool = false) {
        self.errorOnOpen = errorOnOpen
    }

    var openTargets: [String] {
        lock.lock()
        let value = targets
        lock.unlock()
        return value
    }

    var tcpPayloads: [Data] {
        lock.lock()
        let value = payloads
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            while let frame = try? readBinaryTestFrame(from: serverFD) {
                switch frame.type {
                case .tcpOpen:
                    if self.errorOnOpen {
                        let response = ConjetBinaryFrame(
                            type: .tcpError,
                            streamID: frame.streamID,
                            payload: Data("open failed".utf8)
                        )
                        _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                        continue
                    }
                    if let target = try? ConjetTCPFrameTarget.decode(frame.payload) {
                        self.lock.lock()
                        self.targets.append("\(target.host):\(target.port)")
                        self.lock.unlock()
                    }
                    let response = ConjetBinaryFrame(type: .tcpOpen, streamID: frame.streamID)
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                case .tcpData:
                    self.lock.lock()
                    self.payloads.append(frame.payload)
                    self.lock.unlock()
                    let responsePayload = String(data: frame.payload, encoding: .utf8) == "ping"
                        ? Data("pong".utf8)
                        : frame.payload
                    let response = ConjetBinaryFrame(
                        type: .tcpData,
                        streamID: frame.streamID,
                        payload: responsePayload
                    )
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                case .tcpHalfClose:
                    let halfClose = ConjetBinaryFrame(type: .tcpHalfClose, streamID: frame.streamID)
                    let close = ConjetBinaryFrame(type: .tcpClose, streamID: frame.streamID)
                    _ = writeAllTestBytes((try? halfClose.encode()) ?? Data(), to: serverFD)
                    _ = writeAllTestBytes((try? close.encode()) ?? Data(), to: serverFD)
                    return
                case .tcpClose:
                    return
                default:
                    let response = ConjetBinaryFrame(
                        type: .tcpError,
                        streamID: frame.streamID,
                        payload: Data("unexpected".utf8)
                    )
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                }
            }
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private func readLineTestBytes(from fd: Int32) -> String {
    var data = Data()
    var byte: UInt8 = 0
    while Darwin.read(fd, &byte, 1) == 1 {
        if byte == 10 {
            break
        }
        data.append(byte)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func makeTestSocketPair() throws -> [Int32] {
    var fds = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw ConjetError.socket("socketpair() failed")
    }
    disableTestSigpipe(fds[0])
    disableTestSigpipe(fds[1])
    return fds
}

private func disableTestSigpipe(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func readAllTestBytes(from fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
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

private func writeAllTestBytes(_ data: Data, to fd: Int32) -> Bool {
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

private func readBinaryTestFrame(from fd: Int32) throws -> ConjetBinaryFrame {
    let header = try readExactTestBytes(from: fd, byteCount: ConjetBinaryFrame.headerSize)
    let payloadLength = testPayloadLength(fromHeader: header)
    let payload = payloadLength > 0 ? try readExactTestBytes(from: fd, byteCount: payloadLength) : Data()
    return try ConjetBinaryFrame.decode(header + payload)
}

private func readExactTestBytes(from fd: Int32, byteCount: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: max(1, min(4096, byteCount)))
    while data.count < byteCount {
        let count = Darwin.read(fd, &buffer, min(buffer.count, byteCount - data.count))
        if count > 0 {
            data.append(buffer, count: count)
        } else if count < 0, errno == EINTR {
            continue
        } else {
            throw ConjetError.socket("test binary frame read failed")
        }
    }
    return data
}

private func testPayloadLength(fromHeader header: Data) -> Int {
    let start = header.index(header.startIndex, offsetBy: 16)
    let b0 = UInt32(header[start])
    let b1 = UInt32(header[header.index(start, offsetBy: 1)])
    let b2 = UInt32(header[header.index(start, offsetBy: 2)])
    let b3 = UInt32(header[header.index(start, offsetBy: 3)])
    return Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
}

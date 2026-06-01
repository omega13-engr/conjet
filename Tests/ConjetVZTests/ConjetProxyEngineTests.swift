import ConjetCore
import Darwin
import Dispatch
import Foundation
@testable import ConjetVZ
import XCTest

final class ConjetProxyEngineTests: XCTestCase {
    func testProxyEngineAutoSelectsMeasuredFastPath() {
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector(),
            proxyEngine: .auto
        )
        defer { forwarder.stop() }

        XCTAssertEqual(forwarder.status().proxyEngine, "proxy-gcd-evented")
    }

    func testProxyEngineCanForceGCDFallback() {
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector(),
            proxyEngine: .gcdFallback
        )
        defer { forwarder.stop() }

        XCTAssertEqual(forwarder.status().proxyEngine, "proxy-gcd-evented")
    }

    func testTCPForwardUsesNIOWhenConfigured() throws {
        let port = try reserveTCPPort()
        let connector = TCPProxyEchoConnectorForProxyEngineTests()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            proxyEngine: .eventLoop
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 80, protocol: .tcp)
        ])

        XCTAssertTrue(waitUntil { forwarder.status().forwards.first?.state == .listening })
        XCTAssertEqual(forwarder.status().forwards.first?.proxyEngine, "proxy-nio")
    }

    func testUDPForwardUsesNIOWhenConfigured() throws {
        let port = try reserveUDPPort()
        let connector = UDPProxyEchoConnectorForProxyEngineTests()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            proxyEngine: .eventLoop,
            capabilities: ConjetNetworkCapabilities(tcpProxy: true, udpProxy: true)
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 5353, protocol: .udp)
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeUDPForwards == 1 })

        let response = try sendUDP(payload: Data("udp-ping".utf8), port: port)
        XCTAssertEqual(String(data: response, encoding: .utf8), "udp-ping")
        XCTAssertEqual(forwarder.status().forwards.first?.proxyEngine, "proxy-nio")
    }

    private func reserveTCPPort() throws -> Int {
        try reservePort(type: SOCK_STREAM)
    }

    private func reserveUDPPort() throws -> Int {
        try reservePort(type: SOCK_DGRAM)
    }

    private func reservePort(type: Int32) throws -> Int {
        let fd = Darwin.socket(AF_INET, type, 0)
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

    private func sendUDP(payload: Data, port: Int) throws -> Data {
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
        let sent = payload.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(fd, rawBuffer.baseAddress, payload.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, payload.count)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw ConjetError.socket("UDP echo receive failed")
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
}

private final class TCPProxyEchoConnectorForProxyEngineTests: GuestConnectionConnector, @unchecked Sendable {
    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            _ = readLineProxyEngineTest(from: serverFD)
            let request = readAllProxyEngineTest(from: serverFD)
            if String(data: request, encoding: .utf8) == "ping" {
                _ = writeAllProxyEngineTest(Data("pong".utf8), to: serverFD)
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }
        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class UDPProxyEchoConnectorForProxyEngineTests: GuestConnectionConnector, @unchecked Sendable {
    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            _ = readLineProxyEngineTest(from: serverFD)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(serverFD, &buffer, buffer.count)
            if count > 0 {
                _ = writeAllProxyEngineTest(Data(buffer.prefix(count)), to: serverFD)
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }
        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private func readLineProxyEngineTest(from fd: Int32) -> String {
    var data = Data()
    var byte: UInt8 = 0
    while Darwin.read(fd, &byte, 1) == 1 {
        if byte == 10 { break }
        data.append(byte)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func readAllProxyEngineTest(from fd: Int32) -> Data {
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

private func writeAllProxyEngineTest(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
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

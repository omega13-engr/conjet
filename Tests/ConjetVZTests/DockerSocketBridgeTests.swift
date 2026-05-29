import ConjetVZ
import Darwin
import Foundation
import XCTest

final class DockerSocketBridgeTests: XCTestCase {
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
}

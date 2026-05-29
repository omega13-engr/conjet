import ConjetCore
import Darwin
import XCTest

final class UnixSocketTests: XCTestCase {
    private final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var stopping = false
        private var error: Error?

        func stop() {
            lock.lock()
            stopping = true
            lock.unlock()
        }

        func shouldStop() -> Bool {
            lock.lock()
            let value = stopping
            lock.unlock()
            return value
        }

        func setError(_ error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        func capturedError() -> Error? {
            lock.lock()
            let value = error
            lock.unlock()
            return value
        }
    }

    func testServerSurvivesClientDisconnectBeforeResponse() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cj-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let socket = root.appendingPathComponent("conjetd.sock")
        let state = ServerState()

        let thread = Thread {
            do {
                let server = UnixSocketServer(socketPath: socket.path)
                try server.listen { request in
                    if request.command == .stop {
                        state.stop()
                    }
                    return DaemonResponse(ok: true, message: "ok")
                } shouldStop: {
                    state.shouldStop()
                }
            } catch {
                state.setError(error)
            }
        }
        thread.start()
        try waitForSocket(socket.path)

        try connectAndClose(socket.path)

        let response = try UnixSocketClient(socketPath: socket.path).send(DaemonRequest(command: .status))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "ok")

        _ = try UnixSocketClient(socketPath: socket.path).send(DaemonRequest(command: .stop))
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertNil(state.capturedError())
    }

    private func waitForSocket(_ path: String) throws {
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw ConjetError.unavailable("test socket did not appear at \(path)")
    }

    private func connectAndClose(_ path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed")
        }
        defer { Darwin.close(fd) }

        try withUnixSocketAddress(path: path) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                throw ConjetError.socket("connect(\(path)) failed")
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
}

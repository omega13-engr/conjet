import ConjetCore
import Darwin
import Dispatch
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

    func testClientSendTimeoutBoundsSlowDaemonHook() throws {
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
                    if request.command == .status {
                        Thread.sleep(forTimeInterval: 1)
                    }
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

        let startedAt = Date()
        XCTAssertThrowsError(try UnixSocketClient(socketPath: socket.path).send(
            DaemonRequest(command: .status),
            timeoutSeconds: 0.1
        )) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("timed out after 0.1s"), description)
            XCTAssertFalse(description.contains("Resource temporarily unavailable"), description)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)

        Thread.sleep(forTimeInterval: 1)
        _ = try UnixSocketClient(socketPath: socket.path).send(DaemonRequest(command: .stop), timeoutSeconds: 1)
    }

    func testClientReportsOversizedDaemonResponse() throws {
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
                        return DaemonResponse(ok: true, message: "stopping")
                    }
                    return DaemonResponse(ok: true, message: String(repeating: "x", count: 1_100_000))
                } shouldStop: {
                    state.shouldStop()
                }
            } catch {
                state.setError(error)
            }
        }
        thread.start()
        try waitForSocket(socket.path)

        XCTAssertThrowsError(try UnixSocketClient(socketPath: socket.path).send(
            DaemonRequest(command: .status),
            timeoutSeconds: 2
        )) { error in
            XCTAssertTrue(String(describing: error).contains("daemon response exceeded"))
        }

        _ = try UnixSocketClient(socketPath: socket.path).send(DaemonRequest(command: .stop), timeoutSeconds: 1)
    }

    func testServerRespondsToPingWhileAnotherRequestIsSlow() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cj-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let socket = root.appendingPathComponent("conjetd.sock")
        let state = ServerState()
        let slowRequestStarted = DispatchSemaphore(value: 0)
        let slowRequestFinished = DispatchSemaphore(value: 0)

        let thread = Thread {
            do {
                let server = UnixSocketServer(socketPath: socket.path)
                try server.listen { request in
                    if request.command == .status {
                        slowRequestStarted.signal()
                        Thread.sleep(forTimeInterval: 0.6)
                    }
                    if request.command == .stop {
                        state.stop()
                    }
                    return DaemonResponse(ok: true, message: request.command.rawValue)
                } shouldStop: {
                    state.shouldStop()
                }
            } catch {
                state.setError(error)
            }
        }
        thread.start()
        try waitForSocket(socket.path)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? UnixSocketClient(socketPath: socket.path).send(
                DaemonRequest(command: .status),
                timeoutSeconds: 2
            )
            slowRequestFinished.signal()
        }

        XCTAssertEqual(slowRequestStarted.wait(timeout: .now() + 1), .success)

        let startedAt = Date()
        let response = try UnixSocketClient(socketPath: socket.path).send(
            DaemonRequest(command: .ping),
            timeoutSeconds: 0.3
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "ping")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)

        XCTAssertEqual(slowRequestFinished.wait(timeout: .now() + 2), .success)
        _ = try UnixSocketClient(socketPath: socket.path).send(DaemonRequest(command: .stop), timeoutSeconds: 1)
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertNil(state.capturedError())
    }

    func testPulseStreamDeliversReplayAndLiveEvents() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cj-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let socket = root.appendingPathComponent("conjetd.sock")
        let state = ServerState()
        let pulse = ConjetPulseLog(capacity: 8)
        _ = pulse.append(type: .daemonStarted, subjectID: "default")

        let replaySeen = DispatchSemaphore(value: 0)
        let clientFinished = DispatchSemaphore(value: 0)
        final class FrameBox: @unchecked Sendable {
            private let lock = NSLock()
            private var frames: [ConjetPulseFrame] = []

            func append(_ frame: ConjetPulseFrame) {
                lock.lock()
                frames.append(frame)
                lock.unlock()
            }

            func get() -> [ConjetPulseFrame] {
                lock.lock()
                defer { lock.unlock() }
                return frames
            }
        }
        let box = FrameBox()

        let thread = Thread {
            do {
                let server = UnixSocketServer(socketPath: socket.path)
                try server.listen { request in
                    if request.command == .stop {
                        state.stop()
                    }
                    return DaemonResponse(ok: true, message: "ok")
                } streamHandler: { request, writer in
                    guard request.command == .pulseSubscribe else { return false }
                    var lastSequence = request.parameters["since_seq"].flatMap(UInt64.init) ?? 0
                    let replay = pulse.replay(after: lastSequence)
                    try writer.write(ConjetPulseFrame.replay(replay))
                    lastSequence = replay.state.highWatermark
                    while !state.shouldStop() {
                        let next = pulse.waitForReplay(after: lastSequence, timeout: 0.2)
                        guard !next.events.isEmpty else { continue }
                        try writer.write(ConjetPulseFrame.events(next))
                        lastSequence = next.state.highWatermark
                    }
                    return true
                } shouldStop: {
                    state.shouldStop()
                }
            } catch {
                state.setError(error)
            }
        }
        thread.start()
        try waitForSocket(socket.path)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try UnixSocketClient(socketPath: socket.path).streamPulse(sinceSequence: 0, timeoutSeconds: 2) { frame in
                    box.append(frame)
                    if frame.kind == .replay {
                        replaySeen.signal()
                    }
                    if frame.events.contains(where: { $0.type == .vmStarted }) {
                        state.stop()
                        return false
                    }
                    return true
                }
            } catch {
                state.setError(error)
            }
            clientFinished.signal()
        }

        XCTAssertEqual(replaySeen.wait(timeout: .now() + 1), .success)
        _ = pulse.append(type: .vmStarted, subjectID: "vm")
        XCTAssertEqual(clientFinished.wait(timeout: .now() + 2), .success)

        let frames = box.get()
        XCTAssertEqual(frames.first?.kind, .replay)
        XCTAssertEqual(frames.first?.events.map(\.type), [.daemonStarted])
        XCTAssertTrue(frames.contains { frame in
            frame.kind == .events && frame.events.contains { $0.type == .vmStarted }
        })
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

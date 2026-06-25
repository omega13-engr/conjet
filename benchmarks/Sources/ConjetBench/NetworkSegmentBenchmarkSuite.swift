import ConjetCore
import Darwin
import Dispatch
import Foundation

public struct NetworkSegmentBenchmarkOptions: Sendable {
    public var contexts: [String]
    public var samples: Int
    public var commandTimeoutSeconds: Double
    public var workloads: [String]

    public init(
        contexts: [String] = ["conjet"],
        samples: Int = 30,
        commandTimeoutSeconds: Double = 60,
        workloads: [String] = NetworkSegmentBenchmarkSuite.defaultWorkloads
    ) {
        self.contexts = contexts
        self.samples = max(1, samples)
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.workloads = workloads
    }
}

public struct NetworkSegmentBenchmarkSuite: Sendable {
    public static let defaultWorkloads = [
        "host-to-conjetd-loopback-echo",
        "host-to-vsock-echo",
        "guest-bridge-echo",
        "guest-to-container-direct-echo",
        "full-tcp-forward-echo",
        "full-udp-forward-echo",
        "tcp-connection-setup-latency",
        "tcp-keepalive-request-latency",
        "tcp-new-connection-request-latency",
        "udp-binary-frame-echo"
    ]

    private let options: NetworkSegmentBenchmarkOptions

    public init(options: NetworkSegmentBenchmarkOptions) {
        self.options = options
    }

    public func run(outputDirectory: URL) throws -> [BenchmarkResult] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let machine = MachineProfiler.capture(cacheTTLSeconds: 60)
        var results: [BenchmarkResult] = []
        for context in options.contexts {
            for sample in 0..<options.samples {
                for workload in options.workloads {
                    switch workload {
                    case "host-to-conjetd-loopback-echo":
                        results.append(runHostLoopbackEcho(context: context, sample: sample, machine: machine))
                    case "host-to-vsock-echo", "guest-bridge-echo":
                        results.append(runGuestHTTPPathEcho(context: context, workload: workload, sample: sample, machine: machine))
                    case "udp-binary-frame-echo":
                        results.append(runBinaryFrameEcho(context: context, sample: sample, machine: machine))
                    case "full-tcp-forward-echo", "tcp-connection-setup-latency", "tcp-new-connection-request-latency":
                        results.append(runFullTCPForwardEcho(context: context, workload: workload, sample: sample, machine: machine))
                    case "full-udp-forward-echo":
                        results.append(runFullUDPForwardEcho(context: context, sample: sample, machine: machine))
                    case "tcp-keepalive-request-latency":
                        results.append(runTCPKeepaliveEcho(context: context, sample: sample, machine: machine))
                    default:
                        results.append(skippedSegment(context: context, workload: workload, sample: sample, machine: machine))
                    }
                }
            }
        }
        return results
    }

    private func runHostLoopbackEcho(context: String, sample: Int, machine: MachineProfile) -> BenchmarkResult {
        let startedAt = Date()
        var metrics = segmentMetrics(context: context, protocolName: "tcp", sample: sample)
        metrics.setString("host-loopback", for: "segment")
        let payload = Data(repeating: 0x5a, count: 64)
        do {
            let server = try LocalTCPEchoServer()
            let latency = measureTCPEcho(port: server.port, payload: payload)
            metrics["latency_p50_ms"] = latency
            metrics["latency_p95_ms"] = latency
            metrics["latency_p99_ms"] = latency
            metrics["max_latency_ms"] = latency
            metrics["bytes"] = Double(payload.count)
            metrics["payload_size"] = Double(payload.count)
            server.stop()
            return BenchmarkResult(
                workload: "host-to-conjetd-loopback-echo",
                runtime: context,
                command: ["builtin-local-tcp-echo"],
                startedAt: startedAt,
                durationSeconds: Date().timeIntervalSince(startedAt),
                exitCode: latency == nil ? 1 : 0,
                metrics: metrics,
                machine: machine,
                stderrTail: latency == nil ? "local TCP echo failed" : ""
            )
        } catch {
            metrics.setString("local_echo_start_failed", for: "failure_reason")
            return BenchmarkResult(
                workload: "host-to-conjetd-loopback-echo",
                runtime: context,
                command: ["builtin-local-tcp-echo"],
                startedAt: startedAt,
                durationSeconds: Date().timeIntervalSince(startedAt),
                exitCode: 1,
                metrics: metrics,
                machine: machine,
                stderrTail: String(describing: error)
            )
        }
    }

    private func runGuestHTTPPathEcho(context: String, workload: String, sample: Int, machine: MachineProfile) -> BenchmarkResult {
        let startedAt = Date()
        var metrics = segmentMetrics(context: context, protocolName: "tcp", sample: sample)
        metrics.setString(workload == "host-to-vsock-echo" ? "host-to-vsock" : "guest-bridge", for: "segment")
        metrics.setBool(false, for: "connection_reuse")
        guard context == "conjet" else {
            metrics.setBool(true, for: "skipped")
            metrics.setString("internal_segment_only_available_for_conjet", for: "failure_reason")
            return BenchmarkResult(workload: workload, runtime: context, command: ["network-segments", workload], startedAt: startedAt, durationSeconds: 0, exitCode: 0, metrics: metrics, machine: machine, stderrTail: "Conjet-only internal segment")
        }
        let payloadBytes = 18
        let latency = measureUnixHTTP(path: "/conjet-guest-echo", expectedBody: "conjet-guest-echo\n")
        metrics["latency_p50_ms"] = latency
        metrics["latency_p95_ms"] = latency
        metrics["latency_p99_ms"] = latency
        metrics["max_latency_ms"] = latency
        metrics["bytes"] = Double(payloadBytes)
        metrics["payload_size"] = Double(payloadBytes)
        if latency == nil {
            metrics.setString("guest_echo_endpoint_unavailable", for: "failure_reason")
        }
        return BenchmarkResult(
            workload: workload,
            runtime: context,
            command: ["unix-http", conjetDockerSocketPath(), "/conjet-guest-echo"],
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: latency == nil ? 1 : 0,
            metrics: metrics,
            machine: machine,
            stderrTail: latency == nil ? "guest echo endpoint failed" : ""
        )
    }

    private func runBinaryFrameEcho(context: String, sample: Int, machine: MachineProfile) -> BenchmarkResult {
        let startedAt = Date()
        var metrics = segmentMetrics(context: context, protocolName: "udp", sample: sample)
        metrics.setString("udp-binary-frame", for: "segment")
        metrics.setString("binary-v1", for: "udp_frame_format")
        guard context == "conjet" else {
            metrics.setBool(true, for: "skipped")
            metrics.setString("binary_frame_segment_only_available_for_conjet", for: "failure_reason")
            return BenchmarkResult(workload: "udp-binary-frame-echo", runtime: context, command: ["network-segments", "udp-binary-frame-echo"], startedAt: startedAt, durationSeconds: 0, exitCode: 0, metrics: metrics, machine: machine, stderrTail: "Conjet-only binary segment")
        }
        let latency = measureBinaryPing(payload: Data("binary-ping".utf8))
        metrics["latency_p50_ms"] = latency
        metrics["latency_p95_ms"] = latency
        metrics["latency_p99_ms"] = latency
        metrics["max_latency_ms"] = latency
        metrics["bytes"] = 11
        metrics["payload_size"] = 11
        metrics["udp_packets_sent"] = 1
        metrics["udp_packets_received"] = latency == nil ? 0 : 1
        if latency == nil {
            metrics.setString("binary_frame_endpoint_unavailable", for: "failure_reason")
        }
        return BenchmarkResult(
            workload: "udp-binary-frame-echo",
            runtime: context,
            command: ["binary-frame", conjetDockerSocketPath(), "PING"],
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: latency == nil ? 1 : 0,
            metrics: metrics,
            machine: machine,
            stderrTail: latency == nil ? "binary frame endpoint failed" : ""
        )
    }

    private func runFullTCPForwardEcho(
        context: String,
        workload: String,
        sample: Int,
        machine: MachineProfile
    ) -> BenchmarkResult {
        let startedAt = Date()
        let port = reservePort(type: SOCK_STREAM) ?? Int.random(in: 20_000...60_000)
        let name = "conjet-seg-tcp-\(context)-\(sample)-\(shortID())"
        let script = """
        import socket
        s=socket.socket()
        s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        s.bind(('0.0.0.0',8080))
        s.listen(128)
        while True:
            c,_=s.accept()
            while True:
                d=c.recv(65536)
                if not d: break
                c.sendall(d)
            c.close()
        """
        let command = dockerArgs(context, [
            "run", "--rm", "-d", "--name", name,
            "-p", "127.0.0.1:\(port):8080",
            "python:3.12-alpine",
            "python", "-u", "-c", script
        ])
        var metrics = segmentMetrics(context: context, protocolName: "tcp", sample: sample)
        metrics.setString("full-tcp-forward", for: "segment")
        metrics.setBool(false, for: "connection_reuse")
        let start = runProcess(command, timeoutSeconds: options.commandTimeoutSeconds)
        guard start.exitCode == 0 else {
            metrics.setString("container_start_failed", for: "failure_reason")
            return segmentFailure(workload: workload, runtime: context, command: command, startedAt: startedAt, metrics: metrics, machine: machine, result: start)
        }
        defer { _ = runProcess(dockerArgs(context, ["rm", "-f", name]), timeoutSeconds: 20) }
        let payload = Data(repeating: 0x43, count: 64)
        let latency = waitForTCPEcho(port: port, payload: payload, timeoutSeconds: 15)
        metrics["latency_p50_ms"] = latency
        metrics["latency_p95_ms"] = latency
        metrics["latency_p99_ms"] = latency
        metrics["max_latency_ms"] = latency
        metrics["bytes"] = Double(payload.count)
        metrics["payload_size"] = Double(payload.count)
        return BenchmarkResult(
            workload: workload,
            runtime: context,
            command: command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: latency == nil ? 1 : 0,
            metrics: metrics,
            machine: machine,
            stderrTail: latency == nil ? "full TCP echo timed out" : ""
        )
    }

    private func runTCPKeepaliveEcho(context: String, sample: Int, machine: MachineProfile) -> BenchmarkResult {
        let startedAt = Date()
        let port = reservePort(type: SOCK_STREAM) ?? Int.random(in: 20_000...60_000)
        let name = "conjet-seg-keepalive-\(context)-\(sample)-\(shortID())"
        let script = "import socket\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',8080));s.listen(128)\nwhile True:\n c,_=s.accept()\n while True:\n  d=c.recv(65536)\n  if not d: break\n  c.sendall(d)\n c.close()\n"
        let command = dockerArgs(context, ["run", "--rm", "-d", "--name", name, "-p", "127.0.0.1:\(port):8080", "python:3.12-alpine", "python", "-u", "-c", script])
        var metrics = segmentMetrics(context: context, protocolName: "tcp", sample: sample)
        metrics.setString("full-tcp-forward-keepalive", for: "segment")
        metrics.setBool(true, for: "connection_reuse")
        let start = runProcess(command, timeoutSeconds: options.commandTimeoutSeconds)
        guard start.exitCode == 0 else {
            metrics.setString("container_start_failed", for: "failure_reason")
            return segmentFailure(workload: "tcp-keepalive-request-latency", runtime: context, command: command, startedAt: startedAt, metrics: metrics, machine: machine, result: start)
        }
        defer { _ = runProcess(dockerArgs(context, ["rm", "-f", name]), timeoutSeconds: 20) }
        let latencies = waitForTCPKeepaliveEcho(port: port, requests: 8, payload: Data(repeating: 0x31, count: 64), timeoutSeconds: 15)
        metrics["latency_p50_ms"] = percentile(latencies, 0.50)
        metrics["latency_p95_ms"] = percentile(latencies, 0.95)
        metrics["latency_p99_ms"] = percentile(latencies, 0.99)
        metrics["max_latency_ms"] = latencies.max()
        metrics["bytes"] = Double(64 * max(0, latencies.count))
        metrics["payload_size"] = 64
        return BenchmarkResult(
            workload: "tcp-keepalive-request-latency",
            runtime: context,
            command: command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: latencies.isEmpty ? 1 : 0,
            metrics: metrics,
            machine: machine,
            stderrTail: latencies.isEmpty ? "keepalive TCP echo failed" : ""
        )
    }

    private func runFullUDPForwardEcho(context: String, sample: Int, machine: MachineProfile) -> BenchmarkResult {
        let startedAt = Date()
        let port = reservePort(type: SOCK_DGRAM) ?? Int.random(in: 20_000...60_000)
        let name = "conjet-seg-udp-\(context)-\(sample)-\(shortID())"
        let script = "import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('0.0.0.0',5353))\nwhile True:\n data,addr=s.recvfrom(65507);s.sendto(data,addr)\n"
        let command = dockerArgs(context, ["run", "--rm", "-d", "--name", name, "-p", "127.0.0.1:\(port):5353/udp", "python:3.12-alpine", "python", "-u", "-c", script])
        var metrics = segmentMetrics(context: context, protocolName: "udp", sample: sample)
        metrics.setString("full-udp-forward", for: "segment")
        let start = runProcess(command, timeoutSeconds: options.commandTimeoutSeconds)
        guard start.exitCode == 0 else {
            metrics.setString("container_start_failed", for: "failure_reason")
            return segmentFailure(workload: "full-udp-forward-echo", runtime: context, command: command, startedAt: startedAt, metrics: metrics, machine: machine, result: start)
        }
        defer { _ = runProcess(dockerArgs(context, ["rm", "-f", name]), timeoutSeconds: 20) }
        let payload = Data(repeating: 0x55, count: 64)
        let latency = waitForUDPEcho(port: port, payload: payload, timeoutSeconds: 15)
        metrics["latency_p50_ms"] = latency
        metrics["latency_p95_ms"] = latency
        metrics["latency_p99_ms"] = latency
        metrics["max_latency_ms"] = latency
        metrics["bytes"] = Double(payload.count)
        metrics["payload_size"] = Double(payload.count)
        metrics["udp_packets_sent"] = 1
        metrics["udp_packets_received"] = latency == nil ? 0 : 1
        return BenchmarkResult(
            workload: "full-udp-forward-echo",
            runtime: context,
            command: command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: latency == nil ? 1 : 0,
            metrics: metrics,
            machine: machine,
            stderrTail: latency == nil ? "full UDP echo timed out" : ""
        )
    }

    private func skippedSegment(context: String, workload: String, sample: Int, machine: MachineProfile) -> BenchmarkResult {
        var metrics = segmentMetrics(context: context, protocolName: "tcp", sample: sample)
        metrics.setBool(true, for: "skipped")
        metrics.setString("segment_unavailable_without_guest_echo_endpoint", for: "failure_reason")
        return BenchmarkResult(
            workload: workload,
            runtime: context,
            command: ["network-segments", workload],
            startedAt: Date(),
            durationSeconds: 0,
            exitCode: 0,
            metrics: metrics,
            machine: machine,
            stderrTail: "segment requires a guest echo endpoint not present in this image"
        )
    }

    private func segmentFailure(
        workload: String,
        runtime: String,
        command: [String],
        startedAt: Date,
        metrics: BenchmarkMetrics,
        machine: MachineProfile,
        result: ProcessResult
    ) -> BenchmarkResult {
        BenchmarkResult(
            workload: workload,
            runtime: runtime,
            command: command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: result.exitCode,
            metrics: metrics,
            machine: machine,
            stdoutTail: tail(result.stdout),
            stderrTail: tail(result.stderr)
        )
    }

    private func segmentMetrics(context: String, protocolName: String, sample: Int) -> BenchmarkMetrics {
        var metrics = BenchmarkMetrics()
        let conjetBridge = context == "conjet" ? activeConjetBridgeMetadata() : nil
        let bridgeEngine = conjetBridge?.bridgeEngine ?? (context == "conjet" ? "python-legacy" : "runtime-native")
        let binaryFrames = conjetBridge?.binaryFrames ?? false
        let udpBinaryFrames = conjetBridge?.udpBinaryFrames ?? false
        let persistentVsock = conjetBridge?.persistentVsock ?? false
        let tcpMode = conjetBridge?.tcpMode ?? (context == "conjet" ? "legacy-tcp-proxy" : "runtime-native")
        let udpMode = conjetBridge?.udpMode ?? (context == "conjet" ? (persistentVsock ? "persistent-binary-udp" : "legacy-udp-proxy") : "runtime-native")
        let tcpBinaryFrames = conjetBridge?.tcpBinaryFrames ?? false
        let persistentTCPVsock = conjetBridge?.persistentTCPVsock ?? false
        let tcpVsockPool = conjetBridge?.tcpVsockPool ?? false
        let pythonFallbackActive = conjetBridge?.pythonFallbackActive ?? (context == "conjet")
        metrics["sample_index"] = Double(sample)
        metrics.setString(protocolName, for: "protocol")
        metrics.setString(context == "conjet" ? "proxy-gcd-evented" : "runtime-native", for: "proxy_engine")
        metrics.setString(bridgeEngine, for: "bridge_engine")
        metrics.setString(context == "conjet" ? tcpMode : "runtime-native", for: "vsock_mode")
        metrics.setString(tcpMode, for: "tcp_mode")
        metrics.setString(udpMode, for: "udp_mode")
        metrics.setString(bridgeEngine, for: "guest_bridge_engine")
        metrics.setBool(false, for: "tcp_mux_enabled")
        metrics.setString(context == "conjet" ? (udpBinaryFrames ? "binary-v1" : "legacy") : "runtime-native", for: "udp_frame_format")
        metrics.setBool(binaryFrames, for: "binary_frames")
        metrics.setBool(udpBinaryFrames, for: "udp_binary_frames")
        metrics.setBool(persistentVsock, for: "persistent_vsock")
        metrics.setBool(tcpBinaryFrames, for: "tcp_binary_frames")
        metrics.setBool(persistentTCPVsock, for: "persistent_tcp_vsock")
        metrics.setBool(tcpVsockPool, for: "tcp_vsock_pool")
        metrics.setBool(pythonFallbackActive, for: "python_fallback_active")
        metrics.setNull(for: "latency_p50_ms")
        metrics.setNull(for: "latency_p95_ms")
        metrics.setNull(for: "latency_p99_ms")
        metrics.setNull(for: "max_latency_ms")
        metrics.setNull(for: "bytes")
        metrics.setNull(for: "payload_size")
        metrics.setNull(for: "failure_reason")
        metrics.setNull(for: "vsock_connections_opened")
        metrics.setNull(for: "vsock_connections_reused")
        metrics.setNull(for: "mux_streams_opened")
        metrics.setNull(for: "mux_active_streams")
        metrics.setNull(for: "backpressure_events")
        return metrics
    }

    private func measureUnixHTTP(path: String, expectedBody: String) -> Double? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        setSegmentSocketTimeout(fd, timeoutSeconds: 2)
        let socketPath = conjetDockerSocketPath()
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let started = Date()
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                Darwin.connect(fd, sockaddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let request = Data("GET \(path) HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n".utf8)
        guard writeAllBenchmarkBytes(request, to: fd) else { return nil }
        Darwin.shutdown(fd, SHUT_WR)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        guard let text = String(data: data, encoding: .utf8),
              text.contains("200 OK"),
              text.hasSuffix(expectedBody) else {
            return nil
        }
        return Date().timeIntervalSince(started) * 1_000
    }

    private func measureBinaryPing(payload: Data) -> Double? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        setSegmentSocketTimeout(fd, timeoutSeconds: 2)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = conjetDockerSocketPath().utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                Darwin.connect(fd, sockaddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let frame = ConjetBinaryFrame(type: .ping, streamID: 1, payload: payload)
        guard let encoded = try? frame.encode() else { return nil }
        let started = Date()
        guard writeAllBenchmarkBytes(encoded, to: fd) else { return nil }
        var header = [UInt8](repeating: 0, count: ConjetBinaryFrame.headerSize)
        guard Darwin.read(fd, &header, header.count) == header.count else { return nil }
        let payloadLength = Int(UInt32(header[16]) << 24 | UInt32(header[17]) << 16 | UInt32(header[18]) << 8 | UInt32(header[19]))
        guard payloadLength >= 0, payloadLength <= ConjetBinaryFrame.maxPayloadBytes else { return nil }
        var body = [UInt8](repeating: 0, count: payloadLength)
        if payloadLength > 0 {
            guard Darwin.read(fd, &body, body.count) == body.count else { return nil }
        }
        let data = Data(header + body)
        guard let decoded = try? ConjetBinaryFrame.decode(data),
              decoded.type == .pong,
              decoded.payload == payload else {
            return nil
        }
        return Date().timeIntervalSince(started) * 1_000
    }

    private func conjetDockerSocketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CONJET_DOCKER_SOCKET"], !override.isEmpty {
            return override
        }
        let home = ProcessInfo.processInfo.environment["CONJET_HOME"]
            ?? "\(NSHomeDirectory())/.conjet"
        return "\(home)/run/docker.sock"
    }

    private func activeConjetBridgeMetadata() -> (
        bridgeEngine: String,
        binaryFrames: Bool,
        udpBinaryFrames: Bool,
        persistentVsock: Bool,
        tcpMode: String,
        udpMode: String,
        tcpBinaryFrames: Bool,
        persistentTCPVsock: Bool,
        tcpVsockPool: Bool,
        pythonFallbackActive: Bool
    )? {
        let result = runProcess(["/usr/bin/env", "swift", "run", "conjet", "network", "status", "--json"], timeoutSeconds: 15)
        guard result.exitCode == 0 else { return nil }
        let text = result.stdout
        let compact = text.filter { !$0.isWhitespace }
        return (
            bridgeEngine: jsonStringField("bridgeEngine", in: text) ?? "python-legacy",
            binaryFrames: compact.contains(#""binaryFrames":true"#) || compact.contains(#""binary_frames":true"#),
            udpBinaryFrames: compact.contains(#""udpBinaryFrames":true"#) || compact.contains(#""udp_binary_frames":true"#),
            persistentVsock: compact.contains(#""persistentVsock":true"#) || compact.contains(#""persistent_vsock":true"#),
            tcpMode: jsonStringField("tcpMode", in: text) ?? "legacy-tcp-proxy",
            udpMode: jsonStringField("udpMode", in: text) ?? "legacy-udp-proxy",
            tcpBinaryFrames: compact.contains(#""tcpBinaryFrames":true"#) || compact.contains(#""tcp_binary_frames":true"#),
            persistentTCPVsock: compact.contains(#""persistentTCPVsock":true"#) || compact.contains(#""persistent_tcp_vsock":true"#),
            tcpVsockPool: compact.contains(#""tcpVsockPool":true"#) || compact.contains(#""tcp_vsock_pool":true"#),
            pythonFallbackActive: compact.contains(#""pythonFallbackActive":true"#) || compact.contains(#""python_fallback_active":true"#)
        )
    }

    private func jsonStringField(_ field: String, in text: String) -> String? {
        guard let fieldRange = text.range(of: "\"\(field)\"") else { return nil }
        let suffix = text[fieldRange.upperBound...]
        guard let colon = suffix.firstIndex(of: ":") else { return nil }
        let afterColon = suffix[suffix.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard afterColon.first == "\"" else { return nil }
        let body = afterColon.dropFirst()
        guard let end = body.firstIndex(of: "\"") else { return nil }
        return String(body[..<end])
    }

    private func waitForTCPEcho(port: Int, payload: Data, timeoutSeconds: Double) -> Double? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let latency = measureTCPEcho(port: port, payload: payload) {
                return latency
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private func measureTCPEcho(port: Int, payload: Data) -> Double? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        setSegmentSocketTimeout(fd, timeoutSeconds: 1)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let started = Date()
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                Darwin.connect(fd, sockaddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0, writeAllBenchmarkBytes(payload, to: fd) else { return nil }
        var buffer = [UInt8](repeating: 0, count: payload.count)
        let read = Darwin.read(fd, &buffer, buffer.count)
        guard read == payload.count, Data(buffer) == payload else { return nil }
        return Date().timeIntervalSince(started) * 1_000
    }

    private func waitForTCPKeepaliveEcho(port: Int, requests: Int, payload: Data, timeoutSeconds: Double) -> [Double] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let latencies = measureTCPKeepaliveEcho(port: port, requests: requests, payload: payload)
            if !latencies.isEmpty {
                return latencies
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return []
    }

    private func measureTCPKeepaliveEcho(port: Int, requests: Int, payload: Data) -> [Double] {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }
        setSegmentSocketTimeout(fd, timeoutSeconds: 2)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                Darwin.connect(fd, sockaddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return [] }
        var latencies: [Double] = []
        for _ in 0..<requests {
            let started = Date()
            guard writeAllBenchmarkBytes(payload, to: fd) else { break }
            var buffer = [UInt8](repeating: 0, count: payload.count)
            let read = Darwin.read(fd, &buffer, buffer.count)
            guard read == payload.count, Data(buffer) == payload else { break }
            latencies.append(Date().timeIntervalSince(started) * 1_000)
        }
        return latencies
    }

    private func waitForUDPEcho(port: Int, payload: Data, timeoutSeconds: Double) -> Double? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let latency = measureUDPEcho(port: port, payload: payload) {
                return latency
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private func measureUDPEcho(port: Int, payload: Data) -> Double? {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        setSegmentSocketTimeout(fd, timeoutSeconds: 1)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let started = Date()
        let sent = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                    Darwin.sendto(fd, base, payload.count, 0, sockaddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: payload.count)
        let read = Darwin.read(fd, &buffer, buffer.count)
        guard read == payload.count, Data(buffer) == payload else { return nil }
        return Date().timeIntervalSince(started) * 1_000
    }

    private func dockerArgs(_ context: String, _ arguments: [String]) -> [String] {
        ["/usr/bin/env", "docker", "--context", context] + arguments
    }

    private func runProcess(_ command: [String], timeoutSeconds: Double?) -> ProcessResult {
        guard let executable = command.first else {
            return ProcessResult(executable: "", arguments: [], exitCode: 127, stdout: "", stderr: "empty command")
        }
        do {
            return try ProcessRunner.run(executable, Array(command.dropFirst()), timeoutSeconds: timeoutSeconds)
        } catch {
            return ProcessResult(executable: executable, arguments: Array(command.dropFirst()), exitCode: 127, stdout: "", stderr: String(describing: error))
        }
    }

    private func reservePort(type: Int32) -> Int? {
        let fd = Darwin.socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                Darwin.bind(fd, sockaddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                Darwin.getsockname(fd, sockaddr, &length)
            }
        }
        guard nameResult == 0 else { return nil }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * quantile).rounded(.down))))
        return sorted[index]
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        text.count <= limit ? text : String(text.suffix(limit))
    }

    private func shortID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

private final class LocalTCPEchoServer {
    let port: Int
    private let fd: Int32
    private let queue = DispatchQueue(label: "dev.conjet.segment-local-echo", qos: .userInitiated)
    private var source: DispatchSourceRead?

    init() throws {
        let listenerFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw ConjetError.socket("socket failed")
        }
        var reuse: Int32 = 1
        setsockopt(listenerFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                Darwin.bind(listenerFD, sockaddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenerFD, 64) == 0 else {
            Darwin.close(listenerFD)
            throw ConjetError.socket("bind/listen failed")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                Darwin.getsockname(listenerFD, sockaddr, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(listenerFD)
            throw ConjetError.socket("getsockname failed")
        }
        self.fd = listenerFD
        self.port = Int(UInt16(bigEndian: actual.sin_port))
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
        source.setEventHandler { [listenerFD] in
            while true {
                let client = Darwin.accept(listenerFD, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(client, &buffer, buffer.count)
                        if count > 0 {
                            _ = Darwin.write(client, buffer, count)
                        } else {
                            break
                        }
                    }
                    Darwin.close(client)
                }
            }
        }
        source.setCancelHandler { [listenerFD] in Darwin.close(listenerFD) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

private func setSegmentSocketTimeout(_ fd: Int32, timeoutSeconds: Double) {
    let seconds = Int(timeoutSeconds)
    let microseconds = Int((timeoutSeconds - Double(seconds)) * 1_000_000)
    var timeout = timeval(tv_sec: seconds, tv_usec: Int32(microseconds))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func writeAllBenchmarkBytes(_ data: Data, to fd: Int32) -> Bool {
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

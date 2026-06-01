import ConjetCore
import Darwin
import Dispatch
import Foundation

public struct NetworkBenchmarkOptions: Sendable {
    public var contexts: [String]
    public var samples: Int
    public var commandTimeoutSeconds: Double
    public var workloads: [String]
    public var runtimeLabels: [String: String]
    public var proxyEngineLabels: [String: String]

    public init(
        contexts: [String],
        samples: Int,
        commandTimeoutSeconds: Double = 60,
        workloads: [String] = NetworkBenchmarkSuite.defaultWorkloads,
        runtimeLabels: [String: String] = [:],
        proxyEngineLabels: [String: String] = [:]
    ) {
        self.contexts = contexts
        self.samples = max(1, samples)
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.workloads = workloads
        self.runtimeLabels = runtimeLabels
        self.proxyEngineLabels = proxyEngineLabels
    }
}

public struct NetworkBenchmarkSuite: Sendable {
    public static let defaultWorkloads = [
        "port-publication-latency",
        "tcp-localhost-latency-c1",
        "http-localhost-c100",
        "udp-echo-latency"
    ]

    private let options: NetworkBenchmarkOptions

    public init(options: NetworkBenchmarkOptions) {
        self.options = options
    }

    public func run(outputDirectory: URL) throws -> [BenchmarkResult] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var results: [BenchmarkResult] = []
        let machine = MachineProfiler.capture(cacheTTLSeconds: 60)

        for context in options.contexts {
            for sample in 0..<options.samples {
                if containsTCPWorkload {
                    results.append(contentsOf: runTCPContext(context, sample: sample, machine: machine))
                }
                if containsUDPWorkload {
                    results.append(contentsOf: runUDPContext(context, sample: sample, machine: machine))
                }
                if options.workloads.contains("tcp-throughput-iperf3") ||
                    options.workloads.contains("tcp-throughput-parallel-iperf3") {
                    results.append(contentsOf: skippedIperfResults(context: context, sample: sample, machine: machine))
                }
            }
        }
        return results
    }

    private var containsTCPWorkload: Bool {
        options.workloads.contains("port-publication-latency") ||
            options.workloads.contains("port-publication-breakdown") ||
            options.workloads.contains("tcp-localhost-latency-c1") ||
            options.workloads.contains { $0.hasPrefix("http-localhost-c") }
    }

    private var containsUDPWorkload: Bool {
        options.workloads.contains {
            $0 == "udp-echo-latency" ||
                $0.hasPrefix("udp-echo-") ||
                $0 == "udp-throughput" ||
                $0 == "udp-packet-loss"
        }
    }

    private var udpEchoWorkloads: [String] {
        let selected = options.workloads.filter { $0 == "udp-echo-latency" || $0.hasPrefix("udp-echo-") }
        return selected.isEmpty && containsUDPWorkload ? ["udp-echo-latency"] : selected
    }

    private func runTCPContext(_ context: String, sample: Int, machine: MachineProfile) -> [BenchmarkResult] {
        let startedAt = Date()
        let runtime = runtimeName(for: context)
        let port = reserveTCPPort() ?? Int.random(in: 20_000...60_000)
        let name = "conjet-net-tcp-\(context)-\(sample)-\(shortID())"
        var command = dockerArgs(context, ["run", "--rm", "-d", "--name", name, "-p", "127.0.0.1:\(port):80", "nginx:alpine"])
        var metrics = baseMetrics(protocolName: "tcp", context: context)
        metrics["sample_index"] = Double(sample)

        let startResult = runProcess(command, timeoutSeconds: options.commandTimeoutSeconds)
        if startResult.exitCode != 0 {
            metrics.setString("container_start_failed", for: "failure_reason")
            return [
                BenchmarkResult(
                    workload: "port-publication-latency",
                    runtime: runtime,
                    command: command,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    exitCode: startResult.exitCode,
                    metrics: metrics,
                    machine: machine,
                    stdoutTail: tail(startResult.stdout),
                    stderrTail: tail(startResult.stderr)
                )
            ]
        }
        defer { _ = runProcess(dockerArgs(context, ["rm", "-f", name]), timeoutSeconds: 20) }

        let publication = waitForHTTP(port: port, timeoutSeconds: 20)
        var results: [BenchmarkResult] = []
        if options.workloads.contains("port-publication-latency") || options.workloads.contains("port-publication-breakdown") {
            var publicationMetrics = metrics
            addPublicationMetrics(&publicationMetrics, durationSeconds: publication.durationSeconds)
            if options.workloads.contains("port-publication-latency") {
                results.append(BenchmarkResult(
                    workload: "port-publication-latency",
                    runtime: runtime,
                    command: command,
                    startedAt: startedAt,
                    durationSeconds: publication.durationSeconds,
                    exitCode: publication.result.exitCode,
                    metrics: publicationMetrics,
                    machine: machine,
                    stdoutTail: tail(publication.result.stdout),
                    stderrTail: tail(publication.result.stderr)
                ))
            }
            if options.workloads.contains("port-publication-breakdown") {
                publicationMetrics.setString("publication_breakdown", for: "trace_type")
                results.append(BenchmarkResult(
                    workload: "port-publication-breakdown",
                    runtime: runtime,
                    command: command,
                    startedAt: startedAt,
                    durationSeconds: publication.durationSeconds,
                    exitCode: publication.result.exitCode,
                    metrics: publicationMetrics,
                    machine: machine,
                    stdoutTail: tail(publication.result.stdout),
                    stderrTail: tail(publication.result.stderr)
                ))
            }
        }

        guard publication.result.exitCode == 0 else {
            return results
        }

        if options.workloads.contains("tcp-localhost-latency-c1") {
            let latencyStartedAt = Date()
            command = ["/usr/bin/curl", "-fsS", "-o", "/dev/null", "-w", "%{time_total}", "http://127.0.0.1:\(port)/"]
            let latency = runProcess(command, timeoutSeconds: 10)
            let latencySeconds = Double(latency.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date().timeIntervalSince(latencyStartedAt)
            var latencyMetrics = metrics
            latencyMetrics["latency_p50_ms"] = latencySeconds * 1_000
            latencyMetrics["latency_p95_ms"] = latencySeconds * 1_000
            latencyMetrics["latency_p99_ms"] = latencySeconds * 1_000
            latencyMetrics["max_latency_ms"] = latencySeconds * 1_000
            latencyMetrics["failed_connections"] = latency.exitCode == 0 ? 0 : 1
            results.append(BenchmarkResult(
                workload: "tcp-localhost-latency-c1",
                runtime: runtime,
                command: command,
                startedAt: latencyStartedAt,
                durationSeconds: Date().timeIntervalSince(latencyStartedAt),
                exitCode: latency.exitCode,
                metrics: latencyMetrics,
                machine: machine,
                stdoutTail: tail(latency.stdout),
                stderrTail: tail(latency.stderr)
            ))
        }

        for workload in options.workloads.filter({ $0.hasPrefix("http-localhost-c") }).sorted() {
            results.append(runHTTPConcurrency(
                context: context,
                workload: workload,
                port: port,
                concurrency: concurrencyValue(from: workload),
                keepalive: workload.hasSuffix("-keepalive"),
                baseMetrics: metrics,
                runtime: runtime,
                machine: machine
            ))
        }
        return results
    }

    private func runUDPContext(_ context: String, sample: Int, machine: MachineProfile) -> [BenchmarkResult] {
        let startedAt = Date()
        let runtime = runtimeName(for: context)
        let port = reserveUDPPort() ?? Int.random(in: 20_000...60_000)
        let name = "conjet-net-udp-\(context)-\(sample)-\(shortID())"
        let script = "import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\ns.bind(('0.0.0.0',5353))\nwhile True:\n data,addr=s.recvfrom(65507)\n s.sendto(data,addr)\n"
        let runCommand = dockerArgs(context, [
            "run", "--rm", "-d", "--name", name,
            "-p", "127.0.0.1:\(port):5353/udp",
            "python:3.12-alpine",
            "python", "-u", "-c", script
        ])
        var metrics = baseMetrics(protocolName: "udp", context: context)
        metrics["sample_index"] = Double(sample)

        let start = runProcess(runCommand, timeoutSeconds: options.commandTimeoutSeconds)
        guard start.exitCode == 0 else {
            metrics.setString("container_start_failed", for: "failure_reason")
            return udpFailureResults(runtime: runtime, workloads: udpEchoWorkloads, command: runCommand, startedAt: startedAt, exitCode: start.exitCode, metrics: metrics, machine: machine, stdout: start.stdout, stderr: start.stderr)
        }
        defer { _ = runProcess(dockerArgs(context, ["rm", "-f", name]), timeoutSeconds: 20) }

        let readinessPayloadBytes = udpPayloadBytes(for: udpEchoWorkloads.first ?? "udp-echo-latency")
        let readiness = waitForUDP(port: port, timeoutSeconds: 15, payloadBytes: readinessPayloadBytes)
        guard readiness.result.exitCode == 0 else {
            metrics["udp_packet_loss"] = 1
            metrics["failed_connections"] = 1
            metrics["udp_readiness_latency_ms"] = readiness.durationSeconds * 1_000
            metrics.setString("udp_echo_not_ready", for: "failure_reason")
            return udpFailureResults(runtime: runtime, workloads: udpEchoWorkloads, command: readiness.command, startedAt: startedAt, exitCode: readiness.result.exitCode, metrics: metrics, machine: machine, stdout: readiness.result.stdout, stderr: readiness.result.stderr)
        }

        var results: [BenchmarkResult] = []
        for workload in udpEchoWorkloads {
            let payloadBytes = udpPayloadBytes(for: workload)
            let command = udpEchoCommand(port: port, timeoutSeconds: 3, payloadBytes: payloadBytes)
            let echoStartedAt = Date()
            let echo = runProcess(command, timeoutSeconds: 5)
            let latencyMS = Double(echo.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            var echoMetrics = metrics
            echoMetrics["latency_p50_ms"] = latencyMS
            echoMetrics["latency_p95_ms"] = latencyMS
            echoMetrics["latency_p99_ms"] = latencyMS
            echoMetrics["max_latency_ms"] = latencyMS
            echoMetrics["udp_latency_p50_ms"] = latencyMS
            echoMetrics["udp_latency_p95_ms"] = latencyMS
            echoMetrics["udp_latency_p99_ms"] = latencyMS
            echoMetrics["udp_packet_loss"] = echo.exitCode == 0 ? 0 : 1
            echoMetrics["failed_connections"] = echo.exitCode == 0 ? 0 : 1
            echoMetrics["payload_bytes"] = Double(payloadBytes)
            echoMetrics["udp_packets_sent"] = 1
            echoMetrics["udp_packets_received"] = echo.exitCode == 0 ? 1 : 0
            if echo.exitCode != 0 {
                echoMetrics.setString("udp_echo_timeout", for: "failure_reason")
            }
            addHelperCPUMetrics(&echoMetrics, context: context)
            results.append(BenchmarkResult(
                workload: workload,
                runtime: runtime,
                command: command,
                startedAt: echoStartedAt,
                durationSeconds: Date().timeIntervalSince(echoStartedAt),
                exitCode: echo.exitCode,
                metrics: echoMetrics,
                machine: machine,
                stdoutTail: tail(echo.stdout),
                stderrTail: tail(echo.stderr)
            ))
        }

        if options.workloads.contains("udp-throughput") || options.workloads.contains("udp-packet-loss") {
            results.append(runUDPThroughput(runtime: runtime, port: port, baseMetrics: metrics, machine: machine))
        }
        return results
    }

    private func runHTTPConcurrency(
        context: String,
        workload: String,
        port: Int,
        concurrency: Int,
        keepalive: Bool,
        baseMetrics: BenchmarkMetrics,
        runtime: String,
        machine: MachineProfile
    ) -> BenchmarkResult {
        let startedAt = Date()
        let requestCount = max(1, concurrency)
        let recorder = ConcurrentLatencyRecorder()
        if keepalive {
            let result = measureKeepaliveHTTP(port: port, requests: requestCount)
            for latency in result.latencies {
                recorder.record(latency)
            }
            for _ in 0..<result.failures {
                recorder.record(nil)
            }
        } else {
            let queue = DispatchQueue(label: "dev.conjet.network-http-bench", attributes: .concurrent)
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: max(1, concurrency))

            for _ in 0..<requestCount {
                semaphore.wait()
                group.enter()
                queue.async {
                    let result = self.measureSingleHTTP(port: port)
                    recorder.record(result)
                    semaphore.signal()
                    group.leave()
                }
            }
            group.wait()
        }

        let duration = max(Date().timeIntervalSince(startedAt), 0.000_001)
        let snapshot = recorder.snapshot()
        let failures = snapshot.failures
        let sorted = snapshot.latencies.sorted()
        var metrics = baseMetrics
        metrics["concurrency"] = Double(concurrency)
        metrics["duration_seconds"] = duration
        metrics["requests_per_second"] = Double(sorted.count) / duration
        metrics["failed_requests"] = Double(failures)
        metrics["failed_connections"] = Double(failures)
        metrics.setBool(keepalive, for: "keepalive")
        metrics.setBool(keepalive, for: "connection_reuse")
        metrics.setBool(!keepalive, for: "new_connection_per_request")
        metrics["latency_p50_ms"] = percentile(sorted, 0.50)
        metrics["latency_p95_ms"] = percentile(sorted, 0.95)
        metrics["latency_p99_ms"] = percentile(sorted, 0.99)
        metrics["max_latency_ms"] = sorted.last
        if failures > 0 {
            metrics.setString("http_request_failures", for: "failure_reason")
        }
        addHelperCPUMetrics(&metrics, context: context)
        return BenchmarkResult(
            workload: workload,
            runtime: runtime,
            command: ["builtin-http-client", "http://127.0.0.1:\(port)/", "--concurrency", String(concurrency)],
            startedAt: startedAt,
            durationSeconds: duration,
            exitCode: failures == 0 ? 0 : 1,
            metrics: metrics,
            machine: machine,
            stdoutTail: "",
            stderrTail: failures == 0 ? "" : "\(failures) HTTP requests failed"
        )
    }

    private func runUDPThroughput(
        runtime: String,
        port: Int,
        baseMetrics: BenchmarkMetrics,
        machine: MachineProfile
    ) -> BenchmarkResult {
        let startedAt = Date()
        let packets = 256
        let payloadBytes = 512
        let command = udpThroughputCommand(port: port, timeoutSeconds: 1, payloadBytes: payloadBytes, packets: packets)
        let result = runProcess(command, timeoutSeconds: 10)
        var metrics = baseMetrics
        metrics["payload_bytes"] = Double(payloadBytes)
        metrics["udp_packets_sent"] = Double(packets)
        if let data = result.stdout.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            metrics["udp_packets_received"] = parsed["received"]
            metrics["packet_loss_percent"] = parsed["loss_percent"]
            metrics["throughput_mbps"] = parsed["throughput_mbps"]
            metrics["latency_p50_ms"] = parsed["latency_p50_ms"]
            metrics["latency_p95_ms"] = parsed["latency_p95_ms"]
            metrics["latency_p99_ms"] = parsed["latency_p99_ms"]
        }
        if result.exitCode != 0 {
            metrics.setString("udp_throughput_failed", for: "failure_reason")
        }
        return BenchmarkResult(
            workload: options.workloads.contains("udp-throughput") ? "udp-throughput" : "udp-packet-loss",
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

    private func skippedIperfResults(context: String, sample: Int, machine: MachineProfile) -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        let runtime = runtimeName(for: context)
        for workload in ["tcp-throughput-iperf3", "tcp-throughput-parallel-iperf3"] where options.workloads.contains(workload) {
            var metrics = baseMetrics(protocolName: "tcp", context: context)
            metrics["sample_index"] = Double(sample)
            metrics.setBool(true, for: "skipped")
            metrics.setString("iperf3_not_available_in_builtin_gate", for: "failure_reason")
            results.append(BenchmarkResult(
                workload: workload,
                runtime: runtime,
                command: ["iperf3"],
                startedAt: Date(),
                durationSeconds: 0,
                exitCode: 0,
                metrics: metrics,
                machine: machine,
                stdoutTail: "",
                stderrTail: "iperf3 workload skipped by built-in gate"
            ))
        }
        return results
    }

    private func udpFailureResults(
        runtime: String,
        workloads: [String],
        command: [String],
        startedAt: Date,
        exitCode: Int32,
        metrics: BenchmarkMetrics,
        machine: MachineProfile,
        stdout: String,
        stderr: String
    ) -> [BenchmarkResult] {
        let selected = workloads.isEmpty ? ["udp-echo-latency"] : workloads
        return selected.map { workload in
            BenchmarkResult(
                workload: workload,
                runtime: runtime,
                command: command,
                startedAt: startedAt,
                durationSeconds: Date().timeIntervalSince(startedAt),
                exitCode: exitCode,
                metrics: metrics,
                machine: machine,
                stdoutTail: tail(stdout),
                stderrTail: tail(stderr)
            )
        }
    }

    private func waitForUDP(port: Int, timeoutSeconds: Double, payloadBytes: Int) -> (result: ProcessResult, command: [String], durationSeconds: Double) {
        let startedAt = Date()
        var command = udpEchoCommand(port: port, timeoutSeconds: 1.0, payloadBytes: payloadBytes)
        var last = ProcessResult(executable: command[0], arguments: Array(command.dropFirst()), exitCode: 1, stdout: "", stderr: "not attempted")
        while Date().timeIntervalSince(startedAt) < timeoutSeconds {
            command = udpEchoCommand(port: port, timeoutSeconds: 1.0, payloadBytes: payloadBytes)
            last = runProcess(command, timeoutSeconds: 2)
            if last.exitCode == 0 {
                Thread.sleep(forTimeInterval: 0.15)
                return (last, command, Date().timeIntervalSince(startedAt))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return (last, command, Date().timeIntervalSince(startedAt))
    }

    private func udpEchoCommand(port: Int, timeoutSeconds: Double, payloadBytes: Int) -> [String] {
        let clientScript = """
        import socket,sys,time
        p=int(sys.argv[1])
        timeout=float(sys.argv[2])
        payload=b'x'*int(sys.argv[3])
        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        s.settimeout(timeout)
        t=time.perf_counter()
        try:
            s.sendto(payload,('127.0.0.1',p))
            d,_=s.recvfrom(65507)
        except TimeoutError:
            print('udp echo timed out', file=sys.stderr)
            sys.exit(3)
        print((time.perf_counter()-t)*1000)
        sys.exit(0 if d==payload else 2)
        """
        return ["/usr/bin/env", "python3", "-c", clientScript, String(port), String(timeoutSeconds), String(payloadBytes)]
    }

    private func udpThroughputCommand(port: Int, timeoutSeconds: Double, payloadBytes: Int, packets: Int) -> [String] {
        let clientScript = """
        import json,socket,sys,time
        p=int(sys.argv[1]); timeout=float(sys.argv[2]); payload=b'x'*int(sys.argv[3]); packets=int(sys.argv[4])
        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(timeout)
        lat=[]; received=0; started=time.perf_counter()
        for _ in range(packets):
            t=time.perf_counter()
            try:
                s.sendto(payload,('127.0.0.1',p))
                d,_=s.recvfrom(65507)
                if d==payload:
                    received+=1; lat.append((time.perf_counter()-t)*1000)
            except TimeoutError:
                pass
        duration=max(time.perf_counter()-started, 0.000001)
        lat.sort()
        def pct(q):
            if not lat: return None
            return lat[min(len(lat)-1, int(len(lat)*q))]
        print(json.dumps({
            "received": received,
            "loss_percent": ((packets-received)/packets)*100,
            "throughput_mbps": (received*len(payload)*8)/(duration*1000*1000),
            "latency_p50_ms": pct(0.50),
            "latency_p95_ms": pct(0.95),
            "latency_p99_ms": pct(0.99)
        }))
        sys.exit(0 if received == packets else 1)
        """
        return ["/usr/bin/env", "python3", "-c", clientScript, String(port), String(timeoutSeconds), String(payloadBytes), String(packets)]
    }

    private func waitForHTTP(port: Int, timeoutSeconds: Double) -> (result: ProcessResult, durationSeconds: Double) {
        let startedAt = Date()
        var last = ProcessResult(executable: "benchmark-http-probe", arguments: [], exitCode: 1, stdout: "", stderr: "not attempted")
        while Date().timeIntervalSince(startedAt) < timeoutSeconds {
            if let milliseconds = measureSingleHTTP(port: port) {
                last = ProcessResult(
                    executable: "benchmark-http-probe",
                    arguments: ["127.0.0.1", String(port)],
                    exitCode: 0,
                    stdout: String(format: "%.3f ms", milliseconds),
                    stderr: ""
                )
                return (last, Date().timeIntervalSince(startedAt))
            }
            last = ProcessResult(
                executable: "benchmark-http-probe",
                arguments: ["127.0.0.1", String(port)],
                exitCode: 1,
                stdout: "",
                stderr: "connection not ready"
            )
            Thread.sleep(forTimeInterval: 0.002)
        }
        return (last, Date().timeIntervalSince(startedAt))
    }

    private func addPublicationMetrics(_ metrics: inout BenchmarkMetrics, durationSeconds: Double) {
        let milliseconds = durationSeconds * 1_000
        metrics["port_publication_latency_ms"] = milliseconds
        metrics["total_publication_ms"] = milliseconds
        metrics["port_publication_listener_visible_ms"] = milliseconds
        metrics["port_publication_first_connect_ms"] = milliseconds
        metrics["first_connect_success_ms"] = milliseconds
        metrics["latency_p50_ms"] = milliseconds
        metrics["latency_p95_ms"] = milliseconds
        metrics["latency_p99_ms"] = milliseconds
        metrics["max_latency_ms"] = milliseconds
        metrics.setNull(for: "docker_event_to_inspect_ms")
        metrics.setNull(for: "inspect_duration_ms")
        metrics.setNull(for: "policy_resolution_ms")
        metrics.setNull(for: "capability_check_ms")
        metrics.setNull(for: "host_listener_bind_ms")
        metrics.setNull(for: "guest_proxy_registration_ms")
        metrics.setNull(for: "state_store_update_ms")
    }

    private func measureSingleHTTP(port: Int) -> Double? {
        let started = Date()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        setBenchmarkSocketTimeout(fd, timeoutSeconds: 3)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let request = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
        guard writeAllBenchmarkBytes(request, to: fd) else { return nil }
        return readHTTPResponseHeaderAndBody(from: fd) ? Date().timeIntervalSince(started) * 1_000 : nil
    }

    private func measureKeepaliveHTTP(port: Int, requests: Int) -> (latencies: [Double], failures: Int) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return ([], requests) }
        defer { Darwin.close(fd) }

        setBenchmarkSocketTimeout(fd, timeoutSeconds: 5)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return ([], requests) }

        var latencies: [Double] = []
        var failures = 0
        for index in 0..<requests {
            let close = index == requests - 1
            let request = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: \(close ? "close" : "keep-alive")\r\n\r\n".utf8)
            let started = Date()
            guard writeAllBenchmarkBytes(request, to: fd), readHTTPResponseHeaderAndBody(from: fd) else {
                failures += 1
                break
            }
            latencies.append(Date().timeIntervalSince(started) * 1_000)
        }
        failures += max(0, requests - latencies.count - failures)
        return (latencies, failures)
    }

    private func concurrencyValue(from workload: String) -> Int {
        let raw = workload
            .replacingOccurrences(of: "http-localhost-c", with: "")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? "1"
        return Int(raw) ?? 1
    }

    private func udpPayloadBytes(for workload: String) -> Int {
        switch workload {
        case "udp-echo-32b":
            return 32
        case "udp-echo-512b":
            return 512
        case "udp-echo-1400b":
            return 1_400
        case "udp-echo-8192b":
            return 8_192
        default:
            return 10
        }
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let index = min(values.count - 1, max(0, Int((Double(values.count) * quantile).rounded(.down))))
        return values[index]
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

    private func reserveTCPPort() -> Int? {
        reservePort(type: SOCK_STREAM)
    }

    private func reserveUDPPort() -> Int? {
        reservePort(type: SOCK_DGRAM)
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
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(fd, socketAddress, &length)
            }
        }
        guard nameResult == 0 else { return nil }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func baseMetrics(protocolName: String, context: String) -> BenchmarkMetrics {
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
        metrics.setString(protocolName, for: "protocol")
        metrics.setString("localhost", for: "network_scope")
        metrics.setString(context, for: "docker_context")
        metrics.setString(context == "conjet" ? "secure-local" : "runtime-native", for: "bind_policy")
        metrics.setString(proxyEngineName(for: context), for: "proxy_engine")
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
        metrics.setBool(context == "conjet", for: "conjet_context")
        metrics.setNull(for: "latency_p50_ms")
        metrics.setNull(for: "latency_p95_ms")
        metrics.setNull(for: "latency_p99_ms")
        metrics.setNull(for: "max_latency_ms")
        metrics.setNull(for: "failure_reason")
        metrics.setNull(for: "requests_per_second")
        metrics.setNull(for: "throughput_mbps")
        metrics.setNull(for: "connections_per_second")
        metrics.setNull(for: "cpu_percent_conjetd")
        metrics.setNull(for: "wakeups_per_second")
        metrics.setNull(for: "energy_to_solution_joules")
        metrics.setNull(for: "port_publication_listener_visible_ms")
        metrics.setNull(for: "port_publication_first_connect_ms")
        metrics.setNull(for: "vsock_connections_opened")
        metrics.setNull(for: "vsock_connections_reused")
        metrics.setNull(for: "vsock_reconnects")
        metrics.setNull(for: "active_vsock_connections")
        metrics.setBool(persistentVsock, for: "udp_target_socket_reuse")
        metrics.setNull(for: "udp_session_cache_hits")
        metrics.setNull(for: "udp_session_cache_misses")
        metrics.setNull(for: "mux_streams_opened")
        metrics.setNull(for: "mux_active_streams")
        metrics.setNull(for: "backpressure_events")
        metrics.setNull(for: "helper_cpu_percent_avg")
        metrics.setNull(for: "helper_cpu_percent_peak")
        metrics.setNull(for: "conjetd_cpu_percent_avg")
        metrics.setNull(for: "conjetd_cpu_percent_peak")
        metrics.setNull(for: "conjet_netd_cpu_percent_avg")
        metrics.setNull(for: "conjet_netd_cpu_percent_peak")
        metrics.setNull(for: "python_bridge_cpu_percent_avg")
        metrics.setNull(for: "helper_cpu_percent_total_avg")
        metrics.setNull(for: "helper_cpu_percent_total_peak")
        metrics.setNull(for: "cpu_per_1000_requests")
        metrics.setString("skipped_process_not_found", for: "cpu_metrics_status")
        metrics.setNull(for: "helper_cpu_metrics_skipped_reason")
        return metrics
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

    private func addHelperCPUMetrics(_ metrics: inout BenchmarkMetrics, context: String) {
        let sample = helperCPUSample(context: context)
        guard let cpu = sample.totalCPUPercent else {
            let reason = sample.skippedReason ?? "helper_process_not_found"
            metrics.setString(reason, for: "helper_cpu_metrics_skipped_reason")
            metrics.setString(statusForCPUSkip(reason), for: "cpu_metrics_status")
            return
        }
        metrics["helper_cpu_percent_avg"] = cpu
        metrics["helper_cpu_percent_peak"] = cpu
        metrics["helper_cpu_percent_total_avg"] = cpu
        metrics["helper_cpu_percent_total_peak"] = cpu
        if context == "conjet" {
            metrics["conjetd_cpu_percent_avg"] = sample.conjetdCPUPercent
            metrics["conjetd_cpu_percent_peak"] = sample.conjetdCPUPercent
            metrics["conjet_netd_cpu_percent_avg"] = sample.conjetNetdCPUPercent
            metrics["conjet_netd_cpu_percent_peak"] = sample.conjetNetdCPUPercent
            metrics["python_bridge_cpu_percent_avg"] = sample.pythonBridgeCPUPercent
        }
        metrics.setString("measured", for: "cpu_metrics_status")
        if let rps = metrics["requests_per_second"], rps > 0 {
            metrics["cpu_per_1000_requests"] = (cpu / rps) * 1_000
        }
    }

    private func helperCPUSample(context: String) -> (
        totalCPUPercent: Double?,
        conjetdCPUPercent: Double?,
        conjetNetdCPUPercent: Double?,
        pythonBridgeCPUPercent: Double?,
        skippedReason: String?
    ) {
        let result = runProcess(["/bin/ps", "-axo", "pcpu,args"], timeoutSeconds: 3)
        guard result.exitCode == 0 else {
            return (nil, nil, nil, nil, "ps_failed")
        }
        let patterns: [String]
        switch context {
        case "conjet":
            patterns = ["conjetd", "conjet-netd", "conjet-docker-vsock-bridge.py"]
        case "orbstack":
            patterns = ["OrbStack Helper"]
        case "colima":
            patterns = ["colima", "qemu", "vz"]
        default:
            patterns = [context]
        }
        var values: [Double] = []
        var conjetdValues: [Double] = []
        var conjetNetdValues: [Double] = []
        var pythonBridgeValues: [Double] = []
        for line in result.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            guard patterns.contains(where: { line.localizedCaseInsensitiveContains($0) }) else { continue }
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            if let first = parts.first, let value = Double(first) {
                values.append(value)
                if context == "conjet" {
                    if line.localizedCaseInsensitiveContains("conjetd") {
                        conjetdValues.append(value)
                    }
                    if line.localizedCaseInsensitiveContains("conjet-netd") {
                        conjetNetdValues.append(value)
                    }
                    if line.localizedCaseInsensitiveContains("conjet-docker-vsock-bridge.py") {
                        pythonBridgeValues.append(value)
                    }
                }
            }
        }
        guard !values.isEmpty else {
            return (nil, nil, nil, nil, "helper_process_not_found")
        }
        return (
            values.reduce(0, +),
            conjetdValues.isEmpty ? nil : conjetdValues.reduce(0, +),
            conjetNetdValues.isEmpty ? nil : conjetNetdValues.reduce(0, +),
            pythonBridgeValues.isEmpty ? nil : pythonBridgeValues.reduce(0, +),
            nil
        )
    }

    private func statusForCPUSkip(_ reason: String) -> String {
        switch reason {
        case "helper_process_not_found":
            return "skipped_process_not_found"
        case "ps_failed":
            return "skipped_not_supported"
        default:
            return "skipped_not_supported"
        }
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

    private func runtimeName(for context: String) -> String {
        options.runtimeLabels[context] ?? context
    }

    private func proxyEngineName(for context: String) -> String {
        if let label = options.proxyEngineLabels[context] {
            return label
        }
        return context == "conjet" ? "proxy-gcd-evented" : "runtime-native"
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        text.count <= limit ? text : String(text.suffix(limit))
    }

    private func shortID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
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

private func setBenchmarkSocketTimeout(_ fd: Int32, timeoutSeconds: Double) {
    let seconds = Int(timeoutSeconds)
    let microseconds = Int((timeoutSeconds - Double(seconds)) * 1_000_000)
    var timeout = timeval(tv_sec: seconds, tv_usec: Int32(microseconds))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func readHTTPResponseHeaderAndBody(from fd: Int32) -> Bool {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var headerEnd: Range<Data.Index>?
    while headerEnd == nil, data.count < 128 * 1024 {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
        } else if count < 0, errno == EINTR {
            continue
        } else {
            return false
        }
    }
    guard let headerEnd else { return false }
    let headerData = data.prefix(upTo: headerEnd.lowerBound)
    let bodyStart = headerEnd.upperBound
    let headers = String(data: headerData, encoding: .isoLatin1) ?? ""
    guard headers.split(separator: "\r\n", maxSplits: 1).first?.contains(" 2") == true else {
        return false
    }
    let contentLength = headers
        .split(separator: "\r\n")
        .first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { line -> Int? in
            let value = line.split(separator: ":", maxSplits: 1).dropFirst().first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.flatMap(Int.init)
        } ?? 0
    var bodyBytes = data.distance(from: bodyStart, to: data.endIndex)
    while bodyBytes < contentLength {
        let count = Darwin.read(fd, &buffer, min(buffer.count, contentLength - bodyBytes))
        if count > 0 {
            bodyBytes += count
        } else if count < 0, errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

private final class ConcurrentLatencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latencies: [Double] = []
    private var failures = 0

    func record(_ latency: Double?) {
        lock.lock()
        if let latency {
            latencies.append(latency)
        } else {
            failures += 1
        }
        lock.unlock()
    }

    func snapshot() -> (latencies: [Double], failures: Int) {
        lock.lock()
        let result = (latencies, failures)
        lock.unlock()
        return result
    }
}

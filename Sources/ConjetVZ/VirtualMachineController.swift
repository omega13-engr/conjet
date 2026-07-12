import ConjetCore
import Darwin
import Foundation

public final class VirtualMachineController {
    private let queue = DispatchQueue(label: "dev.conjet.vm")
    private let operationLock = NSLock()
    private let progressLock = NSLock()
    private var state: VMRunState = .stopped
    private var phase: String?
    private var events: [VMRuntimeEvent] = []
    private let maxEventCount = 16
    private var hvfRun: ConjetCoreRustVMMRun?

    private var publishedPortForwarder: DockerPublishedPortForwarder?

    public init() {}

    public func status(store: VMImageStore, backend: ConjetVMBackend = .hvfExperimental) -> VMRuntimeStatus {
        if let hvfRun {
            if hvfRun.isRunning {
                return statusWithProgress(
                    store.status(state: .running, message: "\(backend.displayName) VM is running"),
                    backend: backend
                )
            }
            let result = hvfRun.resultSnapshot()
            publishedPortForwarder?.stop()
            publishedPortForwarder = nil
            self.hvfRun = nil
            let message = result?.message ?? "\(backend.displayName) VM exited"
            return statusWithProgress(
                store.status(state: .stopped, message: message),
                backend: backend
            )
        }
        let snapshot = progressSnapshot()
        return statusWithProgress(
            store.status(state: snapshot.state, message: snapshot.message ?? "\(backend.displayName) VM is \(snapshot.state.rawValue)"),
            backend: backend
        )
    }

    public func networkStatus(config: ConjetConfig) -> ConjetNetworkStatus {
        if let publishedPortForwarder {
            return publishedPortForwarder.status()
        }
        return ConjetNetworkStatus(
            bindPolicy: config.networkBindPolicy,
            proxyEngine: config.networkProxyEngine.rawValue,
            requestedBridgeEngine: config.networkBridgeEngine.rawValue,
            fallbackReason: "network proxy is not running",
            eventWatcherState: "stopped",
            capabilities: ConjetNetworkCapabilities(),
            messages: ["network proxy is not running"]
        )
    }

    public func repairNetwork(config: ConjetConfig) -> ConjetNetworkStatus {
        if let publishedPortForwarder {
            publishedPortForwarder.repair()
            return publishedPortForwarder.status()
        }
        return networkStatus(config: config)
    }

    public func pruneCache(config: ConjetConfig) -> ConjetNetworkStatus {
        if let publishedPortForwarder {
            publishedPortForwarder.pruneCache()
            return publishedPortForwarder.status()
        }
        return networkStatus(config: config)
    }

    public func start(
        manifest: VMAssetManifest,
        config: ConjetConfig,
        store: VMImageStore,
        waitMode: VMStartWaitMode = .control
    ) throws -> VMRuntimeStatus {
        operationLock.lock()
        defer { operationLock.unlock() }

        return try startJetstreamHVF(manifest: manifest, config: config, store: store, waitMode: waitMode)
    }

    public func stop(store: VMImageStore, backend: ConjetVMBackend = .hvfExperimental) throws -> VMRuntimeStatus {
        operationLock.lock()
        defer { operationLock.unlock() }

        if let hvfRun {
            setProgress(state: .stopping, phase: "rust-vmm-stop", message: "stopping Conjet Core Rust virtual machine", resetEvents: true)
            if let manifest = try? store.loadManifest() {
                try? DockerServiceQuiescer(socketPath: manifest.dockerSocketPath).quiesceForVMStop()
            }
            publishedPortForwarder?.stop()
            publishedPortForwarder = nil
            let stopped = hvfRun.stop(timeoutSeconds: 15)
            if !stopped {
                setProgress(state: .error, phase: "jetstream-stop", message: "timed out waiting for Jetstream HVF VM to stop")
                throw ConjetError.unavailable("timed out waiting for Jetstream HVF VM to stop")
            }
            self.hvfRun = nil
            setProgress(state: .stopped, phase: "stopped", message: "Conjet Core Rust VM stopped")
            return statusWithProgress(
                store.status(state: .stopped, message: "Conjet Core Rust VM stopped"),
                backend: backend
            )
        }
        publishedPortForwarder?.stop()
        publishedPortForwarder = nil
        setProgress(state: .stopped, phase: "stopped", message: "Conjet Core Rust VM is not running", resetEvents: true)
        return statusWithProgress(
            store.status(state: .stopped, message: "Conjet Core Rust VM is not running"),
            backend: backend
        )
    }

    private func startJetstreamHVF(
        manifest: VMAssetManifest,
        config: ConjetConfig,
        store: VMImageStore,
        waitMode: VMStartWaitMode
    ) throws -> VMRuntimeStatus {
        if let hvfRun, hvfRun.isRunning {
            if waitMode == .docker {
                try waitForDockerAPIReady(socketPath: manifest.dockerSocketPath)
            }
            return statusWithProgress(
                manifest.runtimeStatus(
                    state: .running,
                    message: "Conjet Core Rust VM is already running",
                    manifestPath: store.paths.vmManifest.path
                ),
                backend: config.vmBackend
            )
        }
        if let hvfRun {
            self.hvfRun = nil
            setProgress(
                state: .stopped,
                phase: "rust-vmm-exited",
                message: hvfRun.resultSnapshot()?.message ?? "previous Conjet Core Rust VM exited",
                resetEvents: true
            )
        }

        setProgress(
            state: .starting,
            phase: "rust-vmm-plan",
            message: "preparing Conjet Core Rust VMM runtime",
            resetEvents: true
        )
        do {
            try VMImageStore.validateJetstreamDirectKernelBootAssets(manifest)
        } catch {
            setProgress(state: .error, phase: "rust-vmm-plan", message: "invalid Conjet Core Rust VMM boot assets")
            throw error
        }
        let tool = ConjetCoreRustVMMTool.resolve()
        let memoryMiB = config.effectiveMemoryMiB
        let vcpus = config.effectiveVMCPUs
        let stdoutPath = manifest.serialLogPath.isEmpty
            ? store.paths.serialLog.path
            : manifest.serialLogPath
        let stderrPath = URL(fileURLWithPath: stdoutPath)
            .deletingPathExtension()
            .appendingPathExtension("rust-vmm.stderr.log")
            .path
        let rustMemorySocketPath = Self.rustMemorySocketPath(dockerSocketPath: manifest.dockerSocketPath)
        let rustMemoryControlSocketPath = Self.rustMemoryControlSocketPath(dockerSocketPath: manifest.dockerSocketPath)
        try? FileManager.default.removeItem(atPath: manifest.dockerSocketPath)
        try? FileManager.default.removeItem(atPath: rustMemorySocketPath)
        try? FileManager.default.removeItem(atPath: rustMemoryControlSocketPath)
        var commandArguments = [
            "boot",
            "--manifest", store.paths.vmManifest.path,
            "--memory-mib", "\(memoryMiB)",
            "--cpus", "\(vcpus)",
            "--max-exits", "\(UInt64.max)",
            "--max-runtime-ms", "0",
            "--host-tick-ms", "25",
            "--require-docker-ready",
            "--docker-probe-timeout-ms", "\(Int(Self.managedHVFReadinessTimeoutSeconds() * 1_000))",
            "--hold-after-ready-forever",
            "--memory-control-socket", rustMemoryControlSocketPath,
            "--json"
        ]
        if tool.path == "/usr/bin/env" {
            commandArguments.insert("jetstream", at: 0)
        }
        let managedRun = try ConjetCoreRustVMMRun(
            executable: tool.path,
            arguments: commandArguments,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath
        )
        hvfRun = managedRun

        setProgress(
            state: .starting,
            phase: "rust-vmm-start",
            message: "starting Conjet Core Rust VMM (\(memoryMiB) MiB, \(vcpus) vCPU, \(tool.source))"
        )
        try managedRun.start()
        try assertRustVMMStillRunning(managedRun)

        do {
            if waitMode == .docker {
                try waitForDockerAPIReady(
                    socketPath: manifest.dockerSocketPath,
                    timeoutSeconds: Self.managedHVFReadinessTimeoutSeconds(),
                    livenessCheck: { try self.assertRustVMMStillRunning(managedRun) }
                )
                startRustPublishedPortForwarder(manifest: manifest, config: config)
                _ = waitForRustCoreMemoryController(
                    memorySocketPath: rustMemorySocketPath,
                    controlSocketPath: rustMemoryControlSocketPath
                )
                let message = "Conjet Core Rust VM started; Docker API ready"
                setProgress(state: .running, phase: "docker-ready", message: message)
                return statusWithProgress(
                    manifest.runtimeStatus(
                        state: .running,
                        message: message,
                        manifestPath: store.paths.vmManifest.path
                    ),
                    backend: config.vmBackend
                )
            }
            startRustPublishedPortForwarder(manifest: manifest, config: config)
            _ = waitForRustCoreMemoryController(
                memorySocketPath: rustMemorySocketPath,
                controlSocketPath: rustMemoryControlSocketPath
            )
            try assertRustVMMStillRunning(managedRun)
            let message = "Conjet Core Rust VM started; Docker API is warming asynchronously"
            setProgress(state: .running, phase: "control-ready", message: message)
            return statusWithProgress(
                manifest.runtimeStatus(
                    state: .running,
                    message: message,
                    manifestPath: store.paths.vmManifest.path
                ),
                backend: config.vmBackend
            )
        } catch {
            let initialResult = managedRun.resultSnapshot()
            _ = managedRun.stop(timeoutSeconds: 15)
            let result = initialResult ?? managedRun.resultSnapshot()
            try? FileManager.default.removeItem(atPath: manifest.dockerSocketPath)
            try? FileManager.default.removeItem(atPath: rustMemorySocketPath)
            try? FileManager.default.removeItem(atPath: rustMemoryControlSocketPath)
            hvfRun = nil
            setProgress(
                state: .error,
                phase: "rust-vmm-start",
                message: result?.message ?? "timed out waiting for Conjet Core Rust VM Docker readiness"
            )
            throw error
        }
    }

    private func startRustPublishedPortForwarder(
        manifest: VMAssetManifest,
        config: ConjetConfig
    ) {
        publishedPortForwarder?.stop()
        publishedPortForwarder = nil

        let baseConnector = UnixSocketGuestConnectionConnector(
            socketPath: manifest.dockerSocketPath,
            timeoutSeconds: 3
        )
        let retryingConnector = RetryingGuestConnectionConnector(
            base: baseConnector,
            timeoutSeconds: 10,
            intervalSeconds: 0.2
        )
        let capabilities = waitForRustBridgeProxyCapabilities(connector: retryingConnector, timeoutSeconds: 30)
        guard capabilities.tcpProxy || capabilities.udpProxy else {
            setProgress(
                state: .starting,
                phase: "port-forwarder",
                message: "published port forwarder unavailable: guest bridge does not advertise TCP/UDP proxy"
            )
            return
        }

        let connector: any GuestConnectionConnector
        if capabilities.lazyUpstream {
            connector = PooledGuestConnectionConnector(
                base: retryingConnector,
                capacity: 16,
                refillDelaySeconds: 0.05
            )
        } else {
            connector = retryingConnector
        }

        let bridgeFallbackReason = Self.bridgeFallbackReason(requested: config.networkBridgeEngine, capabilities: capabilities)
        let forwarder = DockerPublishedPortForwarder(
            socketPath: manifest.dockerSocketPath,
            connector: connector,
            policy: ConjetPortPolicy(
                bindPolicy: config.networkBindPolicy,
                lanAllowedCIDRs: config.networkLANAllowedCIDRs,
                lanAllowedPorts: config.networkLANAllowedPorts
            ),
            proxyEngine: config.networkProxyEngine,
            capabilities: capabilities.conjetNetworkCapabilities,
            requestedBridgeEngine: config.networkBridgeEngine,
            bridgeFallbackReason: bridgeFallbackReason,
            energyMode: config.energyMode,
            successfulConnectionHandler: { _ in },
            activityHandler: { _ in }
        )
        setProgress(state: .starting, phase: "port-forwarder", message: "starting published port forwarder")
        forwarder.start()
        publishedPortForwarder = forwarder
    }

    private func waitForRustBridgeProxyCapabilities(
        connector: any GuestConnectionConnector,
        timeoutSeconds: TimeInterval
    ) -> GuestBridgeCapabilities {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        var latest = GuestBridgeCapabilities()
        while true {
            latest = GuestBridgeCapabilityProbe.capabilities(connector: connector, timeoutSeconds: 2)
            if latest.tcpProxy || latest.udpProxy || Date() >= deadline {
                return latest
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func bridgeFallbackReason(
        requested: ConjetNetworkBridgeEngine,
        capabilities: GuestBridgeCapabilities
    ) -> String? {
        guard requested != .auto else { return nil }
        let active = capabilities.bridgeEngine ?? "python-legacy"
        guard active != requested.rawValue else { return nil }
        if requested == .conjetNetdC {
            return "requested conjet-netd-c but active bridge is \(active); rebuild/import a Conjet Core image with /usr/local/sbin/conjet-netd or set the guest bridge engine"
        }
        return "requested \(requested.rawValue) but active bridge is \(active)"
    }

    private func assertRustVMMStillRunning(_ run: ConjetCoreRustVMMRun) throws {
        if let result = run.resultSnapshot() {
            throw ConjetError.unavailable(result.message)
        }
    }

    static func managedHVFReadinessTimeoutSeconds(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
        let keys = [
            "CONJET_JETSTREAM_HVF_READINESS_TIMEOUT_SECONDS",
            "CONJET_HVF_READINESS_TIMEOUT_SECONDS"
        ]
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let value = TimeInterval(raw),
                  value >= 30 else {
                continue
            }
            return value
        }
        return 600
    }

    static func rustMemorySocketPath(dockerSocketPath: String) -> String {
        rustUnixSocketPath(dockerSocketPath: dockerSocketPath, basename: "memory.sock")
    }

    static func rustMemoryControlSocketPath(dockerSocketPath: String) -> String {
        rustUnixSocketPath(dockerSocketPath: dockerSocketPath, basename: "rust-memory-control.sock")
    }

    private static func rustUnixSocketPath(dockerSocketPath: String, basename: String) -> String {
        let preferred = URL(fileURLWithPath: dockerSocketPath)
            .deletingLastPathComponent()
            .appendingPathComponent(basename)
            .path
        guard preferred.utf8CString.count > unixSocketPathCapacity else {
            return preferred
        }
        let digest = stableDigestHex(dockerSocketPath)
        return URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("conjet-\(digest)", isDirectory: true)
            .appendingPathComponent(basename)
            .path
    }

    private static var unixSocketPathCapacity: Int { 104 }

    private static func stableDigestHex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    static func memoryReclaimVMIsRunning(
        hvfRunIsRunning: Bool,
        virtualizationState: VMRunState?
    ) -> Bool {
        hvfRunIsRunning || virtualizationState == .running
    }

    public func reclaimIdleMemory(
        config: ConjetConfig,
        store: VMImageStore,
        reason: String = "manual",
        timeoutSeconds: TimeInterval = 12
    ) throws -> VMRuntimeStatus {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard hvfRun?.isRunning == true else {
            return statusWithProgress(
                store.status(state: .stopped, message: "\(config.vmBackend.displayName) VM is not running"),
                backend: config.vmBackend
            )
        }

        setProgress(
            state: .running,
            phase: "memory-reclaim",
            message: "reclaiming idle guest memory (\(reason))"
        )

        setProgress(
            state: .running,
            phase: "ready",
            message: "Jetstream owns idle memory reclaim; no host-side target change"
        )
        return statusWithProgress(
            store.status(
                state: .running,
                message: "Jetstream owns idle memory reclaim; no host-side target change"
            ),
            backend: config.vmBackend
        )
    }

    private func waitForDockerAPIReady(
        socketPath: String,
        timeoutSeconds: TimeInterval = 45,
        livenessCheck: (() throws -> Void)? = nil
    ) throws {
        setProgress(state: .starting, phase: "docker-ready", message: "waiting for Conjet Docker API readiness")
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        let probe = DockerSocketReadinessProbe(socketPath: socketPath)
        repeat {
            try livenessCheck?()
            if probe.isReady(timeoutSeconds: min(1, max(0.1, deadline.timeIntervalSinceNow))) {
                setProgress(state: .starting, phase: "docker-ready", message: "Conjet Docker API ready")
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(0.25, remaining))
        } while Date() < deadline
        try livenessCheck?()
        throw ConjetError.unavailable("timed out waiting \(Int(timeoutSeconds))s for Conjet Docker API readiness")
    }

    private func waitForRustCoreMemoryController(
        memorySocketPath: String,
        controlSocketPath: String
    ) -> Bool {
        setProgress(state: .starting, phase: "dynamic-memory", message: "verifying Jetstream memory telemetry")
        let metricsClient = GuestMemoryMetricsClient(
            connector: RetryingGuestConnectionConnector(
                base: UnixSocketGuestConnectionConnector(socketPath: memorySocketPath, timeoutSeconds: 3),
                timeoutSeconds: 8,
                intervalSeconds: 0.5
            )
        )
        do {
            let deadline = Date().addingTimeInterval(60)
            var lastError: Error?
            repeat {
                do {
                    _ = try metricsClient.snapshot()
                    _ = try ConjetCoreRustMemoryControlClient(socketPath: controlSocketPath).metrics()
                    setProgress(state: .starting, phase: "dynamic-memory", message: "Jetstream memory controller enabled")
                    return true
                } catch {
                    lastError = error
                    Thread.sleep(forTimeInterval: 0.5)
                }
            } while Date() < deadline
            throw lastError ?? ConjetError.unavailable("timed out waiting for Jetstream memory telemetry")
        } catch {
            setProgress(state: .starting, phase: "dynamic-memory", message: "Jetstream memory telemetry unavailable: \(error)")
            return false
        }
    }


    private func progressSnapshot() -> (state: VMRunState, phase: String?, message: String?, events: [VMRuntimeEvent]) {
        progressLock.lock()
        defer { progressLock.unlock() }
        return (state, phase, events.last?.message, events)
    }

    private func statusWithProgress(_ status: VMRuntimeStatus, backend: ConjetVMBackend? = nil) -> VMRuntimeStatus {
        let snapshot = progressSnapshot()
        var enriched = status
        if let backend {
            enriched.backend = backend
        }
        enriched.phase = snapshot.phase
        enriched.events = snapshot.events
        switch snapshot.state {
        case .starting, .stopping, .error:
            enriched.state = snapshot.state
            if let message = snapshot.message {
                enriched.message = message
            }
        default:
            if let message = snapshot.message, status.state == snapshot.state {
                enriched.message = message
            }
        }
        if enriched.state == .unconfigured {
            enriched.phase = nil
            enriched.events = []
        }
        return enriched
    }

    private func setProgress(
        state: VMRunState,
        phase: String,
        message: String,
        resetEvents: Bool = false
    ) {
        progressLock.lock()
        self.state = state
        self.phase = phase
        if resetEvents {
            events.removeAll(keepingCapacity: true)
        }
        events.append(VMRuntimeEvent(phase: phase, message: message))
        if events.count > maxEventCount {
            events.removeFirst(events.count - maxEventCount)
        }
        progressLock.unlock()
    }
}
extension VirtualMachineController: @unchecked Sendable {}


private final class AsyncErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        let value = error
        lock.unlock()
        return value
    }
}

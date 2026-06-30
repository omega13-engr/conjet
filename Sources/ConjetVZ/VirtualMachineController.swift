import ConjetCore
import Darwin
import Foundation

#if canImport(Virtualization)
@preconcurrency import Virtualization
#endif

public final class VirtualMachineController {
    private let queue = DispatchQueue(label: "dev.conjet.vm")
    private let operationLock = NSLock()
    private let progressLock = NSLock()
    private var state: VMRunState = .stopped
    private var phase: String?
    private var events: [VMRuntimeEvent] = []
    private let maxEventCount = 16
    private var hvfRun: ConjetCoreRustVMMRun?

    #if canImport(Virtualization)
    private var machine: VZVirtualMachine?
    private var retainedResources: VZRuntimeResources?
    private var dockerBridge: DockerSocketBridge?
    private var publishedPortForwarder: DockerPublishedPortForwarder?
    private var dynamicMemoryManager: DynamicMemoryManager?
    private let idleMemoryReclaimLock = NSLock()
    private var idleMemoryReclaimThread: Thread?
    private var idleMemoryReclaimRunning = false
    private var lastMemoryActivityAt = Date.distantPast
    private var lastIdleMemoryReclaimAt: Date?
    #endif

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
            #if canImport(Virtualization)
            publishedPortForwarder?.stop()
            publishedPortForwarder = nil
            dockerBridge?.stop()
            dockerBridge = nil
            stopDynamicMemoryManager()
            stopIdleMemoryReclaimer()
            #endif
            self.hvfRun = nil
            let message = result?.message ?? "\(backend.displayName) VM exited"
            return statusWithProgress(
                store.status(state: .stopped, message: message),
                backend: backend
            )
        }
        #if canImport(Virtualization)
        if let machine {
            let mappedState = mapState(machine.state)
            return statusWithProgress(
                store.status(state: mappedState, message: "\(backend.displayName) VM is \(mappedState.rawValue)"),
                backend: backend
            )
        }
        #endif
        let snapshot = progressSnapshot()
        return statusWithProgress(
            store.status(state: snapshot.state, message: snapshot.message ?? "\(backend.displayName) VM is \(snapshot.state.rawValue)"),
            backend: backend
        )
    }

    public func networkStatus(config: ConjetConfig) -> ConjetNetworkStatus {
        #if canImport(Virtualization)
        if let publishedPortForwarder {
            return publishedPortForwarder.status()
        }
        #endif
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
        #if canImport(Virtualization)
        if let publishedPortForwarder {
            publishedPortForwarder.repair()
            return publishedPortForwarder.status()
        }
        #endif
        return networkStatus(config: config)
    }

    public func pruneCache(config: ConjetConfig) -> ConjetNetworkStatus {
        #if canImport(Virtualization)
        if let publishedPortForwarder {
            publishedPortForwarder.pruneCache()
            return publishedPortForwarder.status()
        }
        #endif
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

        if config.vmBackend == .hvfExperimental {
            return try startJetstreamHVF(manifest: manifest, config: config, store: store, waitMode: waitMode)
        }

        guard config.vmBackend.startSupported else {
            let message = "\(config.vmBackend.displayName) is selected; run 'conjet vm backend smoke' to validate the isolated HVF backend. Guest VM start remains blocked until the Jetstream boot path lands."
            setProgress(state: .error, phase: "backend-selection", message: message, resetEvents: true)
            throw ConjetError.unavailable(message)
        }

        #if canImport(Virtualization)
        if let machine, mapState(machine.state) == .running || mapState(machine.state) == .starting {
            let mappedState = mapState(machine.state)
            if mappedState == .running, waitMode == .docker {
                try waitForDockerAPIReady(socketPath: manifest.dockerSocketPath)
            }
            return statusWithProgress(manifest.runtimeStatus(
                state: mappedState,
                message: "VM is already \(mappedState.rawValue)",
                manifestPath: store.paths.vmManifest.path
            ), backend: config.vmBackend)
        }

        setProgress(
            state: .starting,
            phase: "configuration",
            message: "preparing Virtualization.framework configuration",
            resetEvents: true
        )
        let configured: VZConfiguredMachine
        do {
            configured = try VZConfigurationBuilder.build(manifest: manifest, config: config)
        } catch {
            setProgress(state: .error, phase: "configuration", message: "failed to prepare VM configuration")
            throw error
        }
        do {
            setProgress(state: .starting, phase: "validation", message: "validating VM configuration")
            try configured.configuration.validate()
        } catch {
            setProgress(state: .error, phase: "validation", message: "VZ configuration did not validate")
            throw ConjetError.unavailable("VZ configuration did not validate: \(error)")
        }

        setProgress(state: .starting, phase: "vz-start", message: "starting VZ virtual machine")
        let vm = VZVirtualMachine(configuration: configured.configuration, queue: queue)
        machine = vm
        retainedResources = configured.resources

        let semaphore = DispatchSemaphore(value: 0)
        let startError = AsyncErrorBox()
        let vmBox = VZMachineBox(vm)
        queue.async {
            vmBox.machine.start { result in
                if case .failure(let error) = result {
                    startError.set(error)
                }
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            setProgress(state: .error, phase: "vz-start", message: "timed out waiting for VZ VM to start")
            throw ConjetError.unavailable("timed out waiting for VZ VM to start")
        }
        if let startError = startError.get() {
            setProgress(state: .error, phase: "vz-start", message: "failed to start VZ VM")
            throw ConjetError.unavailable("failed to start VZ VM: \(startError)")
        }
        setProgress(state: .starting, phase: "guest-bridge", message: "VZ VM started; waiting for guest bridge")
        let socketDevice: VZVirtioSocketDevice
        do {
            socketDevice = try startDockerBridge(for: vm, manifest: manifest, config: config, waitMode: waitMode)
        } catch {
            setProgress(state: .error, phase: "guest-bridge", message: "failed to expose Docker bridge")
            throw error
        }
        if waitMode == .docker {
            try waitForDockerAPIReady(socketPath: manifest.dockerSocketPath)
            ensureGuestMemorySetup(socketPath: manifest.dockerSocketPath)
            setProgress(state: .running, phase: "docker-ready", message: "VM started; Docker API ready")
        } else {
            setProgress(
                state: .running,
                phase: "control-ready",
                message: "VM control plane ready; Docker API is warming asynchronously"
            )
        }
        if !startDynamicMemoryManager(for: vm, socketDevice: socketDevice, config: config) {
            startIdleMemoryReclaimer(config: config, store: store)
        }
        return statusWithProgress(
            manifest.runtimeStatus(
                state: .running,
                message: waitMode == .docker ? "VM started; Docker API ready" : "VM control plane ready",
                manifestPath: store.paths.vmManifest.path
            ),
            backend: config.vmBackend
        )
        #else
        throw ConjetError.unavailable("Virtualization.framework is not available in this build")
        #endif
    }

    public func stop(store: VMImageStore, backend: ConjetVMBackend = .hvfExperimental) throws -> VMRuntimeStatus {
        operationLock.lock()
        defer { operationLock.unlock() }

        if let hvfRun {
            setProgress(state: .stopping, phase: "rust-vmm-stop", message: "stopping Conjet Core Rust virtual machine", resetEvents: true)
            #if canImport(Virtualization)
            stopDynamicMemoryManager()
            stopIdleMemoryReclaimer()
            if let manifest = try? store.loadManifest() {
                try? DockerServiceQuiescer(socketPath: manifest.dockerSocketPath).quiesceForVMStop()
            }
            publishedPortForwarder?.stop()
            publishedPortForwarder = nil
            dockerBridge?.stop()
            dockerBridge = nil
            #endif
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
        if backend == .hvfExperimental {
            setProgress(state: .stopped, phase: "stopped", message: "Conjet Core Rust VM is not running", resetEvents: true)
            return statusWithProgress(
                store.status(state: .stopped, message: "Conjet Core Rust VM is not running"),
                backend: backend
            )
        }

        #if canImport(Virtualization)
        guard let machine else {
            stopDynamicMemoryManager()
            stopIdleMemoryReclaimer()
            publishedPortForwarder?.stop()
            publishedPortForwarder = nil
            dockerBridge?.stop()
            dockerBridge = nil
            setProgress(state: .stopped, phase: "stopped", message: "VM is not running", resetEvents: true)
            return statusWithProgress(store.status(state: .stopped, message: "VM is not running"), backend: backend)
        }

        if mapState(machine.state) == .stopped {
            stopDynamicMemoryManager()
            stopIdleMemoryReclaimer()
            publishedPortForwarder?.stop()
            publishedPortForwarder = nil
            dockerBridge?.stop()
            dockerBridge = nil
            self.machine = nil
            retainedResources = nil
            setProgress(state: .stopped, phase: "stopped", message: "VM is already stopped", resetEvents: true)
            return statusWithProgress(store.status(state: .stopped, message: "VM is already stopped"), backend: backend)
        }

        setProgress(state: .stopping, phase: "guest-shutdown", message: "quiescing guest Docker services", resetEvents: true)
        stopDynamicMemoryManager()
        stopIdleMemoryReclaimer()
        if let manifest = try? store.loadManifest() {
            try? DockerServiceQuiescer(socketPath: manifest.dockerSocketPath).quiesceForVMStop()
        }
        setProgress(state: .stopping, phase: "network-stop", message: "stopping Docker socket bridge")
        publishedPortForwarder?.stop()
        publishedPortForwarder = nil
        dockerBridge?.stop()
        dockerBridge = nil

        setProgress(state: .stopping, phase: "vz-stop", message: "stopping VZ virtual machine")
        let semaphore = DispatchSemaphore(value: 0)
        let stopError = AsyncErrorBox()
        let vmBox = VZMachineBox(machine)
        queue.async {
            if vmBox.machine.canStop {
                vmBox.machine.stop { error in
                    stopError.set(error)
                    semaphore.signal()
                }
            } else {
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            setProgress(state: .error, phase: "vz-stop", message: "timed out waiting for VZ VM to stop")
            throw ConjetError.unavailable("timed out waiting for VZ VM to stop")
        }
        if let stopError = stopError.get() {
            setProgress(state: .error, phase: "vz-stop", message: "failed to stop VZ VM")
            throw ConjetError.unavailable("failed to stop VZ VM: \(stopError)")
        }
        self.machine = nil
        retainedResources = nil
        setProgress(state: .stopped, phase: "stopped", message: "VM stopped")
        return statusWithProgress(store.status(state: .stopped, message: "VM stopped"), backend: backend)
        #else
        return statusWithProgress(
            store.status(state: .stopped, message: "Virtualization.framework is not available in this build"),
            backend: backend
        )
        #endif
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
        let repairedVMMEntitlements = try ConjetCoreRustVMMTool.ensureHVFEntitlementsIfPossible(
            executable: tool.path,
            source: tool.source
        )
        if repairedVMMEntitlements {
            setProgress(
                state: .starting,
                phase: "rust-vmm-signing",
                message: "signed local Jetstream VMM with debug Hypervisor entitlements"
            )
        }
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
                    timeoutSeconds: Self.managedHVFReadinessTimeoutSeconds()
                )
                startRustPublishedPortForwarder(manifest: manifest, config: config)
                _ = startRustDynamicMemoryManager(
                    config: config,
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
            _ = startRustDynamicMemoryManager(
                config: config,
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
            let result = managedRun.resultSnapshot()
            _ = managedRun.stop(timeoutSeconds: 15)
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
            activityHandler: { [weak self] activity in
                self?.recordMemoryActivity()
                self?.dynamicMemoryManager?.handleDockerActivity(activity)
            }
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

        #if canImport(Virtualization)
        let virtualizationState = machine.map { mapState($0.state) }
        guard Self.memoryReclaimVMIsRunning(
            hvfRunIsRunning: hvfRun?.isRunning == true,
            virtualizationState: virtualizationState
        ) else {
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

        if let dynamicMemoryManager {
            try dynamicMemoryManager.forceRecompute(reason: "manual.\(reason)")
            markIdleMemoryReclaimed()
            setProgress(state: .running, phase: "ready", message: "guest memory reclaim requested")
            return statusWithProgress(
                store.status(state: .running, message: "guest memory reclaim requested"),
                backend: config.vmBackend
            )
        }
        markIdleMemoryReclaimed()
        setProgress(state: .running, phase: "ready", message: "dynamic memory telemetry unavailable; no manual balloon pulse used")

        return statusWithProgress(
            store.status(state: .running, message: "dynamic memory telemetry unavailable; no manual balloon pulse used"),
            backend: config.vmBackend
        )
        #else
        return statusWithProgress(
            store.status(state: .stopped, message: "Virtualization.framework is not available in this build"),
            backend: config.vmBackend
        )
        #endif
    }

    public func hardDropIdleMemory(
        config: ConjetConfig,
        store: VMImageStore,
        dropBytes: UInt64,
        timeoutSeconds: TimeInterval = 30
    ) throws -> ConjetMemoryHardDropResult {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard dropBytes > 0 else {
            throw ConjetError.invalidArgument("hard memory drop bytes must be greater than zero")
        }

        #if canImport(Virtualization)
        guard config.vmBackend == .hvfExperimental else {
            throw ConjetError.unavailable("hard memory drop currently requires the Rust HVF backend")
        }
        guard hvfRun?.isRunning == true else {
            throw ConjetError.unavailable("\(config.vmBackend.displayName) VM is not running")
        }

        let manifest = try store.loadManifest()
        let memorySocketPath = Self.rustMemorySocketPath(dockerSocketPath: manifest.dockerSocketPath)
        let controlSocketPath = Self.rustMemoryControlSocketPath(dockerSocketPath: manifest.dockerSocketPath)
        let metricsClient = GuestMemoryMetricsClient(
            connector: RetryingGuestConnectionConnector(
                base: UnixSocketGuestConnectionConnector(socketPath: memorySocketPath, timeoutSeconds: 3),
                timeoutSeconds: timeoutSeconds,
                intervalSeconds: 0.5
            )
        )
        let controlClient = ConjetCoreRustMemoryControlClient(
            socketPath: controlSocketPath,
            timeoutSeconds: Int(max(1, timeoutSeconds))
        )

        setProgress(
            state: .running,
            phase: "memory-hard-drop",
            message: "offlining guest memory blocks for host decommit"
        )
        let hostBeforeMetrics = try? controlClient.metrics()
        let hostBefore = hostBeforeMetrics?.hostMemory.physicalFootprintBytes
        let guestDrop: GuestMemoryHardDropResponse
        do {
            guestDrop = try metricsClient.hardDrop(bytes: dropBytes)
        } catch {
            return try hardDropIdleMemoryWithBalloonFallback(
                config: config,
                dropBytes: dropBytes,
                guestFailure: "\(error)",
                hostBeforeMetrics: hostBeforeMetrics,
                metricsClient: metricsClient,
                controlClient: controlClient
            )
        }
        guard guestDrop.accepted, guestDrop.offlinedBytes > 0, !guestDrop.ranges.isEmpty else {
            return try hardDropIdleMemoryWithBalloonFallback(
                config: config,
                dropBytes: dropBytes,
                guestFailure: "guest memory hard drop was not accepted: \(guestDrop.message)",
                hostBeforeMetrics: hostBeforeMetrics,
                metricsClient: metricsClient,
                controlClient: controlClient
            )
        }
        let hostDrop = try controlClient.decommitOfflinedRanges(guestDrop.ranges)
        let hostAfter = try? controlClient.metrics().hostMemory.physicalFootprintBytes
        let footprintDrop: UInt64?
        if let hostBefore, let hostAfter {
            footprintDrop = hostBefore > hostAfter ? hostBefore - hostAfter : 0
        } else {
            footprintDrop = nil
        }
        let decommittedBytes = hostDrop.offlinedMemoryDrop?.lastAppliedBytes ?? 0
        let message = "hard memory drop offlined \(guestDrop.offlinedBytes / 1_048_576) MiB and decommitted \(decommittedBytes / 1_048_576) MiB"
        setProgress(state: .running, phase: "ready", message: message)
        return ConjetMemoryHardDropResult(
            requestedBytes: guestDrop.requestedBytes,
            guestOfflinedBytes: guestDrop.offlinedBytes,
            hostDecommittedBytes: decommittedBytes,
            rangeCount: guestDrop.rangeCount,
            hostFootprintBeforeBytes: hostBefore,
            hostFootprintAfterBytes: hostAfter,
            hostFootprintDropBytes: footprintDrop,
            message: message,
            ranges: guestDrop.ranges
        )
        #else
        throw ConjetError.unavailable("Virtualization.framework is not available in this build")
        #endif
    }

    #if canImport(Virtualization)
    private func hardDropIdleMemoryWithBalloonFallback(
        config: ConjetConfig,
        dropBytes: UInt64,
        guestFailure: String,
        hostBeforeMetrics: ConjetCoreRustMemoryControlClient.Response?,
        metricsClient: GuestMemoryMetricsClient,
        controlClient: ConjetCoreRustMemoryControlClient
    ) throws -> ConjetMemoryHardDropResult {
        let policy = config.memoryPolicy
        let bytesPerMiB: UInt64 = 1_048_576
        let currentTargetMiB = Int(hostBeforeMetrics?.targetMiB ?? UInt64(config.memoryMiB))
        let requestedDropMiB = max(1, Int((dropBytes + bytesPerMiB - 1) / bytesPerMiB))
        var floorMiB = max(0, policy.dynamicMemoryMinimumMiB)
        if let guestMetrics = try? metricsClient.snapshot() {
            let guestUsedBytes = guestMetrics.memTotalBytes > guestMetrics.memAvailableBytes
                ? guestMetrics.memTotalBytes - guestMetrics.memAvailableBytes
                : 0
            let guestUsedMiB = Int((guestUsedBytes + bytesPerMiB - 1) / bytesPerMiB)
            floorMiB = max(
                floorMiB,
                roundUpMiB(guestUsedMiB + policy.dynamicMemoryHeadroomMiB, quantum: 128)
            )
        }
        let desiredTargetMiB = max(floorMiB, currentTargetMiB - requestedDropMiB)
        let boundedTargetMiB = min(currentTargetMiB - 1, max(0, desiredTargetMiB))
        guard boundedTargetMiB > 0, boundedTargetMiB < currentTargetMiB else {
            throw ConjetError.unavailable("\(guestFailure); virtio-balloon fallback had no safe lower target from \(currentTargetMiB) MiB")
        }

        setProgress(
            state: .running,
            phase: "memory-hard-drop",
            message: "guest block offline failed; lowering virtio-balloon target to \(boundedTargetMiB) MiB"
        )
        let beforeMetrics = hostBeforeMetrics ?? (try? controlClient.metrics())
        _ = try controlClient.setTargetBytes(UInt64(boundedTargetMiB) * bytesPerMiB)
        let afterMetrics = observeRustMemoryControlConvergence(
            controlClient: controlClient,
            beforeMetrics: beforeMetrics
        )
        let hostBefore = beforeMetrics?.hostMemory.physicalFootprintBytes
        let hostAfter = afterMetrics?.hostMemory.physicalFootprintBytes
        let footprintDrop: UInt64? = {
            guard let hostBefore, let hostAfter else { return nil }
            return hostBefore > hostAfter ? hostBefore - hostAfter : 0
        }()
        guard let footprintDrop, footprintDrop > 0 else {
            throw ConjetError.unavailable("\(guestFailure); virtio-balloon fallback reached \(boundedTargetMiB) MiB target but host footprint did not drop")
        }

        dynamicMemoryManager?.recordHardDropBalloonTarget(
            targetMiB: boundedTargetMiB,
            reason: "memory-hard-drop.balloon-fallback",
            hostFootprintBefore: hostBefore,
            hostFootprintAfter: hostAfter,
            hostFootprintDrop: footprintDrop
        )
        let message = "hard memory drop used virtio-balloon fallback after guest block offline failed; target \(currentTargetMiB) -> \(boundedTargetMiB) MiB, host footprint dropped \(footprintDrop / bytesPerMiB) MiB"
        setProgress(state: .running, phase: "ready", message: message)
        return ConjetMemoryHardDropResult(
            requestedBytes: dropBytes,
            guestOfflinedBytes: 0,
            hostDecommittedBytes: footprintDrop,
            rangeCount: 0,
            hostFootprintBeforeBytes: hostBefore,
            hostFootprintAfterBytes: hostAfter,
            hostFootprintDropBytes: footprintDrop,
            message: message,
            ranges: []
        )
    }

    private func observeRustMemoryControlConvergence(
        controlClient: ConjetCoreRustMemoryControlClient,
        beforeMetrics: ConjetCoreRustMemoryControlClient.Response?
    ) -> ConjetCoreRustMemoryControlClient.Response? {
        var latest = beforeMetrics
        let beforeFootprint = beforeMetrics?.hostMemory.physicalFootprintBytes
        let beforeReclaimed = beforeMetrics?.balloon.reclaimedBytes ?? 0
        var previousDelay: TimeInterval = 0
        for delay in [0.5, 2.0, 5.0, 10.0, 20.0] as [TimeInterval] {
            Thread.sleep(forTimeInterval: max(0, delay - previousDelay))
            previousDelay = delay
            guard let sample = try? controlClient.metrics() else {
                continue
            }
            latest = sample
            let reclaimed = sample.balloon.reclaimedBytes > beforeReclaimed
                ? sample.balloon.reclaimedBytes - beforeReclaimed
                : 0
            let footprintDrop: UInt64
            if let beforeFootprint, let after = sample.hostMemory.physicalFootprintBytes {
                footprintDrop = beforeFootprint > after ? beforeFootprint - after : 0
            } else {
                footprintDrop = 0
            }
            if reclaimed > 0 || footprintDrop > 0 {
                break
            }
        }
        return latest
    }

    private func roundUpMiB(_ value: Int, quantum: Int) -> Int {
        guard quantum > 1 else { return value }
        return ((value + quantum - 1) / quantum) * quantum
    }
    #endif

    #if canImport(Virtualization)
    private func mapState(_ state: VZVirtualMachine.State) -> VMRunState {
        switch state {
        case .stopped:
            return .stopped
        case .running:
            return .running
        case .starting:
            return .starting
        case .stopping:
            return .stopping
        case .error:
            return .error
        default:
            return progressSnapshot().state
        }
    }

    private func startDockerBridge(
        for machine: VZVirtualMachine,
        manifest: VMAssetManifest,
        config: ConjetConfig,
        waitMode: VMStartWaitMode
    ) throws -> VZVirtioSocketDevice {
        guard let socketDevice = machine.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
            throw ConjetError.unavailable("VM started without a virtio socket device; cannot expose Docker socket")
        }
        dockerBridge?.stop()
        setProgress(state: .starting, phase: "guest-bridge", message: "probing guest bridge capabilities")
        let retryingConnector = RetryingGuestConnectionConnector(
            base: VZGuestConnectionConnector(socketDevice: socketDevice, queue: queue),
            timeoutSeconds: 90,
            intervalSeconds: 0.5
        )
        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: retryingConnector)
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
        try startDockerBridge(
            manifest: manifest,
            config: config,
            connector: connector,
            capabilities: capabilities,
            waitMode: waitMode
        )
        return socketDevice
    }

    private func startDockerBridge(
        manifest: VMAssetManifest,
        config: ConjetConfig,
        connector: any GuestConnectionConnector,
        capabilities: GuestBridgeCapabilities,
        waitMode: VMStartWaitMode,
        memoryMetricsConnector: (any GuestConnectionConnector)? = nil
    ) throws {
        _ = memoryMetricsConnector
        dockerBridge?.stop()
        publishedPortForwarder?.stop()
        publishedPortForwarder = nil
        let bridgeFallbackReason = Self.bridgeFallbackReason(requested: config.networkBridgeEngine, capabilities: capabilities)
        let bridgeReadinessPolicy = GuestDockerBridgeReadinessPolicy.resolve(
            requested: config.networkBridgeEngine,
            capabilities: capabilities
        )
        let forwarder: DockerPublishedPortForwarder?
        if capabilities.tcpProxy {
            forwarder = DockerPublishedPortForwarder(
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
                activityHandler: { [weak self] activity in
                    self?.recordMemoryActivity()
                    self?.dynamicMemoryManager?.handleDockerActivity(activity)
                }
            )
        } else {
            forwarder = nil
        }
        let createPublicationIntentHandler: DockerSocketBridge.CreatePublicationIntentHandler?
        if let forwarder {
            createPublicationIntentHandler = { [weak forwarder] (intent: DockerCreatePublicationIntent) in
                guard let forwarder else { return }
                forwarder.observeCreatePublicationIntent(intent)
            }
        } else {
            createPublicationIntentHandler = nil
        }
        let createPublicationResolutionHandler: DockerSocketBridge.CreatePublicationResolutionHandler?
        if let forwarder {
            createPublicationResolutionHandler = { [weak forwarder] (resolution: DockerCreatePublicationResolution) in
                guard let forwarder else { return }
                forwarder.resolveCreatePublication(resolution)
            }
        } else {
            createPublicationResolutionHandler = nil
        }
        let containerStartIntentHandler: DockerSocketBridge.ContainerStartIntentHandler?
        if let forwarder {
            containerStartIntentHandler = { [weak forwarder] (request: DockerContainerStartRequest) in
                guard let forwarder else { return }
                forwarder.observeContainerStartIntent(request)
            }
        } else {
            containerStartIntentHandler = nil
        }
        let containerStartHandler: DockerSocketBridge.ContainerStartHandler?
        if let forwarder {
            containerStartHandler = { [weak forwarder] (request: DockerContainerStartRequest) in
                guard let forwarder else { return }
                forwarder.observeContainerStart(request)
            }
        } else {
            containerStartHandler = nil
        }

        if let forwarder {
            setProgress(state: .starting, phase: "port-forwarder", message: "starting published port forwarder")
            forwarder.start()
            publishedPortForwarder = forwarder
        } else {
            publishedPortForwarder = nil
        }

        setProgress(state: .starting, phase: "docker-socket", message: "exposing Docker socket")
        let managedHostMounts: DockerManagedHostMountCoordinator?
        if config.enableHostMounts {
            var allowedHostPathPrefixes = ["/Users"]
            if config.enableRemovableHostMounts {
                allowedHostPathPrefixes.append("/Volumes")
            }
            setProgress(
                state: .starting,
                phase: "file-sharing",
                message: "managed Docker host mount bridge enabled prefixes=\(allowedHostPathPrefixes.joined(separator: ","))"
            )
            managedHostMounts = DockerManagedHostMountCoordinator(
                connector: connector,
                allowedHostPathPrefixes: allowedHostPathPrefixes,
                requestGuestControlMounts: config.vmBackend != .hvfExperimental,
                requireGuestControlMounts: bridgeReadinessPolicy.requiresGuestControlMounts
                    && config.vmBackend != .hvfExperimental
            )
        } else {
            managedHostMounts = nil
        }

        let bridge = DockerSocketBridge(
            socketPath: manifest.dockerSocketPath,
            connector: connector,
            createPublicationIntentHandler: createPublicationIntentHandler,
            createPublicationResolutionHandler: createPublicationResolutionHandler,
            containerStartIntentHandler: containerStartIntentHandler,
            containerStartHandler: containerStartHandler,
            activityHandler: { [weak self] activity in
                self?.recordMemoryActivity()
                self?.dynamicMemoryManager?.handleDockerActivity(activity)
            },
            managedHostMounts: managedHostMounts,
            managedHostMountEventHandler: { [weak self] message in
                self?.setProgress(state: .running, phase: "file-sharing", message: message)
            }
        )
        do {
            try bridge.start()
            if bridgeReadinessPolicy.requiresDockerAPIProbe {
                if waitMode == .docker {
                    setProgress(state: .starting, phase: "docker-api", message: "waiting for guest Docker API readiness")
                    try GuestDockerAPIReadinessProbe.waitUntilReady(
                        connector: connector,
                        timeoutSeconds: 45,
                        intervalSeconds: 0.25
                    )
                } else {
                    setProgress(
                        state: .starting,
                        phase: "control-ready",
                        message: "guest bridge exposed; Docker API readiness probe deferred"
                    )
                }
            } else {
                setProgress(
                    state: .starting,
                    phase: "docker-api",
                    message: "legacy guest bridge exposed; Docker API readiness is handled by the guest bridge"
                )
            }
            if capabilities.guestControl {
                setProgress(state: .starting, phase: "guest-control", message: "verifying Jetstream guest control endpoint")
                guard try GuestControlClient(connector: connector).ping() else {
                    throw ConjetError.unavailable("Jetstream guest control endpoint did not return ok")
                }
            } else if bridgeReadinessPolicy.requiresGuestControlCapability {
                throw ConjetError.unavailable("conjet-netd-c is active but guest control endpoints are unavailable; rebuild/import the appliance image")
            }
        } catch {
            bridge.stop()
            forwarder?.stop()
            publishedPortForwarder = nil
            throw error
        }
        dockerBridge = bridge
    }

    private func waitForDockerAPIReady(
        socketPath: String,
        timeoutSeconds: TimeInterval = 45
    ) throws {
        setProgress(state: .starting, phase: "docker-ready", message: "waiting for Conjet Docker API readiness")
        try DockerSocketReadinessProbe(socketPath: socketPath).requireReady(
            timeoutSeconds: timeoutSeconds,
            intervalSeconds: 0.25
        )
        setProgress(state: .starting, phase: "docker-ready", message: "Conjet Docker API ready")
    }

    private func ensureGuestMemorySetup(socketPath: String) {
        setProgress(state: .starting, phase: "memory-setup", message: "ensuring guest zram and swap setup")
        do {
            let message = try DockerServiceQuiescer(socketPath: socketPath)
                .ensureGuestMemorySetup(timeoutSeconds: 120)
            setProgress(
                state: .starting,
                phase: "memory-setup",
                message: message.isEmpty ? "guest memory setup completed" : message
            )
        } catch {
            setProgress(state: .starting, phase: "memory-setup", message: "guest memory setup skipped: \(error)")
        }
    }

    private func probeJetstreamMemoryTelemetry(connector: any GuestConnectionConnector) {
        setDynamicMemoryTelemetryProgress(message: "probing Jetstream guest memory telemetry")
        let retryingConnector = RetryingGuestConnectionConnector(
            base: connector,
            timeoutSeconds: 12,
            intervalSeconds: 0.5
        )
        do {
            let metrics = try GuestMemoryMetricsClient(connector: retryingConnector).snapshot()
            let swapMiB = metrics.swapTotalBytes / 1024 / 1024
            let zramMiB = metrics.zramMemUsedTotalBytes / 1024 / 1024
            setDynamicMemoryTelemetryProgress(
                message: "Jetstream memory telemetry ready: swap=\(swapMiB) MiB zramUsed=\(zramMiB) MiB psiSomeAvg10=\(metrics.psiSomeAvg10)"
            )
        } catch {
            setDynamicMemoryTelemetryProgress(message: "Jetstream memory telemetry unavailable: \(error)")
        }
    }

    private func setDynamicMemoryTelemetryProgress(message: String) {
        let snapshot = progressSnapshot()
        guard let state = VMAsyncProgressPolicy.dynamicMemoryTelemetryState(current: snapshot.state) else {
            return
        }
        setProgress(state: state, phase: "dynamic-memory", message: message)
    }

    private func startDynamicMemoryManager(
        for machine: VZVirtualMachine,
        socketDevice: VZVirtioSocketDevice,
        config: ConjetConfig
    ) -> Bool {
        let policy = config.memoryPolicy
        guard policy.dynamicMemoryEnabled else {
            return false
        }
        guard let balloon = machine.memoryBalloonDevices
            .compactMap({ $0 as? VZVirtioTraditionalMemoryBalloonDevice })
            .first else {
            setProgress(state: .starting, phase: "dynamic-memory", message: "dynamic memory unavailable: VZ balloon device is missing")
            return false
        }

        stopDynamicMemoryManager()
        setProgress(state: .starting, phase: "dynamic-memory", message: "probing guest memory agent")
        let connector = RetryingGuestConnectionConnector(
            base: VZGuestConnectionConnector(
                socketDevice: socketDevice,
                queue: queue,
                port: ConjetRuntimePorts.memoryVsockPort,
                timeoutSeconds: 3
            ),
            timeoutSeconds: 8,
            intervalSeconds: 0.5
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let initialMetrics: GuestMemoryMetrics
        do {
            initialMetrics = try metricsClient.snapshot()
        } catch {
            setProgress(
                state: .starting,
                phase: "dynamic-memory",
                message: "guest memory agent unavailable; using legacy idle reclaim"
            )
            return false
        }

        let balloonBox = VZMemoryBalloonBox(balloon)
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { [weak self, balloonBox] targetBytes in
                guard let self else { return }
                try self.setMemoryBalloonTarget(targetBytes, device: balloonBox)
            }
        )
        dynamicMemoryManager = manager
        manager.start(initialMetrics: initialMetrics)
        return true
    }

    private func startRustDynamicMemoryManager(
        config: ConjetConfig,
        memorySocketPath: String,
        controlSocketPath: String
    ) -> Bool {
        let policy = config.memoryPolicy
        guard policy.dynamicMemoryEnabled else {
            return false
        }

        stopDynamicMemoryManager()
        setProgress(state: .starting, phase: "dynamic-memory", message: "probing Rust guest memory agent")
        let connector = RetryingGuestConnectionConnector(
            base: UnixSocketGuestConnectionConnector(socketPath: memorySocketPath, timeoutSeconds: 3),
            timeoutSeconds: 8,
            intervalSeconds: 0.5
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let initialMetrics: GuestMemoryMetrics
        do {
            initialMetrics = try waitForRustDynamicMemoryReadiness(
                metricsClient: metricsClient,
                controlSocketPath: controlSocketPath,
                timeoutSeconds: 60
            )
        } catch {
            setProgress(
                state: .starting,
                phase: "dynamic-memory",
                message: "Rust dynamic memory unavailable: \(error)"
            )
            return false
        }

        let controlClient = ConjetCoreRustMemoryControlClient(socketPath: controlSocketPath)
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { targetBytes in
                try controlClient.setTargetBytes(targetBytes)
            },
            hostFootprintBytes: {
                try controlClient.metrics().hostMemory.physicalFootprintBytes
            },
            hostMemorySnapshot: {
                let metrics = try controlClient.metrics()
                return HostMemoryRuntimeSnapshot(
                    physicalFootprintBytes: metrics.hostMemory.physicalFootprintBytes,
                    balloonActualPages: metrics.balloon.actualPages,
                    balloonInflatePages: metrics.balloon.inflatePages,
                    balloonDeflatePages: metrics.balloon.deflatePages,
                    balloonReportedFreePages: metrics.balloon.reportedFreePages,
                    balloonReportedFreeReclaimedBytes: metrics.balloon.reportedFreeReclaimedBytes,
                    balloonReclaimFailures: metrics.balloon.reclaimFailures,
                    balloonMalformedReports: metrics.balloon.malformedReports
                )
            }
        )
        dynamicMemoryManager = manager
        manager.start(initialMetrics: initialMetrics)
        setProgress(state: .starting, phase: "dynamic-memory", message: "Rust dynamic memory manager enabled")
        return true
    }

    private func waitForRustDynamicMemoryReadiness(
        metricsClient: GuestMemoryMetricsClient,
        controlSocketPath: String,
        timeoutSeconds: TimeInterval
    ) throws -> GuestMemoryMetrics {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?
        repeat {
            do {
                let metrics = try metricsClient.snapshot()
                _ = try ConjetCoreRustMemoryControlClient(socketPath: controlSocketPath).metrics()
                return metrics
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.5)
            }
        } while Date() < deadline
        throw lastError ?? ConjetError.unavailable("timed out waiting for Rust dynamic memory")
    }

    private func stopDynamicMemoryManager() {
        dynamicMemoryManager?.stop()
        dynamicMemoryManager = nil
    }

    private func startIdleMemoryReclaimer(config: ConjetConfig, store: VMImageStore) {
        let policy = config.memoryPolicy
        guard policy.automaticIdleMemoryReclaim,
              policy.idleMemoryReclaimTargetMiB < config.memoryMiB,
              policy.reclaimIdleHelpersAfterSeconds > 0 else {
            return
        }

        stopIdleMemoryReclaimer()
        idleMemoryReclaimLock.lock()
        idleMemoryReclaimRunning = true
        lastMemoryActivityAt = Date()
        lastIdleMemoryReclaimAt = nil
        idleMemoryReclaimLock.unlock()

        let thread = Thread { [weak self] in
            self?.idleMemoryReclaimLoop(config: config, store: store)
        }
        thread.name = "dev.conjet.idle-memory-reclaim"
        idleMemoryReclaimThread = thread
        thread.start()
    }

    private func stopIdleMemoryReclaimer() {
        idleMemoryReclaimLock.lock()
        idleMemoryReclaimRunning = false
        idleMemoryReclaimThread = nil
        idleMemoryReclaimLock.unlock()
    }

    private func recordMemoryActivity() {
        idleMemoryReclaimLock.lock()
        lastMemoryActivityAt = Date()
        idleMemoryReclaimLock.unlock()
    }

    private func markIdleMemoryReclaimed() {
        idleMemoryReclaimLock.lock()
        lastIdleMemoryReclaimAt = Date()
        idleMemoryReclaimLock.unlock()
    }

    private func idleMemoryReclaimLoop(config: ConjetConfig, store: VMImageStore) {
        let policy = config.memoryPolicy
        let idleThreshold = TimeInterval(policy.reclaimIdleHelpersAfterSeconds)
        let pollInterval = min(max(idleThreshold / 3, 10), 60)

        while idleMemoryReclaimerIsRunning() {
            Thread.sleep(forTimeInterval: pollInterval)
            guard idleMemoryReclaimerIsRunning() else { break }

            let snapshot = idleMemorySnapshot()
            let now = Date()
            guard now.timeIntervalSince(snapshot.lastActivityAt) >= idleThreshold else {
                continue
            }
            if let lastReclaimAt = snapshot.lastReclaimAt,
               lastReclaimAt >= snapshot.lastActivityAt {
                continue
            }

            do {
                _ = try reclaimIdleMemory(config: config, store: store, reason: "idle", timeoutSeconds: 8)
            } catch {
                markIdleMemoryReclaimed()
                setProgress(
                    state: .running,
                    phase: "memory-reclaim",
                    message: "idle memory reclaim skipped: \(error)"
                )
            }
        }
    }

    private func idleMemoryReclaimerIsRunning() -> Bool {
        idleMemoryReclaimLock.lock()
        let value = idleMemoryReclaimRunning
        idleMemoryReclaimLock.unlock()
        return value
    }

    private func idleMemorySnapshot() -> (lastActivityAt: Date, lastReclaimAt: Date?) {
        idleMemoryReclaimLock.lock()
        let snapshot = (lastMemoryActivityAt, lastIdleMemoryReclaimAt)
        idleMemoryReclaimLock.unlock()
        return snapshot
    }

    private func setMemoryBalloonTarget(_ targetBytes: UInt64, device: VZMemoryBalloonBox) throws {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            device.balloon.targetVirtualMachineMemorySize = targetBytes
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            throw ConjetError.unavailable("timed out setting VZ memory balloon target")
        }
    }

    private static func memoryBytes(mib: Int) -> UInt64 {
        UInt64(max(0, mib)) * 1024 * 1024
    }
    #endif

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
        #if canImport(Virtualization)
        if let dynamicMemoryManager {
            enriched.memory = dynamicMemoryManager.status()
        }
        #endif
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

#if canImport(Virtualization)
private extension VirtualMachineController {
    static func bridgeFallbackReason(
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
}

struct GuestDockerBridgeReadinessPolicy: Equatable {
    var requiresDockerAPIProbe: Bool
    var requiresGuestControlCapability: Bool
    var requiresGuestControlMounts: Bool

    static func resolve(
        requested: ConjetNetworkBridgeEngine,
        capabilities: GuestBridgeCapabilities
    ) -> GuestDockerBridgeReadinessPolicy {
        let guestControlReadyBridge = capabilities.guestControl
        let requestedConjetNetdC = requested == .conjetNetdC && guestControlReadyBridge
        return GuestDockerBridgeReadinessPolicy(
            requiresDockerAPIProbe: requestedConjetNetdC || guestControlReadyBridge,
            requiresGuestControlCapability: requestedConjetNetdC,
            requiresGuestControlMounts: requestedConjetNetdC || guestControlReadyBridge
        )
    }
}

enum VMAsyncProgressPolicy {
    static func dynamicMemoryTelemetryState(current: VMRunState) -> VMRunState? {
        switch current {
        case .running:
            return .running
        case .starting:
            return .starting
        default:
            return nil
        }
    }
}

private struct VZRuntimeResources {
    var serialLogHandle: FileHandle
}

private struct VZConfiguredMachine {
    var configuration: VZVirtualMachineConfiguration
    var resources: VZRuntimeResources
}

private enum VZConfigurationBuilder {
    static func build(manifest: VMAssetManifest, config: ConjetConfig) throws -> VZConfiguredMachine {
        try VMImageStore().validateManifest(manifest)

        let vmConfig = VZVirtualMachineConfiguration()
        if #available(macOS 12.0, *) {
            vmConfig.platform = VZGenericPlatformConfiguration()
        }

        vmConfig.bootLoader = try bootLoader(manifest: manifest)
        let minimumCPUCount = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maximumCPUCount = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let requestedCPUs: Int
        switch config.energyMode {
        case .performance, .balanced:
            requestedCPUs = config.vmCPUs
        case .eco:
            requestedCPUs = max(1, config.vmCPUs / 2)
        }
        vmConfig.cpuCount = max(minimumCPUCount, min(requestedCPUs, maximumCPUCount))
        vmConfig.memorySize = UInt64(config.memoryMiB) * 1024 * 1024

        vmConfig.storageDevices = try storageDevices(manifest: manifest)
        vmConfig.networkDevices = [networkDevice()]
        vmConfig.serialPorts = [try serialPort(path: manifest.serialLogPath)]
        vmConfig.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vmConfig.directorySharingDevices = try directoryShares(manifest: manifest, config: config)

        let serialLogHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: manifest.serialLogPath))
        try serialLogHandle.seekToEnd()
        return VZConfiguredMachine(configuration: vmConfig, resources: VZRuntimeResources(serialLogHandle: serialLogHandle))
    }

    private static func bootLoader(manifest: VMAssetManifest) throws -> VZBootLoader {
        switch manifest.bootLoaderKind {
        case .linuxKernel:
            let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: manifest.kernelPath))
            bootLoader.commandLine = manifest.kernelCommandLine
            if let initialRamdiskPath = manifest.initialRamdiskPath {
                bootLoader.initialRamdiskURL = URL(fileURLWithPath: initialRamdiskPath)
            }
            return bootLoader
        case .efiDisk:
            guard #available(macOS 13.0, *) else {
                throw ConjetError.unavailable("EFI disk boot requires macOS 13.0 or newer")
            }
            guard let variableStorePath = manifest.efiVariableStorePath, !variableStorePath.isEmpty else {
                throw ConjetError.unavailable("EFI disk boot requires efiVariableStorePath in the VM manifest")
            }
            let variableStoreURL = URL(fileURLWithPath: variableStorePath)
            let variableStore: VZEFIVariableStore
            if FileManager.default.fileExists(atPath: variableStoreURL.path) {
                variableStore = VZEFIVariableStore(url: variableStoreURL)
            } else {
                try FileManager.default.createDirectory(
                    at: variableStoreURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                variableStore = try VZEFIVariableStore(creatingVariableStoreAt: variableStoreURL, options: [])
            }
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = variableStore
            return bootLoader
        case .linuxArm64CompressedEfiZboot:
            throw ConjetError.unavailable("compressed ARM64 EFI zboot artifacts need EFI disk boot, not VZLinuxBootLoader")
        }
    }

    private static func storageDevices(manifest: VMAssetManifest) throws -> [VZStorageDeviceConfiguration] {
        switch manifest.bootLoaderKind {
        case .efiDisk:
            let bootDisk = manifest.bootDiskPath ?? manifest.rootDiskPath
            var devices: [VZStorageDeviceConfiguration] = [
                try blockDevice(path: bootDisk, identifier: "conjet-efi-boot", readOnly: false)
            ]
            if let dataDiskPath = manifest.dataDiskPath {
                devices.append(try blockDevice(path: dataDiskPath, identifier: "conjet-data", readOnly: false))
            }
            if let swapDiskPath = manifest.swapDiskPath {
                devices.append(try ephemeralSwapBlockDevice(path: swapDiskPath))
            }
            if let cloudInitSeedPath = manifest.cloudInitSeedPath {
                devices.append(try blockDevice(path: cloudInitSeedPath, identifier: "conjet-cloud-init", readOnly: true))
            }
            return devices
        case .linuxKernel, .linuxArm64CompressedEfiZboot:
            var devices: [VZStorageDeviceConfiguration]
            if #available(macOS 14.0, *) {
                devices = [
                    try nvmeDevice(path: manifest.rootDiskPath, identifier: "conjet-root", readOnly: false)
                ]
                if let dataDiskPath = manifest.dataDiskPath {
                    devices.append(try nvmeDevice(path: dataDiskPath, identifier: "conjet-data", readOnly: false))
                }
            } else {
                devices = [
                    try blockDevice(path: manifest.rootDiskPath, identifier: "conjet-root", readOnly: false)
                ]
                if let dataDiskPath = manifest.dataDiskPath {
                    devices.append(try blockDevice(path: dataDiskPath, identifier: "conjet-data", readOnly: false))
                }
            }
            if let swapDiskPath = manifest.swapDiskPath {
                if #available(macOS 14.0, *) {
                    try recreateSparseDisk(path: swapDiskPath, fallbackSizeBytes: 8 * 1024 * 1024 * 1024)
                    devices.append(try nvmeDevice(path: swapDiskPath, identifier: "conjet-swap", readOnly: false))
                } else {
                    devices.append(try ephemeralSwapBlockDevice(path: swapDiskPath))
                }
            }
            return devices
        }
    }

    private static func ephemeralSwapBlockDevice(path: String) throws -> VZVirtioBlockDeviceConfiguration {
        try recreateSparseDisk(path: path, fallbackSizeBytes: 8 * 1024 * 1024 * 1024)
        return try blockDevice(path: path, identifier: "conjet-swap", readOnly: false)
    }

    private static func recreateSparseDisk(path: String, fallbackSizeBytes: UInt64) throws {
        let manager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let currentSize = (try? manager.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        let size = max(currentSize, fallbackSizeBytes)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: path) {
            try manager.removeItem(at: url)
        }
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ConjetError.filesystem("open(\(path)) failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw ConjetError.filesystem("ftruncate(\(path)) failed: \(String(cString: strerror(errno)))")
        }
    }

    private static func blockDevice(path: String, identifier: String, readOnly: Bool) throws -> VZVirtioBlockDeviceConfiguration {
        let attachment: VZDiskImageStorageDeviceAttachment
        if #available(macOS 12.0, *) {
            let modes = diskImageModes(identifier: identifier, readOnly: readOnly)
            attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: path),
                readOnly: readOnly,
                cachingMode: modes.caching,
                synchronizationMode: modes.synchronization
            )
        } else {
            attachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: readOnly)
        }
        let device = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        if #available(macOS 12.3, *) {
            device.blockDeviceIdentifier = identifier
        }
        return device
    }

    @available(macOS 14.0, *)
    private static func nvmeDevice(
        path: String,
        identifier: String,
        readOnly: Bool
    ) throws -> VZNVMExpressControllerDeviceConfiguration {
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: path),
            readOnly: readOnly,
            cachingMode: .automatic,
            synchronizationMode: readOnly ? .fsync : .none
        )
        return VZNVMExpressControllerDeviceConfiguration(attachment: attachment)
    }

    @available(macOS 12.0, *)
    private static func diskImageModes(
        identifier: String,
        readOnly: Bool
    ) -> (caching: VZDiskImageCachingMode, synchronization: VZDiskImageSynchronizationMode) {
        if readOnly {
            return (.automatic, .fsync)
        }
        if identifier == "conjet-data" {
            return (.cached, .none)
        }
        return (.automatic, .fsync)
    }

    private static func networkDevice() -> VZVirtioNetworkDeviceConfiguration {
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        return network
    }

    private static func serialPort(path: String) throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try output.seekToEnd()
        let attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: output)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = attachment
        return serial
    }

    private static func directoryShares(manifest: VMAssetManifest, config: ConjetConfig) throws -> [VZDirectorySharingDeviceConfiguration] {
        var devices: [VZDirectorySharingDeviceConfiguration] = []

        let bootstrapDevice = VZVirtioFileSystemDeviceConfiguration(tag: "conjetboot")
        let bootstrapDirectory = VZSharedDirectory(url: URL(fileURLWithPath: manifest.bootstrapSharePath), readOnly: false)
        bootstrapDevice.share = VZSingleDirectoryShare(directory: bootstrapDirectory)
        devices.append(bootstrapDevice)

        if config.enableHostMounts {
            devices.append(contentsOf: hostDirectoryShares(includeRemovableVolumes: config.enableRemovableHostMounts))
        }

        #if arch(arm64)
        if config.enableRosetta, #available(macOS 13.0, *), VZLinuxRosettaDirectoryShare.availability == .installed {
            let rosettaDevice = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            rosettaDevice.share = try? VZLinuxRosettaDirectoryShare()
            if rosettaDevice.share != nil {
                devices.append(rosettaDevice)
            }
        }
        #endif

        return devices
    }

    private static func hostDirectoryShares(includeRemovableVolumes: Bool) -> [VZDirectorySharingDeviceConfiguration] {
        var hostShares = [("conjethostusers", "/Users")]
        if includeRemovableVolumes {
            hostShares.append(("conjethostvolumes", "/Volumes"))
        }
        return hostShares.compactMap { tag, path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            let directory = VZSharedDirectory(url: URL(fileURLWithPath: path, isDirectory: true), readOnly: false)
            device.share = VZSingleDirectoryShare(directory: directory)
            return device
        }
    }
}
#endif

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

#if canImport(Virtualization)
private final class VZMachineBox: @unchecked Sendable {
    let machine: VZVirtualMachine

    init(_ machine: VZVirtualMachine) {
        self.machine = machine
    }
}

private final class VZMemoryBalloonBox: @unchecked Sendable {
    let balloon: VZVirtioTraditionalMemoryBalloonDevice

    init(_ balloon: VZVirtioTraditionalMemoryBalloonDevice) {
        self.balloon = balloon
    }
}
#endif

import ConjetCore
import ConjetPower
import ConjetVZ
import Darwin
import Foundation

@main
struct ConjetDaemon {
    static func main() {
        do {
            try serve()
        } catch {
            FileHandle.standardError.write(Data("Conjet Core: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func serve() throws {
        let paths = ConjetPaths.default()
        try paths.ensureBaseDirectories()
        let instanceLock = try DaemonInstanceLock.acquire(
            path: paths.runDirectory.appendingPathComponent("conjetd.lock").path
        )
        defer { instanceLock.release() }
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        let socketPath = config.socketPath ?? paths.socket.path
        let policy = EnergyGovernor(
            configuredVCPUs: config.vmCPUs,
            quietStopSeconds: Double(config.quietStopMinutes) * 60,
            mode: config.energyMode
        ).policy(for: .warmIdle)
        let logger = try DaemonLogger(
            path: paths.daemonLog,
            flushInterval: TimeInterval(policy.statusPersistenceMinIntervalMilliseconds) / 1_000
        )
        let runtime = DaemonRuntime(
            startedAt: Date(),
            socketPath: socketPath,
            config: config
        )

        try logger.log("daemon_start", [
            "profile": paths.profileName,
            "socket": socketPath,
            "vmCPUs": String(config.vmCPUs),
            "memoryMiB": String(config.memoryMiB),
            "architecture": config.architecture,
            "diskGiB": String(config.diskGiB),
            "runtime": config.runtime,
            "vmBackend": config.vmBackend.rawValue,
            "energyMode": config.energyMode.rawValue,
            "memoryProfile": config.memoryProfile.rawValue
        ])

        let server = UnixSocketServer(socketPath: socketPath)
        let stopFlag = DaemonStopFlag()
        try server.listen { request in
            let response = runtime.handle(request: request, stopFlag: stopFlag)
            runtime.recordCommandFinished(request: request, response: response)
            try? logger.log("request", [
                "command": request.command.rawValue,
                "ok": String(response.ok)
            ])
            return response
        } streamHandler: { request, writer in
            let handled = try runtime.handleStream(request: request, writer: writer, stopFlag: stopFlag)
            if handled {
                try? logger.log("stream", ["command": request.command.rawValue])
            }
            return handled
        } shouldStop: {
            stopFlag.isSet()
        }

        try logger.log("daemon_stop", ["socket": socketPath])
    }
}

private final class DaemonStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func set(_ value: Bool) {
        lock.lock()
        stopped = value
        lock.unlock()
    }

    func isSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private final class DaemonInstanceLock {
    private let fd: Int32
    private let path: String

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    static func acquire(path: String) throws -> DaemonInstanceLock {
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ConjetError.socket("open(\(path)) failed: \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = String(cString: strerror(errno))
            close(fd)
            throw ConjetError.unavailable("another Conjet Core is already running for this profile: \(error)")
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return DaemonInstanceLock(fd: fd, path: path)
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
        unlink(path)
    }
}

private final class DaemonRuntime: @unchecked Sendable {
    private struct CachedStatus {
        var status: DaemonStatus
        var createdAt: Date
    }

    let startedAt: Date
    let socketPath: String
    let config: ConjetConfig
    let host: HostCapabilities
    let paths: ConjetPaths
    let vmStore: VMImageStore
    let vmController: VirtualMachineController
    let governor: EnergyGovernor
    let pulse: ConjetPulseLog
    private var dockerEventAdapter: DaemonDockerEventAdapter?
    private let statusCacheLock = NSLock()
    private var cachedStatus: CachedStatus?
    private let statusCacheTTL: TimeInterval

    init(
        startedAt: Date,
        socketPath: String,
        config: ConjetConfig,
        paths: ConjetPaths = .default(),
        pulse: ConjetPulseLog = ConjetPulseLog()
    ) {
        self.startedAt = startedAt
        self.socketPath = socketPath
        self.config = config
        self.paths = paths
        self.vmStore = VMImageStore(paths: paths)
        self.vmController = VirtualMachineController()
        self.pulse = pulse
        self.governor = EnergyGovernor(
            configuredVCPUs: config.vmCPUs,
            quietStopSeconds: Double(config.quietStopMinutes) * 60,
            mode: config.energyMode
        )
        self.statusCacheTTL = TimeInterval(governor.policy(for: .warmIdle).statusPersistenceMinIntervalMilliseconds) / 1_000
        self.host = HostCapabilities.detect()
        _ = VirtualizationProbe.inspect(config: config, host: host)
        self.dockerEventAdapter = DaemonDockerEventAdapter(
            socketPath: paths.dockerSocket.path,
            energyMode: config.energyMode,
            emit: { [weak self] event in
                self?.publishDockerRuntimeEvent(event)
            }
        )
        publish(.daemonStarted, subjectID: paths.profileName, message: "Conjet Core started", payload: [
            "profile": paths.profileName,
            "socket": socketPath,
            "pid": String(getpid())
        ])
        startDockerEventAdapterIfPossible()
        startClockWakeMonitor()
    }

    deinit {
        dockerEventAdapter?.stop()
    }

    func handleStream(
        request: DaemonRequest,
        writer: UnixSocketJSONLineWriter,
        stopFlag: DaemonStopFlag
    ) throws -> Bool {
        guard request.command == .pulseSubscribe else { return false }

        let sinceSequence = request.parameters["since_seq"].flatMap(UInt64.init) ?? 0
        let heartbeatSeconds = request.parameters["heartbeat_seconds"].flatMap(Double.init)
            .map { min(max($0, 1), 60) }
            ?? 15
        var lastSequence = sinceSequence
        let replay = pulse.replay(after: lastSequence)
        try writer.write(ConjetPulseFrame.replay(replay))
        lastSequence = replay.state.highWatermark

        while !stopFlag.isSet() {
            let nextReplay = pulse.waitForReplay(after: lastSequence, timeout: heartbeatSeconds)
            if nextReplay.events.isEmpty {
                try writer.write(ConjetPulseFrame.heartbeat(state: nextReplay.state))
                continue
            }

            try writer.write(ConjetPulseFrame.events(nextReplay))
            lastSequence = nextReplay.state.highWatermark
        }

        return true
    }

    func handle(request: DaemonRequest, stopFlag: DaemonStopFlag) -> DaemonResponse {
        switch request.command {
        case .ping:
            return response(ok: true, message: "pong", status: status(state: .warmIdle, allowCache: true))
        case .status:
            return response(ok: true, message: "running", status: status(state: .warmIdle, allowCache: true))
        case .vmStatus:
            let vm = vmController.status(store: vmStore, backend: config.vmBackend)
            return response(ok: vm.configured, message: vm.message, status: status(state: runtimeState(for: vm), vm: vm), vm: vm)
        case .vmStart:
            let waitMode: VMStartWaitMode
            do {
                waitMode = try VMStartWaitMode(requestValue: request.parameters[VMStartWaitMode.requestParameterKey])
            } catch {
                return response(ok: false, message: String(describing: error), status: status(state: .warmIdle))
            }
            publish(.vmStarting, subjectID: "vm", message: "VM start requested", payload: [
                "wait": waitMode.rawValue
            ])
            do {
                invalidateStatusCache()
                let manifest = try vmStore.loadManifest()
                let vm = try vmController.start(manifest: manifest, config: config, store: vmStore, waitMode: waitMode)
                writeFastPathRunningStatus(vm: vm, waitMode: waitMode)
                repairClockAsync(reason: "vm-start")
                invalidateStatusCache()
                publishVMEvent(.vmStarted, vm: vm)
                startDockerEventAdapterIfPossible()
                return response(ok: true, message: vm.message, status: status(state: runtimeState(for: vm), vm: vm), vm: vm)
            } catch {
                invalidateStatusCache()
                let vm = vmStore.status(state: .error, message: String(describing: error))
                publishVMEvent(.vmErrored, vm: vm)
                return response(ok: false, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            }
        case .vmStop:
            publish(.vmStopping, subjectID: "vm", message: "VM stop requested")
            dockerEventAdapter?.stop()
            do {
                invalidateStatusCache()
                let vm = try vmController.stop(store: vmStore, backend: config.vmBackend)
                removeFastPathRunningStatus()
                invalidateStatusCache()
                publishVMEvent(.vmStopped, vm: vm)
                return response(ok: true, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            } catch {
                invalidateStatusCache()
                let vm = vmStore.status(state: .error, message: String(describing: error))
                publishVMEvent(.vmErrored, vm: vm)
                return response(ok: false, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            }
        case .dockerRun:
            guard let image = request.arguments.first else {
                return response(ok: false, message: "docker-run requires an image")
            }
            do {
                if let initializingMessage = waitForDockerIfInitializing(parameters: request.parameters) {
                    let result = DockerRunResult(
                        image: image,
                        command: Array(request.arguments.dropFirst()),
                        dockerHost: "unix://\(paths.dockerSocket.path)",
                        exitCode: nil,
                        stderrTail: initializingMessage
                    )
                    return response(ok: false, message: initializingMessage, status: status(state: .warmIdle), dockerRun: result)
                }
                let result = try DockerRunExecutor(
                    socketPath: paths.dockerSocket.path,
                    requestedBackend: config.vmBackend,
                    rosettaAvailable: HostCapabilities.detect().rosettaLinuxSupportLikelyAvailable
                )
                .run(
                    image: image,
                    command: Array(request.arguments.dropFirst()),
                    platform: request.parameters["platform"]
                )
                let ok = result.exitCode == 0
                let message = ok ? "container exited successfully" : (result.stderrTail.isEmpty ? "container did not run" : result.stderrTail)
                publish(.dockerRunFinished, subjectID: image, message: message, payload: [
                    "image": image,
                    "exitCode": result.exitCode.map(String.init) ?? ""
                ])
                return response(ok: ok, message: message, status: status(state: .warmIdle), dockerRun: result)
            } catch {
                publish(.dockerRunFinished, subjectID: image, message: String(describing: error), payload: [
                    "image": image,
                    "ok": "false"
                ])
                return response(ok: false, message: String(describing: error), status: status(state: .warmIdle))
            }
        case .dockerCompose:
            guard DockerComposeExecutor.containsUpCommand(request.arguments) else {
                return response(ok: false, message: "docker-compose requires an 'up' command")
            }
            do {
                if let initializingMessage = waitForDockerIfInitializing(parameters: request.parameters) {
                    let result = DockerComposeResult(
                        arguments: request.arguments,
                        dockerHost: "unix://\(paths.dockerSocket.path)",
                        executable: "",
                        exitCode: nil,
                        stderrTail: initializingMessage
                    )
                    return response(ok: false, message: initializingMessage, status: status(state: .warmIdle), dockerCompose: result)
                }
                let result = try DockerComposeExecutor(socketPath: paths.dockerSocket.path)
                    .up(arguments: request.arguments)
                let ok = result.exitCode == 0
                let message = ok
                    ? "compose completed successfully"
                    : (result.stderrTail.isEmpty ? "compose command did not complete successfully" : result.stderrTail)
                return response(ok: ok, message: message, status: status(state: .warmIdle), dockerCompose: result)
            } catch {
                return response(ok: false, message: String(describing: error), status: status(state: .warmIdle))
            }
        case .networkRepair:
            invalidateStatusCache()
            let network = vmController.repairNetwork(config: config)
            invalidateStatusCache()
            publish(.networkChanged, subjectID: "network", message: "network repair completed", payload: [
                "activeTCPForwards": String(network.activeTCPForwards),
                "activeUDPForwards": String(network.activeUDPForwards),
                "failedForwards": String(network.failedForwards)
            ])
            return response(
                ok: true,
                message: "network repair completed",
                status: status(state: .warmIdle, network: network)
            )
        case .clockRepair:
            invalidateStatusCache()
            let repaired = repairClock(reason: request.parameters["reason"] ?? "command")
            invalidateStatusCache()
            publish(.clockRepaired, subjectID: "clock", message: repaired ? "clock repair completed" : "clock repair skipped or failed", payload: [
                "ok": String(repaired)
            ])
            return response(
                ok: repaired,
                message: repaired ? "clock repair completed" : "clock repair skipped or failed",
                status: status(state: .warmIdle)
            )
        case .pruneCache:
            invalidateStatusCache()
            let network = vmController.pruneCache(config: config)
            invalidateStatusCache()
            publish(.cachePruned, subjectID: "runtime", message: "runtime cache pruned")
            return response(
                ok: true,
                message: "runtime cache pruned",
                status: status(state: .warmIdle, network: network)
            )
        case .memoryReclaim:
            invalidateStatusCache()
            do {
                let vm = try vmController.reclaimIdleMemory(config: config, store: vmStore, reason: "manual")
                invalidateStatusCache()
                publish(.memoryReclaimed, subjectID: "vm", message: "idle memory reclaim requested", payload: [
                    "profile": config.memoryProfile.rawValue,
                    "targetMiB": String(config.memoryPolicy.idleMemoryReclaimTargetMiB),
                    "configuredMiB": String(config.memoryMiB)
                ])
                return response(
                    ok: true,
                    message: "idle memory reclaim requested",
                    status: status(state: runtimeState(for: vm), vm: vm),
                    vm: vm
                )
            } catch {
                invalidateStatusCache()
                let vm = vmStore.status(state: .error, message: String(describing: error))
                publish(.memoryReclaimed, subjectID: "vm", message: "idle memory reclaim failed", payload: [
                    "ok": "false",
                    "error": String(describing: error)
                ])
                return response(ok: false, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            }
        case .memoryHardDrop:
            invalidateStatusCache()
            do {
                let dropMiB = request.parameters["drop_mib"].flatMap(UInt64.init)
                    ?? UInt64(config.memoryPolicy.idleMemoryReclaimTargetMiB)
                let dropBytes = dropMiB > UInt64.max / 1_048_576
                    ? UInt64.max
                    : dropMiB * 1_048_576
                let result = try vmController.hardDropIdleMemory(
                    config: config,
                    store: vmStore,
                    dropBytes: dropBytes
                )
                invalidateStatusCache()
                let vm = status(state: .warmIdle).vm
                    ?? vmStore.status(state: .running, message: result.message)
                publish(.memoryReclaimed, subjectID: "vm", message: "hard memory drop completed", payload: [
                    "requestedBytes": String(result.requestedBytes),
                    "guestOfflinedBytes": String(result.guestOfflinedBytes),
                    "hostDecommittedBytes": String(result.hostDecommittedBytes)
                ])
                return response(
                    ok: true,
                    message: result.message,
                    status: status(state: .warmIdle, vm: vm),
                    vm: vm,
                    memoryHardDrop: result
                )
            } catch {
                invalidateStatusCache()
                let vm = vmController.status(store: vmStore, backend: config.vmBackend)
                publish(.memoryReclaimed, subjectID: "vm", message: "hard memory drop failed", payload: [
                    "ok": "false",
                    "error": String(describing: error)
                ])
                return response(ok: false, message: String(describing: error), status: status(state: .warmIdle, vm: vm), vm: vm)
            }
        case .pulseSubscribe:
            return response(ok: false, message: "pulse-subscribe requires a streaming connection")
        case .stop:
            invalidateStatusCache()
            let cleanupTimeout = request.parameters["timeout_seconds"].flatMap(Double.init)
                .map { min(max($0, 0.1), 300) }
                ?? 25
            dockerEventAdapter?.stop()
            let semaphore = DispatchSemaphore(value: 0)
            let cleanupError = AsyncErrorBox()
            let backend = config.vmBackend
            DispatchQueue.global(qos: .utility).async { [vmController, vmStore, backend] in
                do {
                    _ = try vmController.stop(store: vmStore, backend: backend)
                } catch {
                    cleanupError.set(error)
                }
                semaphore.signal()
            }
            let boundedWait = cleanupTimeout
            let cleanupTimedOut = semaphore.wait(timeout: .now() + boundedWait) == .timedOut
            let message: String
            let ok: Bool
            if cleanupTimedOut {
                ok = false
                message = "Conjet Core stopping; cleanup still in progress after \(String(format: "%.1f", boundedWait))s"
            } else if let error = cleanupError.get() {
                ok = false
                message = "Conjet Core stopping; cleanup failed separately: \(error)"
            } else {
                stopFlag.set(true)
                ok = true
                message = "Conjet Core stopping; cleanup completed"
            }
            let vm = vmStore.status(state: ok ? .stopping : .error, message: message)
            publish(.daemonStopping, subjectID: paths.profileName, message: message, payload: [
                "ok": String(ok)
            ])
            return response(ok: ok, message: message, status: status(state: ok ? .stopping : .warmIdle, vm: vm), vm: vm)
        }
    }

    func recordCommandFinished(request: DaemonRequest, response: DaemonResponse) {
        guard request.command.shouldPublishCommandFinished else { return }
        publish(.commandFinished, subjectID: request.command.rawValue, message: response.message, payload: [
            "command": request.command.rawValue,
            "ok": String(response.ok)
        ])
    }

    private func response(
        ok: Bool,
        message: String,
        status: DaemonStatus? = nil,
        vm: VMRuntimeStatus? = nil,
        dockerRun: DockerRunResult? = nil,
        dockerCompose: DockerComposeResult? = nil,
        memoryHardDrop: ConjetMemoryHardDropResult? = nil
    ) -> DaemonResponse {
        DaemonResponse(
            ok: ok,
            message: message,
            status: status,
            vm: vm,
            dockerRun: dockerRun,
            dockerCompose: dockerCompose,
            pulse: pulse.state(),
            memoryHardDrop: memoryHardDrop
        )
    }

    private func publishVMEvent(_ type: ConjetPulseEventType, vm: VMRuntimeStatus) {
        publish(type, subjectID: "vm", message: vm.message, payload: [
            "state": vm.state.rawValue,
            "configured": String(vm.configured),
            "phase": vm.phase ?? ""
        ])
    }

    private func publish(
        _ type: ConjetPulseEventType,
        subjectID: String? = nil,
        message: String = "",
        payload: [String: String] = [:],
        at: Date = Date()
    ) {
        pulse.append(type: type, subjectID: subjectID, message: message, payload: payload, at: at)
        invalidateStatusCache()
    }

    private func publishDockerRuntimeEvent(_ event: ConjetDockerRuntimeEvent) {
        guard let type = event.pulseEventType else { return }
        publish(
            type,
            subjectID: event.subjectID,
            message: "\(event.objectType).\(event.eventName)",
            payload: event.pulsePayload,
            at: event.occurredAt ?? Date()
        )
    }

    private func startDockerEventAdapterIfPossible() {
        dockerEventAdapter?.startIfSocketAvailable()
    }

    private func waitForDockerIfInitializing(parameters: [String: String]) -> String? {
        guard isUnixSocket(paths.dockerSocket.path) else {
            return nil
        }
        let timeoutSeconds = parameters["docker_wait_seconds"]
            .flatMap(TimeInterval.init)
            .map { min(max($0, 0), 120) }
            ?? 30
        let probe = DockerSocketReadinessProbe(socketPath: paths.dockerSocket.path)
        if probe.ping(timeoutSeconds: 0.5) {
            return nil
        }
        publish(.vmStarting, subjectID: "docker", message: "Docker API is initializing", payload: [
            "socket": paths.dockerSocket.path,
            "timeoutSeconds": String(Int(timeoutSeconds))
        ])
        guard probe.waitUntilReady(timeoutSeconds: timeoutSeconds, intervalSeconds: 0.25) else {
            return "Conjet Docker API is still initializing at \(paths.dockerSocket.path); retry shortly or run 'conjet vm prepare-fast --wait docker'."
        }
        return nil
    }

    private func isUnixSocket(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func writeFastPathRunningStatus(vm: VMRuntimeStatus, waitMode: VMStartWaitMode) {
        let statusDirectory = paths.runDirectory.appendingPathComponent("status", isDirectory: true)
        let statusPath = statusDirectory.appendingPathComponent("running")
        do {
            try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
            let body = [
                "state=\(vm.state.rawValue)",
                "backend=\(vm.backend?.rawValue ?? config.vmBackend.rawValue)",
                "phase=\(vm.phase ?? "")",
                "wait=\(waitMode.rawValue)",
                "docker_socket=\(vm.dockerSocketPath ?? paths.dockerSocket.path)",
                "updated_at=\(ISO8601DateFormatter().string(from: Date()))"
            ].joined(separator: "\n") + "\n"
            try body.write(to: statusPath, atomically: true, encoding: .utf8)
        } catch {
            publish(.vmStarting, subjectID: "fastpath-status", message: "could not write FastPath status: \(error)")
        }
    }

    private func removeFastPathRunningStatus() {
        let statusPath = paths.runDirectory
            .appendingPathComponent("status", isDirectory: true)
            .appendingPathComponent("running")
        try? FileManager.default.removeItem(at: statusPath)
    }

    private func status(
        state: RuntimeState,
        vm: VMRuntimeStatus? = nil,
        network: ConjetNetworkStatus? = nil,
        allowCache: Bool = false
    ) -> DaemonStatus {
        if allowCache, vm == nil, network == nil, let cached = currentCachedStatus() {
            return cached
        }

        let effectiveVM = vm ?? vmController.status(store: vmStore, backend: config.vmBackend)
        let snapshot = DaemonStatus(
            pid: getpid(),
            startedAt: startedAt,
            state: state,
            socketPath: socketPath,
            host: host,
            config: config,
            vm: effectiveVM,
            network: network ?? vmController.networkStatus(config: config)
        )
        if allowCache, vm == nil, network == nil {
            storeCachedStatus(snapshot)
        }
        return snapshot
    }

    private func currentCachedStatus() -> DaemonStatus? {
        statusCacheLock.lock()
        defer { statusCacheLock.unlock() }
        guard let cachedStatus,
              Date().timeIntervalSince(cachedStatus.createdAt) <= statusCacheTTL else {
            self.cachedStatus = nil
            return nil
        }
        return cachedStatus.status
    }

    private func storeCachedStatus(_ status: DaemonStatus) {
        statusCacheLock.lock()
        cachedStatus = CachedStatus(status: status, createdAt: Date())
        statusCacheLock.unlock()
    }

    private func invalidateStatusCache() {
        statusCacheLock.lock()
        cachedStatus = nil
        statusCacheLock.unlock()
    }

    private func startClockWakeMonitor() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var lastWallClock = Date()
            while true {
                Thread.sleep(forTimeInterval: 30)
                let now = Date()
                let gap = now.timeIntervalSince(lastWallClock)
                lastWallClock = now
                if gap > 45 {
                    self?.repairClockAsync(reason: "wake-gap-\(Int(gap))s")
                }
            }
        }
    }

    private func repairClockAsync(reason: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.repairClock(reason: reason)
        }
    }

    @discardableResult
    private func repairClock(reason: String) -> Bool {
        guard FileManager.default.fileExists(atPath: paths.dockerSocket.path) else {
            return false
        }
        let epochMs = Int(Date().timeIntervalSince1970 * 1000)
        let seconds = epochMs / 1000
        let milliseconds = epochMs % 1000
        let timestamp = "\(seconds).\(String(format: "%03d", milliseconds))"
        let script = """
        if command -v timedatectl >/dev/null 2>&1; then timedatectl set-ntp false >/dev/null 2>&1 || true; fi
        date -u -s @\(timestamp) >/dev/null 2>&1 || date -u -s @\(seconds) >/dev/null
        hwclock -w >/dev/null 2>&1 || true
        """
        do {
            let result = try ProcessRunner.run("/usr/bin/env", [
                "docker",
                "--host",
                "unix://\(paths.dockerSocket.path)",
                "run",
                "--rm",
                "--privileged",
                "--pid=host",
                "--net=host",
                "--ipc=host",
                "--uts=host",
                "ubuntu:24.04",
                "nsenter",
                "-t",
                "1",
                "-m",
                "-u",
                "-i",
                "-n",
                "-p",
                "--",
                "sh",
                "-lc",
                script
            ], timeoutSeconds: 30)
            return result.succeeded
        } catch {
            return false
        }
    }

    private func runtimeState(for vm: VMRuntimeStatus) -> RuntimeState {
        switch vm.state {
        case .running:
            return .warmIdle
        case .starting:
            return .interactive
        case .stopping:
            return .stopping
        case .error, .stopped, .unconfigured:
            return .cold
        }
    }
}

private extension DaemonCommand {
    var shouldPublishCommandFinished: Bool {
        switch self {
        case .ping, .status, .vmStatus, .pulseSubscribe:
            false
        case .stop,
             .vmStart,
             .vmStop,
             .dockerRun,
             .dockerCompose,
             .networkRepair,
             .clockRepair,
             .pruneCache,
             .memoryReclaim,
             .memoryHardDrop:
            true
        }
    }
}

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
        defer { lock.unlock() }
        return error
    }
}

private final class DaemonDockerEventAdapter: @unchecked Sendable {
    private let socketPath: String
    private let energyMode: ConjetEnergyMode
    private let emit: @Sendable (ConjetDockerRuntimeEvent) -> Void
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private var fd: Int32 = -1

    init(
        socketPath: String,
        energyMode: ConjetEnergyMode,
        emit: @escaping @Sendable (ConjetDockerRuntimeEvent) -> Void
    ) {
        self.socketPath = socketPath
        self.energyMode = energyMode
        self.emit = emit
    }

    deinit {
        stop()
    }

    func startIfSocketAvailable() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            lock.unlock()
            return
        }
        running = true
        let thread = Thread { [weak self] in
            self?.eventLoop()
        }
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        let fd = fd
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }

    private func eventLoop() {
        var reconnectDelay = reconnectDelaySeconds
        defer {
            lock.lock()
            running = false
            thread = nil
            fd = -1
            lock.unlock()
        }

        while isRunning(), FileManager.default.fileExists(atPath: socketPath) {
            let connected = autoreleasepool {
                runDockerEventStream()
            }
            if isRunning(), FileManager.default.fileExists(atPath: socketPath) {
                let delay = connected ? reconnectDelaySeconds : reconnectDelay
                Thread.sleep(forTimeInterval: delay)
                reconnectDelay = connected ? reconnectDelaySeconds : min(reconnectDelay * 2, maxReconnectDelaySeconds)
            }
        }
    }

    private func runDockerEventStream() -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        disableSigpipeForDockerEventSocket(fd)
        defer {
            clear(fd)
            Darwin.close(fd)
        }

        lock.lock()
        self.fd = fd
        lock.unlock()

        do {
            try connectDockerEventSocket(fd)
        } catch {
            return false
        }

        let request = "GET /events HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        guard writeAll(Data(request.utf8), to: fd) else {
            return false
        }
        guard let response = readHTTPHeader(from: fd), response.statusCode == 200 else {
            return false
        }
        streamEvents(from: fd, initialBody: response.body, isChunked: response.isChunked)
        return true
    }

    private func streamEvents(from fd: Int32, initialBody: Data, isChunked: Bool) {
        var pending = initialBody
        var lineBuffer = Data()
        while isRunning() {
            if isChunked {
                consumeChunkedBuffer(&pending, lineBuffer: &lineBuffer)
            } else {
                consumeLineBuffer(&pending, lineBuffer: &lineBuffer)
            }

            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                pending.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private func handleEventLine(_ data: Data) {
        let trimmed = data.trimmingDockerEventASCIIWhitespace()
        guard !trimmed.isEmpty,
              let event = try? ConjetDockerRuntimeEvent.decode(line: trimmed),
              event.pulseEventType != nil else {
            return
        }
        emit(event)
    }

    private func consumeLineBuffer(_ pending: inout Data, lineBuffer: inout Data) {
        guard !pending.isEmpty else { return }
        lineBuffer.append(pending)
        pending.removeAll(keepingCapacity: true)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let line = lineBuffer.prefix(upTo: newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            handleEventLine(Data(line))
        }
    }

    private func consumeChunkedBuffer(_ pending: inout Data, lineBuffer: inout Data) {
        while true {
            guard let lineEnd = pending.range(of: Data([13, 10]))?.lowerBound,
                  let sizeLine = String(data: pending[..<lineEnd], encoding: .utf8) else {
                return
            }
            let sizeText = sizeLine
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                pending.removeAll(keepingCapacity: true)
                return
            }
            let chunkStart = lineEnd + 2
            let chunkEnd = chunkStart + size
            guard pending.count >= chunkEnd + 2 else {
                return
            }
            if size == 0 {
                pending.removeAll(keepingCapacity: true)
                return
            }
            lineBuffer.append(pending[chunkStart..<chunkEnd])
            pending.removeSubrange(pending.startIndex..<(chunkEnd + 2))
            while let newline = lineBuffer.firstIndex(of: 10) {
                let line = lineBuffer.prefix(upTo: newline)
                lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
                handleEventLine(Data(line))
            }
        }
    }

    private func clear(_ fd: Int32) {
        lock.lock()
        if self.fd == fd {
            self.fd = -1
        }
        lock.unlock()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private var reconnectDelaySeconds: TimeInterval {
        switch energyMode {
        case .performance:
            return 1
        case .balanced:
            return 2
        case .eco:
            return 5
        }
    }

    private var maxReconnectDelaySeconds: TimeInterval {
        switch energyMode {
        case .performance:
            return 15
        case .balanced:
            return 30
        case .eco:
            return 60
        }
    }

    private func connectDockerEventSocket(_ fd: Int32) throws {
        try withDockerEventSocketAddress(path: socketPath) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                throw ConjetError.socket("connect(\(socketPath)) failed")
            }
        }
    }

    private func readHTTPHeader(from fd: Int32) -> DockerEventHTTPHeader? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let delimiter = Data([13, 10, 13, 10])
        while isRunning(), data.range(of: delimiter) == nil, data.count < 64 * 1024 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return DockerEventHTTPHeader(
            statusCode: statusCode,
            isChunked: headers["transfer-encoding"]?.lowercased().contains("chunked") == true,
            body: Data(data[headerRange.upperBound...])
        )
    }
}

private struct DockerEventHTTPHeader {
    var statusCode: Int
    var isChunked: Bool
    var body: Data
}

private func disableSigpipeForDockerEventSocket(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func writeAll(_ data: Data, to fd: Int32) -> Bool {
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

private func withDockerEventSocketAddress<T>(
    path: String,
    body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw ConjetError.socket("socket path is too long: \(path)")
    }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
        path.withCString { source in
            strncpy(pointer, source, pathCapacity)
        }
    }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            try body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private extension Data {
    func trimmingDockerEventASCIIWhitespace() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, self[start].isDockerEventASCIIWhitespace {
            start = index(after: start)
        }
        while end > start {
            let previous = index(before: end)
            guard self[previous].isDockerEventASCIIWhitespace else { break }
            end = previous
        }
        return Data(self[start..<end])
    }
}

private extension UInt8 {
    var isDockerEventASCIIWhitespace: Bool {
        self == 9 || self == 10 || self == 13 || self == 32
    }
}

private final class DaemonLogger: @unchecked Sendable {
    private let handle: FileHandle
    private let formatter = ISO8601DateFormatter()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.conjet.daemon-log", qos: .utility)
    private let flushInterval: TimeInterval
    private var bufferedLines: [String] = []
    private var flushScheduled = false

    init(path: URL, flushInterval: TimeInterval = 0.25) throws {
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: path)
        self.flushInterval = max(0.05, flushInterval)
        try handle.seekToEnd()
    }

    deinit {
        flushSync()
        try? handle.close()
    }

    func log(_ event: String, _ fields: [String: String]) throws {
        var payload = fields
        payload["event"] = event
        payload["at"] = formatter.string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: payload.sortedDictionary(), options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else { return }
        queue.async { [weak self] in
            self?.enqueue(line)
        }
    }

    private func enqueue(_ line: String) {
        lock.lock()
        bufferedLines.append(line)
        let shouldSchedule = !flushScheduled
        if shouldSchedule {
            flushScheduled = true
        }
        lock.unlock()

        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                self?.flushSync()
            }
        }
    }

    private func flushSync() {
        lock.lock()
        let lines = bufferedLines
        bufferedLines.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !lines.isEmpty else { return }
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

private extension Dictionary where Key == String, Value == String {
    func sortedDictionary() -> [String: String] {
        Dictionary(uniqueKeysWithValues: self.sorted { $0.key < $1.key })
    }
}

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
            FileHandle.standardError.write(Data("conjetd: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func serve() throws {
        let paths = ConjetPaths.default()
        try paths.ensureBaseDirectories()
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
            "energyMode": config.energyMode.rawValue
        ])

        let server = UnixSocketServer(socketPath: socketPath)
        var stopping = false
        try server.listen { request in
            let response = runtime.handle(request: request, stopping: &stopping)
            try? logger.log("request", [
                "command": request.command.rawValue,
                "ok": String(response.ok)
            ])
            return response
        } shouldStop: {
            stopping
        }

        try logger.log("daemon_stop", ["socket": socketPath])
    }
}

private final class DaemonRuntime {
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
    private let statusCacheLock = NSLock()
    private var cachedStatus: CachedStatus?
    private let statusCacheTTL: TimeInterval

    init(startedAt: Date, socketPath: String, config: ConjetConfig, paths: ConjetPaths = .default()) {
        self.startedAt = startedAt
        self.socketPath = socketPath
        self.config = config
        self.paths = paths
        self.vmStore = VMImageStore(paths: paths)
        self.vmController = VirtualMachineController()
        self.governor = EnergyGovernor(
            configuredVCPUs: config.vmCPUs,
            quietStopSeconds: Double(config.quietStopMinutes) * 60,
            mode: config.energyMode
        )
        self.statusCacheTTL = TimeInterval(governor.policy(for: .warmIdle).statusPersistenceMinIntervalMilliseconds) / 1_000
        self.host = HostCapabilities.detect()
        _ = VirtualizationProbe.inspect(config: config, host: host)
    }

    func handle(request: DaemonRequest, stopping: inout Bool) -> DaemonResponse {
        switch request.command {
        case .ping:
            return DaemonResponse(ok: true, message: "pong", status: status(state: .warmIdle, allowCache: true))
        case .status:
            return DaemonResponse(ok: true, message: "running", status: status(state: .warmIdle, allowCache: true))
        case .vmStatus:
            let vm = vmController.status(store: vmStore)
            return DaemonResponse(ok: vm.configured, message: vm.message, status: status(state: runtimeState(for: vm), vm: vm), vm: vm)
        case .vmStart:
            do {
                invalidateStatusCache()
                let manifest = try vmStore.loadManifest()
                let vm = try vmController.start(manifest: manifest, config: config, store: vmStore)
                invalidateStatusCache()
                return DaemonResponse(ok: true, message: vm.message, status: status(state: runtimeState(for: vm), vm: vm), vm: vm)
            } catch {
                invalidateStatusCache()
                let vm = vmStore.status(state: .error, message: String(describing: error))
                return DaemonResponse(ok: false, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            }
        case .vmStop:
            do {
                invalidateStatusCache()
                let vm = try vmController.stop(store: vmStore)
                invalidateStatusCache()
                return DaemonResponse(ok: true, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            } catch {
                invalidateStatusCache()
                let vm = vmStore.status(state: .error, message: String(describing: error))
                return DaemonResponse(ok: false, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            }
        case .dockerRun:
            guard let image = request.arguments.first else {
                return DaemonResponse(ok: false, message: "docker-run requires an image")
            }
            do {
                let result = try DockerRunExecutor(socketPath: paths.dockerSocket.path)
                    .run(image: image, command: Array(request.arguments.dropFirst()))
                let ok = result.exitCode == 0
                let message = ok ? "container exited successfully" : (result.stderrTail.isEmpty ? "container did not run" : result.stderrTail)
                return DaemonResponse(ok: ok, message: message, status: status(state: .warmIdle), dockerRun: result)
            } catch {
                return DaemonResponse(ok: false, message: String(describing: error), status: status(state: .warmIdle))
            }
        case .networkRepair:
            invalidateStatusCache()
            let network = vmController.repairNetwork(config: config)
            invalidateStatusCache()
            return DaemonResponse(
                ok: true,
                message: "network repair completed",
                status: status(state: .warmIdle, network: network)
            )
        case .pruneCache:
            invalidateStatusCache()
            let network = vmController.pruneCache(config: config)
            invalidateStatusCache()
            return DaemonResponse(
                ok: true,
                message: "runtime cache pruned",
                status: status(state: .warmIdle, network: network)
            )
        case .stop:
            invalidateStatusCache()
            stopping = true
            let cleanupTimeout = request.parameters["timeout_seconds"].flatMap(Double.init)
                .map { min(max($0, 0.1), 25) }
                ?? 25
            let semaphore = DispatchSemaphore(value: 0)
            let cleanupError = AsyncErrorBox()
            DispatchQueue.global(qos: .utility).async { [vmController, vmStore] in
                do {
                    _ = try vmController.stop(store: vmStore)
                } catch {
                    cleanupError.set(error)
                }
                semaphore.signal()
            }
            let boundedWait = cleanupTimeout
            let cleanupTimedOut = semaphore.wait(timeout: .now() + boundedWait) == .timedOut
            let message: String
            if cleanupTimedOut {
                message = "conjetd stopping; cleanup still in progress after \(String(format: "%.1f", boundedWait))s"
            } else if let error = cleanupError.get() {
                message = "conjetd stopping; cleanup failed separately: \(error)"
            } else {
                message = "conjetd stopping; cleanup completed"
            }
            let vm = vmStore.status(state: .stopping, message: message)
            return DaemonResponse(ok: true, message: message, status: status(state: .stopping, vm: vm), vm: vm)
        }
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

        let snapshot = DaemonStatus(
            pid: getpid(),
            startedAt: startedAt,
            state: state,
            socketPath: socketPath,
            host: host,
            config: config,
            vm: vm ?? vmController.status(store: vmStore),
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

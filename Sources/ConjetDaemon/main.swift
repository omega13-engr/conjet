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
        let logger = try DaemonLogger(path: paths.daemonLog)
        let runtime = DaemonRuntime(
            startedAt: Date(),
            socketPath: socketPath,
            config: config
        )

        try logger.log("daemon_start", [
            "socket": socketPath,
            "vmCPUs": String(config.vmCPUs),
            "memoryMiB": String(config.memoryMiB)
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
    let startedAt: Date
    let socketPath: String
    let config: ConjetConfig
    let host: HostCapabilities
    let paths: ConjetPaths
    let vmStore: VMImageStore
    let vmController: VirtualMachineController

    init(startedAt: Date, socketPath: String, config: ConjetConfig, paths: ConjetPaths = .default()) {
        self.startedAt = startedAt
        self.socketPath = socketPath
        self.config = config
        self.paths = paths
        self.vmStore = VMImageStore(paths: paths)
        self.vmController = VirtualMachineController()
        self.host = HostCapabilities.detect()
        _ = VirtualizationProbe.inspect(config: config, host: host)
    }

    func handle(request: DaemonRequest, stopping: inout Bool) -> DaemonResponse {
        switch request.command {
        case .ping:
            return DaemonResponse(ok: true, message: "pong", status: status(state: .warmIdle))
        case .status:
            return DaemonResponse(ok: true, message: "running", status: status(state: .warmIdle))
        case .vmStatus:
            let vm = vmController.status(store: vmStore)
            return DaemonResponse(ok: vm.configured, message: vm.message, status: status(state: runtimeState(for: vm), vm: vm), vm: vm)
        case .vmStart:
            do {
                let manifest = try vmStore.loadManifest()
                let vm = try vmController.start(manifest: manifest, config: config, store: vmStore)
                return DaemonResponse(ok: true, message: vm.message, status: status(state: runtimeState(for: vm), vm: vm), vm: vm)
            } catch {
                let vm = vmStore.status(state: .error, message: String(describing: error))
                return DaemonResponse(ok: false, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            }
        case .vmStop:
            do {
                let vm = try vmController.stop(store: vmStore)
                return DaemonResponse(ok: true, message: vm.message, status: status(state: .warmIdle, vm: vm), vm: vm)
            } catch {
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
        case .stop:
            _ = try? vmController.stop(store: vmStore)
            stopping = true
            return DaemonResponse(ok: true, message: "conjetd stopping", status: status(state: .stopping))
        }
    }

    private func status(state: RuntimeState, vm: VMRuntimeStatus? = nil) -> DaemonStatus {
        DaemonStatus(
            pid: getpid(),
            startedAt: startedAt,
            state: state,
            socketPath: socketPath,
            host: host,
            config: config,
            vm: vm ?? vmController.status(store: vmStore)
        )
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

private final class DaemonLogger {
    private let url: URL

    init(path: URL) throws {
        self.url = path
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
    }

    func log(_ event: String, _ fields: [String: String]) throws {
        var payload = fields
        payload["event"] = event
        payload["at"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: payload.sortedDictionary(), options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else { return }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }
}

private extension Dictionary where Key == String, Value == String {
    func sortedDictionary() -> [String: String] {
        Dictionary(uniqueKeysWithValues: self.sorted { $0.key < $1.key })
    }
}

import ConjetBench
import ConjetCore
import ConjetPower
import ConjetVZ
import Darwin
import Foundation

@main
struct ConjetCLI {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("conjet: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(arguments: [String]) throws {
        var args = arguments
        let json = args.removeAllOccurrences("--json")
        let command = args.first ?? "help"
        if !args.isEmpty { args.removeFirst() }

        switch command {
        case "doctor":
            try doctor(json: json)
        case "status":
            try status(json: json)
        case "start":
            try start(json: json)
        case "stop":
            try stop()
        case "vm":
            try vm(args: args, json: json)
        case "run":
            try runContainer(args: args, json: json)
        case "compose":
            try compose(args: args)
        case "bench", "benchmark":
            try bench(args: args, json: json)
        case "sync":
            try sync(args: args, json: json)
        case "power":
            try power(args: args, json: json)
        case "help", "-h", "--help":
            printHelp()
        default:
            throw ConjetError.invalidArgument("unknown command '\(command)'")
        }
    }

    private static func doctor(json: Bool) throws {
        let paths = ConjetPaths.default()
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        let host = HostCapabilities.detect()
        let vz = VirtualizationProbe.inspect(config: config, host: host)
        let output = DoctorOutput(host: host, virtualization: vz, config: config)
        if json {
            print(try ConjetJSON.string(output))
        } else {
            print("Conjet doctor")
            print("  macOS: \(host.macOSVersion) (\(host.buildVersion))")
            print("  arch: \(host.architecture)")
            print("  cpu: \(host.cpuBrand)")
            print("  memory: \(host.memoryBytes / 1_048_576) MiB")
            print("  Virtualization.framework: \(host.virtualizationFrameworkAvailable ? "available" : "unavailable")")
            print("  Rosetta Linux support: \(host.rosettaLinuxSupportLikelyAvailable ? "likely available" : "not detected")")
            print("  low power mode: \(host.lowPowerModeEnabled ? "on" : "off")")
            print("  thermal: \(host.thermalState)")
            if !vz.notes.isEmpty {
                print("  notes:")
                for note in vz.notes {
                    print("    - \(note)")
                }
            }
        }
    }

    private static func status(json: Bool) throws {
        let paths = ConjetPaths.default()
        let socketPath = try socketPath(paths: paths)
        do {
            let response = try UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .status))
            if json {
                print(try ConjetJSON.string(response))
            } else if let status = response.status {
                print("conjetd: \(status.state.rawValue)")
                print("  pid: \(status.pid)")
                print("  socket: \(status.socketPath)")
                print("  started: \(status.startedAt)")
                if let vm = status.vm {
                    print("  vm: \(vm.state.rawValue)")
                    if let bootLoaderKind = vm.bootLoaderKind {
                        print("  boot loader: \(bootLoaderKind)")
                    }
                    print("  docker socket: \(vm.dockerSocketPath ?? "unknown")")
                }
            } else {
                print(response.message)
            }
        } catch {
            let offline = DaemonResponse(ok: false, message: "conjetd is not running at \(socketPath)")
            if json {
                print(try ConjetJSON.string(offline))
            } else {
                print(offline.message)
            }
        }
    }

    private static func start(json: Bool = false) throws {
        let socketPath = try startDaemonOnly(printStatus: !json)
        try startVMIfConfigured(socketPath: socketPath, json: json)
    }

    private static func startDaemonOnly(printStatus: Bool) throws -> String {
        let paths = ConjetPaths.default()
        try paths.ensureBaseDirectories()
        let socketPath = try socketPath(paths: paths)
        if let response = try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .ping)), response.ok {
            if printStatus { print("conjetd is already running") }
            return socketPath
        }

        let daemonURL = try daemonExecutableURL()
        let process = Process()
        process.executableURL = daemonURL
        process.arguments = ["--serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        for _ in 0..<50 {
            if let response = try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .ping)), response.ok {
                if printStatus { print("conjetd started") }
                return socketPath
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw ConjetError.unavailable("conjetd did not become ready")
    }

    private static func stop() throws {
        let paths = ConjetPaths.default()
        let response = try UnixSocketClient(socketPath: try socketPath(paths: paths)).send(DaemonRequest(command: .stop))
        print(response.message)
    }

    private static func startVMIfConfigured(socketPath: String, json: Bool) throws {
        let store = VMImageStore()
        guard store.manifestExists() else {
            if !json {
                print("VM is not configured yet; run 'conjet vm fetch-fedora' or 'conjet vm init --kernel PATH'")
            }
            return
        }
        let response = try UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .vmStart))
        if json {
            print(try ConjetJSON.string(response))
        } else {
            print(response.message)
            if let vm = response.vm {
                print("  vm: \(vm.state.rawValue)")
                print("  serial log: \(vm.serialLogPath ?? "unknown")")
            }
        }
        if !response.ok {
            try throwResponseError(response.message)
        }
    }

    private static func vm(args: [String], json: Bool) throws {
        let subcommand = args.first ?? "status"
        switch subcommand {
        case "fetch-ubuntu-cloud":
            let force = args.contains("--force")
            let release = value(after: "--release", in: args) ?? "noble"
            let cloudInitSeedPath: String?
            if args.contains("--cloud-init-docker") {
                cloudInitSeedPath = try buildDockerCloudInitSeed()
            } else {
                cloudInitSeedPath = nil
            }
            let manifest = try VMImageStore().fetchUbuntuCloudImage(
                source: UbuntuCloudImageSource(release: release),
                force: force,
                cloudInitSeedPath: cloudInitSeedPath,
                bootDiskMinimumSizeBytes: bootDiskMinimumSizeBytes(args: args, defaultGiB: 16)
            )
            try printVMManifest(manifest, json: json)
        case "fetch-fedora":
            let force = args.contains("--force")
            let release = value(after: "--release", in: args) ?? "43"
            let manifest = try VMImageStore().fetchFedoraPXE(source: FedoraPXESource(release: release), force: force)
            try printVMManifest(manifest, json: json)
        case "fetch-alpine":
            let force = args.contains("--force")
            let manifest = try VMImageStore().fetchAlpineNetboot(force: force)
            try printVMManifest(manifest, json: json)
        case "import-efi-disk":
            guard let image = value(after: "--image", in: args) else {
                throw ConjetError.invalidArgument("usage: conjet vm import-efi-disk --image PATH [--name NAME] [--cloud-init-docker] [--force]")
            }
            let cloudInitSeedPath: String?
            if args.contains("--cloud-init-docker") {
                cloudInitSeedPath = try buildDockerCloudInitSeed()
            } else {
                cloudInitSeedPath = nil
            }
            let manifest = try VMImageStore().importEFIBootDisk(
                sourcePath: image,
                name: value(after: "--name", in: args),
                force: args.contains("--force"),
                cloudInitSeedPath: cloudInitSeedPath,
                bootDiskMinimumSizeBytes: bootDiskMinimumSizeBytes(
                    args: args,
                    defaultGiB: args.contains("--cloud-init-docker") ? 16 : nil
                )
            )
            try printVMManifest(manifest, json: json)
        case "build-cloud-init-seed":
            let output = value(after: "--output", in: args)
                .map { URL(fileURLWithPath: $0) }
                ?? ConjetPaths.default().vmDirectory.appendingPathComponent("cloud-init-docker.iso")
            let result = try CloudInitSeedBuilder.buildDockerBootstrapSeed(output: output)
            if json {
                print(try ConjetJSON.string(result))
            } else {
                print("cloud-init seed built")
                print("  output: \(result.outputPath)")
                print("  bytes: \(result.bytes)")
            }
        case "build-initramfs":
            guard let initPath = value(after: "--init", in: args) else {
                throw ConjetError.invalidArgument("usage: conjet vm build-initramfs --init PATH [--output PATH]")
            }
            let output = value(after: "--output", in: args)
                .map { URL(fileURLWithPath: $0) }
                ?? ConjetPaths.default().vmDirectory.appendingPathComponent("initramfs.cpio.gz")
            let result = try InitramfsBuilder.build(initBinary: URL(fileURLWithPath: initPath), output: output)
            if json {
                print(try ConjetJSON.string(result))
            } else {
                print("initramfs built")
                print("  output: \(result.outputPath)")
                print("  entries: \(result.entryCount)")
                print("  uncompressed: \(result.uncompressedBytes) bytes")
                print("  compressed: \(result.compressedBytes) bytes")
            }
        case "init":
            guard let kernel = value(after: "--kernel", in: args) else {
                throw ConjetError.invalidArgument("usage: conjet vm init --kernel PATH [--initrd PATH] [--cmdline TEXT]")
            }
            let manifest = try VMImageStore().initializeFromLocalKernel(
                kernelPath: kernel,
                initialRamdiskPath: value(after: "--initrd", in: args),
                kernelCommandLine: value(after: "--cmdline", in: args)
            )
            try printVMManifest(manifest, json: json)
        case "validate":
            let store = VMImageStore()
            let manifest = try store.loadManifest()
            try store.validateManifest(manifest)
            let message = manifest.bootLoaderKind == .efiDisk
                ? "VM assets are present for EFI disk boot"
                : "VM assets are present and boot-compatible"
            let status = manifest.runtimeStatus(state: .stopped, message: message, manifestPath: store.paths.vmManifest.path)
            if json {
                print(try ConjetJSON.string(status))
            } else {
                print(message)
                print("  boot loader: \(manifest.bootLoaderKind.rawValue)")
                if let bootDisk = manifest.bootDiskPath {
                    print("  boot disk: \(bootDisk)")
                }
                if let efiVariableStore = manifest.efiVariableStorePath {
                    print("  EFI variables: \(efiVariableStore)")
                }
                if let cloudInitSeed = manifest.cloudInitSeedPath {
                    print("  cloud-init seed: \(cloudInitSeed)")
                }
                if !manifest.kernelPath.isEmpty {
                    print("  kernel: \(manifest.kernelPath)")
                }
                print("  root disk: \(manifest.rootDiskPath)")
                print("  data disk: \(manifest.dataDiskPath)")
            }
        case "status":
            try ensureDaemon()
            let response = try daemonRequest(.vmStatus)
            try printDaemonResponse(response, json: json)
        case "start":
            try ensureDaemon()
            let response = try daemonRequest(.vmStart)
            try printDaemonResponse(response, json: json, failOnError: true)
        case "stop":
            try ensureDaemon()
            let response = try daemonRequest(.vmStop)
            try printDaemonResponse(response, json: json, failOnError: true)
        case "logs":
            let lines = value(after: "--lines", in: args).flatMap(Int.init) ?? 120
            try printSerialLog(lines: lines)
        default:
            throw ConjetError.invalidArgument("unknown vm command '\(subcommand)'")
        }
    }

    private static func runContainer(args: [String], json: Bool) throws {
        guard let image = args.first else {
            throw ConjetError.invalidArgument("usage: conjet run IMAGE [CMD...]")
        }
        try ensureDaemon()
        let response = try daemonRequest(.dockerRun, arguments: [image] + Array(args.dropFirst()))
        if json {
            print(try ConjetJSON.string(response))
        } else if response.ok, let result = response.dockerRun {
            if !result.stdoutTail.isEmpty {
                print(result.stdoutTail, terminator: result.stdoutTail.hasSuffix("\n") ? "" : "\n")
            } else {
                print(response.message)
            }
        } else {
            throw ConjetError.unavailable(response.message)
        }
    }

    private static func compose(args: [String]) throws {
        guard args.first == "up" else {
            throw ConjetError.invalidArgument("usage: conjet compose up [docker compose args]")
        }
        let socket = ConjetPaths.default().dockerSocket.path
        guard FileManager.default.fileExists(atPath: socket) else {
            throw ConjetError.unavailable("Conjet Docker socket is not available yet at \(socket)")
        }
        let compose = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/docker-compose")
            ? "/opt/homebrew/bin/docker-compose"
            : "/opt/homebrew/bin/docker"
        let composeArgs = compose.hasSuffix("docker") ? ["--host", "unix://\(socket)", "compose"] + args : args
        let result = try ProcessRunner.run(compose, composeArgs)
        print(result.stdout, terminator: result.stdout.hasSuffix("\n") ? "" : "\n")
        if !result.succeeded {
            throw ConjetError.processFailed(executable: compose, exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private static func bench(args: [String], json: Bool) throws {
        let markdown = args.contains("--markdown")
        let args = args.filter { $0 != "--markdown" }
        let subcommand = args.first ?? "profile"
        switch subcommand {
        case "profile":
            let profile = MachineProfiler.capture()
            if json {
                print(try ConjetJSON.string(profile))
            } else {
                print("machine profile")
                print("  macOS: \(profile.host.macOSVersion) (\(profile.host.buildVersion))")
                print("  arch: \(profile.host.architecture)")
                print("  power: \(profile.powerSource)")
                print("  thermal: \(profile.thermalState)")
            }
        case "small-files":
            let fileCount = value(after: "--files", in: args).flatMap(Int.init) ?? 10_000
            let bytes = value(after: "--bytes", in: args).flatMap(Int.init) ?? 128
            let directory = value(after: "--dir", in: args)
                .map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("conjet-small-files-\(UUID().uuidString)")
            let result = try SmallFileWorkload(fileCount: fileCount, bytesPerFile: bytes).run(directory: directory)
            if json {
                print(try ConjetJSON.string(result))
            } else if markdown {
                print(BenchmarkMarkdownReport.render(results: [result]))
            } else {
                print("many-small-files: \(String(format: "%.3f", result.durationSeconds))s")
                print("  files: \(fileCount)")
                print("  dir: \(directory.path)")
            }
        default:
            throw ConjetError.invalidArgument("unknown bench command '\(subcommand)'")
        }
    }

    private static func sync(args: [String], json: Bool) throws {
        guard args.first == "classify", args.count >= 2 else {
            throw ConjetError.invalidArgument("usage: conjet sync classify PATH [--json]")
        }
        let classification = PathClassifier().classify(args[1])
        if json {
            print(try ConjetJSON.string(classification))
        } else {
            print("\(classification.path): \(classification.placement.rawValue)")
            print("  score: \(classification.score)")
            print("  reason: \(classification.reason)")
        }
    }

    private static func power(args: [String], json: Bool) throws {
        guard args.first == "policy", args.count >= 2 else {
            throw ConjetError.invalidArgument("usage: conjet power policy STATE [--json]")
        }
        guard let state = RuntimeState(rawValue: args[1]) else {
            throw ConjetError.invalidArgument("unknown runtime state '\(args[1])'")
        }
        let config = try ConjetConfig.loadOrCreate()
        let policy = EnergyGovernor(configuredVCPUs: config.vmCPUs).policy(for: state)
        if json {
            print(try ConjetJSON.string(policy))
        } else {
            print("\(state.rawValue) policy")
            print("  vcpus: \(policy.maxVCPUs)")
            print("  event batch: \(policy.eventBatchWindowMilliseconds) ms")
            print("  sync scan: \(policy.syncScanIntervalSeconds) s")
            print("  prefetch: \(policy.allowPrefetch ? "enabled" : "disabled")")
        }
    }

    private static func socketPath(paths: ConjetPaths) throws -> String {
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        return config.socketPath ?? paths.socket.path
    }

    private static func ensureDaemon() throws {
        _ = try startDaemonOnly(printStatus: false)
    }

    private static func daemonRequest(
        _ command: DaemonCommand,
        parameters: [String: String] = [:],
        arguments: [String] = []
    ) throws -> DaemonResponse {
        let paths = ConjetPaths.default()
        return try UnixSocketClient(socketPath: try socketPath(paths: paths)).send(
            DaemonRequest(command: command, parameters: parameters, arguments: arguments)
        )
    }

    private static func printDaemonResponse(_ response: DaemonResponse, json: Bool, failOnError: Bool = false) throws {
        if json {
            print(try ConjetJSON.string(response))
            if failOnError, !response.ok {
                try throwResponseError(response.message)
            }
            return
        }
        print(response.message)
        if let vm = response.vm ?? response.status?.vm {
            print("  vm: \(vm.state.rawValue)")
            print("  manifest: \(vm.manifestPath)")
            if let bootLoaderKind = vm.bootLoaderKind {
                print("  boot loader: \(bootLoaderKind)")
            }
            if let bootDiskPath = vm.bootDiskPath {
                print("  boot disk: \(bootDiskPath)")
            }
            if let efiVariableStorePath = vm.efiVariableStorePath {
                print("  EFI variables: \(efiVariableStorePath)")
            }
            if let cloudInitSeedPath = vm.cloudInitSeedPath {
                print("  cloud-init seed: \(cloudInitSeedPath)")
            }
            if let serialLogPath = vm.serialLogPath {
                print("  serial log: \(serialLogPath)")
            }
            if let dockerSocketPath = vm.dockerSocketPath {
                print("  docker socket: \(dockerSocketPath)")
            }
        }
        if failOnError, !response.ok {
            try throwResponseError(response.message)
        }
    }

    private static func buildDockerCloudInitSeed() throws -> String {
        let seed = ConjetPaths.default().vmDirectory.appendingPathComponent("cloud-init-docker.iso")
        let suffix = UUID().uuidString.prefix(8)
        let instanceID = "conjet-\(Int(Date().timeIntervalSince1970))-\(suffix)"
        _ = try CloudInitSeedBuilder.buildDockerBootstrapSeed(output: seed, instanceID: String(instanceID))
        return seed.path
    }

    private static func bootDiskMinimumSizeBytes(args: [String], defaultGiB: Int64?) throws -> Int64? {
        guard let value = value(after: "--boot-disk-gb", in: args) else {
            return defaultGiB.map { $0 * 1024 * 1024 * 1024 }
        }
        guard let gibibytes = Int64(value), gibibytes > 0 else {
            throw ConjetError.invalidArgument("--boot-disk-gb must be a positive integer")
        }
        return gibibytes * 1024 * 1024 * 1024
    }

    private static func throwResponseError(_ message: String) throws -> Never {
        let unavailablePrefix = "unavailable: "
        if message.hasPrefix(unavailablePrefix) {
            throw ConjetError.unavailable(String(message.dropFirst(unavailablePrefix.count)))
        }
        throw ConjetError.unavailable(message)
    }

    private static func printVMManifest(_ manifest: VMAssetManifest, json: Bool) throws {
        if json {
            print(try ConjetJSON.string(manifest))
            return
        }
        print("VM assets configured: \(manifest.name)")
        print("  boot loader: \(manifest.bootLoaderKind.rawValue)")
        if manifest.bootLoaderKind == .linuxArm64CompressedEfiZboot {
            print("  runnable: no - standalone zboot files need a full EFI boot disk")
        }
        if let bootDisk = manifest.bootDiskPath {
            print("  boot disk: \(bootDisk)")
        }
        if let efiVariableStore = manifest.efiVariableStorePath {
            print("  EFI variables: \(efiVariableStore)")
        }
        if let cloudInitSeed = manifest.cloudInitSeedPath {
            print("  cloud-init seed: \(cloudInitSeed)")
        }
        if !manifest.kernelPath.isEmpty {
            print("  kernel: \(manifest.kernelPath)")
        }
        if let initrd = manifest.initialRamdiskPath {
            print("  initrd: \(initrd)")
        }
        print("  root disk: \(manifest.rootDiskPath)")
        print("  data disk: \(manifest.dataDiskPath)")
        print("  serial log: \(manifest.serialLogPath)")
    }

    private static func printSerialLog(lines: Int) throws {
        let log = ConjetPaths.default().serialLog
        guard FileManager.default.fileExists(atPath: log.path) else {
            throw ConjetError.filesystem("serial log does not exist at \(log.path)")
        }
        let text = try String(contentsOf: log, encoding: .utf8)
        let suffix = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
        print(suffix.joined(separator: "\n"))
    }

    private static func daemonExecutableURL() throws -> URL {
        let cli = URL(fileURLWithPath: CommandLine.arguments[0])
        let daemon = cli.deletingLastPathComponent().appendingPathComponent("conjetd")
        if FileManager.default.isExecutableFile(atPath: daemon.path) {
            return daemon
        }
        throw ConjetError.unavailable("could not find conjetd next to \(cli.path); run 'swift build' first")
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func printHelp() {
        print(
            """
            conjet - light macOS container runtime prototype

            Commands:
              conjet doctor [--json]
              conjet start
              conjet status [--json]
              conjet stop
              conjet vm fetch-ubuntu-cloud [--release noble] [--cloud-init-docker] [--boot-disk-gb N] [--force] [--json]
              conjet vm fetch-fedora [--release N] [--force] [--json]
              conjet vm fetch-alpine [--force] [--json]
              conjet vm import-efi-disk --image PATH [--name NAME] [--cloud-init-docker] [--boot-disk-gb N] [--force] [--json]
              conjet vm build-cloud-init-seed [--output PATH] [--json]
              conjet vm build-initramfs --init PATH [--output PATH] [--json]
              conjet vm init --kernel PATH [--initrd PATH] [--cmdline TEXT] [--json]
              conjet vm validate [--json]
              conjet vm start|stop|status [--json]
              conjet vm logs [--lines N]
              conjet run IMAGE [CMD...] [--json]
              conjet compose up [docker compose args]
              conjet bench profile [--json]
              conjet bench small-files [--files N] [--bytes N] [--dir PATH] [--json|--markdown]
              conjet sync classify PATH [--json]
              conjet power policy STATE [--json]
            """
        )
    }
}

private struct DoctorOutput: Codable, Equatable {
    var host: HostCapabilities
    var virtualization: VirtualizationCapabilities
    var config: ConjetConfig
}

private extension Array where Element == String {
    mutating func removeAllOccurrences(_ value: String) -> Bool {
        var removed = false
        self = filter { element in
            if element == value {
                removed = true
                return false
            }
            return true
        }
        return removed
    }
}

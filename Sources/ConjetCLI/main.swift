import ConjetBench
import ConjetCore
import ConjetPower
import ConjetVZ
import Darwin
import Dispatch
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
        case "shell":
            try shell(args: args)
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
        try ensureVMConfiguredForStart(json: json)
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
        _ = try repairDebugVirtualizationSigningIfPossible(daemonURL: daemonURL)
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
                print("VM is not configured yet; no Conjet-core image could be imported")
            }
            return
        }
        let response = try vmStartResponseWithDebugSigningRepair(socketPath: socketPath, json: json)
        let dockerContext = configureDockerContextIfStarted(response, json: json)
        if json {
            print(try ConjetJSON.string(response))
        } else {
            print(response.message)
            if let vm = response.vm {
                print("  vm: \(vm.state.rawValue)")
                print("  serial log: \(vm.serialLogPath ?? "unknown")")
                if let dockerContext {
                    print("  docker context: \(dockerContext.contextName)")
                }
            }
        }
        if !response.ok {
            try throwResponseError(response.message)
        }
    }

    private static func vm(args: [String], json: Bool) throws {
        let subcommand = args.first ?? "status"
        switch subcommand {
        case "fetch-conjet-core":
            let force = args.contains("--force")
            let artifact = try conjetCoreArtifactPath(args: args, force: force, printStatus: !json)
            let ui = ConjetFetchUI(enabled: !json)
            ui.step("[conjet-core 4/4] importing img")
            let manifest = try VMImageStore().importEFIBootDisk(
                sourcePath: artifact,
                name: value(after: "--name", in: args) ?? "conjet-core",
                force: force,
                cloudInitSeedPath: nil,
                bootDiskMinimumSizeBytes: bootDiskMinimumSizeBytes(args: args, defaultGiB: nil)
            )
            try printVMManifest(
                manifest,
                json: json,
                headline: "=> [conjet-core 4/4] VM assets configured: \(manifest.name)"
            )
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
            try ensureVMConfiguredForStart(json: json)
            try ensureDaemon()
            let socketPath = try socketPath(paths: ConjetPaths.default())
            let response = try vmStartResponseWithDebugSigningRepair(socketPath: socketPath, json: json)
            let dockerContext = configureDockerContextIfStarted(response, json: json)
            try printDaemonResponse(response, json: json, failOnError: true, dockerContext: dockerContext)
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

    private static func shell(args: [String]) throws {
        let socket = try ensureConjetDockerSocket()
        let commandArgs = args.first == "--" ? Array(args.dropFirst()) : args
        let shellCommand = commandArgs.isEmpty ? ["/bin/bash", "-l"] : commandArgs
        var dockerArgs = [
            "docker",
            "--host",
            "unix://\(socket)",
            "run",
            "--rm"
        ]
        if isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 {
            dockerArgs.append("-it")
        }
        dockerArgs += [
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
            "--"
        ] + shellCommand

        try runInheritedProcess("/usr/bin/env", dockerArgs)
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
        case "docker-compare":
            let contexts = value(after: "--contexts", in: args)
                .map { $0.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
                ?? ["conjet", "colima"]
            let iterations = value(after: "--iterations", in: args).flatMap(Int.init) ?? 1
            let warmup = args.contains("--warmup")
            let workloads = value(after: "--workloads", in: args)
                .map { $0.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
                ?? DockerBenchmarkSuite.defaultWorkloads
            let output = value(after: "--output", in: args)
            let workDirectory = value(after: "--dir", in: args)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("conjet-docker-bench-\(UUID().uuidString)", isDirectory: true)
            defer {
                if value(after: "--dir", in: args) == nil {
                    try? FileManager.default.removeItem(at: workDirectory)
                }
            }

            let results = try DockerBenchmarkSuite(
                contexts: contexts,
                iterations: iterations,
                warmup: warmup,
                workloads: workloads
            ).run(workDirectory: workDirectory)

            if let output {
                try writeBenchmarkResults(results, to: URL(fileURLWithPath: output), markdown: markdown)
            }

            if json {
                print(try ConjetJSON.string(results))
            } else if markdown {
                print(BenchmarkMarkdownReport.render(results: results, title: "Conjet Docker Context Benchmark"))
            } else {
                for result in results {
                    let status = result.exitCode == 0 ? "ok" : "failed"
                    print("\(result.runtime) \(result.workload): \(String(format: "%.3f", result.durationSeconds))s \(status)")
                }
                if let output {
                    print("wrote benchmark report: \(output)")
                }
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

    private static func printDaemonResponse(
        _ response: DaemonResponse,
        json: Bool,
        failOnError: Bool = false,
        dockerContext: DockerContextResult? = nil
    ) throws {
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
            if let dockerContext {
                print("  docker context: \(dockerContext.contextName)")
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

    private static func ensureConjetDockerSocket() throws -> String {
        let paths = ConjetPaths.default()
        let socket = paths.dockerSocket.path
        if FileManager.default.fileExists(atPath: socket) {
            return socket
        }
        try start(json: false)
        guard FileManager.default.fileExists(atPath: socket) else {
            throw ConjetError.unavailable("Conjet Docker socket is not available yet at \(socket)")
        }
        return socket
    }

    private static func runInheritedProcess(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConjetError.processFailed(
                executable: executable,
                exitCode: process.terminationStatus,
                stderr: "command exited with status \(process.terminationStatus)"
            )
        }
    }

    private static func writeBenchmarkResults(_ results: [BenchmarkResult], to url: URL, markdown: Bool) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = try markdown
            ? BenchmarkMarkdownReport.render(results: results, title: "Conjet Docker Context Benchmark")
            : ConjetJSON.string(results)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func ensureVMConfiguredForStart(json: Bool) throws {
        let store = VMImageStore()
        guard !store.manifestExists() else {
            return
        }

        let config = try ConjetConfig.loadOrCreate()
        let repository = conjetCoreRepository(cliValue: nil, config: config)
        let ui = ConjetFetchUI(enabled: !json)
        ui.step("[conjet-core internal] VM image missing; fetching latest release")
        let artifact = try downloadLatestConjetCoreArtifact(
            repository: repository,
            force: false,
            printStatus: !json
        )
        ui.step("[conjet-core 4/4] importing img")
        let manifest = try store.importEFIBootDisk(
            sourcePath: artifact,
            name: "conjet-core",
            force: true,
            cloudInitSeedPath: nil,
            bootDiskMinimumSizeBytes: nil
        )
        if !json {
            try printVMManifest(
                manifest,
                json: false,
                headline: "=> [conjet-core 4/4] VM assets configured: \(manifest.name)"
            )
        }
    }

    private static func conjetCoreArtifactPath(args: [String], force: Bool, printStatus: Bool) throws -> String {
        let image = value(after: "--image", in: args)
        let url = value(after: "--url", in: args)
        if image != nil, url != nil {
            throw ConjetError.invalidArgument(
                "usage: conjet vm fetch-conjet-core [--image PATH|--url HTTPS_URL|--repository OWNER/REPO] [--name NAME] [--boot-disk-gb N] [--force]"
            )
        }
        if let image {
            return image
        }
        if let url {
            return try downloadConjetCoreArtifact(
                urlString: url,
                force: force,
                progress: ConjetFetchUI(enabled: printStatus).progress(stage: "[conjet-core 1/1] downloading img")
            )
        }
        let repository = conjetCoreRepository(cliValue: value(after: "--repository", in: args), config: try ConjetConfig.loadOrCreate())
        return try downloadLatestConjetCoreArtifact(repository: repository, force: force, printStatus: printStatus)
    }

    private static func conjetCoreRepository(cliValue: String?, config: ConjetConfig) -> String {
        let repository: String
        if let cliValue, !cliValue.isEmpty {
            repository = cliValue
        } else if let environment = ProcessInfo.processInfo.environment["CONJET_CORE_REPOSITORY"], !environment.isEmpty {
            repository = environment
        } else {
            repository = config.conjetCoreRepository
        }
        return repository
    }

    private static func downloadLatestConjetCoreArtifact(
        repository: String,
        force: Bool,
        printStatus: Bool
    ) throws -> String {
        let ui = ConjetFetchUI(enabled: printStatus)
        let source = ConjetCoreReleaseSource(repository: repository)
        ui.step("[conjet-core internal] load release metadata")
        let releaseData = try githubGet(urlString: source.latestReleaseURL)
        ui.step("[conjet-core internal] resolve img")
        let artifact = try ConjetCoreReleaseResolver.selectArtifact(
            fromLatestReleaseJSON: releaseData,
            hostArchitecture: HostCapabilities.detect().architecture
        )
        ui.step("[conjet-core internal] selected release \(artifact.releaseTag)")
        let imagePath = try downloadConjetCoreArtifact(
            urlString: artifact.downloadURL,
            force: force,
            progress: ui.progress(stage: "[conjet-core 1/4] downloading img")
        )
        if let checksumURL = artifact.checksumDownloadURL {
            let checksumPath = try downloadConjetCoreArtifact(
                urlString: checksumURL,
                force: force,
                progress: ui.progress(stage: "[conjet-core 2/4] downloading checksum")
            )
            ui.step("[conjet-core 3/4] verifying checksum")
            try verifySHA512(filePath: imagePath, checksumPath: checksumPath)
            ui.step("[conjet-core 3/4] checksum verified")
        } else {
            ui.step("[conjet-core 2/4] checksum unavailable; skipping verification")
        }
        return imagePath
    }

    private static func githubGet(urlString: String) throws -> Data {
        var arguments = [
            "-fsSL",
            "--retry", "3",
            "--connect-timeout", "20",
            "-H", "Accept: application/vnd.github+json"
        ]
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
            arguments += ["-H", "Authorization: Bearer \(token)"]
        }
        arguments.append(urlString)

        let result = try ProcessRunner.run("/usr/bin/curl", arguments)
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw ConjetError.decoding("GitHub release response was not UTF-8")
        }
        return data
    }

    private static func downloadConjetCoreArtifact(
        urlString: String,
        force: Bool,
        progress: DownloadProgressRenderer? = nil
    ) throws -> String {
        guard let remote = URL(string: urlString),
              remote.scheme == "https",
              remote.host?.isEmpty == false,
              !remote.lastPathComponent.isEmpty else {
            throw ConjetError.invalidArgument("Conjet-core image URL must be a public https:// URL with a file name")
        }

        let paths = ConjetPaths.default()
        try paths.ensureBaseDirectories()
        let destination = paths.vmDirectory.appendingPathComponent(remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path), !force {
            progress?.cached()
            return destination.path
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).download")
        if FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }

        try ConjetCoreArtifactDownloader.download(url: remote, to: temporary, progress: progress)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination.path
    }

    private static func verifySHA512(filePath: String, checksumPath: String) throws {
        let checksumText = try String(contentsOfFile: checksumPath, encoding: .utf8)
        guard let expected = checksumText.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first,
              expected.count == 128 else {
            throw ConjetError.decoding("invalid SHA-512 checksum file at \(checksumPath)")
        }
        let result = try ProcessRunner.run("/usr/bin/shasum", ["-a", "512", filePath])
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        guard let actual = result.stdout.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else {
            throw ConjetError.decoding("could not parse SHA-512 output for \(filePath)")
        }
        guard actual.lowercased() == expected.lowercased() else {
            throw ConjetError.filesystem("SHA-512 mismatch for \(filePath)")
        }
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

    private static func printVMManifest(_ manifest: VMAssetManifest, json: Bool, headline: String? = nil) throws {
        if json {
            print(try ConjetJSON.string(manifest))
            return
        }
        print(headline ?? "VM assets configured: \(manifest.name)")
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

    private static func vmStartResponseWithDebugSigningRepair(socketPath: String, json: Bool) throws -> DaemonResponse {
        let request = DaemonRequest(command: .vmStart)
        let response = try UnixSocketClient(socketPath: socketPath).send(request)
        guard !response.ok, isVirtualizationEntitlementFailure(response.message) else {
            return response
        }

        let daemonURL = try daemonExecutableURL()
        guard isSwiftPMDebugExecutable(daemonURL),
              repositoryRoot(containing: daemonURL) != nil else {
            return response
        }

        let repaired = try repairDebugVirtualizationSigningIfPossible(daemonURL: daemonURL)
        guard repaired || binaryHasVirtualizationEntitlement(daemonURL) else {
            return response
        }
        if !json {
            let action = repaired ? "signed it and restarting conjetd" : "restarting conjetd"
            writeDiagnostic("debug conjetd was missing com.apple.security.virtualization at runtime; \(action)")
        }
        _ = try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .stop))
        waitForDaemonStop(socketPath: socketPath)
        let restartedSocketPath = try startDaemonOnly(printStatus: false)
        return try UnixSocketClient(socketPath: restartedSocketPath).send(request)
    }

    private static func configureDockerContextIfStarted(_ response: DaemonResponse, json: Bool) -> DockerContextResult? {
        guard response.ok,
              let vm = response.vm ?? response.status?.vm,
              let dockerSocketPath = vm.dockerSocketPath else {
            return nil
        }

        do {
            return try DockerContextManager().ensureContext(socketPath: dockerSocketPath, makeCurrent: true)
        } catch {
            if !json {
                writeDiagnostic("could not configure Docker context 'conjet': \(error)")
            }
            return nil
        }
    }

    private static func isVirtualizationEntitlementFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("com.apple.security.virtualization")
            || (lowercased.contains("virtualization") && lowercased.contains("entitlement"))
    }

    @discardableResult
    private static func repairDebugVirtualizationSigningIfPossible(daemonURL: URL) throws -> Bool {
        guard isSwiftPMDebugExecutable(daemonURL),
              let root = repositoryRoot(containing: daemonURL) else {
            return false
        }

        let entitlements = root.appendingPathComponent("build-support/conjet-debug.entitlements")
        guard FileManager.default.fileExists(atPath: entitlements.path) else {
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            return false
        }
        guard !binaryHasVirtualizationEntitlement(daemonURL) else {
            return false
        }

        let result = try ProcessRunner.run("/usr/bin/codesign", [
            "--force",
            "--sign", "-",
            "--entitlements", entitlements.path,
            daemonURL.path
        ])
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return true
    }

    private static func binaryHasVirtualizationEntitlement(_ executable: URL) -> Bool {
        guard let result = try? ProcessRunner.run("/usr/bin/codesign", [
            "-d",
            "--entitlements", ":-",
            executable.path
        ]) else {
            return false
        }
        return (result.stdout + result.stderr).contains("com.apple.security.virtualization")
    }

    private static func isSwiftPMDebugExecutable(_ executable: URL) -> Bool {
        let path = executable.standardizedFileURL.path
        return path.contains("/.build/") && path.contains("/debug/")
    }

    private static func repositoryRoot(containing executable: URL) -> URL? {
        let manager = FileManager.default
        var directory = executable.deletingLastPathComponent().standardizedFileURL
        while true {
            let entitlements = directory.appendingPathComponent("build-support/conjet-debug.entitlements")
            if manager.fileExists(atPath: entitlements.path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                return nil
            }
            directory = parent
        }
    }

    private static func waitForDaemonStop(socketPath: String) {
        for _ in 0..<50 {
            let response = try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .ping))
            if response == nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func writeDiagnostic(_ message: String) {
        FileHandle.standardError.write(Data("conjet: \(message)\n".utf8))
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
              conjet start [--json]  (auto-fetches latest Conjet-core image when needed)
              conjet status [--json]
              conjet stop
              conjet shell [-- COMMAND...]
              conjet vm fetch-ubuntu-cloud [--release noble] [--cloud-init-docker] [--boot-disk-gb N] [--force] [--json]
              conjet vm fetch-conjet-core [--image PATH|--url HTTPS_URL|--repository OWNER/REPO] [--name NAME] [--boot-disk-gb N] [--force] [--json]
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
              conjet bench docker-compare [--contexts conjet,colima] [--iterations N] [--workloads NAME,...] [--warmup] [--output PATH] [--json|--markdown]
              conjet sync classify PATH [--json]
              conjet power policy STATE [--json]
            """
        )
    }
}

private struct ConjetFetchUI {
    var enabled: Bool

    func step(_ message: String) {
        guard enabled else { return }
        print("=> \(message)")
    }

    func progress(stage: String) -> DownloadProgressRenderer? {
        guard enabled else { return nil }
        return DownloadProgressRenderer(stage: stage)
    }
}

private final class DownloadProgressRenderer: @unchecked Sendable {
    private let stage: String
    private let lock = NSLock()
    private var lastPercent: Int?
    private var lastBytes: Int64 = 0
    private var emitted = false

    init(stage: String) {
        self.stage = stage
    }

    func update(bytesWritten: Int64, totalBytes: Int64?) {
        lock.lock()
        defer { lock.unlock() }

        if let totalBytes, totalBytes > 0 {
            let percent = min(100, Int((Double(bytesWritten) / Double(totalBytes)) * 100))
            let shouldEmit = !emitted
                || percent == 100
                || lastPercent.map { percent >= $0 + 5 } ?? true
            guard shouldEmit else { return }
            lastPercent = percent
            emitted = true
            print(
                "=> \(stage): \(Self.formatBytes(bytesWritten)) / \(Self.formatBytes(totalBytes)) (\(percent)%)"
            )
            return
        }

        let shouldEmit = !emitted || bytesWritten - lastBytes >= 16 * 1024 * 1024
        guard shouldEmit else { return }
        lastBytes = bytesWritten
        emitted = true
        print("=> \(stage): \(Self.formatBytes(bytesWritten))")
    }

    func retry(attempt: Int, maxAttempts: Int) {
        lock.lock()
        lastPercent = nil
        lastBytes = 0
        emitted = false
        lock.unlock()
        print("=> \(stage): retrying (\(attempt)/\(maxAttempts))")
    }

    func cached() {
        print("=> CACHED \(stage)")
    }

    func finish(bytesWritten: Int64?) {
        lock.lock()
        defer { lock.unlock() }

        if let bytesWritten {
            print("=> \(stage): done \(Self.formatBytes(bytesWritten))")
        } else {
            print("=> \(stage): done")
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value))\(units[unitIndex])"
        }
        if value >= 100 {
            return String(format: "%.0f%@", value, units[unitIndex])
        }
        if value >= 10 {
            return String(format: "%.1f%@", value, units[unitIndex])
        }
        return String(format: "%.2f%@", value, units[unitIndex])
    }
}

private enum ConjetCoreArtifactDownloader {
    private static let maxAttempts = 3

    static func download(
        url remote: URL,
        to destination: URL,
        progress: DownloadProgressRenderer?
    ) throws {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                _ = try downloadOnce(url: remote, to: destination, progress: progress)
                return
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    progress?.retry(attempt: attempt + 1, maxAttempts: maxAttempts)
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
        throw lastError ?? ConjetError.unavailable("download failed for \(remote.absoluteString)")
    }

    private static func downloadOnce(
        url remote: URL,
        to destination: URL,
        progress: DownloadProgressRenderer?
    ) throws -> Int64 {
        let delegate = FileDownloadDelegate(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.downloadTask(with: remote)
        task.resume()
        return try delegate.wait()
    }
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: DownloadProgressRenderer?
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Int64, Error>?
    private var finishError: Error?
    private var finishedBytes: Int64?

    init(destination: URL, progress: DownloadProgressRenderer?) {
        self.destination = destination
        self.progress = progress
    }

    func wait() throws -> Int64 {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let bytes):
            return bytes
        case .failure(let error):
            throw error
        case nil:
            throw ConjetError.unavailable("download did not complete for \(destination.path)")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progress?.update(bytesWritten: totalBytesWritten, totalBytes: total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw ConjetError.unavailable("download failed with HTTP \(response.statusCode)")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finishedBytes = try Self.fileSize(destination)
        } catch {
            finishError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(.failure(error))
            return
        }
        if let finishError {
            complete(.failure(finishError))
            return
        }
        guard let finishedBytes else {
            complete(.failure(ConjetError.filesystem("download did not write \(destination.path)")))
            return
        }
        progress?.finish(bytesWritten: finishedBytes)
        complete(.success(finishedBytes))
    }

    private func complete(_ newResult: Result<Int64, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = newResult
        semaphore.signal()
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return 0
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

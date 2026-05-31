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
        let globalProfile = try removeLeadingProfileOption(from: &args)
        let command = args.first ?? "help"
        if !args.isEmpty { args.removeFirst() }
        let commandProfile: String?
        if command == "compose" {
            commandProfile = nil
        } else {
            commandProfile = try removeProfileOption(from: &args)
        }
        if let profileName = commandProfile ?? globalProfile {
            try activateProfile(profileName)
        }

        switch command {
        case "doctor":
            try doctor(json: json)
        case "status":
            try status(json: json)
        case "start":
            try start(args: args, json: json)
        case "stop":
            try stop(args: args, json: json)
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
        case "project":
            try project(args: args, json: json)
        case "power":
            try power(args: args, json: json)
        case "profile":
            try profile(args: args, json: json)
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
            print("  profile: \(paths.profileName)")
            print("  home: \(paths.home.path)")
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
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        let socketPath = try socketPath(paths: paths)
        do {
            let response = try UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .status))
            if json {
                print(try ConjetJSON.string(response))
            } else if let status = response.status {
                print("conjetd: \(status.state.rawValue)")
                printProfileSummary(paths: paths, config: status.config)
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
                printProfileSummary(paths: paths, config: config)
            }
        }
    }

    private static func profile(args: [String], json: Bool) throws {
        let subcommand = args.first ?? "status"
        switch subcommand {
        case "status":
            let paths = ConjetPaths.default()
            let config = try ConjetConfig.loadOrCreate(paths: paths)
            let output = ProfileStatus(profile: paths.profileName, home: paths.home.path, config: config)
            if json {
                print(try ConjetJSON.string(output))
            } else {
                printProfileSummary(paths: paths, config: config)
            }
        case "list":
            let paths = ConjetPaths.default()
            let profiles = try listProfiles(rootHome: paths.rootHome)
            if json {
                print(try ConjetJSON.string(profiles))
            } else {
                print("profiles")
                for profile in profiles {
                    print("  \(profile)")
                }
            }
        default:
            throw ConjetError.invalidArgument("unknown profile command '\(subcommand)'")
        }
    }

    private static func start(args: [String] = [], json: Bool = false) throws {
        let paths = ConjetPaths.default()
        let config = try updateProfileConfigFromStartArgs(args, paths: paths, json: json)
        try ensureVMConfiguredForStart(json: json, config: config)
        let socketPath = try startDaemonOnly(printStatus: !json)
        try startVMIfConfigured(socketPath: socketPath, config: config, json: json)
    }

    private static func updateProfileConfigFromStartArgs(_ args: [String], paths: ConjetPaths, json: Bool) throws -> ConjetConfig {
        var config = try ConjetConfig.loadOrCreate(paths: paths)
        let original = config
        var remaining = args

        while !remaining.isEmpty {
            let flag = remaining.removeFirst()
            switch flag {
            case "--cpu", "--cpus":
                config.vmCPUs = try parsePositiveInt(consumeValue(flag, from: &remaining), flag: flag)
            case "--memory":
                config.memoryMiB = try parseMemoryMiB(consumeValue(flag, from: &remaining), flag: flag)
            case "--disk":
                let value = try consumeValue(flag, from: &remaining)
                if let diskGiB = try parseOptionalGiB(value, flag: flag) {
                    config.diskGiB = diskGiB
                    config.diskImagePath = nil
                } else {
                    let path = expandedPath(value)
                    guard FileManager.default.fileExists(atPath: path) else {
                        throw ConjetError.invalidArgument("--disk custom image does not exist at \(path)")
                    }
                    config.diskImagePath = path
                }
            case "--runtime":
                config.runtime = try normalizeRuntime(consumeValue(flag, from: &remaining))
            case "--arch", "--architecture":
                config.architecture = try normalizeArchitecture(consumeValue(flag, from: &remaining))
            default:
                throw ConjetError.invalidArgument("unknown start option '\(flag)'")
            }
        }

        if config != original {
            try config.save(paths: paths)
            if !json {
                ConjetFetchUI(enabled: true).step("[profile \(paths.profileName)] updated")
                printProfileSummary(paths: paths, config: config)
            }
        }
        return config
    }

    private static func startDaemonOnly(printStatus: Bool) throws -> String {
        let ui = ConjetFetchUI(enabled: printStatus)
        let paths = ConjetPaths.default()
        try paths.ensureBaseDirectories()
        let socketPath = try socketPath(paths: paths)
        if let response = try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .ping)), response.ok {
            ui.cached("[conjetd 1/2] running")
            return socketPath
        }

        let daemonURL = try daemonExecutableURL()
        _ = try repairDebugVirtualizationSigningIfPossible(daemonURL: daemonURL)
        let process = Process()
        process.executableURL = daemonURL
        process.arguments = ["--serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["CONJET_PROFILE"] = paths.profileName
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        for _ in 0..<50 {
            if let response = try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .ping)), response.ok {
                ui.step("[conjetd 1/2] started")
                return socketPath
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw ConjetError.unavailable("conjetd did not become ready")
    }

    private static func stop(args: [String] = [], json: Bool = false) throws {
        let paths = ConjetPaths.default()
        let timeout = value(after: "--timeout", in: args).flatMap(Double.init)
            ?? ProcessInfo.processInfo.environment["CONJET_STOP_TIMEOUT_SECONDS"].flatMap(Double.init)
            ?? 25
        let response = try UnixSocketClient(socketPath: try socketPath(paths: paths)).send(
            DaemonRequest(command: .stop, parameters: ["timeout_seconds": String(timeout)]),
            timeoutSeconds: timeout
        )
        if json {
            print(try ConjetJSON.string(response))
        } else {
            print(response.message)
        }
    }

    private static func startVMIfConfigured(socketPath: String, config: ConjetConfig, json: Bool) throws {
        let store = VMImageStore()
        guard store.manifestExists() else {
            if !json {
                ConjetFetchUI(enabled: true).step("[vm 2/2] not configured; no Conjet-core image imported")
            }
            return
        }
        let response = try vmStartResponseWithDebugSigningRepair(socketPath: socketPath, json: json)
        let dockerContext = configureDockerContextIfStarted(response, json: json)
        let hostShares = mountHostSharesIfStarted(response, dockerContext: dockerContext, config: config, json: json)
        if json {
            print(try ConjetJSON.string(response))
        } else {
            printStartVMResponse(response, dockerContext: dockerContext, hostShares: hostShares)
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
            let config = try ConjetConfig.loadOrCreate()
            let ui = ConjetFetchUI(enabled: !json)
            ui.step("[conjet-core 4/4] importing img")
            let manifest = try VMImageStore().importEFIBootDisk(
                sourcePath: artifact,
                name: value(after: "--name", in: args) ?? "conjet-core",
                force: force,
                cloudInitSeedPath: nil,
                bootDiskMinimumSizeBytes: bootDiskMinimumSizeBytes(args: args, defaultGiB: nil),
                dataDiskSizeBytes: gibibytes(config.diskGiB)
            )
            try printVMManifest(
                manifest,
                json: json,
                headline: "=> [conjet-core 4/4] VM assets configured: \(manifest.name)"
            )
        case "fetch-ubuntu-cloud":
            let force = args.contains("--force")
            let release = value(after: "--release", in: args) ?? "noble"
            let config = try ConjetConfig.loadOrCreate()
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
                bootDiskMinimumSizeBytes: bootDiskMinimumSizeBytes(args: args, defaultGiB: 16),
                dataDiskSizeBytes: gibibytes(config.diskGiB)
            )
            try printVMManifest(manifest, json: json)
        case "fetch-fedora":
            let force = args.contains("--force")
            let release = value(after: "--release", in: args) ?? "43"
            let config = try ConjetConfig.loadOrCreate()
            let manifest = try VMImageStore().fetchFedoraPXE(
                source: FedoraPXESource(release: release),
                force: force,
                dataDiskSizeBytes: gibibytes(config.diskGiB)
            )
            try printVMManifest(manifest, json: json)
        case "fetch-alpine":
            let force = args.contains("--force")
            let config = try ConjetConfig.loadOrCreate()
            let manifest = try VMImageStore().fetchAlpineNetboot(
                force: force,
                dataDiskSizeBytes: gibibytes(config.diskGiB)
            )
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
            let config = try ConjetConfig.loadOrCreate()
            try ensureVMConfiguredForStart(json: json, config: config)
            try ensureDaemon()
            let socketPath = try socketPath(paths: ConjetPaths.default())
            let response = try vmStartResponseWithDebugSigningRepair(socketPath: socketPath, json: json)
            let dockerContext = configureDockerContextIfStarted(response, json: json)
            let hostShares = mountHostSharesIfStarted(response, dockerContext: dockerContext, config: config, json: json)
            try printDaemonResponse(
                response,
                json: json,
                failOnError: true,
                dockerContext: dockerContext,
                hostShares: hostShares,
                headline: vmStartHeadline(response)
            )
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
        if subcommand == "help" || subcommand == "-h" || subcommand == "--help" || args.contains("--help") || args.contains("-h") {
            printHelp()
            return
        }
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
        case "idle":
            let runtime = value(after: "--runtime", in: args) ?? "conjet"
            let processPattern = value(after: "--process", in: args) ?? defaultIdleProcessPattern(runtime: runtime)
            let seconds = value(after: "--seconds", in: args).flatMap(Double.init) ?? 30
            let interval = value(after: "--interval", in: args).flatMap(Double.init) ?? 1
            let output = value(after: "--output", in: args)
            let result = try IdleResourceSampler(
                runtime: runtime,
                processPattern: processPattern,
                durationSeconds: seconds,
                intervalSeconds: interval
            ).run()
            if let output {
                try writeBenchmarkResults([result], to: URL(fileURLWithPath: output), markdown: markdown)
            }
            if json {
                print(try ConjetJSON.string(result))
            } else if markdown {
                print(BenchmarkMarkdownReport.render(results: [result], title: "Conjet Idle Resource Benchmark"))
            } else {
                print("\(runtime) idle-resource-sample: \(String(format: "%.3f", result.durationSeconds))s")
                print("  process pattern: \(processPattern)")
                print("  samples: \(Int(result.metrics["sample_count"] ?? 0))")
                print("  cpu mean: \(String(format: "%.3f", result.metrics["cpu_percent_mean"] ?? 0))%")
                print("  cpu p95: \(String(format: "%.3f", result.metrics["cpu_percent_p95"] ?? 0))%")
                print("  memory mean: \(String(format: "%.3f", result.metrics["memory_percent_mean"] ?? 0))%")
            }
        case "power":
            let runtime = value(after: "--runtime", in: args) ?? "conjet"
            let processPattern = value(after: "--process", in: args) ?? defaultIdleProcessPattern(runtime: runtime)
            let seconds = value(after: "--seconds", in: args).flatMap(Double.init) ?? 60
            let interval = value(after: "--interval", in: args).flatMap(Double.init) ?? 1
            let samplers = value(after: "--samplers", in: args) ?? "cpu_power,gpu_power,ane_power,tasks"
            let output = value(after: "--output", in: args)
            let result = try PowerMetricsSampler(
                runtime: runtime,
                processPattern: processPattern,
                durationSeconds: seconds,
                intervalSeconds: interval,
                samplers: samplers,
                useSudo: !args.contains("--no-sudo")
            ).run()
            if let output {
                try writeBenchmarkResults([result], to: URL(fileURLWithPath: output), markdown: markdown)
            }
            if json {
                print(try ConjetJSON.string(result))
            } else if markdown {
                print(BenchmarkMarkdownReport.render(results: [result], title: "Conjet Power Benchmark"))
            } else {
                print("\(runtime) idle-power-sample: \(String(format: "%.3f", result.durationSeconds))s")
                print("  exit: \(result.exitCode)")
                print("  process pattern: \(processPattern)")
                print("  samples: \(Int(result.metrics["powermetrics_sample_count"] ?? 0))")
                print("  cpu power mean: \(String(format: "%.3f", result.metrics["cpu_power_mw_mean"] ?? 0)) mW")
                print("  combined power mean: \(String(format: "%.3f", result.metrics["combined_power_mw_mean"] ?? 0)) mW")
                print("  matched energy impact mean: \(String(format: "%.3f", result.metrics["matched_energy_impact_mean"] ?? 0))")
                if result.exitCode != 0, !result.stderrTail.isEmpty {
                    print("  stderr: \(result.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        case "energy", "active-power":
            let optionArgs = argsBeforeDoubleDash(args)
            let runtime = value(after: "--runtime", in: optionArgs) ?? "conjet"
            let workload = value(after: "--workload", in: optionArgs) ?? "active-energy-sample"
            let processPattern = value(after: "--process", in: optionArgs) ?? defaultIdleProcessPattern(runtime: runtime)
            let seconds = value(after: "--seconds", in: optionArgs).flatMap(Double.init) ?? 60
            let minSeconds = value(after: "--min-seconds", in: optionArgs).flatMap(Double.init) ?? min(2, seconds)
            let interval = value(after: "--interval", in: optionArgs).flatMap(Double.init) ?? 1
            let samplers = value(after: "--samplers", in: optionArgs) ?? "cpu_power,gpu_power,ane_power,tasks"
            let output = value(after: "--output", in: optionArgs)
            let command = try commandAfterDoubleDash(
                in: args,
                usage: "usage: conjet bench energy [--runtime NAME] [--workload NAME] [--process REGEX] [--seconds N] [--min-seconds N] [--interval N] [--output PATH] [--no-sudo] -- COMMAND..."
            )
            let result = try ActivePowerSampler(
                runtime: runtime,
                workloadName: workload,
                processPattern: processPattern,
                maxDurationSeconds: seconds,
                minSampleSeconds: minSeconds,
                intervalSeconds: interval,
                samplers: samplers,
                useSudo: !optionArgs.contains("--no-sudo")
            ).run(executable: "/usr/bin/env", arguments: command)
            if let output {
                try writeBenchmarkResults([result], to: URL(fileURLWithPath: output), markdown: markdown)
            }
            if json {
                print(try ConjetJSON.string(result))
            } else if markdown {
                print(BenchmarkMarkdownReport.render(results: [result], title: "Conjet Active Energy Benchmark"))
            } else {
                print("\(runtime) \(workload): \(String(format: "%.3f", result.durationSeconds))s")
                print("  exit: \(result.exitCode)")
                print("  process pattern: \(processPattern)")
                print("  workload duration: \(String(format: "%.3f", result.metrics["workload_duration_seconds"] ?? 0))s")
                print("  combined power mean: \(String(format: "%.3f", result.metrics["combined_power_mw_mean"] ?? 0)) mW")
                print("  energy to solution: \(String(format: "%.3f", result.metrics["energy_to_solution_joules_estimate"] ?? 0)) J")
                if result.exitCode != 0, !result.stderrTail.isEmpty {
                    print("  stderr: \(result.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        case "release-gate", "global-gate", "cold-gate", "no-cache-gate":
            var gateArgs = args
            if subcommand == "cold-gate", value(after: "--phase", in: gateArgs) == nil {
                gateArgs += ["--phase", "cold-base-prepulled"]
            }
            if subcommand == "no-cache-gate", value(after: "--phase", in: gateArgs) == nil {
                gateArgs += ["--phase", "no-cache"]
            }
            try benchReleaseGate(args: gateArgs, json: json, markdown: markdown)
        case "topology-gate":
            try benchTopologyGate(args: args, json: json, markdown: markdown)
        case "polyglot-gate", "real-project-gate":
            try benchPolyglotGate(args: args, json: json, markdown: markdown)
        case "energy-gate":
            try benchEnergyGate(args: args, json: json, markdown: markdown)
        case "gate":
            let reportPaths = value(after: "--reports", in: args)
                ?? value(after: "--input", in: args)
                ?? value(after: "--report", in: args)
            guard let reportPaths else {
                throw ConjetError.invalidArgument("usage: conjet bench gate --reports report.json[,report2.json] [--candidate conjet] [--baselines orbstack,colima] [--min-samples N] [--phase any|cold|cold-base-prepulled|no-cache|true-cold|warm] [--workloads NAME,...] [--no-idle] [--no-power] [--json]")
            }
            let reportURLs = reportPaths
                .split(separator: ",")
                .map { URL(fileURLWithPath: expandedPath(String($0))) }
            let candidate = value(after: "--candidate", in: args) ?? "conjet"
            let baselines = value(after: "--baselines", in: args)
                .map { $0.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
                ?? ["orbstack", "colima"]
            let minSamples = value(after: "--min-samples", in: args).flatMap(Int.init) ?? 3
            let samplePhase = try benchmarkSamplePhase(from: value(after: "--phase", in: args), default: .any)
            let workloads = value(after: "--workloads", in: args).map(csvList)
            let results = try BenchmarkClaimGate.loadJSONReports(urls: reportURLs)
            let rules = BenchmarkReleaseGateOptions(
                candidateRuntime: candidate,
                baselineRuntimes: baselines,
                minimumSamples: minSamples,
                workloads: workloads ?? DockerBenchmarkSuite.defaultWorkloads,
                includeIdle: !args.contains("--no-idle"),
                includePower: !args.contains("--no-power")
            ).effectiveGateRules
            let report = BenchmarkClaimGate.evaluate(
                results: results,
                options: BenchmarkClaimGateOptions(
                    candidateRuntime: candidate,
                    baselineRuntimes: baselines,
                    minimumSamples: minSamples,
                    samplePhase: samplePhase,
                    rules: rules
                )
            )
            if json {
                print(try ConjetJSON.string(report))
            } else if markdown {
                print(BenchmarkClaimGateMarkdownReport.render(report))
            } else {
                printBenchmarkGateReport(report)
            }
            if !report.passed {
                throw ConjetError.unavailable("benchmark gate failed; faster-than-OrbStack claim is not proven")
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
            let commandTimeout = value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 180
            let output = value(after: "--output", in: args)
            let explicitWorkDirectory = value(after: "--dir", in: args)
            let needsHostBindableDirectory = workloads.contains { $0.hasPrefix("bind-") || $0.hasPrefix("conjetfs-") }
            let generatedRoot = needsHostBindableDirectory
                ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent(".conjet-bench", isDirectory: true)
                : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let workDirectory = explicitWorkDirectory
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? generatedRoot.appendingPathComponent("conjet-docker-bench-\(UUID().uuidString)", isDirectory: true)
            defer {
                if explicitWorkDirectory == nil {
                    try? FileManager.default.removeItem(at: workDirectory)
                }
            }

            let results = try DockerBenchmarkSuite(
                contexts: contexts,
                iterations: iterations,
                warmup: warmup,
                workloads: workloads,
                commandTimeoutSeconds: commandTimeout
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

    private static func benchReleaseGate(args: [String], json: Bool, markdown: Bool) throws {
        let candidate = value(after: "--candidate", in: args) ?? "conjet"
        let explicitContexts = value(after: "--contexts", in: args).map(csvList)
        let baselines = value(after: "--baselines", in: args)
            .map(csvList)
            ?? explicitContexts?.filter { $0 != candidate }
            ?? ["orbstack", "colima"]
        let contexts = value(after: "--contexts", in: args)
            .map(csvList)
            ?? []
        let iterations = value(after: "--iterations", in: args).flatMap(Int.init)
            ?? value(after: "--samples", in: args).flatMap(Int.init)
            ?? 3
        let minSamples = value(after: "--min-samples", in: args).flatMap(Int.init)
            ?? value(after: "--samples", in: args).flatMap(Int.init)
            ?? 3
        let requestedPhase = value(after: "--phase", in: args)
        let warmup = args.contains("--warmup") || requestedPhase?.lowercased() == BenchmarkSamplePhase.warm.rawValue
        let samplePhase = try benchmarkSamplePhase(
            from: requestedPhase,
            default: warmup ? .warm : .cold
        )
        let workloads = value(after: "--workloads", in: args)
            .map(csvList)
            ?? DockerBenchmarkSuite.defaultWorkloads
        let seconds = value(after: "--seconds", in: args).flatMap(Double.init)
        let interval = value(after: "--interval", in: args).flatMap(Double.init)
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(
                value(after: "--output-dir", in: args)
                    ?? value(after: "--output", in: args)
                    ?? defaultBenchmarkReleaseGateDirectory().path
            ),
            isDirectory: true
        )
        let workDirectory = value(after: "--work-dir", in: args)
            .map { URL(fileURLWithPath: expandedPath($0), isDirectory: true) }
        let options = BenchmarkReleaseGateOptions(
            contexts: contexts,
            candidateRuntime: candidate,
            baselineRuntimes: baselines,
            iterations: iterations,
            minimumSamples: minSamples,
            workloads: workloads,
            warmup: warmup,
            samplePhase: samplePhase,
            includeIdle: !args.contains("--no-idle"),
            includePower: !args.contains("--no-power"),
            idleSeconds: value(after: "--idle-seconds", in: args).flatMap(Double.init) ?? seconds ?? 30,
            idleInterval: value(after: "--idle-interval", in: args).flatMap(Double.init) ?? interval ?? 1,
            powerSeconds: value(after: "--power-seconds", in: args).flatMap(Double.init) ?? seconds ?? 60,
            powerInterval: value(after: "--power-interval", in: args).flatMap(Double.init) ?? interval ?? 1,
            powerSamplers: value(after: "--samplers", in: args) ?? "cpu_power,gpu_power,ane_power,tasks",
            useSudoForPower: !args.contains("--no-sudo"),
            dockerCommandTimeoutSeconds: value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 180
        )
        let ui = ConjetFetchUI(enabled: !json && !markdown)
        if !json && !markdown {
            ui.step("[bench 0/5] writing evidence to \(outputDirectory.path)")
        }
        let runner = BenchmarkReleaseGateRunner(
            options: options,
            dockerCollector: { contexts, iterations, warmup, workloads, workDirectory in
                ui.step("[bench 1/5] docker workloads: \(contexts.joined(separator: ", "))")
                return try DockerBenchmarkSuite(
                    contexts: contexts,
                    iterations: iterations,
                    warmup: warmup,
                    samplePhase: options.samplePhase,
                    workloads: workloads,
                    commandTimeoutSeconds: options.dockerCommandTimeoutSeconds
                ).run(workDirectory: workDirectory)
            },
            idleCollector: { runtime, iteration in
                ui.step("[bench 2/5] idle \(runtime) sample \(iteration)/\(options.iterations)")
                return try IdleResourceSampler(
                    runtime: runtime,
                    processPattern: defaultIdleProcessPattern(runtime: runtime),
                    durationSeconds: options.idleSeconds,
                    intervalSeconds: options.idleInterval
                ).run()
            },
            powerCollector: { runtime, iteration in
                ui.step("[bench 3/5] idle power \(runtime) sample \(iteration)/\(options.iterations)")
                return try PowerMetricsSampler(
                    runtime: runtime,
                    processPattern: defaultIdleProcessPattern(runtime: runtime),
                    durationSeconds: options.powerSeconds,
                    intervalSeconds: options.powerInterval,
                    samplers: options.powerSamplers,
                    useSudo: options.useSudoForPower
                ).run()
            },
            activeEnergyCollector: { runtime, iteration in
                ui.step("[bench 4/5] active energy \(runtime) sample \(iteration)/\(options.iterations)")
                return try ActivePowerSampler(
                    runtime: runtime,
                    workloadName: "container-start-energy-sample",
                    processPattern: defaultIdleProcessPattern(runtime: runtime),
                    maxDurationSeconds: options.powerSeconds,
                    minSampleSeconds: min(2, options.powerSeconds),
                    intervalSeconds: options.powerInterval,
                    samplers: options.powerSamplers,
                    useSudo: options.useSudoForPower
                ).run(
                    executable: "/usr/bin/env",
                    arguments: [
                        "sh",
                        "-c",
                        """
                        i=0
                        while [ "$i" -lt 10 ]; do
                          docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
                          i=$((i + 1))
                        done
                        """,
                        "conjet-energy-loop",
                        runtime
                    ]
                )
            }
        )
        let result = try runner.run(outputDirectory: outputDirectory, workDirectory: workDirectory)
        ui.step("[bench 5/5] claim gate \(result.gateReport.passed ? "passed" : "failed")")

        if json {
            print(try ConjetJSON.string(result))
        } else if markdown {
            print(BenchmarkClaimGateMarkdownReport.render(result.gateReport))
        } else {
            printBenchmarkReleaseGateResult(result)
        }
        if !result.gateReport.passed {
            throw ConjetError.unavailable("benchmark release gate failed; faster-than-OrbStack claim is not proven")
        }
    }

    private static func benchTopologyGate(args: [String], json: Bool, markdown: Bool) throws {
        let contexts = value(after: "--contexts", in: args).map(csvList) ?? ["conjet", "orbstack"]
        let samples = value(after: "--samples", in: args).flatMap(Int.init) ?? 10
        let commandTimeout = value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 180
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(value(after: "--output-dir", in: args) ?? defaultBenchmarkReleaseGateDirectory().path),
            isDirectory: true
        )
        let workDirectory = outputDirectory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let workloads = [
            "strict-bind-npm-install",
            "smart-bind-npm-install",
            "volume-npm-install",
            "conjetfs-npm-install",
            "strict-bind-pnpm-install",
            "smart-bind-pnpm-install",
            "volume-pnpm-install",
            "conjetfs-pnpm-install",
            "strict-bind-cargo-build",
            "smart-bind-cargo-build",
            "volume-cargo-build",
            "conjetfs-cargo-build",
            "strict-bind-hot-reload",
            "smart-bind-hot-reload",
            "conjetfs-hot-reload"
        ]
        let results = try DockerBenchmarkSuite(
            contexts: contexts,
            iterations: samples,
            warmup: true,
            samplePhase: .warm,
            workloads: workloads,
            commandTimeoutSeconds: commandTimeout
        ).run(workDirectory: workDirectory)
        let allResults = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.string(results).write(to: allResults, atomically: true, encoding: .utf8)
        let report = outputDirectory.appendingPathComponent("topology-gate.md")
        try renderTopologyGateMarkdown(results: results).write(to: report, atomically: true, encoding: .utf8)
        if json {
            print(try ConjetJSON.string(results))
        } else if markdown {
            print(try String(contentsOf: report, encoding: .utf8))
        } else {
            print("topology gate results: \(allResults.path)")
            print("topology gate report: \(report.path)")
        }
    }

    private static func benchPolyglotGate(args: [String], json: Bool, markdown: Bool) throws {
        let contexts = value(after: "--contexts", in: args).map(csvList) ?? ["conjet", "orbstack"]
        let samples = value(after: "--samples", in: args).flatMap(Int.init) ?? 5
        let ecosystems = value(after: "--ecosystems", in: args).map(csvList) ?? PolyglotBenchmarkSuite.defaultEcosystems
        let topology = value(after: "--topology", in: args) ?? "smart-bind"
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(value(after: "--output-dir", in: args) ?? defaultBenchmarkReleaseGateDirectory().path),
            isDirectory: true
        )
        let workDirectory = outputDirectory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let results = try PolyglotBenchmarkSuite(
            contexts: contexts,
            samples: samples,
            ecosystems: ecosystems,
            topology: topology,
            commandTimeoutSeconds: value(after: "--command-timeout", in: args).flatMap(Double.init) ?? 300
        ).run(workDirectory: workDirectory)
        let allResults = outputDirectory.appendingPathComponent("all-results.json")
        try ConjetJSON.string(results).write(to: allResults, atomically: true, encoding: .utf8)
        let report = outputDirectory.appendingPathComponent("polyglot-gate.md")
        try renderPolyglotGateMarkdown(results: results, ecosystems: ecosystems, topology: topology)
            .write(to: report, atomically: true, encoding: .utf8)
        if json {
            print(try ConjetJSON.string(results))
        } else if markdown {
            print(try String(contentsOf: report, encoding: .utf8))
        } else {
            print("polyglot gate results: \(allResults.path)")
            print("polyglot gate report: \(report.path)")
        }
    }

    private static func benchEnergyGate(args: [String], json: Bool, markdown: Bool) throws {
        let outputDirectory = URL(
            fileURLWithPath: expandedPath(value(after: "--output-dir", in: args) ?? defaultBenchmarkReleaseGateDirectory().path),
            isDirectory: true
        )
        let options = BenchmarkEnergyGateOptions(
            contexts: value(after: "--contexts", in: args).map(csvList) ?? ["conjet", "orbstack"],
            workloads: value(after: "--workloads", in: args).map(csvList) ?? ["idle", "container-start-loop", "hot-reload-loop", "compose-loop", "npm-install", "pnpm-install", "cargo-build"],
            samples: value(after: "--samples", in: args).flatMap(Int.init) ?? 10,
            requirePower: args.contains("--require-power"),
            useSudo: !args.contains("--no-sudo"),
            seconds: value(after: "--seconds", in: args).flatMap(Double.init) ?? 30,
            minimumActiveSeconds: value(after: "--min-active-seconds", in: args).flatMap(Double.init) ?? 10,
            workloadTimeoutSeconds: value(after: "--workload-timeout", in: args).flatMap(Double.init) ?? 180,
            interval: value(after: "--interval", in: args).flatMap(Double.init) ?? 1,
            samplers: value(after: "--samplers", in: args) ?? "cpu_power,gpu_power,ane_power,tasks",
            prepullImages: !args.contains("--no-prepull")
        )
        let result = try BenchmarkEnergyGateRunner(options: options).run(outputDirectory: outputDirectory)
        if json {
            print(try ConjetJSON.string(result))
        } else if markdown {
            print(try String(contentsOfFile: result.markdownReport, encoding: .utf8))
        } else {
            print("energy gate: \(result.powermetricsAvailable ? "measured" : "skipped")")
            if let reason = result.skippedReason {
                print("  reason: \(reason)")
            }
            print("  results: \(result.allResultsReport)")
            print("  report: \(result.markdownReport)")
        }
    }

    private static func sync(args: [String], json: Bool) throws {
        let subcommand = args.first ?? "status"
        switch subcommand {
        case "classify":
            guard args.count >= 2 else {
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
        case "push":
            let result = try syncProject(root: projectRoot(from: Array(args.dropFirst())), json: json)
            try printConjetFSSyncResult(result, json: json, headline: "ConjetFS sync pushed")
        case "repair":
            let result = try syncProject(root: projectRoot(from: Array(args.dropFirst())), json: json)
            try printConjetFSSyncResult(result, json: json, headline: "ConjetFS sync repaired")
        case "watch":
            try watchConjetFSProject(args: Array(args.dropFirst()), json: json)
        case "export":
            try exportConjetFSPaths(args: Array(args.dropFirst()), json: json)
        case "status":
            let root = projectRoot(from: Array(args.dropFirst()))
            let fs = conjetFS(root: root)
            let project = try fs.loadOrInitializeProject()
            let status = try fs.status(project: project)
            try printConjetFSStatus(status, json: json, headline: "ConjetFS sync status")
        default:
            throw ConjetError.invalidArgument("unknown sync command '\(subcommand)'")
        }
    }

    private static func project(args: [String], json: Bool) throws {
        let subcommand = args.first ?? "status"
        switch subcommand {
        case "init":
            let root = projectRoot(from: Array(args.dropFirst()))
            let fs = conjetFS(root: root)
            let project = try fs.initializeProject()
            let plan = try fs.makePlan(project: project)
            if json {
                print(try ConjetJSON.string(project))
            } else {
                print("ConjetFS project initialized")
                print("  project: \(project.name)")
                print("  host: \(project.hostRoot)")
                print("  volume: \(project.dockerVolume)")
                print("  guest: \(project.guestPath)")
                print("  host-synced files: \(plan.includedFiles.count)")
                print("  vm-native/skipped files: \(plan.skippedFiles.count)")
            }
        case "attach":
            let root = projectRoot(from: Array(args.dropFirst()))
            if args.contains("--no-sync") {
                let fs = conjetFS(root: root)
                let project = try fs.loadOrInitializeProject()
                let result = ConjetFSSyncResult(
                    project: project,
                    dockerContext: ConjetFS.defaultDockerContext(profileName: ConjetPaths.default().profileName),
                    guestPath: project.guestPath,
                    includedFiles: 0,
                    skippedFiles: 0,
                    removedFiles: 0,
                    includedBytes: 0,
                    skippedBytes: 0,
                    dockerVolume: project.dockerVolume,
                    containerMountArgument: "\(project.dockerVolume):\(project.guestPath)"
                )
                try printConjetFSSyncResult(result, json: json, headline: "ConjetFS project attached")
            } else {
                let result = try syncProject(root: root, json: json)
                try printConjetFSSyncResult(result, json: json, headline: "ConjetFS project attached")
            }
        case "run":
            try projectRun(args: Array(args.dropFirst()), json: json)
        case "status":
            let root = projectRoot(from: Array(args.dropFirst()))
            let fs = conjetFS(root: root)
            let project = try fs.loadOrInitializeProject()
            let status = try fs.status(project: project)
            try printConjetFSStatus(status, json: json, headline: "ConjetFS project")
        default:
            throw ConjetError.invalidArgument("unknown project command '\(subcommand)'")
        }
    }

    private static func syncProject(root: URL, json: Bool) throws -> ConjetFSSyncResult {
        _ = try ensureConjetDockerSocket()
        let fs = conjetFS(root: root)
        let project = try fs.loadOrInitializeProject()
        return try fs.sync(project: project)
    }

    private static func watchConjetFSProject(args: [String], json: Bool) throws {
        let interval = value(after: "--interval", in: args).flatMap(Double.init) ?? 1
        let debounce = value(after: "--debounce", in: args).flatMap(Double.init) ?? 0.005
        let once = args.contains("--once")
        let poll = args.contains("--poll")
        let root = projectRoot(from: args)
        _ = try ensureConjetDockerSocket()
        let fs = conjetFS(root: root)
        let project = try fs.loadOrInitializeProject()
        var cycle = 0
        var syncHelper: String?
        defer {
            if let syncHelper {
                fs.stopSyncHelper(syncHelper)
            }
        }

        if !json {
            print("ConjetFS sync watch")
            print("  project: \(project.name)")
            print("  host: \(project.hostRoot)")
            print("  mode: \(poll || once ? "poll" : "fsevents")")
            if poll || once {
                print("  interval: \(String(format: "%.3f", interval))s")
            } else {
                print("  debounce: \(String(format: "%.3f", debounce))s")
            }
        }

        func syncIfDirty(force: Bool, event: ConjetFSWatchEvent? = nil) throws {
            if let event, !force {
                let result = try fs.sync(
                    project: project,
                    changedPaths: event.changedPaths,
                    helperContainer: syncHelper
                )
                if json {
                    print(try ConjetJSON.string(result, pretty: false))
                } else if result.changedFiles > 0 || result.removedFiles > 0 {
                    print("=> event \(event.changedPaths.prefix(6).joined(separator: ", "))")
                    print("=> synced \(result.changedFiles) changed, \(result.removedFiles) removed")
                } else {
                    print("=> event \(event.changedPaths.prefix(6).joined(separator: ", "))")
                    print("=> clean")
                }
                return
            }

            let status = try fs.status(project: project)
            if force || status.dirty {
                let result = try fs.sync(project: project)
                if json {
                    print(try ConjetJSON.string(result, pretty: false))
                } else if let event {
                    print("=> event \(event.changedPaths.prefix(6).joined(separator: ", "))")
                    print("=> synced \(result.changedFiles) changed, \(result.removedFiles) removed")
                } else {
                    print("=> synced \(result.changedFiles) changed, \(result.removedFiles) removed")
                }
            } else if !json {
                print("=> clean")
            }
        }

        if once || poll {
            repeat {
                try syncIfDirty(force: cycle == 0)
                cycle += 1
                if once { break }
                Thread.sleep(forTimeInterval: max(0.1, interval))
            } while true
            return
        }

        try syncIfDirty(force: true)
        syncHelper = try fs.startSyncHelper(project: project)
        let watcher = ConjetFSHostEventStream(root: root, debounceSeconds: debounce)
        try watcher.run { event in
            do {
                try syncIfDirty(force: false, event: event)
            } catch {
                FileHandle.standardError.write(Data("conjet sync watch: \(error)\n".utf8))
            }
        }
    }

    private static func exportConjetFSPaths(args: [String], json: Bool) throws {
        let root = projectRootFromPathOption(args)
        let exportPaths = positionalArguments(from: args, valueOptions: ["--path", "--to", "--destination"])
        guard !exportPaths.isEmpty else {
            throw ConjetError.invalidArgument("usage: conjet sync export PATH... --to DEST [--path PROJECT]")
        }
        let destination = value(after: "--to", in: args)
            ?? value(after: "--destination", in: args)
            ?? FileManager.default.currentDirectoryPath
        _ = try ensureConjetDockerSocket()
        let fs = conjetFS(root: root)
        let project = try fs.loadOrInitializeProject()
        let result = try fs.export(
            project: project,
            paths: exportPaths,
            to: URL(fileURLWithPath: expandedPath(destination), isDirectory: true)
        )
        if json {
            print(try ConjetJSON.string(result))
        } else {
            print("ConjetFS export complete")
            print("  project: \(result.project.name)")
            print("  volume: \(result.dockerVolume)")
            print("  destination: \(result.hostDestination)")
            print("  exported: \(result.exportedPaths.joined(separator: ", "))")
        }
    }

    private static func conjetFS(root: URL) -> ConjetFS {
        let paths = ConjetPaths.default()
        return ConjetFS(
            projectRoot: root,
            paths: paths,
            dockerContext: dockerContextName(profileName: paths.profileName)
        )
    }

    private static func defaultIdleProcessPattern(runtime: String) -> String {
        BenchmarkReleaseGateRunner.defaultProcessPattern(runtime: runtime)
    }

    private static func csvList(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func benchmarkSamplePhase(
        from value: String?,
        default defaultPhase: BenchmarkSamplePhase
    ) throws -> BenchmarkSamplePhase {
        guard let value else {
            return defaultPhase
        }
        guard let phase = BenchmarkSamplePhase(rawValue: value.lowercased()) else {
            throw ConjetError.invalidArgument("invalid benchmark phase '\(value)'; expected any, cold, cold-base-prepulled, no-cache, true-cold, or warm")
        }
        return phase
    }

    private static func defaultBenchmarkReleaseGateDirectory(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("bench", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent("release-gate-\(formatter.string(from: now))", isDirectory: true)
    }

    private static func printConjetFSSyncResult(_ result: ConjetFSSyncResult, json: Bool, headline: String) throws {
        if json {
            print(try ConjetJSON.string(result))
        } else {
            print(headline)
            print("  project: \(result.project.name)")
            print("  host: \(result.project.hostRoot)")
            print("  docker context: \(result.dockerContext)")
            print("  volume: \(result.dockerVolume)")
            print("  guest path: \(result.guestPath)")
            print("  host-synced: \(result.includedFiles) files")
            print("  changed: \(result.changedFiles) files")
            print("  skipped vm-native: \(result.skippedFiles) files")
            print("  removed: \(result.removedFiles) files")
            print("  docker run args: -v \(result.containerMountArgument) -w \(result.guestPath)")
        }
    }

    private static func printBenchmarkReleaseGateResult(_ result: BenchmarkReleaseGateRunResult) {
        print(result.gateReport.passed ? "benchmark release gate: passed" : "benchmark release gate: failed")
        print("  output: \(result.artifacts.outputDirectory)")
        print("  docker report: \(result.artifacts.dockerReport)")
        print("  all results: \(result.artifacts.allResultsReport)")
        print("  markdown: \(result.artifacts.allResultsMarkdown)")
        print("  gate report: \(result.artifacts.gateReport)")
        print("  gate markdown: \(result.artifacts.gateMarkdownReport)")
        if !result.artifacts.idleReports.isEmpty {
            print("  idle reports: \(result.artifacts.idleReports.count)")
        }
        if !result.artifacts.powerReports.isEmpty {
            print("  power reports: \(result.artifacts.powerReports.count)")
        }
        if !result.artifacts.energyReports.isEmpty {
            print("  energy reports: \(result.artifacts.energyReports.count)")
        }
        printBenchmarkGateReport(result.gateReport)
    }

    private static func printBenchmarkGateReport(_ report: BenchmarkClaimGateReport) {
        print(report.passed ? "benchmark gate: passed" : "benchmark gate: failed")
        print("  candidate: \(report.candidateRuntime)")
        print("  baselines: \(report.baselineRuntimes.joined(separator: ", "))")
        print("  minimum samples: \(report.minimumSamples)")
        print("  sample phase: \(report.samplePhase.rawValue)")
        if !report.missingRequirements.isEmpty {
            print("  missing requirements:")
            for requirement in report.missingRequirements.prefix(20) {
                print("    - \(requirement)")
            }
            if report.missingRequirements.count > 20 {
                print("    - ... \(report.missingRequirements.count - 20) more")
            }
        }
        let failed = report.comparisons.filter { !$0.passed }
        if !failed.isEmpty {
            print("  failed comparisons:")
            for comparison in failed.prefix(20) {
                print("    - \(benchmarkComparisonLabel(comparison)) vs \(comparison.baselineRuntime): \(comparison.reason)")
            }
            if failed.count > 20 {
                print("    - ... \(failed.count - 20) more")
            }
        }
    }

    private static func benchmarkComparisonLabel(_ comparison: BenchmarkClaimComparison) -> String {
        if comparison.candidateWorkload == comparison.workload && comparison.baselineWorkload == comparison.workload {
            return comparison.workload
        }
        return "\(comparison.workload) (\(comparison.candidateWorkload) -> \(comparison.baselineWorkload))"
    }

    private static func renderBenchmarkGateMarkdown(_ report: BenchmarkClaimGateReport) -> String {
        var lines: [String] = [
            "# Conjet Benchmark Claim Gate",
            "",
            "- Verdict: \(report.passed ? "passed" : "failed")",
            "- Candidate: \(report.candidateRuntime)",
            "- Baselines: \(report.baselineRuntimes.joined(separator: ", "))",
            "- Minimum samples: \(report.minimumSamples)",
            "- Sample phase: \(report.samplePhase.rawValue)",
            ""
        ]

        if !report.missingRequirements.isEmpty {
            lines.append("## Missing Requirements")
            lines.append("")
            for requirement in report.missingRequirements {
                lines.append("- \(requirement)")
            }
            lines.append("")
        }

        lines.append("## Comparisons")
        lines.append("")
        lines.append("| Claim | Candidate Workload | Baseline | Baseline Workload | Measure | Candidate P50 | Baseline P50 | P50 Ratio | Candidate P95 | Baseline P95 | P95 Ratio | Result |")
        lines.append("| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
        for comparison in report.comparisons {
            lines.append(
                "| \(comparison.workload) | \(comparison.candidateWorkload) | \(comparison.baselineRuntime) | \(comparison.baselineWorkload) | \(comparison.measure) | \(formatOptional(comparison.candidateP50)) | \(formatOptional(comparison.baselineP50)) | \(formatOptional(comparison.p50Ratio)) | \(formatOptional(comparison.candidateP95)) | \(formatOptional(comparison.baselineP95)) | \(formatOptional(comparison.p95Ratio)) | \(comparison.passed ? "pass" : comparison.reason) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTopologyGateMarkdown(results: [BenchmarkResult]) -> String {
        var lines = [
            "# Conjet Topology Gate",
            "",
            "strict-bind is maximum compatibility and may be slower.",
            "smart-bind/native-overlay is Conjet's default optimized topology candidate.",
            "conjetfs is the fast-path workspace.",
            "volume is the Linux-native baseline.",
            "",
            "## Claim Discipline",
            "",
            "| Claim | Status | Evidence | Caveat |",
            "| --- | --- | --- | --- |",
            "| Conjet strict bind is faster than OrbStack. | Not proven unless strict-bind comparisons pass. | strict-bind workloads in this report. | SmartMount/native-overlay is separate evidence. |",
            "| Conjet SmartMount/native-overlay topology is faster than OrbStack on selected workloads. | Partial until the gate comparisons pass. | smart-bind workloads in this report. | Not identical to raw Docker bind semantics. |",
            "| ConjetFS fast path is faster than bind on selected workloads. | Partial until measured comparisons pass. | conjetfs workloads in this report. | Uses ConjetFS-managed source synchronization. |",
            "",
            "## Raw Summary",
            ""
        ]
        lines.append(BenchmarkMarkdownReport.render(results: results, title: "Conjet Topology Results"))
        return lines.joined(separator: "\n")
    }

    private static func renderPolyglotGateMarkdown(results: [BenchmarkResult], ecosystems: [String], topology: String) -> String {
        var lines = [
            "# Conjet Polyglot Gate",
            "",
            "- Ecosystems: \(ecosystems.joined(separator: ", "))",
            "- Topology: \(topology)",
            "",
            "Status: Partial until the measured p50/p95 comparisons pass for the selected real-project workloads.",
            "",
            "## Raw Summary",
            ""
        ]
        lines.append(BenchmarkMarkdownReport.render(results: results, title: "Conjet Polyglot Results"))
        return lines.joined(separator: "\n")
    }

    private static func formatOptional(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.3f", value)
    }

    private static func printConjetFSStatus(_ status: ConjetFSStatus, json: Bool, headline: String) throws {
        if json {
            print(try ConjetJSON.string(status))
        } else {
            print(headline)
            print("  project: \(status.project.name)")
            print("  host: \(status.project.hostRoot)")
            print("  docker context: \(status.dockerContext)")
            print("  volume: \(status.dockerVolume)")
            print("  guest: \(status.guestPath)")
            print("  state: \(status.dirty ? "dirty" : "clean")")
            print("  host-synced: \(status.hostSyncedFiles) files")
            print("  changed since last push: \(status.changedFiles) files")
            print("  removed since last push: \(status.removedFiles) files")
            print("  vm-native/skipped: \(status.skippedFiles) files")
            if let manifestUpdatedAt = status.manifestUpdatedAt {
                print("  last push: \(manifestUpdatedAt)")
            }
        }
    }

    private static func projectRun(args: [String], json: Bool) throws {
        let noSync = args.contains("--no-sync")
        let root = value(after: "--path", in: args)
            .map { URL(fileURLWithPath: expandedPath($0), isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let runArgs = args.removingOption("--path").filter { $0 != "--no-sync" }
        guard let image = runArgs.first else {
            throw ConjetError.invalidArgument("usage: conjet project run [--path PATH] [--no-sync] IMAGE [CMD...]")
        }

        let result: ConjetFSSyncResult
        if noSync {
            let fs = conjetFS(root: root)
            let project = try fs.loadOrInitializeProject()
            result = ConjetFSSyncResult(
                project: project,
                dockerContext: ConjetFS.defaultDockerContext(profileName: ConjetPaths.default().profileName),
                guestPath: project.guestPath,
                includedFiles: 0,
                skippedFiles: 0,
                removedFiles: 0,
                includedBytes: 0,
                skippedBytes: 0,
                dockerVolume: project.dockerVolume,
                containerMountArgument: "\(project.dockerVolume):\(project.guestPath)"
            )
        } else {
            result = try syncProject(root: root, json: json)
        }

        let socket = try ensureConjetDockerSocket()
        var dockerArgs = [
            "docker",
            "--host",
            "unix://\(socket)",
            "run",
            "--rm"
        ]
        let topology = ConjetPackageTopologyOptimizer.plan(projectRoot: root, guestPath: result.guestPath)
        dockerArgs += topology.dockerEnvironmentArguments()
        if !json, isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 {
            dockerArgs.append("-it")
        }
        dockerArgs += [
            "--mount",
            "type=volume,source=\(result.dockerVolume),target=\(result.guestPath)",
            "-w",
            result.guestPath,
            image
        ] + Array(runArgs.dropFirst())

        if json {
            let process = try ProcessRunner.run("/usr/bin/env", dockerArgs)
            print(try ConjetJSON.string(ConjetFSProjectRunResult(sync: result, process: process)))
            guard process.succeeded else {
                throw ConjetError.processFailed(
                    executable: process.executable,
                    exitCode: process.exitCode,
                    stderr: process.stderr
                )
            }
        } else {
            try runInheritedProcess("/usr/bin/env", dockerArgs)
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

    private static func activateProfile(_ profileName: String) throws {
        guard ConjetPaths.isValidProfileName(profileName) else {
            throw ConjetError.invalidArgument("--profile must contain only letters, numbers, '.', '_' or '-' and cannot start with '.'")
        }
        setenv("CONJET_PROFILE", profileName, 1)
    }

    private static func removeLeadingProfileOption(from args: inout [String]) throws -> String? {
        guard args.first == "--profile" else { return nil }
        guard args.indices.contains(1) else {
            throw ConjetError.invalidArgument("--profile requires a name")
        }
        let profileName = args[1]
        args.removeFirst(2)
        return profileName
    }

    private static func removeProfileOption(from args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: "--profile") else { return nil }
        guard args.indices.contains(index + 1) else {
            throw ConjetError.invalidArgument("--profile requires a name")
        }
        let profileName = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return profileName
    }

    private static func listProfiles(rootHome: URL) throws -> [String] {
        var profiles = ["default"]
        let profilesDirectory = rootHome.appendingPathComponent("profiles", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for entry in entries {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true,
                   ConjetPaths.isValidProfileName(entry.lastPathComponent) {
                    profiles.append(entry.lastPathComponent)
                }
            }
        }
        return Array(Set(profiles)).sorted()
    }

    private static func printProfileSummary(paths: ConjetPaths, config: ConjetConfig) {
        print("  profile: \(paths.profileName)")
        print("  home: \(paths.home.path)")
        print("  arch: \(config.architecture)")
        print("  cpus: \(config.vmCPUs)")
        print("  memory: \(config.memoryMiB / 1024) GiB")
        print("  disk: \(config.diskGiB) GiB")
        if let diskImagePath = config.diskImagePath {
            print("  disk image: \(diskImagePath)")
        }
        print("  runtime: \(config.runtime)")
    }

    private static func consumeValue(_ flag: String, from args: inout [String]) throws -> String {
        guard let value = args.first else {
            throw ConjetError.invalidArgument("\(flag) requires a value")
        }
        args.removeFirst()
        return value
    }

    private static func parsePositiveInt(_ value: String, flag: String) throws -> Int {
        guard let integer = Int(value), integer > 0 else {
            throw ConjetError.invalidArgument("\(flag) must be a positive integer")
        }
        return integer
    }

    private static func parseMemoryMiB(_ value: String, flag: String) throws -> Int {
        let lowercased = value.lowercased()
        if lowercased.hasSuffix("mib") || lowercased.hasSuffix("mb") {
            let number = lowercased
                .replacingOccurrences(of: "mib", with: "")
                .replacingOccurrences(of: "mb", with: "")
            return try parsePositiveInt(number, flag: flag)
        }
        return try parsePositiveInt(stripGiBSuffix(lowercased), flag: flag) * 1024
    }

    private static func parseOptionalGiB(_ value: String, flag: String) throws -> Int? {
        let stripped = stripGiBSuffix(value.lowercased())
        guard stripped.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return try parsePositiveInt(stripped, flag: flag)
    }

    private static func stripGiBSuffix(_ value: String) -> String {
        value
            .replacingOccurrences(of: "gib", with: "")
            .replacingOccurrences(of: "gb", with: "")
            .replacingOccurrences(of: "g", with: "")
    }

    private static func normalizeArchitecture(_ value: String) throws -> String {
        switch value.lowercased() {
        case "arm64", "arm64e", "aarch64":
            return "aarch64"
        case "amd64", "x86_64":
            return "x86_64"
        default:
            throw ConjetError.invalidArgument("--arch must be aarch64 or x86_64")
        }
    }

    private static func normalizeRuntime(_ value: String) throws -> String {
        guard value == "docker" else {
            throw ConjetError.invalidArgument("--runtime currently supports docker")
        }
        return value
    }

    private static func expandedPath(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func projectRoot(from args: [String]) -> URL {
        if let path = value(after: "--path", in: args) {
            return URL(fileURLWithPath: expandedPath(path), isDirectory: true)
        }
        let positionals = positionalArguments(
            from: args,
            valueOptions: ["--path", "--interval", "--debounce", "--to", "--destination", "--seconds", "--process", "--runtime"]
        )
        let path = positionals.first ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: expandedPath(path), isDirectory: true)
    }

    private static func projectRootFromPathOption(_ args: [String]) -> URL {
        let path = value(after: "--path", in: args) ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: expandedPath(path), isDirectory: true)
    }

    private static func positionalArguments(from args: [String], valueOptions: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let element = args[index]
            if element.hasPrefix("--") {
                index += valueOptions.contains(element) ? 2 : 1
                continue
            }
            result.append(element)
            index += 1
        }
        return result
    }

    private static func gibibytes(_ value: Int) -> Int64 {
        Int64(value) * 1024 * 1024 * 1024
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
        dockerContext: DockerContextResult? = nil,
        hostShares: HostShareMountResult? = nil,
        headline: String? = nil
    ) throws {
        if json {
            print(try ConjetJSON.string(response))
            if failOnError, !response.ok {
                try throwResponseError(response.message)
            }
            return
        }
        print(headline ?? response.message)
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
            if let hostShares {
                print("  host shares: \(hostShares.mountedPaths.joined(separator: ", "))")
            }
        }
        if failOnError, !response.ok {
            try throwResponseError(response.message)
        }
    }

    private static func printStartVMResponse(
        _ response: DaemonResponse,
        dockerContext: DockerContextResult?,
        hostShares: HostShareMountResult?
    ) {
        print(vmStartHeadline(response))
        if let dockerContext {
            ConjetFetchUI(enabled: true).step("[docker context internal] using \(dockerContext.contextName)")
        }
        if let hostShares {
            ConjetFetchUI(enabled: true).step("[host shares internal] mounted \(hostShares.mountedPaths.joined(separator: ", "))")
        }
        if let vm = response.vm ?? response.status?.vm {
            print("  vm: \(vm.state.rawValue)")
            print("  serial log: \(vm.serialLogPath ?? "unknown")")
            if let dockerContext {
                print("  docker context: \(dockerContext.contextName)")
            }
            if let hostShares {
                print("  host shares: \(hostShares.mountedPaths.joined(separator: ", "))")
            }
        }
    }

    private static func vmStartHeadline(_ response: DaemonResponse) -> String {
        guard response.ok else {
            return "=> ERROR [vm 2/2] \(response.message)"
        }
        let state = (response.vm ?? response.status?.vm)?.state.rawValue ?? "unknown"
        if response.message.localizedCaseInsensitiveContains("already") {
            return "=> CACHED [vm 2/2] \(state)"
        }
        return "=> [vm 2/2] \(state)"
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
        let text = try benchmarkOutputIsMarkdown(url: url, requestedMarkdown: markdown)
            ? BenchmarkMarkdownReport.render(results: results, title: "Conjet Docker Context Benchmark")
            : ConjetJSON.string(results)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func benchmarkOutputIsMarkdown(url: URL, requestedMarkdown: Bool) -> Bool {
        guard requestedMarkdown else { return false }
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return true
        default:
            return false
        }
    }

    private static func ensureVMConfiguredForStart(json: Bool, config: ConjetConfig) throws {
        let store = VMImageStore()
        if store.manifestExists() {
            try store.expandDataDiskIfNeeded(sizeBytes: gibibytes(config.diskGiB))
            return
        }

        let ui = ConjetFetchUI(enabled: !json)
        let artifact: String
        if let diskImagePath = config.diskImagePath {
            ui.step("[conjet-core internal] VM image missing; using custom img")
            artifact = diskImagePath
        } else {
            let repository = conjetCoreRepository(cliValue: nil, config: config)
            ui.step("[conjet-core internal] VM image missing; fetching latest release")
            artifact = try downloadLatestConjetCoreArtifact(
                repository: repository,
                architecture: config.architecture,
                runtime: config.runtime,
                force: false,
                printStatus: !json
            )
        }
        ui.step("[conjet-core 4/4] importing img")
        let manifest = try store.importEFIBootDisk(
            sourcePath: artifact,
            name: "conjet-core",
            force: true,
            cloudInitSeedPath: nil,
            bootDiskMinimumSizeBytes: nil,
            dataDiskSizeBytes: gibibytes(config.diskGiB)
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
        let config = try ConjetConfig.loadOrCreate()
        return try downloadLatestConjetCoreArtifact(
            repository: repository,
            architecture: config.architecture,
            runtime: config.runtime,
            force: force,
            printStatus: printStatus
        )
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
        architecture: String,
        runtime: String,
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
            hostArchitecture: architecture,
            runtime: runtime
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
        _ = try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .stop), timeoutSeconds: 5)
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
            return try DockerContextManager(contextName: dockerContextName(profileName: ConjetPaths.default().profileName))
                .ensureContext(socketPath: dockerSocketPath, makeCurrent: true)
        } catch {
            if !json {
                writeDiagnostic(
                    "could not configure Docker context '\(dockerContextName(profileName: ConjetPaths.default().profileName))': \(error)"
                )
            }
            return nil
        }
    }

    private static func dockerContextName(profileName: String) -> String {
        profileName == "default" ? "conjet" : "conjet-\(profileName)"
    }

    private static func mountHostSharesIfStarted(
        _ response: DaemonResponse,
        dockerContext: DockerContextResult?,
        config: ConjetConfig,
        json: Bool
    ) -> HostShareMountResult? {
        guard config.enableHostMounts,
              response.ok,
              let dockerContext else {
            return nil
        }

        do {
            return try HostShareMounter(dockerContext: dockerContext.contextName).ensureMounted()
        } catch {
            if !json {
                writeDiagnostic("could not mount Conjet host shares in guest: \(error)")
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

    private static func argsBeforeDoubleDash(_ args: [String]) -> [String] {
        guard let separator = args.firstIndex(of: "--") else {
            return args
        }
        return Array(args[..<separator])
    }

    private static func commandAfterDoubleDash(in args: [String], usage: String) throws -> [String] {
        guard let separator = args.firstIndex(of: "--") else {
            throw ConjetError.invalidArgument(usage)
        }
        let command = Array(args[(separator + 1)...])
        guard !command.isEmpty else {
            throw ConjetError.invalidArgument(usage)
        }
        return command
    }

    private static func printHelp() {
        print(
            """
            conjet - light macOS container runtime prototype

            Global:
              conjet [--profile NAME] COMMAND...
              CONJET_HOME=/path/to/home moves Conjet state off ~/.conjet

            Commands:
              conjet doctor [--json]
              conjet start [--cpu N] [--memory GiB] [--disk GiB|PATH] [--runtime docker] [--arch aarch64|x86_64] [--json]
              conjet status [--json]
              conjet stop
              conjet profile status|list [--json]
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
              conjet project init|attach|status [PATH] [--json]
              conjet project run [--path PATH] [--no-sync] IMAGE [CMD...] [--json]
              conjet bench profile [--json]
              conjet bench idle [--runtime NAME] [--process REGEX] [--seconds N] [--interval N] [--output PATH] [--json|--markdown]
              conjet bench power [--runtime NAME] [--process REGEX] [--seconds N] [--interval N] [--output PATH] [--no-sudo] [--json|--markdown]
              conjet bench energy [--runtime NAME] [--workload NAME] [--process REGEX] [--seconds N] [--min-seconds N] [--interval N] [--output PATH] [--no-sudo] [--json|--markdown] -- COMMAND...
              conjet bench gate --reports report.json[,report2.json] [--candidate conjet] [--baselines orbstack,colima] [--min-samples N] [--phase any|cold|cold-base-prepulled|no-cache|true-cold|warm] [--workloads NAME,...] [--no-idle] [--no-power] [--json|--markdown]
              conjet bench release-gate|global-gate [--contexts conjet,orbstack,colima] [--samples N|--iterations N] [--phase cold|cold-base-prepulled|no-cache|true-cold|warm] [--warmup] [--workloads NAME,...] [--command-timeout N] [--output-dir DIR] [--seconds N] [--no-sudo] [--no-power] [--json|--markdown]
              conjet bench topology-gate [--contexts conjet,orbstack] [--samples N] [--output-dir DIR] [--json|--markdown]
              conjet bench polyglot-gate [--contexts conjet,orbstack] [--samples N] [--ecosystems js,python,jvm,dotnet,go,rust,cpp] [--topology smart-bind|strict-bind|volume] [--output-dir DIR] [--json|--markdown]
              conjet bench energy-gate [--contexts conjet,orbstack] [--workloads idle,container-start-loop] [--samples N] [--seconds N] [--min-active-seconds N] [--workload-timeout N] [--no-prepull] [--require-power] [--output-dir DIR] [--json|--markdown]
                Active workloads are pre-pulled, repeated for --min-active-seconds, and bounded by --workload-timeout.
              conjet bench small-files [--files N] [--bytes N] [--dir PATH] [--json|--markdown]
              conjet bench docker-compare [--contexts conjet,colima] [--iterations N] [--workloads NAME,...] [--warmup] [--command-timeout N] [--output PATH] [--json|--markdown]
              conjet sync classify PATH [--json]
              conjet sync push|status|repair [PATH] [--json]
              conjet sync watch [PATH] [--debounce N] [--poll --interval N] [--once] [--json]
              conjet sync export PATH... --to DEST [--path PROJECT] [--json]
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

    func cached(_ message: String) {
        guard enabled else { return }
        print("=> CACHED \(message)")
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

private struct ProfileStatus: Codable, Equatable {
    var profile: String
    var home: String
    var config: ConjetConfig
}

private struct ConjetFSProjectRunResult: Codable, Equatable {
    var sync: ConjetFSSyncResult
    var process: ProcessResult
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

    func removingOption(_ option: String) -> [String] {
        var result: [String] = []
        var skipNext = false
        for element in self {
            if skipNext {
                skipNext = false
                continue
            }
            if element == option {
                skipNext = true
                continue
            }
            result.append(element)
        }
        return result
    }
}

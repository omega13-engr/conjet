import ConjetCore
import ConjetManagement
import ConjetVZ
import Foundation

extension ConjetCLI {
    static func buildQAInitramfsIfRequested(args: [String], output: URL) throws -> InitramfsBuildResult? {
        guard args.contains("--network-proof") else {
            return nil
        }
        guard let busyboxPath = value(after: "--busybox", in: args) else {
            throw ConjetError.invalidArgument(
                "usage: conjet vm build-initramfs --network-proof --busybox PATH [--proof-url URL] [--guest-service-port PORT] [--output PATH]"
            )
        }
        return try InitramfsBuilder.buildNetworkProofProbe(
            busybox: URL(fileURLWithPath: busyboxPath),
            output: output,
            proofURL: value(after: "--proof-url", in: args) ?? "http://example.com",
            guestServicePort: try positiveIntegerOption("--guest-service-port", in: args, defaultValue: 8080)
        )
    }

    static func handleVMQACommand(_ subcommand: String, args: [String], json: Bool) throws -> Bool {
        switch subcommand {
        case "import-phase9-network-proof":
            try importPhase9NetworkProof(args: args, json: json)
            return true
        default:
            return false
        }
    }

    static func vmBackend(args rawArgs: [String], json: Bool) throws {
        var args = rawArgs
        let json = try args.removeJSONFormatOption() || json
        let subcommand = args.first ?? "status"
        let paths = ConjetPaths.default()
        switch subcommand {
        case "status":
            let config = try ConjetConfig.loadOrCreate(paths: paths)
            let active = runningBackend(paths: paths)
            try printVMBackendStatus(
                ConjetVMBackendSelectionStatus(selected: config.vmBackend, active: active),
                json: json
            )
        case "set":
            guard args.indices.contains(1) else {
                throw ConjetError.invalidArgument("usage: conjet vm backend set <vz|hvf-experimental>")
            }
            let backend = try parseVMBackend(args[1])
            var config = try ConjetConfig.loadOrCreate(paths: paths)
            config.vmBackend = backend
            try config.save(paths: paths)
            try printVMBackendStatus(
                ConjetVMBackendSelectionStatus(selected: backend, active: runningBackend(paths: paths)),
                json: json
            )
        case "smoke":
            let tool = ConjetToolResolver.conjetCoreVMM()
            let invocation = tool.invocation(
                arguments: ["smoke", "--json"],
                displayName: "Conjet Core Rust VMM smoke",
                timeoutSeconds: 15
            )
            let process = try ProcessRunner.run(invocation.executable, invocation.arguments, timeoutSeconds: 15)
            if json {
                print(process.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                print("Conjet Core Rust VMM smoke")
                print("  vmm: \(tool.executable) (\(tool.source))")
                print("  exit code: \(process.exitCode)")
                if !process.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print(process.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if !process.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print(process.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if !process.succeeded {
                throw ConjetError.unavailable(process.stderr.isEmpty ? "Conjet Core Rust VMM smoke failed" : process.stderr)
            }
        case "rust-boot-attempt", "boot-attempt":
            let output = try conjetCoreRustBootAttempt(args: args, paths: paths)
            try printConjetCoreRustBootAttemptOutput(output, json: json)
            if !output.process.succeeded {
                throw ConjetError.unavailable(output.report?.message ?? output.process.stderr)
            }
        default:
            if let backend = ConjetVMBackend.parse(subcommand) {
                var config = try ConjetConfig.loadOrCreate(paths: paths)
                config.vmBackend = backend
                try config.save(paths: paths)
                try printVMBackendStatus(
                    ConjetVMBackendSelectionStatus(selected: backend, active: runningBackend(paths: paths)),
                    json: json
                )
            } else {
                throw ConjetError.invalidArgument("unknown vm backend command '\(subcommand)'")
            }
        }
    }

    private static func importPhase9NetworkProof(args: [String], json: Bool) throws {
        guard let bundleManifest = value(after: "--manifest", in: args) else {
            throw ConjetError.invalidArgument(
                "usage: conjet vm import-phase9-network-proof --manifest PATH [--cmdline TEXT] [--json]"
            )
        }
        let config = try ConjetConfig.loadOrCreate()
        let manifest = try VMImageStore().importPhase9NetworkProofBundle(
            manifestPath: bundleManifest,
            kernelCommandLine: value(after: "--cmdline", in: args),
            dataDiskSizeBytes: gibibytes(config.diskGiB)
        )
        try printVMManifest(
            manifest,
            json: json,
            headline: "Phase 9 network-proof VM assets configured: \(manifest.name)"
        )
    }

    private static func runningBackend(paths: ConjetPaths) -> ConjetVMBackend? {
        guard let socketPath = try? socketPath(paths: paths),
              daemonIsRunning(socketPath: socketPath),
              let response = try? UnixSocketClient(socketPath: socketPath)
                .send(DaemonRequest(command: .status), timeoutSeconds: 0.75),
              response.ok else {
            return nil
        }
        return response.status?.vm?.backend ?? response.status?.config.vmBackend
    }

    private static func printVMBackendStatus(_ status: ConjetVMBackendSelectionStatus, json: Bool) throws {
        if json {
            print(try ConjetJSON.string(status))
            return
        }
        print("Conjet VM backend")
        print("  selected: \(status.selected.rawValue) (\(status.selected.displayName))")
        if let active = status.active {
            print("  active: \(active.rawValue) (\(active.displayName))")
        } else {
            print("  active: not running")
        }
        print("  effective: \(status.effective.rawValue)")
        print("  lane: \(status.performanceLane)")
        print("  start supported: \(status.startSupported ? "yes" : "no")")
        print("  Apple VM Service expected: \(status.appleVirtualMachineServiceExpected ? "yes" : "no")")
        print("  x86_64 emulation: \(status.x86EmulationPolicy)")
        print("  note: \(status.message)")
    }

    private struct RustBootAttemptOutput: Codable {
        var vmmPath: String
        var vmmSource: String
        var manifestPath: String
        var commandLine: String
        var timeoutSeconds: Double
        var process: ProcessResult
        var report: RustHVFBootReport?
    }

    private struct RustHVFBootReport: Codable {
        var ok: Bool
        var message: String
        var exitCount: UInt64
        var consoleOutput: String
        var dockerReady: Bool
        var stages: [RustHVFBootStage]

        private enum CodingKeys: String, CodingKey {
            case ok
            case message
            case exitCount = "exit_count"
            case consoleOutput = "console_output"
            case dockerReady = "docker_ready"
            case stages
        }
    }

    private struct RustHVFBootStage: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    private static func conjetCoreRustBootAttempt(args: [String], paths: ConjetPaths) throws -> RustBootAttemptOutput {
        var bootArgs = Array(args.dropFirst())
        let earlyConsoleOnly = bootArgs.removeAllOccurrences("--early-console-only")
        let dryRun = bootArgs.removeAllOccurrences("--dry-run")
        let fullMemory = bootArgs.removeAllOccurrences("--full-memory")
        let requireDocker = bootArgs.removeAllOccurrences("--require-docker-ready")
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        let memoryMiB = try takeValueOption("--memory-mib", from: &bootArgs).map {
            try parsePositiveInt($0, flag: "--memory-mib")
        } ?? (fullMemory ? config.effectiveMemoryMiB : 512)
        let cpus = try takeValueOption("--cpus", from: &bootArgs).map {
            try parsePositiveInt($0, flag: "--cpus")
        } ?? 1
        let maxExits = try takeValueOption("--max-exits", from: &bootArgs).map {
            try parsePositiveInt($0, flag: "--max-exits")
        } ?? 16_384
        let timeoutSeconds = try takeValueOption("--timeout-seconds", from: &bootArgs).map {
            Double(try parsePositiveInt($0, flag: "--timeout-seconds"))
        } ?? 30
        if let unknown = bootArgs.first {
            throw ConjetError.invalidArgument("unknown rust boot option '\(unknown)'")
        }

        let store = VMImageStore(paths: paths)
        guard store.manifestExists() else {
            throw ConjetError.unavailable(
                "Conjet Core Rust boot attempt is not configured; import Conjet Core direct-kernel assets first."
            )
        }

        let tool = ConjetToolResolver.conjetCoreVMM()
        var commandArguments = [
            "boot",
            "--manifest", store.paths.vmManifest.path,
            "--memory-mib", "\(memoryMiB)",
            "--cpus", "\(cpus)",
            "--max-exits", "\(maxExits)",
            "--json"
        ]
        if earlyConsoleOnly {
            commandArguments.append("--early-console-only")
        }
        if dryRun {
            commandArguments.append("--dry-run")
        }
        if requireDocker {
            commandArguments += ["--require-docker-ready", "--docker-probe-timeout-ms", "\(Int(timeoutSeconds * 1_000))"]
        }
        let invocation = tool.invocation(
            arguments: commandArguments,
            displayName: "Conjet Core Rust bounded boot",
            timeoutSeconds: timeoutSeconds
        )
        let process = try ProcessRunner.run(
            invocation.executable,
            invocation.arguments,
            timeoutSeconds: timeoutSeconds
        )
        return RustBootAttemptOutput(
            vmmPath: tool.executable,
            vmmSource: tool.source,
            manifestPath: store.paths.vmManifest.path,
            commandLine: invocation.commandLine,
            timeoutSeconds: timeoutSeconds,
            process: process,
            report: parseRustBootReport(from: process.stdout)
        )
    }

    private static func parseRustBootReport(from stdout: String) -> RustHVFBootReport? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? ConjetJSON.decoder().decode(RustHVFBootReport.self, from: data)
    }

    private static func printConjetCoreRustBootAttemptOutput(_ output: RustBootAttemptOutput, json: Bool) throws {
        if json {
            print(try ConjetJSON.string(output))
            return
        }
        print("Conjet Core Rust boot attempt")
        print("  result: \(output.process.succeeded ? "completed" : "failed")")
        print("  vmm: \(output.vmmPath) (\(output.vmmSource))")
        print("  manifest: \(output.manifestPath)")
        print("  command: \(output.commandLine)")
        print("  exit code: \(output.process.exitCode)")
        if let report = output.report {
            print("  boot result: \(report.ok ? "ready" : "incomplete")")
            print("  docker: \(report.dockerReady ? "ready" : "not ready")")
            print("  exits: \(report.exitCount)")
            print("  console: \(report.consoleOutput.utf8.count) bytes")
            print("  note: \(report.message)")
        }
        if !output.process.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("  stderr:")
            for line in output.process.stderr.split(whereSeparator: \.isNewline).prefix(16) {
                print("    \(line)")
            }
        }
    }
}

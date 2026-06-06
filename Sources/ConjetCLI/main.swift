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
        if command == "help" {
            printHelp(for: args)
            return
        }
        if isHelpRequest(command: command, args: args) {
            printHelp(for: [command] + args.filter { !isHelpFlag($0) })
            return
        }

        if let profileName = commandProfile ?? globalProfile {
            try activateProfile(profileName)
        }

        switch command {
        case "doctor":
            try doctor(args: args, json: json)
        case "ssh":
            try ssh(args: args, json: json)
        case "ssh-key":
            try ssh(args: ["key"] + args, json: json)
        case "status":
            try status(json: json)
        case "start":
            try start(args: args, json: json)
        case "stop":
            try stop(args: args, json: json)
        case "restart":
            try restart(args: args, json: json)
        case "update":
            try update(args: args, json: json)
        case "shell":
            try shell(args: args)
        case "vm":
            try vm(args: args, json: json)
        case "run":
            try runContainer(args: args, json: json)
        case "compose":
            try compose(args: args)
        case "docker":
            try docker(args: args, json: json)
        case "sync":
            try sync(args: args, json: json)
        case "project":
            try project(args: args, json: json)
        case "power":
            try power(args: args, json: json)
        case "profile":
            try profile(args: args, json: json)
        case "port":
            try port(args: args, json: json)
        case "network":
            try network(args: args, json: json)
        case "-h", "--help":
            printHelp()
        default:
            throw ConjetError.invalidArgument("unknown command '\(command)'")
        }
    }

    private static func doctor(args: [String] = [], json: Bool) throws {
        if args.first == "clock" || args.contains("--clock") {
            let repair = args.contains("--repair")
            let output = try doctorClock(repair: repair)
            if json {
                print(try ConjetJSON.string(output))
            } else {
                print("Conjet clock doctor")
                print("  profile: \(ConjetPaths.default().profileName)")
                print("  host/guest delta: \(output.hostGuestClockDeltaMs) ms")
                print("  threshold: \(output.thresholdMs) ms")
                print("  status: \(output.supported ? "within threshold" : "out of threshold")")
                if output.repairAttempted {
                    print("  repair: \(output.repairSucceeded ? "succeeded" : "failed")")
                    if let latency = output.resyncLatencyMs {
                        print("  repair latency: \(latency) ms")
                    }
                }
                print("  note: \(output.message)")
            }
            return
        }
        if args.contains("--repair-network") {
            let response = try UnixSocketClient(socketPath: try socketPath(paths: ConjetPaths.default()))
                .send(DaemonRequest(command: .networkRepair), timeoutSeconds: 15)
            if json {
                print(try ConjetJSON.string(response))
            } else {
                print(response.message)
                if let network = response.status?.network {
                    printNetworkSummary(network, indent: "  ")
                }
            }
            return
        }
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

    private static func doctorClock(repair: Bool) throws -> ClockDoctorOutput {
        let thresholdMs = 100
        var probe = try probeGuestClock()
        var repairSucceeded = false
        var repairLatencyMs: Int?
        if abs(probe.deltaMs) > thresholdMs, repair {
            let startedAt = Date()
            repairSucceeded = try repairGuestClock()
            repairLatencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            probe = try probeGuestClock()
        }
        let supported = abs(probe.deltaMs) <= thresholdMs
        let message: String
        if supported {
            message = "guest clock is within the supported drift threshold"
        } else if repair {
            message = "guest clock remains outside the supported drift threshold after repair"
        } else {
            message = "run 'conjet doctor clock --repair' to resync the guest clock"
        }
        return ClockDoctorOutput(
            hostEpochMs: probe.hostEpochMs,
            guestEpochMs: probe.guestEpochMs,
            hostGuestClockDeltaMs: probe.deltaMs,
            thresholdMs: thresholdMs,
            supported: supported,
            repairAttempted: repair,
            repairSucceeded: repairSucceeded,
            resyncLatencyMs: repairLatencyMs,
            message: message
        )
    }

    private static func probeGuestClock() throws -> ClockProbe {
        let hostEpochMs = Int(Date().timeIntervalSince1970 * 1000)
        let result = try runGuestRootShell("date +%s%3N")
        guard result.succeeded else {
            throw ConjetError.processFailed(executable: "guest date", exitCode: result.exitCode, stderr: result.stderr)
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guestEpochMs = Int(text) else {
            throw ConjetError.decoding("guest date returned unexpected value '\(text)'")
        }
        return ClockProbe(hostEpochMs: hostEpochMs, guestEpochMs: guestEpochMs, deltaMs: guestEpochMs - hostEpochMs)
    }

    private static func repairGuestClock() throws -> Bool {
        if let response = try? UnixSocketClient(socketPath: try socketPath(paths: ConjetPaths.default())).send(
            DaemonRequest(command: .clockRepair, parameters: ["reason": "doctor"]),
            timeoutSeconds: 45
        ), response.ok {
            return true
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
        let result = try runGuestRootShell(script)
        return result.succeeded
    }

    private static func ssh(args: [String] = [], json: Bool) throws {
        var remaining = args
        let subcommand = remaining.first ?? "connect"
        if !remaining.isEmpty {
            remaining.removeFirst()
        }
        switch subcommand {
        case "status":
            let output = try sshStatus(checkGuest: true)
            if json {
                print(try ConjetJSON.string(output))
            } else {
                printSSHStatus(output)
            }
        case "key", "ssh-key":
            let keySubcommand = remaining.first ?? "status"
            switch keySubcommand {
            case "rotate":
                try rotateSSHKey()
                let output = try sshStatus(checkGuest: true)
                if json {
                    print(try ConjetJSON.string(output))
                } else {
                    print("Conjet SSH key rotated")
                    printSSHStatus(output)
                }
            case "status":
                let output = try sshStatus(checkGuest: false)
                if json {
                    print(try ConjetJSON.string(output))
                } else {
                    printSSHStatus(output)
                }
            default:
                throw ConjetError.invalidArgument("unknown ssh key command '\(keySubcommand)'")
            }
        case "enable":
            try updateSSHEnabled(true)
            let output = try sshStatus(checkGuest: false)
            if json {
                print(try ConjetJSON.string(output))
            } else {
                print("Conjet SSH enabled")
                printSSHStatus(output)
            }
        case "disable":
            try updateSSHEnabled(false)
            let output = try sshStatus(checkGuest: false)
            if json {
                print(try ConjetJSON.string(output))
            } else {
                print("Conjet SSH disabled")
                printSSHStatus(output)
            }
        case "connect":
            guard try ConjetConfig.loadOrCreate().ssh.enabled else {
                throw ConjetError.unavailable("Conjet SSH is disabled for this profile")
            }
            try ensureSSHKeyInstalled()
            let endpoint = sshEndpoint(config: try ConjetConfig.loadOrCreate())
            if endpoint.transport == .tcp,
               !localTCPConnectable(host: endpoint.host, port: endpoint.port, timeoutSeconds: 1.0) {
                throw ConjetError.unavailable("Conjet SSH key and guest sshd are configured, but localhost SSH endpoint \(endpoint.host):\(endpoint.port) is not reachable")
            }
            try runInheritedProcess("/usr/bin/ssh", sshArguments(endpoint: endpoint) + remaining)
        default:
            guard try ConjetConfig.loadOrCreate().ssh.enabled else {
                throw ConjetError.unavailable("Conjet SSH is disabled for this profile")
            }
            try ensureSSHKeyInstalled()
            let endpoint = sshEndpoint(config: try ConjetConfig.loadOrCreate())
            if endpoint.transport == .tcp,
               !localTCPConnectable(host: endpoint.host, port: endpoint.port, timeoutSeconds: 1.0) {
                throw ConjetError.unavailable("Conjet SSH key and guest sshd are configured, but localhost SSH endpoint \(endpoint.host):\(endpoint.port) is not reachable")
            }
            try runInheritedProcess("/usr/bin/ssh", sshArguments(endpoint: endpoint) + [subcommand] + remaining)
        }
    }

    private static func printSSHStatus(_ output: SSHStatusOutput) {
        print("Conjet SSH")
        print("  profile: \(output.profile)")
        print("  enabled: \(output.enabled ? "yes" : "no")")
        print("  key: \(output.keyExists ? output.keyPath : "missing")")
        print("  guest configured: \(output.guestConfigured ? "yes" : "no")")
        print("  sshd running: \(output.sshdRunning ? "yes" : "no")")
        print("  localhost-only: \(output.localhostOnly ? "yes" : "no")")
        print("  endpoint: \(output.endpoint ?? "not reachable")")
        print("  note: \(output.message)")
    }

    private static func sshStatus(checkGuest: Bool) throws -> SSHStatusOutput {
        let paths = ConjetPaths.default()
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        let keyPath = sshPrivateKeyURL(paths: paths)
        let publicKeyPath = sshPublicKeyURL(paths: paths)
        let keyExists = FileManager.default.fileExists(atPath: keyPath.path)
            && FileManager.default.fileExists(atPath: publicKeyPath.path)
        var guestConfigured = false
        var sshdRunning = false
        if config.ssh.enabled, checkGuest, FileManager.default.fileExists(atPath: paths.dockerSocket.path) {
            if keyExists {
                try? installSSHAuthorizedKey(publicKeyPath: publicKeyPath)
            }
            let result = try? runGuestRootShell("""
            test -f /home/conjet/.ssh/authorized_keys && echo key=yes || echo key=no
            (systemctl is-active --quiet ssh || systemctl is-active --quiet sshd || pgrep -x sshd >/dev/null 2>&1 || service sshd status >/dev/null 2>&1) && echo sshd=yes || echo sshd=no
            """)
            if let result, result.succeeded {
                guestConfigured = result.stdout.contains("key=yes")
                sshdRunning = result.stdout.contains("sshd=yes")
            }
        }
        let endpoint = sshEndpoint(config: config)
        let reachable = endpoint.transport == .proxyCommand
            ? config.ssh.enabled && keyExists && guestConfigured && sshdRunning
            : localTCPConnectable(host: endpoint.host, port: endpoint.port, timeoutSeconds: 0.3)
        let message: String
        if !config.ssh.enabled {
            message = "profile SSH is disabled"
        } else if reachable {
            message = endpoint.transport == .proxyCommand
                ? "local ProxyCommand SSH transport is available"
                : "localhost SSH endpoint is reachable"
        } else if keyExists && guestConfigured && sshdRunning {
            message = "guest SSH is ready; localhost endpoint bridge is not reachable"
        } else if keyExists {
            message = "host key exists; run 'conjet ssh key rotate' or 'conjet ssh' to install it in the guest"
        } else {
            message = "profile-scoped SSH key has not been created"
        }
        return SSHStatusOutput(
            profile: paths.profileName,
            enabled: config.ssh.enabled,
            keyPath: keyPath.path,
            publicKeyPath: publicKeyPath.path,
            keyExists: keyExists,
            guestConfigured: guestConfigured,
            sshdRunning: sshdRunning,
            localhostOnly: true,
            endpoint: reachable ? endpoint.description : nil,
            message: message
        )
    }

    private static func updateSSHEnabled(_ enabled: Bool) throws {
        let paths = ConjetPaths.default()
        var config = try ConjetConfig.loadOrCreate(paths: paths)
        config.ssh.enabled = enabled
        try config.save(paths: paths)
    }

    private static func rotateSSHKey() throws {
        let paths = ConjetPaths.default()
        let keyPath = sshPrivateKeyURL(paths: paths)
        let publicKeyPath = sshPublicKeyURL(paths: paths)
        try FileManager.default.createDirectory(at: keyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: keyPath.path) {
            try FileManager.default.removeItem(at: keyPath)
        }
        if FileManager.default.fileExists(atPath: publicKeyPath.path) {
            try FileManager.default.removeItem(at: publicKeyPath)
        }
        let result = try ProcessRunner.run("/usr/bin/ssh-keygen", [
            "-q",
            "-t", "ed25519",
            "-N", "",
            "-C", "conjet-\(paths.profileName)",
            "-f", keyPath.path
        ], timeoutSeconds: 15)
        guard result.succeeded else {
            throw ConjetError.processFailed(executable: "ssh-keygen", exitCode: result.exitCode, stderr: result.stderr)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyPath.path)
        try installSSHAuthorizedKey(publicKeyPath: publicKeyPath)
    }

    private static func ensureSSHKeyInstalled() throws {
        let paths = ConjetPaths.default()
        let keyPath = sshPrivateKeyURL(paths: paths)
        let publicKeyPath = sshPublicKeyURL(paths: paths)
        if !FileManager.default.fileExists(atPath: keyPath.path)
            || !FileManager.default.fileExists(atPath: publicKeyPath.path) {
            try rotateSSHKey()
            return
        }
        try installSSHAuthorizedKey(publicKeyPath: publicKeyPath)
    }

    private static func installSSHAuthorizedKey(publicKeyPath: URL) throws {
        let publicKey = try String(contentsOf: publicKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard publicKey.hasPrefix("ssh-ed25519 ") else {
            throw ConjetError.decoding("Conjet SSH public key is not an ed25519 key")
        }
        let script = """
        set -eu
        if ! command -v sshd >/dev/null 2>&1; then
          if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y openssh-server
          elif command -v dnf >/dev/null 2>&1; then
            dnf install -y openssh-server
          elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache openssh-server
          else
            echo "unsupported package manager for openssh-server" >&2
            exit 1
          fi
        fi
        if ! id conjet >/dev/null 2>&1; then useradd -m -s /bin/sh conjet 2>/dev/null || adduser -D -s /bin/sh conjet; fi
        passwd -l conjet >/dev/null 2>&1 || true
        mkdir -p /home/conjet/.ssh /run/sshd /etc/ssh/sshd_config.d
        printf '%s\\n' \(shellSingleQuote(publicKey)) >/home/conjet/.ssh/authorized_keys
        chown -R conjet:conjet /home/conjet/.ssh 2>/dev/null || chown -R conjet /home/conjet/.ssh
        chmod 700 /home/conjet/.ssh
        chmod 600 /home/conjet/.ssh/authorized_keys
        cat >/etc/ssh/sshd_config.d/99-conjet-managed.conf <<'SSH'
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin no
        PubkeyAuthentication yes
        X11Forwarding no
        AllowTcpForwarding no
        GatewayPorts no
        AllowUsers conjet
        SSH
        ssh-keygen -A
        /usr/sbin/sshd -t -e
        if command -v systemctl >/dev/null 2>&1; then
          systemctl daemon-reload >/dev/null 2>&1 || true
          systemctl enable --now ssh.socket >/dev/null 2>&1 || true
          systemctl restart ssh >/dev/null 2>&1 || systemctl restart ssh.service >/dev/null 2>&1 || systemctl start ssh >/dev/null 2>&1 || systemctl start ssh.service >/dev/null 2>&1 || true
        fi
        if ! (systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null || pgrep -x sshd >/dev/null 2>&1 || service sshd status >/dev/null 2>&1); then
          service sshd restart >/dev/null 2>&1 || service ssh restart >/dev/null 2>&1 || /usr/sbin/sshd
        fi
        systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null || pgrep -x sshd >/dev/null 2>&1 || service sshd status >/dev/null 2>&1 || service ssh status >/dev/null 2>&1
        """
        let result = try runGuestRootShell(script)
        guard result.succeeded else {
            throw ConjetError.processFailed(executable: "guest ssh setup", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private static func sshPrivateKeyURL(paths: ConjetPaths) -> URL {
        paths.home.appendingPathComponent("ssh", isDirectory: true).appendingPathComponent("id_ed25519")
    }

    private static func sshPublicKeyURL(paths: ConjetPaths) -> URL {
        URL(fileURLWithPath: sshPrivateKeyURL(paths: paths).path + ".pub")
    }

    private static func sshEndpoint(config: ConjetConfig) -> SSHEndpoint {
        if (ProcessInfo.processInfo.environment["CONJET_SSH_TRANSPORT"] ?? config.ssh.transport) == "tcp" {
            let host = ProcessInfo.processInfo.environment["CONJET_SSH_HOST"] ?? "127.0.0.1"
            let port = ProcessInfo.processInfo.environment["CONJET_SSH_PORT"].flatMap(Int.init) ?? 2222
            return SSHEndpoint(transport: .tcp, host: host, port: port)
        }
        return SSHEndpoint(transport: .proxyCommand, host: "conjet", port: 0)
    }

    private static func sshProxyCommand(paths: ConjetPaths) -> String {
        [
            "/usr/bin/env",
            "docker",
            "--host", shellSingleQuote("unix://\(paths.dockerSocket.path)"),
            "run",
            "--rm",
            "-i",
            "--privileged",
            "--pid=host",
            "--net=host",
            "--ipc=host",
            "--uts=host",
            "ubuntu:24.04",
            "nsenter",
            "-t", "1",
            "-m",
            "-u",
            "-i",
            "-n",
            "-p",
            "--",
            "/usr/sbin/sshd",
            "-i",
            "-e"
        ].joined(separator: " ")
    }

    private static func sshArguments(endpoint: SSHEndpoint) -> [String] {
        let paths = ConjetPaths.default()
        var arguments = [
            "-i", sshPrivateKeyURL(paths: paths).path,
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(paths.home.appendingPathComponent("ssh", isDirectory: true).appendingPathComponent("known_hosts").path)"
        ]
        switch endpoint.transport {
        case .proxyCommand:
            arguments += [
                "-o", "ProxyCommand=\(sshProxyCommand(paths: paths))",
                "conjet@conjet"
            ]
        case .tcp:
            arguments += [
                "-p", String(endpoint.port),
                "conjet@\(endpoint.host)"
            ]
        }
        return arguments
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
                if let network = status.network {
                    printNetworkSummary(network, indent: "  ")
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

    private static func port(args: [String], json: Bool) throws {
        let subcommand = args.first ?? "list"
        switch subcommand {
        case "list":
            let response = try UnixSocketClient(socketPath: try socketPath(paths: ConjetPaths.default()))
                .send(DaemonRequest(command: .status), timeoutSeconds: 10)
            guard let network = response.status?.network else {
                throw ConjetError.unavailable("network status is unavailable")
            }
            if json {
                print(try ConjetJSON.string(network.forwards))
            } else {
                printPortList(network.forwards, verbose: args.contains("--verbose"))
            }
        case "diagnose":
            guard args.count >= 2 else {
                throw ConjetError.invalidArgument("usage: conjet port diagnose PORT[/tcp|/udp]")
            }
            let query = try parsePortQuery(args[1])
            let response = try UnixSocketClient(socketPath: try socketPath(paths: ConjetPaths.default()))
                .send(DaemonRequest(command: .status), timeoutSeconds: 10)
            guard let network = response.status?.network else {
                throw ConjetError.unavailable("network status is unavailable")
            }
            let matches = network.forwards.filter {
                $0.hostPort == query.port && (query.protocol == nil || $0.protocol == query.protocol)
            }
            let diagnosis = portDiagnosis(query: query, network: network, matches: matches)
            if json {
                print(try ConjetJSON.string(diagnosis))
            } else {
                printPortDiagnosis(diagnosis)
            }
        default:
            throw ConjetError.invalidArgument("unknown port command '\(subcommand)'")
        }
    }

    private static func network(args: [String], json: Bool) throws {
        let subcommand = args.first ?? "status"
        switch subcommand {
        case "status":
            let response = try UnixSocketClient(socketPath: try socketPath(paths: ConjetPaths.default()))
                .send(DaemonRequest(command: .status), timeoutSeconds: 10)
            guard let network = response.status?.network else {
                throw ConjetError.unavailable("network status is unavailable")
            }
            if json {
                print(try ConjetJSON.string(network))
            } else {
                printNetworkSummary(network, indent: "")
                if !network.messages.isEmpty {
                    print("Messages:")
                    for message in network.messages.suffix(10) {
                        print("  - \(message)")
                    }
                }
            }
        case "repair":
            let response = try UnixSocketClient(socketPath: try socketPath(paths: ConjetPaths.default()))
                .send(DaemonRequest(command: .networkRepair), timeoutSeconds: 20)
            if json {
                print(try ConjetJSON.string(response))
            } else {
                print(response.message)
                if let network = response.status?.network {
                    printNetworkSummary(network, indent: "  ")
                }
            }
        case "bridge-test":
            let output = try networkBridgeTest()
            if json {
                print(try ConjetJSON.string(output))
            } else {
                print("Conjet network bridge test")
                print("  requested bridge: \(output.requestedBridgeEngine)")
                print("  active bridge: \(output.activeBridgeEngine)")
                print("  guest echo: \(output.guestEcho)")
                print("  guest metrics: \(output.guestMetrics)")
                print("  binary frames: \(output.binaryFrames)")
                print("  udp binary frames: \(output.udpBinaryFrames)")
                print("  persistent vsock: \(output.persistentVsock)")
                print("  tcp mode: \(output.tcpMode)")
                print("  udp mode: \(output.udpMode)")
                print("  tcp binary frames: \(output.tcpBinaryFrames)")
                print("  persistent TCP vsock: \(output.persistentTCPVsock)")
                print("  TCP vsock pool: \(output.tcpVsockPool)")
                print("  python fallback active: \(output.pythonFallbackActive)")
                print("  docker API passthrough: \(output.dockerApiPassthrough)")
                print("  tcp guest echo: \(output.tcpGuestEcho)")
                print("  binary ping: \(output.binaryPing)")
                print("  udp binary echo: \(output.udpBinaryEcho)")
                if let fallbackReason = output.fallbackReason {
                    print("  fallback: \(fallbackReason)")
                }
                if !output.errors.isEmpty {
                    print("  errors:")
                    for error in output.errors {
                        print("    - \(error)")
                    }
                }
            }
        case "bridge-switch":
            try networkBridgeSwitch(args: Array(args.dropFirst()), json: json)
        case "policy":
            try networkPolicy(args: Array(args.dropFirst()), json: json)
        case "enable-turbo":
            throw ConjetError.unavailable("ConjetNet turbo mode is experimental and not available in this build")
        default:
            throw ConjetError.invalidArgument("unknown network command '\(subcommand)'")
        }
    }

    private static func networkBridgeSwitch(args: [String], json: Bool) throws {
        guard let rawEngine = args.first else {
            throw ConjetError.invalidArgument("usage: conjet network bridge-switch python-legacy|conjet-netd-c [--restart]")
        }
        let engine = try parseNetworkBridgeEngine(rawEngine)
        guard engine != .auto else {
            throw ConjetError.invalidArgument("bridge-switch requires python-legacy or conjet-netd-c")
        }
        let restart = args.contains("--restart")
        let paths = ConjetPaths.default()
        var config = try ConjetConfig.loadOrCreate(paths: paths)
        config.networkBridgeEngine = engine
        try config.save(paths: paths)
        try writeBridgeSelectorToBootstrap(paths: paths, engine: engine)

        if !FileManager.default.fileExists(atPath: paths.dockerSocket.path) {
            try start(args: ["--bridge-engine", engine.rawValue], json: false)
        }

        let script = "mkdir -p /etc/conjet && printf '%s\\n' \(shellSingleQuote(engine.rawValue)) > /etc/conjet/network-bridge-engine && cat /etc/conjet/network-bridge-engine"
        let write = try runGuestRootShell(script)
        guard write.succeeded else {
            throw ConjetError.unavailable("failed to write guest bridge selector: \(write.stderr)")
        }

        if restart {
            try stop(args: ["--timeout", "10"], json: false)
            try start(args: ["--bridge-engine", engine.rawValue], json: false)
        }

        let output = try networkBridgeTest()
        if json {
            print(try ConjetJSON.string(output))
        } else {
            print("Conjet network bridge switched")
            print("  requested bridge: \(output.requestedBridgeEngine)")
            print("  active bridge: \(output.activeBridgeEngine)")
            print("  restart: \(restart)")
            if output.activeBridgeEngine != engine.rawValue {
                print("  warning: active bridge does not match requested bridge")
            }
        }
    }

    private static func networkPolicy(args: [String], json: Bool) throws {
        let paths = ConjetPaths.default()
        var config = try ConjetConfig.loadOrCreate(paths: paths)
        guard args.first == "set" else {
            if json {
                print(try ConjetJSON.string(config))
            } else {
                print("Network policy")
                print("  bind policy: \(config.networkBindPolicy.rawValue)")
                print("  proxy engine: \(config.networkProxyEngine.rawValue)")
                if !config.networkLANAllowedCIDRs.isEmpty {
                    print("  LAN CIDRs: \(config.networkLANAllowedCIDRs.joined(separator: ", "))")
                }
                if !config.networkLANAllowedPorts.isEmpty {
                    print("  LAN ports: \(config.networkLANAllowedPorts.map(String.init).joined(separator: ", "))")
                }
            }
            return
        }

        guard args.count >= 2 else {
            throw ConjetError.invalidArgument("usage: conjet network policy set secure-local|docker-strict|lan-allowlist [--allow-cidr CIDR] [--allow-port PORT]")
        }
        config.networkBindPolicy = try parseNetworkBindPolicy(args[1])
        var remaining = Array(args.dropFirst(2))
        while !remaining.isEmpty {
            let flag = remaining.removeFirst()
            switch flag {
            case "--allow-cidr":
                config.networkLANAllowedCIDRs.append(try consumeValue(flag, from: &remaining))
            case "--allow-port":
                config.networkLANAllowedPorts.append(try parsePortNumber(consumeValue(flag, from: &remaining), flag: flag))
            case "--clear-allowlist":
                config.networkLANAllowedCIDRs.removeAll()
                config.networkLANAllowedPorts.removeAll()
            default:
                throw ConjetError.invalidArgument("unknown network policy option '\(flag)'")
            }
        }
        try config.save(paths: paths)
        if json {
            print(try ConjetJSON.string(config))
        } else {
            print("network policy saved: \(config.networkBindPolicy.rawValue)")
            print("  restart Conjet for running listeners to adopt the new policy")
        }
    }

    private static func networkBridgeTest() throws -> BridgeTestOutput {
        let paths = ConjetPaths.default()
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        let response = try UnixSocketClient(socketPath: try socketPath(paths: paths))
            .send(DaemonRequest(command: .status), timeoutSeconds: 10)
        let network = response.status?.network
        let socket = try ensureConjetDockerSocket()

        var errors: [String] = []
        let dockerApiPassthrough = bridgeHTTPCheck(
            socketPath: socket,
            path: "/_ping",
            expectedBodySubstring: "OK",
            errors: &errors,
            label: "Docker API passthrough"
        )
        let tcpGuestEcho = bridgeHTTPCheck(
            socketPath: socket,
            path: "/conjet-guest-echo",
            expectedBodySubstring: "conjet-guest-echo",
            errors: &errors,
            label: "guest echo"
        )
        let metricsHTTP = bridgeHTTPCheck(
            socketPath: socket,
            path: "/conjet-bridge-metrics",
            expectedBodySubstring: "bridge_engine",
            errors: &errors,
            label: "guest metrics"
        )
        let binaryPing = bridgeBinaryPing(socketPath: socket, errors: &errors)
        let udpBinaryEcho = bridgeUDPBinaryEcho(socketPath: socket, errors: &errors)

        return BridgeTestOutput(
            requestedBridgeEngine: network?.requestedBridgeEngine ?? config.networkBridgeEngine.rawValue,
            activeBridgeEngine: network?.bridgeEngine ?? network?.capabilities.bridgeEngine ?? "unknown",
            fallbackReason: network?.fallbackReason,
            guestEcho: network?.capabilities.guestEcho ?? tcpGuestEcho,
            guestMetrics: network?.capabilities.guestMetrics ?? metricsHTTP,
            binaryFrames: network?.capabilities.binaryFrames ?? binaryPing,
            udpBinaryFrames: network?.capabilities.udpBinaryFrames ?? udpBinaryEcho,
            persistentVsock: network?.capabilities.persistentVsock ?? false,
            tcpMode: network?.tcpMode ?? "legacy-tcp-proxy",
            udpMode: network?.udpMode ?? "legacy-udp-proxy",
            tcpBinaryFrames: network?.capabilities.tcpBinaryFrames ?? false,
            persistentTCPVsock: network?.capabilities.persistentTCPVsock ?? false,
            tcpVsockPool: network?.capabilities.tcpVsockPool ?? false,
            pythonFallbackActive: network?.pythonFallbackActive ?? false,
            dockerApiPassthrough: dockerApiPassthrough,
            tcpGuestEcho: tcpGuestEcho,
            binaryPing: binaryPing,
            udpBinaryEcho: udpBinaryEcho,
            errors: errors
        )
    }

    private static func start(args: [String] = [], json: Bool = false) throws {
        let response = try startRuntime(args: args, json: json)
        if json {
            print(try ConjetJSON.string(response))
        }
    }

    @discardableResult
    private static func startRuntime(args: [String] = [], json: Bool = false) throws -> DaemonResponse {
        let paths = ConjetPaths.default()
        let config = try updateProfileConfigFromStartArgs(args, paths: paths, json: json)
        try ensureVMConfiguredForStart(json: json, config: config)
        let socketPath = try startDaemonOnly(printStatus: !json)
        return try startVMIfConfigured(socketPath: socketPath, config: config, json: json)
    }

    private static func updateProfileConfigFromStartArgs(_ args: [String], paths: ConjetPaths, json: Bool) throws -> ConjetConfig {
        var config = try ConjetConfig.loadOrCreate(paths: paths)
        if let envProxyEngine = ProcessInfo.processInfo.environment["CONJET_NET_PROXY_ENGINE"],
           !envProxyEngine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.networkProxyEngine = try parseNetworkProxyEngine(envProxyEngine)
        }
        if let envBridgeEngine = ProcessInfo.processInfo.environment["CONJET_NET_BRIDGE_ENGINE"],
           !envBridgeEngine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.networkBridgeEngine = try parseNetworkBridgeEngine(envBridgeEngine)
        }
        if let envEnergyMode = ProcessInfo.processInfo.environment["CONJET_ENERGY_MODE"],
           !envEnergyMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.energyMode = try parseEnergyMode(envEnergyMode)
        }
        if let envMemoryProfile = ProcessInfo.processInfo.environment["CONJET_MEMORY_PROFILE"],
           !envMemoryProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.memoryProfile = try parseMemoryProfile(envMemoryProfile)
        }
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
            case "--network-bind-policy":
                config.networkBindPolicy = try parseNetworkBindPolicy(consumeValue(flag, from: &remaining))
            case "--proxy-engine", "--network-proxy-engine":
                config.networkProxyEngine = try parseNetworkProxyEngine(consumeValue(flag, from: &remaining))
            case "--bridge-engine", "--network-bridge-engine":
                config.networkBridgeEngine = try parseNetworkBridgeEngine(consumeValue(flag, from: &remaining))
            case "--energy-mode":
                config.energyMode = try parseEnergyMode(consumeValue(flag, from: &remaining))
            case "--memory-profile":
                config.memoryProfile = try parseMemoryProfile(consumeValue(flag, from: &remaining))
                if config.memoryProfile == .eco,
                   !args.contains("--memory"),
                   config.memoryMiB == ConjetConfig.default.memoryMiB {
                    config.memoryMiB = config.memoryPolicy.recommendedMemoryMiB
                }
            case "--allow-cidr":
                config.networkLANAllowedCIDRs.append(try consumeValue(flag, from: &remaining))
            case "--allow-port":
                config.networkLANAllowedPorts.append(try parsePortNumber(consumeValue(flag, from: &remaining), flag: flag))
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
        var stopArgs = args
        let timeout = try stopTimeout(from: takeValueOption("--timeout", from: &stopArgs))
        if let unknown = stopArgs.first {
            throw ConjetError.invalidArgument("unknown stop option '\(unknown)'")
        }
        guard let response = try stopRuntime(timeout: timeout, requireRunning: true) else {
            throw ConjetError.unavailable("conjetd is not running")
        }
        if json {
            print(try ConjetJSON.string(response))
        } else {
            print(response.message)
        }
    }

    private static func stopRuntime(timeout: Double, requireRunning: Bool) throws -> DaemonResponse? {
        let paths = ConjetPaths.default()
        let currentSocketPath = try socketPath(paths: paths)
        guard daemonIsRunning(socketPath: currentSocketPath) else {
            if requireRunning {
                throw ConjetError.unavailable("conjetd is not running at \(currentSocketPath)")
            }
            return nil
        }

        let response = try UnixSocketClient(socketPath: currentSocketPath).send(
            DaemonRequest(command: .stop, parameters: ["timeout_seconds": String(timeout)]),
            timeoutSeconds: max(timeout, 1) + 1
        )
        waitForDaemonStop(socketPath: currentSocketPath, timeoutSeconds: max(timeout, 5))
        return response
    }

    private static func pruneRuntimeCacheIfRunning() throws -> DaemonResponse? {
        let paths = ConjetPaths.default()
        let currentSocketPath = try socketPath(paths: paths)
        guard daemonIsRunning(socketPath: currentSocketPath) else {
            return nil
        }
        let response = try UnixSocketClient(socketPath: currentSocketPath).send(
            DaemonRequest(command: .pruneCache),
            timeoutSeconds: 10
        )
        if DaemonCompatibility.isUnsupportedCommandResponse(response, command: .pruneCache) {
            return nil
        }
        return response
    }

    private static func daemonIsRunning(socketPath: String) -> Bool {
        (try? UnixSocketClient(socketPath: socketPath).send(DaemonRequest(command: .ping), timeoutSeconds: 1).ok) == true
    }

    private static func stopTimeout(from value: String?) throws -> Double {
        let text = value ?? ProcessInfo.processInfo.environment["CONJET_STOP_TIMEOUT_SECONDS"]
        guard let text else { return 25 }
        guard let timeout = Double(text), timeout > 0 else {
            throw ConjetError.invalidArgument("--timeout must be a positive number of seconds")
        }
        return timeout
    }

    private static func restart(args: [String] = [], json: Bool = false) throws {
        var startArgs = args
        let timeout = try stopTimeout(from: takeValueOption("--timeout", from: &startArgs))
        let pruned = try pruneRuntimeCacheIfRunning()
        let stopped = try stopRuntime(timeout: timeout, requireRunning: false)
        if !json {
            if let pruned {
                print(pruned.message)
            }
            if let stopped {
                print(stopped.message)
            } else {
                print("conjetd is not running; starting")
            }
        }
        let started = try startRuntime(args: startArgs, json: json)
        if json {
            print(try ConjetJSON.string(ConjetRestartResult(pruned: pruned, stopped: stopped, started: started)))
        }
    }

    private static func update(args: [String] = [], json: Bool = false) throws {
        var updateArgs = args
        let force = updateArgs.removeAllOccurrences("--force")
        let restartRequested = updateArgs.removeAllOccurrences("--restart")
        let noRestart = updateArgs.removeAllOccurrences("--no-restart")
        if restartRequested && noRestart {
            throw ConjetError.invalidArgument("use either --restart or --no-restart, not both")
        }
        let timeout = try stopTimeout(from: takeValueOption("--timeout", from: &updateArgs))
        try validateUpdateArgs(updateArgs)

        let paths = ConjetPaths.default()
        let config = try ConjetConfig.loadOrCreate(paths: paths)
        let currentSocketPath = try socketPath(paths: paths)
        let wasRunning = daemonIsRunning(socketPath: currentSocketPath)
        let stopped = try stopRuntime(timeout: timeout, requireRunning: false)
        if !json, wasRunning, let stopped {
            print(stopped.message)
        }

        let artifact = try conjetCoreArtifactPath(
            args: updateArgs,
            force: force,
            printStatus: !json
        )

        let ui = ConjetFetchUI(enabled: !json)
        ui.step("[conjet-core 4/4] importing img")
        let manifest = try VMImageStore(paths: paths).importEFIBootDisk(
            sourcePath: artifact,
            name: "conjet-core",
            force: true,
            cloudInitSeedPath: nil,
            bootDiskMinimumSizeBytes: bootDiskMinimumSizeBytes(args: updateArgs, defaultGiB: nil),
            dataDiskSizeBytes: gibibytes(config.diskGiB)
        )
        if !json {
            try printVMManifest(
                manifest,
                json: false,
                headline: "=> [conjet-core 4/4] VM assets updated: \(manifest.name)"
            )
        }

        let shouldRestart = restartRequested || (wasRunning && !noRestart)
        let started = shouldRestart ? try startRuntime(args: [], json: json) : nil
        if !json, !shouldRestart {
            print("Conjet Core image updated; run 'conjet start' to boot it.")
        }
        if json {
            print(try ConjetJSON.string(ConjetUpdateResult(
                artifactPath: artifact,
                previousDaemonRunning: wasRunning,
                stopped: stopped,
                manifest: manifest,
                restarted: shouldRestart,
                started: started
            )))
        }
    }

    private static func validateUpdateArgs(_ args: [String]) throws {
        var remaining = args
        while !remaining.isEmpty {
            let element = remaining.removeFirst()
            switch element {
            case "--image", "--url", "--repository", "--boot-disk-gb":
                _ = try consumeValue(element, from: &remaining)
            default:
                throw ConjetError.invalidArgument("unknown update option '\(element)'")
            }
        }
    }

    private static func startVMIfConfigured(socketPath: String, config: ConjetConfig, json: Bool) throws -> DaemonResponse {
        let store = VMImageStore()
        guard store.manifestExists() else {
            if !json {
                ConjetFetchUI(enabled: true).step("[vm 2/2] not configured; no Conjet-core image imported")
            }
            return DaemonResponse(ok: false, message: "VM is not configured", vm: store.status())
        }
        try writeBridgeSelectorToBootstrap(paths: ConjetPaths.default(), engine: config.networkBridgeEngine)
        let renderer = json ? nil : VMStartLiveRenderer(serialLogPath: store.status().serialLogPath)
        renderer?.start()
        let response: DaemonResponse
        do {
            response = try vmStartResponseWithDebugSigningRepair(socketPath: socketPath, json: json)
        } catch {
            renderer?.stop(finalLine: "\(JetTerminal.symbolError) [vm 2/2] failed: \(error)")
            throw error
        }
        renderer?.setState(vmStartHeadline(response))
        let dockerContext = configureDockerContextIfStarted(response, json: json)
        if dockerContext != nil {
            renderer?.setState("\(JetTerminal.symbolStep) [docker context internal] configured")
        }
        let hostShares = mountHostSharesIfStarted(response, dockerContext: dockerContext, config: config, json: json)
        if hostShares != nil {
            renderer?.setState("\(JetTerminal.symbolStep) [host shares internal] mounted")
        }
        if !json {
            renderer?.stop(finalLine: vmStartHeadline(response))
            printStartVMResponseDetails(response, dockerContext: dockerContext, hostShares: hostShares)
        }
        if !response.ok {
            try throwResponseError(response.message)
        }
        return response
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
            let renderer = json ? nil : VMStartLiveRenderer(serialLogPath: VMImageStore().status().serialLogPath)
            renderer?.start()
            let response: DaemonResponse
            do {
                response = try vmStartResponseWithDebugSigningRepair(socketPath: socketPath, json: json)
            } catch {
                renderer?.stop(finalLine: "\(JetTerminal.symbolError) [vm 2/2] failed: \(error)")
                throw error
            }
            renderer?.setState(vmStartHeadline(response))
            let dockerContext = configureDockerContextIfStarted(response, json: json)
            if dockerContext != nil {
                renderer?.setState("\(JetTerminal.symbolStep) [docker context internal] configured")
            }
            let hostShares = mountHostSharesIfStarted(response, dockerContext: dockerContext, config: config, json: json)
            if hostShares != nil {
                renderer?.setState("\(JetTerminal.symbolStep) [host shares internal] mounted")
            }
            if json {
                try printDaemonResponse(
                    response,
                    json: json,
                    failOnError: true,
                    dockerContext: dockerContext,
                    hostShares: hostShares,
                    headline: vmStartHeadline(response)
                )
            } else {
                renderer?.stop(finalLine: vmStartHeadline(response))
                printStartVMResponseDetails(response, dockerContext: dockerContext, hostShares: hostShares)
                if !response.ok {
                    try throwResponseError(response.message)
                }
            }
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

    private static func docker(args: [String], json: Bool) throws {
        let subcommand = args.first ?? "repair"
        switch subcommand {
        case "repair":
            var repairArgs = Array(args.dropFirst())
            let dryRun = repairArgs.removeAllOccurrences("--dry-run")
            let apply = repairArgs.removeAllOccurrences("--apply")
            let restartAfterRepair = repairArgs.removeAllOccurrences("--restart")
            if dryRun && apply {
                throw ConjetError.invalidArgument("use either --dry-run or --apply, not both")
            }
            if json && restartAfterRepair {
                throw ConjetError.invalidArgument("use --restart without --json, or run 'conjet restart' after JSON repair")
            }
            let project = try takeValueOption("--project", from: &repairArgs)
            var containerIDs: [String] = []
            while let id = try takeValueOption("--id", from: &repairArgs) {
                containerIDs.append(id)
            }
            if let unknown = repairArgs.first {
                throw ConjetError.invalidArgument("unknown docker repair option '\(unknown)'")
            }

            let result = try DockerMetadataRepairer(dockerContext: dockerContextName(profileName: ConjetPaths.default().profileName))
                .repair(dryRun: !apply, project: project, containerIDs: containerIDs)
            if json {
                print(try ConjetJSON.string(result))
            } else {
                printDockerMetadataRepairResult(result)
            }
            if restartAfterRepair && result.repairedCount > 0 {
                let stopped = try stopRuntime(timeout: stopTimeout(from: nil), requireRunning: false)
                if !json, let stopped {
                    print(stopped.message)
                }
                _ = try startRuntime(args: [], json: json)
            } else if !json, result.repairedCount > 0 {
                print("Run 'conjet restart' so guest Docker reloads repaired metadata.")
            }
        default:
            throw ConjetError.invalidArgument("unknown docker command '\(subcommand)'")
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
        print("  energy mode: \(config.energyMode.rawValue)")
        print("  memory profile: \(config.memoryProfile.rawValue)")
        print("  network bind policy: \(config.networkBindPolicy.rawValue)")
        print("  network proxy engine: \(config.networkProxyEngine.rawValue)")
        print("  network bridge engine: \(config.networkBridgeEngine.rawValue)")
    }

    private static func printNetworkSummary(_ network: ConjetNetworkStatus, indent: String) {
        print("\(indent)Network:")
        print("\(indent)  Bind policy: \(network.bindPolicy.rawValue)")
        print("\(indent)  Proxy engine: \(network.proxyEngine)")
        print("\(indent)  Requested bridge: \(network.requestedBridgeEngine ?? "unknown")")
        print("\(indent)  Bridge engine: \(network.bridgeEngine)")
        print("\(indent)  TCP mode: \(network.tcpMode)")
        print("\(indent)  UDP mode: \(network.udpMode)")
        print("\(indent)  TCP forwards: \(network.activeTCPForwards) listening")
        print("\(indent)  UDP forwards: \(network.activeUDPForwards) listening")
        print("\(indent)  Failed forwards: \(network.failedForwards)")
        print("\(indent)  Conflicts: \(network.conflictCount)")
        print("\(indent)  Docker events: \(network.eventWatcherState)")
        print("\(indent)  Container target events: \(network.targetEventWatcherState)")
        print("\(indent)  Guest capabilities: tcp_proxy=\(network.capabilities.tcpProxy) udp_proxy=\(network.capabilities.udpProxy) container_target_events=\(network.capabilities.containerTargetEvents)")
        print("\(indent)  Guest bridge: \(network.capabilities.bridgeEngine ?? "unknown")")
        print("\(indent)  Binary frames: \(network.capabilities.binaryFrames) udp_binary_frames=\(network.capabilities.udpBinaryFrames)")
        print("\(indent)  TCP binary: frames=\(network.tcpBinaryFrames) persistent_vsock=\(network.persistentTCPVsock) pool=\(network.tcpVsockPool)")
        print("\(indent)  Python fallback active: \(network.pythonFallbackActive)")
        if let fallbackReason = network.fallbackReason {
            print("\(indent)  Bridge fallback: \(fallbackReason)")
        }
        if let lastReconcileAt = network.lastReconcileAt {
            print("\(indent)  Last reconcile: \(lastReconcileAt)")
        }
    }

    private static func printPortList(_ forwards: [ConjetPortForwardStatus], verbose: Bool) {
        guard !forwards.isEmpty else {
            print("No Docker published ports are currently tracked.")
            return
        }
        print([
            padded("PORT", width: 8),
            padded("PROTO", width: 5),
            padded("BIND", width: 15),
            padded("TARGET", width: 21),
            padded("STATE", width: 22),
            padded("CONTAINER", width: 18)
        ].joined(separator: " "))
        for forward in forwards.sorted(by: portSort) {
            let target = "\(forward.targetIP ?? "unknown"):\(forward.targetPort)"
            let container = forward.containerName ?? forward.containerID?.prefix(12).description ?? "-"
            print([
                padded(String(forward.hostPort), width: 8),
                padded(forward.protocol.rawValue, width: 5),
                padded(forward.hostIP, width: 15),
                padded(target, width: 21),
                padded(forward.state.rawValue, width: 22),
                padded(container, width: 18)
            ].joined(separator: " "))
            if verbose {
                if let warning = forward.warning {
                    print("  warning: \(warning)")
                }
                if let error = forward.error {
                    print("  error: \(error)")
                }
            }
        }
    }

    private static func printPortDiagnosis(_ diagnosis: PortDiagnosis) {
        let proto = diagnosis.queryProtocol ?? "tcp/udp"
        print("Port \(diagnosis.queryPort)/\(proto)")
        guard !diagnosis.matches.isEmpty else {
            print("  State: not tracked")
            print("  Policy: \(diagnosis.bindPolicy)")
            print("  Guest capability: tcp_proxy=\(diagnosis.tcpProxy) udp_proxy=\(diagnosis.udpProxy)")
            print("  Guest bridge: \(diagnosis.bridgeEngine)")
            print("  Suggested fix: verify the container is running and published through the conjet Docker context.")
            return
        }
        for forward in diagnosis.matches.sorted(by: portSort) {
            print("  State: \(forward.state.rawValue)")
            print("  Host bind: \(forward.hostIP):\(forward.hostPort)")
            print("  Target: \(forward.containerName ?? forward.containerID ?? "container") \(forward.targetIP ?? "unknown"):\(forward.targetPort)")
            print("  Protocol: \(forward.protocol.rawValue)")
            print("  Policy: \(forward.policy.rawValue)")
            print("  Proxy engine: \(forward.proxyEngine)")
            print("  Guest capability: tcp_proxy=\(diagnosis.tcpProxy) udp_proxy=\(diagnosis.udpProxy)")
            print("  Guest bridge: \(diagnosis.bridgeEngine)")
            if let warning = forward.warning {
                print("  Warning: \(warning)")
            }
            if let error = forward.error {
                print("  Error: \(error)")
                print("  Suggested fix: stop the process using the port, change the Compose mapping, or run conjet network repair.")
            } else {
                print("  Last check: ok")
            }
        }
        if !diagnosis.activeChecks.isEmpty {
            print("  Active checks:")
            for check in diagnosis.activeChecks {
                let status = check.ok ? "ok" : "failed"
                if let detail = check.detail {
                    print("    \(check.name): \(status) - \(detail)")
                } else {
                    print("    \(check.name): \(status)")
                }
            }
        }
    }

    private static func portDiagnosis(
        query: PortQuery,
        network: ConjetNetworkStatus,
        matches: [ConjetPortForwardStatus]
    ) -> PortDiagnosis {
        let activeChecks = matches.sorted(by: portSort).flatMap { forward -> [PortActiveCheck] in
            guard forward.state == .listening else {
                return [
                    PortActiveCheck(
                        name: "\(forward.protocol.rawValue)_listener",
                        ok: false,
                        detail: "tracked state is \(forward.state.rawValue)",
                        protocol: forward.protocol.rawValue,
                        host: forward.hostIP,
                        port: forward.hostPort
                    )
                ]
            }
            switch forward.protocol {
            case .tcp:
                return [activeTCPPortCheck(forward)]
            case .udp:
                return [activeUDPPortCheck(forward)]
            }
        }
        return PortDiagnosis(
            queryPort: query.port,
            queryProtocol: query.protocol?.rawValue,
            bindPolicy: network.bindPolicy.rawValue,
            bridgeEngine: network.bridgeEngine,
            tcpMode: network.tcpMode,
            udpMode: network.udpMode,
            tcpProxy: network.capabilities.tcpProxy,
            udpProxy: network.capabilities.udpProxy,
            tcpBinaryFrames: network.tcpBinaryFrames,
            persistentTCPVsock: network.persistentTCPVsock,
            tcpVsockPool: network.tcpVsockPool,
            pythonFallbackActive: network.pythonFallbackActive,
            matches: matches,
            activeChecks: activeChecks
        )
    }

    private static func activeTCPPortCheck(_ forward: ConjetPortForwardStatus) -> PortActiveCheck {
        let host = activeCheckHost(forward.hostIP)
        let result = tcpConnect(host: host, port: forward.hostPort, timeoutSeconds: 1)
        return PortActiveCheck(
            name: "tcp_connect",
            ok: result.ok,
            detail: result.detail,
            protocol: "tcp",
            host: host,
            port: forward.hostPort
        )
    }

    private static func activeUDPPortCheck(_ forward: ConjetPortForwardStatus) -> PortActiveCheck {
        let host = activeCheckHost(forward.hostIP)
        let result = udpProbe(host: host, port: forward.hostPort, timeoutSeconds: 1)
        return PortActiveCheck(
            name: "udp_datagram",
            ok: result.ok,
            detail: result.detail,
            protocol: "udp",
            host: host,
            port: forward.hostPort
        )
    }

    private static func activeCheckHost(_ hostIP: String) -> String {
        switch hostIP {
        case "0.0.0.0", "::", "":
            return "127.0.0.1"
        default:
            return hostIP
        }
    }

    private static func tcpConnect(host: String, port: Int, timeoutSeconds: Int) -> (ok: Bool, detail: String) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return (false, "socket failed: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }
        disableCLISigpipe(fd)
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        guard var address = ipv4Address(host: host, port: port) else {
            return (false, "unsupported or invalid IPv4 host \(host)")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 {
            return (true, "connected")
        }
        guard errno == EINPROGRESS else {
            return (false, "connect failed: \(String(cString: strerror(errno)))")
        }
        var writeSet = fd_set()
        fdZero(&writeSet)
        fdSet(fd, set: &writeSet)
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let selected = Darwin.select(fd + 1, nil, &writeSet, nil, &timeout)
        if selected <= 0 {
            return (false, selected == 0 ? "connect timed out" : "select failed: \(String(cString: strerror(errno)))")
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return (false, "SO_ERROR failed: \(String(cString: strerror(errno)))")
        }
        if socketError == 0 {
            return (true, "connected")
        }
        return (false, "connect failed: \(String(cString: strerror(socketError)))")
    }

    private static func udpProbe(host: String, port: Int, timeoutSeconds: Int) -> (ok: Bool, detail: String) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            return (false, "socket failed: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }
        guard var address = ipv4Address(host: host, port: port) else {
            return (false, "unsupported or invalid IPv4 host \(host)")
        }
        let payload = Data("conjet-diagnose".utf8)
        let sent = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, base, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else {
            return (false, "sendto failed: \(String(cString: strerror(errno)))")
        }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        if count > 0 {
            return (true, "datagram sent and \(count) byte response received")
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return (true, "datagram sent; no response required")
        }
        return (true, "datagram sent")
    }

    private static func ipv4Address(host: String, port: Int) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return nil
        }
        return address
    }

    private static func fdZero(_ set: inout fd_set) {
        set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static func fdSet(_ fd: Int32, set: inout fd_set) {
        let intOffset = Int(fd) / (MemoryLayout<Int32>.size * 8)
        let bitOffset = Int(fd) % (MemoryLayout<Int32>.size * 8)
        let mask = Int32(1 << bitOffset)
        withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[intOffset] |= mask
            }
        }
    }

    private static func disableCLISigpipe(_ fd: Int32) {
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func portSort(_ lhs: ConjetPortForwardStatus, _ rhs: ConjetPortForwardStatus) -> Bool {
        if lhs.hostPort != rhs.hostPort { return lhs.hostPort < rhs.hostPort }
        if lhs.protocol != rhs.protocol { return lhs.protocol.rawValue < rhs.protocol.rawValue }
        return lhs.hostIP < rhs.hostIP
    }

    private static func padded(_ value: String, width: Int) -> String {
        if value.count >= width { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    private static func parsePortQuery(_ value: String) throws -> PortQuery {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard let port = Int(parts[0]), port > 0, port <= 65_535 else {
            throw ConjetError.invalidArgument("port must be between 1 and 65535")
        }
        let proto: ConjetPortProtocol?
        if parts.count == 2 {
            guard let parsed = ConjetPortProtocol(rawValue: parts[1].lowercased()) else {
                throw ConjetError.invalidArgument("protocol must be tcp or udp")
            }
            proto = parsed
        } else {
            proto = nil
        }
        return PortQuery(port: port, protocol: proto)
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

    private static func parsePortNumber(_ value: String, flag: String) throws -> Int {
        let port = try parsePositiveInt(value, flag: flag)
        guard port <= 65_535 else {
            throw ConjetError.invalidArgument("\(flag) must be between 1 and 65535")
        }
        return port
    }

    private static func parseNetworkBindPolicy(_ value: String) throws -> ConjetNetworkBindPolicy {
        guard let policy = ConjetNetworkBindPolicy(rawValue: value) else {
            throw ConjetError.invalidArgument("network bind policy must be secure-local, docker-strict, or lan-allowlist")
        }
        return policy
    }

    private static func parseNetworkProxyEngine(_ value: String) throws -> ConjetNetworkProxyEngine {
        if let engine = ConjetNetworkProxyEngine(rawValue: value) {
            return engine
        }
        switch value {
        case "nio":
            return .eventLoop
        case "gcd-evented":
            return .gcdFallback
        default:
            throw ConjetError.invalidArgument("network proxy engine must be auto, nio, event-loop, gcd-evented, gcd-fallback, or turbo")
        }
    }

    private static func parseNetworkBridgeEngine(_ value: String) throws -> ConjetNetworkBridgeEngine {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto":
            return .auto
        case "python", "python-legacy":
            return .pythonLegacy
        case "conjet-netd", "conjet-netd-c":
            return .conjetNetdC
        default:
            throw ConjetError.invalidArgument("network bridge engine must be auto, python-legacy, or conjet-netd-c")
        }
    }

    private static func parseEnergyMode(_ value: String) throws -> ConjetEnergyMode {
        guard let mode = ConjetEnergyMode(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw ConjetError.invalidArgument("energy mode must be performance, balanced, or eco")
        }
        return mode
    }

    private static func parseMemoryProfile(_ value: String) throws -> ConjetMemoryProfile {
        guard let profile = ConjetMemoryProfile(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw ConjetError.invalidArgument("memory profile must be performance, balanced, or eco")
        }
        return profile
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

    private static func printStartVMResponseDetails(
        _ response: DaemonResponse,
        dockerContext: DockerContextResult?,
        hostShares: HostShareMountResult?
    ) {
        if let vm = response.vm ?? response.status?.vm {
            JetTerminal.line("  \(JetTerminal.symbolState) vm: \(vm.state.rawValue)")
            JetTerminal.dimLine("  \(JetTerminal.symbolLog) serial log: \(vm.serialLogPath ?? "unknown")")
            if let dockerContext {
                JetTerminal.dimLine("  \(JetTerminal.symbolDetail) docker context: \(dockerContext.contextName)")
            }
            if let hostShares {
                JetTerminal.dimLine("  \(JetTerminal.symbolDetail) host shares: \(hostShares.mountedPaths.joined(separator: ", "))")
            }
        }
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

    private static func printDockerMetadataRepairResult(_ result: DockerMetadataRepairResult) {
        let headline = result.dryRun ? "Docker metadata repair dry run" : "Docker metadata repair"
        print(headline)
        print("  docker context: \(result.dockerContext)")
        if let project = result.project {
            print("  project: \(project)")
        }
        if result.records.isEmpty {
            print("  stale records: 0")
            return
        }
        let interesting = result.records.filter { $0.action == .stale || $0.action == .repaired || $0.action == .skipped }
        print("  stale records: \(result.dryRun ? result.staleCount : result.repairedCount)")
        for record in interesting {
            let id = String(record.containerID.prefix(12))
            switch record.action {
            case .stale:
                print("  - stale \(id): \(record.reason)")
                if let backupPath = record.backupPath {
                    print("    backup: \(backupPath)")
                }
            case .repaired:
                print("  - repaired \(id): \(record.reason)")
                if let backupPath = record.backupPath {
                    print("    backup: \(backupPath)")
                }
            case .skipped:
                print("  - skipped \(id): \(record.reason)")
            case .healthy:
                continue
            }
        }
        if result.dryRun, result.staleCount > 0 {
            print("Run again with --apply to back up and remove stale metadata.")
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

    private static func bridgeHTTPCheck(
        socketPath: String,
        path: String,
        expectedBodySubstring: String,
        errors: inout [String],
        label: String
    ) -> Bool {
        do {
            let response = try unixSocketHTTPRequest(socketPath: socketPath, path: path)
            guard response.statusCode >= 200, response.statusCode < 300 else {
                errors.append("\(label) returned HTTP \(response.statusCode)")
                return false
            }
            guard response.body.contains(expectedBodySubstring) else {
                errors.append("\(label) did not include expected response")
                return false
            }
            return true
        } catch {
            errors.append("\(label) failed: \(error)")
            return false
        }
    }

    private static func bridgeBinaryPing(socketPath: String, errors: inout [String]) -> Bool {
        do {
            let fd = try connectUnixSocket(path: socketPath, timeoutSeconds: 2)
            defer { Darwin.close(fd) }
            let payload = Data("bridge-test".utf8)
            try writeBinaryFrameForBridgeTest(
                ConjetBinaryFrame(type: .ping, streamID: 1, payload: payload),
                to: fd
            )
            let response = try readBinaryFrameForBridgeTest(from: fd)
            guard response.type == .pong, response.payload == payload else {
                errors.append("binary ping returned \(response.type)")
                return false
            }
            return true
        } catch {
            errors.append("binary ping failed: \(error)")
            return false
        }
    }

    private static func bridgeUDPBinaryEcho(socketPath: String, errors: inout [String]) -> Bool {
        do {
            let fd = try connectUnixSocket(path: socketPath, timeoutSeconds: 2)
            defer { Darwin.close(fd) }
            let portForwardID: UInt32 = 4_242
            let target = Data("\(portForwardID) udp 127.0.0.1 0".utf8)
            try writeBinaryFrameForBridgeTest(
                ConjetBinaryFrame(type: .registerTarget, portForwardID: portForwardID, payload: target),
                to: fd
            )
            let registration = try readBinaryFrameForBridgeTest(from: fd)
            guard registration.type == .helloAck else {
                errors.append("UDP binary target registration returned \(registration.type)")
                return false
            }
            let payload = Data("conjet-udp-binary-echo".utf8)
            try writeBinaryFrameForBridgeTest(
                ConjetBinaryFrame(type: .udp, streamID: 2, portForwardID: portForwardID, payload: payload),
                to: fd
            )
            let response = try readBinaryFrameForBridgeTest(from: fd)
            guard response.type == .udp, response.payload == payload else {
                errors.append("UDP binary echo returned \(response.type)")
                return false
            }
            return true
        } catch {
            errors.append("UDP binary echo failed: \(error)")
            return false
        }
    }

    private static func unixSocketHTTPRequest(socketPath: String, path: String) throws -> BridgeHTTPResponse {
        let fd = try connectUnixSocket(path: socketPath, timeoutSeconds: 3)
        defer { Darwin.close(fd) }
        let request = "GET \(path) HTTP/1.1\r\nHost: conjet\r\nConnection: close\r\n\r\n"
        try writeAllForBridgeTest(Data(request.utf8), to: fd)
        Darwin.shutdown(fd, SHUT_WR)
        let data = try readAllForBridgeTest(from: fd, maxBytes: 256 * 1024)
        guard let text = String(data: data, encoding: .utf8),
              let statusLine = text.components(separatedBy: "\r\n").first else {
            throw ConjetError.decoding("bridge HTTP response was not UTF-8")
        }
        let pieces = statusLine.split(separator: " ")
        let statusCode = pieces.count >= 2 ? Int(pieces[1]) ?? 0 : 0
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return BridgeHTTPResponse(statusCode: statusCode, body: body)
    }

    private static func connectUnixSocket(path: String, timeoutSeconds: Double) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("socket() failed: \(lastErrnoForBridgeTest())")
        }
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setSocketTimeoutForBridgeTest(fd, timeoutSeconds: timeoutSeconds)
        do {
            try withUnixSocketAddressForBridgeTest(path: path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw ConjetError.socket("connect(\(path)) failed: \(lastErrnoForBridgeTest())")
                }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func localTCPConnectable(host: String, port: Int, timeoutSeconds: Double) -> Bool {
        guard port > 0, port <= 65_535 else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        setSocketTimeoutForBridgeTest(fd, timeoutSeconds: timeoutSeconds)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return false
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func withUnixSocketAddressForBridgeTest<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw ConjetError.socket("Unix socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func setSocketTimeoutForBridgeTest(_ fd: Int32, timeoutSeconds: Double) {
        let timeout = max(0.1, timeoutSeconds)
        var value = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func writeAllForBridgeTest(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw ConjetError.socket("write() failed: \(lastErrnoForBridgeTest())")
                }
            }
        }
    }

    private static func readAllForBridgeTest(from fd: Int32, maxBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maxBytes - data.count))
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if count < 0 {
                throw ConjetError.socket("read() failed: \(lastErrnoForBridgeTest())")
            } else {
                break
            }
        }
        return data
    }

    private static func writeBinaryFrameForBridgeTest(_ frame: ConjetBinaryFrame, to fd: Int32) throws {
        try writeAllForBridgeTest(try frame.encode(), to: fd)
    }

    private static func readBinaryFrameForBridgeTest(from fd: Int32) throws -> ConjetBinaryFrame {
        let header = try readExactForBridgeTest(from: fd, byteCount: ConjetBinaryFrame.headerSize)
        let payloadLength = binaryPayloadLengthForBridgeTest(header)
        guard payloadLength <= ConjetBinaryFrame.maxPayloadBytes else {
            throw ConjetError.socket("binary frame payload too large: \(payloadLength)")
        }
        let payload = payloadLength > 0 ? try readExactForBridgeTest(from: fd, byteCount: payloadLength) : Data()
        return try ConjetBinaryFrame.decode(header + payload)
    }

    private static func readExactForBridgeTest(from fd: Int32, byteCount: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(4096, max(1, byteCount)))
        while data.count < byteCount {
            let count = Darwin.read(fd, &buffer, min(buffer.count, byteCount - data.count))
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw ConjetError.socket("binary frame read failed: \(lastErrnoForBridgeTest())")
            }
        }
        return data
    }

    private static func binaryPayloadLengthForBridgeTest(_ header: Data) -> Int {
        guard header.count >= ConjetBinaryFrame.headerSize else { return 0 }
        let bytes = [UInt8](header)
        return (Int(bytes[16]) << 24) | (Int(bytes[17]) << 16) | (Int(bytes[18]) << 8) | Int(bytes[19])
    }

    private static func lastErrnoForBridgeTest() -> String {
        String(cString: strerror(errno))
    }

    private static func runGuestRootShell(_ script: String) throws -> ProcessResult {
        let socket = try ensureConjetDockerSocket()
        return try ProcessRunner.run("/usr/bin/env", [
            "docker",
            "--host",
            "unix://\(socket)",
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
        ], timeoutSeconds: 120)
    }

    private static func writeBridgeSelectorToBootstrap(paths: ConjetPaths, engine: ConjetNetworkBridgeEngine) throws {
        try FileManager.default.createDirectory(
            at: paths.bootstrapShare,
            withIntermediateDirectories: true
        )
        try "\(engine.rawValue)\n".write(
            to: paths.bootstrapShare.appendingPathComponent("network-bridge-engine"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
            cacheName: "\(artifact.releaseTag)-\(artifact.name)",
            progress: ui.progress(stage: "[conjet-core 1/4] downloading img")
        )
        if let checksumURL = artifact.checksumDownloadURL {
            let checksumPath = try downloadConjetCoreArtifact(
                urlString: checksumURL,
                force: force,
                cacheName: "\(artifact.releaseTag)-\(artifact.name).sha512sum",
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
        cacheName: String? = nil,
        progress: DownloadProgressRenderer? = nil
    ) throws -> String {
        guard let remote = URL(string: urlString),
              remote.scheme == "https",
              remote.host?.isEmpty == false,
              !remote.lastPathComponent.isEmpty else {
            throw ConjetError.invalidArgument("Conjet-core image URL must be a public https:// URL with a file name")
        }
        let destinationName = cacheName ?? remote.lastPathComponent
        guard !destinationName.isEmpty,
              !destinationName.contains("/"),
              !destinationName.contains("\0") else {
            throw ConjetError.invalidArgument("Conjet-core cache file name is invalid")
        }

        let paths = ConjetPaths.default()
        try paths.ensureBaseDirectories()
        let destination = paths.vmDirectory.appendingPathComponent(destinationName)
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

    private static func waitForDaemonStop(socketPath: String, timeoutSeconds: Double = 5) {
        let attempts = max(1, Int((timeoutSeconds / 0.1).rounded(.up)))
        for _ in 0..<attempts {
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
        let manager = FileManager.default
        let candidates = daemonExecutableCandidates()
        for candidate in candidates where manager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        let checked = candidates.map(\.path).joined(separator: ", ")
        throw ConjetError.unavailable(
            "could not find conjetd next to conjet; checked: \(checked). " +
            "If installed with Homebrew, run 'brew reinstall conjet'. If running from source, run 'swift build' first."
        )
    }

    private static func daemonExecutableCandidates() -> [URL] {
        var executables: [URL] = []
        if let executable = currentExecutableURL() {
            executables.append(executable)
        }
        if let executable = Bundle.main.executableURL {
            executables.append(executable)
        }
        executables.append(contentsOf: commandLineExecutableCandidates())

        var seen: Set<String> = []
        var daemons: [URL] = []
        for executable in executables {
            for candidate in daemonCandidates(nextTo: executable) {
                let path = candidate.standardizedFileURL.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                daemons.append(candidate)
            }
        }

        if let pathDaemon = executableInPATH(named: "conjetd") {
            let path = pathDaemon.standardizedFileURL.path
            if !seen.contains(path) {
                daemons.append(pathDaemon)
            }
        }
        return daemons
    }

    private static func daemonCandidates(nextTo executable: URL) -> [URL] {
        let standardized = executable.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        let rawDaemon = standardized.deletingLastPathComponent().appendingPathComponent("conjetd")
        let resolvedDaemon = resolved.deletingLastPathComponent().appendingPathComponent("conjetd")
        return rawDaemon.path == resolvedDaemon.path ? [rawDaemon] : [rawDaemon, resolvedDaemon]
    }

    private static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        guard _NSGetExecutablePath(buffer, &size) == 0 else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private static func commandLineExecutableCandidates() -> [URL] {
        guard let arg0 = CommandLine.arguments.first, !arg0.isEmpty else {
            return []
        }
        if arg0.contains("/") {
            return [URL(fileURLWithPath: arg0)]
        }
        if let executable = executableInPATH(named: arg0) {
            return [executable]
        }
        return []
    }

    private static func executableInPATH(named name: String) -> URL? {
        guard !name.contains("/") else {
            return nil
        }
        let manager = FileManager.default
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name)
            if manager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func takeValueOption(_ flag: String, from args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: flag) else {
            return nil
        }
        guard args.indices.contains(index + 1) else {
            throw ConjetError.invalidArgument("\(flag) requires a value")
        }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    private static func isHelpFlag(_ value: String) -> Bool {
        value == "--help" || value == "-h"
    }

    private static func isHelpRequest(command: String, args: [String]) -> Bool {
        guard !args.isEmpty else { return false }
        if isHelpFlag(args[0]) { return true }
        switch command {
        case "vm", "sync", "project", "profile", "power", "port", "network", "docker":
            return args.indices.contains(1) && isHelpFlag(args[1])
        default:
            return false
        }
    }

    private static func printHelp(for topic: [String]) {
        let parts = topic.filter { !isHelpFlag($0) }
        guard let command = parts.first else {
            printHelp()
            return
        }

        switch command {
        case "start":
            print(
                """
                Start conjetd and the configured VM.

                Usage:
                  conjet start [--cpus N] [--memory SIZE] [--disk SIZE_OR_PATH] [--runtime NAME] [--arch ARCH]
                               [--energy-mode MODE] [--memory-profile MODE] [--network-bind-policy POLICY] [--proxy-engine ENGINE]

                Options:
                  --cpus, --cpu N       Set VM CPU count
                  --memory SIZE         Set VM memory, for example 4G or 4096M
                  --disk SIZE_OR_PATH   Set VM data disk size or use a custom disk image path
                  --runtime NAME        Set container runtime preference
                  --arch ARCH           Set guest architecture
                  --energy-mode performance|balanced|eco
                  --memory-profile performance|balanced|eco
                  --network-bind-policy secure-local|docker-strict|lan-allowlist
                  --proxy-engine auto|nio|event-loop|gcd-evented|gcd-fallback|turbo
                  --allow-cidr CIDR     Add a LAN allowlist CIDR for lan-allowlist mode
                  --allow-port PORT     Add a LAN allowlist port for lan-allowlist mode
                  --profile NAME        Use an isolated Conjet profile
                  --json                Emit machine-readable JSON where supported
                  -h, --help            Show this help text
                """
            )
        case "stop":
            print(
                """
                Stop the VM and daemon.

                Usage:
                  conjet stop [--timeout SECONDS]

                Options:
                  --timeout SECONDS     Bound graceful shutdown wait time
                  --profile NAME        Use an isolated Conjet profile
                  --json                Emit machine-readable JSON where supported
                  -h, --help            Show this help text
                """
            )
        case "restart":
            print(
                """
                Restart the VM and daemon, or start Conjet if it is stopped.
                Restart prunes runtime cache before shutdown when conjetd is running.

                Usage:
                  conjet restart [--timeout SECONDS] [start options]

                Options:
                  --timeout SECONDS     Bound graceful shutdown wait time
                  --cpus, --cpu N       Set VM CPU count before starting
                  --memory SIZE         Set VM memory before starting
                  --disk SIZE_OR_PATH   Set VM data disk size or use a custom disk image path
                  --runtime NAME        Set container runtime preference
                  --arch ARCH           Set guest architecture
                  --energy-mode performance|balanced|eco
                  --memory-profile performance|balanced|eco
                  --network-bind-policy secure-local|docker-strict|lan-allowlist
                  --proxy-engine auto|nio|event-loop|gcd-evented|gcd-fallback|turbo
                  --profile NAME        Use an isolated Conjet profile
                  --json                Emit machine-readable JSON
                  -h, --help            Show this help text
                """
            )
        case "update":
            print(
                """
                Update the Conjet Core VM image, preserving the data disk.

                Usage:
                  conjet update [--repository OWNER/REPO] [--image PATH|--url HTTPS_URL] [--force]
                                [--restart|--no-restart] [--timeout SECONDS]

                Options:
                  --repository OWNER/REPO Fetch Conjet Core from a GitHub repository
                  --image PATH           Import a local Conjet Core image artifact
                  --url HTTPS_URL        Download a Conjet Core image artifact from a URL
                  --boot-disk-gb N       Expand imported boot disk to at least N GiB
                  --force                Redownload remote artifacts even when cached
                  --restart              Start Conjet after updating, even if it was stopped
                  --no-restart           Leave Conjet stopped after updating
                  --timeout SECONDS      Bound graceful shutdown wait time
                  --profile NAME         Use an isolated Conjet profile
                  --json                 Emit machine-readable JSON
                  -h, --help             Show this help text
                """
            )
        case "status":
            print(
                """
                Show daemon, VM, and Docker socket status.

                Usage:
                  conjet status [--json]

                Options:
                  --profile NAME        Use an isolated Conjet profile
                  --json                Emit machine-readable JSON
                  -h, --help            Show this help text
                """
            )
        case "doctor":
            print(
                """
                Check host capabilities and Conjet configuration.

                Usage:
                  conjet doctor [clock [--repair]|--repair-network] [--json]

                Options:
                  clock                 Report host/guest clock drift
                  --repair              Repair clock drift when used with doctor clock
                  --repair-network      Reconcile ConjetNet state and restart network tracking
                  --profile NAME        Use an isolated Conjet profile
                  --json                Emit machine-readable JSON
                  -h, --help            Show this help text
                """
            )
        case "ssh", "ssh-key":
            print(
                """
                Manage the Conjet profile SSH key and localhost-only SSH access.

                Usage:
                  conjet ssh [command]
                  conjet ssh-key rotate

                Commands:
                  status                Show SSH key, guest sshd, and localhost endpoint status
                  enable                Enable SSH for this profile
                  disable               Disable SSH for this profile
                  key status            Show profile-scoped key status
                  key rotate            Rotate the profile-scoped Ed25519 key and install it in the guest

                Options:
                  --profile NAME        Use an isolated Conjet profile
                  --json                Emit machine-readable JSON where supported
                  -h, --help            Show this help text
                """
            )
        case "shell":
            print(
                """
                Open a privileged Linux shell through the Conjet Docker socket.

                Usage:
                  conjet shell [-- COMMAND...]

                Examples:
                  conjet shell
                  conjet shell -- uname -a
                """
            )
        case "run":
            print(
                """
                Run a Docker image through Conjet.

                Usage:
                  conjet run IMAGE [COMMAND...]

                Examples:
                  conjet run ubuntu:24.04 uname -a
                  conjet run alpine:latest sh
                """
            )
        case "compose":
            print(
                """
                Pass through to docker compose using Conjet.

                Usage:
                  conjet compose up [docker compose args]

                Examples:
                  conjet compose up
                  conjet compose up --build
                """
            )
        case "vm":
            printVMHelp(parts: parts)
        case "project":
            printProjectHelp(parts: parts)
        case "sync":
            printSyncHelp(parts: parts)
        case "profile":
            printProfileHelp(parts: parts)
        case "power":
            printPowerHelp(parts: parts)
        case "port":
            printPortHelp(parts: parts)
        case "network":
            printNetworkHelp(parts: parts)
        case "docker":
            printDockerHelp(parts: parts)
        default:
            printHelp()
        }
    }

    private static func printVMHelp(parts: [String]) {
        if parts.count >= 2 {
            switch parts[1] {
            case "fetch-conjet-core":
                print(
                    """
                    Download and import a Conjet Core VM image.

                    Usage:
                      conjet vm fetch-conjet-core [--image PATH|--url HTTPS_URL|--repository OWNER/REPO] [--name NAME] [--boot-disk-gb N] [--force]
                    """
                )
            case "fetch-ubuntu-cloud":
                print(
                    """
                    Prepare an Ubuntu cloud image.

                    Usage:
                      conjet vm fetch-ubuntu-cloud [--release NAME] [--name NAME] [--cloud-init-docker] [--boot-disk-gb N] [--force]
                    """
                )
            case "fetch-fedora":
                print(
                    """
                    Prepare a Fedora cloud image.

                    Usage:
                      conjet vm fetch-fedora [--release VERSION] [--force]
                    """
                )
            case "fetch-alpine":
                print(
                    """
                    Prepare an Alpine image.

                    Usage:
                      conjet vm fetch-alpine [--force]
                    """
                )
            case "import-efi-disk":
                print(
                    """
                    Import a custom EFI-bootable disk image.

                    Usage:
                      conjet vm import-efi-disk --image PATH [--name NAME] [--cloud-init-docker] [--force]
                    """
                )
            case "init":
                print(
                    """
                    Configure kernel and initrd boot assets.

                    Usage:
                      conjet vm init --kernel PATH [--initrd PATH] [--cmdline TEXT]
                    """
                )
            case "validate":
                print("Usage:\n  conjet vm validate [--json]")
            case "start":
                print("Usage:\n  conjet vm start [--json]")
            case "stop":
                print("Usage:\n  conjet vm stop [--json]")
            case "status":
                print("Usage:\n  conjet vm status [--json]")
            case "logs":
                print("Usage:\n  conjet vm logs [--lines N]")
            default:
                printVMHelp(parts: ["vm"])
            }
            return
        }

        print(
            """
            Manage Conjet VM images and VM lifecycle.

            Usage:
              conjet vm <command> [options]

            Commands:
              fetch-conjet-core   Download a Conjet Core VM image
              fetch-ubuntu-cloud  Prepare an Ubuntu cloud image
              fetch-fedora        Prepare a Fedora cloud image
              fetch-alpine        Prepare an Alpine image
              import-efi-disk     Import a custom EFI-bootable disk image
              init                Configure kernel/initrd boot assets
              validate            Validate the configured VM image
              start               Start only the VM layer
              stop                Stop only the VM layer
              status              Show VM status
              logs                Show VM logs
            """
        )
    }

    private static func printProjectHelp(parts: [String]) {
        if parts.count >= 2 {
            switch parts[1] {
            case "init":
                print("Usage:\n  conjet project init [PATH] [--json]")
            case "attach":
                print("Usage:\n  conjet project attach [PATH] [--no-sync] [--json]")
            case "status":
                print("Usage:\n  conjet project status [PATH] [--json]")
            case "run":
                print("Usage:\n  conjet project run [--path PATH] [--no-sync] IMAGE [COMMAND...]")
            default:
                printProjectHelp(parts: ["project"])
            }
            return
        }

        print(
            """
            Manage ConjetFS project workspaces.

            Usage:
              conjet project <command> [options]

            Commands:
              init      Create ConjetFS metadata for a project
              attach    Attach an existing project to ConjetFS
              status    Show project sync state
              run       Sync and run a container in the project workspace
            """
        )
    }

    private static func printSyncHelp(parts: [String]) {
        if parts.count >= 2 {
            switch parts[1] {
            case "classify":
                print("Usage:\n  conjet sync classify PATH [--json]")
            case "push":
                print("Usage:\n  conjet sync push [PATH] [--json]")
            case "status":
                print("Usage:\n  conjet sync status [PATH] [--json]")
            case "watch":
                print("Usage:\n  conjet sync watch [PATH] [--once] [--poll] [--interval SECONDS] [--debounce SECONDS] [--json]")
            case "repair":
                print("Usage:\n  conjet sync repair [PATH] [--json]")
            case "export":
                print("Usage:\n  conjet sync export PATH... --to DEST [--path PROJECT] [--json]")
            default:
                printSyncHelp(parts: ["sync"])
            }
            return
        }

        print(
            """
            Synchronize project files into ConjetFS.

            Usage:
              conjet sync <command> [options]

            Commands:
              classify   Explain host vs Linux-native path handling
              push       Push changed project files into ConjetFS
              status     Show ConjetFS sync status
              watch      Watch and incrementally sync project changes
              repair     Rebuild ConjetFS metadata
              export     Export synchronized paths back to macOS
            """
        )
    }

    private static func printProfileHelp(parts: [String]) {
        if parts.count >= 2 {
            switch parts[1] {
            case "status":
                print("Usage:\n  conjet profile status [--json]")
            case "list":
                print("Usage:\n  conjet profile list [--json]")
            default:
                printProfileHelp(parts: ["profile"])
            }
            return
        }

        print(
            """
            Manage local Conjet profiles.

            Usage:
              conjet profile <command> [options]

            Commands:
              status   Show the active profile configuration
              list     List local profiles
            """
        )
    }

    private static func printPowerHelp(parts: [String]) {
        if parts.count >= 2 {
            switch parts[1] {
            case "policy":
                print("Usage:\n  conjet power policy STATE [--json]")
            default:
                printPowerHelp(parts: ["power"])
            }
            return
        }

        print(
            """
            Inspect Conjet power policies.

            Usage:
              conjet power <command> [options]

            Commands:
              policy   Show the policy for a runtime state
            """
        )
    }

    private static func printPortHelp(parts: [String]) {
        if parts.count >= 2 {
            switch parts[1] {
            case "list":
                print("Usage:\n  conjet port list [--verbose] [--json]")
            case "diagnose":
                print("Usage:\n  conjet port diagnose PORT[/tcp|/udp] [--json]")
            default:
                printPortHelp(parts: ["port"])
            }
            return
        }

        print(
            """
            Inspect Docker published ports exposed by ConjetNet.

            Usage:
              conjet port <command> [options]

            Commands:
              list       Show tracked TCP and UDP published ports
              diagnose   Explain listener, policy, capability, and conflict state for a port
            """
        )
    }

    private static func printNetworkHelp(parts: [String]) {
        if parts.count >= 2 {
            switch parts[1] {
            case "status":
                print("Usage:\n  conjet network status [--json]")
            case "repair":
                print("Usage:\n  conjet network repair [--json]")
            case "bridge-test":
                print("Usage:\n  conjet network bridge-test [--json]")
            case "bridge-switch":
                print("Usage:\n  conjet network bridge-switch python-legacy|conjet-netd-c [--restart] [--json]")
            case "policy":
                print("Usage:\n  conjet network policy\n  conjet network policy set secure-local|docker-strict|lan-allowlist [--allow-cidr CIDR] [--allow-port PORT] [--clear-allowlist]")
            case "enable-turbo":
                print("Usage:\n  conjet network enable-turbo")
            default:
                printNetworkHelp(parts: ["network"])
            }
            return
        }

        print(
            """
            Manage ConjetNet port publishing and bind policy.

            Usage:
              conjet network <command> [options]

            Commands:
              status       Show ConjetNet state and guest capabilities
              repair       Clear stale state and reconcile published ports
              bridge-test  Verify the active guest bridge and Docker passthrough
              bridge-switch Select python-legacy or conjet-netd-c inside the guest
              policy       Inspect or set the network bind policy
              enable-turbo Show turbo-mode availability
            """
        )
    }

    private static func printDockerHelp(parts: [String]) {
        if parts.count >= 2 {
            switch parts[1] {
            case "repair":
                print(
                    """
                    Repair stale Docker metadata inside the Conjet VM.

                    Usage:
                      conjet docker repair [--dry-run|--apply] [--restart] [--project NAME] [--id CONTAINER_ID]... [--json]

                    Options:
                      --dry-run       Detect stale metadata without removing it (default)
                      --apply         Back up and remove verified stale metadata directories
                      --restart       Restart Conjet after successful repair so dockerd reloads metadata
                      --project NAME  Limit scan to a Docker Compose project label
                      --id ID         Limit repair to one container id; may be repeated
                    """
                )
            default:
                printDockerHelp(parts: ["docker"])
            }
            return
        }

        print(
            """
            Inspect and repair Docker daemon state inside Conjet.

            Usage:
              conjet docker <command> [options]

            Commands:
              repair   Detect and repair stale Docker container metadata
            """
        )
    }

    private static func printHelp() {
        print(
            """
            Conjet manages a lightweight macOS container runtime and synchronized Linux workspaces.

            Usage:
              conjet [--profile NAME] <command> [options]

            Runtime:
              start       Start conjetd and the configured VM
              stop        Stop the VM and daemon
              restart     Stop and start the VM and daemon
              update      Update the Conjet Core VM image
              status      Show daemon, VM, and Docker socket status
              doctor      Check host capabilities and Conjet configuration
              ssh         Manage localhost-only SSH access
              ssh-key     Rotate or inspect the profile SSH key
              shell       Open a privileged Linux shell through the Conjet Docker socket
              run         Run a Docker image through Conjet
              compose     Pass through to docker compose using Conjet
              docker      Inspect and repair Docker daemon metadata

            Networking:
              port list        Show Docker published ports on macOS
              port diagnose    Diagnose a published TCP or UDP port
              network status   Show ConjetNet policy, capabilities, and watcher state
              network repair   Reconcile stale port-forwarding state
              network bridge-test Verify native bridge activation and Docker passthrough
              network bridge-switch Switch the active guest bridge engine
              network policy   Inspect or change the network bind policy
              docker repair    Repair stale Docker container metadata

            VM Images:
              vm fetch-conjet-core   Download a Conjet Core VM image
              vm fetch-ubuntu-cloud  Prepare an Ubuntu cloud image
              vm fetch-fedora        Prepare a Fedora cloud image
              vm fetch-alpine        Prepare an Alpine image
              vm import-efi-disk     Import a custom EFI-bootable disk image
              vm init                Configure kernel/initrd boot assets
              vm validate            Validate the configured VM image
              vm start|stop|status   Control only the VM layer
              vm logs                Show VM logs

            Projects:
              project init     Create ConjetFS metadata for a project
              project attach   Attach an existing project to ConjetFS
              project status   Show project sync state
              project run      Sync and run a container in the project workspace

            Sync:
              sync classify    Explain host vs Linux-native path handling
              sync push        Push changed project files into ConjetFS
              sync status      Show ConjetFS sync status
              sync watch       Watch and incrementally sync project changes
              sync repair      Rebuild ConjetFS metadata
              sync export      Export synchronized paths back to macOS

            Profiles and Power:
              profile status   Show the active profile configuration
              profile list     List local profiles
              power policy     Set power policy state

            Flags:
              --profile NAME   Use an isolated Conjet profile
              --json           Emit machine-readable JSON where supported
              -h, --help       Show this help text

            Environment:
              CONJET_HOME      Override the state root (default: ~/.conjet)
              CONJET_PROFILE   Select the active profile when --profile is omitted

            Benchmarks:
              Benchmarking ships as a standalone developer package and is not part of
              the production conjet executable. Use:
                swift run --package-path benchmarks conjet-bench --help

            Kubernetes:
              Kubernetes commands are intentionally not included in this generation.
            """
        )
    }
}

private enum JetTerminal {
    static let symbolStep = "◆"
    static let symbolCached = "◇"
    static let symbolDone = "✓"
    static let symbolError = "✗"
    static let symbolRetry = "↻"
    static let symbolState = "▶"
    static let symbolLog = "╰"
    static let symbolDetail = "·"

    private static let dimGray = "\u{001B}[2;90m"
    private static let neonGreen = "\u{001B}[38;5;46m"
    private static let reset = "\u{001B}[0m"
    private static let clearLine = "\u{001B}[2K"
    private static let outputLock = NSLock()

    static func line(_ text: String) {
        write("\(colorizeBrand(text))\n")
    }

    static func dimLine(_ text: String) {
        write("\(dim(text))\n")
    }

    static func renderProgress(_ text: String) {
        write("\r\(clearLine)\(colorizeBrand(text))")
    }

    static func finishProgress() {
        write("\n")
    }

    static func redrawBlock(previousLineCount: Int, lines: [String]) {
        var text = ""
        if previousLineCount > 0 {
            text += "\u{001B}[\(previousLineCount)A"
        }
        for line in lines {
            text += "\(clearLine)\(line)\n"
        }
        write(text)
    }

    static func dim(_ text: String) -> String {
        "\(dimGray)\(colorizeBrand(text, restoreStyle: dimGray))\(reset)"
    }

    private static func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(data)
    }

    private static func colorizeBrand(_ text: String, restoreStyle: String = "") -> String {
        text.replacingOccurrences(of: "conjet", with: "\(neonGreen)conjet\(reset)\(restoreStyle)")
    }
}

private final class VMStartLiveRenderer: @unchecked Sendable {
    private let serialLogPath: String?
    private let serialStartOffset: UInt64?
    private let lock = NSLock()
    private var running = false
    private var renderedLineCount = 0
    private var spinnerIndex = 0
    private var state = "[vm 2/2] starting"
    private var thread: Thread?

    init(serialLogPath: String?) {
        self.serialLogPath = serialLogPath
        self.serialStartOffset = serialLogPath.flatMap(Self.fileSize)
    }

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        redraw()
        let worker = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 0.16)
                guard self?.isRunning() == true else { break }
                self?.redraw()
            }
        }
        thread = worker
        worker.start()
    }

    func setState(_ state: String) {
        lock.lock()
        self.state = state
        lock.unlock()
        redraw()
    }

    func stop(finalLine: String) {
        lock.lock()
        running = false
        state = finalLine
        lock.unlock()
        redraw()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func redraw() {
        let frame = spinner()
        let currentState: String
        lock.lock()
        currentState = state
        lock.unlock()

        var lines = ["\(frame) \(currentState)"]
        if let serialLogPath {
            lines.append(JetTerminal.dim("  \(JetTerminal.symbolLog) serial: \(serialLogPath)"))
            let serialLines = Self.tailLines(
                path: serialLogPath,
                limit: 5,
                containing: "conjet-boot-diagnostics",
                fromOffset: serialStartOffset
            )
            if serialLines.isEmpty {
                lines.append(JetTerminal.dim("  \(JetTerminal.symbolDetail) waiting for serial status..."))
            } else {
                lines += serialLines.map { JetTerminal.dim("  \(JetTerminal.symbolDetail) \($0)") }
            }
        } else {
            lines.append(JetTerminal.dim("  \(JetTerminal.symbolDetail) serial log unavailable"))
        }

        lock.lock()
        let previous = renderedLineCount
        renderedLineCount = lines.count
        lock.unlock()
        JetTerminal.redrawBlock(previousLineCount: previous, lines: lines)
    }

    private func spinner() -> String {
        lock.lock()
        defer { lock.unlock() }
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let frame = frames[spinnerIndex % frames.count]
        spinnerIndex += 1
        return running ? frame : JetTerminal.symbolDone
    }

    private static func fileSize(path: String) -> UInt64? {
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        return try? handle.seekToEnd()
    }

    private static func tailLines(
        path: String,
        limit: Int,
        containing filter: String? = nil,
        fromOffset: UInt64? = nil
    ) -> [String] {
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return []
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let maxReadSize = UInt64(64 * 1024)
        let startOffset: UInt64
        if let fromOffset, fromOffset <= size {
            startOffset = size - fromOffset > maxReadSize ? size - maxReadSize : fromOffset
        } else {
            startOffset = size > UInt64(8 * 1024) ? size - UInt64(8 * 1024) : 0
        }
        do {
            try handle.seek(toOffset: startOffset)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            let lines = text
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let filtered = filter.map { needle in
                lines.filter { $0.contains(needle) }
            } ?? lines
            return Array(filtered.suffix(limit))
        } catch {
            return []
        }
    }
}

private struct ConjetFetchUI {
    var enabled: Bool

    func step(_ message: String) {
        guard enabled else { return }
        JetTerminal.line("\(JetTerminal.symbolStep) \(message)")
    }

    func cached(_ message: String) {
        guard enabled else { return }
        JetTerminal.line("\(JetTerminal.symbolCached) CACHED \(message)")
    }

    func progress(stage: String) -> DownloadProgressRenderer? {
        guard enabled else { return nil }
        return DownloadProgressRenderer(stage: stage)
    }
}

private struct PortQuery {
    var port: Int
    var `protocol`: ConjetPortProtocol?
}

private struct PortDiagnosis: Codable {
    var queryPort: Int
    var queryProtocol: String?
    var bindPolicy: String
    var bridgeEngine: String
    var tcpMode: String
    var udpMode: String
    var tcpProxy: Bool
    var udpProxy: Bool
    var tcpBinaryFrames: Bool
    var persistentTCPVsock: Bool
    var tcpVsockPool: Bool
    var pythonFallbackActive: Bool
    var matches: [ConjetPortForwardStatus]
    var activeChecks: [PortActiveCheck]
}

private struct PortActiveCheck: Codable {
    var name: String
    var ok: Bool
    var detail: String?
    var `protocol`: String
    var host: String
    var port: Int
}

private final class DownloadProgressRenderer: @unchecked Sendable {
    private let stage: String
    private let lock = NSLock()
    private var lastPercent: Int?
    private var lastBytes: Int64 = 0
    private var emitted = false
    private var spinnerIndex = 0

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
                || lastPercent.map { percent != $0 } ?? true
            guard shouldEmit else { return }
            lastPercent = percent
            emitted = true
            JetTerminal.renderProgress(
                "\(spinner()) \(stage) \(Self.progressBar(percent: percent)) \(percent)% \(Self.formatBytes(bytesWritten))/\(Self.formatBytes(totalBytes))"
            )
            return
        }

        let shouldEmit = !emitted || bytesWritten - lastBytes >= 1024 * 1024
        guard shouldEmit else { return }
        lastBytes = bytesWritten
        emitted = true
        JetTerminal.renderProgress("\(spinner()) \(stage) \(Self.formatBytes(bytesWritten))")
    }

    func retry(attempt: Int, maxAttempts: Int) {
        lock.lock()
        lastPercent = nil
        lastBytes = 0
        emitted = false
        spinnerIndex = 0
        lock.unlock()
        JetTerminal.finishProgress()
        JetTerminal.line("\(JetTerminal.symbolRetry) \(stage): retrying (\(attempt)/\(maxAttempts))")
    }

    func cached() {
        JetTerminal.line("\(JetTerminal.symbolCached) CACHED \(stage)")
    }

    func finish(bytesWritten: Int64?) {
        lock.lock()
        defer { lock.unlock() }

        if let bytesWritten {
            JetTerminal.renderProgress("\(JetTerminal.symbolDone) \(stage) done \(Self.formatBytes(bytesWritten))")
        } else {
            JetTerminal.renderProgress("\(JetTerminal.symbolDone) \(stage) done")
        }
        JetTerminal.finishProgress()
    }

    private func spinner() -> String {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let frame = frames[spinnerIndex % frames.count]
        spinnerIndex += 1
        return frame
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

    private static func progressBar(percent: Int) -> String {
        let width = 18
        let filled = max(0, min(width, Int((Double(percent) / 100.0) * Double(width))))
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: width - filled)
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

private struct ClockDoctorOutput: Codable, Equatable {
    var hostEpochMs: Int
    var guestEpochMs: Int
    var hostGuestClockDeltaMs: Int
    var thresholdMs: Int
    var supported: Bool
    var repairAttempted: Bool
    var repairSucceeded: Bool
    var resyncLatencyMs: Int?
    var message: String
}

private struct ClockProbe: Codable, Equatable {
    var hostEpochMs: Int
    var guestEpochMs: Int
    var deltaMs: Int
}

private struct SSHStatusOutput: Codable, Equatable {
    var profile: String
    var enabled: Bool
    var keyPath: String
    var publicKeyPath: String
    var keyExists: Bool
    var guestConfigured: Bool
    var sshdRunning: Bool
    var localhostOnly: Bool
    var endpoint: String?
    var message: String
}

private enum SSHTransport: String, Codable, Equatable {
    case proxyCommand = "proxy-command"
    case tcp
}

private struct SSHEndpoint: Codable, Equatable {
    var transport: SSHTransport
    var host: String
    var port: Int

    var description: String {
        switch transport {
        case .proxyCommand:
            return "proxy-command:docker-local"
        case .tcp:
            return "\(host):\(port)"
        }
    }
}

private struct ProfileStatus: Codable, Equatable {
    var profile: String
    var home: String
    var config: ConjetConfig
}

private struct ConjetRestartResult: Codable, Equatable {
    var pruned: DaemonResponse?
    var stopped: DaemonResponse?
    var started: DaemonResponse
}

private struct ConjetUpdateResult: Codable, Equatable {
    var artifactPath: String
    var previousDaemonRunning: Bool
    var stopped: DaemonResponse?
    var manifest: VMAssetManifest
    var restarted: Bool
    var started: DaemonResponse?
}

private struct BridgeTestOutput: Codable, Equatable {
    var requestedBridgeEngine: String
    var activeBridgeEngine: String
    var fallbackReason: String?
    var guestEcho: Bool
    var guestMetrics: Bool
    var binaryFrames: Bool
    var udpBinaryFrames: Bool
    var persistentVsock: Bool
    var tcpMode: String
    var udpMode: String
    var tcpBinaryFrames: Bool
    var persistentTCPVsock: Bool
    var tcpVsockPool: Bool
    var pythonFallbackActive: Bool
    var dockerApiPassthrough: Bool
    var tcpGuestEcho: Bool
    var binaryPing: Bool
    var udpBinaryEcho: Bool
    var errors: [String]
}

private struct BridgeHTTPResponse: Equatable {
    var statusCode: Int
    var body: String
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

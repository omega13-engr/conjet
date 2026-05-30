import Foundation

public struct ConjetConfig: Codable, Equatable, Sendable {
    public var vmCPUs: Int
    public var memoryMiB: Int
    public var architecture: String
    public var diskGiB: Int
    public var diskImagePath: String?
    public var runtime: String
    public var quietStopMinutes: Int
    public var enableRosetta: Bool
    public var enableHostMounts: Bool
    public var socketPath: String?
    public var conjetCoreRepository: String

    public init(
        vmCPUs: Int = 4,
        memoryMiB: Int = 8192,
        architecture: String = "aarch64",
        diskGiB: Int = 100,
        diskImagePath: String? = nil,
        runtime: String = "docker",
        quietStopMinutes: Int = 30,
        enableRosetta: Bool = true,
        enableHostMounts: Bool = true,
        socketPath: String? = nil,
        conjetCoreRepository: String = ConjetCoreReleaseSource.defaultRepository
    ) {
        self.vmCPUs = vmCPUs
        self.memoryMiB = memoryMiB
        self.architecture = architecture
        self.diskGiB = diskGiB
        self.diskImagePath = diskImagePath
        self.runtime = runtime
        self.quietStopMinutes = quietStopMinutes
        self.enableRosetta = enableRosetta
        self.enableHostMounts = enableHostMounts
        self.socketPath = socketPath
        self.conjetCoreRepository = conjetCoreRepository
    }

    public static let `default` = ConjetConfig()

    public static func loadOrCreate(paths: ConjetPaths = .default()) throws -> ConjetConfig {
        try paths.ensureBaseDirectories()
        let manager = FileManager.default
        if manager.fileExists(atPath: paths.config.path) {
            let text = try String(contentsOf: paths.config, encoding: .utf8)
            return try parseTOML(text)
        }
        let config = ConjetConfig.default
        try config.renderTOML().write(to: paths.config, atomically: true, encoding: .utf8)
        return config
    }

    public func save(paths: ConjetPaths = .default()) throws {
        try paths.ensureBaseDirectories()
        try renderTOML().write(to: paths.config, atomically: true, encoding: .utf8)
    }

    public func renderTOML() -> String {
        var lines = [
            "# Conjet local configuration",
            "# This file is intentionally small until the VM and sync engines are stable.",
            "",
            "[daemon]",
            "quiet_stop_minutes = \(quietStopMinutes)"
        ]
        if let socketPath {
            lines.append("socket_path = \"\(escapeTOML(socketPath))\"")
        }
        lines.append("")
        lines.append("[vm]")
        lines.append("cpus = \(vmCPUs)")
        lines.append("memory_mib = \(memoryMiB)")
        lines.append("architecture = \"\(escapeTOML(architecture))\"")
        lines.append("disk_gib = \(diskGiB)")
        if let diskImagePath {
            lines.append("disk_image_path = \"\(escapeTOML(diskImagePath))\"")
        }
        lines.append("runtime = \"\(escapeTOML(runtime))\"")
        lines.append("enable_rosetta = \(enableRosetta)")
        lines.append("enable_host_mounts = \(enableHostMounts)")
        lines.append("")
        lines.append("[images]")
        lines.append("conjet_core_repository = \"\(escapeTOML(conjetCoreRepository))\"")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func parseTOML(_ text: String) throws -> ConjetConfig {
        var config = ConjetConfig.default
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else {
                throw ConjetError.decoding("invalid config line: \(line)")
            }

            let key = section.isEmpty ? parts[0] : "\(section).\(parts[0])"
            let value = parts[1]
            switch key {
            case "vm.cpus":
                config.vmCPUs = try parseInt(value, key: key)
            case "vm.memory_mib":
                config.memoryMiB = try parseInt(value, key: key)
            case "vm.architecture":
                config.architecture = parseString(value)
            case "vm.disk_gib":
                config.diskGiB = try parseInt(value, key: key)
            case "vm.disk_image_path":
                let parsed = parseString(value)
                config.diskImagePath = parsed.isEmpty ? nil : parsed
            case "vm.runtime":
                config.runtime = parseString(value)
            case "vm.enable_rosetta":
                config.enableRosetta = try parseBool(value, key: key)
            case "vm.enable_host_mounts":
                config.enableHostMounts = try parseBool(value, key: key)
            case "daemon.quiet_stop_minutes":
                config.quietStopMinutes = try parseInt(value, key: key)
            case "daemon.socket_path":
                config.socketPath = parseString(value)
            case "images.conjet_core_repository":
                config.conjetCoreRepository = parseString(value)
            default:
                continue
            }
        }

        guard config.vmCPUs > 0 else {
            throw ConjetError.decoding("vm.cpus must be positive")
        }
        guard config.memoryMiB >= 512 else {
            throw ConjetError.decoding("vm.memory_mib must be at least 512")
        }
        guard ["aarch64", "x86_64"].contains(config.architecture) else {
            throw ConjetError.decoding("vm.architecture must be aarch64 or x86_64")
        }
        guard config.diskGiB > 0 else {
            throw ConjetError.decoding("vm.disk_gib must be positive")
        }
        guard config.runtime == "docker" else {
            throw ConjetError.decoding("vm.runtime currently supports docker")
        }
        guard isValidGitHubRepository(config.conjetCoreRepository) else {
            throw ConjetError.decoding("images.conjet_core_repository must use OWNER/REPO format")
        }
        return config
    }

    private static func parseInt(_ value: String, key: String) throws -> Int {
        guard let intValue = Int(value) else {
            throw ConjetError.decoding("\(key) must be an integer")
        }
        return intValue
    }

    private static func parseBool(_ value: String, key: String) throws -> Bool {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: throw ConjetError.decoding("\(key) must be true or false")
        }
    }

    private static func parseString(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\"") {
            text.removeFirst()
            text.removeLast()
        }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        var result = ""
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                result.append(character)
                continue
            }
            if character == "#", !inString {
                break
            }
            result.append(character)
        }
        return result
    }

    private func escapeTOML(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func isValidGitHubRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }
}

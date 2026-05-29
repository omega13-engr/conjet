import Foundation

public struct ConjetConfig: Codable, Equatable, Sendable {
    public var vmCPUs: Int
    public var memoryMiB: Int
    public var quietStopMinutes: Int
    public var enableRosetta: Bool
    public var socketPath: String?
    public var conjetCoreRepository: String

    public init(
        vmCPUs: Int = 4,
        memoryMiB: Int = 4096,
        quietStopMinutes: Int = 30,
        enableRosetta: Bool = true,
        socketPath: String? = nil,
        conjetCoreRepository: String = ConjetCoreReleaseSource.defaultRepository
    ) {
        self.vmCPUs = vmCPUs
        self.memoryMiB = memoryMiB
        self.quietStopMinutes = quietStopMinutes
        self.enableRosetta = enableRosetta
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
        lines.append("enable_rosetta = \(enableRosetta)")
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
            case "vm.enable_rosetta":
                config.enableRosetta = try parseBool(value, key: key)
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

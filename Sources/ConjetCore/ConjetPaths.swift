import Foundation

public struct ConjetPaths: Codable, Equatable, Sendable {
    public var profileName: String
    public var rootHome: URL
    public var home: URL
    public var config: URL
    public var runDirectory: URL
    public var socket: URL
    public var logsDirectory: URL
    public var daemonLog: URL
    public var stateDirectory: URL
    public var vmDirectory: URL
    public var vmManifest: URL
    public var bootstrapShare: URL
    public var serialLog: URL
    public var dockerSocket: URL

    public init(home: URL) {
        self.init(home: home, profileName: "default")
    }

    public init(home: URL, profileName: String) {
        let safeProfileName = Self.safeProfileName(profileName)
        let profileHome = safeProfileName == "default"
            ? home
            : home.appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(safeProfileName, isDirectory: true)
        self.profileName = safeProfileName
        self.rootHome = home
        self.home = profileHome
        self.config = profileHome.appendingPathComponent("config.toml")
        self.runDirectory = profileHome.appendingPathComponent("run")
        self.socket = runDirectory.appendingPathComponent("conjetd.sock")
        self.logsDirectory = profileHome.appendingPathComponent("logs")
        self.daemonLog = logsDirectory.appendingPathComponent("conjetd.log")
        self.stateDirectory = profileHome.appendingPathComponent("state")
        self.vmDirectory = stateDirectory.appendingPathComponent("vm", isDirectory: true)
        self.vmManifest = vmDirectory.appendingPathComponent("manifest.json")
        self.bootstrapShare = vmDirectory.appendingPathComponent("bootstrap", isDirectory: true)
        self.serialLog = logsDirectory.appendingPathComponent("vm-serial.log")
        self.dockerSocket = runDirectory.appendingPathComponent("docker.sock")
    }

    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ConjetPaths {
        let profileName = environment["CONJET_PROFILE"] ?? "default"
        if let override = environment["CONJET_HOME"], !override.isEmpty {
            return ConjetPaths(home: URL(fileURLWithPath: override, isDirectory: true), profileName: profileName)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".conjet", isDirectory: true)
        return ConjetPaths(home: home, profileName: profileName)
    }

    public func ensureBaseDirectories() throws {
        let manager = FileManager.default
        for directory in [home, runDirectory, logsDirectory, stateDirectory, vmDirectory, bootstrapShare] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public static func isValidProfileName(_ profileName: String) -> Bool {
        safeProfileName(profileName) == profileName && !profileName.isEmpty
    }

    public static func safeProfileName(_ profileName: String) -> String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !trimmed.contains(".."),
              !trimmed.hasPrefix(".") else {
            return "default"
        }
        return trimmed
    }
}

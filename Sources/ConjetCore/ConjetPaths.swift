import Foundation

public struct ConjetPaths: Codable, Equatable, Sendable {
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
        self.home = home
        self.config = home.appendingPathComponent("config.toml")
        self.runDirectory = home.appendingPathComponent("run")
        self.socket = runDirectory.appendingPathComponent("conjetd.sock")
        self.logsDirectory = home.appendingPathComponent("logs")
        self.daemonLog = logsDirectory.appendingPathComponent("conjetd.log")
        self.stateDirectory = home.appendingPathComponent("state")
        self.vmDirectory = stateDirectory.appendingPathComponent("vm", isDirectory: true)
        self.vmManifest = vmDirectory.appendingPathComponent("manifest.json")
        self.bootstrapShare = vmDirectory.appendingPathComponent("bootstrap", isDirectory: true)
        self.serialLog = logsDirectory.appendingPathComponent("vm-serial.log")
        self.dockerSocket = runDirectory.appendingPathComponent("docker.sock")
    }

    public static func `default`() -> ConjetPaths {
        if let override = ProcessInfo.processInfo.environment["CONJET_HOME"], !override.isEmpty {
            return ConjetPaths(home: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".conjet", isDirectory: true)
        return ConjetPaths(home: home)
    }

    public func ensureBaseDirectories() throws {
        let manager = FileManager.default
        for directory in [home, runDirectory, logsDirectory, stateDirectory, vmDirectory, bootstrapShare] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

import ConjetCore
import Foundation

public struct MachineProfile: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var host: HostCapabilities
    public var powerSource: String
    public var thermalState: String

    public init(capturedAt: Date, host: HostCapabilities, powerSource: String, thermalState: String) {
        self.capturedAt = capturedAt
        self.host = host
        self.powerSource = powerSource
        self.thermalState = thermalState
    }
}

public enum MachineProfiler {
    public static func capture() -> MachineProfile {
        let host = HostCapabilities.detect()
        return MachineProfile(
            capturedAt: Date(),
            host: host,
            powerSource: powerSource(),
            thermalState: host.thermalState
        )
    }

    private static func powerSource() -> String {
        do {
            let result = try ProcessRunner.run("/usr/bin/pmset", ["-g", "batt"])
            let output = result.stdout.lowercased()
            if output.contains("ac power") { return "ac-power" }
            if output.contains("battery power") { return "battery" }
            return "unknown"
        } catch {
            return "unknown"
        }
    }
}

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

private final class MachineProfileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var profile: MachineProfile?

    func value(validAt now: Date, ttl: TimeInterval) -> MachineProfile? {
        lock.lock()
        defer { lock.unlock() }
        guard let profile, now.timeIntervalSince(profile.capturedAt) <= ttl else {
            return nil
        }
        return profile
    }

    func store(_ profile: MachineProfile) {
        lock.lock()
        self.profile = profile
        lock.unlock()
    }
}

public enum MachineProfiler {
    private static let cache = MachineProfileCache()

    public static func capture(cacheTTLSeconds: TimeInterval = 30) -> MachineProfile {
        let now = Date()
        let ttl = max(0, cacheTTLSeconds)
        if let cachedProfile = cache.value(validAt: now, ttl: ttl) {
            return MachineProfile(
                capturedAt: now,
                host: cachedProfile.host,
                powerSource: cachedProfile.powerSource,
                thermalState: cachedProfile.thermalState
            )
        }

        let host = HostCapabilities.detect()
        let profile = MachineProfile(
            capturedAt: now,
            host: host,
            powerSource: powerSource(),
            thermalState: host.thermalState
        )
        cache.store(profile)
        return profile
    }

    private static func powerSource() -> String {
        do {
            let result = try ProcessRunner.run("/usr/bin/pmset", ["-g", "batt"], timeoutSeconds: 5)
            let output = result.stdout.lowercased()
            if output.contains("ac power") { return "ac-power" }
            if output.contains("battery power") { return "battery" }
            return "unknown"
        } catch {
            return "unknown"
        }
    }
}

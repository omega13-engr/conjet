import Darwin
import Foundation

public struct HostCapabilities: Codable, Equatable, Sendable {
    public var macOSVersion: String
    public var buildVersion: String
    public var architecture: String
    public var cpuBrand: String
    public var memoryBytes: UInt64
    public var isAppleSilicon: Bool
    public var hypervisorFrameworkAvailable: Bool
    public var lowPowerModeEnabled: Bool
    public var thermalState: String
    public var requiredEntitlements: [String]

    public static func detect() -> HostCapabilities {
        let architecture = unameMachine()
        return HostCapabilities(
            macOSVersion: swVers("-productVersion"),
            buildVersion: swVers("-buildVersion"),
            architecture: architecture,
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            memoryBytes: sysctlUInt64("hw.memsize") ?? 0,
            isAppleSilicon: architecture == "arm64",
            hypervisorFrameworkAvailable: hypervisorFrameworkAvailable(),
            lowPowerModeEnabled: lowPowerModeEnabled(),
            thermalState: thermalState(),
            requiredEntitlements: [
                "com.apple.security.hypervisor"
            ]
        )
    }

    private static func swVers(_ argument: String) -> String {
        do {
            let result = try ProcessRunner.run("/usr/bin/sw_vers", [argument], timeoutSeconds: 5)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }

    private static func unameMachine() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let bytes = mirror.children.compactMap { child -> UInt8? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return UInt8(value)
        }
        return String(bytes: bytes, encoding: .utf8) ?? "unknown"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func hypervisorFrameworkAvailable() -> Bool {
        #if canImport(Hypervisor)
        return true
        #else
        return false
        #endif
    }

    private static func lowPowerModeEnabled() -> Bool {
        if #available(macOS 12.0, *) {
            return ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return false
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

import Foundation

public struct ConjetHVFSmokeStageResult: Codable, Equatable, Sendable {
    public var name: String
    public var ok: Bool
    public var detail: String
    public var returnCode: Int64?
    public var returnCodeHex: String?
    public var durationNanoseconds: UInt64?

    public init(
        name: String,
        ok: Bool,
        detail: String,
        returnCode: Int64? = nil,
        returnCodeHex: String? = nil,
        durationNanoseconds: UInt64? = nil
    ) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.returnCode = returnCode
        self.returnCodeHex = returnCodeHex
        self.durationNanoseconds = durationNanoseconds
    }
}

public struct ConjetHVFEntitlementStatus: Codable, Equatable, Sendable {
    public var executablePath: String?
    public var requiredEntitlement: String
    public var present: Bool?
    public var detail: String

    public init(
        executablePath: String?,
        requiredEntitlement: String,
        present: Bool?,
        detail: String
    ) {
        self.executablePath = executablePath
        self.requiredEntitlement = requiredEntitlement
        self.present = present
        self.detail = detail
    }
}

public struct ConjetHVFSmokeResult: Codable, Equatable, Sendable {
    public var backend: ConjetVMBackend
    public var ok: Bool
    public var hypervisorAvailable: Bool
    public var appleSilicon: Bool
    public var architecture: String
    public var requiredEntitlement: String
    public var entitlementStatus: ConjetHVFEntitlementStatus?
    public var memoryBytes: Int
    public var guestPhysicalAddress: UInt64
    public var consoleOutput: String?
    public var stages: [ConjetHVFSmokeStageResult]
    public var message: String

    public init(
        backend: ConjetVMBackend = .hvfExperimental,
        ok: Bool,
        hypervisorAvailable: Bool,
        appleSilicon: Bool,
        architecture: String,
        requiredEntitlement: String = "com.apple.security.hypervisor",
        entitlementStatus: ConjetHVFEntitlementStatus? = nil,
        memoryBytes: Int,
        guestPhysicalAddress: UInt64,
        consoleOutput: String? = nil,
        stages: [ConjetHVFSmokeStageResult],
        message: String
    ) {
        self.backend = backend
        self.ok = ok
        self.hypervisorAvailable = hypervisorAvailable
        self.appleSilicon = appleSilicon
        self.architecture = architecture
        self.requiredEntitlement = requiredEntitlement
        self.entitlementStatus = entitlementStatus
        self.memoryBytes = memoryBytes
        self.guestPhysicalAddress = guestPhysicalAddress
        self.consoleOutput = consoleOutput
        self.stages = stages
        self.message = message
    }
}

import ConjetCore
import Foundation

public struct VirtualizationCapabilities: Codable, Equatable, Sendable {
    public var hypervisorAvailable: Bool
    public var appleSilicon: Bool
    public var recommendedVMType: String
    public var notes: [String]

    public init(
        hypervisorAvailable: Bool,
        appleSilicon: Bool,
        recommendedVMType: String,
        notes: [String]
    ) {
        self.hypervisorAvailable = hypervisorAvailable
        self.appleSilicon = appleSilicon
        self.recommendedVMType = recommendedVMType
        self.notes = notes
    }
}

public struct LinuxVMPlan: Codable, Equatable, Sendable {
    public var cpuCount: Int
    public var memoryMiB: Int
    public var rootDiskPath: String
    public var dataDiskPath: String
    public var bootstrapSharePath: String

    public init(
        cpuCount: Int,
        memoryMiB: Int,
        rootDiskPath: String,
        dataDiskPath: String,
        bootstrapSharePath: String
    ) {
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.rootDiskPath = rootDiskPath
        self.dataDiskPath = dataDiskPath
        self.bootstrapSharePath = bootstrapSharePath
    }
}

public enum VirtualizationProbe {
    public static func inspect(config: ConjetConfig = .default, host: HostCapabilities = .detect()) -> VirtualizationCapabilities {
        var notes: [String] = []
        if !host.isAppleSilicon {
            notes.append("non-arm64 host: the Jetstream ARM64 HVF backend is unavailable")
        }
        if !host.hypervisorFrameworkAvailable {
            notes.append("Hypervisor.framework is not available to this build target")
        }
        notes.append("Jetstream HVF is the Conjet Core backend; direct-kernel guest start is available when Jetstream boot assets are imported")
        notes.append("x86_64 Linux userspace uses on-demand guest QEMU translation; native arm64 execution remains direct")

        return VirtualizationCapabilities(
            hypervisorAvailable: host.hypervisorFrameworkAvailable,
            appleSilicon: host.isAppleSilicon,
            recommendedVMType: config.vmBackend.rawValue,
            notes: notes
        )
    }

    public static func draftPlan(config: ConjetConfig, paths: ConjetPaths = .default()) -> LinuxVMPlan {
        LinuxVMPlan(
            cpuCount: config.effectiveVMCPUs,
            memoryMiB: config.effectiveMemoryMiB,
            rootDiskPath: paths.stateDirectory.appendingPathComponent("root.img").path,
            dataDiskPath: paths.stateDirectory.appendingPathComponent("data.img").path,
            bootstrapSharePath: paths.stateDirectory.appendingPathComponent("bootstrap").path
        )
    }

}

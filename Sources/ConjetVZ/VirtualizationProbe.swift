import ConjetCore
import Foundation

#if canImport(Virtualization)
import Virtualization
#endif

public struct VirtualizationCapabilities: Codable, Equatable, Sendable {
    public var frameworkLinked: Bool
    public var appleSilicon: Bool
    public var rosettaRequestedByDefault: Bool
    public var recommendedVMType: String
    public var notes: [String]

    public init(
        frameworkLinked: Bool,
        appleSilicon: Bool,
        rosettaRequestedByDefault: Bool,
        recommendedVMType: String,
        notes: [String]
    ) {
        self.frameworkLinked = frameworkLinked
        self.appleSilicon = appleSilicon
        self.rosettaRequestedByDefault = rosettaRequestedByDefault
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
    public var useRosetta: Bool

    public init(
        cpuCount: Int,
        memoryMiB: Int,
        rootDiskPath: String,
        dataDiskPath: String,
        bootstrapSharePath: String,
        useRosetta: Bool
    ) {
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.rootDiskPath = rootDiskPath
        self.dataDiskPath = dataDiskPath
        self.bootstrapSharePath = bootstrapSharePath
        self.useRosetta = useRosetta
    }
}

public enum VirtualizationProbe {
    public static func inspect(config: ConjetConfig = .default, host: HostCapabilities = .detect()) -> VirtualizationCapabilities {
        var notes: [String] = []
        if !host.isAppleSilicon {
            notes.append("non-arm64 host: Rosetta-for-Linux and Apple Silicon fast paths are unavailable")
        }
        if !host.virtualizationFrameworkAvailable {
            notes.append("Virtualization.framework is not available to this build target")
        }
        if config.enableRosetta, !host.rosettaLinuxSupportLikelyAvailable {
            notes.append("Rosetta Linux support was requested but was not detected")
        }
        if config.vmBackend == .hvfExperimental {
            notes.append("Jetstream HVF is selected as the primary Conjet Core backend; direct-kernel guest start is available when Jetstream boot assets are imported")
            if config.enableRosetta {
                notes.append("Rosetta Linux workloads require the VZ fallback while HVF public Rosetta support is unresolved")
            }
        }

        return VirtualizationCapabilities(
            frameworkLinked: frameworkLinked,
            appleSilicon: host.isAppleSilicon,
            rosettaRequestedByDefault: config.enableRosetta,
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
            bootstrapSharePath: paths.stateDirectory.appendingPathComponent("bootstrap").path,
            useRosetta: config.enableRosetta
        )
    }

    private static var frameworkLinked: Bool {
        #if canImport(Virtualization)
        return true
        #else
        return false
        #endif
    }
}

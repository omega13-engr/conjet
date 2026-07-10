import ConjetCore
import CryptoKit
import Darwin
import Foundation

public enum VMBootLoaderKind: String, Codable, Equatable, Sendable {
    case linuxKernel = "linux-kernel"
    case linuxArm64CompressedEfiZboot = "linux-arm64-compressed-efi-zboot"
    case efiDisk = "efi-disk"
}

public struct VMAssetManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var architecture: String
    public var bootLoaderKind: VMBootLoaderKind
    public var bootDiskPath: String?
    public var efiVariableStorePath: String?
    public var cloudInitSeedPath: String?
    public var kernelPath: String
    public var initialRamdiskPath: String?
    public var modloopPath: String?
    public var rootDiskPath: String
    public var dataDiskPath: String?
    public var swapDiskPath: String?
    public var bootstrapSharePath: String
    public var serialLogPath: String
    public var dockerSocketPath: String
    public var kernelCommandLine: String
    public var createdAt: Date
    public var source: String

    public init(
        version: Int = 1,
        name: String,
        architecture: String,
        bootLoaderKind: VMBootLoaderKind = .linuxKernel,
        bootDiskPath: String? = nil,
        efiVariableStorePath: String? = nil,
        cloudInitSeedPath: String? = nil,
        kernelPath: String,
        initialRamdiskPath: String?,
        modloopPath: String?,
        rootDiskPath: String,
        dataDiskPath: String? = nil,
        swapDiskPath: String? = nil,
        bootstrapSharePath: String,
        serialLogPath: String,
        dockerSocketPath: String,
        kernelCommandLine: String,
        createdAt: Date = Date(),
        source: String
    ) {
        self.version = version
        self.name = name
        self.architecture = architecture
        self.bootLoaderKind = bootLoaderKind
        self.bootDiskPath = bootDiskPath
        self.efiVariableStorePath = efiVariableStorePath
        self.cloudInitSeedPath = cloudInitSeedPath
        self.kernelPath = kernelPath
        self.initialRamdiskPath = initialRamdiskPath
        self.modloopPath = modloopPath
        self.rootDiskPath = rootDiskPath
        self.dataDiskPath = dataDiskPath
        self.swapDiskPath = swapDiskPath
        self.bootstrapSharePath = bootstrapSharePath
        self.serialLogPath = serialLogPath
        self.dockerSocketPath = dockerSocketPath
        self.kernelCommandLine = kernelCommandLine
        self.createdAt = createdAt
        self.source = source
    }

    public func runtimeStatus(state: VMRunState, message: String, manifestPath: String) -> VMRuntimeStatus {
        VMRuntimeStatus(
            state: state,
            configured: true,
            manifestPath: manifestPath,
            bootLoaderKind: bootLoaderKind.rawValue,
            bootDiskPath: bootDiskPath,
            efiVariableStorePath: efiVariableStorePath,
            cloudInitSeedPath: cloudInitSeedPath,
            kernelPath: kernelPath,
            initialRamdiskPath: initialRamdiskPath,
            rootDiskPath: rootDiskPath,
            dataDiskPath: dataDiskPath,
            swapDiskPath: swapDiskPath,
            bootstrapSharePath: bootstrapSharePath,
            serialLogPath: serialLogPath,
            dockerSocketPath: dockerSocketPath,
            message: message
        )
    }
}

public struct AlpineNetbootSource: Codable, Equatable, Sendable {
    public var baseURL: String
    public var repositoryURL: String

    public init(
        baseURL: String = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/netboot",
        repositoryURL: String = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"
    ) {
        self.baseURL = baseURL
        self.repositoryURL = repositoryURL
    }

    public var kernelURL: String { "\(baseURL)/vmlinuz-virt" }
    public var initialRamdiskURL: String { "\(baseURL)/initramfs-virt" }
    public var modloopURL: String { "\(baseURL)/modloop-virt" }
}

public struct FedoraPXESource: Codable, Equatable, Sendable {
    public var release: String
    public var baseURL: String
    public var repositoryURL: String

    public init(
        release: String = "43",
        baseURL: String? = nil,
        repositoryURL: String? = nil
    ) {
        self.release = release
        self.baseURL = baseURL ?? "https://download.fedoraproject.org/pub/fedora/linux/releases/\(release)/Everything/aarch64/os/images/pxeboot"
        self.repositoryURL = repositoryURL ?? "https://download.fedoraproject.org/pub/fedora/linux/releases/\(release)/Everything/aarch64/os"
    }

    public var kernelURL: String { "\(baseURL)/vmlinuz" }
    public var initialRamdiskURL: String { "\(baseURL)/initrd.img" }
}

public struct DebianInstallerSource: Codable, Equatable, Sendable {
    public var suite: String
    public var baseURL: String

    public init(
        suite: String = "stable",
        baseURL: String? = nil
    ) {
        self.suite = suite
        self.baseURL = baseURL
            ?? "https://deb.debian.org/debian/dists/\(suite)/main/installer-arm64/current/images/netboot/debian-installer/arm64"
    }

    public var kernelURL: String { "\(baseURL)/linux" }
    public var initialRamdiskURL: String { "\(baseURL)/initrd.gz" }
}

public struct Phase9NetworkProofAssetBundleManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var architecture: String
    public var createdAt: String?
    public var kernelImage: String
    public var kernelImageSha256: String
    public var kernelBuildManifest: String?
    public var kernelBuildManifestSha256: String?
    public var busybox: String
    public var busyboxSha256: String
    public var initramfs: String
    public var initramfsSha256: String
    public var proofURL: String
    public var guestServicePort: Int

    public init(
        schemaVersion: Int,
        name: String,
        architecture: String,
        createdAt: String?,
        kernelImage: String,
        kernelImageSha256: String,
        kernelBuildManifest: String? = nil,
        kernelBuildManifestSha256: String? = nil,
        busybox: String,
        busyboxSha256: String,
        initramfs: String,
        initramfsSha256: String,
        proofURL: String,
        guestServicePort: Int
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.architecture = architecture
        self.createdAt = createdAt
        self.kernelImage = kernelImage
        self.kernelImageSha256 = kernelImageSha256
        self.kernelBuildManifest = kernelBuildManifest
        self.kernelBuildManifestSha256 = kernelBuildManifestSha256
        self.busybox = busybox
        self.busyboxSha256 = busyboxSha256
        self.initramfs = initramfs
        self.initramfsSha256 = initramfsSha256
        self.proofURL = proofURL
        self.guestServicePort = guestServicePort
    }
}

public struct Phase9KernelBuildManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var version: String
    public var architecture: String
    public var image: String
    public var imageSha256: String
    public var config: String
    public var configSha256: String?
    public var systemMapSha256: String?
    public var vmlinuxSha256: String?
    public var source: String
    public var sourceSha256: String
    public var requiredBuiltIns: [String]
}

public struct VMImageStore: Sendable {
    public static let dockerDirectKernelRequiredBuiltIns = [
        "CONFIG_ARM64_16K_PAGES",
        "CONFIG_OF",
        "CONFIG_BLK_DEV_INITRD",
        "CONFIG_BLK_DEV_LOOP",
        "CONFIG_RD_GZIP",
        "CONFIG_DEVTMPFS",
        "CONFIG_DEVTMPFS_MOUNT",
        "CONFIG_TMPFS",
        "CONFIG_TMPFS_POSIX_ACL",
        "CONFIG_DUMMY_CONSOLE",
        "CONFIG_SERIAL_AMBA_PL011",
        "CONFIG_SERIAL_AMBA_PL011_CONSOLE",
        "CONFIG_ARM_AMBA",
        "CONFIG_ARM_GIC",
        "CONFIG_ARM_GIC_V3",
        "CONFIG_ARM_ARCH_TIMER",
        "CONFIG_VIRTIO",
        "CONFIG_VIRTIO_MENU",
        "CONFIG_VIRTIO_MMIO",
        "CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES",
        "CONFIG_VIRTIO_BLK",
        "CONFIG_VIRTIO_NET",
        "CONFIG_VIRTIO_CONSOLE",
        "CONFIG_VIRTIO_BALLOON",
        "CONFIG_VSOCKETS",
        "CONFIG_VIRTIO_VSOCKETS",
        "CONFIG_VIRTIO_VSOCKETS_COMMON",
        "CONFIG_HW_RANDOM",
        "CONFIG_HW_RANDOM_VIRTIO",
        "CONFIG_BLOCK",
        "CONFIG_BLK_DEV",
        "CONFIG_PCI",
        "CONFIG_PCI_HOST_GENERIC",
        "CONFIG_NVME_CORE",
        "CONFIG_BLK_DEV_NVME",
        "CONFIG_PARTITION_ADVANCED",
        "CONFIG_EFI_PARTITION",
        "CONFIG_MSDOS_PARTITION",
        "CONFIG_EXT4_FS",
        "CONFIG_EXT4_USE_FOR_EXT2",
        "CONFIG_OVERLAY_FS",
        "CONFIG_MISC_FILESYSTEMS",
        "CONFIG_SQUASHFS",
        "CONFIG_ISO9660_FS",
        "CONFIG_VFAT_FS",
        "CONFIG_NLS",
        "CONFIG_NLS_CODEPAGE_437",
        "CONFIG_NLS_ISO8859_1",
        "CONFIG_FUSE_FS",
        "CONFIG_VIRTIO_FS",
        "CONFIG_SWAP",
        "CONFIG_NAMESPACES",
        "CONFIG_SYSVIPC",
        "CONFIG_UTS_NS",
        "CONFIG_IPC_NS",
        "CONFIG_USER_NS",
        "CONFIG_PID_NS",
        "CONFIG_NET_NS",
        "CONFIG_CGROUPS",
        "CONFIG_BPF_SYSCALL",
        "CONFIG_CGROUP_BPF",
        "CONFIG_CGROUP_PIDS",
        "CONFIG_CGROUP_FREEZER",
        "CONFIG_CGROUP_DEVICE",
        "CONFIG_CPUSETS",
        "CONFIG_MEMCG",
        "CONFIG_BLK_CGROUP",
        "CONFIG_CGROUP_SCHED",
        "CONFIG_FAIR_GROUP_SCHED",
        "CONFIG_SECCOMP",
        "CONFIG_SECCOMP_FILTER",
        "CONFIG_KEYS",
        "CONFIG_POSIX_MQUEUE",
        "CONFIG_BINFMT_ELF",
        "CONFIG_BINFMT_SCRIPT",
        "CONFIG_BINFMT_MISC",
        "CONFIG_PSI",
        "CONFIG_ZSMALLOC",
        "CONFIG_ZRAM",
        "CONFIG_ZRAM_WRITEBACK",
        "CONFIG_NET",
        "CONFIG_INET",
        "CONFIG_IPV6",
        "CONFIG_PACKET",
        "CONFIG_UNIX",
        "CONFIG_NETDEVICES",
        "CONFIG_NET_CORE",
        "CONFIG_TUN",
        "CONFIG_VETH",
        "CONFIG_BRIDGE",
        "CONFIG_BRIDGE_NETFILTER",
        "CONFIG_NETFILTER",
        "CONFIG_NETFILTER_ADVANCED",
        "CONFIG_NF_CONNTRACK",
        "CONFIG_NF_NAT",
        "CONFIG_NF_TABLES",
        "CONFIG_NF_TABLES_INET",
        "CONFIG_NF_TABLES_IPV4",
        "CONFIG_NF_TABLES_IPV6",
        "CONFIG_NFT_CT",
        "CONFIG_NFT_FIB",
        "CONFIG_NFT_FIB_INET",
        "CONFIG_NFT_FIB_IPV4",
        "CONFIG_NFT_FIB_IPV6",
        "CONFIG_NFT_NAT",
        "CONFIG_NFT_MASQ",
        "CONFIG_NFT_REDIR",
        "CONFIG_INOTIFY_USER",
        "CONFIG_FANOTIFY",
        "CONFIG_EPOLL",
        "CONFIG_PROC_FS",
        "CONFIG_SYSFS",
        "CONFIG_DEBUG_FS",
        "CONFIG_PRINTK",
        "CONFIG_MAGIC_SYSRQ"
    ]

    public static let requiredJetstreamKernelBuiltIns = dockerDirectKernelRequiredBuiltIns

    private static let phase9RequiredKernelBuiltIns = requiredJetstreamKernelBuiltIns

    public var paths: ConjetPaths

    public init(paths: ConjetPaths = .default()) {
        self.paths = paths
    }

    public func manifestExists() -> Bool {
        FileManager.default.fileExists(atPath: paths.vmManifest.path)
    }

    public func loadManifest() throws -> VMAssetManifest {
        guard manifestExists() else {
            throw ConjetError.unavailable("VM is not configured; run 'conjet start' to fetch and import the latest Conjet Core image")
        }
        let data = try Data(contentsOf: paths.vmManifest)
        return try ConjetJSON.decoder().decode(VMAssetManifest.self, from: data)
    }

    public func saveManifest(_ manifest: VMAssetManifest) throws {
        try paths.ensureBaseDirectories()
        let data = try ConjetJSON.encoder().encode(manifest)
        try data.write(to: paths.vmManifest, options: .atomic)
    }

    public func expandDataDiskIfNeeded(sizeBytes: Int64) throws {
        let manifest = try loadManifest()
        guard let dataDiskPath = manifest.dataDiskPath else {
            return
        }
        try expandRawDiskIfNeeded(url: URL(fileURLWithPath: dataDiskPath), sizeBytes: sizeBytes)
    }

    @discardableResult
    public func ensureDataDiskIfNeeded(sizeBytes: Int64) throws -> VMAssetManifest {
        var manifest = try loadManifest()
        let dataDiskPath = manifest.dataDiskPath ?? paths.vmDirectory.appendingPathComponent("data.raw").path
        try createRawDiskIfNeeded(url: URL(fileURLWithPath: dataDiskPath), sizeBytes: sizeBytes)
        guard manifest.dataDiskPath != dataDiskPath else {
            return manifest
        }
        manifest.dataDiskPath = dataDiskPath
        try saveManifest(manifest)
        return manifest
    }

    public func status(state: VMRunState = .stopped, message: String = "VM configured") -> VMRuntimeStatus {
        do {
            let manifest = try loadManifest()
            return manifest.runtimeStatus(state: state, message: message, manifestPath: paths.vmManifest.path)
        } catch {
            return VMRuntimeStatus(
                state: .unconfigured,
                configured: false,
                manifestPath: paths.vmManifest.path,
                dockerSocketPath: paths.dockerSocket.path,
                message: String(describing: error)
            )
        }
    }

    public func initializeFromLocalKernel(
        name: String = "custom-linux",
        kernelPath: String,
        initialRamdiskPath: String?,
        kernelCommandLine: String?,
        rootDiskSizeBytes: Int64 = 2 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        swapDiskSizeBytes: Int64 = 1024 * 1024 * 1024,
        source: String = "local"
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        guard FileManager.default.fileExists(atPath: kernelPath) else {
            throw ConjetError.filesystem("kernel does not exist at \(kernelPath)")
        }
        if let initialRamdiskPath, !FileManager.default.fileExists(atPath: initialRamdiskPath) {
            throw ConjetError.filesystem("initrd does not exist at \(initialRamdiskPath)")
        }

        let rootDisk = paths.vmDirectory.appendingPathComponent("root.raw")
        let dataDisk = paths.vmDirectory.appendingPathComponent("data.raw")
        let swapDisk = paths.vmDirectory.appendingPathComponent("swap.raw")
        try createRawDiskIfNeeded(url: rootDisk, sizeBytes: rootDiskSizeBytes)
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
        try createRawDiskIfNeeded(url: swapDisk, sizeBytes: swapDiskSizeBytes)
        try ensureFile(paths.serialLog)

        let manifest = VMAssetManifest(
            name: name,
            architecture: HostCapabilities.detect().architecture,
            bootLoaderKind: try detectBootLoaderKind(kernelURL: URL(fileURLWithPath: kernelPath)),
            kernelPath: URL(fileURLWithPath: kernelPath).standardizedFileURL.path,
            initialRamdiskPath: initialRamdiskPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            modloopPath: nil,
            rootDiskPath: rootDisk.path,
            dataDiskPath: dataDisk.path,
            swapDiskPath: swapDisk.path,
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: kernelCommandLine ?? defaultKernelCommandLine(),
            source: source
        )
        try saveManifest(manifest)
        return manifest
    }

    public func importPhase9NetworkProofBundle(
        manifestPath: String,
        kernelCommandLine: String? = nil,
        rootDiskSizeBytes: Int64 = 2 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        swapDiskSizeBytes: Int64 = 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ConjetError.filesystem("Phase 9 network-proof bundle manifest is missing: \(manifestURL.path)")
        }
        let bundleData = try Data(contentsOf: manifestURL)
        let bundle = try ConjetJSON.decoder().decode(Phase9NetworkProofAssetBundleManifest.self, from: bundleData)
        guard bundle.schemaVersion == 1 else {
            throw ConjetError.invalidArgument(
                "unsupported Phase 9 network-proof bundle schema version \(bundle.schemaVersion)"
            )
        }
        let architecture = bundle.architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard architecture == "arm64" || architecture == "aarch64" else {
            throw ConjetError.unavailable(
                "Phase 9 network-proof bundle must be arm64/aarch64, got '\(bundle.architecture)'"
            )
        }
        guard (1...65535).contains(bundle.guestServicePort) else {
            throw ConjetError.invalidArgument("Phase 9 network-proof bundle guestServicePort must be 1...65535")
        }
        let bundleName = bundle.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleName.isEmpty else {
            throw ConjetError.invalidArgument("Phase 9 network-proof bundle name must not be empty")
        }
        guard !bundle.proofURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConjetError.invalidArgument("Phase 9 network-proof bundle proofURL must not be empty")
        }

        let kernel = try phase9BundleAssetURL(bundle.kernelImage, relativeTo: manifestURL, field: "kernelImage")
        let busybox = try phase9BundleAssetURL(bundle.busybox, relativeTo: manifestURL, field: "busybox")
        let initramfs = try phase9BundleAssetURL(bundle.initramfs, relativeTo: manifestURL, field: "initramfs")
        try verifySHA256(kernel, expectedHex: bundle.kernelImageSha256, label: "kernelImage")
        let kernelBuildManifest = try verifyOptionalPhase9BundleAsset(
            bundle.kernelBuildManifest,
            expectedHex: bundle.kernelBuildManifestSha256,
            relativeTo: manifestURL,
            field: "kernelBuildManifest"
        )
        if let kernelBuildManifest {
            try validatePhase9KernelBuildManifest(
                kernelBuildManifest,
                expectedKernelImageSha256: bundle.kernelImageSha256
            )
        }
        try verifySHA256(busybox, expectedHex: bundle.busyboxSha256, label: "busybox")
        try verifySHA256(initramfs, expectedHex: bundle.initramfsSha256, label: "initramfs")
        try InitramfsBuilder.validateStaticArm64LinuxELF(
            Data(contentsOf: busybox),
            sourceDescription: "static ARM64 Linux BusyBox"
        )
        try Self.validateArm64LinuxImage(kernel)
        try validatePhase9NetworkProofInitramfs(initramfs)

        let manifest = try initializeFromLocalKernel(
            name: bundleName,
            kernelPath: kernel.path,
            initialRamdiskPath: initramfs.path,
            kernelCommandLine: kernelCommandLine,
            rootDiskSizeBytes: rootDiskSizeBytes,
            dataDiskSizeBytes: dataDiskSizeBytes,
            swapDiskSizeBytes: swapDiskSizeBytes,
            source: "phase9-network-proof-bundle:\(manifestURL.path)"
        )
        try validatePhase9NetworkProofAssets(manifest)
        return manifest
    }

    public func importDirectKernelRootDisk(
        kernelPath: String,
        rootDiskPath: String,
        name: String? = nil,
        initialRamdiskPath: String? = nil,
        kernelCommandLine: String? = nil,
        force: Bool = false,
        dataDiskSizeBytes: Int64? = 20 * 1024 * 1024 * 1024,
        swapDiskSizeBytes: Int64? = 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        let kernelURL = URL(fileURLWithPath: kernelPath).standardizedFileURL
        let sourceRootDisk = URL(fileURLWithPath: rootDiskPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: kernelURL.path) else {
            throw ConjetError.filesystem("kernel does not exist at \(kernelURL.path)")
        }
        guard FileManager.default.fileExists(atPath: sourceRootDisk.path) else {
            throw ConjetError.filesystem("root disk image does not exist at \(sourceRootDisk.path)")
        }
        if let initialRamdiskPath, !FileManager.default.fileExists(atPath: initialRamdiskPath) {
            throw ConjetError.filesystem("initrd does not exist at \(initialRamdiskPath)")
        }
        let bootLoaderKind = try detectBootLoaderKind(kernelURL: kernelURL)
        guard bootLoaderKind == .linuxKernel else {
            throw ConjetError.unavailable(
                "Jetstream direct rootfs import requires an uncompressed ARM64 Linux Image; got \(bootLoaderKind.rawValue)"
            )
        }
        try Self.validateArm64LinuxImage(kernelURL, context: "Jetstream direct rootfs import")

        let rootDisk = paths.vmDirectory.appendingPathComponent("root.raw")
        let dataDisk = paths.vmDirectory.appendingPathComponent("data.raw")
        let swapDisk = paths.vmDirectory.appendingPathComponent("swap.raw")
        try importDiskImage(source: sourceRootDisk, destination: rootDisk, force: force)
        let dataDiskPath: String?
        if let dataDiskSizeBytes {
            try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
            dataDiskPath = dataDisk.path
        } else {
            dataDiskPath = nil
        }
        let swapDiskPath: String?
        if let swapDiskSizeBytes {
            try createRawDiskIfNeeded(url: swapDisk, sizeBytes: swapDiskSizeBytes)
            swapDiskPath = swapDisk.path
        } else {
            swapDiskPath = nil
        }
        try ensureFile(paths.serialLog)

        let manifest = VMAssetManifest(
            name: name ?? sourceRootDisk.deletingPathExtension().lastPathComponent,
            architecture: HostCapabilities.detect().architecture,
            bootLoaderKind: .linuxKernel,
            kernelPath: kernelURL.path,
            initialRamdiskPath: initialRamdiskPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            modloopPath: nil,
            rootDiskPath: rootDisk.path,
            dataDiskPath: dataDiskPath,
            swapDiskPath: swapDiskPath,
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: kernelCommandLine ?? defaultDirectRootDiskKernelCommandLine(),
            source: "direct-rootfs:\(sourceRootDisk.path)"
        )
        try saveManifest(manifest)
        return manifest
    }

    public func importEFIBootDisk(
        sourcePath: String,
        name: String? = nil,
        force: Bool = false,
        cloudInitSeedPath: String? = nil,
        bootDiskMinimumSizeBytes: Int64? = nil,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        swapDiskSizeBytes: Int64 = 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ConjetError.filesystem("boot disk image does not exist at \(sourceURL.path)")
        }

        let bootDisk = paths.vmDirectory.appendingPathComponent("efi-boot.raw")
        let dataDisk = paths.vmDirectory.appendingPathComponent("data.raw")
        let swapDisk = paths.vmDirectory.appendingPathComponent("swap.raw")
        let variableStore = paths.vmDirectory.appendingPathComponent("efi-variable-store.bin")

        try importDiskImage(source: sourceURL, destination: bootDisk, force: force)
        if let bootDiskMinimumSizeBytes {
            try expandRawDiskIfNeeded(url: bootDisk, sizeBytes: bootDiskMinimumSizeBytes)
        }
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
        try createRawDiskIfNeeded(url: swapDisk, sizeBytes: swapDiskSizeBytes)
        try ensureFile(paths.serialLog)

        let manifest = VMAssetManifest(
            name: name ?? sourceURL.deletingPathExtension().lastPathComponent,
            architecture: HostCapabilities.detect().architecture,
            bootLoaderKind: .efiDisk,
            bootDiskPath: bootDisk.path,
            efiVariableStorePath: variableStore.path,
            cloudInitSeedPath: cloudInitSeedPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            kernelPath: "",
            initialRamdiskPath: nil,
            modloopPath: nil,
            rootDiskPath: bootDisk.path,
            dataDiskPath: dataDisk.path,
            swapDiskPath: swapDisk.path,
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: "",
            source: sourceURL.path
        )
        try saveManifest(manifest)
        return manifest
    }

    public func fetchAlpineNetboot(
        source: AlpineNetbootSource = AlpineNetbootSource(),
        force: Bool = false,
        rootDiskSizeBytes: Int64 = 2 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        swapDiskSizeBytes: Int64 = 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        let kernel = paths.vmDirectory.appendingPathComponent("vmlinuz-virt")
        let initrd = paths.vmDirectory.appendingPathComponent("initramfs-virt")
        let modloop = paths.bootstrapShare.appendingPathComponent("modloop-virt")

        try download(source.kernelURL, to: kernel, force: force)
        try download(source.initialRamdiskURL, to: initrd, force: force)
        try download(source.modloopURL, to: modloop, force: force)

        let rootDisk = paths.vmDirectory.appendingPathComponent("root.raw")
        let dataDisk = paths.vmDirectory.appendingPathComponent("data.raw")
        let swapDisk = paths.vmDirectory.appendingPathComponent("swap.raw")
        try createRawDiskIfNeeded(url: rootDisk, sizeBytes: rootDiskSizeBytes)
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
        try createRawDiskIfNeeded(url: swapDisk, sizeBytes: swapDiskSizeBytes)
        try ensureFile(paths.serialLog)

        let commandLine = [
            "console=ttyAMA0",
            "earlycon=pl011,0x09000000",
            "modules=loop,squashfs,sd-mod,virtio_blk,virtio_net,virtio_pci,virtio_console,virtiofs",
            "ip=dhcp",
            "alpine_repo=\(source.repositoryURL)",
            "modloop=\(source.modloopURL)"
        ].joined(separator: " ")

        let manifest = VMAssetManifest(
            name: "alpine-netboot",
            architecture: "aarch64",
            bootLoaderKind: try detectBootLoaderKind(kernelURL: kernel),
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            modloopPath: modloop.path,
            rootDiskPath: rootDisk.path,
            dataDiskPath: dataDisk.path,
            swapDiskPath: swapDisk.path,
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: commandLine,
            source: source.baseURL
        )
        try saveManifest(manifest)
        return manifest
    }

    public func fetchFedoraPXE(
        source: FedoraPXESource = FedoraPXESource(),
        force: Bool = false,
        rootDiskSizeBytes: Int64 = 4 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        swapDiskSizeBytes: Int64 = 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        let kernel = paths.vmDirectory.appendingPathComponent("fedora-\(source.release)-vmlinuz")
        let initrd = paths.vmDirectory.appendingPathComponent("fedora-\(source.release)-initrd.img")

        try download(source.kernelURL, to: kernel, force: force)
        try download(source.initialRamdiskURL, to: initrd, force: force)

        let rootDisk = paths.vmDirectory.appendingPathComponent("root.raw")
        let dataDisk = paths.vmDirectory.appendingPathComponent("data.raw")
        let swapDisk = paths.vmDirectory.appendingPathComponent("swap.raw")
        try createRawDiskIfNeeded(url: rootDisk, sizeBytes: rootDiskSizeBytes)
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
        try createRawDiskIfNeeded(url: swapDisk, sizeBytes: swapDiskSizeBytes)
        try ensureFile(paths.serialLog)

        let commandLine = [
            "console=ttyAMA0",
            "earlycon=pl011,0x09000000",
            "inst.text",
            "inst.repo=\(source.repositoryURL)",
            "ip=dhcp"
        ].joined(separator: " ")

        let manifest = VMAssetManifest(
            name: "fedora-\(source.release)-pxe",
            architecture: "aarch64",
            bootLoaderKind: try detectBootLoaderKind(kernelURL: kernel),
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            modloopPath: nil,
            rootDiskPath: rootDisk.path,
            dataDiskPath: dataDisk.path,
            swapDiskPath: swapDisk.path,
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: commandLine,
            source: source.baseURL
        )
        try saveManifest(manifest)
        return manifest
    }

    public func fetchDebianInstaller(
        source: DebianInstallerSource = DebianInstallerSource(),
        force: Bool = false,
        rootDiskSizeBytes: Int64 = 4 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        swapDiskSizeBytes: Int64 = 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        let kernel = paths.vmDirectory.appendingPathComponent("debian-\(source.suite)-linux")
        let initrd = paths.vmDirectory.appendingPathComponent("debian-\(source.suite)-initrd.gz")

        try download(source.kernelURL, to: kernel, force: force)
        try download(source.initialRamdiskURL, to: initrd, force: force)

        let rootDisk = paths.vmDirectory.appendingPathComponent("root.raw")
        let dataDisk = paths.vmDirectory.appendingPathComponent("data.raw")
        let swapDisk = paths.vmDirectory.appendingPathComponent("swap.raw")
        try createRawDiskIfNeeded(url: rootDisk, sizeBytes: rootDiskSizeBytes)
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
        try createRawDiskIfNeeded(url: swapDisk, sizeBytes: swapDiskSizeBytes)
        try ensureFile(paths.serialLog)

        let commandLine = [
            "console=ttyAMA0",
            "earlycon=pl011,0x09000000",
            "DEBIAN_FRONTEND=text",
            "priority=low"
        ].joined(separator: " ")

        let manifest = VMAssetManifest(
            name: "debian-\(source.suite)-installer",
            architecture: "aarch64",
            bootLoaderKind: try detectBootLoaderKind(kernelURL: kernel),
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            modloopPath: nil,
            rootDiskPath: rootDisk.path,
            dataDiskPath: dataDisk.path,
            swapDiskPath: swapDisk.path,
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: commandLine,
            source: source.baseURL
        )
        try saveManifest(manifest)
        return manifest
    }

    public func validateManifestFiles(_ manifest: VMAssetManifest) throws {
        var required = [
            manifest.rootDiskPath,
            manifest.bootstrapSharePath,
            manifest.serialLogPath
        ]
        if let dataDiskPath = manifest.dataDiskPath {
            required.append(dataDiskPath)
        }
        if let swapDiskPath = manifest.swapDiskPath {
            required.append(swapDiskPath)
        }
        switch manifest.bootLoaderKind {
        case .linuxKernel, .linuxArm64CompressedEfiZboot:
            required.append(manifest.kernelPath)
        case .efiDisk:
            required.append(manifest.bootDiskPath ?? manifest.rootDiskPath)
        }
        for path in required where !FileManager.default.fileExists(atPath: path) {
            throw ConjetError.filesystem("required VM asset is missing: \(path)")
        }
        if let initialRamdiskPath = manifest.initialRamdiskPath,
           !FileManager.default.fileExists(atPath: initialRamdiskPath) {
            throw ConjetError.filesystem("required VM initrd is missing: \(initialRamdiskPath)")
        }
        if let cloudInitSeedPath = manifest.cloudInitSeedPath,
           !FileManager.default.fileExists(atPath: cloudInitSeedPath) {
            throw ConjetError.filesystem("required cloud-init seed image is missing: \(cloudInitSeedPath)")
        }
    }

    public func validateManifest(_ manifest: VMAssetManifest) throws {
        try validateManifestFiles(manifest)
        try validateBootCompatibility(manifest)
    }

    public func validateJetstreamDirectKernelBootAssets(_ manifest: VMAssetManifest) throws {
        try Self.validateJetstreamDirectKernelBootAssets(manifest)
    }

    public static func validateJetstreamDirectKernelBootAssets(
        _ manifest: VMAssetManifest,
        fileManager: FileManager = .default
    ) throws {
        guard manifest.bootLoaderKind == .linuxKernel else {
            throw ConjetError.unavailable(
                "Jetstream direct-kernel boot requires an uncompressed ARM64 Linux Image; got \(manifest.bootLoaderKind.rawValue)"
            )
        }
        let kernelPath = manifest.kernelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kernelPath.isEmpty, fileManager.fileExists(atPath: kernelPath) else {
            throw ConjetError.filesystem("Jetstream direct-kernel boot kernel is missing: \(kernelPath)")
        }
        try validateArm64LinuxImage(
            URL(fileURLWithPath: kernelPath),
            context: "Jetstream direct-kernel boot"
        )
        if let initialRamdiskPath = manifest.initialRamdiskPath,
           !initialRamdiskPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !fileManager.fileExists(atPath: initialRamdiskPath) {
            throw ConjetError.filesystem(
                "Jetstream direct-kernel boot initrd is missing: \(initialRamdiskPath)"
            )
        }
        let bootsFromInitrd = manifest.initialRamdiskPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !bootsFromInitrd {
            try validateDirectKernelRootFilesystem(manifest)
        }
    }

    private static func validateDirectKernelRootFilesystem(_ manifest: VMAssetManifest) throws {
        guard let rootDevice = linuxRootDevice(from: manifest.kernelCommandLine),
              rootDevice.hasPrefix("/dev/vda") else {
            return
        }
        let rootDiskPath = manifest.rootDiskPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootDiskPath.isEmpty else {
            throw ConjetError.filesystem("Jetstream direct-kernel boot root disk is missing")
        }
        guard FileManager.default.fileExists(atPath: rootDiskPath) else {
            throw ConjetError.filesystem("Jetstream direct-kernel boot root disk is missing: \(rootDiskPath)")
        }
        let rootOffset: UInt64
        if rootDevice == "/dev/vda" {
            rootOffset = 0
        } else if let partition = Int(rootDevice.dropFirst("/dev/vda".count)), partition > 0 {
            guard let partitionOffset = try gptPartitionByteOffset(diskPath: rootDiskPath, partition: partition) else {
                throw ConjetError.unavailable(
                    "Jetstream direct-kernel boot root device \(rootDevice) was not found in \(rootDiskPath)"
                )
            }
            rootOffset = partitionOffset
        } else {
            return
        }
        guard try diskRegionHasLinuxRootFilesystem(diskPath: rootDiskPath, byteOffset: rootOffset) else {
            throw ConjetError.unavailable(
                "Jetstream direct-kernel boot root device \(rootDevice) in \(rootDiskPath) does not contain a supported Linux root filesystem; re-import or update the Conjet Core image"
            )
        }
    }

    private static func linuxRootDevice(from commandLine: String) -> String? {
        for token in commandLine.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard token.hasPrefix("root=") else { continue }
            let value = token.dropFirst("root=".count)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                return String(value.dropFirst().dropLast())
            }
            return String(value)
        }
        return nil
    }

    private static func gptPartitionByteOffset(diskPath: String, partition: Int) throws -> UInt64? {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: diskPath))
        defer { try? handle.close() }
        try handle.seek(toOffset: 512)
        let header = handle.readData(ofLength: 92)
        guard header.count >= 92, Data(header.prefix(8)) == Data("EFI PART".utf8) else {
            return nil
        }
        let partitionEntryLBA = header.uint64LE(at: 72)
        let partitionEntryCount = Int(header.uint32LE(at: 80))
        let partitionEntrySize = Int(header.uint32LE(at: 84))
        guard partition > 0,
              partition <= partitionEntryCount,
              partitionEntrySize >= 128 else {
            return nil
        }
        let entryOffset = partitionEntryLBA * 512 + UInt64(partition - 1) * UInt64(partitionEntrySize)
        try handle.seek(toOffset: entryOffset)
        let entry = handle.readData(ofLength: partitionEntrySize)
        guard entry.count >= 48,
              !entry.prefix(16).allSatisfy({ $0 == 0 }) else {
            return nil
        }
        let firstLBA = entry.uint64LE(at: 32)
        return firstLBA * 512
    }

    private static func diskRegionHasLinuxRootFilesystem(diskPath: String, byteOffset: UInt64) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: diskPath))
        defer { try? handle.close() }
        try handle.seek(toOffset: byteOffset)
        let firstBlock = handle.readData(ofLength: 4)
        if firstBlock == Data([0x68, 0x73, 0x71, 0x73]) { // squashfs "hsqs"
            return true
        }
        try handle.seek(toOffset: byteOffset + 1024 + 0x38)
        let extMagic = handle.readData(ofLength: 2)
        if extMagic == Data([0x53, 0xef]) {
            return true
        }
        return false
    }

    public func validateBootCompatibility(_ manifest: VMAssetManifest) throws {
        switch manifest.bootLoaderKind {
        case .linuxKernel:
            return
        case .efiDisk:
            if manifest.bootDiskPath?.isEmpty == false || !manifest.rootDiskPath.isEmpty {
                return
            }
            throw ConjetError.unavailable("EFI disk boot requires bootDiskPath or rootDiskPath in the VM manifest")
        case .linuxArm64CompressedEfiZboot:
            throw ConjetError.unavailable(
                """
                VM asset '\(manifest.name)' uses a compressed ARM64 EFI zboot kernel at \(manifest.kernelPath). \
                This standalone zboot file is not a bootable disk image. Use 'conjet vm init --kernel PATH' with \
                a direct ARM64 Linux Image/vmlinux kernel, or import a full EFI-bootable distro/cloud disk with \
                'conjet vm import-efi-disk --image PATH'.
                """
            )
        }
    }

    public func validatePhase9NetworkProofAssets(_ manifest: VMAssetManifest) throws {
        try validateManifest(manifest)
        try validateJetstreamDirectKernelBootAssets(manifest)
        guard let initialRamdiskPath = manifest.initialRamdiskPath,
              !initialRamdiskPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConjetError.unavailable(
                "Phase 9 network proof requires a network-proof initramfs; build it with 'conjet vm build-initramfs --network-proof'"
            )
        }
        try validatePhase9NetworkProofInitramfs(URL(fileURLWithPath: initialRamdiskPath))
    }

    private func validatePhase9NetworkProofInitramfs(_ url: URL) throws {
        let initramfsData = try decodedGzipFile(url)
        let requiredMarkers = [
            "conjet-network-proof-initramfs",
            "CONJET_NETWORK_PROOF_BEGIN",
            "CONJET_NETWORK_OUTBOUND_TCP_OK",
            "CONJET_NETWORK_GUEST_SERVICE_READY",
            "CONJET_NETWORK_FORWARDED_PORT_OK"
        ]
        for marker in requiredMarkers {
            guard initramfsData.range(of: Data(marker.utf8)) != nil else {
                throw ConjetError.unavailable(
                    "Phase 9 network-proof initramfs is missing required marker '\(marker)'"
                )
            }
        }
        guard let busyboxData = try newcEntryData(named: "bin/busybox", in: initramfsData) else {
            throw ConjetError.unavailable(
                "Phase 9 network-proof initramfs is missing required static ARM64 Linux BusyBox at bin/busybox"
            )
        }
        guard let shellLink = try newcEntryData(named: "bin/sh", in: initramfsData),
              shellLink == Data("busybox".utf8) || shellLink == Data("/bin/busybox".utf8) else {
            throw ConjetError.unavailable(
                "Phase 9 network-proof initramfs is missing required BusyBox shell applet link at bin/sh"
            )
        }
        try InitramfsBuilder.validateStaticArm64LinuxELF(
            busyboxData,
            sourceDescription: "static ARM64 Linux BusyBox"
        )
    }

    private static func validateArm64LinuxImage(
        _ url: URL,
        context: String = "Phase 9 network proof"
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 64) ?? Data()
        guard header.count >= 64 else {
            throw ConjetError.unavailable(
                "\(context) requires an uncompressed ARM64 Linux Image; kernel header is too small"
            )
        }
        let magicOffset = 0x38
        let magic = UInt32(header[magicOffset])
            | (UInt32(header[magicOffset + 1]) << 8)
            | (UInt32(header[magicOffset + 2]) << 16)
            | (UInt32(header[magicOffset + 3]) << 24)
        guard magic == 0x644d_5241 else {
            throw ConjetError.unavailable(
                "\(context) requires an uncompressed ARM64 Linux Image with ARM64 Image header magic"
            )
        }
    }

    private func newcEntryData(named targetName: String, in archive: Data) throws -> Data? {
        var offset = 0
        while offset + 110 <= archive.count {
            let header = archive.subdata(in: offset..<(offset + 110))
            guard String(data: header.subdata(in: 0..<6), encoding: .ascii) == "070701" else {
                throw ConjetError.unavailable("Phase 9 network-proof initramfs is not a valid newc archive")
            }
            let fileSize = try newcHexField(header, 54)
            let nameSize = try newcHexField(header, 94)
            guard nameSize > 0 else {
                throw ConjetError.unavailable("Phase 9 network-proof initramfs has an invalid newc entry name")
            }
            let nameStart = offset + 110
            let nameEnd = nameStart + nameSize - 1
            guard nameEnd <= archive.count else {
                throw ConjetError.unavailable("Phase 9 network-proof initramfs newc entry name is truncated")
            }
            let nameData = archive.subdata(in: nameStart..<nameEnd)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ConjetError.unavailable("Phase 9 network-proof initramfs contains a non-UTF8 newc entry name")
            }

            offset = align4(nameStart + nameSize)
            guard offset <= archive.count,
                  fileSize <= archive.count - offset else {
                throw ConjetError.unavailable("Phase 9 network-proof initramfs newc entry data is truncated")
            }
            let entryData = archive.subdata(in: offset..<(offset + fileSize))
            if name == targetName {
                return entryData
            }
            offset = align4(offset + fileSize)
            if name == "TRAILER!!!" {
                break
            }
        }
        return nil
    }

    private func newcHexField(_ header: Data, _ offset: Int) throws -> Int {
        let field = header.subdata(in: offset..<(offset + 8))
        guard let string = String(data: field, encoding: .ascii),
              let value = Int(string, radix: 16) else {
            throw ConjetError.unavailable("Phase 9 network-proof initramfs has an invalid newc header")
        }
        return value
    }

    private func align4(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder == 0 ? value : value + (4 - remainder)
    }

    private func phase9BundleAssetURL(_ path: String, relativeTo manifestURL: URL, field: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConjetError.invalidArgument("Phase 9 network-proof bundle field '\(field)' is empty")
        }
        let url = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : manifestURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw ConjetError.filesystem(
                "Phase 9 network-proof bundle is missing required asset '\(field)' at \(standardized.path)"
            )
        }
        return standardized
    }

    private func verifyOptionalPhase9BundleAsset(
        _ rawPath: String?,
        expectedHex: String?,
        relativeTo manifestURL: URL,
        field: String
    ) throws -> URL? {
        let trimmedPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedHash = expectedHex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedPath.isEmpty || !trimmedHash.isEmpty else {
            return nil
        }
        guard !trimmedPath.isEmpty, !trimmedHash.isEmpty else {
            throw ConjetError.invalidArgument(
                "Phase 9 network-proof bundle \(field) and \(field)Sha256 must be provided together"
            )
        }
        let asset = try phase9BundleAssetURL(trimmedPath, relativeTo: manifestURL, field: field)
        try verifySHA256(asset, expectedHex: trimmedHash, label: field)
        return asset
    }

    private func validatePhase9KernelBuildManifest(
        _ url: URL,
        expectedKernelImageSha256: String
    ) throws {
        let data = try Data(contentsOf: url)
        let manifest = try ConjetJSON.decoder().decode(Phase9KernelBuildManifest.self, from: data)
        guard manifest.schemaVersion == 1 else {
            throw ConjetError.invalidArgument(
                "unsupported Phase 9 kernel build manifest schema version \(manifest.schemaVersion)"
            )
        }
        guard manifest.name.trimmingCharacters(in: .whitespacesAndNewlines) == "conjet-linux" else {
            throw ConjetError.unavailable("Phase 9 kernel build manifest must describe conjet-linux")
        }
        let architecture = manifest.architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard architecture == "arm64" || architecture == "aarch64" else {
            throw ConjetError.unavailable(
                "Phase 9 kernel build manifest must be arm64/aarch64, got '\(manifest.architecture)'"
            )
        }
        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConjetError.invalidArgument("Phase 9 kernel build manifest version must not be empty")
        }
        guard !manifest.image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConjetError.invalidArgument(
                "Phase 9 kernel build manifest image, config, and source fields must not be empty"
            )
        }

        let imageSha256 = try normalizedSHA256Hex(
            manifest.imageSha256,
            field: "kernelBuildManifest.imageSha256"
        )
        let expectedImageSha256 = try normalizedSHA256Hex(
            expectedKernelImageSha256,
            field: "kernelImageSha256"
        )
        guard imageSha256 == expectedImageSha256 else {
            throw ConjetError.unavailable(
                "Phase 9 kernel build manifest imageSha256 does not match the bundle kernelImageSha256"
            )
        }
        _ = try normalizedSHA256Hex(manifest.sourceSha256, field: "kernelBuildManifest.sourceSha256")
        if let configSha256 = manifest.configSha256 {
            _ = try normalizedSHA256Hex(configSha256, field: "kernelBuildManifest.configSha256")
        }
        if let systemMapSha256 = manifest.systemMapSha256 {
            _ = try normalizedSHA256Hex(systemMapSha256, field: "kernelBuildManifest.systemMapSha256")
        }
        if let vmlinuxSha256 = manifest.vmlinuxSha256 {
            _ = try normalizedSHA256Hex(vmlinuxSha256, field: "kernelBuildManifest.vmlinuxSha256")
        }

        let builtIns = Set(manifest.requiredBuiltIns)
        for option in Self.phase9RequiredKernelBuiltIns where !builtIns.contains(option) {
            throw ConjetError.unavailable(
                "Phase 9 kernel build manifest is missing required built-in kernel option \(option)"
            )
        }
    }

    private func verifySHA256(_ url: URL, expectedHex: String, label: String) throws {
        let expected = try normalizedSHA256Hex(expectedHex, field: "\(label)Sha256")
        let actual = try sha256Hex(of: url)
        guard actual == expected else {
            throw ConjetError.filesystem(
                "SHA-256 mismatch for Phase 9 network-proof bundle asset '\(label)' at \(url.path)"
            )
        }
    }

    private func normalizedSHA256Hex(_ rawValue: String, field: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hexDigits = Set("0123456789abcdef")
        guard value.count == 64,
              value.allSatisfy({ hexDigits.contains($0) }) else {
            throw ConjetError.invalidArgument(
                "Phase 9 network-proof bundle field '\(field)' must be a 64-character hex SHA-256"
            )
        }
        return value
    }

    private func sha256Hex(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    private func defaultKernelCommandLine() -> String {
        "console=ttyAMA0 earlycon=pl011,0x09000000 root=/dev/vda rw"
    }

    private func defaultDirectRootDiskKernelCommandLine() -> String {
        [
            "console=ttyAMA0",
            "earlycon=pl011,0x09000000",
            "root=/dev/vda1",
            "rw",
            "rootwait"
        ].joined(separator: " ")
    }

    private func download(_ url: String, to destination: URL, force: Bool) throws {
        if FileManager.default.fileExists(atPath: destination.path), !force {
            return
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).download")
        let result = try ProcessRunner.run("/usr/bin/curl", [
            "-fL",
            "--retry", "3",
            "--connect-timeout", "20",
            "-o", temporary.path,
            url
        ])
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func importDiskImage(source: URL, destination: URL, force: Bool) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            if force {
                try FileManager.default.removeItem(at: destination)
            } else {
                throw ConjetError.filesystem("disk image already exists at \(destination.path); pass --force to replace it")
            }
        }

        let preparedSource = try preparedDiskImageSource(source)
        defer {
            if preparedSource.removeAfterImport {
                try? FileManager.default.removeItem(at: preparedSource.url)
            }
        }

        if let format = try inspectedDiskImageFormat(source: preparedSource.url) {
            if format == "raw" {
                try FileManager.default.copyItem(at: preparedSource.url, to: destination)
                return
            }
            try convertDiskImage(source: preparedSource.url, destination: destination)
            return
        }

        if shouldTreatAsRawWithoutInspection(preparedSource.url) {
            try FileManager.default.copyItem(at: preparedSource.url, to: destination)
            return
        }

        try convertDiskImage(source: preparedSource.url, destination: destination)
    }

    private struct PreparedDiskImageSource {
        var url: URL
        var removeAfterImport: Bool
    }

    private func preparedDiskImageSource(_ source: URL) throws -> PreparedDiskImageSource {
        guard source.pathExtension.lowercased() == "gz" else {
            return PreparedDiskImageSource(url: source, removeAfterImport: false)
        }

        let decompressedName = source.deletingPathExtension().lastPathComponent
        let temporary = paths.vmDirectory
            .appendingPathComponent(".decompressed-\(UUID().uuidString)-\(decompressedName)")
        _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)

        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", source.path]
        process.standardOutput = output

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ConjetError.processFailed(
                executable: "/usr/bin/gzip",
                exitCode: process.terminationStatus,
                stderr: stderrText
            )
        }

        return PreparedDiskImageSource(url: temporary, removeAfterImport: true)
    }

    private func convertDiskImage(source: URL, destination: URL) throws {
        let qemuImg = try qemuImgPath()
        let result = try ProcessRunner.run(qemuImg, [
            "convert",
            "-O", "raw",
            source.path,
            destination.path
        ])
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    private struct QemuImageInfo: Decodable {
        var format: String?
    }

    private func inspectedDiskImageFormat(source: URL) throws -> String? {
        guard let qemuImg = try? qemuImgPath() else {
            return nil
        }
        let result = try ProcessRunner.run(qemuImg, [
            "info",
            "--output=json",
            source.path
        ])
        guard result.succeeded else {
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let info = try? JSONDecoder().decode(QemuImageInfo.self, from: data) else {
            return nil
        }
        return info.format
    }

    private func shouldTreatAsRawWithoutInspection(_ source: URL) -> Bool {
        let pathExtension = source.pathExtension.lowercased()
        return pathExtension == "raw" || pathExtension == "img"
    }

    private func qemuImgPath() throws -> String {
        for candidate in ["/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img", "/usr/bin/qemu-img"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw ConjetError.unavailable("qemu-img is required to import non-raw EFI boot disk images")
    }

    private func createRawDiskIfNeeded(url: URL, sizeBytes: Int64) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try expandRawDiskIfNeeded(url: url, sizeBytes: sizeBytes)
            return
        }
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ConjetError.filesystem("open(\(url.path)) failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else {
            throw ConjetError.filesystem("ftruncate(\(url.path)) failed: \(String(cString: strerror(errno)))")
        }
    }

    private func expandRawDiskIfNeeded(url: URL, sizeBytes: Int64) throws {
        let currentSize = try fileSize(url)
        guard currentSize < UInt64(sizeBytes) else {
            return
        }
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else {
            throw ConjetError.filesystem("open(\(url.path)) failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else {
            throw ConjetError.filesystem("ftruncate(\(url.path)) failed: \(String(cString: strerror(errno)))")
        }
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? UInt64 ?? 0
    }

    private func ensureFile(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    private func decodedGzipFile(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ConjetError.processFailed(
                executable: "/usr/bin/gzip",
                exitCode: process.terminationStatus,
                stderr: stderrText
            )
        }
        return data
    }

    private func detectBootLoaderKind(kernelURL: URL) throws -> VMBootLoaderKind {
        let handle = try FileHandle(forReadingFrom: kernelURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8) ?? Data()
        guard data.count >= 8 else {
            return .linuxKernel
        }
        let bytes = [UInt8](data.prefix(8))
        if bytes[0] == 0x4d, bytes[1] == 0x5a,
           bytes[4] == 0x7a, bytes[5] == 0x69, bytes[6] == 0x6d, bytes[7] == 0x67 {
            return .linuxArm64CompressedEfiZboot
        }
        return .linuxKernel
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        return UInt32(self[startIndex + offset])
            | UInt32(self[startIndex + offset + 1]) << 8
            | UInt32(self[startIndex + offset + 2]) << 16
            | UInt32(self[startIndex + offset + 3]) << 24
    }

    func uint64LE(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && offset + 8 <= count)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[startIndex + offset + index]) << UInt64(index * 8)
        }
        return value
    }
}

private extension VMAssetManifest {
    enum CodingKeys: String, CodingKey {
        case version
        case name
        case architecture
        case bootLoaderKind
        case bootDiskPath
        case efiVariableStorePath
        case cloudInitSeedPath
        case kernelPath
        case initialRamdiskPath
        case modloopPath
        case rootDiskPath
        case dataDiskPath
        case swapDiskPath
        case bootstrapSharePath
        case serialLogPath
        case dockerSocketPath
        case kernelCommandLine
        case createdAt
        case source
    }
}

public extension VMAssetManifest {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.name = try container.decode(String.self, forKey: .name)
        self.architecture = try container.decode(String.self, forKey: .architecture)
        self.bootLoaderKind = try container.decodeIfPresent(VMBootLoaderKind.self, forKey: .bootLoaderKind) ?? .linuxKernel
        self.bootDiskPath = try container.decodeIfPresent(String.self, forKey: .bootDiskPath)
        self.efiVariableStorePath = try container.decodeIfPresent(String.self, forKey: .efiVariableStorePath)
        self.cloudInitSeedPath = try container.decodeIfPresent(String.self, forKey: .cloudInitSeedPath)
        self.kernelPath = try container.decode(String.self, forKey: .kernelPath)
        self.initialRamdiskPath = try container.decodeIfPresent(String.self, forKey: .initialRamdiskPath)
        self.modloopPath = try container.decodeIfPresent(String.self, forKey: .modloopPath)
        self.rootDiskPath = try container.decode(String.self, forKey: .rootDiskPath)
        self.dataDiskPath = try container.decodeIfPresent(String.self, forKey: .dataDiskPath)
        self.swapDiskPath = try container.decodeIfPresent(String.self, forKey: .swapDiskPath)
        self.bootstrapSharePath = try container.decode(String.self, forKey: .bootstrapSharePath)
        self.serialLogPath = try container.decode(String.self, forKey: .serialLogPath)
        self.dockerSocketPath = try container.decode(String.self, forKey: .dockerSocketPath)
        self.kernelCommandLine = try container.decode(String.self, forKey: .kernelCommandLine)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.source = try container.decode(String.self, forKey: .source)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(bootLoaderKind, forKey: .bootLoaderKind)
        try container.encodeIfPresent(bootDiskPath, forKey: .bootDiskPath)
        try container.encodeIfPresent(efiVariableStorePath, forKey: .efiVariableStorePath)
        try container.encodeIfPresent(cloudInitSeedPath, forKey: .cloudInitSeedPath)
        try container.encode(kernelPath, forKey: .kernelPath)
        try container.encodeIfPresent(initialRamdiskPath, forKey: .initialRamdiskPath)
        try container.encodeIfPresent(modloopPath, forKey: .modloopPath)
        try container.encode(rootDiskPath, forKey: .rootDiskPath)
        try container.encodeIfPresent(dataDiskPath, forKey: .dataDiskPath)
        try container.encodeIfPresent(swapDiskPath, forKey: .swapDiskPath)
        try container.encode(bootstrapSharePath, forKey: .bootstrapSharePath)
        try container.encode(serialLogPath, forKey: .serialLogPath)
        try container.encode(dockerSocketPath, forKey: .dockerSocketPath)
        try container.encode(kernelCommandLine, forKey: .kernelCommandLine)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(source, forKey: .source)
    }
}

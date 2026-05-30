import ConjetCore
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
    public var dataDiskPath: String
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
        dataDiskPath: String,
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

public struct UbuntuCloudImageSource: Codable, Equatable, Sendable {
    public var release: String
    public var baseURL: String

    public init(
        release: String = "noble",
        baseURL: String? = nil
    ) {
        self.release = release
        self.baseURL = baseURL ?? "https://cloud-images.ubuntu.com/\(release)/current"
    }

    public var imageURL: String { "\(baseURL)/\(release)-server-cloudimg-arm64.img" }
}

public struct VMImageStore: Sendable {
    public var paths: ConjetPaths

    public init(paths: ConjetPaths = .default()) {
        self.paths = paths
    }

    public func manifestExists() -> Bool {
        FileManager.default.fileExists(atPath: paths.vmManifest.path)
    }

    public func loadManifest() throws -> VMAssetManifest {
        guard manifestExists() else {
            throw ConjetError.unavailable("VM is not configured; run 'conjet start' to fetch and import the latest Conjet-core image")
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
        try expandRawDiskIfNeeded(url: URL(fileURLWithPath: manifest.dataDiskPath), sizeBytes: sizeBytes)
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
        kernelPath: String,
        initialRamdiskPath: String?,
        kernelCommandLine: String?,
        rootDiskSizeBytes: Int64 = 2 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024
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
        try createRawDiskIfNeeded(url: rootDisk, sizeBytes: rootDiskSizeBytes)
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
        try ensureFile(paths.serialLog)

        let manifest = VMAssetManifest(
            name: "custom-linux",
            architecture: HostCapabilities.detect().architecture,
            bootLoaderKind: try detectBootLoaderKind(kernelURL: URL(fileURLWithPath: kernelPath)),
            kernelPath: URL(fileURLWithPath: kernelPath).standardizedFileURL.path,
            initialRamdiskPath: initialRamdiskPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            modloopPath: nil,
            rootDiskPath: rootDisk.path,
            dataDiskPath: dataDisk.path,
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: kernelCommandLine ?? defaultKernelCommandLine(),
            source: "local"
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
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ConjetError.filesystem("boot disk image does not exist at \(sourceURL.path)")
        }

        let bootDisk = paths.vmDirectory.appendingPathComponent("efi-boot.raw")
        let dataDisk = paths.vmDirectory.appendingPathComponent("data.raw")
        let variableStore = paths.vmDirectory.appendingPathComponent("efi-variable-store.bin")

        try importDiskImage(source: sourceURL, destination: bootDisk, force: force)
        if let bootDiskMinimumSizeBytes {
            try expandRawDiskIfNeeded(url: bootDisk, sizeBytes: bootDiskMinimumSizeBytes)
        }
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
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
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: "",
            source: sourceURL.path
        )
        try saveManifest(manifest)
        return manifest
    }

    public func fetchUbuntuCloudImage(
        source: UbuntuCloudImageSource = UbuntuCloudImageSource(),
        force: Bool = false,
        cloudInitSeedPath: String? = nil,
        bootDiskMinimumSizeBytes: Int64? = 16 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        let image = paths.vmDirectory.appendingPathComponent("ubuntu-\(source.release)-server-cloudimg-arm64.img")
        try download(source.imageURL, to: image, force: force)
        return try importEFIBootDisk(
            sourcePath: image.path,
            name: "ubuntu-\(source.release)-cloudimg-arm64",
            force: force,
            cloudInitSeedPath: cloudInitSeedPath,
            bootDiskMinimumSizeBytes: bootDiskMinimumSizeBytes,
            dataDiskSizeBytes: dataDiskSizeBytes
        )
    }

    public func fetchAlpineNetboot(
        source: AlpineNetbootSource = AlpineNetbootSource(),
        force: Bool = false,
        rootDiskSizeBytes: Int64 = 2 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024
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
        try createRawDiskIfNeeded(url: rootDisk, sizeBytes: rootDiskSizeBytes)
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
        try ensureFile(paths.serialLog)

        let commandLine = [
            "console=hvc0",
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
        dataDiskSizeBytes: Int64 = 20 * 1024 * 1024 * 1024
    ) throws -> VMAssetManifest {
        try paths.ensureBaseDirectories()
        let kernel = paths.vmDirectory.appendingPathComponent("fedora-\(source.release)-vmlinuz")
        let initrd = paths.vmDirectory.appendingPathComponent("fedora-\(source.release)-initrd.img")

        try download(source.kernelURL, to: kernel, force: force)
        try download(source.initialRamdiskURL, to: initrd, force: force)

        let rootDisk = paths.vmDirectory.appendingPathComponent("root.raw")
        let dataDisk = paths.vmDirectory.appendingPathComponent("data.raw")
        try createRawDiskIfNeeded(url: rootDisk, sizeBytes: rootDiskSizeBytes)
        try createRawDiskIfNeeded(url: dataDisk, sizeBytes: dataDiskSizeBytes)
        try ensureFile(paths.serialLog)

        let commandLine = [
            "console=hvc0",
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
            manifest.dataDiskPath,
            manifest.bootstrapSharePath,
            manifest.serialLogPath
        ]
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

    private func defaultKernelCommandLine() -> String {
        "console=hvc0 root=/dev/vda rw"
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
                throw ConjetError.filesystem("boot disk already exists at \(destination.path); pass --force to replace it")
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
        self.dataDiskPath = try container.decode(String.self, forKey: .dataDiskPath)
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
        try container.encode(dataDiskPath, forKey: .dataDiskPath)
        try container.encode(bootstrapSharePath, forKey: .bootstrapSharePath)
        try container.encode(serialLogPath, forKey: .serialLogPath)
        try container.encode(dockerSocketPath, forKey: .dockerSocketPath)
        try container.encode(kernelCommandLine, forKey: .kernelCommandLine)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(source, forKey: .source)
    }
}

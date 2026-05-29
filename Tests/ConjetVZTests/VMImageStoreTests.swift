import ConjetCore
import ConjetVZ
import XCTest

final class VMImageStoreTests: XCTestCase {
    private struct QemuImageInfo: Decodable {
        var format: String
    }

    func testInitializeFromLocalKernelCreatesManifestAndDisks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("vmlinuz")
        let initrd = root.appendingPathComponent("initrd")
        try Data("kernel".utf8).write(to: kernel)
        try Data("initrd".utf8).write(to: initrd)

        let store = VMImageStore(paths: paths)
        let manifest = try store.initializeFromLocalKernel(
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            kernelCommandLine: "console=hvc0 root=/dev/vda rw",
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 2 * 1024 * 1024
        )

        XCTAssertEqual(manifest.kernelPath, kernel.path)
        XCTAssertEqual(manifest.bootLoaderKind, .linuxKernel)
        XCTAssertEqual(manifest.initialRamdiskPath, initrd.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.vmManifest.path))
        XCTAssertEqual(try fileSize(manifest.rootDiskPath), 1024 * 1024)
        XCTAssertEqual(try fileSize(manifest.dataDiskPath), 2 * 1024 * 1024)
        XCTAssertNoThrow(try store.validateManifest(manifest))
    }

    func testCompressedEFIZbootKernelIsRejectedBeforeVZStart() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("zboot-vmlinuz")
        let initrd = root.appendingPathComponent("initrd")
        try Data([0x4d, 0x5a, 0x00, 0x00] + Array("zimg".utf8)).write(to: kernel)
        try Data("initrd".utf8).write(to: initrd)

        let store = VMImageStore(paths: paths)
        let manifest = try store.initializeFromLocalKernel(
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            kernelCommandLine: nil,
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 1024 * 1024
        )

        XCTAssertEqual(manifest.bootLoaderKind, .linuxArm64CompressedEfiZboot)
        XCTAssertNoThrow(try store.validateManifestFiles(manifest))
        XCTAssertThrowsError(try store.validateManifest(manifest)) { error in
            XCTAssertTrue(String(describing: error).contains("compressed ARM64 EFI zboot"))
        }
    }

    func testImportEFIBootDiskCreatesManifestForDiskBoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let source = root.appendingPathComponent("cloud.img")
        let seed = root.appendingPathComponent("seed.iso")
        try Data("raw-disk-placeholder".utf8).write(to: source)
        try Data("seed-placeholder".utf8).write(to: seed)

        let store = VMImageStore(paths: paths)
        let manifest = try store.importEFIBootDisk(
            sourcePath: source.path,
            name: "cloud-test",
            force: false,
            cloudInitSeedPath: seed.path,
            dataDiskSizeBytes: 1024 * 1024
        )

        XCTAssertEqual(manifest.name, "cloud-test")
        XCTAssertEqual(manifest.bootLoaderKind, .efiDisk)
        XCTAssertEqual(manifest.kernelPath, "")
        XCTAssertEqual(manifest.bootDiskPath, paths.vmDirectory.appendingPathComponent("efi-boot.raw").path)
        XCTAssertEqual(manifest.efiVariableStorePath, paths.vmDirectory.appendingPathComponent("efi-variable-store.bin").path)
        XCTAssertEqual(manifest.cloudInitSeedPath, seed.path)
        XCTAssertEqual(manifest.rootDiskPath, manifest.bootDiskPath)
        XCTAssertEqual(try String(contentsOfFile: manifest.bootDiskPath ?? ""), "raw-disk-placeholder")
        XCTAssertEqual(try fileSize(manifest.dataDiskPath), 1024 * 1024)
        XCTAssertNoThrow(try store.validateManifest(manifest))
    }

    func testImportEFIBootDiskConvertsQcow2EvenWhenExtensionIsImg() throws {
        let qemuImg = try requireQemuImg()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let source = root.appendingPathComponent("ubuntu-cloud.img")
        let create = try ProcessRunner.run(qemuImg, [
            "create",
            "-f", "qcow2",
            source.path,
            "16M"
        ])
        XCTAssertTrue(create.succeeded, create.stderr)

        let store = VMImageStore(paths: paths)
        let manifest = try store.importEFIBootDisk(
            sourcePath: source.path,
            name: "ubuntu-cloud",
            force: false,
            dataDiskSizeBytes: 1024 * 1024
        )

        let info = try qemuInfo(qemuImg: qemuImg, path: manifest.bootDiskPath ?? "")
        XCTAssertEqual(info.format, "raw")
        XCTAssertNoThrow(try store.validateManifest(manifest))
    }

    func testImportEFIBootDiskCanExpandBootDiskForCloudInitImages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let source = root.appendingPathComponent("cloud.raw")
        try Data("raw-disk-placeholder".utf8).write(to: source)

        let store = VMImageStore(paths: paths)
        let manifest = try store.importEFIBootDisk(
            sourcePath: source.path,
            name: "expanded-cloud-test",
            force: false,
            bootDiskMinimumSizeBytes: 4 * 1024 * 1024,
            dataDiskSizeBytes: 1024 * 1024
        )

        XCTAssertEqual(try fileSize(manifest.bootDiskPath ?? ""), 4 * 1024 * 1024)
        XCTAssertNoThrow(try store.validateManifest(manifest))
    }

    func testImportEFIBootDiskAcceptsGzippedRawConjetCoreArtifact() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let raw = root.appendingPathComponent("conjet-core.raw")
        let gzip = root.appendingPathComponent("conjet-core.raw.gz")
        try Data("conjet-core-raw-placeholder".utf8).write(to: raw)
        try gzipFile(source: raw, destination: gzip)

        let store = VMImageStore(paths: paths)
        let manifest = try store.importEFIBootDisk(
            sourcePath: gzip.path,
            name: "conjet-core-test",
            force: false,
            dataDiskSizeBytes: 1024 * 1024
        )

        XCTAssertEqual(manifest.name, "conjet-core-test")
        XCTAssertEqual(manifest.bootLoaderKind, .efiDisk)
        XCTAssertEqual(try String(contentsOfFile: manifest.bootDiskPath ?? ""), "conjet-core-raw-placeholder")
        let vmFiles = try FileManager.default.contentsOfDirectory(atPath: paths.vmDirectory.path)
        XCTAssertFalse(vmFiles.contains { $0.hasPrefix(".decompressed-") })
        XCTAssertNoThrow(try store.validateManifest(manifest))
    }

    func testUbuntuCloudImageSourceDefaultsToCurrentNobleArm64Image() {
        let source = UbuntuCloudImageSource()

        XCTAssertEqual(source.release, "noble")
        XCTAssertEqual(source.baseURL, "https://cloud-images.ubuntu.com/noble/current")
        XCTAssertEqual(source.imageURL, "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img")
    }

    func testUnconfiguredStatusPointsToManifestAndDockerSocket() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ConjetPaths(home: root)
        let status = VMImageStore(paths: paths).status()
        XCTAssertFalse(status.configured)
        XCTAssertEqual(status.state, .unconfigured)
        XCTAssertEqual(status.manifestPath, paths.vmManifest.path)
        XCTAssertEqual(status.dockerSocketPath, paths.dockerSocket.path)
    }

    private func fileSize(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return attributes[.size] as? UInt64 ?? 0
    }

    private func requireQemuImg() throws -> String {
        for candidate in ["/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img", "/usr/bin/qemu-img"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw XCTSkip("qemu-img is not available")
    }

    private func qemuInfo(qemuImg: String, path: String) throws -> QemuImageInfo {
        let result = try ProcessRunner.run(qemuImg, [
            "info",
            "--output=json",
            path
        ])
        XCTAssertTrue(result.succeeded, result.stderr)
        let data = try XCTUnwrap(result.stdout.data(using: .utf8))
        return try JSONDecoder().decode(QemuImageInfo.self, from: data)
    }

    private func gzipFile(source: URL, destination: URL) throws {
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = output

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderrText)
    }
}

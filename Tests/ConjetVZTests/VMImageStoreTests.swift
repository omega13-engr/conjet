import ConjetCore
import ConjetVZ
import CryptoKit
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
            dataDiskSizeBytes: 2 * 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertEqual(manifest.kernelPath, kernel.path)
        XCTAssertEqual(manifest.bootLoaderKind, .linuxKernel)
        XCTAssertEqual(manifest.initialRamdiskPath, initrd.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.vmManifest.path))
        XCTAssertEqual(try fileSize(manifest.rootDiskPath), 1024 * 1024)
        XCTAssertEqual(try fileSize(try dataDiskPath(manifest)), 2 * 1024 * 1024)
        XCTAssertEqual(try fileSize(manifest.swapDiskPath ?? ""), 512 * 1024)
        XCTAssertNoThrow(try store.validateManifest(manifest))
    }

    func testCompressedEFIZbootKernelIsRejectedBeforeHVFStart() throws {
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
        XCTAssertTrue(manifest.kernelCommandLine.contains("console=ttyAMA0"))
        XCTAssertTrue(manifest.kernelCommandLine.contains("earlycon=pl011,0x09000000"))
        XCTAssertNoThrow(try store.validateManifestFiles(manifest))
        XCTAssertThrowsError(try store.validateManifest(manifest)) { error in
            XCTAssertTrue(String(describing: error).contains("compressed ARM64 EFI zboot"))
        }
    }

    func testImportDirectKernelRootDiskCopiesProductionRootfsManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("Image")
        let initrd = root.appendingPathComponent("initrd.cpio.gz")
        let sourceRootDisk = root.appendingPathComponent("conjet-rootfs.raw")
        try arm64LinuxImageHeader().write(to: kernel)
        try Data("optional initrd".utf8).write(to: initrd)
        try Data("production root disk".utf8).write(to: sourceRootDisk)

        let store = VMImageStore(paths: paths)
        let manifest = try store.importDirectKernelRootDisk(
            kernelPath: kernel.path,
            rootDiskPath: sourceRootDisk.path,
            name: "conjet-direct-rootfs",
            initialRamdiskPath: initrd.path,
            dataDiskSizeBytes: 2 * 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertEqual(manifest.name, "conjet-direct-rootfs")
        XCTAssertEqual(manifest.bootLoaderKind, .linuxKernel)
        XCTAssertEqual(manifest.kernelPath, kernel.path)
        XCTAssertEqual(manifest.initialRamdiskPath, initrd.path)
        XCTAssertEqual(manifest.rootDiskPath, paths.vmDirectory.appendingPathComponent("root.raw").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: manifest.rootDiskPath)), Data("production root disk".utf8))
        XCTAssertEqual(try fileSize(try dataDiskPath(manifest)), 2 * 1024 * 1024)
        XCTAssertEqual(try fileSize(manifest.swapDiskPath ?? ""), 512 * 1024)
        XCTAssertTrue(manifest.kernelCommandLine.contains("root=/dev/vda1"))
        XCTAssertTrue(manifest.kernelCommandLine.contains("rootwait"))
        XCTAssertFalse(manifest.kernelCommandLine.contains("systemd.unit="))
        XCTAssertTrue(manifest.source.hasPrefix("direct-rootfs:"))
        XCTAssertNoThrow(try store.validateManifest(manifest))
        let saved = try store.loadManifest()
        XCTAssertEqual(saved.name, manifest.name)
        XCTAssertEqual(saved.bootLoaderKind, manifest.bootLoaderKind)
        XCTAssertEqual(saved.kernelPath, manifest.kernelPath)
        XCTAssertEqual(saved.rootDiskPath, manifest.rootDiskPath)
        XCTAssertEqual(saved.kernelCommandLine, manifest.kernelCommandLine)
        XCTAssertEqual(saved.source, manifest.source)
    }

    func testImportDirectKernelRootDiskCanOmitAuxiliaryDisks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("Image")
        let sourceRootDisk = root.appendingPathComponent("conjet-rootfs.raw")
        try arm64LinuxImageHeader().write(to: kernel)
        try Data("root-only production root disk".utf8).write(to: sourceRootDisk)

        let store = VMImageStore(paths: paths)
        let manifest = try store.importDirectKernelRootDisk(
            kernelPath: kernel.path,
            rootDiskPath: sourceRootDisk.path,
            name: "conjet-root-only",
            force: true,
            dataDiskSizeBytes: nil,
            swapDiskSizeBytes: nil
        )

        XCTAssertEqual(manifest.name, "conjet-root-only")
        XCTAssertEqual(manifest.rootDiskPath, paths.vmDirectory.appendingPathComponent("root.raw").path)
        XCTAssertNil(manifest.dataDiskPath)
        XCTAssertNil(manifest.swapDiskPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmDirectory.appendingPathComponent("data.raw").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmDirectory.appendingPathComponent("swap.raw").path))
        XCTAssertNoThrow(try store.validateManifest(manifest))
        try store.expandDataDiskIfNeeded(sizeBytes: 4 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmDirectory.appendingPathComponent("data.raw").path))
    }

    func testEnsureDataDiskBackfillsExistingRootOnlyManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("Image")
        let sourceRootDisk = root.appendingPathComponent("conjet-rootfs.raw")
        try arm64LinuxImageHeader().write(to: kernel)
        try Data("root-only production root disk".utf8).write(to: sourceRootDisk)

        let store = VMImageStore(paths: paths)
        let rootOnly = try store.importDirectKernelRootDisk(
            kernelPath: kernel.path,
            rootDiskPath: sourceRootDisk.path,
            name: "conjet-root-only",
            force: true,
            dataDiskSizeBytes: nil,
            swapDiskSizeBytes: nil
        )
        XCTAssertNil(rootOnly.dataDiskPath)

        let updated = try store.ensureDataDiskIfNeeded(sizeBytes: 4 * 1024 * 1024)
        XCTAssertEqual(updated.dataDiskPath, paths.vmDirectory.appendingPathComponent("data.raw").path)
        XCTAssertEqual(try fileSize(try dataDiskPath(updated)), 4 * 1024 * 1024)
        XCTAssertEqual(try store.loadManifest().dataDiskPath, updated.dataDiskPath)
    }

    func testJetstreamDirectKernelValidationRejectsEmptyRootPartition() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let kernel = root.appendingPathComponent("Image")
        let disk = root.appendingPathComponent("root.raw")
        try arm64LinuxImageHeader().write(to: kernel)
        try gptDisk(rootDisk: disk, ext4RootPartition: false)

        let manifest = directKernelManifest(
            root: root,
            kernel: kernel,
            disk: disk,
            commandLine: "console=ttyAMA0 root=/dev/vda1 rw rootwait"
        )

        XCTAssertThrowsError(try VMImageStore.validateJetstreamDirectKernelBootAssets(manifest)) { error in
            XCTAssertTrue(String(describing: error).contains("does not contain a supported Linux root filesystem"))
        }
    }

    func testJetstreamDirectKernelValidationAcceptsExt4RootPartition() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let kernel = root.appendingPathComponent("Image")
        let disk = root.appendingPathComponent("root.raw")
        try arm64LinuxImageHeader().write(to: kernel)
        try gptDisk(rootDisk: disk, ext4RootPartition: true)

        let manifest = directKernelManifest(
            root: root,
            kernel: kernel,
            disk: disk,
            commandLine: "console=ttyAMA0 root=/dev/vda1 rw rootwait"
        )

        XCTAssertNoThrow(try VMImageStore.validateJetstreamDirectKernelBootAssets(manifest))
    }

    func testImportDirectKernelRootDiskRejectsCompressedEFIZbootKernel() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("zboot-vmlinuz")
        let sourceRootDisk = root.appendingPathComponent("conjet-rootfs.raw")
        try Data([0x4d, 0x5a, 0x00, 0x00] + Array("zimg".utf8)).write(to: kernel)
        try Data("production root disk".utf8).write(to: sourceRootDisk)

        let store = VMImageStore(paths: paths)
        XCTAssertThrowsError(
            try store.importDirectKernelRootDisk(
                kernelPath: kernel.path,
                rootDiskPath: sourceRootDisk.path
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("direct rootfs import requires an uncompressed ARM64 Linux Image"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmManifest.path))
    }

    func testPhase9NetworkProofPreflightAcceptsGeneratedNetworkProofInitramfs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("Image")
        let busybox = root.appendingPathComponent("busybox")
        let initrd = root.appendingPathComponent("network-proof.cpio.gz")
        try arm64LinuxImageHeader().write(to: kernel)
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)

        let store = VMImageStore(paths: paths)
        let manifest = try store.initializeFromLocalKernel(
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            kernelCommandLine: nil,
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertNoThrow(try store.validatePhase9NetworkProofAssets(manifest))
    }

    func testNetworkProofInitramfsScriptProducesPreflightCompatibleArchive() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = repoRoot.appendingPathComponent("guest/kernel/scripts/build-network-proof-initramfs.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path), "missing executable script at \(script.path)")
        let scriptContents = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains("echo \"CONJET_INIT_READY\"\n\ninterface=\"\""))
        XCTAssertTrue(scriptContents.contains("udhcpc -q -n -t 10 -T 1"))
        XCTAssertTrue(scriptContents.contains("dhcp_pid=\"\\$!\""))
        XCTAssertTrue(scriptContents.contains("/run/conjet/dhcp.bound"))

        let kernel = root.appendingPathComponent("Image")
        let busybox = root.appendingPathComponent("busybox")
        let initrd = root.appendingPathComponent("network-proof.cpio.gz")
        try arm64LinuxImageHeader().write(to: kernel)
        try staticArm64LinuxELF().write(to: busybox)

        let result = try ProcessRunner.run("/bin/bash", [
            script.path,
            "--busybox", busybox.path,
            "--proof-url", "http://192.0.2.1/proof",
            "--guest-service-port", "18080",
            "--output", initrd.path
        ])
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertTrue(result.stdout.contains("\"guestServicePort\": 18080"))

        let store = VMImageStore(paths: paths)
        let manifest = try store.initializeFromLocalKernel(
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            kernelCommandLine: nil,
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertNoThrow(try store.validatePhase9NetworkProofAssets(manifest))
    }

    func testImportPhase9NetworkProofBundleVerifiesRelativeAssetsAndSavesManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let bundleRoot = root.appendingPathComponent("phase9-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let kernel = bundleRoot.appendingPathComponent("Image")
        let kernelBuildManifest = bundleRoot.appendingPathComponent("kernel-build-manifest.json")
        let busybox = bundleRoot.appendingPathComponent("busybox")
        let initrd = bundleRoot.appendingPathComponent("conjet-network-proof-initramfs.cpio.gz")
        let bundleManifest = bundleRoot.appendingPathComponent("phase9-network-proof-assets.json")
        try arm64LinuxImageHeader().write(to: kernel)
        try writeKernelBuildManifestFixture(kernelBuildManifest, kernel: kernel)
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)
        try writePhase9NetworkProofBundleManifest(
            bundleManifest,
            kernel: kernel,
            kernelBuildManifest: kernelBuildManifest,
            busybox: busybox,
            initramfs: initrd
        )

        let store = VMImageStore(paths: paths)
        let manifest = try store.importPhase9NetworkProofBundle(
            manifestPath: bundleManifest.path,
            kernelCommandLine: "console=ttyAMA0 proof=phase9",
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 2 * 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertEqual(manifest.name, "conjet-phase9-network-proof-assets")
        XCTAssertEqual(manifest.bootLoaderKind, .linuxKernel)
        XCTAssertEqual(manifest.kernelPath, kernel.path)
        XCTAssertEqual(manifest.initialRamdiskPath, initrd.path)
        XCTAssertEqual(manifest.kernelCommandLine, "console=ttyAMA0 proof=phase9")
        XCTAssertTrue(manifest.source.hasPrefix("phase9-network-proof-bundle:"))
        XCTAssertEqual(try fileSize(manifest.rootDiskPath), 1024 * 1024)
        XCTAssertEqual(try fileSize(try dataDiskPath(manifest)), 2 * 1024 * 1024)
        XCTAssertEqual(try fileSize(manifest.swapDiskPath ?? ""), 512 * 1024)
        XCTAssertNoThrow(try store.validatePhase9NetworkProofAssets(manifest))
        XCTAssertEqual(try store.loadManifest().source, manifest.source)
    }

    func testPhase9BundleVerifierScriptAcceptsImporterCompatibleBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let verifier = repoRoot.appendingPathComponent("guest/kernel/scripts/verify-phase9-network-proof-assets.pl")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: verifier.path),
            "missing executable verifier at \(verifier.path)"
        )

        let bundleRoot = root.appendingPathComponent("phase9-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let kernel = bundleRoot.appendingPathComponent("Image")
        let kernelBuildManifest = bundleRoot.appendingPathComponent("kernel-build-manifest.json")
        let busybox = bundleRoot.appendingPathComponent("busybox")
        let initrd = bundleRoot.appendingPathComponent("conjet-network-proof-initramfs.cpio.gz")
        let bundleManifest = bundleRoot.appendingPathComponent("phase9-network-proof-assets.json")
        try arm64LinuxImageHeader().write(to: kernel)
        try writeKernelBuildManifestFixture(kernelBuildManifest, kernel: kernel)
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)
        try writePhase9NetworkProofBundleManifest(
            bundleManifest,
            kernel: kernel,
            kernelBuildManifest: kernelBuildManifest,
            busybox: busybox,
            initramfs: initrd
        )

        let result = try ProcessRunner.run(verifier.path, [
            "--manifest", bundleManifest.path
        ])
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertTrue(result.stdout.contains("Conjet Phase 9 network-proof bundle OK"))
    }

    func testPhase2BootProofHarnessSyntaxAndPrerequisitesDoNotStartRuntime() throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let harness = repoRoot.appendingPathComponent("build-support/run-jetstream-boot-proof.sh")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: harness.path),
            "missing Phase 2 proof harness at \(harness.path)"
        )

        let syntax = try ProcessRunner.run("/bin/sh", ["-n", harness.path])
        XCTAssertTrue(syntax.succeeded, syntax.stderr)

        let checkTools = try ProcessRunner.run("/bin/sh", [harness.path, "--check-tools"])
        XCTAssertTrue(checkTools.succeeded, checkTools.stderr)
        XCTAssertTrue(checkTools.stdout.contains("Phase 2 boot proof harness prerequisites OK"))

        let help = try ProcessRunner.run("/bin/sh", [harness.path, "--help"])
        XCTAssertTrue(help.succeeded, help.stderr)
        XCTAssertTrue(help.stdout.contains("--preflight-only"))
        XCTAssertTrue(help.stdout.contains("--build-ready-initrd"))
        XCTAssertTrue(help.stdout.contains("jetstream-boot-proof-summary.json"))
        XCTAssertTrue(help.stdout.contains("CONJET_INIT_READY"))
    }

    func testPhase9BootProofHarnessWritesWorkflowExpectedDeviceTreeName() throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let harness = repoRoot.appendingPathComponent("build-support/run-jetstream-boot-proof.sh")
        let workflow = repoRoot.appendingPathComponent(".github/workflows/jetstream-kernel-assets.yml")

        let harnessSource = try String(contentsOf: harness, encoding: .utf8)
        let workflowSource = try String(contentsOf: workflow, encoding: .utf8)

        XCTAssertTrue(harnessSource.contains("jetstream-phase2.dtb"))
        XCTAssertTrue(harnessSource.contains("jetstream-phase9.dtb"))
        XCTAssertTrue(workflowSource.contains("test -s \"${qa_root}/jetstream-phase9.dtb\""))
        XCTAssertTrue(workflowSource.contains("! -name '*.raw'"))
    }

    func testPhase2BootProofHarnessRequiresInitramfsForInitReadyMode() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let harness = repoRoot.appendingPathComponent("build-support/run-jetstream-boot-proof.sh")
        let kernel = root.appendingPathComponent("Image")
        try arm64LinuxImageHeader().write(to: kernel)

        let result = try ProcessRunner.run("/bin/sh", [
            harness.path,
            "--kernel", kernel.path,
            "--require-init-ready",
            "--skip-build",
            "--skip-sign",
            "--qa-root", root.appendingPathComponent("qa", isDirectory: true).path
        ])

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("--require-init-ready requires --initrd PATH"))
    }

    func testPhase2BootProofHarnessRejectsGeneratedAndProvidedInitramfsTogether() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let harness = repoRoot.appendingPathComponent("build-support/run-jetstream-boot-proof.sh")
        let kernel = root.appendingPathComponent("Image")
        let initrd = root.appendingPathComponent("initramfs.cpio.gz")
        try arm64LinuxImageHeader().write(to: kernel)
        try Data("initrd".utf8).write(to: initrd)

        let result = try ProcessRunner.run("/bin/sh", [
            harness.path,
            "--kernel", kernel.path,
            "--initrd", initrd.path,
            "--build-ready-initrd",
            "--skip-build",
            "--skip-sign",
            "--qa-root", root.appendingPathComponent("qa", isDirectory: true).path
        ])

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("use either --build-ready-initrd or --initrd, not both"))
    }

    func testImportPhase9NetworkProofBundleRejectsChecksumMismatch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let bundleRoot = root.appendingPathComponent("phase9-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let kernel = bundleRoot.appendingPathComponent("Image")
        let kernelBuildManifest = bundleRoot.appendingPathComponent("kernel-build-manifest.json")
        let busybox = bundleRoot.appendingPathComponent("busybox")
        let initrd = bundleRoot.appendingPathComponent("conjet-network-proof-initramfs.cpio.gz")
        let bundleManifest = bundleRoot.appendingPathComponent("phase9-network-proof-assets.json")
        try arm64LinuxImageHeader().write(to: kernel)
        try writeKernelBuildManifestFixture(kernelBuildManifest, kernel: kernel)
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)
        try writePhase9NetworkProofBundleManifest(
            bundleManifest,
            kernel: kernel,
            kernelBuildManifest: kernelBuildManifest,
            busybox: busybox,
            initramfs: initrd,
            kernelImageSha256: String(repeating: "0", count: 64)
        )

        let store = VMImageStore(paths: paths)
        XCTAssertThrowsError(
            try store.importPhase9NetworkProofBundle(
                manifestPath: bundleManifest.path,
                rootDiskSizeBytes: 1024 * 1024,
                dataDiskSizeBytes: 1024 * 1024,
                swapDiskSizeBytes: 512 * 1024
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("SHA-256 mismatch"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmManifest.path))
    }

    func testImportPhase9NetworkProofBundleRejectsKernelBuildManifestChecksumMismatch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let bundleRoot = root.appendingPathComponent("phase9-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let kernel = bundleRoot.appendingPathComponent("Image")
        let kernelBuildManifest = bundleRoot.appendingPathComponent("kernel-build-manifest.json")
        let busybox = bundleRoot.appendingPathComponent("busybox")
        let initrd = bundleRoot.appendingPathComponent("conjet-network-proof-initramfs.cpio.gz")
        let bundleManifest = bundleRoot.appendingPathComponent("phase9-network-proof-assets.json")
        try arm64LinuxImageHeader().write(to: kernel)
        try writeKernelBuildManifestFixture(kernelBuildManifest, kernel: kernel)
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)
        try writePhase9NetworkProofBundleManifest(
            bundleManifest,
            kernel: kernel,
            kernelBuildManifest: kernelBuildManifest,
            busybox: busybox,
            initramfs: initrd,
            kernelBuildManifestSha256: String(repeating: "0", count: 64)
        )

        let store = VMImageStore(paths: paths)
        XCTAssertThrowsError(
            try store.importPhase9NetworkProofBundle(
                manifestPath: bundleManifest.path,
                rootDiskSizeBytes: 1024 * 1024,
                dataDiskSizeBytes: 1024 * 1024,
                swapDiskSizeBytes: 512 * 1024
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("SHA-256 mismatch"))
            XCTAssertTrue(String(describing: error).contains("kernelBuildManifest"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmManifest.path))
    }

    func testImportPhase9NetworkProofBundleRejectsKernelBuildManifestImageMismatch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let bundleRoot = root.appendingPathComponent("phase9-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let kernel = bundleRoot.appendingPathComponent("Image")
        let kernelBuildManifest = bundleRoot.appendingPathComponent("kernel-build-manifest.json")
        let busybox = bundleRoot.appendingPathComponent("busybox")
        let initrd = bundleRoot.appendingPathComponent("conjet-network-proof-initramfs.cpio.gz")
        let bundleManifest = bundleRoot.appendingPathComponent("phase9-network-proof-assets.json")
        try arm64LinuxImageHeader().write(to: kernel)
        try writeKernelBuildManifestFixture(
            kernelBuildManifest,
            kernel: kernel,
            kernelImageSha256: String(repeating: "f", count: 64)
        )
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)
        try writePhase9NetworkProofBundleManifest(
            bundleManifest,
            kernel: kernel,
            kernelBuildManifest: kernelBuildManifest,
            busybox: busybox,
            initramfs: initrd
        )

        let store = VMImageStore(paths: paths)
        XCTAssertThrowsError(
            try store.importPhase9NetworkProofBundle(
                manifestPath: bundleManifest.path,
                rootDiskSizeBytes: 1024 * 1024,
                dataDiskSizeBytes: 1024 * 1024,
                swapDiskSizeBytes: 512 * 1024
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("imageSha256"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmManifest.path))
    }

    func testImportPhase9NetworkProofBundleRejectsKernelBuildManifestMissingRequiredBuiltIn() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let bundleRoot = root.appendingPathComponent("phase9-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let kernel = bundleRoot.appendingPathComponent("Image")
        let kernelBuildManifest = bundleRoot.appendingPathComponent("kernel-build-manifest.json")
        let busybox = bundleRoot.appendingPathComponent("busybox")
        let initrd = bundleRoot.appendingPathComponent("conjet-network-proof-initramfs.cpio.gz")
        let bundleManifest = bundleRoot.appendingPathComponent("phase9-network-proof-assets.json")
        try arm64LinuxImageHeader().write(to: kernel)
        try writeKernelBuildManifestFixture(
            kernelBuildManifest,
            kernel: kernel,
            requiredBuiltIns: phase9KernelRequiredBuiltIns.filter { $0 != "CONFIG_VIRTIO_NET" }
        )
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)
        try writePhase9NetworkProofBundleManifest(
            bundleManifest,
            kernel: kernel,
            kernelBuildManifest: kernelBuildManifest,
            busybox: busybox,
            initramfs: initrd
        )

        let store = VMImageStore(paths: paths)
        XCTAssertThrowsError(
            try store.importPhase9NetworkProofBundle(
                manifestPath: bundleManifest.path,
                rootDiskSizeBytes: 1024 * 1024,
                dataDiskSizeBytes: 1024 * 1024,
                swapDiskSizeBytes: 512 * 1024
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("CONFIG_VIRTIO_NET"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmManifest.path))
    }

    func testImportPhase9NetworkProofBundleRejectsInvalidKernelWithoutSavingManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()

        let bundleRoot = root.appendingPathComponent("phase9-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let kernel = bundleRoot.appendingPathComponent("Image")
        let kernelBuildManifest = bundleRoot.appendingPathComponent("kernel-build-manifest.json")
        let busybox = bundleRoot.appendingPathComponent("busybox")
        let initrd = bundleRoot.appendingPathComponent("conjet-network-proof-initramfs.cpio.gz")
        let bundleManifest = bundleRoot.appendingPathComponent("phase9-network-proof-assets.json")
        try Data("not-an-arm64-linux-image".utf8).write(to: kernel)
        try writeKernelBuildManifestFixture(kernelBuildManifest, kernel: kernel)
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)
        try writePhase9NetworkProofBundleManifest(
            bundleManifest,
            kernel: kernel,
            kernelBuildManifest: kernelBuildManifest,
            busybox: busybox,
            initramfs: initrd
        )

        let store = VMImageStore(paths: paths)
        XCTAssertThrowsError(
            try store.importPhase9NetworkProofBundle(
                manifestPath: bundleManifest.path,
                rootDiskSizeBytes: 1024 * 1024,
                dataDiskSizeBytes: 1024 * 1024,
                swapDiskSizeBytes: 512 * 1024
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("ARM64 Linux Image"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.vmManifest.path))
    }

    func testPhase9NetworkProofPreflightRejectsInvalidLinuxImageHeader() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("Image")
        let busybox = root.appendingPathComponent("busybox")
        let initrd = root.appendingPathComponent("network-proof.cpio.gz")
        try Data("direct-linux-image-placeholder".utf8).write(to: kernel)
        try staticArm64LinuxELF().write(to: busybox)
        _ = try InitramfsBuilder.buildNetworkProofProbe(busybox: busybox, output: initrd)

        let store = VMImageStore(paths: paths)
        let manifest = try store.initializeFromLocalKernel(
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            kernelCommandLine: nil,
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertThrowsError(try store.validatePhase9NetworkProofAssets(manifest)) { error in
            XCTAssertTrue(String(describing: error).contains("ARM64 Linux Image"))
        }
    }

    func testPhase9NetworkProofPreflightRejectsInvalidEmbeddedBusyBox() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("Image")
        let archive = root.appendingPathComponent("network-proof.cpio")
        let initrd = root.appendingPathComponent("network-proof.cpio.gz")
        try arm64LinuxImageHeader().write(to: kernel)
        try InitramfsBuilder.writeNewcArchive(
            entries: [
                .directory("bin"),
                .regularFile("bin/busybox", data: Data("not-a-linux-busybox".utf8), mode: 0o100755),
                .symbolicLink("bin/sh", target: "busybox"),
                .regularFile(
                    "init",
                    data: Data(
                        """
                        conjet-network-proof-initramfs
                        CONJET_NETWORK_PROOF_BEGIN
                        CONJET_NETWORK_OUTBOUND_TCP_OK
                        CONJET_NETWORK_GUEST_SERVICE_READY
                        CONJET_NETWORK_FORWARDED_PORT_OK
                        """.utf8
                    ),
                    mode: 0o100755
                )
            ],
            to: archive
        )
        try gzipFile(source: archive, destination: initrd)

        let store = VMImageStore(paths: paths)
        let manifest = try store.initializeFromLocalKernel(
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            kernelCommandLine: nil,
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertThrowsError(try store.validatePhase9NetworkProofAssets(manifest)) { error in
            XCTAssertTrue(String(describing: error).contains("static ARM64 Linux BusyBox"))
        }
    }

    func testPhase9NetworkProofPreflightRejectsPlainInitramfs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("Image")
        let initrd = root.appendingPathComponent("plain.cpio.gz")
        let initBinary = root.appendingPathComponent("init")
        try arm64LinuxImageHeader().write(to: kernel)
        try Data("plain-init-placeholder".utf8).write(to: initBinary)
        _ = try InitramfsBuilder.build(initBinary: initBinary, output: initrd)

        let store = VMImageStore(paths: paths)
        let manifest = try store.initializeFromLocalKernel(
            kernelPath: kernel.path,
            initialRamdiskPath: initrd.path,
            kernelCommandLine: nil,
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertThrowsError(try store.validatePhase9NetworkProofAssets(manifest)) { error in
            XCTAssertTrue(String(describing: error).contains("network-proof initramfs"))
        }
    }

    func testExpandDataDiskIfNeededGrowsExistingManifestDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-vz-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConjetPaths(home: root)
        try paths.ensureBaseDirectories()

        let kernel = root.appendingPathComponent("vmlinuz")
        try Data("kernel".utf8).write(to: kernel)

        let store = VMImageStore(paths: paths)
        let manifest = try store.initializeFromLocalKernel(
            kernelPath: kernel.path,
            initialRamdiskPath: nil,
            kernelCommandLine: nil,
            rootDiskSizeBytes: 1024 * 1024,
            dataDiskSizeBytes: 1024 * 1024
        )

        try store.expandDataDiskIfNeeded(sizeBytes: 2 * 1024 * 1024)
        XCTAssertEqual(try fileSize(try dataDiskPath(manifest)), 2 * 1024 * 1024)

        try store.expandDataDiskIfNeeded(sizeBytes: 1024 * 1024)
        XCTAssertEqual(try fileSize(try dataDiskPath(manifest)), 2 * 1024 * 1024)
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
            dataDiskSizeBytes: 1024 * 1024,
            swapDiskSizeBytes: 512 * 1024
        )

        XCTAssertEqual(manifest.name, "cloud-test")
        XCTAssertEqual(manifest.bootLoaderKind, .efiDisk)
        XCTAssertEqual(manifest.kernelPath, "")
        XCTAssertEqual(manifest.bootDiskPath, paths.vmDirectory.appendingPathComponent("efi-boot.raw").path)
        XCTAssertEqual(manifest.efiVariableStorePath, paths.vmDirectory.appendingPathComponent("efi-variable-store.bin").path)
        XCTAssertEqual(manifest.cloudInitSeedPath, seed.path)
        XCTAssertEqual(manifest.rootDiskPath, manifest.bootDiskPath)
        XCTAssertEqual(try String(contentsOfFile: manifest.bootDiskPath ?? ""), "raw-disk-placeholder")
        XCTAssertEqual(try fileSize(try dataDiskPath(manifest)), 1024 * 1024)
        XCTAssertEqual(try fileSize(manifest.swapDiskPath ?? ""), 512 * 1024)
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

    func testDebianInstallerSourceDefaultsToStableDirectArm64NetbootAssets() {
        let source = DebianInstallerSource()

        XCTAssertEqual(source.suite, "stable")
        XCTAssertEqual(
            source.baseURL,
            "https://deb.debian.org/debian/dists/stable/main/installer-arm64/current/images/netboot/debian-installer/arm64"
        )
        XCTAssertEqual(
            source.kernelURL,
            "https://deb.debian.org/debian/dists/stable/main/installer-arm64/current/images/netboot/debian-installer/arm64/linux"
        )
        XCTAssertEqual(
            source.initialRamdiskURL,
            "https://deb.debian.org/debian/dists/stable/main/installer-arm64/current/images/netboot/debian-installer/arm64/initrd.gz"
        )
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

    private func writePhase9NetworkProofBundleManifest(
        _ manifest: URL,
        kernel: URL,
        kernelBuildManifest: URL,
        busybox: URL,
        initramfs: URL,
        kernelImageSha256: String? = nil,
        kernelBuildManifestSha256: String? = nil
    ) throws {
        let resolvedKernelImageSha256: String
        if let kernelImageSha256 {
            resolvedKernelImageSha256 = kernelImageSha256
        } else {
            resolvedKernelImageSha256 = try sha256Hex(kernel)
        }
        let resolvedKernelBuildManifestSha256: String
        if let kernelBuildManifestSha256 {
            resolvedKernelBuildManifestSha256 = kernelBuildManifestSha256
        } else {
            resolvedKernelBuildManifestSha256 = try sha256Hex(kernelBuildManifest)
        }
        let bundle = Phase9NetworkProofAssetBundleManifest(
            schemaVersion: 1,
            name: "conjet-phase9-network-proof-assets",
            architecture: "arm64",
            createdAt: "2026-06-17T00:00:00Z",
            kernelImage: kernel.lastPathComponent,
            kernelImageSha256: resolvedKernelImageSha256,
            kernelBuildManifest: kernelBuildManifest.lastPathComponent,
            kernelBuildManifestSha256: resolvedKernelBuildManifestSha256,
            busybox: busybox.lastPathComponent,
            busyboxSha256: try sha256Hex(busybox),
            initramfs: initramfs.lastPathComponent,
            initramfsSha256: try sha256Hex(initramfs),
            proofURL: "http://example.com",
            guestServicePort: 8080
        )
        try ConjetJSON.encoder().encode(bundle).write(to: manifest)
    }

    private var phase9KernelRequiredBuiltIns: [String] {
        let configURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/config/conjet-arm64.config")
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return VMImageStore.requiredJetstreamKernelBuiltIns
        }
        return config
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("CONFIG_"), trimmed.hasSuffix("=y") else { return nil }
                return String(trimmed.dropLast(2))
            }
    }

    private func writeKernelBuildManifestFixture(
        _ manifest: URL,
        kernel: URL,
        kernelImageSha256: String? = nil,
        requiredBuiltIns: [String]? = nil
    ) throws {
        let resolvedKernelImageSha256: String
        if let kernelImageSha256 {
            resolvedKernelImageSha256 = kernelImageSha256
        } else {
            resolvedKernelImageSha256 = try sha256Hex(kernel)
        }
        try kernelBuildManifestFixture(
            kernelImageSha256: resolvedKernelImageSha256,
            requiredBuiltIns: requiredBuiltIns ?? phase9KernelRequiredBuiltIns
        ).write(to: manifest)
    }

    private func kernelBuildManifestFixture(
        kernelImageSha256: String,
        requiredBuiltIns: [String]
    ) -> Data {
        let requiredBuiltInsJSON = requiredBuiltIns
            .map { "    \"\($0)\"" }
            .joined(separator: ",\n")
        return Data(
            """
            {
              "schemaVersion": 1,
              "name": "conjet-linux",
              "version": "6.12.86",
              "architecture": "arm64",
              "image": "/tmp/conjet-kernel/Image",
              "imageSha256": "\(kernelImageSha256)",
              "config": "/tmp/conjet-kernel/.config",
              "configSha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
              "systemMapSha256": "1111111111111111111111111111111111111111111111111111111111111111",
              "vmlinuxSha256": "2222222222222222222222222222222222222222222222222222222222222222",
              "source": "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.86.tar.xz",
              "sourceSha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
              "requiredBuiltIns": [
            \(requiredBuiltInsJSON)
              ]
            }
            """.utf8
        )
    }

    private func sha256Hex(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    private func arm64LinuxImageHeader() -> Data {
        var data = Data(repeating: 0, count: 64)
        data[0x38] = 0x41
        data[0x39] = 0x52
        data[0x3a] = 0x4d
        data[0x3b] = 0x64
        return data
    }

    private func directKernelManifest(
        root: URL,
        kernel: URL,
        disk: URL,
        commandLine: String
    ) -> VMAssetManifest {
        VMAssetManifest(
            name: "conjet-core",
            architecture: "arm64",
            bootLoaderKind: .linuxKernel,
            kernelPath: kernel.path,
            initialRamdiskPath: nil,
            modloopPath: nil,
            rootDiskPath: disk.path,
            dataDiskPath: nil,
            swapDiskPath: nil,
            bootstrapSharePath: root.appendingPathComponent("bootstrap").path,
            serialLogPath: root.appendingPathComponent("serial.log").path,
            dockerSocketPath: root.appendingPathComponent("docker.sock").path,
            kernelCommandLine: commandLine,
            source: "test"
        )
    }

    private func gptDisk(rootDisk: URL, ext4RootPartition: Bool) throws {
        FileManager.default.createFile(atPath: rootDisk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: rootDisk)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 4 * 1024 * 1024)

        var header = Data(repeating: 0, count: 512)
        header.replaceSubrange(0..<8, with: Data("EFI PART".utf8))
        header.writeLittleEndian(UInt64(2), at: 72)
        header.writeLittleEndian(UInt32(128), at: 80)
        header.writeLittleEndian(UInt32(128), at: 84)
        try handle.seek(toOffset: 512)
        try handle.write(contentsOf: header)

        var entry = Data(repeating: 0, count: 128)
        entry.replaceSubrange(0..<16, with: Data([0x0f, 0xc6, 0x3d, 0xaf, 0x84, 0x83, 0x47, 0x72, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4]))
        entry.writeLittleEndian(UInt64(2048), at: 32)
        entry.writeLittleEndian(UInt64(4095), at: 40)
        try handle.seek(toOffset: 1024)
        try handle.write(contentsOf: entry)

        if ext4RootPartition {
            try handle.seek(toOffset: 2048 * 512 + 1024 + 0x38)
            try handle.write(contentsOf: Data([0x53, 0xef]))
        }
    }

    private func dataDiskPath(
        _ manifest: VMAssetManifest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try XCTUnwrap(manifest.dataDiskPath, file: file, line: line)
    }

    private func staticArm64LinuxELF() -> Data {
        var elf = Data()
        elf.append(contentsOf: [0x7f, 0x45, 0x4c, 0x46])
        elf.append(contentsOf: [0x02, 0x01, 0x01, 0x00])
        elf.append(contentsOf: Data(repeating: 0, count: 8))
        elf.appendLittleEndian(UInt16(2))
        elf.appendLittleEndian(UInt16(183))
        elf.appendLittleEndian(UInt32(1))
        elf.appendLittleEndian(UInt64(0x0040_0000))
        elf.appendLittleEndian(UInt64(64))
        elf.appendLittleEndian(UInt64(0))
        elf.appendLittleEndian(UInt32(0))
        elf.appendLittleEndian(UInt16(64))
        elf.appendLittleEndian(UInt16(56))
        elf.appendLittleEndian(UInt16(1))
        elf.appendLittleEndian(UInt16(0))
        elf.appendLittleEndian(UInt16(0))
        elf.appendLittleEndian(UInt16(0))

        elf.appendLittleEndian(UInt32(1))
        elf.appendLittleEndian(UInt32(5))
        elf.appendLittleEndian(UInt64(0x1000))
        elf.appendLittleEndian(UInt64(0x0040_0000))
        elf.appendLittleEndian(UInt64(0x0040_0000))
        elf.appendLittleEndian(UInt64(4))
        elf.appendLittleEndian(UInt64(4))
        elf.appendLittleEndian(UInt64(0x1000))
        if elf.count < 0x1000 {
            elf.append(contentsOf: Data(repeating: 0, count: 0x1000 - elf.count))
        }
        elf.append(contentsOf: [0xc0, 0x03, 0x5f, 0xd6])
        return elf
    }
}

private extension Data {
    mutating func writeLittleEndian(_ value: UInt32, at offset: Int) {
        let bytes = Swift.withUnsafeBytes(of: value.littleEndian) { Data($0) }
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    mutating func writeLittleEndian(_ value: UInt64, at offset: Int) {
        let bytes = Swift.withUnsafeBytes(of: value.littleEndian) { Data($0) }
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}

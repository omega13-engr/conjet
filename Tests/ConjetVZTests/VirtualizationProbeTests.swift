import ConjetCore
import ConjetVZ
import Foundation
import XCTest

final class VirtualizationProbeTests: XCTestCase {
    func testInspectReportsSelectedHVFBackendAsExperimental() throws {
        let config = ConjetConfig(vmBackend: .hvfExperimental)
        let capabilities = VirtualizationProbe.inspect(config: config)

        XCTAssertEqual(capabilities.recommendedVMType, "hvf-experimental")
        XCTAssertTrue(capabilities.notes.contains { $0.contains("Jetstream HVF") })
        XCTAssertTrue(capabilities.notes.contains { $0.contains("x86_64 Linux userspace") })
    }

    func testHVFExperimentalStartRejectsInvalidDirectKernelAssetsBeforeHVFCreate() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-hvf-gate-\(UUID().uuidString)", isDirectory: true)
        let paths = ConjetPaths(home: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = VMAssetManifest(
            name: "hvf-gate",
            architecture: "aarch64",
            kernelPath: "/does/not/need/to/exist",
            initialRamdiskPath: nil,
            modloopPath: nil,
            rootDiskPath: "/does/not/need/to/exist",
            dataDiskPath: "/does/not/need/to/exist",
            bootstrapSharePath: paths.bootstrapShare.path,
            serialLogPath: paths.serialLog.path,
            dockerSocketPath: paths.dockerSocket.path,
            kernelCommandLine: "",
            source: "test"
        )

        XCTAssertThrowsError(try VirtualMachineController().start(
            manifest: manifest,
            config: ConjetConfig(vmBackend: .hvfExperimental),
            store: VMImageStore(paths: paths)
        )) { error in
            let detail = String(describing: error)
            XCTAssertFalse(detail.contains("conjet vm backend smoke"))
            XCTAssertTrue(
                detail.contains("direct ARM64 Linux Image")
                    || detail.contains("direct-kernel boot kernel is missing")
                    || detail.contains("kernel does not exist")
                    || detail.contains("does not exist"),
                detail
            )
        }
    }
}

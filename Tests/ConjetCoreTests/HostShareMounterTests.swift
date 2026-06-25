import ConjetCore
import XCTest

final class HostShareMounterTests: XCTestCase {
    func testDockerArgumentsEnterGuestHostNamespaceAndMountConjetShares() {
        let mounter = HostShareMounter(dockerContext: "conjet")
        let arguments = mounter.dockerArguments()

        XCTAssertTrue(arguments.starts(with: [
            "docker",
            "--context",
            "conjet",
            "run",
            "--rm",
            "--privileged"
        ]))
        XCTAssertTrue(arguments.contains("--pid=host"))
        XCTAssertTrue(arguments.contains("ubuntu:24.04"))
        XCTAssertTrue(arguments.contains("nsenter"))
        let commandText = arguments.joined(separator: " ")
        XCTAssertTrue(commandText.contains("conjethostusers"))
        XCTAssertTrue(commandText.contains("/Users"))
        XCTAssertFalse(commandText.contains("conjethostvolumes"))
        XCTAssertFalse(commandText.contains("/Volumes"))
    }

    func testDockerArgumentsMountRemovableVolumesOnlyWhenEnabled() {
        let mounter = HostShareMounter(dockerContext: "conjet", includeRemovableVolumes: true)
        let commandText = mounter.dockerArguments().joined(separator: " ")

        XCTAssertTrue(commandText.contains("conjethostusers"))
        XCTAssertTrue(commandText.contains("/Users"))
        XCTAssertTrue(commandText.contains("conjethostvolumes"))
        XCTAssertTrue(commandText.contains("/Volumes"))
    }

    func testEnsureMountedReturnsMountedPaths() throws {
        let mounter = HostShareMounter(dockerContext: "conjet") { executable, arguments in
            ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                stdout: "/Users mounted\n",
                stderr: ""
            )
        }

        let result = try mounter.ensureMounted()

        XCTAssertEqual(result.dockerContext, "conjet")
        XCTAssertEqual(result.mountedPaths, ["/Users"])
        XCTAssertTrue(result.stdoutTail.contains("/Users mounted"))
    }

    func testEnsureMountedReturnsRemovableVolumePathWhenEnabled() throws {
        let mounter = HostShareMounter(dockerContext: "conjet", includeRemovableVolumes: true) { executable, arguments in
            ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                stdout: "/Users mounted\n/Volumes mounted\n",
                stderr: ""
            )
        }

        let result = try mounter.ensureMounted()

        XCTAssertEqual(result.mountedPaths, ["/Users", "/Volumes"])
    }

    func testEnsureMountedReportsDockerFailure() {
        let mounter = HostShareMounter(dockerContext: "conjet") { executable, arguments in
            ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 32,
                stdout: "",
                stderr: "mount: unknown filesystem type virtiofs"
            )
        }

        XCTAssertThrowsError(try mounter.ensureMounted()) { error in
            XCTAssertTrue(String(describing: error).contains("virtiofs"))
        }
    }
}

import ConjetCore
import XCTest

final class DockerMetadataRepairerTests: XCTestCase {
    func testDockerArgumentsEnterGuestHostNamespaceAndDefaultToDryRun() {
        let repairer = DockerMetadataRepairer(dockerContext: "conjet")
        let arguments = repairer.dockerArguments(project: "chum-mem", containerIDs: ["1c1d76b426c1"])

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
        XCTAssertTrue(arguments.contains("dry-run"))
        XCTAssertTrue(arguments.contains("chum-mem"))
        XCTAssertTrue(arguments.contains("1c1d76b426c1"))
        XCTAssertTrue(arguments.joined(separator: " ").contains(".conjet-stale-backup"))
    }

    func testParseRecordsDecodesRepairOutput() {
        let output = """
        ignored line
        conjet-docker-metadata\tstale\t1c1d76b426c19f0f91d404c199b7e6b4e16b2e0be2721cc2d544195f8303d4c9\tdocker-list-without-inspect-or-containerd\t/backup/1.tgz
        conjet-docker-metadata\trepaired\tcab5d0c4e47275282ce694468988ad4c357246db31085e701da6fd4082afb66b\tbacked-up-and-removed-stale-docker-metadata\t/backup/2.tgz
        conjet-docker-metadata\tskipped\tabc123abc123\tcontainerd-task-present\t
        """

        let records = DockerMetadataRepairer.parseRecords(output)

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].action, .stale)
        XCTAssertEqual(records[0].backupPath, "/backup/1.tgz")
        XCTAssertEqual(records[1].action, .repaired)
        XCTAssertEqual(records[2].action, .skipped)
        XCTAssertNil(records[2].backupPath)
    }

    func testRepairRejectsUnsafeProjectName() {
        let repairer = DockerMetadataRepairer(dockerContext: "conjet") { _, _ in
            XCTFail("runner should not be called")
            return ProcessResult(executable: "", arguments: [], exitCode: 0, stdout: "", stderr: "")
        }

        XCTAssertThrowsError(try repairer.repair(project: "bad;name")) { error in
            XCTAssertTrue(String(describing: error).contains("--project"))
        }
    }

    func testRepairRejectsUnsafeContainerID() {
        let repairer = DockerMetadataRepairer(dockerContext: "conjet") { _, _ in
            XCTFail("runner should not be called")
            return ProcessResult(executable: "", arguments: [], exitCode: 0, stdout: "", stderr: "")
        }

        XCTAssertThrowsError(try repairer.repair(containerIDs: ["not-a-container"])) { error in
            XCTAssertTrue(String(describing: error).contains("--id"))
        }
    }

    func testRepairReturnsParsedRecords() throws {
        let repairer = DockerMetadataRepairer(dockerContext: "conjet") { executable, arguments in
            ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                stdout: "conjet-docker-metadata\tstale\t1c1d76b426c1\tdocker-list-without-inspect-or-containerd\t/backup/1.tgz\n",
                stderr: ""
            )
        }

        let result = try repairer.repair(dryRun: true, project: "chum-mem")

        XCTAssertEqual(result.dockerContext, "conjet")
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.project, "chum-mem")
        XCTAssertEqual(result.staleCount, 1)
        XCTAssertEqual(result.repairedCount, 0)
    }
}

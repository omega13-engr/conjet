import ConjetVZ
import Foundation
import XCTest

final class CloudInitSeedBuilderTests: XCTestCase {
    func testBuildDockerBootstrapSeedCreatesISO() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-cloud-init-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let output = root.appendingPathComponent("cloud-init-docker.iso")
        let result = try CloudInitSeedBuilder.buildDockerBootstrapSeed(output: output)

        XCTAssertEqual(result.outputPath, output.path)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertGreaterThan(result.userDataBytes, 0)
        XCTAssertGreaterThan(result.metaDataBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testDockerBootstrapUserDataMentionsDockerService() {
        let userData = CloudInitSeedBuilder.dockerBootstrapUserData()
        XCTAssertTrue(userData.contains("#cloud-config"))
        XCTAssertTrue(userData.contains("systemctl enable --now docker"))
        XCTAssertTrue(userData.contains("conjet-docker-vsock-bridge.py"))
        XCTAssertTrue(userData.contains("VSOCK_PORT = 2375"))
        XCTAssertTrue(userData.contains("docker-bootstrap-ready"))
        XCTAssertTrue(userData.contains("Conjet cloud-init bootcmd reached"))
        XCTAssertTrue(userData.contains("mount -t virtiofs conjetboot"))
        XCTAssertTrue(userData.contains("docker-bootstrap.log"))
        XCTAssertTrue(userData.contains("unpigz.conjet-original"))
        XCTAssertTrue(userData.contains("waiting for Docker API"))
        XCTAssertTrue(userData.contains("vmw_vsock_virtio_transport"))
        XCTAssertTrue(userData.contains("/usr/bin/tee -a /run/conjet/docker-vsock.log /dev/hvc0"))
        XCTAssertTrue(userData.contains("StandardOutput=journal"))
        XCTAssertTrue(userData.contains("shutdown(socket.SHUT_WR)"))
        XCTAssertTrue(userData.contains("left.join()"))
        XCTAssertTrue(userData.contains("right.join()"))
    }
}

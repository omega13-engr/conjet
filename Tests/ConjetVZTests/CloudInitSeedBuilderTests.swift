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
        XCTAssertTrue(userData.contains("conjet-data-disk.sh"))
        XCTAssertTrue(userData.contains("conjet-data-disk.service"))
        XCTAssertTrue(userData.contains("/dev/disk/by-id/virtio-conjet-data"))
        XCTAssertTrue(userData.contains("resize2fs"))
        XCTAssertTrue(userData.contains("bind_runtime_directory /var/lib/docker"))
        XCTAssertTrue(userData.contains("bind_runtime_directory /var/lib/containerd"))
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
        XCTAssertTrue(userData.contains("read_first_client_chunk(client)"))
        XCTAssertTrue(userData.contains("/conjet-bridge-capabilities"))
        XCTAssertTrue(userData.contains(#""lazy_upstream":true"#))
        XCTAssertTrue(userData.contains("upstream.sendall(first_chunk)"))
        XCTAssertTrue(userData.contains("left.join()"))
        XCTAssertTrue(userData.contains("right.join()"))
    }

    func testConjetCoreDockerVsockBridgeCachesDockerReadiness() throws {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = repositoryRoot.appendingPathComponent(
            "guest/image/conjet-core/scripts/conjet-docker-vsock-bridge.py"
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("DOCKER_READY = threading.Event()"))
        XCTAssertTrue(script.contains("DOCKER_READY.set()"))
        XCTAssertTrue(script.contains("DOCKER_READY.clear()"))
        XCTAssertTrue(script.contains("if not DOCKER_READY.is_set():"))
        XCTAssertTrue(script.contains("run_buildkit_healthcheck()"))
        XCTAssertTrue(script.contains("parent snapshot"))
        XCTAssertTrue(script.contains("builder\", \"prune\", \"-af"))
        XCTAssertTrue(script.contains("BuildKit health check passed after cache prune"))
        XCTAssertTrue(script.contains("upstream.connect(DOCKER_SOCKET)"))
        XCTAssertTrue(script.contains("read_first_client_chunk(client)"))
        XCTAssertTrue(script.contains("/conjet-bridge-capabilities"))
        XCTAssertTrue(script.contains(#""lazy_upstream":true"#))
        XCTAssertTrue(script.contains("upstream.sendall(first_chunk)"))

        let readinessCheck = try XCTUnwrap(script.range(of: "if not DOCKER_READY.is_set():"))
        let directConnect = try XCTUnwrap(script.range(of: "upstream.connect(DOCKER_SOCKET)", range: readinessCheck.upperBound..<script.endIndex))
        XCTAssertLessThan(readinessCheck.lowerBound, directConnect.lowerBound)
        let firstClientRead = try XCTUnwrap(script.range(of: "first_chunk = read_first_client_chunk(client)"))
        let clientScopedConnect = try XCTUnwrap(script.range(of: "upstream = connect_docker_with_retry()", range: firstClientRead.upperBound..<script.endIndex))
        XCTAssertLessThan(firstClientRead.lowerBound, clientScopedConnect.lowerBound)
    }

    func testConjetCoreDataDiskScriptMountsDockerStateOnDataDisk() throws {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = repositoryRoot.appendingPathComponent(
            "guest/image/conjet-core/scripts/conjet-data-disk.sh"
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("/dev/disk/by-id/virtio-conjet-data"))
        XCTAssertTrue(script.contains("mkfs.ext4 -F -L conjet-data"))
        XCTAssertTrue(script.contains("resize2fs"))
        XCTAssertTrue(script.contains("MOUNT_OPTIONS=\"${CONJET_DATA_MOUNT_OPTIONS:-noatime,nodiratime,lazytime,nodiscard,commit=60}\""))
        XCTAssertTrue(script.contains("mount -o \"${MOUNT_OPTIONS}\""))
        XCTAssertFalse(script.contains("mount -o noatime,discard"))
        XCTAssertTrue(script.contains("bind_runtime_directory /var/lib/containerd"))
        XCTAssertTrue(script.contains("bind_runtime_directory /var/lib/docker"))
    }
}

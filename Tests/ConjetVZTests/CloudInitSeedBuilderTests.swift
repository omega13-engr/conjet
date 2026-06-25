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
        XCTAssertTrue(userData.contains("openssh-server"))
        XCTAssertTrue(userData.contains("useradd -m -s /bin/sh conjet"))
        XCTAssertTrue(userData.contains("passwd -l conjet"))
        XCTAssertTrue(userData.contains("99-conjet-managed.conf"))
        XCTAssertTrue(userData.contains("PasswordAuthentication no"))
        XCTAssertTrue(userData.contains("PermitRootLogin no"))
        XCTAssertTrue(userData.contains("AllowTcpForwarding no"))
        XCTAssertTrue(userData.contains("GatewayPorts no"))
        XCTAssertTrue(userData.contains("AllowUsers conjet"))
        XCTAssertTrue(userData.contains("ssh-keygen -A"))
        XCTAssertTrue(userData.contains("systemctl enable --now ssh"))
        XCTAssertFalse(userData.contains("conjet-data-disk.sh"))
        XCTAssertFalse(userData.contains("conjet-data-disk.service"))
        XCTAssertFalse(userData.contains("CONJET_DATA_DEVICE_WAIT_ATTEMPTS"))
        XCTAssertFalse(userData.contains("CONJET_DATA_RESIZE_ON_BOOT"))
        XCTAssertFalse(userData.contains("systemd-udev-settle.service"))
        XCTAssertFalse(userData.contains("bind_runtime_directory /var/lib/docker"))
        XCTAssertFalse(userData.contains("bind_runtime_directory /var/lib/containerd"))
        XCTAssertTrue(userData.contains("conjet-docker-vsock-bridge.py"))
        XCTAssertTrue(userData.contains("VSOCK_PORT = 2375"))
        XCTAssertTrue(userData.contains("docker-bootstrap-ready"))
        XCTAssertTrue(userData.contains("Conjet cloud-init bootcmd reached"))
        XCTAssertTrue(userData.contains("mount -t virtiofs conjetboot"))
        XCTAssertTrue(userData.contains("docker-bootstrap.log"))
        XCTAssertTrue(userData.contains("unpigz.conjet-original"))
        XCTAssertTrue(userData.contains("waiting for Docker API"))
        XCTAssertTrue(userData.contains("vmw_vsock_virtio_transport"))
        XCTAssertTrue(userData.contains("conjet-docker-vsock-entrypoint.sh"))
        XCTAssertTrue(userData.contains("ExecStart=/usr/local/sbin/conjet-docker-vsock-entrypoint.sh"))
        XCTAssertTrue(userData.contains("StandardOutput=append:/run/conjet/docker-vsock.log"))
        XCTAssertFalse(userData.contains("/usr/bin/tee -a /run/conjet/docker-vsock.log /dev/hvc0"))
        XCTAssertTrue(userData.contains("shutdown(socket.SHUT_WR)"))
        XCTAssertTrue(userData.contains("read_first_client_chunk(client)"))
        XCTAssertTrue(userData.contains("/conjet-bridge-capabilities"))
        XCTAssertTrue(userData.contains(#""lazy_upstream":true"#))
        XCTAssertTrue(userData.contains(#""tcp_proxy":true"#))
        XCTAssertTrue(userData.contains(#""udp_proxy":true"#))
        XCTAssertTrue(userData.contains("CONJET-TCP "))
        XCTAssertTrue(userData.contains("CONJET-UDP "))
        XCTAssertTrue(userData.contains("handle_tcp_proxy(client, first_chunk)"))
        XCTAssertTrue(userData.contains("handle_udp_proxy(client, first_chunk)"))
        XCTAssertTrue(userData.contains("upstream.sendall(first_chunk)"))
        XCTAssertTrue(userData.contains("left.join()"))
        XCTAssertTrue(userData.contains("right.join()"))
    }

    func testDockerBootstrapEmbeddedVsockBridgeCompiles() throws {
        let python = try embeddedHeredoc(
            named: "conjet-docker-vsock-bridge.py",
            terminator: "PY",
            from: CloudInitSeedBuilder.dockerBootstrapUserData()
        )
        try assertPythonCompiles(python, fileName: "conjet-docker-vsock-bridge.py")
    }

    func testConjetCoreDockerVsockBridgeCompiles() throws {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = repositoryRoot.appendingPathComponent(
            "guest/image/conjet-core/scripts/conjet-docker-vsock-bridge.py"
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        try assertPythonCompiles(script, fileName: "conjet-docker-vsock-bridge.py")
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
        XCTAssertTrue(script.contains(#""tcp_proxy":true"#))
        XCTAssertTrue(script.contains(#""udp_proxy":true"#))
        XCTAssertTrue(script.contains("TCP_PROXY_PREFIX = b\"CONJET-TCP \""))
        XCTAssertTrue(script.contains("UDP_PROXY_PREFIX = b\"CONJET-UDP \""))
        XCTAssertTrue(script.contains("handle_tcp_proxy(client, first_chunk)"))
        XCTAssertTrue(script.contains("handle_udp_proxy(client, first_chunk)"))
        XCTAssertTrue(script.contains("upstream.sendall(first_chunk)"))

        let readinessCheck = try XCTUnwrap(script.range(of: "if not DOCKER_READY.is_set():"))
        let directConnect = try XCTUnwrap(script.range(of: "upstream.connect(DOCKER_SOCKET)", range: readinessCheck.upperBound..<script.endIndex))
        XCTAssertLessThan(readinessCheck.lowerBound, directConnect.lowerBound)
        let firstClientRead = try XCTUnwrap(script.range(of: "first_chunk = read_first_client_chunk(client)"))
        let clientScopedConnect = try XCTUnwrap(script.range(of: "upstream = connect_docker_with_retry()", range: firstClientRead.upperBound..<script.endIndex))
        XCTAssertLessThan(firstClientRead.lowerBound, clientScopedConnect.lowerBound)
    }

    private func assertPythonCompiles(_ script: String, fileName: String) throws {
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("python3 is not available at \(pythonPath)")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-cloud-init-python-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent(fileName)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-m", "py_compile", scriptURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)
    }

    private func embeddedHeredoc(named fileName: String, terminator: String, from text: String) throws -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try XCTUnwrap(lines.firstIndex { line in
            line.contains("cat >") && line.contains(fileName) && line.contains("<<'\(terminator)'")
        })
        let end = try XCTUnwrap(lines[(start + 1)...].firstIndex { line in
            line.trimmingCharacters(in: .whitespaces) == terminator
        })
        let body = Array(lines[(start + 1)..<end])
        let commonIndent = body
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in line.prefix { $0 == " " }.count }
            .min() ?? 0
        return body.map { line in
            String(line.dropFirst(min(commonIndent, line.count)))
        }.joined(separator: "\n") + "\n"
    }
}

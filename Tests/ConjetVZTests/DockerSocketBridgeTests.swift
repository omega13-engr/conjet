import ConjetCore
import Darwin
import Foundation
@testable import ConjetVZ
import XCTest

final class DockerSocketBridgeTests: XCTestCase {
    func testRetryingConnectorEventuallyConnects() throws {
        let connector = FlakyGuestConnectionConnector(failuresBeforeSuccess: 2)
        let retrying = RetryingGuestConnectionConnector(
            base: connector,
            timeoutSeconds: 1,
            intervalSeconds: 0.01
        )

        let connection = try retrying.connect()
        connection.close()
        XCTAssertEqual(connector.attempts, 3)
    }

    func testRetryingConnectorReportsTimeout() {
        let connector = FlakyGuestConnectionConnector(failuresBeforeSuccess: Int.max)
        let retrying = RetryingGuestConnectionConnector(
            base: connector,
            timeoutSeconds: 0.03,
            intervalSeconds: 0.01
        )

        XCTAssertThrowsError(try retrying.connect()) { error in
            XCTAssertTrue(String(describing: error).contains("timed out waiting for guest Docker bridge"))
        }
        XCTAssertGreaterThanOrEqual(connector.attempts, 2)
    }

    func testPooledConnectorServesPreconnectedConnection() throws {
        let connector = NumberedGuestConnectionConnector()
        let pooled = PooledGuestConnectionConnector(
            base: connector,
            capacity: 1,
            refillDelaySeconds: 0.01
        )
        defer { pooled.closeIdleConnections() }

        XCTAssertTrue(waitUntil { pooled.idleConnectionCountForTesting() == 1 })

        let connection = try pooled.connect()
        defer { connection.close() }
        XCTAssertEqual(connection.fileDescriptor, 1)
    }

    func testPooledConnectorFallsBackWhenPoolIsEmpty() throws {
        let connector = NumberedGuestConnectionConnector()
        let pooled = PooledGuestConnectionConnector(
            base: connector,
            capacity: 0,
            refillDelaySeconds: 0.01
        )
        defer { pooled.closeIdleConnections() }

        let connection = try pooled.connect()
        defer { connection.close() }
        XCTAssertEqual(connection.fileDescriptor, 1)
    }

    func testCapabilityProbeEnablesPoolForLazyGuestBridge() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 45\r
        \r
        {"lazy_upstream":true,"docker_ready_cache":true}

        """)

        XCTAssertTrue(GuestBridgeCapabilityProbe.supportsPooledConnections(connector: connector))
    }

    func testCapabilityProbeDetectsPublishedPortTCPProxy() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 67\r
        \r
        {"lazy_upstream":true,"docker_ready_cache":true,"tcp_proxy":true}

        """)

        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: connector)
        XCTAssertTrue(capabilities.lazyUpstream)
        XCTAssertTrue(capabilities.dockerReadyCache)
        XCTAssertTrue(capabilities.tcpProxy)
    }

    func testCapabilityProbeDetectsConjetNetV2Capabilities() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 220\r
        \r
        {"version":2,"capabilities":{"tcp_proxy":true,"udp_proxy":true,"docker_events":true,"container_ip_lookup":true,"container_target_events":true,"port_probe":true,"proxy_metrics":true},"tcp_proxy":true,"udp_proxy":true}

        """)

        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: connector)
        XCTAssertEqual(capabilities.version, 2)
        XCTAssertTrue(capabilities.tcpProxy)
        XCTAssertTrue(capabilities.containerTargetEvents)
        XCTAssertTrue(capabilities.udpProxy)
        XCTAssertTrue(capabilities.dockerEvents)
        XCTAssertTrue(capabilities.containerIPLookup)
        XCTAssertTrue(capabilities.portProbe)
        XCTAssertTrue(capabilities.proxyMetrics)
    }

    func testCapabilityProbeDetectsConjetNetdCapabilities() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 350\r
        \r
        {"version":6,"capabilities":{"tcp_proxy":true,"udp_proxy":true,"guest_echo":true,"guest_metrics":true,"binary_frames":true,"udp_binary_frames":true,"persistent_vsock":true,"tcp_binary_frames":true,"persistent_tcp_vsock":true,"tcp_vsock_pool":true,"proxy_metrics":true,"guest_control":true,"bridge_engine":"conjet-netd-c"},"tcp_proxy":true,"udp_proxy":true,"guest_echo":true,"guest_metrics":true,"binary_frames":true,"udp_binary_frames":true,"persistent_vsock":true,"tcp_binary_frames":true,"persistent_tcp_vsock":true,"tcp_vsock_pool":true,"guest_control":true}

        """)

        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: connector)
        XCTAssertEqual(capabilities.version, 6)
        XCTAssertTrue(capabilities.guestEcho)
        XCTAssertTrue(capabilities.guestMetrics)
        XCTAssertTrue(capabilities.binaryFrames)
        XCTAssertTrue(capabilities.udpBinaryFrames)
        XCTAssertTrue(capabilities.persistentVsock)
        XCTAssertTrue(capabilities.tcpBinaryFrames)
        XCTAssertTrue(capabilities.persistentTCPVsock)
        XCTAssertTrue(capabilities.tcpVsockPool)
        XCTAssertTrue(capabilities.guestControl)
        XCTAssertEqual(capabilities.bridgeEngine, "conjet-netd-c")
    }

    func testGuestControlClientMountsAllowlistedVirtioFSPath() throws {
        let responseBody = #"{"mounted":true,"already_mounted":false,"target":"/Users","tag":"conjethostusers"}"#
        let connector = RecordingHTTPGuestConnectionConnector(response: """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(Data(responseBody.utf8).count)\r
        \r
        \(responseBody)
        """)

        let result = try GuestControlClient(connector: connector).mountVirtioFS(forHostPath: "/Users/sly/project")

        XCTAssertEqual(result?.target, "/Users")
        XCTAssertEqual(result?.tag, "conjethostusers")
        XCTAssertTrue(result?.mounted == true)
        XCTAssertTrue(waitUntil { connector.requests.count == 1 })
        let request = try XCTUnwrap(connector.requests.first)
        XCTAssertTrue(request.contains("POST /conjet-control/mount-virtiofs HTTP/1.1"))
        XCTAssertTrue(request.contains(#""target":"/Users""#))
        XCTAssertTrue(request.contains(#""tag":"conjethostusers""#))
    }

    func testGuestControlMountRequestRejectsUnmanagedHostPaths() {
        XCTAssertNil(GuestControlClient.mountRequest(forHostPath: "/tmp/project"))
        XCTAssertEqual(GuestControlClient.mountRequest(forHostPath: "/Volumes/ExternalSSD/project")?.target, "/Volumes")
    }

    func testCapabilityProbeRejectsLegacyDockerForwarder() {
        let connector = CapabilityResponseGuestConnectionConnector(response: """
        HTTP/1.1 404 Not Found\r
        Content-Type: application/json\r
        Content-Length: 16\r
        \r
        {"message":"404"}

        """)

        XCTAssertFalse(GuestBridgeCapabilityProbe.supportsPooledConnections(connector: connector))
    }

    func testCompleteFiniteDockerRequestDoesNotNeedClientPump() {
        let request = """
        GET /v1.52/containers/abcdef/json HTTP/1.1\r
        Host: docker\r
        \r

        """

        XCTAssertFalse(DockerSocketBridge.dockerRequestNeedsClientToGuestPump(Data(request.utf8)))
    }

    func testIncompleteDockerRequestStillNeedsClientPump() {
        let request = """
        POST /v1.52/build HTTP/1.1\r
        Host: docker\r
        Content-Length: 32\r
        \r
        partial
        """

        XCTAssertTrue(DockerSocketBridge.dockerRequestNeedsClientToGuestPump(Data(request.utf8)))
    }

    func testBuildRequestRewriteAddsNestedCgroupParent() {
        let request = Data("""
        POST /v1.52/build?t=demo&nocache=1 HTTP/1.1\r
        Host: docker\r
        Content-Length: 0\r
        \r

        """.utf8)

        let rewritten = String(
            data: DockerSocketBridge.addBuildCgroupParentForDockerBuildRequest(request),
            encoding: .utf8
        ) ?? ""

        XCTAssertTrue(rewritten.contains("POST /v1.52/build?t=demo&nocache=1&cgroupparent=/conjet.slice/conjet-build.slice HTTP/1.1"))
    }

    func testBuildRequestRewritePreservesExistingCgroupParent() {
        let request = Data("""
        POST /build?cgroupparent=custom.slice&t=demo HTTP/1.1\r
        Host: docker\r
        Content-Length: 0\r
        \r

        """.utf8)

        let rewritten = String(
            data: DockerSocketBridge.addBuildCgroupParentForDockerBuildRequest(request),
            encoding: .utf8
        ) ?? ""

        XCTAssertTrue(rewritten.contains("POST /build?cgroupparent=custom.slice&t=demo HTTP/1.1"))
        XCTAssertFalse(rewritten.contains("/conjet.slice/conjet-build.slice"))
    }

    func testStreamingDockerRequestStillNeedsClientPump() {
        let request = """
        GET /v1.52/events?filters=%7B%7D HTTP/1.1\r
        Host: docker\r
        \r

        """

        XCTAssertTrue(DockerSocketBridge.dockerRequestNeedsClientToGuestPump(Data(request.utf8)))
    }

    func testUpgradedDockerRequestStillNeedsClientPump() {
        let request = """
        POST /v1.52/containers/abcdef/attach?stream=1&stdout=1 HTTP/1.1\r
        Host: docker\r
        Connection: Upgrade\r
        Upgrade: tcp\r
        Content-Length: 0\r
        \r

        """

        XCTAssertTrue(DockerSocketBridge.dockerRequestNeedsClientToGuestPump(Data(request.utf8)))
    }

    func testStartAndStopOwnsDockerSocketPath() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: UnavailableGuestConnectionConnector()
        )

        try bridge.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertTrue(bridge.isRunning())

        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertFalse(bridge.isRunning())
    }

    func testUnavailableGuestReturnsHTTP503() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: UnavailableGuestConnectionConnector(message: "guest not booted")
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path)
        XCTAssertTrue(response.contains("503 Service Unavailable"))
        XCTAssertTrue(response.contains("guest not booted"))
    }

    func testBridgeWaitsForNonblockingGuestReadiness() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let body = #"{"ok":true}"#
        let connector = DelayedNonblockingDockerResponseGuestConnectionConnector(
            delaySeconds: 0.05,
            body: body
        )
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(socketPath: socket.path, connector: connector)
        try bridge.start()
        defer { bridge.stop() }

        let request = """
        GET /v1.52/containers/abcdef/json HTTP/1.1\r
        Host: docker\r
        \r

        """
        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("200 OK"), response)
        XCTAssertTrue(response.contains(body), response)
        XCTAssertTrue(waitUntil {
            connector.requests.first?.contains("GET /v1.52/containers/abcdef/json") == true
        })
    }

    func testBridgeObservesCreateIntentAndResolutionWhileForwardingBytes() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let body = #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}}}"#
        let request = """
        POST /v1.52/containers/create?name=web HTTP/1.1\r
        Host: docker\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """
        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let connector = DockerCreateResponseGuestConnectionConnector(containerID: containerID)
        let observed = ObservedCreateCallbacks()
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: connector,
            createPublicationIntentHandler: { intent in
                observed.setIntent(intent)
            },
            createPublicationResolutionHandler: { resolution in
                observed.setResolution(resolution)
            }
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("201 Created"))
        XCTAssertTrue(waitUntil { observed.intent != nil && observed.resolution != nil })
        XCTAssertEqual(observed.intent?.containerName, "web")
        XCTAssertEqual(observed.intent?.ports.first?.hostPort, 8080)
        XCTAssertEqual(observed.resolution?.containerID, containerID)
        XCTAssertEqual(observed.resolution?.intent, observed.intent)
        XCTAssertTrue(waitUntil { connector.requests.first?.contains("POST /v1.52/containers/create?name=web") == true })
    }

    func testBridgeRegistersManagedHostMountCreateWithoutPublishedPorts() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let body = #"{"Image":"busybox:1.36","HostConfig":{"Mounts":[{"Type":"volume","Source":"conjet-hostsync-test","Target":"/workspace"}]}}"#
        let request = """
        POST /v1.52/containers/create?name=web HTTP/1.1\r
        Host: docker\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """
        let rewrite = DockerManagedHostMountRewriteResult(
            requestData: Data(request.utf8),
            mounts: [
                DockerManagedHostMountBinding(
                    hostPath: root.path,
                    volumeName: "conjet-hostsync-test",
                    targetPath: "/workspace",
                    readOnly: false
                )
            ]
        )
        let managed = RecordingManagedHostMounts(rewrite: rewrite)
        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let connector = DockerCreateResponseGuestConnectionConnector(containerID: containerID)
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: connector,
            managedHostMounts: managed
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("201 Created"))
        XCTAssertTrue(waitUntil { managed.registeredContainerID == containerID })
    }

    func testBridgeObservesSuccessfulContainerStartWhileForwardingBytes() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = """
        POST /v1.52/containers/abcdef012345/start HTTP/1.1\r
        Host: docker\r
        Content-Length: 0\r
        \r

        """
        let connector = DockerStartResponseGuestConnectionConnector(statusCode: 204)
        let observed = ObservedStartCallbacks()
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: connector,
            containerStartHandler: { request in
                observed.setRequest(request)
            }
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("204 No Content"))
        XCTAssertTrue(waitUntil { observed.request != nil })
        XCTAssertEqual(observed.request?.containerID, "abcdef012345")
        XCTAssertEqual(observed.request?.requestPath, "/v1.52/containers/abcdef012345/start")
        XCTAssertTrue(waitUntil { connector.requests.first?.contains("POST /v1.52/containers/abcdef012345/start") == true })
    }

    func testBridgeEmitsBuildMemoryActivityWithoutGuestNetworkCapability() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = """
        POST /v1.52/build?t=demo HTTP/1.1\r
        Host: docker\r
        Content-Length: 0\r
        \r

        """
        let connector = DockerStartResponseGuestConnectionConnector(statusCode: 204)
        let observed = ObservedMemoryActivityCallbacks()
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: connector,
            activityHandler: { activity in
                observed.append(activity)
            }
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("204 No Content"))
        XCTAssertTrue(waitUntil { observed.events.contains(where: { $0.kind == .workloadFinished }) })
        XCTAssertTrue(waitUntil {
            connector.requests.first?.contains("cgroupparent=/conjet.slice/conjet-build.slice") == true
        })
        XCTAssertTrue(observed.events.contains(DockerMemoryActivity(
            kind: .workloadStarted,
            workload: .build,
            activeStreams: 1,
            buildLike: true
        )))
        XCTAssertTrue(observed.events.contains(DockerMemoryActivity(
            kind: .workloadFinished,
            workload: .build,
            activeStreams: 0,
            buildLike: true
        )))
    }

    func testBridgeClassifiesBuildKitSessionAsBuildMemoryActivity() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = """
        POST /v1.52/session HTTP/1.1\r
        Host: docker\r
        Content-Length: 0\r
        \r

        """
        let connector = DockerStartResponseGuestConnectionConnector(statusCode: 204)
        let observed = ObservedMemoryActivityCallbacks()
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: connector,
            activityHandler: { activity in
                observed.append(activity)
            }
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("204 No Content"))
        XCTAssertTrue(waitUntil { observed.events.contains(where: { $0.kind == .workloadStarted }) })
        let started = observed.events.first { $0.kind == .workloadStarted }
        XCTAssertEqual(started?.workload, .build)
        XCTAssertEqual(started?.pressureStreams, 1)
        XCTAssertEqual(started?.buildLike, true)
    }

    func testBridgeEmitsBuildStreamPhaseFinishedFromBuildKitOutput() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = """
        POST /v1.52/build?t=demo HTTP/1.1\r
        Host: docker\r
        Content-Length: 0\r
        \r

        """
        let responseBody = """
        {"stream":"#1 [internal] load build definition from Dockerfile\\n"}
        {"stream":"#1 DONE 0.1s\\n"}

        """
        let connector = RawDockerResponseGuestConnectionConnector(
            statusCode: 200,
            reason: "OK",
            body: responseBody
        )
        let observed = ObservedMemoryActivityCallbacks()
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: connector,
            activityHandler: { activity in
                observed.append(activity)
            }
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("#1 DONE 0.1s"))
        XCTAssertTrue(waitUntil {
            connector.requests.first?.contains("cgroupparent=/conjet.slice/conjet-build.slice") == true
        })
        XCTAssertTrue(waitUntil { observed.events.contains(where: { $0.kind == .streamPhaseFinished }) })
        let phase = observed.events.first { $0.kind == .streamPhaseFinished }
        XCTAssertEqual(phase?.workload, .build)
        XCTAssertEqual(phase?.activeStreams, 1)
        XCTAssertEqual(phase?.pressureStreams, 1)
        XCTAssertEqual(phase?.buildLike, true)
    }

    func testBridgeExcludesDockerEventsFromMemoryPressureStreams() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = """
        GET /v1.52/events?filters=%7B%7D HTTP/1.1\r
        Host: docker\r
        Content-Length: 0\r
        \r

        """
        let connector = DockerStartResponseGuestConnectionConnector(statusCode: 204)
        let observed = ObservedMemoryActivityCallbacks()
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: connector,
            activityHandler: { activity in
                observed.append(activity)
            }
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("204 No Content"))
        XCTAssertTrue(waitUntil { observed.events.contains(where: { $0.kind == .streamClosed }) })
        let opened = observed.events.first { $0.kind == .streamOpened }
        XCTAssertEqual(opened?.workload, .events)
        XCTAssertEqual(opened?.activeStreams, 1)
        XCTAssertEqual(opened?.pressureStreams, 0)
        let closed = observed.events.first { $0.kind == .streamClosed }
        XCTAssertEqual(closed?.workload, .events)
        XCTAssertEqual(closed?.activeStreams, 0)
        XCTAssertEqual(closed?.pressureStreams, 0)
    }

    func testBridgeDoesNotObserveFailedContainerStart() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = "POST /containers/abcdef012345/start HTTP/1.1\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"
        let connector = DockerStartResponseGuestConnectionConnector(statusCode: 404)
        let observed = ObservedStartCallbacks()
        let socket = root.appendingPathComponent("docker.sock")
        let bridge = DockerSocketBridge(
            socketPath: socket.path,
            connector: connector,
            containerStartHandler: { request in
                observed.setRequest(request)
            }
        )
        try bridge.start()
        defer { bridge.stop() }

        let response = try sendRawRequest(socketPath: socket.path, request: request)

        XCTAssertTrue(response.contains("404 Not Found"))
        XCTAssertFalse(waitUntil(timeoutSeconds: 0.05) { observed.request != nil })
    }

    func testManagedHostMountRewriterConvertsDockerMountToVolume() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-hostmount-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("host-token".utf8).write(to: root.appendingPathComponent("token.txt"))

        let body = """
        {"Image":"busybox:1.36","HostConfig":{"Mounts":[{"Type":"bind","Source":"\(root.path)","Target":"/workspace","ReadOnly":false}]}}
        """
        let request = """
        POST /v1.52/containers/create?name=web HTTP/1.1\r
        Host: docker\r
        Content-Type: application/json\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """

        let rewrite = try XCTUnwrap(DockerManagedHostMountRequestRewriter.rewrite(
            Data(request.utf8),
            allowedHostPathPrefixes: ["/tmp"]
        ))
        XCTAssertEqual(rewrite.mounts.count, 1)
        XCTAssertEqual(rewrite.mounts.first?.hostPath, root.standardized.path)
        XCTAssertEqual(rewrite.mounts.first?.targetPath, "/workspace")

        let rewritten = String(data: rewrite.requestData, encoding: .utf8) ?? ""
        XCTAssertTrue(rewritten.contains(#""Type":"volume""#))
        XCTAssertTrue(rewritten.contains(#""Target":"\/workspace""#) || rewritten.contains(#""Target":"/workspace""#))
        XCTAssertTrue(rewritten.contains(rewrite.mounts[0].volumeName))
        XCTAssertFalse(rewritten.contains(root.path))
        XCTAssertTrue(rewritten.contains("Content-Length:"))
        XCTAssertFalse(rewritten.contains("Transfer-Encoding: chunked"))
    }

    func testManagedHostMountRewriterHonorsContentLengthWhenSocketReadIncludesExtraBytes() throws {
        let root = URL(fileURLWithPath: "/tmp/cjbr-hostmount-extra-\(shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let body = #"{"Image":"busybox:1.36","HostConfig":{"Binds":["\#(root.path):/workspace:rw"]}}"#
        var request = Data("""
        POST /containers/create HTTP/1.1\r
        Host: docker\r
        Content-Type: application/json\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """.utf8)
        request.append(Data("GET /_ping HTTP/1.1\r\n\r\n".utf8))

        let rewrite = try XCTUnwrap(DockerManagedHostMountRequestRewriter.rewrite(
            request,
            allowedHostPathPrefixes: ["/tmp"]
        ))

        XCTAssertEqual(rewrite.mounts.first?.hostPath, root.standardized.path)
        XCTAssertTrue((String(data: rewrite.requestData, encoding: .utf8) ?? "").contains(rewrite.mounts[0].volumeName))
    }

    func testManagedHostMountCoordinatorSkipsGuestVirtioFSMountWhenDisabled() throws {
        let root = try managedHostMountTestRoot(prefix: "cjbr-hostmount-disabled")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("host-token".utf8).write(to: source.appendingPathComponent("token.txt"))

        let connector = ManagedHostMountDockerAPIConnector(mountStatusCode: 503)
        let coordinator = DockerManagedHostMountCoordinator(
            connector: connector,
            allowedHostPathPrefixes: [root.path],
            requestGuestControlMounts: false,
            requireGuestControlMounts: false,
            workDirectory: work
        )

        let rewrite = try XCTUnwrap(try coordinator.rewriteCreateRequest(managedHostMountCreateRequest(source: source.path)))

        XCTAssertEqual(rewrite.mounts.first?.hostPath, source.standardized.path)
        XCTAssertFalse(connector.requests.contains { $0.contains("/conjet-control/mount-virtiofs") })
        XCTAssertTrue(connector.requests.contains { $0.contains("POST /v1.45/volumes/create") })
        XCTAssertTrue(connector.requests.contains { $0.contains("PUT /v1.45/containers/helper/archive") })
    }

    func testManagedHostMountCoordinatorTreatsGuestVirtioFSMountFailureAsAdvisory() throws {
        let root = try managedHostMountTestRoot(prefix: "cjbr-hostmount-advisory")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("host-token".utf8).write(to: source.appendingPathComponent("token.txt"))

        let connector = ManagedHostMountDockerAPIConnector(mountStatusCode: 503)
        let coordinator = DockerManagedHostMountCoordinator(
            connector: connector,
            allowedHostPathPrefixes: [root.path],
            requestGuestControlMounts: true,
            requireGuestControlMounts: false,
            workDirectory: work
        )

        let rewrite = try XCTUnwrap(try coordinator.rewriteCreateRequest(managedHostMountCreateRequest(source: source.path)))

        XCTAssertEqual(rewrite.mounts.first?.hostPath, source.standardized.path)
        XCTAssertTrue(connector.requests.contains { $0.contains("POST /conjet-control/mount-virtiofs") })
        XCTAssertTrue(connector.requests.contains { $0.contains("POST /v1.45/volumes/create") })
    }

    func testManagedHostMountCoordinatorPullsMissingHelperImage() throws {
        let root = try managedHostMountTestRoot(prefix: "cjbr-hostmount-helper-image")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("host-token".utf8).write(to: source.appendingPathComponent("token.txt"))

        let connector = ManagedHostMountDockerAPIConnector(
            mountStatusCode: 503,
            helperImageMissingOnce: true
        )
        let coordinator = DockerManagedHostMountCoordinator(
            connector: connector,
            allowedHostPathPrefixes: [root.path],
            requestGuestControlMounts: false,
            requireGuestControlMounts: false,
            workDirectory: work
        )

        let rewrite = try XCTUnwrap(try coordinator.rewriteCreateRequest(managedHostMountCreateRequest(source: source.path)))

        XCTAssertEqual(rewrite.mounts.first?.hostPath, source.standardized.path)
        XCTAssertEqual(connector.requests.filter { $0.contains("POST /v1.45/containers/create") }.count, 2)
        XCTAssertTrue(connector.requests.contains { $0.contains("POST /v1.45/images/create?fromImage=busybox&tag=1.36") })
        XCTAssertTrue(connector.requests.contains { $0.contains("PUT /v1.45/containers/helper/archive") })
    }

    func testManagedHostMountInterceptionForcesConnectionCloseForOrdinaryRequests() {
        let request = Data("""
        GET /_ping HTTP/1.1\r
        Host: docker\r
        Connection: keep-alive\r
        \r

        """.utf8)

        let rewritten = String(
            data: DockerSocketBridge.forceConnectionCloseForInterceptableRequest(request),
            encoding: .utf8
        ) ?? ""

        XCTAssertTrue(rewritten.contains("Connection: close\r\n"))
        XCTAssertFalse(rewritten.contains("Connection: keep-alive"))
    }

    func testManagedHostMountInterceptionKeepsStreamingRequestsOpen() {
        let request = Data("""
        POST /v1.52/containers/abcdef/attach?stream=1&stdout=1 HTTP/1.1\r
        Host: docker\r
        Connection: Upgrade\r
        Upgrade: tcp\r
        \r

        """.utf8)

        let rewritten = String(
            data: DockerSocketBridge.forceConnectionCloseForInterceptableRequest(request),
            encoding: .utf8
        ) ?? ""

        XCTAssertTrue(rewritten.contains("Connection: Upgrade"))
        XCTAssertFalse(rewritten.contains("Connection: close"))
    }

    func testContainerRemoveParserExtractsVersionedContainerID() {
        let request = "DELETE /v1.52/containers/abcdef012345?v=true&force=false HTTP/1.1\r\nHost: docker\r\n\r\n"

        XCTAssertEqual(
            DockerContainerRemoveRequestParser.containerID(from: Data(request.utf8)),
            "abcdef012345"
        )
    }

    func testContainerWaitParserExtractsVersionedContainerID() {
        let request = "POST /v1.52/containers/abcdef012345/wait?condition=not-running HTTP/1.1\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"

        XCTAssertEqual(
            DockerContainerWaitRequestParser.containerID(from: Data(request.utf8)),
            "abcdef012345"
        )
    }

    func testContainerAttachParserExtractsVersionedContainerID() {
        let request = "POST /v1.52/containers/abcdef012345/attach?stream=1&stdout=1 HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\n\r\n"

        XCTAssertEqual(
            DockerContainerAttachRequestParser.containerID(from: Data(request.utf8)),
            "abcdef012345"
        )
    }

    func testDockerCreateRequestParserExtractsPortBindings() throws {
        let body = """
        {"Image":"nginx","HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}],"53/udp":[{"HostIp":"0.0.0.0","HostPort":"5353"}],"443/tcp":[{"HostIp":"","HostPort":""}]}}}
        """
        let request = """
        POST /v1.52/containers/create?name=web%2D1 HTTP/1.1\r
        Host: docker\r
        Content-Type: application/json\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """

        let intent = DockerCreateRequestParser.intent(from: Data(request.utf8))
        XCTAssertEqual(intent?.requestPath, "/v1.52/containers/create?name=web%2D1")
        XCTAssertEqual(intent?.containerName, "web-1")
        XCTAssertEqual(intent?.ports, [
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: 8080,
                containerPort: 80,
                protocol: .tcp,
                containerName: "web-1"
            ),
            DockerPublishedPort(
                hostIP: "0.0.0.0",
                hostPort: 5353,
                containerPort: 53,
                protocol: .udp,
                containerName: "web-1"
            )
        ])
    }

    func testDockerCreateRequestParserExtractsChunkedPortBindings() throws {
        let body = #"{"Image":"nginx","HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}}}"#
        let bodyData = Data(body.utf8)
        let first = String(data: bodyData.prefix(24), encoding: .utf8) ?? ""
        let second = String(data: bodyData.dropFirst(24), encoding: .utf8) ?? ""
        let request = """
        POST /v1.52/containers/create?name=web HTTP/1.1\r
        Host: docker\r
        Transfer-Encoding: chunked\r
        \r
        \(String(24, radix: 16))\r
        \(first)\r
        \(String(Data(second.utf8).count, radix: 16))\r
        \(second)\r
        0\r
        \r

        """

        let intent = DockerCreateRequestParser.intent(from: Data(request.utf8))

        XCTAssertEqual(intent?.containerName, "web")
        XCTAssertEqual(intent?.ports, [
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: 8080,
                containerPort: 80,
                protocol: .tcp,
                containerName: "web"
            )
        ])
    }

    func testDockerCreateRequestParserIgnoresNonCreateRequests() {
        let request = "GET /v1.52/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n"

        XCTAssertNil(DockerCreateRequestParser.intent(from: Data(request.utf8)))
    }

    func testDockerStartRequestParserExtractsVersionedContainerID() {
        let request = "POST /v1.52/containers/abcdef012345/start HTTP/1.1\r\nHost: docker\r\n\r\n"

        let start = DockerStartRequestParser.startRequest(from: Data(request.utf8))

        XCTAssertEqual(start?.containerID, "abcdef012345")
        XCTAssertEqual(start?.requestPath, "/v1.52/containers/abcdef012345/start")
    }

    func testDockerStartRequestParserIgnoresNonStartRequests() {
        let request = "POST /v1.52/containers/abcdef012345/stop HTTP/1.1\r\nHost: docker\r\n\r\n"

        XCTAssertNil(DockerStartRequestParser.startRequest(from: Data(request.utf8)))
    }

    func testDockerCreateRequestParserReportsMissingBodyBytes() {
        let body = #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}"#
        let partialBody = String(body.prefix(12))
        let request = """
        POST /containers/create HTTP/1.1\r
        Host: docker\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(partialBody)
        """

        XCTAssertEqual(
            DockerCreateRequestParser.additionalBodyBytesNeeded(in: Data(request.utf8)),
            Data(body.utf8).count - Data(partialBody.utf8).count
        )
        XCTAssertNil(DockerCreateRequestParser.intent(from: Data(request.utf8)))
    }

    func testDockerCreateResponseParserExtractsContainerID() {
        let body = #"{"Id":"abcdef0123456789","Warnings":[]}"#
        let response = """
        HTTP/1.1 201 Created\r
        Content-Type: application/json\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """

        XCTAssertEqual(DockerCreateResponseParser.containerID(from: Data(response.utf8)), "abcdef0123456789")
    }

    func testDockerCreateResponseParserReportsMissingBodyBytes() {
        let body = #"{"Id":"abcdef0123456789","Warnings":[]}"#
        let partialBody = String(body.prefix(10))
        let response = """
        HTTP/1.1 201 Created\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(partialBody)
        """

        XCTAssertEqual(
            DockerCreateResponseParser.additionalBodyBytesNeeded(in: Data(response.utf8)),
            Data(body.utf8).count - Data(partialBody.utf8).count
        )
        XCTAssertNil(DockerCreateResponseParser.containerID(from: Data(response.utf8)))
    }

    private func sendRawRequest(socketPath: String) throws -> String {
        try sendRawRequest(socketPath: socketPath, request: "GET /_ping HTTP/1.1\r\nHost: conjet\r\n\r\n")
    }

    private func sendRawRequest(socketPath: String, request: String) throws -> String {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        try withUnixSocketAddress(path: socketPath) { address, length in
            XCTAssertEqual(Darwin.connect(fd, address, length), 0)
        }

        _ = request.withCString { pointer in
            Darwin.write(fd, pointer, strlen(pointer))
        }
        Darwin.shutdown(fd, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func withUnixSocketAddress<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, length)
            }
        }
    }

    private func shortID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private func managedHostMountCreateRequest(source: String) -> Data {
        let body = #"{"Image":"busybox:1.36","HostConfig":{"Mounts":[{"Type":"bind","Source":"\#(source)","Target":"/workspace","ReadOnly":false}]}}"#
        return Data("""
        POST /v1.52/containers/create HTTP/1.1\r
        Host: docker\r
        Content-Type: application/json\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """.utf8)
    }

    private func managedHostMountTestRoot(prefix: String) throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".\(prefix)-\(shortID())", isDirectory: true)
        guard GuestControlClient.mountRequest(forHostPath: root.path) != nil else {
            throw XCTSkip("home directory is not under a managed host-share prefix")
        }
        return root
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 1,
        intervalSeconds: TimeInterval = 0.01,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() {
                return true
            }
            Thread.sleep(forTimeInterval: intervalSeconds)
        }
        return predicate()
    }
}

private final class FlakyGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let failuresBeforeSuccess: Int
    private var attemptCount = 0

    var attempts: Int {
        lock.lock()
        let value = attemptCount
        lock.unlock()
        return value
    }

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func connect() throws -> GuestConnection {
        lock.lock()
        attemptCount += 1
        let shouldFail = attemptCount <= failuresBeforeSuccess
        lock.unlock()

        if shouldFail {
            throw ConjetError.unavailable("guest not ready")
        }
        return GuestConnection(fileDescriptor: -1) {}
    }
}

private final class NumberedGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var nextFileDescriptor: Int32 = 1

    func connect() throws -> GuestConnection {
        lock.lock()
        let fileDescriptor = nextFileDescriptor
        nextFileDescriptor += 1
        lock.unlock()

        return GuestConnection(fileDescriptor: fileDescriptor) {}
    }
}

private final class CapabilityResponseGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let response: String

    init(response: String) {
        self.response = response
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        let response = response
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(serverFD, &buffer, buffer.count)
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.close(serverFD)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class RecordingHTTPGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let response: String
    private var seenRequests: [String] = []

    init(response: String) {
        self.response = response
    }

    var requests: [String] {
        lock.lock()
        let value = seenRequests
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        let response = response
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(serverFD, &buffer, buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            let requestText = String(data: data, encoding: .utf8) ?? ""
            self.lock.lock()
            self.seenRequests.append(requestText)
            self.lock.unlock()
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class DelayedNonblockingDockerResponseGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let delaySeconds: TimeInterval
    private let body: String
    private var seenRequests: [String] = []

    init(delaySeconds: TimeInterval, body: String) {
        self.delaySeconds = delaySeconds
        self.body = body
    }

    var requests: [String] {
        lock.lock()
        let value = seenRequests
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        let flags = Darwin.fcntl(clientFD, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(clientFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(clientFD)
            Darwin.close(serverFD)
            throw ConjetError.socket("fcntl(O_NONBLOCK) failed")
        }

        let delaySeconds = delaySeconds
        let body = body
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let request = readAllSocketBridgeTestBytes(from: serverFD)
            let requestText = String(data: request, encoding: .utf8) ?? ""
            self.lock.lock()
            self.seenRequests.append(requestText)
            self.lock.unlock()

            Thread.sleep(forTimeInterval: delaySeconds)
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(Data(body.utf8).count)\r
            \r
            \(body)
            """
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class ManagedHostMountDockerAPIConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let mountStatusCode: Int
    private var helperImageMissingOnce: Bool
    private var seenRequests: [String] = []

    init(mountStatusCode: Int, helperImageMissingOnce: Bool = false) {
        self.mountStatusCode = mountStatusCode
        self.helperImageMissingOnce = helperImageMissingOnce
    }

    var requests: [String] {
        lock.lock()
        let value = seenRequests
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let request = readManagedHostMountHTTPRequest(from: serverFD)
            let requestText = String(data: request, encoding: .utf8) ?? ""
            self.lock.lock()
            self.seenRequests.append(requestText)
            self.lock.unlock()

            let response = self.response(for: requestText)
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }

    private func response(for request: String) -> String {
        if request.contains("POST /conjet-control/mount-virtiofs") {
            let body = #"{"mounted":false,"already_mounted":false,"target":"/Users","tag":"conjethostusers","error":"mount failed: Invalid argument"}"#
            return httpResponse(statusCode: mountStatusCode, reason: "Service Unavailable", body: body)
        }
        if request.contains("DELETE /v1.45/volumes/") {
            return httpResponse(statusCode: 404, reason: "Not Found", body: #"{"message":"not found"}"#)
        }
        if request.contains("POST /v1.45/volumes/create") {
            return httpResponse(statusCode: 201, reason: "Created", body: #"{"Name":"conjet-hostsync-test"}"#)
        }
        if request.contains("POST /v1.45/containers/create") {
            lock.lock()
            let shouldMissHelperImage = helperImageMissingOnce
            helperImageMissingOnce = false
            lock.unlock()
            if shouldMissHelperImage {
                return httpResponse(statusCode: 404, reason: "Not Found", body: #"{"message":"No such image: busybox:1.36"}"#)
            }
            return httpResponse(statusCode: 201, reason: "Created", body: #"{"Id":"helper","Warnings":[]}"#)
        }
        if request.contains("POST /v1.45/images/create?fromImage=busybox&tag=1.36") {
            return httpResponse(statusCode: 200, reason: "OK", body: #"{"status":"Downloaded newer image for busybox:1.36"}"#)
        }
        if request.contains("POST /v1.45/containers/helper/start") {
            return httpResponse(statusCode: 204, reason: "No Content")
        }
        if request.contains("PUT /v1.45/containers/helper/archive") {
            return httpResponse(statusCode: 200, reason: "OK", body: #"{}"#)
        }
        if request.contains("DELETE /v1.45/containers/helper") {
            return httpResponse(statusCode: 204, reason: "No Content")
        }
        return httpResponse(statusCode: 500, reason: "Unexpected Request", body: #"{"message":"unexpected request"}"#)
    }

    private func httpResponse(statusCode: Int, reason: String, body: String = "") -> String {
        """
        HTTP/1.1 \(statusCode) \(reason)\r
        Content-Type: application/json\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """
    }
}

private final class DockerCreateResponseGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let containerID: String
    private var seenRequests: [String] = []

    init(containerID: String) {
        self.containerID = containerID
    }

    var requests: [String] {
        lock.lock()
        let value = seenRequests
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        let containerID = containerID
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let request = readAllSocketBridgeTestBytes(from: serverFD)
            let requestText = String(data: request, encoding: .utf8) ?? ""
            self.lock.lock()
            self.seenRequests.append(requestText)
            self.lock.unlock()

            let body = #"{"Id":"\#(containerID)","Warnings":[]}"#
            let response = """
            HTTP/1.1 201 Created\r
            Content-Type: application/json\r
            Content-Length: \(Data(body.utf8).count)\r
            \r
            \(body)
            """
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class DockerStartResponseGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let statusCode: Int
    private var seenRequests: [String] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    var requests: [String] {
        lock.lock()
        let value = seenRequests
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        let statusCode = statusCode
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let request = readAllSocketBridgeTestBytes(from: serverFD)
            let requestText = String(data: request, encoding: .utf8) ?? ""
            self.lock.lock()
            self.seenRequests.append(requestText)
            self.lock.unlock()

            let reason = statusCode == 204 ? "No Content" : "Not Found"
            let response = """
            HTTP/1.1 \(statusCode) \(reason)\r
            Content-Length: 0\r
            \r

            """
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class RawDockerResponseGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let statusCode: Int
    private let reason: String
    private let body: String
    private var seenRequests: [String] = []

    init(statusCode: Int, reason: String, body: String) {
        self.statusCode = statusCode
        self.reason = reason
        self.body = body
    }

    var requests: [String] {
        lock.lock()
        let value = seenRequests
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        let statusCode = statusCode
        let reason = reason
        let body = body
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let request = readAllSocketBridgeTestBytes(from: serverFD)
            let requestText = String(data: request, encoding: .utf8) ?? ""
            self.lock.lock()
            self.seenRequests.append(requestText)
            self.lock.unlock()

            let response = """
            HTTP/1.1 \(statusCode) \(reason)\r
            Content-Type: application/json\r
            Content-Length: \(Data(body.utf8).count)\r
            \r
            \(body)
            """
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class ObservedCreateCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedIntent: DockerCreatePublicationIntent?
    private var capturedResolution: DockerCreatePublicationResolution?

    var intent: DockerCreatePublicationIntent? {
        lock.lock()
        let value = capturedIntent
        lock.unlock()
        return value
    }

    var resolution: DockerCreatePublicationResolution? {
        lock.lock()
        let value = capturedResolution
        lock.unlock()
        return value
    }

    func setIntent(_ intent: DockerCreatePublicationIntent) {
        lock.lock()
        capturedIntent = intent
        lock.unlock()
    }

    func setResolution(_ resolution: DockerCreatePublicationResolution) {
        lock.lock()
        capturedResolution = resolution
        lock.unlock()
    }
}

private final class ObservedStartCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequest: DockerContainerStartRequest?

    var request: DockerContainerStartRequest? {
        lock.lock()
        let value = capturedRequest
        lock.unlock()
        return value
    }

    func setRequest(_ request: DockerContainerStartRequest) {
        lock.lock()
        capturedRequest = request
        lock.unlock()
    }
}

private final class ObservedMemoryActivityCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedEvents: [DockerMemoryActivity] = []

    var events: [DockerMemoryActivity] {
        lock.lock()
        let value = capturedEvents
        lock.unlock()
        return value
    }

    func append(_ event: DockerMemoryActivity) {
        lock.lock()
        capturedEvents.append(event)
        lock.unlock()
    }
}

private final class RecordingManagedHostMounts: DockerManagedHostMounting, @unchecked Sendable {
    private let lock = NSLock()
    private let rewrite: DockerManagedHostMountRewriteResult?
    private var capturedContainerID: String?

    init(rewrite: DockerManagedHostMountRewriteResult?) {
        self.rewrite = rewrite
    }

    var registeredContainerID: String? {
        lock.lock()
        let value = capturedContainerID
        lock.unlock()
        return value
    }

    func rewriteCreateRequest(_ data: Data) throws -> DockerManagedHostMountRewriteResult? {
        rewrite
    }

    func register(containerID: String, rewrite: DockerManagedHostMountRewriteResult) {
        lock.lock()
        capturedContainerID = containerID
        lock.unlock()
    }

    func copyBack(containerID: String) throws -> Int {
        0
    }

    func copyBackBeforeContainerRemoval(requestData: Data) throws -> Int {
        0
    }

    func copyBackAfterContainerWait(requestData: Data) throws -> Int {
        0
    }
}

private func readAllSocketBridgeTestBytes(from fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") {
                break
            }
        } else if count < 0, errno == EINTR {
            continue
        } else {
            break
        }
    }
    return data
}

private func readManagedHostMountHTTPRequest(from fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
            if let expectedCount = expectedManagedHostMountHTTPRequestByteCount(data),
               data.count >= expectedCount {
                break
            }
        } else if count < 0, errno == EINTR {
            continue
        } else {
            break
        }
    }
    return data
}

private func expectedManagedHostMountHTTPRequestByteCount(_ data: Data) -> Int? {
    let delimiter = Data([13, 10, 13, 10])
    guard let range = data.range(of: delimiter),
          let headerText = String(data: Data(data[..<range.lowerBound]), encoding: .utf8) else {
        return nil
    }
    let contentLength = headerText
        .split(separator: "\r\n", omittingEmptySubsequences: false)
        .first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { line -> Int? in
            let value = line.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value)
        } ?? 0
    return range.upperBound + contentLength
}

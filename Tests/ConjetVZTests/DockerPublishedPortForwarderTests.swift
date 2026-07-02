import ConjetCore
import Darwin
import Foundation
@testable import ConjetVZ
import XCTest

final class DockerPublishedPortForwarderTests: XCTestCase {
    func testParsesDockerInspectPublishedTCPPorts() throws {
        let json = """
        [
          {
            "Id": "abc123",
            "Name": "/web",
            "State": {"Running": true},
            "NetworkSettings": {
              "Ports": {
                "63000/tcp": [{"HostIp": "0.0.0.0", "HostPort": "63000"}],
                "63001/tcp": [{"HostIp": "127.0.0.1", "HostPort": "63001"}],
                "8125/udp": [{"HostIp": "0.0.0.0", "HostPort": "8125"}],
                "9000/tcp": null
              }
            }
          }
        ]
        """

        let ports = DockerPublishedPortForwarder.publishedPorts(fromDockerInspectJSON: Data(json.utf8))

        XCTAssertEqual(ports, [
            DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 63000, containerPort: 63000, protocol: .tcp, containerID: "abc123", containerName: "web"),
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: 63001, containerPort: 63001, protocol: .tcp, containerID: "abc123", containerName: "web"),
            DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 8125, containerPort: 8125, protocol: .udp, containerID: "abc123", containerName: "web")
        ])
    }

    func testDockerInspectTargetSelectionPrefersBridgeThenComposeDefault() throws {
        let bridgeJSON = """
        [
          {
            "Id": "abc123",
            "Name": "/web",
            "State": {"Running": true},
            "NetworkSettings": {
              "Ports": {
                "80/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]
              },
              "Networks": {
                "zz_custom": {"IPAddress": "172.31.0.44"},
                "app_default": {"IPAddress": "172.22.0.9"},
                "bridge": {"IPAddress": "172.17.0.2"}
              }
            }
          }
        ]
        """
        let bridgePorts = DockerPublishedPortForwarder.publishedPorts(fromDockerInspectJSON: Data(bridgeJSON.utf8))
        XCTAssertEqual(bridgePorts.first?.targetIP, "172.17.0.2")

        let composeJSON = """
        [
          {
            "Id": "abc123",
            "Name": "/web",
            "State": {"Running": true},
            "NetworkSettings": {
              "Ports": {
                "80/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]
              },
              "Networks": {
                "zz_custom": {"IPAddress": "172.31.0.44"},
                "app_default": {"IPAddress": "172.22.0.9"},
                "aa_custom": {"IPAddress": "172.40.0.3"}
              }
            }
          }
        ]
        """
        let composePorts = DockerPublishedPortForwarder.publishedPorts(fromDockerInspectJSON: Data(composeJSON.utf8))
        XCTAssertEqual(composePorts.first?.targetIP, "172.22.0.9")
    }

    func testDiscoveryCacheKeepsPublishedPortsAcrossFullReconcile() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let fullID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let shortID = String(fullID.prefix(12))
        let inspectJSON = """
        [
          {
            "Id": "\(fullID)",
            "Name": "/api",
            "State": {"Running": true},
            "NetworkSettings": {
              "Ports": {
                "63001/tcp": [{"HostIp": "0.0.0.0", "HostPort": "63001"}]
              },
              "Networks": {
                "default": {"IPAddress": "172.18.0.5"}
              }
            }
          }
        ]
        """

        let runner = DockerDiscoveryRunner(fullID: fullID, shortID: shortID, inspectJSON: inspectJSON)
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: UnavailableGuestConnectionConnector(),
            runner: runner.run
        )
        defer { forwarder.stop() }

        let first = forwarder.discoverPublishedPortsForTesting()
        let second = forwarder.discoverPublishedPortsForTesting()

        XCTAssertEqual(first, [
            DockerPublishedPort(
                hostIP: "0.0.0.0",
                hostPort: 63001,
                containerPort: 63001,
                protocol: .tcp,
                containerID: fullID,
                containerName: "api",
                targetIP: "172.18.0.5"
            )
        ])
        XCTAssertEqual(second, first)
        XCTAssertEqual(runner.inspectCalls, 1)
        XCTAssertTrue(runner.psArguments.allSatisfy { $0.contains("--no-trunc") })
    }

    func testPruneCacheForcesNextDiscoveryToInspectAgain() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let fullID = "bcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789a"
        let shortID = String(fullID.prefix(12))
        let inspectJSON = """
        [
          {
            "Id": "\(fullID)",
            "Name": "/api",
            "State": {"Running": true},
            "NetworkSettings": {
              "Ports": {
                "63002/tcp": [{"HostIp": "0.0.0.0", "HostPort": "63002"}]
              }
            }
          }
        ]
        """

        let runner = DockerDiscoveryRunner(fullID: fullID, shortID: shortID, inspectJSON: inspectJSON)
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: UnavailableGuestConnectionConnector(),
            runner: runner.run
        )
        defer { forwarder.stop() }

        _ = forwarder.discoverPublishedPortsForTesting()
        _ = forwarder.discoverPublishedPortsForTesting()
        XCTAssertEqual(runner.inspectCalls, 1)

        forwarder.pruneCache()
        _ = forwarder.discoverPublishedPortsForTesting()

        XCTAssertEqual(runner.inspectCalls, 2)
        XCTAssertTrue(forwarder.status().messages.contains("network cache pruned"))
    }

    func testStatusMessagesAreCappedToRecentEntries() {
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector()
        )
        defer { forwarder.stop() }

        forwarder.appendMessagesForTesting((0..<250).map { "message-\($0)" })

        let messages = forwarder.status().messages
        XCTAssertEqual(messages.count, 200)
        XCTAssertEqual(messages.first, "message-50")
        XCTAssertEqual(messages.last, "message-249")
    }

    func testCreatePublicationIntentPrimesPendingPortMetadataAndPruneClearsIt() {
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector()
        )
        defer { forwarder.stop() }

        let ports: Set<DockerPublishedPort> = [
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: 8080,
                containerPort: 80,
                protocol: .tcp,
                containerName: "web"
            )
        ]
        forwarder.observeCreatePublicationIntent(DockerCreatePublicationIntent(
            requestPath: "/v1.52/containers/create?name=web",
            containerName: "web",
            ports: ports
        ))

        XCTAssertEqual(forwarder.pendingCreatePortsForTesting(containerName: "web"), ports)
        XCTAssertTrue(forwarder.status().messages.contains("observed Docker create port intent web [8080:80/tcp]"))

        forwarder.pruneCache()

        XCTAssertTrue(forwarder.pendingCreatePortsForTesting(containerName: "web").isEmpty)
    }

    func testCreatePublicationResolutionAssociatesContainerID() {
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector()
        )
        defer { forwarder.stop() }

        let intent = DockerCreatePublicationIntent(
            requestPath: "/containers/create?name=web",
            containerName: "web",
            ports: [
                DockerPublishedPort(
                    hostIP: "127.0.0.1",
                    hostPort: 8080,
                    containerPort: 80,
                    protocol: .tcp,
                    containerName: "web"
                )
            ]
        )

        forwarder.observeCreatePublicationIntent(intent)
        forwarder.resolveCreatePublication(DockerCreatePublicationResolution(
            intent: intent,
            containerID: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        ))

        XCTAssertTrue(forwarder.pendingCreatePortsForTesting(containerName: "web").isEmpty)
        XCTAssertEqual(forwarder.pendingCreatePortsForTesting(containerID: "abcdef012345"), [
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: 8080,
                containerPort: 80,
                protocol: .tcp,
                containerID: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                containerName: "web"
            )
        ])
        XCTAssertTrue(forwarder.status().messages.contains("resolved Docker create port intent abcdef012345"))
    }

    func testTargetedReconcileUsesCreateIntentAndDirectDockerAPIWithoutRunnerInspect() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let connector = DockerAPIInspectConnector(
            containerID: containerID,
            containerName: "web",
            hostPort: hostPort,
            containerPort: 80,
            targetIP: "172.18.0.9"
        )
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: connector,
            runner: { _, arguments, _ in
                XCTFail("runner should not be used for targeted reconcile when create metadata is resolved: \(arguments)")
                return ProcessResult(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    exitCode: 1,
                    stdout: "",
                    stderr: "unexpected runner call"
                )
            }
        )
        defer { forwarder.stop() }

        let intent = DockerCreatePublicationIntent(
            requestPath: "/containers/create?name=web",
            containerName: "web",
            ports: [
                DockerPublishedPort(
                    hostIP: "127.0.0.1",
                    hostPort: hostPort,
                    containerPort: 80,
                    protocol: .tcp,
                    containerName: "web"
                )
            ]
        )
        forwarder.resolveCreatePublication(DockerCreatePublicationResolution(
            intent: intent,
            containerID: containerID
        ))

        forwarder.reconcileContainerIDsForTesting([String(containerID.prefix(12))])

        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })
        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 1)
        XCTAssertEqual(status.forwards.first?.targetIP, "172.18.0.9")
        XCTAssertEqual(status.forwards.first?.containerID, containerID)
        XCTAssertGreaterThanOrEqual(connector.requests.filter { $0.contains("/containers/\(containerID)/json") }.count, 1)
    }

    func testContainerStartFastAttachesResolvedCreateIntentWithoutRunnerInspect() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let connector = DockerAPIInspectConnector(
            containerID: containerID,
            containerName: "web",
            hostPort: hostPort,
            containerPort: 80,
            targetIP: "172.18.0.9"
        )
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: connector,
            capabilities: nativeTCPCapabilities(),
            runner: { _, arguments, _ in
                XCTFail("runner should not be used during start-driven fast attach: \(arguments)")
                return ProcessResult(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    exitCode: 1,
                    stdout: "",
                    stderr: "unexpected runner call"
                )
            }
        )
        defer { forwarder.stop() }
        forwarder.reconcileForTesting([])

        let intent = DockerCreatePublicationIntent(
            requestPath: "/containers/create?name=web",
            containerName: "web",
            ports: [
                DockerPublishedPort(
                    hostIP: "127.0.0.1",
                    hostPort: hostPort,
                    containerPort: 80,
                    protocol: .tcp,
                    containerName: "web"
                )
            ]
        )
        forwarder.observeCreatePublicationIntent(intent)
        forwarder.resolveCreatePublication(DockerCreatePublicationResolution(
            intent: intent,
            containerID: containerID
        ))
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })

        forwarder.observeContainerStart(DockerContainerStartRequest(
            requestPath: "/v1.52/containers/\(String(containerID.prefix(12)))/start",
            containerID: String(containerID.prefix(12))
        ))

        XCTAssertTrue(waitUntil { forwarder.status().forwards.first?.targetIP == "172.18.0.9" })
        XCTAssertEqual(forwarder.status().forwards.first?.containerID, containerID)
        XCTAssertEqual(connector.requests.filter { $0.contains("/containers/\(containerID)/json") }.count, 0)
        XCTAssertEqual(connector.requests.filter { $0.contains("/conjet-container-targets") }.count, 1)
    }

    func testContainerTargetEventStreamWarmsStartAttachCache() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let connector = DockerAPIInspectConnector(
            containerID: containerID,
            containerName: "web",
            hostPort: hostPort,
            containerPort: 80,
            targetIP: "172.18.0.9"
        )
        var capabilities = nativeTCPCapabilities()
        capabilities.containerTargetEvents = true
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: connector,
            capabilities: capabilities,
            runner: { _, arguments, _ in
                if arguments.contains("ps") {
                    return ProcessResult(
                        executable: "/usr/bin/env",
                        arguments: arguments,
                        exitCode: 0,
                        stdout: "",
                        stderr: ""
                    )
                }
                XCTFail("runner should not be used during target event fast attach: \(arguments)")
                return ProcessResult(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    exitCode: 1,
                    stdout: "",
                    stderr: "unexpected runner call"
                )
            }
        )
        defer { forwarder.stop() }
        forwarder.start()
        XCTAssertTrue(waitUntil {
            forwarder.status().messages.contains("refreshed guest container target event stream (1 containers)")
        })

        let intent = DockerCreatePublicationIntent(
            requestPath: "/containers/create?name=web",
            containerName: "web",
            ports: [
                DockerPublishedPort(
                    hostIP: "127.0.0.1",
                    hostPort: hostPort,
                    containerPort: 80,
                    protocol: .tcp,
                    containerName: "web"
                )
            ]
        )
        forwarder.observeCreatePublicationIntent(intent)
        forwarder.resolveCreatePublication(DockerCreatePublicationResolution(
            intent: intent,
            containerID: containerID
        ))
        forwarder.observeContainerStart(DockerContainerStartRequest(
            requestPath: "/v1.52/containers/\(String(containerID.prefix(12)))/start",
            containerID: String(containerID.prefix(12))
        ))

        XCTAssertTrue(waitUntil { forwarder.status().forwards.first?.targetIP == "172.18.0.9" })
        XCTAssertEqual(connector.requests.filter { $0.contains("/conjet-container-targets") }.count, 0)
        XCTAssertGreaterThanOrEqual(connector.requests.filter { $0.contains("/containers/\(containerID)/json") }.count, 1)
    }

    func testDockerEventStreamUsesGuestConnectionWithoutDockerEventsRunner() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let eventLine = """
        {"Type":"container","Action":"start","Actor":{"ID":"\(String(containerID.prefix(12)))","Attributes":{"name":"web"}}}
        """
        let connector = DockerAPIInspectConnector(
            containerID: containerID,
            containerName: "web",
            hostPort: hostPort,
            containerPort: 80,
            targetIP: "172.18.0.9",
            dockerEventLines: [eventLine],
            dockerEventsChunked: true
        )
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: connector,
            capabilities: nativeTCPCapabilities(),
            runner: { _, arguments, _ in
                if arguments.contains("ps") {
                    return ProcessResult(
                        executable: "/usr/bin/env",
                        arguments: arguments,
                        exitCode: 0,
                        stdout: "",
                        stderr: ""
                    )
                }
                XCTFail("runner should not be used for Docker event streaming or targeted inspect: \(arguments)")
                return ProcessResult(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    exitCode: 1,
                    stdout: "",
                    stderr: "unexpected runner call"
                )
            }
        )
        defer { forwarder.stop() }

        forwarder.start()

        XCTAssertTrue(waitUntil { connector.requests.contains { $0.contains("GET /events?filters=") } })
        XCTAssertTrue(waitUntil { forwarder.status().forwards.first?.containerID == containerID })
        let status = forwarder.status()
        XCTAssertTrue(status.messages.contains("Docker event stream connected"))
        XCTAssertEqual(status.activeTCPForwards, 1)
        XCTAssertEqual(status.forwards.first?.targetIP, "172.18.0.9")
        XCTAssertGreaterThanOrEqual(connector.requests.filter { $0.contains("/containers/\(String(containerID.prefix(12)))/json") }.count, 1)
    }

    func testContainerTargetEventStreamSuppressesDuplicateSnapshotMessages() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let connector = DockerAPIInspectConnector(
            containerID: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            containerName: "web",
            hostPort: try reserveLoopbackPort(),
            containerPort: 80,
            targetIP: "172.18.0.9",
            eventSnapshotCopies: 3
        )
        var capabilities = nativeTCPCapabilities()
        capabilities.containerTargetEvents = true
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: connector,
            capabilities: capabilities,
            runner: { _, arguments, _ in
                if arguments.contains("ps") {
                    return ProcessResult(
                        executable: "/usr/bin/env",
                        arguments: arguments,
                        exitCode: 0,
                        stdout: "",
                        stderr: ""
                    )
                }
                return ProcessResult(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    exitCode: 0,
                    stdout: "",
                    stderr: ""
                )
            }
        )
        defer { forwarder.stop() }

        forwarder.start()

        XCTAssertTrue(waitUntil {
            forwarder.status().messages.contains("refreshed guest container target event stream (1 containers)")
        })
        Thread.sleep(forTimeInterval: 0.05)
        let refreshMessages = forwarder.status().messages.filter {
            $0 == "refreshed guest container target event stream (1 containers)"
        }
        XCTAssertEqual(refreshMessages.count, 1)
    }

    func testContainerTargetEventStreamAttachesPendingCreateIntentWithoutStartDiscovery() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let connector = DockerAPIInspectConnector(
            containerID: containerID,
            containerName: "web",
            hostPort: hostPort,
            containerPort: 80,
            targetIP: "172.18.0.9",
            eventResponseDelaySeconds: 0.05
        )
        var capabilities = nativeTCPCapabilities()
        capabilities.containerTargetEvents = true
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: connector,
            capabilities: capabilities,
            runner: { _, arguments, _ in
                if arguments.contains("ps") {
                    return ProcessResult(
                        executable: "/usr/bin/env",
                        arguments: arguments,
                        exitCode: 0,
                        stdout: "",
                        stderr: ""
                    )
                }
                XCTFail("runner should not be used during target event attach: \(arguments)")
                return ProcessResult(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    exitCode: 1,
                    stdout: "",
                    stderr: "unexpected runner call"
                )
            }
        )
        defer { forwarder.stop() }

        let intent = DockerCreatePublicationIntent(
            requestPath: "/containers/create?name=web",
            containerName: "web",
            ports: [
                DockerPublishedPort(
                    hostIP: "127.0.0.1",
                    hostPort: hostPort,
                    containerPort: 80,
                    protocol: .tcp,
                    containerName: "web"
                )
            ]
        )
        forwarder.start()
        forwarder.observeCreatePublicationIntent(intent)
        forwarder.resolveCreatePublication(DockerCreatePublicationResolution(
            intent: intent,
            containerID: containerID
        ))

        XCTAssertTrue(waitUntil { forwarder.status().forwards.first?.targetIP == "172.18.0.9" })
        XCTAssertTrue(forwarder.status().messages.contains("target-event attached published ports for abcdef012345 from event stream"))
        XCTAssertEqual(connector.requests.filter { $0.contains("/conjet-container-targets") }.count, 0)
        XCTAssertEqual(connector.requests.filter { $0.contains("/containers/\(containerID)/json") }.count, 0)
    }

    func testContainerTargetSnapshotRemovesStalePublishedListeners() throws {
        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: BinaryTCPEchoConnector(),
            capabilities: nativeTCPCapabilities()
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 80,
                protocol: .tcp,
                containerID: containerID,
                containerName: "web",
                targetIP: "172.18.0.9"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })

        try forwarder.applyContainerTargetSnapshotDataForTesting(Data("[]".utf8))

        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().isEmpty })
        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 0)
        XCTAssertEqual(status.staleForwards, 1)
        XCTAssertEqual(status.forwards.first?.state, .stale)
        XCTAssertTrue(status.messages.contains("removed stale published ports for missing container abcdef012345"))
    }

    func testContainerTargetSnapshotDiscoversPublishedPortsWithoutCreateIntent() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let connector = DockerAPIInspectConnector(
            containerID: containerID,
            containerName: "web",
            hostPort: hostPort,
            containerPort: 80,
            targetIP: "172.18.0.9"
        )
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: connector,
            capabilities: nativeTCPCapabilities(),
            runner: { _, arguments, _ in
                if arguments.contains("ps") {
                    return ProcessResult(
                        executable: "/usr/bin/env",
                        arguments: arguments,
                        exitCode: 0,
                        stdout: "",
                        stderr: ""
                    )
                }
                XCTFail("runner should not be used for target snapshot inspect: \(arguments)")
                return ProcessResult(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    exitCode: 1,
                    stdout: "",
                    stderr: "unexpected runner call"
                )
            }
        )
        defer { forwarder.stop() }
        forwarder.reconcileForTesting([])

        let snapshot = """
        [{"Id":"\(containerID)","Names":["/web"],"NetworkSettings":{"Networks":{"default":{"IPAddress":"172.18.0.9"}}}}]
        """
        try forwarder.applyContainerTargetSnapshotDataForTesting(Data(snapshot.utf8))

        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })
        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 1)
        XCTAssertEqual(status.forwards.first?.targetIP, "172.18.0.9")
        XCTAssertEqual(status.forwards.first?.containerID, containerID)
        XCTAssertGreaterThanOrEqual(connector.requests.filter { $0.contains("/containers/\(containerID)/json") }.count, 1)
    }

    func testContainerStartIntentPrepublishesConfiguredPortsBeforeContainerIsRunning() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let connector = DockerAPIInspectConnector(
            containerID: containerID,
            containerName: "web",
            hostPort: hostPort,
            containerPort: 80,
            targetIP: "",
            running: false
        )
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: connector,
            capabilities: nativeTCPCapabilities(),
            runner: { _, arguments, _ in
                XCTFail("runner should not be used during start-intent prepublication: \(arguments)")
                return ProcessResult(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    exitCode: 1,
                    stdout: "",
                    stderr: "unexpected runner call"
                )
            }
        )
        defer { forwarder.stop() }
        forwarder.reconcileForTesting([])

        forwarder.observeContainerStartIntent(DockerContainerStartRequest(
            requestPath: "/v1.52/containers/\(String(containerID.prefix(12)))/start",
            containerID: String(containerID.prefix(12))
        ))

        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })
        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 0)
        XCTAssertEqual(status.forwards.first?.state, .reservedWaitingForTarget)
        XCTAssertNil(status.forwards.first?.targetIP)
        XCTAssertEqual(forwarder.pendingCreatePortsForTesting(containerID: containerID).first?.hostPort, hostPort)
        XCTAssertTrue(forwarder.status().messages.contains("prepublished Docker start port intent abcdef012345"))
    }

    func testCreateIntentPrepublishesNativeTCPReservationBeforeTargetIsResolved() throws {
        let connector = BinaryTCPEchoConnector()
        let hostPort = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: nativeTCPCapabilities()
        )
        defer { forwarder.stop() }
        forwarder.start()

        forwarder.observeCreatePublicationIntent(DockerCreatePublicationIntent(
            requestPath: "/containers/create?name=web",
            containerName: "web",
            ports: [
                DockerPublishedPort(
                    hostIP: "127.0.0.1",
                    hostPort: hostPort,
                    containerPort: 80,
                    protocol: .tcp,
                    containerName: "web"
                )
            ]
        ))

        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })
        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 0)
        XCTAssertEqual(status.forwards.first?.state, .reservedWaitingForTarget)
        XCTAssertNil(status.forwards.first?.targetIP)
    }

    func testPrepublishedNativeTCPListenerForwardsAfterTargetReconcile() throws {
        let connector = BinaryTCPEchoConnector()
        let containerID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let hostPort = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: nativeTCPCapabilities()
        )
        defer { forwarder.stop() }
        forwarder.start()

        let intent = DockerCreatePublicationIntent(
            requestPath: "/containers/create?name=web",
            containerName: "web",
            ports: [
                DockerPublishedPort(
                    hostIP: "127.0.0.1",
                    hostPort: hostPort,
                    containerPort: 80,
                    protocol: .tcp,
                    containerName: "web"
                )
            ]
        )
        forwarder.observeCreatePublicationIntent(intent)
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 80,
                protocol: .tcp,
                containerID: containerID,
                containerName: "web",
                targetIP: "172.18.0.9"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.status().forwards.first?.targetIP == "172.18.0.9" })

        let fd = try connectLoopback(port: hostPort)
        defer { Darwin.close(fd) }
        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)
        let response = readAllTestBytes(from: fd)

        XCTAssertEqual(String(data: response, encoding: .utf8), "pong")
        XCTAssertTrue(waitUntil { connector.openTargets.contains("172.18.0.9:80") })
        XCTAssertEqual(forwarder.status().forwards.first?.targetIP, "172.18.0.9")
        XCTAssertEqual(forwarder.status().tcpMode, "persistent-binary-tcp-pool")
    }

    func testLegacyTCPReconcileWithoutTargetStillPublishesGuestHostPort() throws {
        let connector = TCPProxyEchoConnector()
        let hostPort = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                containerIPLookup: true,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 80,
                protocol: .tcp,
                containerName: "web"
            )
        ])

        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 1)
        XCTAssertEqual(status.forwards.first?.state, .listening)
        XCTAssertTrue(forwarder.listenerPortsForTesting().contains(hostPort))
    }

    func testPrivilegedTCPPortReportsHelperRequiredWhenHelperIsUnavailable() throws {
        let lowPort = 81
        guard directLowPortBindNeedsPrivilege(port: lowPort) else {
            throw XCTSkip("low TCP port \(lowPort) is bindable or already unavailable on this host")
        }

        let previousHelper = getenv("CONJET_PORT_HELPER_PATH").map { String(cString: $0) }
        setenv("CONJET_PORT_HELPER_PATH", "/nonexistent/conjet-port-helper", 1)
        defer {
            if let previousHelper {
                setenv("CONJET_PORT_HELPER_PATH", previousHelper, 1)
            } else {
                unsetenv("CONJET_PORT_HELPER_PATH")
            }
        }

        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector()
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: lowPort,
                containerPort: 80,
                protocol: .tcp,
                containerName: "web"
            )
        ])

        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 0)
        XCTAssertEqual(status.forwards.first?.state, .requiresPrivilegedHelper)
        XCTAssertTrue(status.forwards.first?.error?.contains("conjet-port-helper was not found") == true)
    }

    func testTargetedReconcilePrunesContainerWhenInspectReportsNoSuchContainer() throws {
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-docker-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let containerID = "cab5d0c4e47275282ce694468988ad4c357246db31085e701da6fd4082afb66b"
        let hostPort = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketURL.path,
            connector: UnavailableGuestConnectionConnector(),
            runner: DockerNoSuchContainerRunner(containerID: containerID).run
        )
        defer { forwarder.stop() }

        let eventContainerID = String(containerID.prefix(12))
        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 80,
                protocol: .tcp,
                containerID: containerID,
                containerName: "web"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })

        forwarder.reconcileContainerIDsForTesting([eventContainerID])

        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().isEmpty })
        let status = forwarder.status()
        XCTAssertEqual(status.activeTCPForwards, 0)
        XCTAssertEqual(status.staleForwards, 1)
        XCTAssertEqual(status.forwards.first?.containerID, containerID)
        XCTAssertEqual(status.forwards.first?.state, .stale)
    }

    func testEnergyModeControlsBackgroundReconcileInterval() {
        let balanced = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector(),
            energyMode: .balanced
        )
        let eco = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector(),
            energyMode: .eco
        )
        defer {
            balanced.stop()
            eco.stop()
        }

        XCTAssertEqual(balanced.status().periodicReconcileIntervalSeconds, 300)
        XCTAssertEqual(eco.status().periodicReconcileIntervalSeconds, 600)
    }

    func testReconcileStartsAndStopsListeners() throws {
        let connector = UnavailableGuestConnectionConnector()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector
        )
        defer { forwarder.stop() }

        let port = try reserveLoopbackPort()
        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "0.0.0.0", hostPort: port, containerPort: 80, protocol: .tcp)
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(port) })
        XCTAssertEqual(forwarder.status().activeTCPForwards, 2)

        forwarder.reconcileForTesting([])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().isEmpty })
    }

    func testListenerForwardsThroughGuestTCPProxyProtocol() throws {
        let connector = TCPProxyEchoConnector()
        let port = try reserveLoopbackPort()
        let observedConnections = ObservedPortConnections()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            successfulConnectionHandler: { observedConnections.append($0) }
        )
        defer { forwarder.stop() }
        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: port,
                containerPort: 63000,
                protocol: .tcp,
                containerID: "container123456789"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(port) })

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }

        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)
        let response = readAllTestBytes(from: fd)

        XCTAssertEqual(String(data: response, encoding: .utf8), "pong")
        XCTAssertTrue(waitUntil { connector.prefaces.contains("CONJET-TCP 127.0.0.1:\(port)") })
        XCTAssertTrue(waitUntil {
            observedConnections.snapshot().contains {
                $0.hostPort == port
                    && $0.containerPort == 63000
                    && $0.containerID == "container123456789"
            }
        })
    }

    func testUDPPortIsCapabilityGated() throws {
        let port = try reserveUDPPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: UnavailableGuestConnectionConnector(),
            capabilities: ConjetNetworkCapabilities(tcpProxy: true, udpProxy: false)
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 5353, protocol: .udp)
        ])

        let status = forwarder.status()
        XCTAssertEqual(status.activeUDPForwards, 0)
        XCTAssertEqual(status.failedForwards, 1)
        XCTAssertEqual(status.forwards.first?.state, .failedGuestCapability)
    }

    func testUDPListenerUsesBinaryFramePathWhenCapabilitiesAdvertiseIt() throws {
        let connector = BinaryUDPEchoConnector()
        let port = try reserveUDPPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                guestEcho: true,
                guestMetrics: true,
                binaryFrames: true,
                udpBinaryFrames: true,
                persistentVsock: true,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 5353, protocol: .udp)
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeUDPForwards == 1 })

        let response = try sendUDPDatagram(Data("ping".utf8), to: port)

        XCTAssertEqual(String(data: response, encoding: .utf8), "echo:ping")
        XCTAssertTrue(waitUntil { connector.registeredTargets == 1 })
        XCTAssertEqual(connector.udpPayloads.map { String(data: $0, encoding: .utf8) }, ["ping"])
    }

    func testUDPBinaryFramePathRegistersResolvedContainerTarget() throws {
        let connector = BinaryUDPEchoConnector()
        let port = try reserveUDPPort()
        let containerPort = 5353
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                guestEcho: true,
                guestMetrics: true,
                binaryFrames: true,
                udpBinaryFrames: true,
                persistentVsock: true,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: port,
                containerPort: containerPort,
                protocol: .udp,
                targetIP: "172.18.0.5"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeUDPForwards == 1 })

        let portForwardID = UInt32((port << 16) | containerPort)
        XCTAssertTrue(waitUntil {
            connector.registeredTargetPayloads.contains("\(portForwardID) udp 172.18.0.5 \(containerPort)")
        })
    }

    func testUDPBinaryFramePathReusesPersistentGuestConnection() throws {
        let connector = BinaryUDPEchoConnector()
        let port = try reserveUDPPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                guestEcho: true,
                guestMetrics: true,
                binaryFrames: true,
                udpBinaryFrames: true,
                persistentVsock: true,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(hostIP: "127.0.0.1", hostPort: port, containerPort: 5353, protocol: .udp)
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeUDPForwards == 1 })

        let first = try sendUDPDatagram(Data("one".utf8), to: port)
        let second = try sendUDPDatagram(Data("two".utf8), to: port)

        XCTAssertEqual(String(data: first, encoding: .utf8), "echo:one")
        XCTAssertEqual(String(data: second, encoding: .utf8), "echo:two")
        XCTAssertTrue(waitUntil { connector.udpPayloads.count == 2 })
        XCTAssertEqual(connector.connectionCount, 2, "one registration connection and one persistent UDP data connection should be used")
    }

    func testTCPFallsBackWhenPoolCapabilityIsUnavailable() throws {
        let connector = TCPProxyEchoConnector()
        let port = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                binaryFrames: true,
                udpBinaryFrames: true,
                persistentVsock: true,
                tcpBinaryFrames: true,
                persistentTCPVsock: true,
                tcpVsockPool: false,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: port,
                containerPort: 63000,
                protocol: .tcp,
                targetIP: "172.17.0.2"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(port) })

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)

        XCTAssertEqual(String(data: readAllTestBytes(from: fd), encoding: .utf8), "pong")
        XCTAssertTrue(waitUntil { connector.prefaces.contains("CONJET-TCP 127.0.0.1:\(port)") })
        XCTAssertEqual(forwarder.status().tcpMode, "legacy-tcp-proxy")
    }

    func testTCPPublishedPortsUseNativePoolWhenAvailable() throws {
        let connector = BinaryTCPEchoConnector()
        let port = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: nativeTCPCapabilities()
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: port,
                containerPort: 80,
                protocol: .tcp,
                targetIP: "172.17.0.2"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeTCPForwards == 1 })

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)
        let response = readAllTestBytes(from: fd)

        XCTAssertEqual(String(data: response, encoding: .utf8), "pong")
        XCTAssertTrue(waitUntil { connector.openTargets.contains("172.17.0.2:80") })
        let status = forwarder.status()
        XCTAssertEqual(status.bridgeEngine, "conjet-netd-c")
        XCTAssertEqual(status.tcpMode, "persistent-binary-tcp-pool")
        XCTAssertTrue(status.tcpBinaryFrames)
        XCTAssertTrue(status.persistentTCPVsock)
        XCTAssertTrue(status.tcpVsockPool)
        XCTAssertFalse(status.pythonFallbackActive)
    }

    func testNativeTCPContainerTargetServesCurlStyleHTTPRequest() throws {
        let hostPort = try reserveLoopbackPort()
        let connector = BinaryTCPEchoConnector()

        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: nativeTCPCapabilities()
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 63001,
                protocol: .tcp,
                containerName: "api",
                targetIP: "172.18.0.3"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })

        let fd = try connectLoopback(port: hostPort)
        defer { Darwin.close(fd) }
        let request = """
        GET /ready HTTP/1.1\r
        Host: 127.0.0.1:\(hostPort)\r
        User-Agent: curl/8.7.1\r
        Accept: */*\r
        \r

        """
        XCTAssertTrue(writeAllTestBytes(Data(request.utf8), to: fd))
        let responseText = String(data: readAllTestBytes(from: fd), encoding: .utf8) ?? ""

        XCTAssertTrue(responseText.contains("HTTP/1.1 200 OK"), responseText)
        XCTAssertTrue(responseText.contains("\r\n\r\nready"), responseText)
        XCTAssertTrue(waitUntil { connector.openTargets.contains("172.18.0.3:63001") })
        XCTAssertEqual(forwarder.status().tcpMode, "persistent-binary-tcp-pool")
    }

    func testNativeTCPContainerTargetDoesNotResetLargeHTTPResponseOnClose() throws {
        let hostPort = try reserveLoopbackPort()
        let connector = BinaryTCPEchoConnector()
        let body = String(repeating: "network-ok\n", count: 16_384)

        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: nativeTCPCapabilities()
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 63002,
                protocol: .tcp,
                containerName: "api",
                targetIP: "172.18.0.4"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })

        let fd = try connectLoopback(port: hostPort)
        let request = """
        GET /large HTTP/1.1\r
        Host: 127.0.0.1:\(hostPort)\r
        User-Agent: curl/8.7.1\r
        Accept: */*\r
        \r

        """
        XCTAssertTrue(writeAllTestBytes(Data(request.utf8), to: fd))
        let responseText = String(data: readAllTestBytes(from: fd), encoding: .utf8) ?? ""
        Darwin.close(fd)

        XCTAssertTrue(responseText.contains("HTTP/1.1 200 OK"), String(responseText.prefix(200)))
        XCTAssertTrue(responseText.hasSuffix(body), "response length=\(responseText.utf8.count)")
        XCTAssertTrue(waitUntil { connector.openTargets.contains("172.18.0.4:63002") })
        let expectedBytesOut = UInt64(Data(responseText.utf8).count)
        XCTAssertTrue(waitUntil {
            forwarder.status().forwards.first?.bytesOut == expectedBytesOut
        })
    }

    func testLiveNativeTCPForwarderAgainstConjetDockerSocketWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["CONJET_LIVE_DOCKER_SOCKET"], !socketPath.isEmpty else {
            throw XCTSkip("set CONJET_LIVE_DOCKER_SOCKET to run live Conjet Docker bridge QA")
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("CONJET_LIVE_DOCKER_SOCKET does not exist: \(socketPath)")
        }

        let connector = UnixSocketGuestConnectionConnector(socketPath: socketPath, timeoutSeconds: 3)
        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: connector, timeoutSeconds: 2)
        guard capabilities.tcpProxy,
              capabilities.binaryFrames,
              capabilities.tcpBinaryFrames,
              capabilities.persistentTCPVsock,
              capabilities.tcpVsockPool else {
            throw XCTSkip("live bridge does not advertise native TCP binary pool capabilities: \(capabilities)")
        }

        let dockerHost = "unix://\(socketPath)"
        let hostPort = try reserveLoopbackPort()
        let containerName = "codex-live-native-\(UUID().uuidString.prefix(8))"
        let run = try ProcessRunner.run("/usr/bin/env", [
            "docker", "--host", dockerHost,
            "run", "--rm", "-d",
            "--name", containerName,
            "python:3.12-alpine",
            "python", "-u", "-m", "http.server", "8000"
        ], timeoutSeconds: 90)
        guard run.succeeded else {
            throw XCTSkip("live Docker run failed: \(run.stderr)")
        }
        defer {
            _ = try? ProcessRunner.run("/usr/bin/env", [
                "docker", "--host", dockerHost, "rm", "-f", containerName
            ], timeoutSeconds: 30)
        }

        XCTAssertTrue(waitUntil(timeoutSeconds: 45, intervalSeconds: 0.5) {
            guard let exec = try? ProcessRunner.run("/usr/bin/env", [
                "docker", "--host", dockerHost,
                "exec", containerName,
                "python", "-c",
                "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/', timeout=2).status)"
            ], timeoutSeconds: 5) else {
                return false
            }
            return exec.succeeded && exec.stdout.contains("200")
        }, "container HTTP service did not become ready")

        let inspect = try ProcessRunner.run("/usr/bin/env", [
            "docker", "--host", dockerHost,
            "inspect", "-f", "{{.Id}} {{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
            containerName
        ], timeoutSeconds: 30)
        XCTAssertTrue(inspect.succeeded, inspect.stderr)
        let inspectParts = inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        XCTAssertGreaterThanOrEqual(inspectParts.count, 2, inspect.stdout)
        let containerID = String(inspectParts[0])
        let targetIP = String(inspectParts[1])
        XCTAssertFalse(targetIP.isEmpty)

        let forwarder = DockerPublishedPortForwarder(
            socketPath: socketPath,
            connector: connector,
            capabilities: capabilities.conjetNetworkCapabilities
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 8000,
                protocol: .tcp,
                containerID: containerID,
                containerName: containerName,
                targetIP: targetIP
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.listenerPortsForTesting().contains(hostPort) })

        var responseText = ""
        XCTAssertTrue(waitUntil(timeoutSeconds: 30, intervalSeconds: 0.25) {
            guard let response = try? requestLoopbackHTTP(port: hostPort) else {
                return false
            }
            responseText = response
            return response.contains("HTTP/1.0 200 OK") || response.contains("HTTP/1.1 200 OK")
        }, "loopback response never succeeded; last response: \(responseText); status: \(forwarder.status())")
        XCTAssertTrue(responseText.contains("Directory listing for /") || responseText.contains("<html"), responseText)

        for attempt in 0..<20 {
            let response = try requestLoopbackHTTP(port: hostPort)
            XCTAssertTrue(
                response.contains("HTTP/1.0 200 OK") || response.contains("HTTP/1.1 200 OK"),
                "attempt \(attempt) failed: \(response)"
            )
        }

        let status = forwarder.status()
        XCTAssertEqual(status.tcpMode, "persistent-binary-tcp-pool")
        XCTAssertEqual(status.forwards.first?.state, .listening)
        XCTAssertEqual(status.forwards.first?.connectionErrors, 0)
    }

    func testMixedPublishedPortsStressAcrossTCPUDPAndBindKinds() throws {
        let connector = MixedTextProxyConnector()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                containerIPLookup: true,
                bridgeEngine: "conjet-netd-c"
            )
        )
        defer { forwarder.stop() }

        let tcpLoopbackPorts = try (0..<8).map { _ in try reserveLoopbackPort() }
        let tcpWildcardPorts = try (0..<4).map { _ in try reserveLoopbackPort() }
        let udpLoopbackPorts = try (0..<6).map { _ in try reserveUDPPort() }
        let udpWildcardPorts = try (0..<3).map { _ in try reserveUDPPort() }

        var publishedPorts = Set<DockerPublishedPort>()
        for (index, hostPort) in tcpLoopbackPorts.enumerated() {
            publishedPorts.insert(DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 18_000 + index,
                protocol: .tcp,
                containerName: "tcp-loopback-\(index)",
                targetIP: "172.18.0.\(index + 2)"
            ))
        }
        for (index, hostPort) in tcpWildcardPorts.enumerated() {
            publishedPorts.insert(DockerPublishedPort(
                hostIP: "0.0.0.0",
                hostPort: hostPort,
                containerPort: 19_000 + index,
                protocol: .tcp,
                containerName: "tcp-wildcard-\(index)",
                targetIP: "172.19.0.\(index + 2)"
            ))
        }
        for (index, hostPort) in udpLoopbackPorts.enumerated() {
            publishedPorts.insert(DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: hostPort,
                containerPort: 28_000 + index,
                protocol: .udp,
                containerName: "udp-loopback-\(index)",
                targetIP: "172.28.0.\(index + 2)"
            ))
        }
        for (index, hostPort) in udpWildcardPorts.enumerated() {
            publishedPorts.insert(DockerPublishedPort(
                hostIP: "0.0.0.0",
                hostPort: hostPort,
                containerPort: 29_000 + index,
                protocol: .udp,
                containerName: "udp-wildcard-\(index)",
                targetIP: "172.29.0.\(index + 2)"
            ))
        }

        forwarder.reconcileForTesting(publishedPorts)

        let expectedTCPForwards = tcpLoopbackPorts.count + (tcpWildcardPorts.count * 2)
        let expectedUDPForwards = udpLoopbackPorts.count + (udpWildcardPorts.count * 2)
        XCTAssertTrue(waitUntil(timeoutSeconds: 5) {
            let status = forwarder.status()
            return status.activeTCPForwards == expectedTCPForwards
                && status.activeUDPForwards == expectedUDPForwards
        })

        let tcpPorts = tcpLoopbackPorts + tcpWildcardPorts
        for hostPort in tcpPorts {
            for attempt in 0..<5 {
                let fd = try connectLoopback(port: hostPort)
                defer { Darwin.close(fd) }
                let payload = "tcp:\(hostPort):\(attempt)"
                XCTAssertTrue(writeAllTestBytes(Data(payload.utf8), to: fd))
                Darwin.shutdown(fd, SHUT_WR)
                let response = String(data: readAllTestBytes(from: fd), encoding: .utf8)
                XCTAssertEqual(response, "echo:\(payload)")
            }
        }

        let udpPorts = udpLoopbackPorts + udpWildcardPorts
        for hostPort in udpPorts {
            for attempt in 0..<5 {
                let payload = "udp:\(hostPort):\(attempt)"
                let response = try sendUDPDatagram(Data(payload.utf8), to: hostPort)
                XCTAssertEqual(String(data: response, encoding: .utf8), "echo:\(payload)")
            }
        }

        XCTAssertTrue(waitUntil(timeoutSeconds: 5) {
            connector.prefaces.filter { $0.hasPrefix("CONJET-TCP ") }.count >= tcpPorts.count * 5
                && connector.prefaces.filter { $0.hasPrefix("CONJET-UDP ") }.count >= udpPorts.count * 5
        })
        for publishedPort in publishedPorts {
            let expected = "CONJET-\(publishedPort.protocol.rawValue.uppercased()) 127.0.0.1:\(publishedPort.hostPort)"
            XCTAssertTrue(connector.prefaces.contains(expected), "missing \(expected)")
        }
    }

    func testLegacyTCPFallsBackToGuestHostPortForPythonBridge() throws {
        let connector = TCPProxyEchoConnector()
        let port = try reserveLoopbackPort()
        let forwarder = DockerPublishedPortForwarder(
            socketPath: "/tmp/missing-\(UUID().uuidString).sock",
            connector: connector,
            capabilities: ConjetNetworkCapabilities(
                tcpProxy: true,
                udpProxy: true,
                containerIPLookup: true,
                bridgeEngine: "python-legacy"
            )
        )
        defer { forwarder.stop() }

        forwarder.reconcileForTesting([
            DockerPublishedPort(
                hostIP: "127.0.0.1",
                hostPort: port,
                containerPort: 63001,
                protocol: .tcp,
                targetIP: "172.18.0.3"
            )
        ])
        XCTAssertTrue(waitUntil { forwarder.status().activeTCPForwards == 1 })

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        XCTAssertTrue(writeAllTestBytes(Data("ping".utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)

        XCTAssertEqual(String(data: readAllTestBytes(from: fd), encoding: .utf8), "pong")
        XCTAssertTrue(waitUntil { connector.prefaces.contains("CONJET-TCP 127.0.0.1:\(port)") })
        XCTAssertTrue(forwarder.status().pythonFallbackActive)
    }

    func testNativeTCPBridgePoolReportsOpenErrors() throws {
        let connector = BinaryTCPEchoConnector(errorOnOpen: true)
        let pool = NativeTCPBridgePool(connector: connector, maxConnections: 1, minimumIdleConnections: 0)
        defer { pool.close() }
        let fds = try makeTestSocketPair()
        let clientFD = fds[0]
        let peerFD = fds[1]
        defer {
            Darwin.close(clientFD)
            Darwin.close(peerFD)
        }
        let connection = try pool.borrow()
        defer { connection.close() }

        let result = connection.forward(
            clientFD: clientFD,
            targetHost: "172.17.0.2",
            targetPort: 63000,
            onClientBytes: { _ in },
            onTargetBytes: { _ in }
        )

        XCTAssertFalse(result.opened)
        XCTAssertTrue(result.hadError)
    }


    private func reserveLoopbackPort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw ConjetError.socket("bind random loopback port failed")
                }
            }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &bound) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.getsockname(fd, socketAddress, &length) == 0 else {
                    throw ConjetError.socket("getsockname failed")
                }
            }
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func directLowPortBindNeedsPrivilege(port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return false
        }
        return errno == EACCES || errno == EPERM
    }

    private func reserveUDPPort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw ConjetError.socket("bind random UDP loopback port failed")
                }
            }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &bound) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.getsockname(fd, socketAddress, &length) == 0 else {
                    throw ConjetError.socket("getsockname failed")
                }
            }
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func connectLoopback(port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        do {
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                        throw ConjetError.socket("connect loopback failed")
                    }
                }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func requestLoopbackHTTP(port: Int) throws -> String {
        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        let request = """
        GET / HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        User-Agent: conjet-live-forwarder-test\r
        Accept: */*\r
        Connection: close\r
        \r

        """
        XCTAssertTrue(writeAllTestBytes(Data(request.utf8), to: fd))
        Darwin.shutdown(fd, SHUT_WR)
        return String(data: readAllTestBytes(from: fd), encoding: .utf8) ?? ""
    }

    private func sendUDPDatagram(_ payload: Data, to port: Int) throws -> Data {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard Darwin.sendto(fd, base, payload.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == payload.count else {
                        throw ConjetError.socket("sendto loopback UDP failed")
                    }
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw ConjetError.socket("recv loopback UDP failed")
        }
        return Data(buffer.prefix(count))
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

    private func nativeTCPCapabilities() -> ConjetNetworkCapabilities {
        ConjetNetworkCapabilities(
            tcpProxy: true,
            udpProxy: true,
            containerIPLookup: true,
            portProbe: true,
            guestEcho: true,
            guestMetrics: true,
            binaryFrames: true,
            udpBinaryFrames: true,
            persistentVsock: true,
            tcpBinaryFrames: true,
            persistentTCPVsock: true,
            tcpVsockPool: true,
            bridgeEngine: "conjet-netd-c"
        )
    }
}

private final class DockerDiscoveryRunner: @unchecked Sendable {
    private let fullID: String
    private let shortID: String
    private let inspectJSON: String
    private let lock = NSLock()
    private var recordedInspectCalls = 0
    private var recordedPSArguments: [[String]] = []

    init(fullID: String, shortID: String, inspectJSON: String) {
        self.fullID = fullID
        self.shortID = shortID
        self.inspectJSON = inspectJSON
    }

    var inspectCalls: Int {
        lock.lock()
        let value = recordedInspectCalls
        lock.unlock()
        return value
    }

    var psArguments: [[String]] {
        lock.lock()
        let value = recordedPSArguments
        lock.unlock()
        return value
    }

    func run(executable: String, arguments: [String], timeoutSeconds: Double?) throws -> ProcessResult {
        if arguments.contains("ps") {
            lock.lock()
            recordedPSArguments.append(arguments)
            lock.unlock()
            let id = arguments.contains("--no-trunc") ? fullID : shortID
            return ProcessResult(executable: executable, arguments: arguments, exitCode: 0, stdout: "\(id)\n", stderr: "")
        }
        if arguments.contains("inspect") {
            lock.lock()
            recordedInspectCalls += 1
            lock.unlock()
            return ProcessResult(executable: executable, arguments: arguments, exitCode: 0, stdout: inspectJSON, stderr: "")
        }
        return ProcessResult(executable: executable, arguments: arguments, exitCode: 1, stdout: "", stderr: "unexpected command")
    }
}

private final class DockerNoSuchContainerRunner: @unchecked Sendable {
    private let containerID: String

    init(containerID: String) {
        self.containerID = containerID
    }

    func run(executable: String, arguments: [String], timeoutSeconds: Double?) throws -> ProcessResult {
        if arguments.contains("inspect") {
            return ProcessResult(
                executable: executable,
                arguments: arguments,
                exitCode: 1,
                stdout: "",
                stderr: "Error response from daemon: No such container: \(containerID)"
            )
        }
        return ProcessResult(executable: executable, arguments: arguments, exitCode: 0, stdout: "", stderr: "")
    }
}

private final class BinaryUDPEchoConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var connectionIndex = 0
    private var registrations = 0
    private var registrationPayloads: [String] = []
    private var payloads: [Data] = []

    var registeredTargets: Int {
        lock.lock()
        let value = registrations
        lock.unlock()
        return value
    }

    var udpPayloads: [Data] {
        lock.lock()
        let value = payloads
        lock.unlock()
        return value
    }

    var registeredTargetPayloads: [String] {
        lock.lock()
        let value = registrationPayloads
        lock.unlock()
        return value
    }

    var connectionCount: Int {
        lock.lock()
        let value = connectionIndex
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        lock.lock()
        connectionIndex += 1
        let index = connectionIndex
        lock.unlock()

        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            while let frame = try? readBinaryTestFrame(from: serverFD) {
                if index == 1, frame.type == .registerTarget {
                    self.lock.lock()
                    self.registrations += 1
                    self.registrationPayloads.append(String(data: frame.payload, encoding: .utf8) ?? "")
                    self.lock.unlock()
                    let response = ConjetBinaryFrame(type: .helloAck, portForwardID: frame.portForwardID)
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                    return
                }
                guard frame.type == .udp else {
                    let response = ConjetBinaryFrame(type: .error, payload: Data("unexpected".utf8))
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                    continue
                }
                self.lock.lock()
                self.payloads.append(frame.payload)
                self.lock.unlock()
                let response = ConjetBinaryFrame(
                    type: .udp,
                    streamID: frame.streamID,
                    portForwardID: frame.portForwardID,
                    payload: Data("echo:".utf8) + frame.payload
                )
                _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
            }
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class TCPProxyEchoConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var seenPrefaces: [String] = []

    var prefaces: [String] {
        lock.lock()
        let value = seenPrefaces
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let preface = readLineTestBytes(from: serverFD)
            self.lock.lock()
            self.seenPrefaces.append(preface)
            self.lock.unlock()

            let request = readAllTestBytes(from: serverFD)
            if String(data: request, encoding: .utf8) == "ping" {
                _ = writeAllTestBytes(Data("pong".utf8), to: serverFD)
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class MixedTextProxyConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var seenPrefaces: [String] = []

    var prefaces: [String] {
        lock.lock()
        let value = seenPrefaces
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let preface = readLineTestBytes(from: serverFD)
            self.lock.lock()
            self.seenPrefaces.append(preface)
            self.lock.unlock()

            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(serverFD, &buffer, buffer.count)
            if count > 0 {
                _ = writeAllTestBytes(Data("echo:".utf8) + Data(buffer.prefix(count)), to: serverFD)
            }
            if preface.hasPrefix("CONJET-UDP ") {
                Darwin.shutdown(serverFD, SHUT_WR)
            } else {
                Darwin.shutdown(serverFD, SHUT_RDWR)
            }
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class TCPProxyForwardingConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let hostPortTargets: [Int: Int]
    private var seenPrefaces: [String] = []

    init(hostPortTargets: [Int: Int] = [:]) {
        self.hostPortTargets = hostPortTargets
    }

    var prefaces: [String] {
        lock.lock()
        let value = seenPrefaces
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let preface = readLineTestBytes(from: serverFD)
            self.lock.lock()
            self.seenPrefaces.append(preface)
            self.lock.unlock()

            guard let target = Self.parseTarget(from: preface) else {
                Darwin.shutdown(serverFD, SHUT_WR)
                return
            }
            let upstreamPort = self.hostPortTargets[target.port] ?? target.port
            guard let upstreamFD = try? connectTCPHost(target.host, port: upstreamPort) else {
                Darwin.shutdown(serverFD, SHUT_WR)
                return
            }
            defer { Darwin.close(upstreamFD) }

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                copyTestBytes(from: serverFD, to: upstreamFD)
                Darwin.shutdown(upstreamFD, SHUT_WR)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                copyTestBytes(from: upstreamFD, to: serverFD)
                Darwin.shutdown(serverFD, SHUT_WR)
                group.leave()
            }
            group.wait()
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }

    private static func parseTarget(from preface: String) -> (host: String, port: Int)? {
        let prefix = "CONJET-TCP "
        guard preface.hasPrefix(prefix) else {
            return nil
        }
        let target = preface.dropFirst(prefix.count)
        guard let separator = target.lastIndex(of: ":"),
              let port = Int(target[target.index(after: separator)...]) else {
            return nil
        }
        return (String(target[..<separator]), port)
    }
}

private final class DockerAPIInspectConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let containerID: String
    private let containerName: String
    private let hostPort: Int
    private let containerPort: Int
    private let targetIP: String
    private let running: Bool
    private let eventResponseDelaySeconds: Double
    private let eventSnapshotCopies: Int
    private let dockerEventLines: [String]
    private let dockerEventsChunked: Bool
    private var seenRequests: [String] = []

    init(
        containerID: String,
        containerName: String,
        hostPort: Int,
        containerPort: Int,
        targetIP: String,
        running: Bool = true,
        eventResponseDelaySeconds: Double = 0,
        eventSnapshotCopies: Int = 1,
        dockerEventLines: [String] = [],
        dockerEventsChunked: Bool = false
    ) {
        self.containerID = containerID
        self.containerName = containerName
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.targetIP = targetIP
        self.running = running
        self.eventResponseDelaySeconds = eventResponseDelaySeconds
        self.eventSnapshotCopies = eventSnapshotCopies
        self.dockerEventLines = dockerEventLines
        self.dockerEventsChunked = dockerEventsChunked
    }

    var requests: [String] {
        lock.lock()
        let value = seenRequests
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            let request = readHTTPHeaderTestBytes(from: serverFD)
            let requestText = String(data: request, encoding: .utf8) ?? ""
            self.lock.lock()
            self.seenRequests.append(requestText)
            self.lock.unlock()

            if requestText.contains("/events?") {
                let body = self.dockerEventLines.map { "\($0)\n" }.joined()
                let response: String
                if self.dockerEventsChunked {
                    let chunkHeader = String(Data(body.utf8).count, radix: 16)
                    response = """
                    HTTP/1.1 200 OK\r
                    Content-Type: application/x-ndjson\r
                    Transfer-Encoding: chunked\r
                    \r
                    \(chunkHeader)\r
                    \(body)\r
                    0\r
                    \r

                    """
                } else {
                    response = """
                    HTTP/1.1 200 OK\r
                    Content-Type: application/x-ndjson\r
                    Content-Length: \(Data(body.utf8).count)\r
                    \r
                    \(body)
                    """
                }
                _ = writeAllTestBytes(Data(response.utf8), to: serverFD)
                Darwin.shutdown(serverFD, SHUT_WR)
                return
            }

            if requestText.contains("/conjet-container-target-events") {
                if self.eventResponseDelaySeconds > 0 {
                    Thread.sleep(forTimeInterval: self.eventResponseDelaySeconds)
                }
                let body = """
                [{"Id":"\(self.containerID)","Names":["/\(self.containerName)"],"NetworkSettings":{"Networks":{"default":{"IPAddress":"\(self.targetIP)"}}}}]

                """
                let repeatedBody = String(repeating: body, count: max(1, self.eventSnapshotCopies))
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: application/x-ndjson\r
                \r
                \(repeatedBody)
                """
                _ = writeAllTestBytes(Data(response.utf8), to: serverFD)
                Darwin.shutdown(serverFD, SHUT_WR)
                return
            }

            if requestText.contains("/conjet-container-targets") {
                let body = """
                [{"Id":"\(self.containerID)","Names":["/\(self.containerName)"],"NetworkSettings":{"Networks":{"default":{"IPAddress":"\(self.targetIP)"}}}}]
                """
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: application/json\r
                Content-Length: \(Data(body.utf8).count)\r
                \r
                \(body)
                """
                _ = writeAllTestBytes(Data(response.utf8), to: serverFD)
                Darwin.shutdown(serverFD, SHUT_WR)
                return
            }

            if requestText.contains("/conjet-port-probe?") {
                let body = "{\"ready\":true}\n"
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: application/json\r
                Content-Length: \(Data(body.utf8).count)\r
                \r
                \(body)
                """
                _ = writeAllTestBytes(Data(response.utf8), to: serverFD)
                Darwin.shutdown(serverFD, SHUT_WR)
                return
            }

            let networkPorts = self.running
                ? "\"\(self.containerPort)/tcp\":[{\"HostIp\":\"127.0.0.1\",\"HostPort\":\"\(self.hostPort)\"}]"
                : ""
            let body = """
            {"Id":"\(self.containerID)","Name":"/\(self.containerName)","State":{"Running":\(self.running ? "true" : "false")},"HostConfig":{"PortBindings":{"\(self.containerPort)/tcp":[{"HostIp":"127.0.0.1","HostPort":"\(self.hostPort)"}]}},"NetworkSettings":{"Ports":{\(networkPorts)},"Networks":{"default":{"IPAddress":"\(self.targetIP)"}}}}
            """
            let shortID = String(self.containerID.prefix(12))
            let statusLine = requestText.contains("/containers/\(self.containerID)/json") ||
                requestText.contains("/containers/\(shortID)/json")
                ? "HTTP/1.1 200 OK"
                : "HTTP/1.1 404 Not Found"
            let response = """
            \(statusLine)\r
            Content-Type: application/json\r
            Content-Length: \(Data(body.utf8).count)\r
            \r
            \(body)
            """
            _ = writeAllTestBytes(Data(response.utf8), to: serverFD)
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class BinaryTCPEchoConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let errorOnOpen: Bool
    private var targets: [String] = []
    private var payloads: [Data] = []

    init(errorOnOpen: Bool = false) {
        self.errorOnOpen = errorOnOpen
    }

    var openTargets: [String] {
        lock.lock()
        let value = targets
        lock.unlock()
        return value
    }

    var tcpPayloads: [Data] {
        lock.lock()
        let value = payloads
        lock.unlock()
        return value
    }

    func connect() throws -> GuestConnection {
        let fds = try makeTestSocketPair()
        let clientFD = fds[0]
        let serverFD = fds[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            while let frame = try? readBinaryTestFrame(from: serverFD) {
                switch frame.type {
                case .tcpOpen:
                    if self.errorOnOpen {
                        let response = ConjetBinaryFrame(
                            type: .tcpError,
                            streamID: frame.streamID,
                            payload: Data("open failed".utf8)
                        )
                        _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                        continue
                    }
                    if let target = try? ConjetTCPFrameTarget.decode(frame.payload) {
                        self.lock.lock()
                        self.targets.append("\(target.host):\(target.port)")
                        self.lock.unlock()
                    }
                    let response = ConjetBinaryFrame(type: .tcpOpen, streamID: frame.streamID)
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                case .tcpData:
                    self.lock.lock()
                    self.payloads.append(frame.payload)
                    self.lock.unlock()
                    let text = String(data: frame.payload, encoding: .utf8) ?? ""
                    let responsePayload: Data
                    let shouldClose: Bool
                    if text.hasPrefix("GET /ready ") {
                        let body = "ready"
                        responsePayload = Data("""
                        HTTP/1.1 200 OK\r
                        Content-Type: text/plain\r
                        Content-Length: \(Data(body.utf8).count)\r
                        Connection: close\r
                        \r
                        \(body)
                        """.utf8)
                        shouldClose = true
                    } else if text.hasPrefix("GET /large ") {
                        let body = String(repeating: "network-ok\n", count: 16_384)
                        responsePayload = Data("""
                        HTTP/1.1 200 OK\r
                        Content-Type: text/plain\r
                        Content-Length: \(Data(body.utf8).count)\r
                        Connection: close\r
                        \r
                        \(body)
                        """.utf8)
                        shouldClose = true
                    } else if text == "ping" {
                        responsePayload = Data("pong".utf8)
                        shouldClose = false
                    } else {
                        responsePayload = frame.payload
                        shouldClose = false
                    }
                    let response = ConjetBinaryFrame(
                        type: .tcpData,
                        streamID: frame.streamID,
                        payload: responsePayload
                    )
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                    if shouldClose {
                        let halfClose = ConjetBinaryFrame(type: .tcpHalfClose, streamID: frame.streamID)
                        let close = ConjetBinaryFrame(type: .tcpClose, streamID: frame.streamID)
                        _ = writeAllTestBytes((try? halfClose.encode()) ?? Data(), to: serverFD)
                        _ = writeAllTestBytes((try? close.encode()) ?? Data(), to: serverFD)
                        return
                    }
                case .tcpHalfClose:
                    let halfClose = ConjetBinaryFrame(type: .tcpHalfClose, streamID: frame.streamID)
                    let close = ConjetBinaryFrame(type: .tcpClose, streamID: frame.streamID)
                    _ = writeAllTestBytes((try? halfClose.encode()) ?? Data(), to: serverFD)
                    _ = writeAllTestBytes((try? close.encode()) ?? Data(), to: serverFD)
                    return
                case .tcpClose:
                    return
                default:
                    let response = ConjetBinaryFrame(
                        type: .tcpError,
                        streamID: frame.streamID,
                        payload: Data("unexpected".utf8)
                    )
                    _ = writeAllTestBytes((try? response.encode()) ?? Data(), to: serverFD)
                }
            }
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }
}

private final class ObservedPortConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [DockerPublishedPort] = []

    func append(_ port: DockerPublishedPort) {
        lock.lock()
        ports.append(port)
        lock.unlock()
    }

    func snapshot() -> [DockerPublishedPort] {
        lock.lock()
        let value = ports
        lock.unlock()
        return value
    }
}

private final class HTTPReadyServer: @unchecked Sendable {
    private let lock = NSLock()
    private let port: Int
    private var listenFD: Int32 = -1
    private var stopped = false

    init(port: Int) {
        self.port = port
    }

    func start() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConjetError.socket("test HTTP server socket failed")
        }
        disableTestSigpipe(fd)

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        do {
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                        throw ConjetError.socket("test HTTP server bind failed")
                    }
                }
            }
            guard Darwin.listen(fd, 8) == 0 else {
                throw ConjetError.socket("test HTTP server listen failed")
            }
        } catch {
            Darwin.close(fd)
            throw error
        }

        lock.lock()
        listenFD = fd
        stopped = false
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            self.acceptLoop(fd: fd)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func acceptLoop(fd: Int32) {
        while !isStopped {
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            disableTestSigpipe(clientFD)
            DispatchQueue.global(qos: .userInitiated).async {
                defer { Darwin.close(clientFD) }
                _ = readHTTPHeaderTestBytes(from: clientFD)
                let body = "ready"
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/plain\r
                Content-Length: \(Data(body.utf8).count)\r
                Connection: close\r
                \r
                \(body)
                """
                _ = writeAllTestBytes(Data(response.utf8), to: clientFD)
                Darwin.shutdown(clientFD, SHUT_WR)
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }
}

private func readLineTestBytes(from fd: Int32) -> String {
    var data = Data()
    var byte: UInt8 = 0
    while Darwin.read(fd, &byte, 1) == 1 {
        if byte == 10 {
            break
        }
        data.append(byte)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func connectTCPHost(_ host: String, port: Int) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw ConjetError.socket("test TCP socket failed")
    }
    disableTestSigpipe(fd)

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
        Darwin.close(fd)
        throw ConjetError.socket("test TCP host parse failed")
    }

    do {
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw ConjetError.socket("test TCP connect failed")
                }
            }
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func makeTestSocketPair() throws -> [Int32] {
    var fds = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw ConjetError.socket("socketpair() failed")
    }
    disableTestSigpipe(fds[0])
    disableTestSigpipe(fds[1])
    return fds
}

private func disableTestSigpipe(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func readAllTestBytes(from fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
        } else if count < 0, errno == EINTR {
            continue
        } else {
            break
        }
    }
    return data
}

private func copyTestBytes(from sourceFD: Int32, to destinationFD: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(sourceFD, &buffer, buffer.count)
        if count > 0 {
            let chunk = Data(buffer.prefix(count))
            if !writeAllTestBytes(chunk, to: destinationFD) {
                return
            }
        } else if count < 0, errno == EINTR {
            continue
        } else {
            return
        }
    }
}

private func readHTTPHeaderTestBytes(from fd: Int32) -> Data {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < 64 * 1024 {
        let count = Darwin.read(fd, &byte, 1)
        if count == 1 {
            data.append(byte)
            if data.count >= 4 && data.suffix(4) == Data([13, 10, 13, 10]) {
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

private func writeAllTestBytes(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return true
        }
        var written = 0
        while written < data.count {
            let count = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
            if count > 0 {
                written += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

private func readBinaryTestFrame(from fd: Int32) throws -> ConjetBinaryFrame {
    let header = try readExactTestBytes(from: fd, byteCount: ConjetBinaryFrame.headerSize)
    let payloadLength = testPayloadLength(fromHeader: header)
    let payload = payloadLength > 0 ? try readExactTestBytes(from: fd, byteCount: payloadLength) : Data()
    return try ConjetBinaryFrame.decode(header + payload)
}

private func readExactTestBytes(from fd: Int32, byteCount: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: max(1, min(4096, byteCount)))
    while data.count < byteCount {
        let count = Darwin.read(fd, &buffer, min(buffer.count, byteCount - data.count))
        if count > 0 {
            data.append(buffer, count: count)
        } else if count < 0, errno == EINTR {
            continue
        } else {
            throw ConjetError.socket("test binary frame read failed")
        }
    }
    return data
}

private func testPayloadLength(fromHeader header: Data) -> Int {
    let start = header.index(header.startIndex, offsetBy: 16)
    let b0 = UInt32(header[start])
    let b1 = UInt32(header[header.index(start, offsetBy: 1)])
    let b2 = UInt32(header[header.index(start, offsetBy: 2)])
    let b3 = UInt32(header[header.index(start, offsetBy: 3)])
    return Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
}

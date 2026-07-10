import ConjetCore
import XCTest

final class DaemonProtocolTests: XCTestCase {
    func testDaemonRequestJSONRoundTrip() throws {
        let request = DaemonRequest(command: .status)
        let data = try ConjetJSON.encoder(pretty: false).encode(request)
        let decoded = try ConjetJSON.decoder().decode(DaemonRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testPruneCacheCommandRoundTrip() throws {
        let request = DaemonRequest(command: .pruneCache)
        let data = try ConjetJSON.encoder(pretty: false).encode(request)
        let decoded = try ConjetJSON.decoder().decode(DaemonRequest.self, from: data)

        XCTAssertEqual(decoded.command, .pruneCache)
    }

    func testMemoryReclaimCommandRoundTrip() throws {
        let request = DaemonRequest(command: .memoryReclaim)
        let data = try ConjetJSON.encoder(pretty: false).encode(request)
        let decoded = try ConjetJSON.decoder().decode(DaemonRequest.self, from: data)

        XCTAssertEqual(decoded.command, .memoryReclaim)
    }

    func testDockerComposeCommandRoundTrip() throws {
        let request = DaemonRequest(command: .dockerCompose, arguments: ["up", "--build"])
        let data = try ConjetJSON.encoder(pretty: false).encode(request)
        let decoded = try ConjetJSON.decoder().decode(DaemonRequest.self, from: data)

        XCTAssertEqual(decoded.command, .dockerCompose)
        XCTAssertEqual(decoded.arguments, ["up", "--build"])
    }

    func testClockRepairCommandRoundTrip() throws {
        let request = DaemonRequest(command: .clockRepair, parameters: ["reason": "test"])
        let data = try ConjetJSON.encoder(pretty: false).encode(request)
        let decoded = try ConjetJSON.decoder().decode(DaemonRequest.self, from: data)

        XCTAssertEqual(decoded.command, .clockRepair)
        XCTAssertEqual(decoded.parameters["reason"], "test")
    }

    func testPulseSubscribeCommandRoundTrip() throws {
        let request = DaemonRequest(command: .pulseSubscribe, parameters: ["since_seq": "42"])
        let data = try ConjetJSON.encoder(pretty: false).encode(request)
        let decoded = try ConjetJSON.decoder().decode(DaemonRequest.self, from: data)

        XCTAssertEqual(decoded.command, .pulseSubscribe)
        XCTAssertEqual(decoded.parameters["since_seq"], "42")
    }

    func testDaemonStatusIncludesMemoryPolicy() throws {
        let config = ConjetConfig(memoryMiB: 8192, memoryProfile: .eco)
        let status = DaemonStatus(
            pid: 1,
            startedAt: Date(timeIntervalSince1970: 0),
            state: .warmIdle,
            socketPath: "/tmp/conjet.sock",
            host: HostCapabilities.detect(),
            config: config
        )

        XCTAssertEqual(status.memoryPolicy.profile, .eco)
        XCTAssertEqual(status.memoryPolicy.recommendedMemoryMiB, 8192)
    }

    func testMemoryPolicyDecodesOldPayloadWithoutIdleReclaimFields() throws {
        let payload = Data("""
        {
          "profile": "balanced",
          "configuredMemoryMiB": 8192,
          "recommendedMemoryMiB": 8192,
          "lazyRuntimeServices": false,
          "lazyNetworkHelpers": true,
          "reclaimIdleHelpersAfterSeconds": 300,
          "idleWakeupBudgetPerSecond": 1
        }
        """.utf8)

        let policy = try ConjetJSON.decoder().decode(ConjetMemoryPolicy.self, from: payload)

        XCTAssertTrue(policy.automaticIdleMemoryReclaim)
        XCTAssertEqual(policy.idleMemoryReclaimTargetMiB, 1024)
        XCTAssertEqual(policy.idleMemoryReclaimDwellSeconds, 0)
        XCTAssertTrue(policy.dynamicMemoryEnabled)
        XCTAssertEqual(policy.dynamicMemoryMinimumMiB, 512)
        XCTAssertEqual(policy.dynamicMemoryHeadroomMiB, 256)
    }

    func testVMRuntimeStatusCarriesStartupEvents() throws {
        let event = VMRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1),
            phase: "guest-bridge",
            message: "waiting for guest bridge"
        )
        let status = VMRuntimeStatus(
            state: .starting,
            backend: .hvfExperimental,
            configured: true,
            manifestPath: "/tmp/manifest.json",
            message: "starting",
            phase: "guest-bridge",
            events: [event],
            memory: ConjetMemoryRuntimeStatus(
                dynamicEnabled: true,
                mode: .balanced,
                maxMiB: 8192,
                minMiB: 1024,
                currentTargetMiB: 2560,
                balloonedMiB: 5632,
                guestAvailableMiB: 920,
                containerMemoryMiB: 1100,
                pressure: .low,
                lastAdjustmentReason: "guest.event"
            ),
            dockerRuntimeObservation: ConjetDockerRuntimeObservationSnapshot(
                containerIDs: ["container123456"],
                publishedPorts: [
                    ConjetPublishedPortRequest(
                        hostIP: "127.0.0.1",
                        hostPort: 18080,
                        containerPort: 80,
                        protocol: .tcp,
                        containerID: "container123456"
                    )
                ],
                dockerActivityEvents: 1,
                memoryTargetChanges: 1,
                successfulPortConnections: 1
            )
        )

        let data = try ConjetJSON.encoder(pretty: false).encode(status)
        let decoded = try ConjetJSON.decoder().decode(VMRuntimeStatus.self, from: data)

        XCTAssertEqual(decoded.phase, "guest-bridge")
        XCTAssertEqual(decoded.backend, .hvfExperimental)
        XCTAssertEqual(decoded.events, [event])
        XCTAssertEqual(decoded.memory?.currentTargetMiB, 2560)
        XCTAssertEqual(decoded.memory?.pressure, .low)
        XCTAssertEqual(decoded.dockerRuntimeObservation?.publishedPorts.first?.hostPort, 18080)
        XCTAssertTrue(decoded.dockerRuntimeObservation?.portForwardProven == true)
    }

    func testVMRuntimeStatusDecodesOldPayloadWithoutStartupEvents() throws {
        let payload = Data("""
        {
          "state": "running",
          "configured": true,
          "manifestPath": "/tmp/manifest.json",
          "message": "VM started"
        }
        """.utf8)

        let decoded = try ConjetJSON.decoder().decode(VMRuntimeStatus.self, from: payload)

        XCTAssertEqual(decoded.state, .running)
        XCTAssertNil(decoded.backend)
        XCTAssertNil(decoded.phase)
        XCTAssertEqual(decoded.events, [])
        XCTAssertNil(decoded.memory)
        XCTAssertNil(decoded.dockerRuntimeObservation)
    }

    func testHVFSmokeResultRoundTrip() throws {
        let result = ConjetHVFSmokeResult(
            ok: true,
            frameworkLinked: true,
            appleSilicon: true,
            architecture: "arm64",
            entitlementStatus: ConjetHVFEntitlementStatus(
                executablePath: "/tmp/conjet",
                requiredEntitlement: "com.apple.security.hypervisor",
                present: true,
                detail: "current executable has com.apple.security.hypervisor"
            ),
            memoryBytes: 65536,
            guestPhysicalAddress: 0x4000_0000,
            stages: [
                ConjetHVFSmokeStageResult(
                    name: "hv_vm_create",
                    ok: true,
                    detail: "VM created",
                    returnCode: 0,
                    returnCodeHex: "0x00000000",
                    durationNanoseconds: 12
                )
            ],
            message: "ok"
        )

        let data = try ConjetJSON.encoder(pretty: false).encode(result)
        let decoded = try ConjetJSON.decoder().decode(ConjetHVFSmokeResult.self, from: data)

        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.backend, .hvfExperimental)
    }

    func testHVFSmokeResultDecodesOldPayloadWithoutEntitlementStatus() throws {
        let payload = Data("""
        {
          "backend": "hvf-experimental",
          "ok": false,
          "frameworkLinked": true,
          "appleSilicon": true,
          "architecture": "arm64",
          "requiredEntitlement": "com.apple.security.hypervisor",
          "memoryBytes": 65536,
          "guestPhysicalAddress": 1073741824,
          "stages": [],
          "message": "Hypervisor denied VM creation"
        }
        """.utf8)

        let decoded = try ConjetJSON.decoder().decode(ConjetHVFSmokeResult.self, from: payload)

        XCTAssertEqual(decoded.backend, .hvfExperimental)
        XCTAssertNil(decoded.entitlementStatus)
        XCTAssertFalse(decoded.ok)
    }

    func testUnsupportedCommandCompatibilityDetectsOldDaemonDecodeFailure() {
        let response = DaemonResponse(
            ok: false,
            message: "DecodingError.dataCorrupted: Data was corrupted. Path: command. Debug description: Cannot initialize DaemonCommand from invalid String value prune-cache"
        )

        XCTAssertTrue(DaemonCompatibility.isUnsupportedCommandResponse(response, command: .pruneCache))
    }

    func testUnsupportedCommandCompatibilityIgnoresSuccessfulResponses() {
        let response = DaemonResponse(ok: true, message: "runtime cache pruned")

        XCTAssertFalse(DaemonCompatibility.isUnsupportedCommandResponse(response, command: .pruneCache))
    }

    func testDaemonResponseCarriesPulseStateWhenPresent() throws {
        let response = DaemonResponse(
            ok: true,
            message: "running",
            pulse: ConjetPulseState(highWatermark: 7, replayAvailableFrom: 2)
        )

        let data = try ConjetJSON.encoder(pretty: false).encode(response)
        let decoded = try ConjetJSON.decoder().decode(DaemonResponse.self, from: data)

        XCTAssertEqual(decoded.pulse?.highWatermark, 7)
        XCTAssertEqual(decoded.pulse?.replayAvailableFrom, 2)
    }

    func testDaemonResponseCarriesDockerComposeResultWhenPresent() throws {
        let response = DaemonResponse(
            ok: true,
            message: "compose completed successfully",
            dockerCompose: DockerComposeResult(
                arguments: ["up", "--build"],
                dockerHost: "unix:///tmp/conjet/docker.sock",
                executable: "/opt/homebrew/bin/docker",
                exitCode: 0,
                stdoutTail: "compose ok\n",
                stderrTail: ""
            )
        )

        let data = try ConjetJSON.encoder(pretty: false).encode(response)
        let decoded = try ConjetJSON.decoder().decode(DaemonResponse.self, from: data)

        XCTAssertEqual(decoded.dockerCompose?.arguments, ["up", "--build"])
        XCTAssertEqual(decoded.dockerCompose?.dockerHost, "unix:///tmp/conjet/docker.sock")
        XCTAssertEqual(decoded.dockerCompose?.executable, "/opt/homebrew/bin/docker")
        XCTAssertEqual(decoded.dockerCompose?.invocationKind, .dockerPlugin)
        XCTAssertEqual(decoded.dockerCompose?.exitCode, 0)
        XCTAssertEqual(decoded.dockerCompose?.stdoutTail, "compose ok\n")
    }

    func testDockerComposeResultDecodesOldPayloadWithoutInvocationKind() throws {
        let payload = Data("""
        {
          "arguments": ["up"],
          "dockerHost": "unix:///tmp/conjet/docker.sock",
          "executable": "/opt/homebrew/bin/docker-compose",
          "exitCode": 0,
          "stdoutTail": "compose ok\\n",
          "stderrTail": ""
        }
        """.utf8)

        let decoded = try ConjetJSON.decoder().decode(DockerComposeResult.self, from: payload)

        XCTAssertEqual(decoded.invocationKind, .dockerCompose)
        XCTAssertEqual(decoded.executable, "/opt/homebrew/bin/docker-compose")
        XCTAssertEqual(decoded.exitCode, 0)
    }

    func testDaemonResponseDecodesOldPayloadWithoutPulseState() throws {
        let payload = Data("""
        {
          "ok": true,
          "message": "running"
        }
        """.utf8)

        let decoded = try ConjetJSON.decoder().decode(DaemonResponse.self, from: payload)

        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.pulse)
        XCTAssertNil(decoded.dockerCompose)
    }
}

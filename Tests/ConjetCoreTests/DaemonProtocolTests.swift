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

    func testClockRepairCommandRoundTrip() throws {
        let request = DaemonRequest(command: .clockRepair, parameters: ["reason": "test"])
        let data = try ConjetJSON.encoder(pretty: false).encode(request)
        let decoded = try ConjetJSON.decoder().decode(DaemonRequest.self, from: data)

        XCTAssertEqual(decoded.command, .clockRepair)
        XCTAssertEqual(decoded.parameters["reason"], "test")
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
        XCTAssertEqual(status.memoryPolicy.recommendedMemoryMiB, 4096)
    }

    func testVMRuntimeStatusCarriesStartupEvents() throws {
        let event = VMRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1),
            phase: "guest-bridge",
            message: "waiting for guest bridge"
        )
        let status = VMRuntimeStatus(
            state: .starting,
            configured: true,
            manifestPath: "/tmp/manifest.json",
            message: "starting",
            phase: "guest-bridge",
            events: [event]
        )

        let data = try ConjetJSON.encoder(pretty: false).encode(status)
        let decoded = try ConjetJSON.decoder().decode(VMRuntimeStatus.self, from: data)

        XCTAssertEqual(decoded.phase, "guest-bridge")
        XCTAssertEqual(decoded.events, [event])
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
        XCTAssertNil(decoded.phase)
        XCTAssertEqual(decoded.events, [])
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
}

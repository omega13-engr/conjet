import ConjetCore
import XCTest

final class ConjetDockerEventsTests: XCTestCase {
    func testContainerStartEventMapsToPulseEvent() throws {
        let json = """
        {"Type":"container","Action":"start","Actor":{"ID":"abcdef012345","Attributes":{"name":"web","image":"nginx:alpine"}},"time":1800000000,"timeNano":1800000000123456789}
        """

        let event = try ConjetDockerRuntimeEvent.decode(line: Data(json.utf8))

        XCTAssertEqual(event.objectType, "container")
        XCTAssertEqual(event.eventName, "start")
        XCTAssertEqual(event.containerID, "abcdef012345")
        XCTAssertEqual(event.pulseEventType, .containerStarted)
        XCTAssertEqual(event.subjectID, "abcdef012345")
        XCTAssertEqual(event.pulsePayload["name"], "web")
        XCTAssertEqual(event.pulsePayload["image"], "nginx:alpine")
        XCTAssertNotNil(event.occurredAt)
        XCTAssertEqual(event.occurredAt!.timeIntervalSince1970, 1_800_000_000.1234567, accuracy: 0.000001)
    }

    func testLegacyStatusEventMapsToContainerRemoval() throws {
        let json = """
        {"status":"destroy","id":"deadbeef","Actor":{"ID":"deadbeef","Attributes":{"name":"old"}}}
        """

        let event = try ConjetDockerRuntimeEvent.decode(line: Data(json.utf8))

        XCTAssertEqual(event.objectType, "")
        XCTAssertEqual(event.eventName, "destroy")
        XCTAssertEqual(event.containerID, "deadbeef")
        XCTAssertEqual(event.pulseEventType, .containerRemoved)
    }

    func testImageAndVolumeEventsMapToPulseChanges() throws {
        let image = try ConjetDockerRuntimeEvent.decode(line: Data("""
        {"Type":"image","Action":"pull","id":"ubuntu:24.04"}
        """.utf8))
        let volume = try ConjetDockerRuntimeEvent.decode(line: Data("""
        {"Type":"volume","Action":"create","Actor":{"ID":"cache","Attributes":{"driver":"local"}}}
        """.utf8))

        XCTAssertEqual(image.pulseEventType, .imageChanged)
        XCTAssertEqual(volume.pulseEventType, .volumeChanged)
        XCTAssertEqual(volume.pulsePayload["driver"], "local")
    }

    func testIgnoredDockerEventHasNoPulseType() throws {
        let json = """
        {"Type":"builder","Action":"prune","Actor":{"ID":"builder"}}
        """

        let event = try ConjetDockerRuntimeEvent.decode(line: Data(json.utf8))

        XCTAssertNil(event.pulseEventType)
    }

    func testDockerRuntimeObservationSnapshotRoundTrips() throws {
        let port = ConjetPublishedPortRequest(
            hostIP: "127.0.0.1",
            hostPort: 18080,
            containerPort: 80,
            protocol: .tcp,
            containerID: "abcdef012345",
            containerName: "web"
        )
        let snapshot = ConjetDockerRuntimeObservationSnapshot(
            containerIDs: ["abcdef012345"],
            publishedPorts: [port],
            dockerActivityEvents: 2,
            memoryTargetChanges: 1,
            successfulPortConnections: 3,
            runtimeEvents: [
                ConjetDockerRuntimeObservedEvent(
                    action: "start",
                    containerID: "abcdef012345",
                    publishedPorts: [port],
                    memoryActivity: "run"
                )
            ]
        )

        let data = try ConjetJSON.encoder(pretty: false).encode(snapshot)
        let decoded = try ConjetJSON.decoder().decode(ConjetDockerRuntimeObservationSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.portForwardProven)
        XCTAssertTrue(decoded.memoryReactionProven)
    }
}

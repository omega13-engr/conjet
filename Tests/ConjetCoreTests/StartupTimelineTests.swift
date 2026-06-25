import ConjetCore
import XCTest

final class StartupTimelineTests: XCTestCase {
    func testStartupTimelineRecordsOrderedEventsAndJSONLines() throws {
        var ticks: UInt64 = 1_000
        let timeline = StartupTimeline(label: "test", clock: { ticks })

        ticks = 1_100
        timeline.record(.t0, clock: { ticks })
        ticks = 1_250
        timeline.record(.t1, metrics: ["bytes": 4], clock: { ticks })
        ticks = 1_500
        timeline.record(.t7, detail: "done", clock: { ticks })

        let trace = timeline.snapshot()
        try StartupTimelineValidator.validate(trace)
        XCTAssertTrue(trace.completeOrdered)
        XCTAssertEqual(trace.events.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(trace.durationNanoseconds(from: .t0, to: .t7), 400)
        let prettyJSONLines = try trace.jsonLines(pretty: true)
        XCTAssertTrue(prettyJSONLines.contains("\"id\" : \"T0\""))
        XCTAssertTrue(prettyJSONLines.contains("\"bytes\" : 4"))
    }

    func testStartupTimelineRejectsMissingT0MissingT7AndOutOfOrderEvents() throws {
        let missingT0 = StartupTimelineTrace(
            traceID: "trace",
            label: "bad",
            startedAt: Date(timeIntervalSince1970: 0),
            startContinuousNanoseconds: 10,
            events: [
                StartupTimelineEvent(
                    id: .t1,
                    sequence: 0,
                    label: "plan",
                    hostContinuousNanoseconds: 11,
                    offsetNanoseconds: 1
                )
            ]
        )
        XCTAssertThrowsError(try StartupTimelineValidator.validate(missingT0))

        let missingT7 = StartupTimelineTrace(
            traceID: "trace",
            label: "bad",
            startedAt: Date(timeIntervalSince1970: 0),
            startContinuousNanoseconds: 10,
            events: [
                StartupTimelineEvent(
                    id: .t0,
                    sequence: 0,
                    label: "start",
                    hostContinuousNanoseconds: 11,
                    offsetNanoseconds: 1
                )
            ]
        )
        XCTAssertThrowsError(try StartupTimelineValidator.validate(missingT7))

        let outOfOrder = StartupTimelineTrace(
            traceID: "trace",
            label: "bad",
            startedAt: Date(timeIntervalSince1970: 0),
            startContinuousNanoseconds: 10,
            events: [
                StartupTimelineEvent(
                    id: .t0,
                    sequence: 0,
                    label: "start",
                    hostContinuousNanoseconds: 11,
                    offsetNanoseconds: 1
                ),
                StartupTimelineEvent(
                    id: .t3,
                    sequence: 1,
                    label: "run",
                    hostContinuousNanoseconds: 12,
                    offsetNanoseconds: 2
                ),
                StartupTimelineEvent(
                    id: .t2,
                    sequence: 2,
                    label: "map",
                    hostContinuousNanoseconds: 13,
                    offsetNanoseconds: 3
                ),
                StartupTimelineEvent(
                    id: .t7,
                    sequence: 3,
                    label: "done",
                    hostContinuousNanoseconds: 14,
                    offsetNanoseconds: 4
                )
            ]
        )
        XCTAssertThrowsError(try StartupTimelineValidator.validate(outOfOrder))
    }
}

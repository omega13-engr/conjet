import ConjetCore
import XCTest

final class ConjetPulseTests: XCTestCase {
    func testPulseLogAssignsMonotonicSequences() {
        let pulse = ConjetPulseLog(capacity: 8)

        let first = pulse.append(type: .daemonStarted, message: "started")
        let second = pulse.append(type: .vmStarting, subjectID: "vm")
        let replay = pulse.replay(after: 0)

        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(replay.state.highWatermark, 2)
        XCTAssertEqual(replay.state.replayAvailableFrom, 1)
        XCTAssertEqual(replay.events.map(\.type), [.daemonStarted, .vmStarting])
        XCTAssertFalse(replay.overflowed)
    }

    func testPulseLogReportsReplayOverflow() {
        let pulse = ConjetPulseLog(capacity: 2)

        _ = pulse.append(type: .daemonStarted)
        _ = pulse.append(type: .vmStarting)
        _ = pulse.append(type: .vmStarted)

        let replay = pulse.replay(after: 0)

        XCTAssertTrue(replay.overflowed)
        XCTAssertEqual(replay.state.highWatermark, 3)
        XCTAssertEqual(replay.state.replayAvailableFrom, 2)
        XCTAssertEqual(replay.events.map(\.seq), [2, 3])
    }

    func testWaitForReplayBlocksUntilEventArrivesWithoutPolling() {
        let pulse = ConjetPulseLog(capacity: 8)
        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var replay: ConjetPulseReplay?

            func set(_ replay: ConjetPulseReplay) {
                lock.lock()
                self.replay = replay
                lock.unlock()
            }

            func get() -> ConjetPulseReplay? {
                lock.lock()
                defer { lock.unlock() }
                return replay
            }
        }
        let box = Box()

        DispatchQueue.global(qos: .userInitiated).async {
            waiterStarted.signal()
            box.set(pulse.waitForReplay(after: 0, timeout: 2))
            waiterFinished.signal()
        }

        XCTAssertEqual(waiterStarted.wait(timeout: .now() + 1), .success)
        Thread.sleep(forTimeInterval: 0.05)
        _ = pulse.append(type: .networkChanged, subjectID: "network")

        XCTAssertEqual(waiterFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(box.get()?.events.map(\.type), [.networkChanged])
    }

    func testPulseFramesRoundTrip() throws {
        let event = ConjetPulseEvent(
            seq: 9,
            type: .commandFinished,
            at: Date(timeIntervalSince1970: 1_800_000_000),
            subjectID: "cmd-1",
            message: "done",
            payload: ["ok": "true"]
        )
        let frame = ConjetPulseFrame(
            kind: .events,
            state: ConjetPulseState(highWatermark: 9, replayAvailableFrom: 1),
            events: [event]
        )

        let data = try ConjetJSON.encoder(pretty: false).encode(frame)
        let decoded = try ConjetJSON.decoder().decode(ConjetPulseFrame.self, from: data)

        XCTAssertEqual(decoded, frame)
    }
}

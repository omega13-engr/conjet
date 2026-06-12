@testable import ConjetApp
import ConjetCore
import XCTest

final class ConjetAppStateTests: XCTestCase {
    @MainActor
    func testRunningSnapshotCompletesStartingCommandState() {
        XCTAssertEqual(
            ConjetAppState.resolvedVMState(command: .starting, snapshot: .running),
            .running
        )
        XCTAssertTrue(ConjetAppState.isCommandTransitionComplete(command: .starting, actual: .running))
    }

    @MainActor
    func testStartingCommandStillWinsOverOldStoppedSnapshot() {
        XCTAssertEqual(
            ConjetAppState.resolvedVMState(command: .starting, snapshot: .stopped),
            .starting
        )
        XCTAssertFalse(ConjetAppState.isCommandTransitionComplete(command: .starting, actual: .stopped))
    }

    @MainActor
    func testStoppedSnapshotCompletesStoppingCommandState() {
        XCTAssertEqual(
            ConjetAppState.resolvedVMState(command: .stopping, snapshot: .stopped),
            .stopped
        )
        XCTAssertTrue(ConjetAppState.isCommandTransitionComplete(command: .stopping, actual: .stopped))
    }

    @MainActor
    func testStoppingCommandStillWinsOverOldRunningSnapshot() {
        XCTAssertEqual(
            ConjetAppState.resolvedVMState(command: .stopping, snapshot: .running),
            .stopping
        )
        XCTAssertFalse(ConjetAppState.isCommandTransitionComplete(command: .stopping, actual: .running))
    }
}

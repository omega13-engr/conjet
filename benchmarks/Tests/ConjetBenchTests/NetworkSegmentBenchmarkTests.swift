import ConjetBench
import XCTest

final class NetworkSegmentBenchmarkTests: XCTestCase {
    func testGuestEchoSegmentEnabledByDefault() {
        XCTAssertTrue(NetworkSegmentBenchmarkSuite.defaultWorkloads.contains("host-to-vsock-echo"))
        XCTAssertTrue(NetworkSegmentBenchmarkSuite.defaultWorkloads.contains("guest-bridge-echo"))
        XCTAssertTrue(NetworkSegmentBenchmarkSuite.defaultWorkloads.contains("udp-binary-frame-echo"))
    }
}

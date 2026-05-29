import ConjetCore
import XCTest

final class DaemonProtocolTests: XCTestCase {
    func testDaemonRequestJSONRoundTrip() throws {
        let request = DaemonRequest(command: .status)
        let data = try ConjetJSON.encoder(pretty: false).encode(request)
        let decoded = try ConjetJSON.decoder().decode(DaemonRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }
}

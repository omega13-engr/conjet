import ConjetCore
import XCTest

final class ConfigTests: XCTestCase {
    func testConfigRoundTrip() throws {
        let config = ConjetConfig(
            vmCPUs: 6,
            memoryMiB: 8192,
            quietStopMinutes: 12,
            enableRosetta: false,
            socketPath: "/tmp/conjet.sock",
            conjetCoreRepository: "zdxsector/conjet"
        )
        let parsed = try ConjetConfig.parseTOML(config.renderTOML())
        XCTAssertEqual(parsed, config)
    }

    func testInvalidMemoryIsRejected() throws {
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[vm]\nmemory_mib = 128\n"))
    }

    func testInvalidConjetCoreRepositoryIsRejected() throws {
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[images]\nconjet_core_repository = \"not-a-repo\"\n"))
    }
}

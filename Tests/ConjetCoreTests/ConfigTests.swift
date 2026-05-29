import ConjetCore
import XCTest

final class ConfigTests: XCTestCase {
    func testConfigRoundTrip() throws {
        let config = ConjetConfig(
            vmCPUs: 6,
            memoryMiB: 8192,
            architecture: "x86_64",
            diskGiB: 120,
            diskImagePath: "/tmp/custom.raw.gz",
            runtime: "docker",
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

    func testDefaultProfileConfigurationMatchesProductionDefaults() throws {
        let config = ConjetConfig.default

        XCTAssertEqual(config.vmCPUs, 4)
        XCTAssertEqual(config.memoryMiB, 8192)
        XCTAssertEqual(config.architecture, "aarch64")
        XCTAssertEqual(config.diskGiB, 100)
        XCTAssertEqual(config.runtime, "docker")
    }

    func testNamedProfilePathsAreIsolatedUnderProfilesDirectory() {
        let root = URL(fileURLWithPath: "/tmp/conjet-home", isDirectory: true)
        let paths = ConjetPaths(home: root, profileName: "work")

        XCTAssertEqual(paths.profileName, "work")
        XCTAssertEqual(paths.rootHome, root)
        XCTAssertEqual(paths.home.path, "/tmp/conjet-home/profiles/work")
        XCTAssertEqual(paths.socket.path, "/tmp/conjet-home/profiles/work/run/conjetd.sock")
        XCTAssertEqual(paths.dockerSocket.path, "/tmp/conjet-home/profiles/work/run/docker.sock")
    }

    func testDefaultProfileKeepsLegacyHomeLayout() {
        let root = URL(fileURLWithPath: "/tmp/conjet-home", isDirectory: true)
        let paths = ConjetPaths(home: root, profileName: "default")

        XCTAssertEqual(paths.profileName, "default")
        XCTAssertEqual(paths.home, root)
        XCTAssertEqual(paths.socket.path, "/tmp/conjet-home/run/conjetd.sock")
        XCTAssertEqual(paths.vmManifest.path, "/tmp/conjet-home/state/vm/manifest.json")
    }
}

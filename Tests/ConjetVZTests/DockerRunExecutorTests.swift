import ConjetVZ
import XCTest

final class DockerRunExecutorTests: XCTestCase {
    func testMissingSocketDoesNotFallBackToHostDocker() throws {
        let socket = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-conjet-docker-\(UUID().uuidString).sock")
        let result = try DockerRunExecutor(socketPath: socket.path).run(image: "hello-world", command: [])
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.dockerHost.contains(socket.path))
        XCTAssertTrue(result.stderrTail.contains("Conjet Docker socket is not available"))
    }
}

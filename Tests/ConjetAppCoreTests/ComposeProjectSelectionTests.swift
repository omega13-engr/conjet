import ConjetAppCore
import XCTest

final class ComposeProjectSelectionTests: XCTestCase {
    func testSelectionRequiresProjectAndPrefersCanonicalComposeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compose project \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ComposeProjectSelection.resolve(""))
        XCTAssertThrowsError(try ComposeProjectSelection.resolve(root.path))
        try Data("services: {}".utf8).write(to: root.appendingPathComponent("docker-compose.yml"))
        XCTAssertEqual(try ComposeProjectSelection.resolve(root.path).configurationFile.lastPathComponent, "docker-compose.yml")
        try Data("services: {}".utf8).write(to: root.appendingPathComponent("compose.yaml"))
        let project = try ComposeProjectSelection.resolve(root.path)
        XCTAssertEqual(project.configurationFile.lastPathComponent, "compose.yaml")
        XCTAssertEqual(project.directory.path, root.path)
        XCTAssertThrowsError(try ComposeProjectSelection.resolve(project.configurationFile.path))
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ComposeProjectSelection.resolve(child.path), "Do not accidentally act on a parent project")
    }
}

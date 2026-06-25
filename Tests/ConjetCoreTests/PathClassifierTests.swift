import ConjetCore
import XCTest

final class PathClassifierTests: XCTestCase {
    func testDependencyFoldersStayVMNative() {
        let classifier = PathClassifier()
        XCTAssertEqual(classifier.classify("node_modules/react/index.js", projectKinds: [.node]).placement, .vmNative)
        XCTAssertEqual(classifier.classify("vendor/autoload.php", projectKinds: [.php]).placement, .vmNative)
        XCTAssertEqual(classifier.classify("target/debug/app", projectKinds: [.rust]).placement, .vmNative)
    }

    func testSourceAndLockfilesStayHostSynced() {
        let classifier = PathClassifier()
        XCTAssertEqual(classifier.classify("src/App.swift").placement, .hostSynced)
        XCTAssertEqual(classifier.classify("pnpm-lock.yaml").placement, .hostSynced)
        XCTAssertEqual(classifier.classify("Dockerfile").placement, .hostSynced)
    }

    func testIgnoreRulesCanBeNegated() {
        let ignore = ConjetIgnore.parse("dist/\n!important.log\n*.log\n!keep.log\n")
        XCTAssertTrue(ignore.isIgnored("dist/app.js"))
        XCTAssertTrue(ignore.isIgnored("server.log"))
        XCTAssertFalse(ignore.isIgnored("keep.log"))
    }

    func testProjectDetectorFindsMultipleStacks() {
        let fingerprint = ProjectDetector.detect(files: ["package.json", "Cargo.toml", "go.mod"])
        XCTAssertEqual(fingerprint.kinds, [.node, .rust, .go])
    }
}

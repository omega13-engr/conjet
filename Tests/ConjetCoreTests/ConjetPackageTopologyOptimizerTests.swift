import ConjetCore
import XCTest

final class ConjetPackageTopologyOptimizerTests: XCTestCase {
    func testDetectsPnpmBeforeGenericNodeProject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "{}\n".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "lockfileVersion: '9.0'\n".write(to: root.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)

        let plan = ConjetPackageTopologyOptimizer.plan(projectRoot: root, guestPath: "/workspace")

        XCTAssertEqual(plan.manager, .pnpm)
        XCTAssertEqual(plan.environment["NPM_CONFIG_STORE_DIR"], "/workspace/.pnpm-store")
        XCTAssertEqual(plan.environment["PNPM_HOME"], "/workspace/.pnpm-state")
        XCTAssertEqual(plan.environment["NPM_CONFIG_CACHE"], "/workspace/.npm-cache")
        XCTAssertEqual(plan.environment["COREPACK_HOME"], "/workspace/.corepack-cache")
        XCTAssertTrue(plan.dockerEnvironmentArguments().contains("--env"))
        XCTAssertTrue(plan.dockerEnvironmentArguments().contains("NPM_CONFIG_STORE_DIR=/workspace/.pnpm-store"))
    }

    func testPlansLanguageSpecificNativeCaches() {
        XCTAssertEqual(
            ConjetPackageTopologyOptimizer.plan(manager: .cargo, guestPath: "/workspace")
                .environment["CARGO_TARGET_DIR"],
            "/workspace/target"
        )
        XCTAssertEqual(
            ConjetPackageTopologyOptimizer.plan(manager: .go, guestPath: "/workspace")
                .environment["GOMODCACHE"],
            "/workspace/.go/pkg/mod"
        )
        XCTAssertEqual(
            ConjetPackageTopologyOptimizer.plan(manager: .composer, guestPath: "/workspace")
                .environment["COMPOSER_CACHE_DIR"],
            "/workspace/.composer-cache"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-topology-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

import ConjetCore
import XCTest

final class ConjetPortPolicyTests: XCTestCase {
    func testSecureLocalMapsWildcardToLoopback() {
        let policy = ConjetPortPolicy(bindPolicy: .secureLocal)
        let decision = policy.evaluate(request(hostIP: "0.0.0.0", port: 8080))

        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(Set(decision.bindAddresses), ["127.0.0.1", "::1"])
        XCTAssertNotNil(decision.warning)
    }

    func testDockerStrictPreservesWildcard() {
        let policy = ConjetPortPolicy(bindPolicy: .dockerStrict)
        let decision = policy.evaluate(request(hostIP: "0.0.0.0", port: 8080))

        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.bindAddresses, ["0.0.0.0"])
        XCTAssertNotNil(decision.warning)
    }

    func testLanAllowlistAllowsConfiguredPort() {
        let policy = ConjetPortPolicy(
            bindPolicy: .lanAllowlist,
            lanAllowedCIDRs: ["192.168.1.0/24"],
            lanAllowedPorts: [8080]
        )
        let decision = policy.evaluate(request(hostIP: "0.0.0.0", port: 8080))

        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.bindAddresses, ["0.0.0.0"])
        XCTAssertNotNil(decision.warning)
    }

    func testLanAllowlistDeniesUnconfiguredPort() {
        let policy = ConjetPortPolicy(
            bindPolicy: .lanAllowlist,
            lanAllowedCIDRs: ["192.168.1.0/24"],
            lanAllowedPorts: [8080]
        )
        let decision = policy.evaluate(request(hostIP: "0.0.0.0", port: 9090))

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.bindAddresses, [])
        XCTAssertNotNil(decision.deniedReason)
    }

    func testExplicitLoopbackIsPreserved() {
        let policy = ConjetPortPolicy(bindPolicy: .secureLocal)
        XCTAssertEqual(policy.evaluate(request(hostIP: "127.0.0.1", port: 8080)).bindAddresses, ["127.0.0.1"])
        XCTAssertEqual(policy.evaluate(request(hostIP: "::1", port: 8080)).bindAddresses, ["::1"])
    }

    func testSecureLocalDeniesLANAddress() {
        let policy = ConjetPortPolicy(bindPolicy: .secureLocal)
        let decision = policy.evaluate(request(hostIP: "192.168.1.40", port: 8080))

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.deniedReason, "secure-local denies non-loopback bind address 192.168.1.40")
    }

    private func request(hostIP: String, port: Int) -> ConjetPublishedPortRequest {
        ConjetPublishedPortRequest(hostIP: hostIP, hostPort: port, containerPort: port, protocol: .tcp)
    }
}

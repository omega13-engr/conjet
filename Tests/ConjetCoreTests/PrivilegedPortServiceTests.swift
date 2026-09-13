import ConjetCore
import Darwin
import Foundation
import Security
import XCTest

final class PrivilegedPortServiceTests: XCTestCase {
    func testXPCInterfaceTransfersUsableOwnedDescriptor() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = DescriptorTestDelegate()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedPortServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let received = expectation(description: "descriptor reply")
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC failed: \(error)")
            received.fulfill()
        } as? PrivilegedPortServiceProtocol)
        proxy.bind(address: "127.0.0.1", port: 80, transport: "tcp") { handle, code, message in
            XCTAssertEqual(code, 0)
            XCTAssertNil(message)
            XCTAssertNotNil(handle)
            XCTAssertEqual(try? handle?.read(upToCount: 16), Data("fd-transfer-ok".utf8))
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 5)
        withExtendedLifetime(delegate) {}
    }

    func testBindPolicyAcceptsOnlyLiteralAddressesAndPrivilegedTCPUDP() throws {
        for address in ["127.0.0.1", "0.0.0.0", "::1", "::", "localhost"] {
            for transport in ["tcp", "udp"] {
                try PrivilegedPortService.validate(address: address, port: 443, transport: transport)
            }
        }
        for port in [-1, 0, 1024, 65536] {
            XCTAssertThrowsError(try PrivilegedPortService.validate(address: "127.0.0.1", port: port, transport: "tcp"))
        }
        for address in ["example.com", "127.0.0.1\n", "", "/tmp/socket"] {
            XCTAssertThrowsError(try PrivilegedPortService.validate(address: address, port: 80, transport: "tcp"))
        }
        XCTAssertThrowsError(try PrivilegedPortService.validate(address: "::1", port: 80, transport: "raw"))
    }

    func testRequirementsAreValidAndRejectUntrustedInput() throws {
        for identifier in [PrivilegedPortService.name, PrivilegedPortService.daemonIdentifier] {
            let text = try PrivilegedPortService.requirement(team: "ABCDE12345", identifier: identifier)
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
            let compiled = try XCTUnwrap(requirement)
            var code: SecCode?
            XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
            XCTAssertNotEqual(SecCodeCheckValidity(code!, [], compiled), errSecSuccess, "An ad-hoc test runner must not authenticate as the helper or daemon")
        }
        XCTAssertThrowsError(try PrivilegedPortService.requirement(team: "x\" or true", identifier: PrivilegedPortService.name))
        XCTAssertThrowsError(try PrivilegedPortService.requirement(team: "ABCDE12345", identifier: "anything"))
    }
}

private final class DescriptorTestDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PrivilegedPortServiceProtocol.self)
        connection.exportedObject = DescriptorTestService()
        connection.resume()
        return true
    }
}

private final class DescriptorTestService: NSObject, PrivilegedPortServiceProtocol {
    func bind(address: String, port: Int, transport: String, reply: @escaping (FileHandle?, Int, String?) -> Void) {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("fd-transfer-ok".utf8))
        try? pipe.fileHandleForWriting.close()
        reply(pipe.fileHandleForReading, 0, nil)
    }
}

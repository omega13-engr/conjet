import ConjetCore
import Foundation
import XCTest

final class BinaryFrameTests: XCTestCase {
    func testBinaryFrameEncodeDecode() throws {
        let frame = ConjetBinaryFrame(
            type: .tcpData,
            flags: 7,
            streamID: 42,
            portForwardID: 9,
            payload: Data("payload".utf8)
        )

        let decoded = try ConjetBinaryFrame.decode(try frame.encode())
        XCTAssertEqual(decoded, frame)
    }

    func testBinaryFrameRejectsBadMagic() throws {
        var encoded = try ConjetBinaryFrame(type: .ping).encode()
        encoded[0] = 0
        XCTAssertThrowsError(try ConjetBinaryFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? ConjetBinaryFrameError, .badMagic)
        }
    }

    func testBinaryFrameRejectsBadVersion() throws {
        var encoded = try ConjetBinaryFrame(type: .ping).encode()
        encoded[4] = 99
        XCTAssertThrowsError(try ConjetBinaryFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? ConjetBinaryFrameError, .badVersion(99))
        }
    }

    func testBinaryFrameRejectsOversizedPayload() throws {
        let frame = ConjetBinaryFrame(type: .data, payload: Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try ConjetBinaryFrame.decode(try frame.encode(), maxPayloadBytes: 4)) { error in
            XCTAssertEqual(error as? ConjetBinaryFrameError, .oversizedPayload(8))
        }
    }

    func testBinaryFrameRejectsTruncatedPayload() throws {
        var encoded = try ConjetBinaryFrame(type: .metrics, payload: Data("abc".utf8)).encode()
        encoded.removeLast()
        XCTAssertThrowsError(try ConjetBinaryFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? ConjetBinaryFrameError, .truncatedPayload)
        }
    }

    func testUnknownFrameHandledSafely() throws {
        var encoded = try ConjetBinaryFrame(type: .ping).encode()
        encoded[5] = 250
        XCTAssertThrowsError(try ConjetBinaryFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? ConjetBinaryFrameError, .unknownType(250))
        }
    }

    func testTCPFrameTypesEncodeDecode() throws {
        let frames: [ConjetBinaryFrame] = [
            ConjetBinaryFrame(type: .tcpOpen, streamID: 1, payload: try ConjetTCPFrameTarget(host: "127.0.0.1", port: 8080).encode()),
            ConjetBinaryFrame(type: .tcpData, streamID: 1, payload: Data("GET / HTTP/1.1\r\n\r\n".utf8)),
            ConjetBinaryFrame(type: .tcpHalfClose, streamID: 1),
            ConjetBinaryFrame(type: .tcpClose, streamID: 1),
            ConjetBinaryFrame(type: .tcpError, streamID: 1, payload: Data("connect failed".utf8))
        ]

        for frame in frames {
            XCTAssertEqual(try ConjetBinaryFrame.decode(try frame.encode()), frame)
        }
    }

    func testTCPOpenTargetPayloadRoundTrip() throws {
        let target = ConjetTCPFrameTarget(host: "172.17.0.2", port: 80)
        XCTAssertEqual(try ConjetTCPFrameTarget.decode(try target.encode()), target)
    }

    func testTCPOpenTargetRejectsInvalidPort() {
        XCTAssertThrowsError(try ConjetTCPFrameTarget(host: "127.0.0.1", port: 0).encode()) { error in
            XCTAssertEqual(error as? ConjetTCPFrameTargetError, .invalidPort("0"))
        }
    }
}

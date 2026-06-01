import Foundation

public enum ConjetBinaryFrameError: Error, Equatable, Sendable {
    case badMagic
    case badVersion(UInt8)
    case truncatedHeader
    case truncatedPayload
    case oversizedPayload(Int)
    case unknownType(UInt8)
}

public enum ConjetBinaryFrameType: UInt8, Codable, Sendable, CaseIterable {
    case hello = 1
    case helloAck = 2
    case ping = 3
    case pong = 4
    case registerTarget = 5
    case open = 6
    case data = 7
    case fin = 8
    case reset = 9
    case udp = 10
    case metrics = 11
    case error = 12
    case windowUpdate = 13
    case tcpOpen = 14
    case tcpData = 15
    case tcpHalfClose = 16
    case tcpClose = 17
    case tcpError = 18
}

public struct ConjetBinaryFrame: Equatable, Sendable {
    public static let magic: UInt32 = 0x434a_4e54 // CJNT
    public static let version: UInt8 = 1
    public static let headerSize = 20
    public static let maxPayloadBytes = 1_048_576

    public var type: ConjetBinaryFrameType
    public var flags: UInt16
    public var streamID: UInt32
    public var portForwardID: UInt32
    public var payload: Data

    public init(
        type: ConjetBinaryFrameType,
        flags: UInt16 = 0,
        streamID: UInt32 = 0,
        portForwardID: UInt32 = 0,
        payload: Data = Data()
    ) {
        self.type = type
        self.flags = flags
        self.streamID = streamID
        self.portForwardID = portForwardID
        self.payload = payload
    }

    public func encode() throws -> Data {
        if payload.count > Self.maxPayloadBytes {
            throw ConjetBinaryFrameError.oversizedPayload(payload.count)
        }
        var data = Data()
        data.reserveCapacity(Self.headerSize + payload.count)
        data.appendUInt32BE(Self.magic)
        data.append(Self.version)
        data.append(type.rawValue)
        data.appendUInt16BE(flags)
        data.appendUInt32BE(streamID)
        data.appendUInt32BE(portForwardID)
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data, maxPayloadBytes: Int = maxPayloadBytes) throws -> ConjetBinaryFrame {
        guard data.count >= headerSize else {
            throw ConjetBinaryFrameError.truncatedHeader
        }
        let magic = data.readUInt32BE(at: 0)
        guard magic == Self.magic else {
            throw ConjetBinaryFrameError.badMagic
        }
        let version = data[data.index(data.startIndex, offsetBy: 4)]
        guard version == Self.version else {
            throw ConjetBinaryFrameError.badVersion(version)
        }
        let rawType = data[data.index(data.startIndex, offsetBy: 5)]
        guard let type = ConjetBinaryFrameType(rawValue: rawType) else {
            throw ConjetBinaryFrameError.unknownType(rawType)
        }
        let flags = data.readUInt16BE(at: 6)
        let streamID = data.readUInt32BE(at: 8)
        let portForwardID = data.readUInt32BE(at: 12)
        let payloadLength = Int(data.readUInt32BE(at: 16))
        guard payloadLength <= maxPayloadBytes else {
            throw ConjetBinaryFrameError.oversizedPayload(payloadLength)
        }
        guard data.count >= headerSize + payloadLength else {
            throw ConjetBinaryFrameError.truncatedPayload
        }
        let payloadStart = data.index(data.startIndex, offsetBy: headerSize)
        let payloadEnd = data.index(payloadStart, offsetBy: payloadLength)
        return ConjetBinaryFrame(
            type: type,
            flags: flags,
            streamID: streamID,
            portForwardID: portForwardID,
            payload: data[payloadStart..<payloadEnd]
        )
    }
}

public enum ConjetTCPFrameTargetError: Error, Equatable, Sendable {
    case invalidEncoding
    case invalidFormat
    case invalidHost
    case invalidPort(String)
}

public struct ConjetTCPFrameTarget: Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public func encode() throws -> Data {
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ConjetTCPFrameTargetError.invalidHost
        }
        guard port > 0, port <= 65_535 else {
            throw ConjetTCPFrameTargetError.invalidPort(String(port))
        }
        return Data("\(host) \(port)".utf8)
    }

    public static func decode(_ data: Data) throws -> ConjetTCPFrameTarget {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConjetTCPFrameTargetError.invalidEncoding
        }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2 else {
            throw ConjetTCPFrameTargetError.invalidFormat
        }
        guard let port = Int(parts[1]), port > 0, port <= 65_535 else {
            throw ConjetTCPFrameTargetError.invalidPort(parts[1])
        }
        return ConjetTCPFrameTarget(host: parts[0], port: port)
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        let start = index(startIndex, offsetBy: offset)
        let b0 = UInt16(self[start])
        let b1 = UInt16(self[index(after: start)])
        return (b0 << 8) | b1
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let start = index(startIndex, offsetBy: offset)
        let b0 = UInt32(self[start])
        let b1 = UInt32(self[index(start, offsetBy: 1)])
        let b2 = UInt32(self[index(start, offsetBy: 2)])
        let b3 = UInt32(self[index(start, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

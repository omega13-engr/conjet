import Foundation

public enum ConjetError: Error, CustomStringConvertible, Sendable {
    case invalidArgument(String)
    case unavailable(String)
    case filesystem(String)
    case processFailed(executable: String, exitCode: Int32, stderr: String)
    case socket(String)
    case encoding(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message):
            return "invalid argument: \(message)"
        case .unavailable(let message):
            return "unavailable: \(message)"
        case .filesystem(let message):
            return "filesystem error: \(message)"
        case .processFailed(let executable, let exitCode, let stderr):
            return "\(executable) failed with exit code \(exitCode): \(stderr)"
        case .socket(let message):
            return "socket error: \(message)"
        case .encoding(let message):
            return "encoding error: \(message)"
        case .decoding(let message):
            return "decoding error: \(message)"
        }
    }
}

public enum ConjetJSON {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func string<T: Encodable>(_ value: T, pretty: Bool = true) throws -> String {
        let data = try encoder(pretty: pretty).encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ConjetError.encoding("JSON data was not UTF-8")
        }
        return string
    }
}

import ConjetCore
import Darwin
import Foundation

struct PortHelperOptions {
    var socketPath: String
    var token: String
    var bindAddress: String
    var port: Int
    var proto: ConjetPortProtocol
}

enum PortHelperError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case socket(String)
    case bind(posixCode: Int32, message: String)

    var description: String {
        switch self {
        case .invalidArgument(let message), .socket(let message):
            return message
        case .bind(_, let message):
            return message
        }
    }

    var posixCode: Int32 {
        switch self {
        case .bind(let posixCode, _):
            return posixCode
        default:
            return 0
        }
    }
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let callbackFD = try connectUnixSocket(path: options.socketPath)
    defer { Darwin.close(callbackFD) }

    do {
        let boundFD = try bindPort(options)
        defer { Darwin.close(boundFD) }
        try UnixFileDescriptorPassing.send(
            fileDescriptor: boundFD,
            payload: Data("OK \(options.token)\n".utf8),
            to: callbackFD
        )
    } catch {
        let helperError = error as? PortHelperError
        let posixCode = helperError?.posixCode ?? 0
        let message = String(describing: error).replacingOccurrences(of: "\n", with: " ")
        try? UnixFileDescriptorPassing.send(
            fileDescriptor: nil,
            payload: Data("ERR \(options.token) \(posixCode) \(message)\n".utf8),
            to: callbackFD
        )
        throw error
    }
} catch {
    fputs("conjet-port-helper: \(error)\n", stderr)
    exit(1)
}

private func parseOptions(_ args: [String]) throws -> PortHelperOptions {
    guard args.first == "bind" else {
        throw PortHelperError.invalidArgument("usage: conjet-port-helper bind --socket PATH --token TOKEN --address ADDRESS --port PORT --proto tcp|udp")
    }
    var values: [String: String] = [:]
    var index = 1
    while index < args.count {
        let key = args[index]
        guard key.hasPrefix("--"), args.indices.contains(index + 1) else {
            throw PortHelperError.invalidArgument("missing value for \(key)")
        }
        values[String(key.dropFirst(2))] = args[index + 1]
        index += 2
    }
    guard let socketPath = values["socket"], !socketPath.isEmpty else {
        throw PortHelperError.invalidArgument("--socket is required")
    }
    guard let token = values["token"], !token.isEmpty else {
        throw PortHelperError.invalidArgument("--token is required")
    }
    guard let bindAddress = values["address"], !bindAddress.isEmpty else {
        throw PortHelperError.invalidArgument("--address is required")
    }
    guard let portText = values["port"],
          let port = Int(portText),
          port > 0,
          port <= 65_535 else {
        throw PortHelperError.invalidArgument("--port must be 1...65535")
    }
    guard let protoText = values["proto"],
          let proto = ConjetPortProtocol(rawValue: protoText) else {
        throw PortHelperError.invalidArgument("--proto must be tcp or udp")
    }
    return PortHelperOptions(
        socketPath: socketPath,
        token: token,
        bindAddress: bindAddress,
        port: port,
        proto: proto
    )
}

private func connectUnixSocket(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw PortHelperError.socket("socket(AF_UNIX) failed: \(lastErrno())")
    }
    do {
        try withUnixSocketAddress(path: path) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                throw PortHelperError.socket("connect(\(path)) failed: \(lastErrno())")
            }
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func bindPort(_ options: PortHelperOptions) throws -> Int32 {
    if options.bindAddress.contains(":") {
        return try bindIPv6Port(options)
    }
    return try bindIPv4Port(options)
}

private func bindIPv4Port(_ options: PortHelperOptions) throws -> Int32 {
    let type: Int32 = options.proto == .tcp ? SOCK_STREAM : SOCK_DGRAM
    let fd = Darwin.socket(AF_INET, type, 0)
    guard fd >= 0 else {
        throw PortHelperError.bind(posixCode: errno, message: "socket(AF_INET) failed: \(lastErrno())")
    }
    do {
        try configureBoundSocket(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(options.port).bigEndian
        let ip = options.bindAddress == "localhost" ? "127.0.0.1" : options.bindAddress
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            throw PortHelperError.bind(posixCode: 0, message: "invalid IPv4 bind address \(options.bindAddress)")
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw PortHelperError.bind(
                        posixCode: errno,
                        message: "bind(\(options.bindAddress):\(options.port)/\(options.proto.rawValue)) failed: \(lastErrno())"
                    )
                }
            }
        }
        if options.proto == .tcp {
            guard Darwin.listen(fd, 128) == 0 else {
                throw PortHelperError.bind(posixCode: errno, message: "listen() failed: \(lastErrno())")
            }
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func bindIPv6Port(_ options: PortHelperOptions) throws -> Int32 {
    let type: Int32 = options.proto == .tcp ? SOCK_STREAM : SOCK_DGRAM
    let fd = Darwin.socket(AF_INET6, type, 0)
    guard fd >= 0 else {
        throw PortHelperError.bind(posixCode: errno, message: "socket(AF_INET6) failed: \(lastErrno())")
    }
    do {
        try configureBoundSocket(fd)
        var v6Only: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(options.port).bigEndian
        let ip = options.bindAddress == "localhost" ? "::1" : options.bindAddress
        guard inet_pton(AF_INET6, ip, &address.sin6_addr) == 1 else {
            throw PortHelperError.bind(posixCode: 0, message: "invalid IPv6 bind address \(options.bindAddress)")
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 else {
                    throw PortHelperError.bind(
                        posixCode: errno,
                        message: "bind(\(options.bindAddress):\(options.port)/\(options.proto.rawValue)) failed: \(lastErrno())"
                    )
                }
            }
        }
        if options.proto == .tcp {
            guard Darwin.listen(fd, 128) == 0 else {
                throw PortHelperError.bind(posixCode: errno, message: "listen() failed: \(lastErrno())")
            }
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func configureBoundSocket(_ fd: Int32) throws {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

private func withUnixSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8CString.count <= maxPathLength else {
        throw PortHelperError.socket("Unix socket path is too long: \(path)")
    }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        path.utf8CString.withUnsafeBufferPointer { buffer in
            memcpy(pointer, buffer.baseAddress!, buffer.count)
        }
    }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            try body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func lastErrno() -> String {
    String(cString: strerror(errno))
}

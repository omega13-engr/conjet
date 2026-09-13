import Darwin
import Foundation
import Security

@objc public protocol PrivilegedPortServiceProtocol {
    func bind(address: String, port: Int, transport: String, reply: @escaping (FileHandle?, Int, String?) -> Void)
}

public enum PrivilegedPortService {
    public static let name = "dev.conjet.port-helper"
    public static let plistName = name + ".plist"
    public static let daemonIdentifier = "dev.conjet.daemon"
    private static let cachedSigningTeam = Result { try loadSigningTeam() }

    public static func signingTeam() throws -> String {
        try cachedSigningTeam.get()
    }

    private static func loadSigningTeam() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw ConjetError.unavailable("Privileged port authorization requires a Developer ID signed Conjet build.")
        }
        return team
    }

    public static func requirement(team: String, identifier: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard team.count == 10, team.unicodeScalars.allSatisfy(allowed.contains),
              [name, daemonIdentifier].contains(identifier) else {
            throw ConjetError.invalidArgument("invalid privileged helper signing identity")
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\" and ! (entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }

    public static func validate(address: String, port: Int, transport: String) throws {
        guard (1...1023).contains(port), ["tcp", "udp"].contains(transport) else {
            throw ConjetError.invalidArgument("privileged helper only binds TCP/UDP ports 1...1023")
        }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard address == "localhost" || inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1 else {
            throw ConjetError.invalidArgument("privileged helper requires a literal IP bind address")
        }
    }

    public static func bind(address: String, port: Int, transport: String, timeout: TimeInterval = 3) throws -> Int32 {
        try validate(address: address, port: port, transport: transport)
        let requirement = try requirement(team: signingTeam(), identifier: name)
        let connection = NSXPCConnection(machServiceName: name, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedPortServiceProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }
        let result = PrivilegedPortReply()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            result.complete(handle: nil, code: 0, message: "Authorize the Conjet port helper in Network settings. \(error.localizedDescription)")
        }) as? PrivilegedPortServiceProtocol else {
            throw ConjetError.unavailable("privileged port service is unavailable")
        }
        proxy.bind(address: address, port: port, transport: transport) { handle, code, message in
            result.complete(handle: handle, code: code, message: message)
        }
        return try result.wait(timeout: timeout)
    }
}

private final class PrivilegedPortReply: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false
    private var descriptor: Int32?
    private var error: String?
    private var posixCode = 0

    func complete(handle: FileHandle?, code: Int, message: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let handle {
            let fd = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
            if fd >= 0 { descriptor = fd }
            else { error = "could not retain privileged listener: \(String(cString: strerror(errno)))" }
        } else {
            posixCode = code
            error = message ?? "privileged bind failed (errno \(code))"
        }
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> Int32 {
        _ = semaphore.wait(timeout: .now() + max(0.1, timeout))
        lock.lock()
        defer { lock.unlock() }
        finished = true
        if let descriptor { return descriptor }
        if posixCode > 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: posixCode, userInfo: [NSLocalizedDescriptionKey: error ?? "privileged bind failed"])
        }
        throw ConjetError.unavailable(error ?? "privileged port helper timed out")
    }
}

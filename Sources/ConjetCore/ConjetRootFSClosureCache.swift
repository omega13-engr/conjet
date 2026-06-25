import CryptoKit
import Darwin
import Foundation

public struct ConjetRootFSClosureManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var digest: String
    public var source: String
    public var cachedPath: String
    public var sizeBytes: UInt64
    public var createdAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersion,
        digest: String,
        source: String,
        cachedPath: String,
        sizeBytes: UInt64,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.digest = digest
        self.source = source
        self.cachedPath = cachedPath
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }
}

public final class ConjetRootFSOpenHandle {
    public let fileDescriptor: Int32
    public let manifest: ConjetRootFSClosureManifest

    init(fileDescriptor: Int32, manifest: ConjetRootFSClosureManifest) {
        self.fileDescriptor = fileDescriptor
        self.manifest = manifest
    }

    deinit {
        Darwin.close(fileDescriptor)
    }
}

public final class ConjetRootFSClosureCache {
    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func prepare(rootfsURL: URL, source: String) throws -> ConjetRootFSClosureManifest {
        let standardized = rootfsURL.standardizedFileURL
        guard fileManager.fileExists(atPath: standardized.path) else {
            throw ConjetError.filesystem("rootfs closure source does not exist at \(standardized.path)")
        }
        let digest = try Self.sha256Hex(fileURL: standardized)
        let size = try Self.fileSize(standardized)
        let cachedURL = artifactURL(digest: digest)
        let manifestURL = self.manifestURL(digest: digest)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: cachedURL.path) {
            let temporaryURL = directory.appendingPathComponent(".\(digest).rootfs.tmp-\(UUID().uuidString)")
            try fileManager.copyItem(at: standardized, to: temporaryURL)
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: temporaryURL.path)
            try fileManager.moveItem(at: temporaryURL, to: cachedURL)
        }

        let cachedDigest = try Self.sha256Hex(fileURL: cachedURL)
        guard cachedDigest == digest else {
            throw ConjetError.filesystem("rootfs closure cache corruption for \(digest)")
        }

        let manifest = ConjetRootFSClosureManifest(
            digest: digest,
            source: source,
            cachedPath: cachedURL.path,
            sizeBytes: size
        )
        try ConjetJSON.encoder().encode(manifest).write(to: manifestURL, options: .atomic)
        return manifest
    }

    public func openValidated(digest: String) throws -> ConjetRootFSOpenHandle {
        let manifest = try loadManifest(digest: digest)
        let fd = Darwin.open(manifest.cachedPath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw ConjetError.filesystem("open cached rootfs failed: \(String(cString: strerror(errno)))")
        }
        do {
            let size = try Self.fileSize(fileDescriptor: fd)
            guard size == manifest.sizeBytes else {
                throw ConjetError.filesystem("cached rootfs size mismatch for \(digest)")
            }
            let actualDigest = try Self.sha256Hex(fileDescriptor: fd)
            guard actualDigest == manifest.digest else {
                throw ConjetError.filesystem("cached rootfs digest mismatch for \(digest)")
            }
            _ = Darwin.lseek(fd, 0, SEEK_SET)
            return ConjetRootFSOpenHandle(fileDescriptor: fd, manifest: manifest)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func loadManifest(digest: String) throws -> ConjetRootFSClosureManifest {
        let url = manifestURL(digest: digest)
        let manifest = try ConjetJSON.decoder().decode(
            ConjetRootFSClosureManifest.self,
            from: Data(contentsOf: url)
        )
        guard manifest.schemaVersion == ConjetRootFSClosureManifest.schemaVersion else {
            throw ConjetError.invalidArgument("unsupported rootfs closure manifest schema \(manifest.schemaVersion)")
        }
        guard manifest.digest == digest else {
            throw ConjetError.filesystem("rootfs closure manifest digest mismatch")
        }
        return manifest
    }

    public func artifactURL(digest: String) -> URL {
        directory.appendingPathComponent("\(digest).rootfs")
    }

    public func manifestURL(digest: String) -> URL {
        directory.appendingPathComponent("\(digest).json")
    }

    public static func sha256Hex(fileURL: URL) throws -> String {
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw ConjetError.filesystem("open \(fileURL.path) failed: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }
        return try sha256Hex(fileDescriptor: fd)
    }

    public static func sha256Hex(fileDescriptor fd: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let bytesRead = Darwin.read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                hasher.update(data: buffer[0..<bytesRead])
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw ConjetError.filesystem("read rootfs for sha256 failed: \(String(cString: strerror(errno)))")
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    public static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let value = attributes[.size] as? UInt64 {
            return value
        }
        if let value = attributes[.size] as? NSNumber {
            return value.uint64Value
        }
        return 0
    }

    public static func fileSize(fileDescriptor fd: Int32) throws -> UInt64 {
        var statValue = stat()
        guard Darwin.fstat(fd, &statValue) == 0 else {
            throw ConjetError.filesystem("fstat rootfs failed: \(String(cString: strerror(errno)))")
        }
        return UInt64(statValue.st_size)
    }
}

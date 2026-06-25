import ConjetCore
import Darwin
import Foundation
import XCTest

final class ConjetRootFSClosureCacheTests: XCTestCase {
    func testPrepareCopiesRootFSIntoContentAddressedReadOnlyCacheAndOpensValidatedFD() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-rootfs-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rootfs.raw")
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("rootfs-image-v1".utf8).write(to: source)

        let cache = ConjetRootFSClosureCache(directory: cacheDir)
        let manifest = try cache.prepare(rootfsURL: source, source: "test-image")

        XCTAssertEqual(manifest.source, "test-image")
        XCTAssertEqual(manifest.sizeBytes, UInt64(Data("rootfs-image-v1".utf8).count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.cachedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.manifestURL(digest: manifest.digest).path))
        let permissions = try FileManager.default.attributesOfItem(atPath: manifest.cachedPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o444)

        let handle = try cache.openValidated(digest: manifest.digest)
        XCTAssertEqual(handle.manifest.digest, manifest.digest)
        XCTAssertEqual(handle.manifest.cachedPath, manifest.cachedPath)
        XCTAssertEqual(handle.manifest.sizeBytes, manifest.sizeBytes)
        XCTAssertEqual(handle.manifest.source, manifest.source)
        var buffer = [UInt8](repeating: 0, count: 5)
        XCTAssertEqual(Darwin.read(handle.fileDescriptor, &buffer, buffer.count), 5)
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "rootf")
    }

    func testOpenValidatedRejectsCorruptedCachedRootFS() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-rootfs-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rootfs.raw")
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("rootfs-image-v1".utf8).write(to: source)

        let cache = ConjetRootFSClosureCache(directory: cacheDir)
        let manifest = try cache.prepare(rootfsURL: source, source: "test-image")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.cachedPath)
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: manifest.cachedPath))

        XCTAssertThrowsError(try cache.openValidated(digest: manifest.digest)) { error in
            XCTAssertTrue(String(describing: error).contains("cached rootfs size mismatch")
                || String(describing: error).contains("cached rootfs digest mismatch"))
        }
    }

    func testPrepareRejectsAlreadyCorruptedCacheEntry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-rootfs-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rootfs.raw")
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data("rootfs-image-v1".utf8).write(to: source)

        let digest = try ConjetRootFSClosureCache.sha256Hex(fileURL: source)
        try Data("corrupt-but-same-path".utf8).write(to: cacheDir.appendingPathComponent("\(digest).rootfs"))

        let cache = ConjetRootFSClosureCache(directory: cacheDir)
        XCTAssertThrowsError(try cache.prepare(rootfsURL: source, source: "test-image")) { error in
            XCTAssertTrue(String(describing: error).contains("rootfs closure cache corruption"))
        }
    }
}

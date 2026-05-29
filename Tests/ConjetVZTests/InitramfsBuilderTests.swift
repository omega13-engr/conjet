import ConjetVZ
import Foundation
import XCTest

final class InitramfsBuilderTests: XCTestCase {
    func testNewcArchiveContainsExpectedEntries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-initramfs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("initramfs.cpio")
        try InitramfsBuilder.writeNewcArchive(
            entries: [
                .directory("dev"),
                .directory("/proc"),
                .regularFile("/init", data: Data("hello".utf8), mode: 0o100755)
            ],
            to: archive
        )

        let names = try parseNewcNames(Data(contentsOf: archive))
        XCTAssertEqual(names, ["dev", "proc", "init", "TRAILER!!!"])
    }

    func testBuildCreatesGzipInitramfs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-initramfs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let initBinary = root.appendingPathComponent("conjet-init")
        try Data("static-linux-init-placeholder".utf8).write(to: initBinary)
        let output = root.appendingPathComponent("initramfs.cpio.gz")

        let result = try InitramfsBuilder.build(initBinary: initBinary, output: output)

        XCTAssertEqual(result.outputPath, output.path)
        XCTAssertGreaterThan(result.uncompressedBytes, 0)
        XCTAssertGreaterThan(result.compressedBytes, 0)
        XCTAssertGreaterThanOrEqual(result.entryCount, 8)
        XCTAssertEqual(try gzipTest(output), 0)
    }

    private func parseNewcNames(_ data: Data) throws -> [String] {
        var offset = 0
        var names: [String] = []
        while offset + 110 <= data.count {
            let header = data.subdata(in: offset..<(offset + 110))
            guard String(data: header.subdata(in: 0..<6), encoding: .ascii) == "070701" else {
                throw NSError(domain: "InitramfsBuilderTests", code: 1)
            }
            let fileSize = try hexField(header, 54)
            let nameSize = try hexField(header, 94)
            let nameStart = offset + 110
            let nameEnd = nameStart + nameSize - 1
            guard nameEnd <= data.count else {
                throw NSError(domain: "InitramfsBuilderTests", code: 2)
            }
            let nameData = data.subdata(in: nameStart..<nameEnd)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw NSError(domain: "InitramfsBuilderTests", code: 3)
            }
            names.append(name)
            offset = align4(nameStart + nameSize)
            offset = align4(offset + fileSize)
            if name == "TRAILER!!!" {
                break
            }
        }
        return names
    }

    private func hexField(_ header: Data, _ offset: Int) throws -> Int {
        let field = header.subdata(in: offset..<(offset + 8))
        guard let string = String(data: field, encoding: .ascii),
              let value = Int(string, radix: 16) else {
            throw NSError(domain: "InitramfsBuilderTests", code: 4)
        }
        return value
    }

    private func align4(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder == 0 ? value : value + (4 - remainder)
    }

    private func gzipTest(_ output: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-t", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

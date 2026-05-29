import ConjetCore
import Foundation

public enum InitramfsEntryKind: String, Codable, Equatable, Sendable {
    case directory
    case regularFile = "regular-file"
}

public struct InitramfsEntry: Equatable, Sendable {
    public var path: String
    public var kind: InitramfsEntryKind
    public var mode: UInt32
    public var data: Data

    public init(path: String, kind: InitramfsEntryKind, mode: UInt32, data: Data = Data()) {
        self.path = InitramfsEntry.normalizedPath(path)
        self.kind = kind
        self.mode = mode
        self.data = data
    }

    public static func directory(_ path: String, mode: UInt32 = 0o040755) -> InitramfsEntry {
        InitramfsEntry(path: path, kind: .directory, mode: mode)
    }

    public static func regularFile(_ path: String, data: Data, mode: UInt32 = 0o100644) -> InitramfsEntry {
        InitramfsEntry(path: path, kind: .regularFile, mode: mode, data: data)
    }

    private static func normalizedPath(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }
}

public struct InitramfsBuildResult: Codable, Equatable, Sendable {
    public var outputPath: String
    public var uncompressedBytes: UInt64
    public var compressedBytes: UInt64
    public var entryCount: Int

    public init(outputPath: String, uncompressedBytes: UInt64, compressedBytes: UInt64, entryCount: Int) {
        self.outputPath = outputPath
        self.uncompressedBytes = uncompressedBytes
        self.compressedBytes = compressedBytes
        self.entryCount = entryCount
    }
}

public enum InitramfsBuilder {
    public static func build(
        initBinary: URL,
        output: URL,
        productName: String = "conjet-initramfs"
    ) throws -> InitramfsBuildResult {
        guard FileManager.default.fileExists(atPath: initBinary.path) else {
            throw ConjetError.filesystem("init binary does not exist at \(initBinary.path)")
        }
        let initData = try Data(contentsOf: initBinary)
        let entries = defaultEntries(initData: initData, productName: productName)
        let parent = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let archive = parent.appendingPathComponent(".\(output.lastPathComponent).cpio")
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        try writeNewcArchive(entries: entries, to: archive)
        let uncompressedBytes = try fileSize(archive)
        try gzip(source: archive, destination: output)
        try? FileManager.default.removeItem(at: archive)

        return InitramfsBuildResult(
            outputPath: output.path,
            uncompressedBytes: uncompressedBytes,
            compressedBytes: try fileSize(output),
            entryCount: entries.count
        )
    }

    public static func writeNewcArchive(entries: [InitramfsEntry], to output: URL) throws {
        let parent = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var inode: UInt32 = 1
        for entry in entries {
            try write(entry: entry, inode: inode, to: handle)
            inode += 1
        }
        try write(
            entry: InitramfsEntry(path: "TRAILER!!!", kind: .regularFile, mode: 0, data: Data()),
            inode: inode,
            to: handle
        )
    }

    private static func defaultEntries(initData: Data, productName: String) -> [InitramfsEntry] {
        [
            .directory("dev"),
            .directory("proc"),
            .directory("sys"),
            .directory("run"),
            .directory("tmp", mode: 0o041777),
            .directory("etc"),
            .regularFile("init", data: initData, mode: 0o100755),
            .regularFile(
                "etc/conjet-release",
                data: Data("\(productName)\n".utf8),
                mode: 0o100644
            )
        ]
    }

    private static func write(entry: InitramfsEntry, inode: UInt32, to handle: FileHandle) throws {
        let pathData = Data(entry.path.utf8) + Data([0])
        let fileSize = entry.kind == .regularFile ? UInt32(entry.data.count) : 0
        let header = [
            "070701",
            hex(inode),
            hex(entry.mode),
            hex(0),
            hex(0),
            hex(entry.kind == .directory ? 2 : 1),
            hex(0),
            hex(fileSize),
            hex(0),
            hex(0),
            hex(0),
            hex(0),
            hex(UInt32(pathData.count)),
            hex(0)
        ].joined()
        try handle.write(contentsOf: Data(header.utf8))
        try handle.write(contentsOf: pathData)
        try writePadding(for: 110 + pathData.count, to: handle)
        if fileSize > 0 {
            try handle.write(contentsOf: entry.data)
            try writePadding(for: entry.data.count, to: handle)
        }
    }

    private static func gzip(source: URL, destination: URL) throws {
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destination)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-n", "-c", source.path]
        process.standardOutput = outputHandle
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ConjetError.processFailed(executable: "/usr/bin/gzip", exitCode: process.terminationStatus, stderr: stderr)
        }
    }

    private static func writePadding(for byteCount: Int, to handle: FileHandle) throws {
        let remainder = byteCount % 4
        if remainder != 0 {
            try handle.write(contentsOf: Data(repeating: 0, count: 4 - remainder))
        }
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "%08x", value)
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? UInt64 ?? 0
    }
}

import ConjetCore
import Foundation

public struct SmallFileWorkload: Sendable {
    public var fileCount: Int
    public var bytesPerFile: Int

    public init(fileCount: Int = 10_000, bytesPerFile: Int = 128) {
        self.fileCount = fileCount
        self.bytesPerFile = bytesPerFile
    }

    public func run(directory: URL, runtime: String = "host") throws -> BenchmarkResult {
        guard fileCount > 0 else {
            throw ConjetError.invalidArgument("fileCount must be positive")
        }
        guard bytesPerFile >= 0 else {
            throw ConjetError.invalidArgument("bytesPerFile must not be negative")
        }

        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x61, count: bytesPerFile)
        let machine = MachineProfiler.capture()
        let startedAt = Date()

        for index in 0..<fileCount {
            let bucket = directory.appendingPathComponent(String(format: "%03d", index % 256), isDirectory: true)
            try manager.createDirectory(at: bucket, withIntermediateDirectories: true)
            let file = bucket.appendingPathComponent("file-\(index).dat")
            try payload.write(to: file, options: .atomic)
        }

        var totalBytes = 0
        let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                totalBytes += values.fileSize ?? 0
            }
        }

        let duration = Date().timeIntervalSince(startedAt)
        return BenchmarkResult(
            workload: "many-small-files",
            runtime: runtime,
            startedAt: startedAt,
            durationSeconds: duration,
            exitCode: 0,
            metrics: [
                "file_count": Double(fileCount),
                "bytes_per_file": Double(bytesPerFile),
                "total_bytes": Double(totalBytes)
            ],
            machine: machine
        )
    }
}

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
                .characterDevice("/dev/console", major: 5, minor: 1),
                .regularFile("/init", data: Data("hello".utf8), mode: 0o100755)
            ],
            to: archive
        )

        let names = try parseNewcNames(Data(contentsOf: archive))
        XCTAssertEqual(names, ["dev", "proc", "dev/console", "init", "TRAILER!!!"])
        let entries = try parseNewcEntries(Data(contentsOf: archive))
        XCTAssertEqual(entries.first(where: { $0.name == "dev/console" })?.rdevMajor, 5)
        XCTAssertEqual(entries.first(where: { $0.name == "dev/console" })?.rdevMinor, 1)

        let archiveWithLink = root.appendingPathComponent("initramfs-with-link.cpio")
        try InitramfsBuilder.writeNewcArchive(
            entries: [
                .directory("bin"),
                .regularFile("bin/busybox", data: Data("busybox".utf8), mode: 0o100755),
                .symbolicLink("bin/sh", target: "busybox")
            ],
            to: archiveWithLink
        )
        let linkEntries = try parseNewcEntries(Data(contentsOf: archiveWithLink))
        let shellEntry = try XCTUnwrap(linkEntries.first { $0.name == "bin/sh" })
        XCTAssertEqual(shellEntry.mode & 0o170000, 0o120000)
        XCTAssertEqual(shellEntry.data, Data("busybox".utf8))
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
        XCTAssertGreaterThanOrEqual(result.entryCount, 12)
        XCTAssertEqual(try gzipTest(output), 0)
    }

    func testBuildConjetReadyProbeCreatesStaticAarch64Init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-initramfs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let output = root.appendingPathComponent("conjet-ready.cpio.gz")
        let result = try InitramfsBuilder.buildConjetReadyProbe(output: output)

        XCTAssertEqual(result.outputPath, output.path)
        XCTAssertGreaterThan(result.uncompressedBytes, 0)
        XCTAssertGreaterThan(result.compressedBytes, 0)
        XCTAssertGreaterThanOrEqual(result.entryCount, 12)
        XCTAssertEqual(try gzipTest(output), 0)

        let archive = try gzipDecode(output)
        let entries = try parseNewcEntries(archive)
        XCTAssertEqual(entries.first(where: { $0.name == "dev/console" })?.rdevMajor, 5)
        XCTAssertEqual(entries.first(where: { $0.name == "dev/ttyAMA0" })?.rdevMajor, 204)
        XCTAssertEqual(entries.first(where: { $0.name == "dev/ttyAMA0" })?.rdevMinor, 64)
        let initEntry = try XCTUnwrap(entries.first { $0.name == "init" })
        XCTAssertTrue(initEntry.data.starts(with: Data([0x7f, 0x45, 0x4c, 0x46])))
        XCTAssertNotNil(initEntry.data.range(of: Data("CONJET_INIT_READY\n".utf8)))
        let readinessEntry = try XCTUnwrap(entries.first { $0.name == "etc/conjet/readiness-vector" })
        let readinessContract = try XCTUnwrap(String(data: readinessEntry.data, encoding: .utf8))
        XCTAssertTrue(readinessContract.contains("vsock_port=1029"))
        XCTAssertTrue(readinessContract.contains("record_bytes=24"))
    }

    func testBuildConjetInitValidatesStaticAarch64InitAndPackagesReadinessContract() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-initramfs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let initBinary = root.appendingPathComponent("conjet-init")
        let initData = staticArm64LinuxELF()
        try initData.write(to: initBinary)
        let output = root.appendingPathComponent("conjet-init.cpio.gz")

        let result = try InitramfsBuilder.buildConjetInit(initBinary: initBinary, output: output)

        XCTAssertEqual(result.outputPath, output.path)
        XCTAssertGreaterThanOrEqual(result.entryCount, 12)
        XCTAssertEqual(try gzipTest(output), 0)

        let archive = try gzipDecode(output)
        let entries = try parseNewcEntries(archive)
        XCTAssertEqual(entries.first(where: { $0.name == "init" })?.data, initData)
        let releaseEntry = try XCTUnwrap(entries.first { $0.name == "etc/conjet-release" })
        XCTAssertEqual(String(data: releaseEntry.data, encoding: .utf8), "conjet-pulse-initramfs\n")
        let readinessEntry = try XCTUnwrap(entries.first { $0.name == "etc/conjet/readiness-vector" })
        let readinessContract = try XCTUnwrap(String(data: readinessEntry.data, encoding: .utf8))
        XCTAssertTrue(readinessContract.contains("event_control_ready=1"))
        XCTAssertTrue(readinessContract.contains("event_process_started=2"))
    }

    func testBuildConjetInitRejectsDynamicOrNonELFInput() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-initramfs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let initBinary = root.appendingPathComponent("conjet-init")
        try Data("not-an-elf".utf8).write(to: initBinary)
        let output = root.appendingPathComponent("conjet-init.cpio.gz")

        XCTAssertThrowsError(try InitramfsBuilder.buildConjetInit(initBinary: initBinary, output: output)) { error in
            XCTAssertTrue(String(describing: error).contains("static ARM64 Linux conjet-init"))
        }
    }

    func testBuildNetworkProofProbePackagesBusyBoxDHCPAndProofMarkers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-initramfs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let busybox = root.appendingPathComponent("busybox-aarch64")
        let busyboxData = staticArm64LinuxELF()
        try busyboxData.write(to: busybox)
        let output = root.appendingPathComponent("network-proof.cpio.gz")

        let result = try InitramfsBuilder.buildNetworkProofProbe(
            busybox: busybox,
            output: output,
            proofURL: "http://192.0.2.1/proof",
            guestServicePort: 18080
        )

        XCTAssertEqual(result.outputPath, output.path)
        XCTAssertGreaterThan(result.entryCount, 18)
        XCTAssertEqual(try gzipTest(output), 0)

        let archive = try gzipDecode(output)
        let entries = try parseNewcEntries(archive)
        XCTAssertEqual(entries.first(where: { $0.name == "bin/busybox" })?.data, busyboxData)
        XCTAssertEqual(entries.first(where: { $0.name == "dev/ttyAMA0" })?.rdevMajor, 204)
        let shellEntry = try XCTUnwrap(entries.first { $0.name == "bin/sh" })
        XCTAssertEqual(shellEntry.mode & 0o170000, 0o120000)
        XCTAssertEqual(shellEntry.data, Data("busybox".utf8))

        let initEntry = try XCTUnwrap(entries.first { $0.name == "init" })
        let initScript = try XCTUnwrap(String(data: initEntry.data, encoding: .utf8))
        XCTAssertTrue(initScript.contains("CONJET_NETWORK_PROOF_BEGIN"))
        let readyRange = try XCTUnwrap(initScript.range(of: "echo CONJET_INIT_READY"))
        let interfaceRange = try XCTUnwrap(initScript.range(of: "iface=\"\""))
        XCTAssertLessThan(readyRange.lowerBound, interfaceRange.lowerBound)
        XCTAssertTrue(initScript.contains("nslookup example.com"))
        XCTAssertTrue(initScript.contains("nslookup example.com \"${dns_server}\""))
        XCTAssertTrue(initScript.contains("dhcp_pid=\"$!\""))
        XCTAssertTrue(initScript.contains("/run/conjet/dhcp.bound"))
        XCTAssertTrue(initScript.contains("/run/conjet/dns.server"))
        XCTAssertTrue(initScript.contains("CONJET_NETWORK_DNS_RESOLVED name=example.com"))
        XCTAssertTrue(initScript.contains("CONJET_NETWORK_OUTBOUND_TCP_OK url=http://192.0.2.1/proof"))
        XCTAssertTrue(initScript.contains("CONJET_NETWORK_SERVICE_TOKEN token=${proof_token}"))
        XCTAssertTrue(initScript.contains("CONJET_NETWORK_FORWARDED_PORT_OK token=${proof_token}"))
        XCTAssertTrue(initScript.contains("CONJET_NETWORK_GUEST_SERVICE_READY port=18080"))
        XCTAssertTrue(initScript.contains("CONJET_INIT_READY"))
        let readinessEntry = try XCTUnwrap(entries.first { $0.name == "etc/conjet/readiness-vector" })
        let readinessContract = try XCTUnwrap(String(data: readinessEntry.data, encoding: .utf8))
        XCTAssertTrue(readinessContract.contains("event_control_ready=1"))
        XCTAssertTrue(readinessContract.contains("event_process_started=2"))

        let udhcpcEntry = try XCTUnwrap(entries.first { $0.name == "etc/udhcpc/default.script" })
        let udhcpcScript = try XCTUnwrap(String(data: udhcpcEntry.data, encoding: .utf8))
        XCTAssertTrue(udhcpcScript.contains("CONJET_NETWORK_DHCP_BOUND"))
        XCTAssertTrue(udhcpcScript.contains("/run/conjet/dhcp.bound"))
        XCTAssertTrue(udhcpcScript.contains("/run/conjet/dns.servers"))
        XCTAssertTrue(udhcpcScript.contains("/run/conjet/dns.server"))
        XCTAssertTrue(udhcpcScript.contains("/etc/resolv.conf"))

        let serviceEntry = try XCTUnwrap(entries.first { $0.name == "www/index.html" })
        XCTAssertEqual(String(data: serviceEntry.data, encoding: .utf8), "CONJET_NETWORK_FORWARDED_PORT_OK\n")
    }

    func testBuildNetworkProofProbeValidatesInputs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-initramfs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let busybox = root.appendingPathComponent("busybox-aarch64")
        try Data("busybox".utf8).write(to: busybox)
        let output = root.appendingPathComponent("network-proof.cpio.gz")

        XCTAssertThrowsError(try InitramfsBuilder.buildNetworkProofProbe(
            busybox: root.appendingPathComponent("missing-busybox"),
            output: output
        ))
        XCTAssertThrowsError(try InitramfsBuilder.buildNetworkProofProbe(
            busybox: busybox,
            output: output,
            proofURL: "  "
        ))
        XCTAssertThrowsError(try InitramfsBuilder.buildNetworkProofProbe(
            busybox: busybox,
            output: output,
            guestServicePort: 70_000
        ))
        XCTAssertThrowsError(try InitramfsBuilder.buildNetworkProofProbe(
            busybox: busybox,
            output: output,
            proofURL: "http://192.0.2.1/proof",
            guestServicePort: 8080
        )) { error in
            XCTAssertTrue(String(describing: error).contains("static ARM64 Linux BusyBox"))
        }
    }

    private struct NewcEntry {
        var name: String
        var mode: Int
        var rdevMajor: Int
        var rdevMinor: Int
        var data: Data = Data()
    }

    private func parseNewcEntries(_ data: Data) throws -> [NewcEntry] {
        var offset = 0
        var entries: [NewcEntry] = []
        while offset + 110 <= data.count {
            let header = data.subdata(in: offset..<(offset + 110))
            guard String(data: header.subdata(in: 0..<6), encoding: .ascii) == "070701" else {
                throw NSError(domain: "InitramfsBuilderTests", code: 5)
            }
            let mode = try hexField(header, 14)
            let fileSize = try hexField(header, 54)
            let rdevMajor = try hexField(header, 78)
            let rdevMinor = try hexField(header, 86)
            let nameSize = try hexField(header, 94)
            let nameStart = offset + 110
            let nameEnd = nameStart + nameSize - 1
            guard nameEnd <= data.count else {
                throw NSError(domain: "InitramfsBuilderTests", code: 6)
            }
            let nameData = data.subdata(in: nameStart..<nameEnd)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw NSError(domain: "InitramfsBuilderTests", code: 7)
            }
            offset = align4(nameStart + nameSize)
            let fileData = data.subdata(in: offset..<(offset + fileSize))
            entries.append(NewcEntry(name: name, mode: mode, rdevMajor: rdevMajor, rdevMinor: rdevMinor, data: fileData))
            offset = align4(offset + fileSize)
            if name == "TRAILER!!!" {
                break
            }
        }
        return entries
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

    private func gzipDecode(_ output: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", output.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    private func staticArm64LinuxELF() -> Data {
        var elf = Data()
        elf.append(contentsOf: [0x7f, 0x45, 0x4c, 0x46])
        elf.append(contentsOf: [0x02, 0x01, 0x01, 0x00])
        elf.append(contentsOf: Data(repeating: 0, count: 8))
        elf.appendLittleEndian(UInt16(2))
        elf.appendLittleEndian(UInt16(183))
        elf.appendLittleEndian(UInt32(1))
        elf.appendLittleEndian(UInt64(0x0040_0000))
        elf.appendLittleEndian(UInt64(64))
        elf.appendLittleEndian(UInt64(0))
        elf.appendLittleEndian(UInt32(0))
        elf.appendLittleEndian(UInt16(64))
        elf.appendLittleEndian(UInt16(56))
        elf.appendLittleEndian(UInt16(1))
        elf.appendLittleEndian(UInt16(0))
        elf.appendLittleEndian(UInt16(0))
        elf.appendLittleEndian(UInt16(0))

        elf.appendLittleEndian(UInt32(1))
        elf.appendLittleEndian(UInt32(5))
        elf.appendLittleEndian(UInt64(0x1000))
        elf.appendLittleEndian(UInt64(0x0040_0000))
        elf.appendLittleEndian(UInt64(0x0040_0000))
        elf.appendLittleEndian(UInt64(4))
        elf.appendLittleEndian(UInt64(4))
        elf.appendLittleEndian(UInt64(0x1000))
        if elf.count < 0x1000 {
            elf.append(contentsOf: Data(repeating: 0, count: 0x1000 - elf.count))
        }
        elf.append(contentsOf: [0xc0, 0x03, 0x5f, 0xd6])
        return elf
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}

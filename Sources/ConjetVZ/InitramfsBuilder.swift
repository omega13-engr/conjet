import ConjetCore
import Foundation

public enum InitramfsEntryKind: String, Codable, Equatable, Sendable {
    case directory
    case regularFile = "regular-file"
    case symbolicLink = "symbolic-link"
    case characterDevice = "character-device"
}

public struct InitramfsEntry: Equatable, Sendable {
    public var path: String
    public var kind: InitramfsEntryKind
    public var mode: UInt32
    public var data: Data
    public var major: UInt32
    public var minor: UInt32

    public init(
        path: String,
        kind: InitramfsEntryKind,
        mode: UInt32,
        data: Data = Data(),
        major: UInt32 = 0,
        minor: UInt32 = 0
    ) {
        self.path = InitramfsEntry.normalizedPath(path)
        self.kind = kind
        self.mode = mode
        self.data = data
        self.major = major
        self.minor = minor
    }

    public static func directory(_ path: String, mode: UInt32 = 0o040755) -> InitramfsEntry {
        InitramfsEntry(path: path, kind: .directory, mode: mode)
    }

    public static func regularFile(_ path: String, data: Data, mode: UInt32 = 0o100644) -> InitramfsEntry {
        InitramfsEntry(path: path, kind: .regularFile, mode: mode, data: data)
    }

    public static func symbolicLink(_ path: String, target: String, mode: UInt32 = 0o120777) -> InitramfsEntry {
        InitramfsEntry(path: path, kind: .symbolicLink, mode: mode, data: Data(target.utf8))
    }

    public static func characterDevice(
        _ path: String,
        major: UInt32,
        minor: UInt32,
        mode: UInt32 = 0o020600
    ) -> InitramfsEntry {
        InitramfsEntry(path: path, kind: .characterDevice, mode: mode, major: major, minor: minor)
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
        return try build(entries: defaultEntries(initData: initData, productName: productName), output: output)
    }

    public static func buildConjetReadyProbe(
        output: URL,
        productName: String = "conjet-initramfs"
    ) throws -> InitramfsBuildResult {
        try build(entries: conjetReadyProbeEntries(productName: productName), output: output)
    }

    public static func buildConjetInit(
        initBinary: URL,
        output: URL,
        productName: String = "conjet-pulse-initramfs"
    ) throws -> InitramfsBuildResult {
        guard FileManager.default.fileExists(atPath: initBinary.path) else {
            throw ConjetError.filesystem("conjet-init binary does not exist at \(initBinary.path)")
        }
        let initData = try Data(contentsOf: initBinary)
        try validateStaticArm64LinuxELF(initData, sourceDescription: "static ARM64 Linux conjet-init")
        return try build(entries: defaultEntries(initData: initData, productName: productName), output: output)
    }

    public static func buildNetworkProofProbe(
        busybox: URL,
        output: URL,
        proofURL: String = "http://example.com",
        guestServicePort: Int = 8080,
        productName: String = "conjet-network-proof-initramfs"
    ) throws -> InitramfsBuildResult {
        guard FileManager.default.fileExists(atPath: busybox.path) else {
            throw ConjetError.filesystem("static Linux busybox does not exist at \(busybox.path)")
        }
        let trimmedProofURL = proofURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProofURL.isEmpty else {
            throw ConjetError.invalidArgument("network proof URL must not be empty")
        }
        guard (1...65_535).contains(guestServicePort) else {
            throw ConjetError.invalidArgument("network proof guest service port must be 1...65535")
        }
        let busyboxData = try Data(contentsOf: busybox)
        try validateStaticArm64LinuxELF(
            busyboxData,
            sourceDescription: "static ARM64 Linux BusyBox"
        )
        return try build(
            entries: networkProofProbeEntries(
                busyboxData: busyboxData,
                proofURL: trimmedProofURL,
                guestServicePort: guestServicePort,
                productName: productName
            ),
            output: output
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

    static func validateStaticArm64LinuxELF(
        _ data: Data,
        sourceDescription: String
    ) throws {
        guard data.count >= 64 else {
            throw ConjetError.unavailable("\(sourceDescription) must be an ELF64 AArch64 Linux binary; file is too small")
        }
        guard Data(data.prefix(4)) == Data([0x7f, 0x45, 0x4c, 0x46]) else {
            throw ConjetError.unavailable("\(sourceDescription) must be an ELF64 AArch64 Linux binary")
        }
        guard data[4] == 0x02 else {
            throw ConjetError.unavailable("\(sourceDescription) must be ELF64")
        }
        guard data[5] == 0x01 else {
            throw ConjetError.unavailable("\(sourceDescription) must be little-endian ELF")
        }
        guard data[6] == 0x01 else {
            throw ConjetError.unavailable("\(sourceDescription) has an unsupported ELF version")
        }

        let objectType = try readUInt16LE(data, at: 16, sourceDescription: sourceDescription)
        guard objectType == 2 || objectType == 3 else {
            throw ConjetError.unavailable("\(sourceDescription) must be an executable or PIE ELF")
        }
        let machine = try readUInt16LE(data, at: 18, sourceDescription: sourceDescription)
        guard machine == 183 else {
            throw ConjetError.unavailable("\(sourceDescription) must target AArch64; ELF machine is \(machine)")
        }
        let version = try readUInt32LE(data, at: 20, sourceDescription: sourceDescription)
        guard version == 1 else {
            throw ConjetError.unavailable("\(sourceDescription) has an unsupported ELF object version")
        }

        let programHeaderOffset = try readUInt64LE(data, at: 32, sourceDescription: sourceDescription)
        let programHeaderEntrySize = try readUInt16LE(data, at: 54, sourceDescription: sourceDescription)
        let programHeaderCount = try readUInt16LE(data, at: 56, sourceDescription: sourceDescription)
        guard programHeaderOffset > 0,
              programHeaderOffset <= UInt64(Int.max),
              programHeaderEntrySize >= 56,
              programHeaderCount > 0 else {
            throw ConjetError.unavailable("\(sourceDescription) must contain a valid ELF program header table")
        }

        let tableOffset = Int(programHeaderOffset)
        let entrySize = Int(programHeaderEntrySize)
        let entryCount = Int(programHeaderCount)
        guard entryCount <= (Int.max / max(entrySize, 1)) else {
            throw ConjetError.unavailable("\(sourceDescription) ELF program header table is too large")
        }
        let tableSize = entrySize * entryCount
        guard tableOffset <= data.count,
              tableSize <= data.count - tableOffset else {
            throw ConjetError.unavailable("\(sourceDescription) ELF program header table is truncated")
        }

        var hasLoadSegment = false
        for index in 0..<entryCount {
            let entryOffset = tableOffset + index * entrySize
            let programType = try readUInt32LE(data, at: entryOffset, sourceDescription: sourceDescription)
            if programType == 1 {
                let segmentOffset = try readUInt64LE(
                    data,
                    at: entryOffset + 8,
                    sourceDescription: sourceDescription
                )
                let fileSize = try readUInt64LE(
                    data,
                    at: entryOffset + 32,
                    sourceDescription: sourceDescription
                )
                guard segmentOffset <= UInt64(Int.max),
                      fileSize <= UInt64(Int.max) else {
                    throw ConjetError.unavailable("\(sourceDescription) has an oversized ELF load segment")
                }
                let segmentOffsetInt = Int(segmentOffset)
                let fileSizeInt = Int(fileSize)
                guard segmentOffsetInt <= data.count,
                      fileSizeInt <= data.count - segmentOffsetInt else {
                    throw ConjetError.unavailable("\(sourceDescription) ELF load segment is truncated")
                }
                hasLoadSegment = true
            }
            if programType == 3 {
                throw ConjetError.unavailable(
                    "\(sourceDescription) must be statically linked; ELF PT_INTERP segment was found"
                )
            }
        }
        guard hasLoadSegment else {
            throw ConjetError.unavailable("\(sourceDescription) must contain a loadable ELF segment")
        }
    }

    private static func build(entries: [InitramfsEntry], output: URL) throws -> InitramfsBuildResult {
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

    private static func defaultEntries(initData: Data, productName: String) -> [InitramfsEntry] {
        [
            .directory("dev"),
            .directory("proc"),
            .directory("sys"),
            .directory("run"),
            .directory("run/conjet"),
            .directory("tmp", mode: 0o041777),
            .directory("etc"),
            .directory("etc/conjet"),
            .characterDevice("dev/console", major: 5, minor: 1, mode: 0o020600),
            .characterDevice("dev/null", major: 1, minor: 3, mode: 0o020666),
            .characterDevice("dev/kmsg", major: 1, minor: 11, mode: 0o020600),
            .regularFile("init", data: initData, mode: 0o100755),
            .regularFile(
                "etc/conjet-release",
                data: Data("\(productName)\n".utf8),
                mode: 0o100644
            ),
            .regularFile(
                "etc/conjet/readiness-vector",
                data: Data(readinessVectorContract().utf8),
                mode: 0o100644
            )
        ]
    }

    private static func conjetReadyProbeEntries(productName: String) -> [InitramfsEntry] {
        [
            .directory("dev"),
            .directory("proc"),
            .directory("sys"),
            .directory("run"),
            .directory("run/conjet"),
            .directory("tmp", mode: 0o041777),
            .directory("etc"),
            .directory("etc/conjet"),
            .characterDevice("dev/console", major: 5, minor: 1, mode: 0o020600),
            .characterDevice("dev/null", major: 1, minor: 3, mode: 0o020666),
            .characterDevice("dev/kmsg", major: 1, minor: 11, mode: 0o020600),
            .characterDevice("dev/ttyAMA0", major: 204, minor: 64, mode: 0o020600),
            .regularFile("init", data: conjetReadyProbeInitELF(), mode: 0o100755),
            .regularFile(
                "etc/conjet-release",
                data: Data("\(productName)\n".utf8),
                mode: 0o100644
            ),
            .regularFile(
                "etc/conjet/readiness-vector",
                data: Data(readinessVectorContract().utf8),
                mode: 0o100644
            )
        ]
    }

    private static func networkProofProbeEntries(
        busyboxData: Data,
        proofURL: String,
        guestServicePort: Int,
        productName: String
    ) -> [InitramfsEntry] {
        [
            .directory("bin"),
            .directory("dev"),
            .directory("etc"),
            .directory("etc/conjet"),
            .directory("etc/udhcpc"),
            .directory("proc"),
            .directory("run"),
            .directory("run/conjet"),
            .directory("sys"),
            .directory("tmp", mode: 0o041777),
            .directory("www"),
            .characterDevice("dev/console", major: 5, minor: 1, mode: 0o020600),
            .characterDevice("dev/null", major: 1, minor: 3, mode: 0o020666),
            .characterDevice("dev/kmsg", major: 1, minor: 11, mode: 0o020600),
            .characterDevice("dev/ttyAMA0", major: 204, minor: 64, mode: 0o020600),
            .regularFile("bin/busybox", data: busyboxData, mode: 0o100755),
        ] + networkProofBusyBoxLinks() + [
            .regularFile(
                "etc/udhcpc/default.script",
                data: Data(networkProofUDHCPCScript().utf8),
                mode: 0o100755
            ),
            .regularFile(
                "init",
                data: Data(networkProofInitScript(
                    proofURL: proofURL,
                    guestServicePort: guestServicePort
                ).utf8),
                mode: 0o100755
            ),
            .regularFile(
                "www/index.html",
                data: Data("CONJET_NETWORK_FORWARDED_PORT_OK\n".utf8),
                mode: 0o100644
            ),
            .regularFile(
                "etc/resolv.conf",
                data: Data("nameserver 1.1.1.1\nnameserver 8.8.8.8\n".utf8),
                mode: 0o100644
            ),
            .regularFile(
                "etc/conjet-release",
                data: Data("\(productName)\n".utf8),
                mode: 0o100644
            ),
            .regularFile(
                "etc/conjet/readiness-vector",
                data: Data(readinessVectorContract().utf8),
                mode: 0o100644
            )
        ]
    }

    private static func readinessVectorContract() -> String {
        """
        version=1
        frame_kind=readiness
        vsock_port=1029
        record_bytes=24
        event_control_ready=1
        event_process_started=2
        legacy_serial_marker=CONJET_INIT_READY
        """
    }

    private static func networkProofBusyBoxLinks() -> [InitramfsEntry] {
        [
            "sh",
            "mount",
            "mkdir",
            "sleep",
            "ip",
            "udhcpc",
            "nslookup",
            "wget",
            "httpd",
            "route",
            "cat",
            "ifconfig"
        ].map { applet in
            .symbolicLink("bin/\(applet)", target: "busybox")
        }
    }

    private static func networkProofInitScript(proofURL: String, guestServicePort: Int) -> String {
        """
        #!/bin/busybox sh
        set -u

        bb=/bin/busybox
        export PATH=/bin

        log() {
            echo "conjet-network-proof: $*"
        }

        mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
        mount -t proc proc /proc 2>/dev/null || true
        mount -t sysfs sysfs /sys 2>/dev/null || true
        mkdir -p /run/conjet /tmp /www
        $bb --install -s /bin 2>/dev/null || true

        echo CONJET_NETWORK_PROOF_BEGIN
        echo CONJET_INIT_READY

        iface=""
        for candidate in eth0 enp0s1 ens3; do
            if [ -d "/sys/class/net/${candidate}" ]; then
                iface="${candidate}"
                break
            fi
        done

        if [ -z "${iface}" ]; then
            echo CONJET_NETWORK_INTERFACE_MISSING
            echo CONJET_INIT_READY
            while true; do $bb sleep 3600; done
        fi

        echo "CONJET_NETWORK_INTERFACE_FOUND interface=${iface}"
        log "using interface ${iface}"
        $bb ip link set lo up 2>/dev/null || true
        $bb ip link set "${iface}" up 2>/dev/null || true
        echo "CONJET_NETWORK_LINK_SET_UP interface=${iface}"
        $bb ip addr show dev "${iface}" 2>/dev/null || true

        echo "CONJET_NETWORK_DHCP_START interface=${iface}"
        $bb udhcpc -i "${iface}" -s /etc/udhcpc/default.script -q -t 10 -T 1 &
        dhcp_pid="$!"
        echo "CONJET_NETWORK_DHCP_PID pid=${dhcp_pid}"
        dhcp_ok=false
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            echo "CONJET_NETWORK_DHCP_WAIT tick=${_}"
            if [ -f /run/conjet/dhcp.bound ]; then
                dhcp_ok=true
                break
            fi
            $bb sleep 1
        done

        if [ "${dhcp_ok}" = true ]; then
            echo "CONJET_NETWORK_DHCP_OK interface=${iface}"
        else
            echo "CONJET_NETWORK_DHCP_FAILED interface=${iface}"
        fi

        $bb ip addr show dev "${iface}" 2>/dev/null || true
        $bb ip route show 2>/dev/null || true

        dns_server="$($bb cat /run/conjet/dns.server 2>/dev/null || true)"
        if [ -n "${dns_server}" ]; then
            $bb nslookup example.com "${dns_server}" >/run/conjet/dns.proof 2>&1
            dns_status="$?"
        else
            $bb nslookup example.com >/run/conjet/dns.proof 2>&1
            dns_status="$?"
        fi
        if [ "${dns_status}" = 0 ]; then
            echo "CONJET_NETWORK_DNS_RESOLVED name=example.com"
        else
            echo "CONJET_NETWORK_DNS_FAILED name=example.com"
            $bb cat /run/conjet/dns.proof 2>/dev/null || true
        fi

        if $bb wget -q -T 10 -O /run/conjet/outbound.tcp.proof "\(proofURL)"; then
            echo "CONJET_NETWORK_OUTBOUND_TCP_OK url=\(proofURL)"
        else
            echo "CONJET_NETWORK_OUTBOUND_TCP_FAILED url=\(proofURL)"
            $bb cat /run/conjet/outbound.tcp.proof 2>/dev/null || true
        fi

        proof_token="$($bb cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
        if [ -z "${proof_token}" ]; then
            proof_token="pid-$$"
        fi
        echo "CONJET_NETWORK_SERVICE_TOKEN token=${proof_token}"
        echo "CONJET_NETWORK_FORWARDED_PORT_OK token=${proof_token}" > /www/index.html
        if $bb httpd -p 0.0.0.0:\(guestServicePort) -h /www; then
            echo "CONJET_NETWORK_GUEST_SERVICE_READY port=\(guestServicePort)"
        else
            echo "CONJET_NETWORK_GUEST_SERVICE_FAILED port=\(guestServicePort)"
        fi

        echo CONJET_INIT_READY
        while true; do $bb sleep 3600; done
        """
    }

    private static func networkProofUDHCPCScript() -> String {
        """
        #!/bin/busybox sh
        set -u

        bb=/bin/busybox

        case "${1:-}" in
            deconfig)
                $bb ifconfig "${interface}" 0.0.0.0 2>/dev/null || true
                ;;
            bound|renew)
                $bb ifconfig "${interface}" "${ip}" netmask "${subnet:-255.255.255.0}" up
                if [ -n "${router:-}" ]; then
                    for gateway in ${router}; do
                        $bb route add default gw "${gateway}" dev "${interface}" 2>/dev/null || true
                    done
                fi
                : > /etc/resolv.conf
                if [ -n "${dns:-}" ]; then
                    : > /run/conjet/dns.servers
                    first_dns=""
                    for server in ${dns}; do
                        echo "nameserver ${server}" >> /etc/resolv.conf
                        echo "${server}" >> /run/conjet/dns.servers
                        if [ -z "${first_dns}" ]; then
                            first_dns="${server}"
                        fi
                    done
                    if [ -n "${first_dns}" ]; then
                        echo "${first_dns}" > /run/conjet/dns.server
                    fi
                fi
                echo "CONJET_NETWORK_DHCP_BOUND interface=${interface} ip=${ip} router=${router:-} dns=${dns:-}"
                : > /run/conjet/dhcp.bound
                ;;
        esac
        """
    }

    private static func conjetReadyProbeInitELF() -> Data {
        var text = Data()
        text.appendLittleEndian(UInt32(0xd280_0000))
        text.appendLittleEndian(UInt32(0xd101_9000))
        text.appendLittleEndian(UInt32(0x1000_02e1))
        text.appendLittleEndian(UInt32(0xd280_0022))
        text.appendLittleEndian(UInt32(0xd280_0003))
        text.appendLittleEndian(UInt32(0xd280_0708))
        text.appendLittleEndian(UInt32(0xd400_0001))
        text.appendLittleEndian(UInt32(0xb7f8_0040))
        text.appendLittleEndian(UInt32(0x1400_000b))
        text.appendLittleEndian(UInt32(0xd280_0000))
        text.appendLittleEndian(UInt32(0xd101_9000))
        text.appendLittleEndian(UInt32(0x1000_0241))
        text.appendLittleEndian(UInt32(0xd280_0022))
        text.appendLittleEndian(UInt32(0xd280_0003))
        text.appendLittleEndian(UInt32(0xd280_0708))
        text.appendLittleEndian(UInt32(0xd400_0001))
        text.appendLittleEndian(UInt32(0xb7f8_0040))
        text.appendLittleEndian(UInt32(0x1400_0002))
        text.appendLittleEndian(UInt32(0xd280_0020))
        text.appendLittleEndian(UInt32(0x1000_01c1))
        text.appendLittleEndian(UInt32(0xd280_0242))
        text.appendLittleEndian(UInt32(0xd280_0808))
        text.appendLittleEndian(UInt32(0xd400_0001))
        text.appendLittleEndian(UInt32(0xd503_205f))
        text.appendLittleEndian(UInt32(0x17ff_ffff))
        text.append(contentsOf: [UInt8]("/dev/ttyAMA0\0".utf8))
        text.append(contentsOf: Data(repeating: 0, count: 3))
        text.append(contentsOf: [UInt8]("/dev/console\0".utf8))
        text.append(contentsOf: Data(repeating: 0, count: 3))
        text.append(contentsOf: Data("CONJET_INIT_READY\n".utf8))

        let loadOffset: UInt64 = 0x1000
        let loadAddress: UInt64 = 0x0040_0000
        var elf = Data()
        elf.append(contentsOf: [0x7f, 0x45, 0x4c, 0x46])
        elf.append(contentsOf: [0x02, 0x01, 0x01, 0x00])
        elf.append(contentsOf: Data(repeating: 0, count: 8))
        elf.appendLittleEndian(UInt16(2))
        elf.appendLittleEndian(UInt16(183))
        elf.appendLittleEndian(UInt32(1))
        elf.appendLittleEndian(loadAddress)
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
        elf.appendLittleEndian(loadOffset)
        elf.appendLittleEndian(loadAddress)
        elf.appendLittleEndian(loadAddress)
        elf.appendLittleEndian(UInt64(text.count))
        elf.appendLittleEndian(UInt64(text.count))
        elf.appendLittleEndian(UInt64(0x1000))

        if elf.count < Int(loadOffset) {
            elf.append(contentsOf: Data(repeating: 0, count: Int(loadOffset) - elf.count))
        }
        elf.append(text)
        return elf
    }

    private static func write(entry: InitramfsEntry, inode: UInt32, to handle: FileHandle) throws {
        let pathData = Data(entry.path.utf8) + Data([0])
        let fileSize = entry.kind == .regularFile || entry.kind == .symbolicLink ? UInt32(entry.data.count) : 0
        let linkCount: UInt32 = entry.kind == .directory ? 2 : 1
        let header = [
            "070701",
            hex(inode),
            hex(entry.mode),
            hex(0),
            hex(0),
            hex(linkCount),
            hex(0),
            hex(fileSize),
            hex(0),
            hex(0),
            hex(entry.kind == .characterDevice ? entry.major : 0),
            hex(entry.kind == .characterDevice ? entry.minor : 0),
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

    private static func readUInt16LE(
        _ data: Data,
        at offset: Int,
        sourceDescription: String
    ) throws -> UInt16 {
        try requireRange(data, offset: offset, byteCount: 2, sourceDescription: sourceDescription)
        return UInt16(data[offset])
            | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(
        _ data: Data,
        at offset: Int,
        sourceDescription: String
    ) throws -> UInt32 {
        try requireRange(data, offset: offset, byteCount: 4, sourceDescription: sourceDescription)
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LE(
        _ data: Data,
        at offset: Int,
        sourceDescription: String
    ) throws -> UInt64 {
        try requireRange(data, offset: offset, byteCount: 8, sourceDescription: sourceDescription)
        let byte0 = UInt64(data[offset])
        let byte1 = UInt64(data[offset + 1]) << 8
        let byte2 = UInt64(data[offset + 2]) << 16
        let byte3 = UInt64(data[offset + 3]) << 24
        let byte4 = UInt64(data[offset + 4]) << 32
        let byte5 = UInt64(data[offset + 5]) << 40
        let byte6 = UInt64(data[offset + 6]) << 48
        let byte7 = UInt64(data[offset + 7]) << 56
        return byte0 | byte1 | byte2 | byte3 | byte4 | byte5 | byte6 | byte7
    }

    private static func requireRange(
        _ data: Data,
        offset: Int,
        byteCount: Int,
        sourceDescription: String
    ) throws {
        guard offset >= 0,
              byteCount >= 0,
              offset <= data.count,
              byteCount <= data.count - offset else {
            throw ConjetError.unavailable("\(sourceDescription) ELF header is truncated")
        }
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

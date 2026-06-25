import ConjetCore
import ConjetVZ
import Foundation
import XCTest

final class GuestKernelConfigTests: XCTestCase {
    func testProductionMemoryReclaimCodeDoesNotReferenceUnsafePageOwnershipPaths() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let productionRoots = [
            "Sources",
            "guest/image/conjet-core/src",
            "guest/image/conjet-core/scripts",
            "jetstream/src"
        ]
        let forbiddenMarkers = [
            "/proc/kpageflags",
            "KPF_BUDDY",
            "/proc/iomem",
            "/proc/sys/vm/compact_memory",
            "MemoryControlRequest::ReclaimRanges",
            "ReclaimRanges",
            #""reclaim_ranges""#
        ]
        let sourceExtensions = Set(["swift", "c", "h", "rs", "sh", "py"])
        var violations: [String] = []

        for relativeRoot in productionRoots {
            let directory = root.appendingPathComponent(relativeRoot, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true,
                      sourceExtensions.contains(fileURL.pathExtension) else {
                    continue
                }
                var content = try String(contentsOf: fileURL, encoding: .utf8)
                if fileURL.pathExtension == "rs",
                   let testRange = content.range(of: "#[cfg(test)]") {
                    content = String(content[..<testRange.lowerBound])
                }
                for marker in forbiddenMarkers where content.contains(marker) {
                    violations.append("\(fileURL.path): \(marker)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Production dynamic-memory code must not reintroduce unsafe guest-page ownership paths:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testLinuxKernelBuilderDoesNotRequestSystemMapAsExplicitMakeTarget() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/scripts/build-linux.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertFalse(
            script.contains("Image vmlinux System.map"),
            "Linux 6.12 does not expose System.map as an explicit make target; build vmlinux and assert the side-effect file exists instead."
        )
        XCTAssertTrue(script.contains("Image vmlinux"))
        XCTAssertTrue(script.contains("kernel builder did not emit System.map"))
    }

    func testLinuxKernelBuilderUsesMinimalAllNoConfigByDefault() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/scripts/build-linux.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("kernel_base_config=\"${KERNEL_BASE_CONFIG:-allnoconfig}\""))
        XCTAssertTrue(script.contains("KCONFIG_ALLCONFIG=\"${config_fragment}\""))
        XCTAssertTrue(script.contains("allnoconfig"))
        XCTAssertTrue(script.contains("supported values: allnoconfig, minimal, defconfig"))
        XCTAssertTrue(script.contains("make_cmd=\"${MAKE:-make}\""))
        XCTAssertTrue(script.contains("host_cc=\"${HOSTCC:-gcc}\""))
        XCTAssertTrue(script.contains("GNU Make >= 4.0 is required"))
        XCTAssertTrue(script.contains("require_host_c_compiler"))
        XCTAssertTrue(script.contains("\"${make_cmd}\" -C \"${source_dir}\""))
        XCTAssertTrue(script.contains("ARCH=arm64 \\\n        ${make_flags} \\\n        KCONFIG_ALLCONFIG"))
        XCTAssertTrue(script.contains("\"${make_cmd}\" -C \"${source_dir}\" ARCH=arm64 ${make_flags} olddefconfig"))
        XCTAssertFalse(script.contains("MAKE_FLAGS:--j"))
    }

    func testLinuxKernelBuilderSupportsPulseFastProfile() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/scripts/build-linux.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let syntax = try ProcessRunner.run("/bin/bash", ["-n", scriptURL.path])
        XCTAssertTrue(syntax.succeeded, syntax.stderr)
        XCTAssertTrue(script.contains("kernel_profile=\"${KERNEL_PROFILE:-docker}\""))
        XCTAssertTrue(script.contains("conjet-fast-arm64.config"))
        XCTAssertTrue(script.contains("linux-${kernel_version}-conjet-fast-arm64"))
        XCTAssertTrue(script.contains("supported values: docker, debug, fast, pulse-fast"))
        XCTAssertTrue(script.contains(#""profile": "$(json_escape "${kernel_profile}")""#))
    }

    func testBusyBoxBuilderUsesDeterministicKconfigSeed() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/scripts/build-busybox.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertFalse(script.contains("/scripts/config"))
        XCTAssertTrue(script.contains("conjet-minimal-busybox.config"))
        XCTAssertTrue(script.contains("KCONFIG_ALLCONFIG=\"${minimal_config}\""))
        XCTAssertTrue(script.contains("allnoconfig"))
        XCTAssertTrue(script.contains("set_config_enabled"))
        XCTAssertTrue(script.contains("apply_minimal_config"))
        XCTAssertTrue(script.contains("BUSYBOX STATIC ASH"))
        XCTAssertTrue(script.contains("ASH_ECHO ASH_PRINTF ASH_TEST"))
        XCTAssertFalse(script.contains("FEATURE_INSTALLER"))
        XCTAssertTrue(script.contains("oldconfig_with_defaults"))
        XCTAssertTrue(script.contains("yes \"\" 2>/dev/null | make -C \"${source_dir}\""))
        XCTAssertFalse(script.contains("cat \"${minimal_config}\" >> \"${source_dir}/.config\""))
        XCTAssertFalse(script.contains(" olddefconfig"))
        XCTAssertFalse(script.contains("MAKE_FLAGS:--j"))
    }

    func testConjetInitSourceImplementsStaticPID1ControlPlaneContract() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/init/conjet-init.c")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("mount_if_needed(\"devtmpfs\", \"/dev\", \"devtmpfs\""))
        XCTAssertTrue(source.contains("mount_if_needed(\"proc\", \"/proc\", \"proc\""))
        XCTAssertTrue(source.contains("mount_if_needed(\"sysfs\", \"/sys\", \"sysfs\""))
        XCTAssertTrue(source.contains("socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0)"))
        XCTAssertTrue(source.contains("#define CONJET_READY_PORT 1029U"))
        XCTAssertTrue(source.contains("#define CONJET_FRAME_MAGIC 0x4356534fU"))
        XCTAssertTrue(source.contains("#define CONJET_READINESS_MAGIC 0x43524459U"))
        XCTAssertTrue(source.contains("#define CONJET_EVENT_CONTROL_READY 1U"))
        XCTAssertTrue(source.contains("#define CONJET_EVENT_PROCESS_STARTED 2U"))
        XCTAssertTrue(source.contains("send_readiness(CONJET_EVENT_CONTROL_READY, CONJET_STATUS_OK, 0)"))
        XCTAssertTrue(source.contains("send_readiness(CONJET_EVENT_PROCESS_STARTED, CONJET_STATUS_OK, 0)"))
        XCTAssertTrue(source.contains("waitpid(-1, &status, WNOHANG)"))
        XCTAssertTrue(source.contains("reboot(LINUX_REBOOT_CMD_POWER_OFF)"))
        XCTAssertTrue(source.contains("cmdline_value(\"conjet.argc=\")"))
        XCTAssertTrue(source.contains("\"conjet.arg%d=\""))
        XCTAssertTrue(source.contains("percent_decode(copy)"))
        XCTAssertTrue(source.contains("cmdline_value(\"conjet.exec=\")"))
        XCTAssertFalse(source.contains("system("))
        XCTAssertFalse(source.contains("popen("))
    }

    func testConjetInitBuilderRequiresStaticArm64LinuxOutput() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/init/build-conjet-init.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let syntax = try ProcessRunner.run("/bin/bash", ["-n", scriptURL.path])
        XCTAssertTrue(syntax.succeeded, syntax.stderr)
        XCTAssertTrue(script.contains("aarch64-linux-musl-gcc"))
        XCTAssertTrue(script.contains("aarch64-linux-gnu-gcc"))
        XCTAssertTrue(script.contains("-static"))
        XCTAssertTrue(script.contains("-fstack-protector-strong"))
        XCTAssertTrue(script.contains("\"schemaVersion\": 1"))
        XCTAssertTrue(script.contains("\"name\": \"conjet-init\""))
        XCTAssertTrue(script.contains("\"binarySha256\""))
        XCTAssertTrue(script.contains("\"statically linked\""))
    }

    func testCLIExposesValidatedConjetInitramfsPackagingMode() throws {
        let cliURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/ConjetCLI/main.swift")
        let cli = try String(contentsOf: cliURL, encoding: .utf8)

        XCTAssertTrue(cli.contains("value(after: \"--conjet-init\", in: args)"))
        XCTAssertTrue(cli.contains("InitramfsBuilder.buildConjetInit"))
        XCTAssertTrue(cli.contains("--conjet-init PATH|--init PATH|--conjet-ready-probe"))
    }

    func testCLIDirectKernelConjetCoreImportsUseReleaseKernelCommandLineFallback() throws {
        let cliURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/ConjetCLI/main.swift")
        let cli = try String(contentsOf: cliURL, encoding: .utf8)

        XCTAssertTrue(cli.contains("conjetCoreReleaseKernelCommandLine"))
        XCTAssertTrue(cli.contains("\"systemd.unit=conjet-appliance.target\""))
        XCTAssertTrue(cli.contains("?? conjetCoreKernelCommandLine(forArtifactPath: artifact)"))
        XCTAssertTrue(cli.contains("kernelCommandLine: conjetCoreKernelCommandLine(forArtifactPath: artifact)"))
        XCTAssertTrue(cli.contains("recommendedKernelCommandLine(forArtifactPath: path) ?? conjetCoreReleaseKernelCommandLine"))
        XCTAssertTrue(cli.contains("validateConjetCoreDirectKernelImageMetadata"))
        XCTAssertTrue(cli.contains("systemdDefaultTarget"))
        XCTAssertTrue(cli.contains("does not declare conjet-appliance.target"))
    }

    func testCLIUpdateUsesDirectKernelImportForHVFBackend() throws {
        let cliURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/ConjetCLI/main.swift")
        let cli = try String(contentsOf: cliURL, encoding: .utf8)

        XCTAssertTrue(cli.contains("private static func update(args: [String] = [], json: Bool = false) throws"))
        XCTAssertTrue(cli.contains("if config.vmBackend == .hvfExperimental"))
        XCTAssertTrue(cli.contains("cliValue: value(after: \"--kernel\", in: updateArgs)"))
        XCTAssertTrue(cli.contains("manifest = try store.importDirectKernelRootDisk"))
        XCTAssertTrue(cli.contains("rootDiskPath: artifact"))
        XCTAssertTrue(cli.contains("kernelCommandLine: value(after: \"--cmdline\", in: updateArgs)"))
        XCTAssertTrue(cli.contains("dataDiskSizeBytes: gibibytes(config.diskGiB)"))
        XCTAssertTrue(cli.contains("try store.ensureDataDiskIfNeeded(sizeBytes: gibibytes(config.diskGiB))"))
        XCTAssertTrue(cli.contains("manifest = try store.importEFIBootDisk"))
        XCTAssertTrue(cli.contains("\"--image\", \"--url\", \"--repository\", \"--boot-disk-gb\", \"--kernel\", \"--cmdline\""))
    }

    func testCLIDirectKernelConjetCoreDownloadsAndValidatesKernelMetadata() throws {
        let cliURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/ConjetCLI/main.swift")
        let cli = try String(contentsOf: cliURL, encoding: .utf8)

        XCTAssertTrue(cli.contains("downloadRequiredConjetCoreMetadata"))
        XCTAssertTrue(cli.contains("validateConjetCoreKernelMetadata"))
        XCTAssertTrue(cli.contains("VMImageStore.dockerDirectKernelRequiredBuiltIns"))
        XCTAssertTrue(cli.contains("cacheName: \"\\(artifact.releaseTag)-\\(artifact.name).json\""))
        XCTAssertTrue(cli.contains("missing built-ins"))
    }

    func testPhase9WorkflowInstallsBusyBoxTarballPrerequisite() throws {
        let workflowURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".github/workflows/jetstream-kernel-assets.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)

        XCTAssertTrue(workflow.contains("bzip2"))
    }

    func testPhase9BundleBuilderCapturesOnlyFinalBuilderArtifactPath() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/scripts/build-phase9-network-proof-assets.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("run_builder_and_capture_path"))
        XCTAssertTrue(script.contains("tee \"${log_path}\" >&2"))
        XCTAssertTrue(script.contains("phase9_linux_out_dir=\"${phase9_work_dir}/linux\""))
        XCTAssertTrue(script.contains("phase9_busybox_out_dir=\"${phase9_work_dir}/busybox\""))
        XCTAssertTrue(script.contains("kernel_image=\"$(run_builder_and_capture_path build-linux env OUT_DIR=\"${phase9_linux_out_dir}\""))
        XCTAssertTrue(script.contains("busybox_bin=\"$(run_builder_and_capture_path build-busybox env OUT_DIR=\"${phase9_busybox_out_dir}\""))
        XCTAssertFalse(script.contains("kernel_image=\"$(\"${scripts_dir}/build-linux.sh\")\""))
        XCTAssertFalse(script.contains("busybox_bin=\"$(\"${scripts_dir}/build-busybox.sh\")\""))
    }

    func testPhase9BundleBuilderPreservesOnlyFinalManifestOnStdoutWithNoisyBuilders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-phase9-builder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let builders = root.appendingPathComponent("builders", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: builders, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let linux = builders.appendingPathComponent("linux-builder.sh")
        let busybox = builders.appendingPathComponent("busybox-builder.sh")
        let initramfs = builders.appendingPathComponent("initramfs-builder.sh")
        let verifier = builders.appendingPathComponent("verifier.sh")
        try writeExecutableScript(linux, contents: """
        #!/usr/bin/env bash
        set -euo pipefail
        out="${FAKE_ASSET_ROOT}/linux"
        mkdir -p "${out}"
        if [ "${1:-}" = "--check-tools" ]; then
          echo "linux prerequisites ok"
          exit 0
        fi
        echo "linux build noise line"
        echo "linux build still running"
        printf 'kernel-image\\n' > "${out}/Image"
        printf '{"schemaVersion":1}\\n' > "${out}/manifest.json"
        printf '%s\\n' "${out}/Image"
        """)
        try writeExecutableScript(busybox, contents: """
        #!/usr/bin/env bash
        set -euo pipefail
        out="${FAKE_ASSET_ROOT}/busybox"
        mkdir -p "${out}"
        if [ "${1:-}" = "--check-tools" ]; then
          echo "busybox prerequisites ok"
          exit 0
        fi
        echo "busybox build noise line"
        printf 'busybox-binary\\n' > "${out}/busybox"
        printf '%s\\n' "${out}/busybox"
        """)
        try writeExecutableScript(initramfs, contents: """
        #!/usr/bin/env bash
        set -euo pipefail
        if [ "${1:-}" = "--check-tools" ]; then
          echo "initramfs prerequisites ok"
          exit 0
        fi
        output=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output)
              output="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        if [ -z "${output}" ]; then
          echo "missing --output" >&2
          exit 64
        fi
        mkdir -p "$(dirname "${output}")"
        printf 'initramfs\\n' > "${output}"
        printf '{"output":"%s"}\\n' "${output}"
        """)
        try writeExecutableScript(verifier, contents: """
        #!/usr/bin/env bash
        set -euo pipefail
        if [ "${1:-}" = "--check-tools" ]; then
          echo "verifier prerequisites ok"
          exit 0
        fi
        if [ "${1:-}" = "--manifest" ] && [ -f "${2:-}" ]; then
          echo "bundle ok"
          exit 0
        fi
        echo "missing manifest" >&2
        exit 65
        """)

        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/scripts/build-phase9-network-proof-assets.sh")
        let result = try ProcessRunner.run("/usr/bin/env", [
            "FAKE_ASSET_ROOT=\(assets.path)",
            "CONJET_PHASE9_LINUX_BUILDER=\(linux.path)",
            "CONJET_PHASE9_BUSYBOX_BUILDER=\(busybox.path)",
            "CONJET_PHASE9_INITRAMFS_BUILDER=\(initramfs.path)",
            "CONJET_PHASE9_BUNDLE_VERIFIER=\(verifier.path)",
            "/bin/bash",
            script.path,
            "--output-dir",
            bundle.path,
            "--proof-url",
            "http://example.com",
            "--guest-service-port",
            "8080"
        ])

        let expectedManifest = bundle.appendingPathComponent("phase9-network-proof-assets.json").path
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), expectedManifest)
        XCTAssertFalse(result.stdout.contains("linux build noise line"))
        XCTAssertFalse(result.stdout.contains("busybox build noise line"))
        XCTAssertTrue(result.stderr.contains("linux build noise line"))
        XCTAssertTrue(result.stderr.contains("busybox build noise line"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedManifest))
    }

    func testConjetARM64KernelConfigKeepsDirectKernelAndContainerNetworkingRequirements() throws {
        let configURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/config/conjet-arm64.config")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let importerBuiltIns = Set(VMImageStore.requiredJetstreamKernelBuiltIns)
        let configBuiltIns = Set(
            config
                .split(separator: "\n")
                .map(String.init)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("CONFIG_"), trimmed.hasSuffix("=y") else { return nil }
                    return String(trimmed.dropLast(2))
                }
        )

        XCTAssertTrue(configBuiltIns.contains("CONFIG_OVERLAY_FS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BLK_DEV"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_PCI"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_PCI_HOST_GENERIC"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NVME_CORE"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BLK_DEV_NVME"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_EFI_PARTITION"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_MSDOS_PARTITION"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_EXT4_FS_POSIX_ACL"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_EXT4_FS_SECURITY"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_MISC_FILESYSTEMS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_HUGETLBFS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NLS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NLS_CODEPAGE_437"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NLS_ISO8859_1"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_VIRTIO_FS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_VIRTIO_BALLOON"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_PAGE_REPORTING"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_SYSVIPC"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_MEMCG"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_CGROUP_CPUACCT"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_PERF_EVENTS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_CFS_BANDWIDTH"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BLK_DEV_THROTTLING"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BPF_SYSCALL"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BPF_JIT"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_CGROUP_BPF"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_CGROUP_HUGETLB"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_CGROUP_PERF"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_CGROUP_NET_CLASSID"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_CGROUP_NET_PRIO"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_SECURITY"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_SECURITYFS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_SECURITY_APPARMOR"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_SECURITY_SELINUX"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_IKCONFIG_PROC"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_COMPACTION"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BALLOON_COMPACTION"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_PSI"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_ZRAM_WRITEBACK"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NET_SCHED"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NET_CLS_ACT"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NET_CLS_BPF"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NET_ACT_BPF"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NETDEVICES"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NET_CORE"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_IP_SCTP"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_VETH"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_VXLAN"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_VLAN_8021Q"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_MACVLAN"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_IPVLAN"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_DUMMY"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BRIDGE_VLAN_FILTERING"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NF_TABLES_IPV4"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NF_TABLES_IPV6"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NFT_NAT"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NFT_MASQ"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NETFILTER_XT_MATCH_IPVS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_NETFILTER_XT_MARK"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_IP_SET"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_IP_VS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_CRYPTO_GCM"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_INET_ESP"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BTRFS_FS"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BINFMT_ELF"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BINFMT_SCRIPT"))
        XCTAssertTrue(configBuiltIns.contains("CONFIG_BINFMT_MISC"))
        XCTAssertFalse(configBuiltIns.contains("CONFIG_MEMCG_SWAP"))

        XCTAssertTrue(
            importerBuiltIns.isSubset(of: configBuiltIns),
            "VMImageStore.requiredJetstreamKernelBuiltIns must remain a subset of guest/kernel/config/conjet-arm64.config"
        )

        let dockerDirectBuiltIns = Set(VMImageStore.dockerDirectKernelRequiredBuiltIns)
        XCTAssertEqual(importerBuiltIns, dockerDirectBuiltIns)
        XCTAssertTrue(dockerDirectBuiltIns.isSubset(of: configBuiltIns))
        XCTAssertTrue(dockerDirectBuiltIns.contains("CONFIG_NFT_MASQ"))
        XCTAssertTrue(dockerDirectBuiltIns.contains("CONFIG_NFT_NAT"))
        XCTAssertTrue(dockerDirectBuiltIns.contains("CONFIG_NF_TABLES_INET"))
        XCTAssertTrue(dockerDirectBuiltIns.contains("CONFIG_SYSVIPC"))
        XCTAssertTrue(dockerDirectBuiltIns.contains("CONFIG_VETH"))
        XCTAssertTrue(dockerDirectBuiltIns.contains("CONFIG_BRIDGE_NETFILTER"))
        XCTAssertTrue(dockerDirectBuiltIns.contains("CONFIG_CGROUP_BPF"))
    }

    func testPulseFastKernelConfigKeepsDirectOCISubstrateWithoutSerialOrDockerBulk() throws {
        let configURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/config/conjet-fast-arm64.config")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let configBuiltIns = Set(
            config
                .split(separator: "\n")
                .map(String.init)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("CONFIG_"), trimmed.hasSuffix("=y") else { return nil }
                    return String(trimmed.dropLast(2))
                }
        )

        for required in [
            "CONFIG_OF",
            "CONFIG_BLK_DEV_INITRD",
            "CONFIG_DEVTMPFS",
            "CONFIG_VIRTIO_MMIO",
            "CONFIG_VIRTIO_BLK",
            "CONFIG_VIRTIO_NET",
            "CONFIG_VIRTIO_BALLOON",
            "CONFIG_PAGE_REPORTING",
            "CONFIG_VIRTIO_VSOCKETS",
            "CONFIG_VSOCKETS",
            "CONFIG_EXT4_FS",
            "CONFIG_OVERLAY_FS",
            "CONFIG_PROC_FS",
            "CONFIG_SYSFS",
            "CONFIG_NAMESPACES",
            "CONFIG_SYSVIPC",
            "CONFIG_PID_NS",
            "CONFIG_NET_NS",
            "CONFIG_CGROUPS",
            "CONFIG_MEMCG",
            "CONFIG_COMPACTION",
            "CONFIG_BALLOON_COMPACTION",
            "CONFIG_PSI",
            "CONFIG_SWAP",
            "CONFIG_ZSMALLOC",
            "CONFIG_ZRAM",
            "CONFIG_SECCOMP_FILTER",
            "CONFIG_BINFMT_ELF",
            "CONFIG_NET",
            "CONFIG_INET",
            "CONFIG_UNIX"
        ] {
            XCTAssertTrue(configBuiltIns.contains(required), "missing \(required)")
        }

        XCTAssertFalse(configBuiltIns.contains("CONFIG_SERIAL_AMBA_PL011"))
        XCTAssertFalse(configBuiltIns.contains("CONFIG_SERIAL_AMBA_PL011_CONSOLE"))
        XCTAssertFalse(configBuiltIns.contains("CONFIG_BRIDGE"))
        XCTAssertFalse(configBuiltIns.contains("CONFIG_NETFILTER"))
        XCTAssertFalse(configBuiltIns.contains("CONFIG_NF_TABLES"))
        XCTAssertFalse(configBuiltIns.contains("CONFIG_BINFMT_MISC"))
    }

    func testConjetCoreImageScriptInstallsHVFReadinessMarkerUnit() throws {
        let imageScriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/image/conjet-core/scripts/image.sh")
        let imageScript = try String(contentsOf: imageScriptURL, encoding: .utf8)

        let syntax = try ProcessRunner.run("/bin/bash", ["-n", imageScriptURL.path])
        XCTAssertTrue(syntax.succeeded, syntax.stderr)
        XCTAssertTrue(imageScript.contains("/usr/local/sbin/conjet-init-ready.sh"))
        XCTAssertTrue(imageScript.contains("CONJET_CONTROL_READY runtime=%s docker_vsock_ready=%s docker_api_ready=%s"))
        XCTAssertTrue(imageScript.contains("CONJET_INIT_READY runtime=%s docker_vsock_ready=%s"))
        XCTAssertTrue(imageScript.contains("conjet-netd --send-readiness control-ready"))
        XCTAssertTrue(imageScript.contains("conjet-netd --send-readiness process-started"))
        XCTAssertTrue(imageScript.contains("CONJET_DOCKER_READY runtime=%s docker_vsock_ready=%s docker_api_ready=yes"))
        XCTAssertTrue(imageScript.contains("while [ ! -e /run/conjet/docker-vsock-ready ]; do"))
        XCTAssertFalse(imageScript.contains("while ! curl --fail --silent --show-error --unix-socket /var/run/docker.sock http://localhost/_ping"))
        XCTAssertTrue(imageScript.contains("cat /run/conjet/control-ready >/dev/console"))
        XCTAssertTrue(imageScript.contains("cat /run/conjet/init-ready >/dev/console"))
        XCTAssertTrue(imageScript.contains("systemctl is-active --quiet docker.service"))
        XCTAssertTrue(imageScript.contains("curl --fail --silent --show-error --max-time 0.5 --unix-socket /var/run/docker.sock http://localhost/_ping"))
        XCTAssertTrue(imageScript.contains("docker_api_ready=yes"))
        XCTAssertTrue(imageScript.contains("Slice=conjet-daemons.slice"))
        XCTAssertTrue(imageScript.contains("conjet-build.slice"))
        XCTAssertTrue(imageScript.contains("enable_unit conjet-build.slice conjet-appliance.target"))
        XCTAssertTrue(imageScript.contains("enable_unit conjet-services.slice conjet-appliance.target"))
        XCTAssertTrue(imageScript.contains(#""cgroup-parent": "/conjet.slice/conjet-build.slice""#))
        XCTAssertTrue(imageScript.contains(#""buildkit": true"#))
        XCTAssertFalse(imageScript.contains("buildkit-${BUILDKIT_VERSION}.linux-${buildkit_arch}.tar.gz"))
        XCTAssertFalse(imageScript.contains("bin/buildkitd"))
        XCTAssertFalse(imageScript.contains("bin/buildctl"))
        XCTAssertFalse(imageScript.contains("enable_unit buildkit.socket sockets.target"))
        XCTAssertFalse(imageScript.contains("enable_unit buildkit.service conjet-appliance.target"))
        XCTAssertTrue(imageScript.contains("MemoryLow=512M"))
        XCTAssertTrue(imageScript.contains("CONJET_DOCKER_REPAIR_ON_BOOT:-0"))
        XCTAssertTrue(imageScript.contains("conjet-init-ready.service"))
        XCTAssertTrue(imageScript.contains("After=conjet-docker-vsock.service"))
        XCTAssertTrue(imageScript.contains("Wants=conjet-docker-vsock.service"))
        XCTAssertFalse(imageScript.contains("conjet-data-disk.service"))
        XCTAssertFalse(imageScript.contains("After=systemd-modules-load.service"))
        XCTAssertFalse(imageScript.contains("cat >\"${MOUNT_DIR}/etc/modules-load.d/conjet-vsock.conf\""))
        XCTAssertTrue(imageScript.contains("rm -f \"${MOUNT_DIR}/etc/modules-load.d/conjet-vsock.conf\""))
        XCTAssertTrue(imageScript.contains("mask_unit \"${unit}\""))
        XCTAssertTrue(imageScript.contains("systemd-modules-load.service"))
        XCTAssertTrue(imageScript.contains("modprobe@loop.service"))
        XCTAssertTrue(imageScript.contains("setvtrgb.service"))
        XCTAssertTrue(imageScript.contains("conjet-appliance.target"))
        XCTAssertTrue(imageScript.contains("ln -sf /etc/systemd/system/conjet-appliance.target"))
        XCTAssertTrue(imageScript.contains("enable_unit conjet-init-ready.service conjet-appliance.target"))
        XCTAssertFalse(imageScript.contains("enable_unit conjet-boot-diagnostics.service conjet-appliance.target"))
        XCTAssertTrue(imageScript.contains(#""systemdDefaultTarget": "conjet-appliance.target""#))
        XCTAssertTrue(imageScript.contains("systemd.unit=conjet-appliance.target"))
        XCTAssertTrue(imageScript.contains("$2 == \"/boot\" || $2 == \"/boot/\" || $2 == \"/boot/efi\" || $2 == \"/boot/efi/\""))
        XCTAssertTrue(imageScript.contains("sha512sum \"$(basename \"${OUT_IMAGE}\")\""))
    }

    func testConjetCoreReleaseWorkflowPublishesOnlyJetstreamLinuxKernelAsset() throws {
        let workflowURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".github/workflows/conjet-core-image.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)

        XCTAssertTrue(workflow.contains("name: Jetstream Linux Kernel Release"))
        XCTAssertTrue(workflow.contains("Build Jetstream Linux kernel asset"))
        XCTAssertTrue(workflow.contains("kernel_version:"))
        XCTAssertTrue(workflow.contains("guest/kernel/scripts/build-linux.sh"))
        XCTAssertTrue(workflow.contains("conjet-linux-${KERNEL_VERSION}-aarch64-Image"))
        XCTAssertTrue(workflow.contains("sha512sum \"$(basename \"${kernel_asset}\")\" > \"$(basename \"${kernel_asset}\").sha512sum\""))
        XCTAssertTrue(workflow.contains("guest/kernel/dist/out/conjet-linux-*-aarch64-Image"))
        XCTAssertTrue(workflow.contains("guest/kernel/dist/out/conjet-linux-*-aarch64-Image.sha512sum"))
        XCTAssertTrue(workflow.contains("guest/kernel/dist/out/conjet-linux-*-aarch64-Image.json"))
        XCTAssertFalse(workflow.contains("root_disk_gb:"))
        XCTAssertFalse(workflow.contains("Build Conjet Core image"))
        XCTAssertFalse(workflow.contains("make -C guest/image/conjet-core image"))
        XCTAssertFalse(workflow.contains("*.raw.gz"))
    }

    func testConjetCoreReleaseNotesDeclareKernelOnlyHVFBackendPolicy() throws {
        let workflowURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".github/workflows/conjet-core-image.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)

        XCTAssertTrue(workflow.contains("Jetstream Linux Kernel v${{ needs.meta.outputs.version }}"))
        XCTAssertTrue(workflow.contains("Jetstream HVF direct-kernel uses only this custom Linux kernel asset."))
    }

    func testLocalConjetCoreReleaseRehearsalRunsWorkflowCommandsInContainer() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build-support/run-conjet-core-release-local.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let syntax = try ProcessRunner.run("/bin/bash", ["-n", scriptURL.path])
        XCTAssertTrue(syntax.succeeded, syntax.stderr)
        XCTAssertTrue(script.contains("CONJET_QA_ROOT_BASE:-/tmp"))
        XCTAssertTrue(script.contains("mktemp -d \"${qa_root_base%/}/conjet-core-release-local.XXXXXX\""))
        XCTAssertTrue(script.contains("--rootfs-only"))
        XCTAssertTrue(script.contains("ROOTFS_ONLY=\"${rootfs_only}\""))
        XCTAssertTrue(script.contains("docker --host \"${docker_host}\" run --rm --privileged"))
        XCTAssertTrue(script.contains("--ulimit nofile=65536:65536"))
        XCTAssertTrue(script.contains("--platform \"${container_platform}\""))
        XCTAssertTrue(script.contains("guest/kernel/scripts/build-linux.sh"))
        XCTAssertTrue(script.contains("conjet-linux-${KERNEL_VERSION}-aarch64-Image"))
        XCTAssertTrue(script.contains("sha512sum \"$(basename \"${kernel_asset}\")\" > \"$(basename \"${kernel_asset}\").sha512sum\""))
        XCTAssertTrue(script.contains("ARTIFACT_DIR=\"${artifact_dir}\""))
    }

    func testPhase9OfflineVerifierRequiresFullDockerKernelConfigBuiltIns() throws {
        let verifierURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/scripts/verify-phase9-network-proof-assets.pl")
        let verifier = try String(contentsOf: verifierURL, encoding: .utf8)
        let configURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("guest/kernel/config/conjet-arm64.config")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let startMarker = "my @required_kernel_builtins = qw("
        let endMarker = ");"
        guard let start = verifier.range(of: startMarker),
              let end = verifier[start.upperBound...].range(of: endMarker) else {
            return XCTFail("Could not find the verifier required kernel built-ins block")
        }

        let verifierBuiltIns = Set(
            verifier[start.upperBound..<end.lowerBound]
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
        )
        let configBuiltIns = Set(
            config
                .split(separator: "\n")
                .map(String.init)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("CONFIG_"), trimmed.hasSuffix("=y") else { return nil }
                    return String(trimmed.dropLast(2))
                }
        )

        XCTAssertEqual(
            verifierBuiltIns,
            configBuiltIns,
            "Phase 9 Linux-side verifier stays aligned with the full Docker kernel config, while the macOS importer may accept a released-kernel subset."
        )
    }

    private func writeExecutableScript(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

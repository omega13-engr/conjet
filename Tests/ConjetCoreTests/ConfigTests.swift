import ConjetCore
import XCTest

final class ConfigTests: XCTestCase {
    func testConfigRoundTrip() throws {
        let config = ConjetConfig(
            vmCPUs: 6,
            memoryMiB: 8192,
            vmProfile: .pulseFast,
            architecture: "x86_64",
            diskGiB: 120,
            diskImagePath: "/tmp/custom.raw.gz",
            kernelImagePath: "/tmp/Image",
            runtime: "docker",
            quietStopMinutes: 12,
            enableRosetta: false,
            enableHostMounts: false,
            enableRemovableHostMounts: true,
            socketPath: "/tmp/conjet.sock",
            conjetCoreRepository: "omega13-engr/conjet",
            energyMode: .eco,
            memoryProfile: .eco,
            ssh: ConjetSSHPolicy(enabled: false, transport: "proxy-command", allowTCPFallback: false)
        )
        let parsed = try ConjetConfig.parseTOML(config.renderTOML())
        XCTAssertEqual(parsed, config)
    }

    func testInvalidMemoryIsRejected() throws {
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[vm]\nmemory_mib = 128\n"))
    }

    func testInvalidConjetCoreRepositoryIsRejected() throws {
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[images]\nconjet_core_repository = \"not-a-repo\"\n"))
    }

    func testDefaultProfileConfigurationMatchesProductionDefaults() throws {
        let config = ConjetConfig.default

        XCTAssertEqual(config.vmCPUs, 2)
        XCTAssertEqual(config.memoryMiB, 4096)
        XCTAssertEqual(config.vmProfile, .dockerCompatibility)
        XCTAssertEqual(config.effectiveVMCPUs, 2)
        XCTAssertEqual(config.effectiveMemoryMiB, 4096)
        XCTAssertEqual(config.architecture, "aarch64")
        XCTAssertEqual(config.diskGiB, 100)
        XCTAssertNil(config.diskImagePath)
        XCTAssertNil(config.kernelImagePath)
        XCTAssertEqual(config.runtime, "docker")
        XCTAssertEqual(config.vmBackend, .hvfExperimental)
        XCTAssertEqual(config.energyMode, .balanced)
        XCTAssertEqual(config.memoryProfile, .noPolicy)
        XCTAssertEqual(config.networkBridgeEngine, .conjetNetdC)
        XCTAssertTrue(config.ssh.enabled)
        XCTAssertEqual(config.ssh.transport, "proxy-command")
        XCTAssertTrue(config.enableHostMounts)
        XCTAssertFalse(config.enableRemovableHostMounts)
    }

    func testProfileMemoryBoundsConstrainSixteenGiBHostsToEightGiB() throws {
        let constrained = ConjetProfileMemoryBounds(hostMemoryMiB: 16_384)

        XCTAssertEqual(constrained.minimumMiB, 2048)
        XCTAssertEqual(constrained.maximumMiB, 8192)
        XCTAssertEqual(constrained.minimumGiB, 2)
        XCTAssertEqual(constrained.maximumGiB, 8)
        XCTAssertTrue(constrained.isMaximumConstrainedByHost)
        XCTAssertEqual(constrained.clampedMiB(16_384), 8192)
        XCTAssertEqual(constrained.clampedMiB(1024), 2048)

        let roomy = ConjetProfileMemoryBounds(hostMemoryMiB: 32_768)

        XCTAssertEqual(roomy.maximumMiB, 16_384)
        XCTAssertEqual(roomy.maximumGiB, 16)
        XCTAssertFalse(roomy.isMaximumConstrainedByHost)
        XCTAssertEqual(roomy.clampedMiB(12_288), 12_288)
    }

    func testEnergyModeIsValidated() throws {
        let parsed = try ConjetConfig.parseTOML("[daemon]\nenergy_mode = \"performance\"\n")
        XCTAssertEqual(parsed.energyMode, .performance)
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[daemon]\nenergy_mode = \"turbo\"\n"))
    }

    func testVMBackendIsValidatedAndRendered() throws {
        let parsed = try ConjetConfig.parseTOML("[vm]\nbackend = \"hvf\"\n")

        XCTAssertEqual(parsed.vmBackend, .hvfExperimental)
        XCTAssertTrue(parsed.renderTOML().contains("backend = \"hvf-experimental\""))
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[vm]\nbackend = \"private-vmm\"\n"))
    }

    func testContainerRuntimeIsValidatedNormalizedAndRendered() throws {
        let direct = try ConjetConfig.parseTOML("[vm]\nruntime = \"direct-oci\"\n")

        XCTAssertEqual(direct.runtime, "oci-direct")
        XCTAssertEqual(direct.containerRuntime, .ociDirect)
        XCTAssertEqual(try direct.validatedContainerRuntime(), .ociDirect)
        XCTAssertTrue(direct.renderTOML().contains("runtime = \"oci-direct\""))

        let docker = try ConjetConfig.parseTOML("[vm]\nruntime = \"docker\"\n")
        XCTAssertEqual(docker.runtime, "docker")
        XCTAssertEqual(docker.containerRuntime, .docker)
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[vm]\nruntime = \"containerd\"\n"))
    }

    func testVMProfileIsValidatedRenderedAndReportsEffectiveResources() throws {
        let parsed = try ConjetConfig.parseTOML("[vm]\nprofile = \"pulse-fast\"\ncpus = 8\nmemory_mib = 8192\n")

        XCTAssertEqual(parsed.vmProfile, .pulseFast)
        XCTAssertEqual(parsed.vmCPUs, 8)
        XCTAssertEqual(parsed.memoryMiB, 8192)
        XCTAssertEqual(parsed.effectiveVMCPUs, 1)
        XCTAssertEqual(parsed.effectiveMemoryMiB, 512)
        XCTAssertFalse(parsed.shouldAdvertiseBalloonDevice)
        XCTAssertTrue(parsed.renderTOML().contains("profile = \"pulse-fast\""))
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[vm]\nprofile = \"full-send\"\n"))
    }

    func testVMBackendSelectionStatusReportsRestartAndHVFStartSupport() throws {
        let pending = ConjetVMBackendSelectionStatus(selected: .hvfExperimental, active: .vz)

        XCTAssertEqual(pending.effective, .vz)
        XCTAssertTrue(pending.requiresCoreRestart)
        XCTAssertTrue(pending.startSupported)
        XCTAssertTrue(pending.appleVirtualMachineServiceExpected)

        let activeHVF = ConjetVMBackendSelectionStatus(selected: .hvfExperimental, active: .hvfExperimental)

        XCTAssertFalse(activeHVF.requiresCoreRestart)
        XCTAssertTrue(activeHVF.startSupported)
        XCTAssertFalse(activeHVF.appleVirtualMachineServiceExpected)
        XCTAssertEqual(activeHVF.performanceLane, "jetstream")
        XCTAssertEqual(activeHVF.selected.displayName, "Jetstream HVF primary")
        XCTAssertTrue(activeHVF.message.contains("Direct-kernel guest start is available"))

        let activeVZ = ConjetVMBackendSelectionStatus(selected: .vz, active: .vz)

        XCTAssertEqual(activeVZ.selected.displayName, "VZ Rosetta fallback")
        XCTAssertEqual(activeVZ.performanceLane, "compatibility")
        XCTAssertTrue(activeVZ.appleVirtualMachineServiceExpected)
        XCTAssertTrue(activeVZ.message.contains("Rosetta"))
    }

    func testNoPolicyMemoryProfileIsDefaultAndProducesDemandPolicy() throws {
        let parsed = try ConjetConfig.parseTOML("[vm]\nmemory_profile = \"no-policy\"\nmemory_mib = 8192\n")
        XCTAssertEqual(parsed.memoryProfile, .noPolicy)
        XCTAssertEqual(parsed.memoryPolicy.recommendedMemoryMiB, 8192)
        XCTAssertFalse(parsed.memoryPolicy.lazyRuntimeServices)
        XCTAssertTrue(parsed.memoryPolicy.lazyNetworkHelpers)
        XCTAssertTrue(parsed.memoryPolicy.automaticIdleMemoryReclaim)
        XCTAssertEqual(parsed.memoryPolicy.idleMemoryReclaimTargetMiB, 8192)
        XCTAssertTrue(parsed.memoryPolicy.dynamicMemoryEnabled)
        XCTAssertEqual(parsed.memoryPolicy.dynamicMemoryMinimumMiB, 512)
        XCTAssertEqual(parsed.memoryPolicy.dynamicMemoryShrinkCooldownSeconds, 0)
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[vm]\nmemory_profile = \"tiny\"\n"))
    }

    func testLegacyMemoryProfilesUseSameDemandPolicy() throws {
        let noPolicy = ConjetConfig(memoryMiB: 8192, memoryProfile: .noPolicy).memoryPolicy
        let policy = ConjetConfig(memoryMiB: 8192, memoryProfile: .balanced).memoryPolicy

        XCTAssertTrue(policy.automaticIdleMemoryReclaim)
        XCTAssertEqual(policy.idleMemoryReclaimTargetMiB, 8192)
        XCTAssertEqual(policy.reclaimIdleHelpersAfterSeconds, 0)
        XCTAssertEqual(policy.idleMemoryReclaimDwellSeconds, 0)
        XCTAssertTrue(policy.dynamicMemoryEnabled)
        XCTAssertEqual(policy.dynamicMemoryMinimumMiB, noPolicy.dynamicMemoryMinimumMiB)
        XCTAssertEqual(policy.dynamicMemoryHeadroomMiB, noPolicy.dynamicMemoryHeadroomMiB)
        XCTAssertEqual(policy.dynamicMemoryCacheAllowanceMiB, noPolicy.dynamicMemoryCacheAllowanceMiB)
        XCTAssertEqual(policy.dynamicMemoryShrinkCooldownSeconds, noPolicy.dynamicMemoryShrinkCooldownSeconds)
        XCTAssertEqual(ConjetConfig(memoryMiB: 8192, memoryProfile: .performance).memoryPolicy.dynamicMemoryMinimumMiB, noPolicy.dynamicMemoryMinimumMiB)
        XCTAssertEqual(ConjetConfig(memoryMiB: 8192, memoryProfile: .eco).memoryPolicy.dynamicMemoryMinimumMiB, noPolicy.dynamicMemoryMinimumMiB)
    }

    func testDynamicMemoryPolicyScalesWithConfiguredMemory() throws {
        let compact = ConjetConfig(memoryMiB: 4096, memoryProfile: .noPolicy).memoryPolicy
        XCTAssertEqual(compact.idleMemoryReclaimTargetMiB, 4096)
        XCTAssertEqual(compact.dynamicMemoryMinimumMiB, 512)
        XCTAssertEqual(compact.dynamicMemoryBaseOverheadMiB, 0)
        XCTAssertEqual(compact.dynamicMemoryHeadroomMiB, 128)
        XCTAssertEqual(compact.dynamicMemoryCacheAllowanceMiB, 128)
        XCTAssertEqual(compact.dynamicMemoryShrinkCooldownSeconds, 0)
        XCTAssertEqual(compact.dynamicMemoryShrinkStepMiB, 4096)

        let defaultSized = ConjetConfig(memoryMiB: 8192, memoryProfile: .noPolicy).memoryPolicy
        XCTAssertEqual(defaultSized.dynamicMemoryMinimumMiB, 512)
        XCTAssertEqual(defaultSized.dynamicMemoryBaseOverheadMiB, 0)
        XCTAssertEqual(defaultSized.dynamicMemoryHeadroomMiB, 128)
        XCTAssertEqual(defaultSized.dynamicMemoryCacheAllowanceMiB, 128)
        XCTAssertEqual(defaultSized.dynamicMemoryShrinkCooldownSeconds, 0)
        XCTAssertEqual(defaultSized.dynamicMemoryShrinkStepMiB, 8192)

        let large = ConjetConfig(memoryMiB: 16_384, memoryProfile: .noPolicy).memoryPolicy
        XCTAssertEqual(large.idleMemoryReclaimTargetMiB, 16_384)
        XCTAssertEqual(large.dynamicMemoryMinimumMiB, 512)
        XCTAssertEqual(large.dynamicMemoryBaseOverheadMiB, 0)
        XCTAssertEqual(large.dynamicMemoryHeadroomMiB, 128)
        XCTAssertEqual(large.dynamicMemoryCacheAllowanceMiB, 128)
        XCTAssertEqual(large.dynamicMemoryShrinkCooldownSeconds, 0)
        XCTAssertEqual(large.dynamicMemoryShrinkStepMiB, 16_384)
    }

    func testMemorySizeParserUsesMiBForBareNumbersAndSupportsUnits() throws {
        XCTAssertEqual(try ConjetConfig.parseMemorySizeMiB("4096"), 4096)
        XCTAssertEqual(try ConjetConfig.parseMemorySizeMiB("4096M"), 4096)
        XCTAssertEqual(try ConjetConfig.parseMemorySizeMiB("4096MiB"), 4096)
        XCTAssertEqual(try ConjetConfig.parseMemorySizeMiB("4G"), 4096)
        XCTAssertEqual(try ConjetConfig.parseMemorySizeMiB("4GiB"), 4096)
        XCTAssertEqual(try ConjetConfig.parseMemorySizeMiB("512m"), 512)
        XCTAssertThrowsError(try ConjetConfig.parseMemorySizeMiB("128M"))
        XCTAssertThrowsError(try ConjetConfig.parseMemorySizeMiB("4T"))
        XCTAssertThrowsError(try ConjetConfig.parseMemorySizeMiB("memory"))
    }

    func testSSHPolicyIsValidated() throws {
        let parsed = try ConjetConfig.parseTOML("[ssh]\nenabled = false\ntransport = \"tcp\"\nallow_tcp_fallback = true\n")
        XCTAssertFalse(parsed.ssh.enabled)
        XCTAssertEqual(parsed.ssh.transport, "tcp")
        XCTAssertTrue(parsed.ssh.allowTCPFallback)
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[ssh]\ntransport = \"lan\"\n"))
    }

    func testRemovableHostMountsAreExplicitOptIn() throws {
        XCTAssertFalse(ConjetConfig.default.enableRemovableHostMounts)

        let parsed = try ConjetConfig.parseTOML("[vm]\nenable_removable_host_mounts = true\n")
        XCTAssertTrue(parsed.enableRemovableHostMounts)
        XCTAssertTrue(parsed.renderTOML().contains("enable_removable_host_mounts = true"))
    }

    func testNamedProfilePathsAreIsolatedUnderProfilesDirectory() {
        let root = URL(fileURLWithPath: "/tmp/conjet-home", isDirectory: true)
        let paths = ConjetPaths(home: root, profileName: "work")

        XCTAssertEqual(paths.profileName, "work")
        XCTAssertEqual(paths.rootHome, root)
        XCTAssertEqual(paths.home.path, "/tmp/conjet-home/profiles/work")
        XCTAssertEqual(paths.socket.path, "/tmp/conjet-home/profiles/work/run/conjetd.sock")
        XCTAssertEqual(paths.dockerSocket.path, "/tmp/conjet-home/profiles/work/run/docker.sock")
    }

    func testDefaultProfileKeepsLegacyHomeLayout() {
        let root = URL(fileURLWithPath: "/tmp/conjet-home", isDirectory: true)
        let paths = ConjetPaths(home: root, profileName: "default")

        XCTAssertEqual(paths.profileName, "default")
        XCTAssertEqual(paths.home, root)
        XCTAssertEqual(paths.socket.path, "/tmp/conjet-home/run/conjetd.sock")
        XCTAssertEqual(paths.vmManifest.path, "/tmp/conjet-home/state/vm/manifest.json")
    }

    func testLongHomeUsesShortRuntimeSocketPaths() throws {
        let root = URL(
            fileURLWithPath: "/Volumes/ExternalSSD/dev_workspace/tmp/conjet-hvf-direct-kernel-docker-live-regression-home-with-long-path",
            isDirectory: true
        )
        let paths = ConjetPaths(home: root, profileName: "security-research-workload")

        XCTAssertEqual(
            paths.home.path,
            root.appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent("security-research-workload", isDirectory: true)
                .path
        )
        XCTAssertTrue(paths.socket.path.hasPrefix("/tmp/conjet-"))
        XCTAssertTrue(paths.dockerSocket.path.hasPrefix("/tmp/conjet-"))
        XCTAssertEqual(paths.socket.lastPathComponent, "conjetd.sock")
        XCTAssertEqual(paths.dockerSocket.lastPathComponent, "docker.sock")
        XCTAssertLessThanOrEqual(paths.socket.path.utf8CString.count, 104)
        XCTAssertLessThanOrEqual(paths.dockerSocket.path.utf8CString.count, 104)

        let qaRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: qaRoot) }
        let isolatedPaths = ConjetPaths(home: qaRoot.appendingPathComponent(root.lastPathComponent), profileName: "security-research-workload")
        try isolatedPaths.ensureBaseDirectories()
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedPaths.socket.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedPaths.dockerSocket.deletingLastPathComponent().path))
    }

    func testDefaultPathsRespectExplicitEnvironment() {
        let paths = ConjetPaths.default(environment: [
            "CONJET_HOME": "/tmp/conjet-env-home",
            "CONJET_PROFILE": "work"
        ])

        XCTAssertEqual(paths.profileName, "work")
        XCTAssertEqual(paths.rootHome.path, "/tmp/conjet-env-home")
        XCTAssertEqual(paths.home.path, "/tmp/conjet-env-home/profiles/work")
        XCTAssertEqual(paths.socket.path, "/tmp/conjet-env-home/profiles/work/run/conjetd.sock")
    }

    func testAppEnvironmentMergesExecutableFallbackPath() {
        let environment = ConjetEnvironment.app(
            processEnvironment: ["PATH": "/custom/bin:/usr/bin"],
            includeLaunchdEnvironment: false
        )

        XCTAssertEqual(
            environment["PATH"],
            "/custom/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"
        )
    }

    func testAppEnvironmentUsesPersistedRuntimeBindingWhenProcessEnvIsMissing() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-env-tests-\(UUID().uuidString)", isDirectory: true)
        let binding = directory.appendingPathComponent("runtime-environment.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try ConjetEnvironment.persistRuntimeBinding(
            environment: [
                "CONJET_HOME": "/tmp/conjet-bound-home",
                "CONJET_PROFILE": "work",
                "PATH": "/should/not/persist"
            ],
            to: binding
        )

        let environment = ConjetEnvironment.app(
            processEnvironment: ["PATH": "/custom/bin"],
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: binding
        )

        XCTAssertEqual(environment["CONJET_HOME"], "/tmp/conjet-bound-home")
        XCTAssertEqual(environment["CONJET_PROFILE"], "work")
        XCTAssertEqual(environment["PATH"], "/custom/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testProcessEnvironmentWinsOverPersistedRuntimeBinding() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conjet-env-tests-\(UUID().uuidString)", isDirectory: true)
        let binding = directory.appendingPathComponent("runtime-environment.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try ConjetEnvironment.persistRuntimeBinding(
            environment: [
                "CONJET_HOME": "/tmp/conjet-bound-home",
                "CONJET_PROFILE": "work"
            ],
            to: binding
        )

        let environment = ConjetEnvironment.app(
            processEnvironment: [
                "CONJET_HOME": "/tmp/process-home",
                "CONJET_PROFILE": "default",
                "PATH": "/custom/bin"
            ],
            includeLaunchdEnvironment: false,
            persistedRuntimeEnvironmentURL: binding
        )

        XCTAssertEqual(environment["CONJET_HOME"], "/tmp/process-home")
        XCTAssertEqual(environment["CONJET_PROFILE"], "default")
    }

    func testForwardedAppEnvironmentArgumentsOnlyIncludeSupportedKeys() {
        let arguments = ConjetEnvironment.forwardedEnvironmentArguments([
            "CONJET_HOME": "/tmp/conjet-home",
            "CONJET_PROFILE": "work",
            "UNRELATED": "ignored"
        ])

        XCTAssertEqual(arguments, [
            "--env", "CONJET_HOME=/tmp/conjet-home",
            "--env", "CONJET_PROFILE=work"
        ])
    }

    func testMenuBarRuntimeBindingPersistenceFollowsDisableFlag() {
        XCTAssertTrue(ConjetEnvironment.shouldPersistMenuBarRuntimeBinding(environment: [:]))
        XCTAssertTrue(ConjetEnvironment.shouldPersistMenuBarRuntimeBinding(environment: [
            "CONJET_DISABLE_MENU_BAR_APP": "0"
        ]))
        XCTAssertFalse(ConjetEnvironment.shouldPersistMenuBarRuntimeBinding(environment: [
            "CONJET_DISABLE_MENU_BAR_APP": "1"
        ]))
    }
}

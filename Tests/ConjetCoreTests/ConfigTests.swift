import ConjetCore
import XCTest

final class ConfigTests: XCTestCase {
    func testConfigRoundTrip() throws {
        let config = ConjetConfig(
            vmCPUs: 6,
            memoryMiB: 8192,
            architecture: "x86_64",
            diskGiB: 120,
            diskImagePath: "/tmp/custom.raw.gz",
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

        XCTAssertEqual(config.vmCPUs, 4)
        XCTAssertEqual(config.memoryMiB, 8192)
        XCTAssertEqual(config.architecture, "aarch64")
        XCTAssertEqual(config.diskGiB, 100)
        XCTAssertEqual(config.runtime, "docker")
        XCTAssertEqual(config.energyMode, .balanced)
        XCTAssertEqual(config.memoryProfile, .balanced)
        XCTAssertTrue(config.ssh.enabled)
        XCTAssertEqual(config.ssh.transport, "proxy-command")
        XCTAssertTrue(config.enableHostMounts)
        XCTAssertFalse(config.enableRemovableHostMounts)
    }

    func testEnergyModeIsValidated() throws {
        let parsed = try ConjetConfig.parseTOML("[daemon]\nenergy_mode = \"performance\"\n")
        XCTAssertEqual(parsed.energyMode, .performance)
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[daemon]\nenergy_mode = \"turbo\"\n"))
    }

    func testMemoryProfileIsValidatedAndProducesPolicy() throws {
        let parsed = try ConjetConfig.parseTOML("[vm]\nmemory_profile = \"eco\"\nmemory_mib = 8192\n")
        XCTAssertEqual(parsed.memoryProfile, .eco)
        XCTAssertEqual(parsed.memoryPolicy.recommendedMemoryMiB, 4096)
        XCTAssertTrue(parsed.memoryPolicy.lazyRuntimeServices)
        XCTAssertTrue(parsed.memoryPolicy.lazyNetworkHelpers)
        XCTAssertThrowsError(try ConjetConfig.parseTOML("[vm]\nmemory_profile = \"tiny\"\n"))
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
}

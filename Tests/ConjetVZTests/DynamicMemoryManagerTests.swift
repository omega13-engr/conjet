import ConjetCore
import Darwin
import Foundation
@testable import ConjetVZ
import XCTest

final class DynamicMemoryManagerTests: XCTestCase {
    func testForceRecomputePreservesConfiguredGuestCapacity() throws {
        let policy = Self.policy()
        let metricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":1073741824,"sreclaimable_bytes":0,"container_memory_current":1073741824,"container_memory_peak":1073741824,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let metricsClient = GuestMemoryMetricsClient(
            connector: StaticHTTPGuestConnectionConnector(body: metricsBody)
        )
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "test.snapshot")

        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().balloonedMiB, 0)
        XCTAssertEqual(manager.status().trace?.last?.action, "observe")
        XCTAssertEqual(appliedTargets.values, [])

        manager.handleDockerActivity(DockerMemoryActivity(
            kind: .streamOpened,
            workload: .build,
            activeStreams: 1,
            buildLike: true
        ))

        XCTAssertTrue(waitUntil { manager.status().activeDockerStreams == 1 })
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(appliedTargets.values, [])
    }

    func testSwapPressureDoesNotIssueBalloonShrink() throws {
        let policy = Self.policy()
        let initialMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":1073741824,"sreclaimable_bytes":0,"container_memory_current":1073741824,"container_memory_peak":1073741824,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let pressureMetricsBody = """
        {"mem_total":8589934592,"mem_available":268435456,"mem_free":134217728,"page_cache_bytes":268435456,"sreclaimable_bytes":0,"swap_total":2147483648,"swap_free":1073741824,"disk_swap_total":1073741824,"disk_swap_free":536870912,"zram_orig_data_size":1073741824,"zram_compr_data_size":268435456,"zram_mem_used_total":335544320,"container_memory_current":1073741824,"container_memory_peak":1073741824,"container_swap_current":268435456,"container_memory_oom_kill_events":1,"psi_some_avg10":3.0,"psi_full_avg10":0.6,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: initialMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(
            connector: connector
        )
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "test.initial")
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)

        connector.setBody(pressureMetricsBody)
        try manager.forceRecompute(reason: "test.swap-pressure")

        let status = manager.status()
        XCTAssertEqual(status.currentTargetMiB, 8192)
        XCTAssertEqual(status.zramUsedMiB, 320)
        XCTAssertEqual(status.diskSwapUsedMiB, 512)
        XCTAssertEqual(status.pressure, .high)
        let pressureTrace = status.trace?.last { $0.reason == "test.swap-pressure" }
        XCTAssertEqual(pressureTrace?.action, "observe")
        XCTAssertEqual(pressureTrace?.reason, "test.swap-pressure")
        XCTAssertEqual(appliedTargets.values, [])
    }

    func testManualIdleReclaimDropsToDemandTarget() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":0,"sreclaimable_bytes":0,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "manual.test")

        XCTAssertEqual(manager.status().currentTargetMiB, 512)
        XCTAssertEqual(manager.status().balloonedMiB, 7680)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertTrue(connector.lastRequest.contains("POST /conjet-memory-reclaim?reason=manual.test"))
        XCTAssertEqual(appliedTargets.values, [512])
    }

    func testManualAndDockerFinishedReclaimBypassRecentReclaimCooldown() throws {
        let policy = Self.policy(dynamicMemoryShrinkCooldownSeconds: 60)
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "manual.first")
        try manager.forceRecompute(reason: "manual.second")
        try manager.forceRecompute(reason: "docker.workloadFinished")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "idle-autodrop" } == true)
        XCTAssertEqual(appliedTargets.values, [512])
    }

    func testDockerWorkloadFinishedDropsToContainerDemandTarget() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":536870912,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "docker.workloadFinished")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [1152])
        XCTAssertEqual(manager.status().currentTargetMiB, 1152)
        XCTAssertEqual(manager.status().balloonedMiB, 7040)
    }

    func testGuestReclaimRangePayloadIsRejectedWithoutChangingBalloonTarget() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":268435456,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
            reclaimBody: """
            {"ranges":[{"start":4096,"size":8192},{"start":16384,"size":4096}],"source":"test"}
            """
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertTrue(manager.status().message?.contains("guest memory reclaim unavailable") == true)
    }

    func testBuildStartAndStreamPhaseFinishedDoNotPulseClassicBalloon() throws {
        let policy = Self.policy()
        let quietMetricsBody = """
        {"mem_total":8589934592,"mem_available":2147483648,"mem_free":1073741824,"page_cache_bytes":67108864,"sreclaimable_bytes":33554432,"container_memory_current":536870912,"container_memory_peak":536870912,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let reclaimableMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":536870912,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: quietMetricsBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        manager.handleDockerActivity(DockerMemoryActivity(
            kind: .streamOpened,
            workload: .build,
            activeStreams: 1,
            pressureStreams: 1,
            buildLike: true
        ))
        try manager.forceRecompute(reason: "docker.streamOpened")
        XCTAssertEqual(appliedTargets.values, [])

        connector.setBody(reclaimableMetricsBody)
        manager.handleDockerActivity(DockerMemoryActivity(
            kind: .streamPhaseFinished,
            workload: .build,
            activeStreams: 1,
            pressureStreams: 1,
            buildLike: true
        ))
        try manager.forceRecompute(reason: "docker.streamPhaseFinished")

        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().trace?.last?.action, "reclaim")
    }

    func testGuestEventWithLargeIdleCacheDropsToDemandTarget() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":268435456,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [896])
        XCTAssertEqual(manager.status().currentTargetMiB, 896)
    }

    func testGuestEventWithAvailableSurplusCanReclaimWithoutPulse() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":67108864,"sreclaimable_bytes":33554432,"container_memory_current":268435456,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(
            connector: connector
        )
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [896])
    }

    func testGuestEventWithActiveWorkloadsSuppressesIdleReclaim() throws {
        let policy = Self.policy()
        let activeMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":1610612736,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: activeMetricsBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertFalse(manager.status().buildWorkloadDetected)
        XCTAssertEqual(manager.status().guestWorkloadDetected, true)
        XCTAssertEqual(manager.status().trace?.last?.action, "observe")
        XCTAssertEqual(connector.reclaimRequests, 0)
        XCTAssertEqual(appliedTargets.values, [])
    }

    func testStatusSeparatesBuildAndGuestWorkloads() throws {
        let policy = Self.policy()
        let buildMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"build_cgroup_memory_current":104857600,"daemon_cgroup_memory_current":209715200,"service_cgroup_memory_current":314572800,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":true,"source":"test"}
        """
        let metricsClient = GuestMemoryMetricsClient(
            connector: StaticHTTPGuestConnectionConnector(body: buildMetricsBody)
        )
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in }
        )

        try manager.forceRecompute(reason: "test.build-status")

        let status = manager.status()
        XCTAssertTrue(status.buildWorkloadDetected)
        XCTAssertEqual(status.guestWorkloadDetected, true)
        XCTAssertEqual(status.buildCgroupMemoryMiB, 100)
        XCTAssertEqual(status.daemonCgroupMemoryMiB, 200)
        XCTAssertEqual(status.serviceCgroupMemoryMiB, 300)
    }

    func testGuestReclaimUnavailableDoesNotTriggerClassicBalloonPulse() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":268435456,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
            reclaimBody: "not found\n",
            reclaimStatusCode: 404
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertTrue(manager.status().message?.contains("guest memory reclaim unavailable") == true)
    }

    func testContainerStartedCancelsActiveGuestReclaimWithoutMarkingBuildActive() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":67108864,"sreclaimable_bytes":33554432,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
            reclaimStatusBody: #"{"epoch":1,"state":"memcgReclaiming","requested_bytes":0,"observed_current_drop_bytes":0,"source":"test"}"#
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in }
        )
        let completed = expectation(description: "reclaim poll exits after cancellation")

        DispatchQueue.global(qos: .utility).async {
            try? manager.forceRecompute(reason: "manual.cancel-test")
            completed.fulfill()
        }
        XCTAssertTrue(waitUntil { connector.reclaimRequests == 1 && connector.reclaimStatusRequests > 0 })

        manager.handleDockerActivity(DockerMemoryActivity(
            kind: .containerStarted,
            workload: .start,
            activeStreams: 0,
            pressureStreams: 0,
            buildLike: false
        ))

        XCTAssertTrue(waitUntil { connector.reclaimCancelRequests == 1 })
        wait(for: [completed], timeout: 2)
        XCTAssertFalse(manager.status().buildWorkloadDetected)
        XCTAssertEqual(manager.status().guestWorkloadDetected, false)
    }

    func testAcceptedReclaimRecordsHostFootprintConvergence() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":67108864,"sreclaimable_bytes":33554432,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(900 * 1024 * 1024),
            UInt64(700 * 1024 * 1024)
        ])
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "manual.footprint")

        let status = manager.status()
        XCTAssertEqual(status.hostFootprintMiB, 700)
        XCTAssertEqual(status.hostReclaimedMiB, 200)
        XCTAssertTrue(status.message?.contains("demand memory reclaim lowered guest target") == true)
        let footprintTrace = try XCTUnwrap(status.trace?.last { $0.action == "reclaim-footprint" })
        XCTAssertEqual(footprintTrace.action, "reclaim-footprint")
        XCTAssertEqual(footprintTrace.hostFootprintBeforeBytes, UInt64(900 * 1024 * 1024))
        XCTAssertEqual(footprintTrace.hostFootprintAfterBytes, UInt64(700 * 1024 * 1024))
        XCTAssertEqual(footprintTrace.hostFootprintDropBytes, UInt64(200 * 1024 * 1024))
    }

    func testActiveReclaimRefreshesHostFootprintWhileWaitingForReporting() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":67108864,"sreclaimable_bytes":33554432,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
            reclaimStatusBody: #"{"epoch":1,"state":"reporting","requested_bytes":67108864,"observed_current_drop_bytes":0,"source":"test"}"#
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(900 * 1024 * 1024),
            UInt64(800 * 1024 * 1024),
            UInt64(700 * 1024 * 1024)
        ])
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0],
            activeReclaimFootprintRefreshInterval: 0.01
        )
        let completed = expectation(description: "reclaim poll reaches terminal state")

        DispatchQueue.global(qos: .utility).async {
            try? manager.forceRecompute(reason: "manual.pending-footprint")
            completed.fulfill()
        }

        XCTAssertTrue(waitUntil {
            connector.reclaimStatusRequests > 0 && manager.status().hostFootprintMiB == 800
        })
        connector.setReclaimStatusBody(
            #"{"epoch":1,"state":"done","requested_bytes":67108864,"observed_current_drop_bytes":67108864,"source":"test"}"#
        )
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(manager.status().hostFootprintMiB, 700)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "reclaim-footprint" } == true)
    }

    func testZeroHostFootprintDropTriggersIdleAutodropBalloonTarget() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":268435456,"service_cgroup_memory_current":67108864,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(12 * 1024 * 1024 * 1024),
            UInt64(12 * 1024 * 1024 * 1024)
        ])
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(appliedTargets.values, [640])
        XCTAssertEqual(manager.status().currentTargetMiB, 640)
        XCTAssertEqual(manager.status().balloonedMiB, 7552)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
        XCTAssertTrue(manager.status().message?.contains("demand memory reclaim lowered guest target") == true)
    }

    func testHostPressureReclaimAutodropsWhenFootprintAlreadyBelowConfiguredCap() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":268435456,"service_cgroup_memory_current":67108864,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(700 * 1024 * 1024),
            UInt64(700 * 1024 * 1024)
        ])
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "host.pressure.high")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [640])
        XCTAssertEqual(manager.status().hostFootprintMiB, 700)
        XCTAssertEqual(manager.status().currentTargetMiB, 640)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
    }

    func testHostPressureDoesNotReclaimWhileGuestWorkloadIsActive() throws {
        let policy = Self.policy()
        let activeMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":1610612736,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: activeMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "host.pressure.high")

        XCTAssertEqual(connector.reclaimRequests, 0)
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().trace?.last?.action, "observe")
    }

    func testIdleAutodropRestoresOnHighGuestPressure() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":268435456,"service_cgroup_memory_current":67108864,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let balloonPressureMetricsBody = """
        {"mem_total":8589934592,"mem_available":268435456,"mem_free":134217728,"page_cache_bytes":134217728,"sreclaimable_bytes":67108864,"container_memory_current":0,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":268435456,"service_cgroup_memory_current":67108864,"psi_some_avg10":1.0,"psi_full_avg10":0.2,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(12 * 1024 * 1024 * 1024),
            UInt64(12 * 1024 * 1024 * 1024)
        ])
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "guest.event")
        XCTAssertEqual(manager.status().currentTargetMiB, 640)

        connector.setBody(balloonPressureMetricsBody)
        try manager.forceRecompute(reason: "guest.event")

        let status = manager.status()
        XCTAssertEqual(appliedTargets.values, [640, 8192])
        XCTAssertEqual(status.currentTargetMiB, 8192)
        XCTAssertEqual(status.balloonedMiB, 0)
        XCTAssertEqual(status.pressure, .high)
        XCTAssertEqual(status.trace?.last?.action, "restore")
        XCTAssertTrue(status.message?.contains("restored to configured maximum") == true)
    }

    func testEcoIdleAutodropFallsTowardLinuxFloorPlusRuntimeUsage() throws {
        let policy = ConjetMemoryPolicy(
            profile: .eco,
            configuredMemoryMiB: 4096,
            recommendedMemoryMiB: 4096,
            lazyRuntimeServices: true,
            lazyNetworkHelpers: true,
            reclaimIdleHelpersAfterSeconds: 60,
            idleWakeupBudgetPerSecond: 0.2,
            automaticIdleMemoryReclaim: true,
            idleMemoryReclaimTargetMiB: 2048,
            idleMemoryReclaimDwellSeconds: 3,
            dynamicMemoryEnabled: true,
            dynamicMemoryMinimumMiB: 512,
            dynamicMemoryBaseOverheadMiB: 0,
            dynamicMemoryHeadroomMiB: 128,
            dynamicMemoryHeadroomRatio: 0.10,
            dynamicMemoryCacheAllowanceMiB: 128,
            dynamicMemoryShrinkCooldownSeconds: 0,
            dynamicMemoryShrinkStepMiB: 256
        )
        let idleMetricsBody = """
        {"mem_total":4294967296,"mem_available":3221225472,"mem_free":1073741824,"page_cache_bytes":1610612736,"sreclaimable_bytes":134217728,"container_memory_current":1048576,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":211812352,"service_cgroup_memory_current":0,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(6 * 1024 * 1024 * 1024),
            UInt64(6 * 1024 * 1024 * 1024)
        ])
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(appliedTargets.values, [512])
        XCTAssertEqual(manager.status().currentTargetMiB, 512)
        XCTAssertEqual(manager.status().balloonedMiB, 3584)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
    }

    func testIdleAutodropDoesNotCapBelowRunningContainerWorkingSet() throws {
        let policy = ConjetMemoryPolicy(
            profile: .eco,
            configuredMemoryMiB: 4096,
            recommendedMemoryMiB: 4096,
            lazyRuntimeServices: true,
            lazyNetworkHelpers: true,
            reclaimIdleHelpersAfterSeconds: 60,
            idleWakeupBudgetPerSecond: 0.2,
            automaticIdleMemoryReclaim: true,
            idleMemoryReclaimTargetMiB: 2048,
            idleMemoryReclaimDwellSeconds: 3,
            dynamicMemoryEnabled: true,
            dynamicMemoryMinimumMiB: 512,
            dynamicMemoryBaseOverheadMiB: 0,
            dynamicMemoryHeadroomMiB: 128,
            dynamicMemoryHeadroomRatio: 0.10,
            dynamicMemoryCacheAllowanceMiB: 128,
            dynamicMemoryShrinkCooldownSeconds: 0,
            dynamicMemoryShrinkStepMiB: 256
        )
        let idleMetricsBody = """
        {"mem_total":4294967296,"mem_available":3221225472,"mem_free":1073741824,"page_cache_bytes":1073741824,"sreclaimable_bytes":134217728,"container_memory_current":2147483648,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":0,"service_cgroup_memory_current":0,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(6 * 1024 * 1024 * 1024),
            UInt64(6 * 1024 * 1024 * 1024)
        ])
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "docker.workloadFinished")

        XCTAssertEqual(appliedTargets.values, [2816])
        XCTAssertEqual(manager.status().currentTargetMiB, 2816)
        XCTAssertEqual(manager.status().balloonedMiB, 1280)
        XCTAssertEqual(manager.status().guestWorkloadDetected, true)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
    }

    func testGuestEventActiveServiceIdleDropsToLiveCgroupDemandTarget() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":3221225472,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":3221225472,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: serviceMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            activeServiceReclaimDwellSeconds: 0
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [4096])
        XCTAssertEqual(manager.status().currentTargetMiB, 4096)
        XCTAssertEqual(manager.status().guestWorkloadDetected, true)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
    }

    func testGuestEventActiveServiceIdleDropsWithPersistentNonBuildDockerStream() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":3221225472,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":3221225472,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: serviceMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            activeServiceReclaimDwellSeconds: 0
        )

        manager.handleDockerActivity(DockerMemoryActivity(
            kind: .streamOpened,
            workload: .start,
            activeStreams: 1,
            pressureStreams: 1,
            buildLike: false
        ))
        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(appliedTargets.values, [4096])
        XCTAssertEqual(manager.status().activeDockerStreams, 1)
        XCTAssertEqual(manager.status().currentTargetMiB, 4096)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
    }

    func testActiveServiceIdleRefinesDownAsLiveCgroupUsageFalls() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":3221225472,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":3221225472,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let lowerServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":1073741824,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":1073741824,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: serviceMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            activeServiceReclaimDwellSeconds: 0
        )

        try manager.forceRecompute(reason: "guest.event")
        connector.setBody(lowerServiceMetricsBody)
        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(appliedTargets.values, [4096, 1792])
        XCTAssertEqual(manager.status().currentTargetMiB, 1792)
        XCTAssertEqual(manager.status().guestWorkloadDetected, true)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-refine")
    }

    func testHostFootprintDropStillAppliesDemandTarget() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(12 * 1024 * 1024 * 1024),
            UInt64(8 * 1024 * 1024 * 1024)
        ])
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(appliedTargets.values, [512])
        XCTAssertEqual(manager.status().currentTargetMiB, 512)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-autodrop")
    }

    func testHostResidentMemoryIsReportedSeparatelyFromPhysicalFootprint() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in },
            hostFootprintBytes: { UInt64(1_280 * 1024 * 1024) },
            hostResidentBytes: { UInt64(300 * 1024 * 1024) },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(manager.status().hostFootprintMiB, 1280)
        XCTAssertEqual(manager.status().hostResidentMiB, 300)
    }

    func testBalloonedIdleGuestUsesRelativeAvailableMemoryPressureFloor() throws {
        let policy = Self.policy()
        let balloonedIdleMetricsBody = """
        {"mem_total":576811008,"mem_available":350695424,"mem_free":333193216,"page_cache_bytes":90800128,"sreclaimable_bytes":8278016,"swap_total":4180717568,"swap_free":4159995904,"disk_swap_total":0,"disk_swap_free":0,"zram_orig_data_size":18624512,"zram_compr_data_size":5005956,"zram_mem_used_total":6283264,"container_memory_current":1925120,"container_memory_peak":11755520,"container_swap_current":888832,"build_cgroup_memory_current":0,"daemon_cgroup_memory_current":124407808,"service_cgroup_memory_current":2207744,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let metricsClient = GuestMemoryMetricsClient(
            connector: StaticHTTPGuestConnectionConnector(body: balloonedIdleMetricsBody)
        )
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in }
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(manager.status().pressure, .low)
        XCTAssertEqual(manager.status().trace?.last?.action, "observe")
    }

    func testStaleIdleTargetRefinesDownForStoppedContainerResidue() throws {
        let policy = Self.policy()
        let staleIdleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":398458880,"service_cgroup_memory_current":0,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let stoppedContainerResidueMetricsBody = """
        {"mem_total":576811008,"mem_available":350695424,"mem_free":333193216,"page_cache_bytes":90800128,"sreclaimable_bytes":8278016,"swap_total":4180717568,"swap_free":4159995904,"disk_swap_total":0,"disk_swap_free":0,"zram_orig_data_size":18624512,"zram_compr_data_size":5005956,"zram_mem_used_total":6283264,"container_memory_current":1925120,"container_memory_peak":11755520,"container_swap_current":888832,"build_cgroup_memory_current":0,"daemon_cgroup_memory_current":124407808,"service_cgroup_memory_current":2207744,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: staleIdleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            }
        )

        try manager.forceRecompute(reason: "manual.test")
        XCTAssertEqual(manager.status().currentTargetMiB, 768)

        connector.setBody(stoppedContainerResidueMetricsBody)
        try manager.forceRecompute(reason: "guest.event")

        let status = manager.status()
        XCTAssertEqual(appliedTargets.values, [768, 512])
        XCTAssertEqual(status.currentTargetMiB, 512)
        XCTAssertEqual(status.balloonedMiB, 7680)
        XCTAssertEqual(status.pressure, .low)
        XCTAssertEqual(status.trace?.last?.action, "idle-refine")
    }

    func testDockerStartRestoresIdleAutodropBalloonTarget() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":268435456,"service_cgroup_memory_current":67108864,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(12 * 1024 * 1024 * 1024),
            UInt64(12 * 1024 * 1024 * 1024)
        ])
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            hostFootprintBytes: { footprintSamples.next() },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "guest.event")
        XCTAssertEqual(manager.status().currentTargetMiB, 640)

        manager.handleDockerActivity(DockerMemoryActivity(
            kind: .streamOpened,
            workload: .build,
            activeStreams: 1,
            pressureStreams: 1,
            buildLike: true
        ))

        XCTAssertTrue(waitUntil { appliedTargets.values == [640, 8192] })
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().balloonedMiB, 0)
        XCTAssertEqual(manager.status().trace?.last?.action, "restore")
    }

    private static func policy(dynamicMemoryShrinkCooldownSeconds: Int = 0) -> ConjetMemoryPolicy {
        ConjetMemoryPolicy(
            profile: .noPolicy,
            configuredMemoryMiB: 8192,
            recommendedMemoryMiB: 8192,
            lazyRuntimeServices: false,
            lazyNetworkHelpers: true,
            reclaimIdleHelpersAfterSeconds: 0,
            idleWakeupBudgetPerSecond: 1,
            automaticIdleMemoryReclaim: true,
            idleMemoryReclaimTargetMiB: 8192,
            idleMemoryReclaimDwellSeconds: 0,
            dynamicMemoryEnabled: true,
            dynamicMemoryMinimumMiB: 512,
            dynamicMemoryBaseOverheadMiB: 0,
            dynamicMemoryHeadroomMiB: 128,
            dynamicMemoryHeadroomRatio: 0.10,
            dynamicMemoryCacheAllowanceMiB: 128,
            dynamicMemoryShrinkCooldownSeconds: dynamicMemoryShrinkCooldownSeconds,
            dynamicMemoryShrinkStepMiB: 8192
        )
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 1,
        intervalSeconds: TimeInterval = 0.01,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() {
                return true
            }
            Thread.sleep(forTimeInterval: intervalSeconds)
        }
        return predicate()
    }
}

private final class AppliedMemoryTargets: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedValues: [Int] = []

    var values: [Int] {
        lock.lock()
        let value = capturedValues
        lock.unlock()
        return value
    }

    func append(_ value: Int) {
        lock.lock()
        capturedValues.append(value)
        lock.unlock()
    }
}

private final class HostFootprintSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private final class StaticHTTPGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var body: String
    private var reclaimBody: String
    private var reclaimStatusBody: String
    private var reclaimStatusCode: Int
    private var capturedReclaimRequests = 0
    private var capturedReclaimCancelRequests = 0
    private var capturedReclaimStatusRequests = 0
    private var capturedLastRequest = ""

    var reclaimRequests: Int {
        lock.lock()
        let value = capturedReclaimRequests
        lock.unlock()
        return value
    }

    var lastRequest: String {
        lock.lock()
        let value = capturedLastRequest
        lock.unlock()
        return value
    }

    var reclaimCancelRequests: Int {
        lock.lock()
        let value = capturedReclaimCancelRequests
        lock.unlock()
        return value
    }

    var reclaimStatusRequests: Int {
        lock.lock()
        let value = capturedReclaimStatusRequests
        lock.unlock()
        return value
    }

    init(
        body: String,
        reclaimBody: String? = nil,
        reclaimStatusBody: String? = nil,
        reclaimStatusCode: Int = 202
    ) {
        self.body = body
        self.reclaimBody = reclaimBody ?? #"{"accepted":true,"epoch":1,"state":"queued","source":"test"}"#
        self.reclaimStatusBody = reclaimStatusBody ?? #"{"epoch":1,"state":"done","requested_bytes":67108864,"observed_current_drop_bytes":67108864,"source":"test"}"#
        self.reclaimStatusCode = reclaimStatusCode
    }

    func setBody(_ body: String) {
        lock.lock()
        self.body = body
        lock.unlock()
    }

    func setReclaimStatusBody(_ body: String) {
        lock.lock()
        self.reclaimStatusBody = body
        lock.unlock()
    }

    func connect() throws -> GuestConnection {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ConjetError.socket("socketpair() failed")
        }

        let clientFD = fds[0]
        let serverFD = fds[1]
        var noSigpipe: Int32 = 1
        withUnsafePointer(to: &noSigpipe) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<Int32>.size) { rebound in
                _ = setsockopt(serverFD, SOL_SOCKET, SO_NOSIGPIPE, rebound, socklen_t(MemoryLayout<Int32>.size))
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(serverFD) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(serverFD, &buffer, buffer.count)
            let request = count > 0 ? String(bytes: buffer.prefix(count), encoding: .utf8) ?? "" : ""
            let responseParts = self.responseSnapshot(for: request)
            let response = """
            HTTP/1.1 \(responseParts.statusCode) \(responseParts.statusText)\r
            Content-Type: application/json\r
            Content-Length: \(Data(responseParts.body.utf8).count)\r
            \r
            \(responseParts.body)
            """
            _ = response.withCString { pointer in
                Darwin.write(serverFD, pointer, strlen(pointer))
            }
            Darwin.shutdown(serverFD, SHUT_WR)
        }

        return GuestConnection(fileDescriptor: clientFD) {
            Darwin.close(clientFD)
        }
    }

    private func responseSnapshot(for request: String) -> (statusCode: Int, statusText: String, body: String) {
        lock.lock()
        let snapshot: String
        let statusCode: Int
        if request.contains("/conjet-memory-reclaim/cancel-before") {
            capturedLastRequest = request
            capturedReclaimCancelRequests += 1
            snapshot = #"{"epoch":2,"state":"cancelled","requested_bytes":0,"observed_current_drop_bytes":0,"source":"test"}"#
            statusCode = 200
        } else if request.contains("/conjet-memory-reclaim/status") {
            capturedReclaimStatusRequests += 1
            snapshot = reclaimStatusBody
            statusCode = 200
        } else if request.contains("/conjet-memory-reclaim") {
            capturedLastRequest = request
            capturedReclaimRequests += 1
            snapshot = reclaimBody
            statusCode = reclaimStatusCode
        } else {
            capturedLastRequest = request
            snapshot = body
            statusCode = 200
        }
        lock.unlock()
        let statusText: String
        switch statusCode {
        case 200:
            statusText = "OK"
        case 202:
            statusText = "Accepted"
        default:
            statusText = "Not Found"
        }
        let body = snapshot.hasSuffix("\n") ? snapshot : snapshot + "\n"
        return (statusCode, statusText, body)
    }
}

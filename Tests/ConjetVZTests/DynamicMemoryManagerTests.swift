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

    func testForceRecomputeRequestsServiceSliceReclaimWithoutChangingGuestCapacity() throws {
        let policy = Self.policy()
        let metricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":4294967296,"container_memory_peak":4294967296,"container_inactive_file":3221225472,"service_cgroup_memory_current":4294967296,"service_cgroup_anon":805306368,"service_cgroup_file":3221225472,"service_cgroup_inactive_file":3221225472,"service_cgroup_slab_reclaimable":268435456,"daemon_cgroup_memory_current":239075328,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_worker","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_worker.slice","memory_current":4294967296,"anon":805306368,"file":3221225472,"inactive_file":3221225472,"active_file":0,"slab_reclaimable":268435456,"slab_unreclaimable":0,"working_set":805306368,"reclaimable":3489660928,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: metricsBody,
            reclaimBody: #"{"accepted":false,"epoch":1,"state":"ignored","source":"test"}"#,
            serviceSlicesBody: serviceSlicesBody
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

        try manager.forceRecompute(reason: "manual.reclaim")

        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(connector.reclaimRequests, 0)
        XCTAssertEqual(connector.serviceReclaimRequests, 1)
        XCTAssertTrue(connector.lastRequest.contains("/conjet-memory-reclaim/service"))
        XCTAssertTrue(connector.lastRequest.contains("key=chum_mem_worker"))
        XCTAssertTrue(connector.lastRequest.contains("bytes=3489660928"))
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().trace?.first { $0.action == "service-slice-reclaim" }?.targetMiB, 8192)
        XCTAssertTrue(manager.status().message?.contains("guest capacity unchanged") == true)
        XCTAssertEqual(manager.status().serviceSlices?.first?.key, "chum_mem_worker")
        XCTAssertEqual(manager.status().serviceSlices?.first?.workingSetBytes, 805306368)

        try manager.forceRecompute(reason: "manual.reclaim")

        XCTAssertEqual(connector.reclaimRequests, 0)
        XCTAssertEqual(connector.serviceReclaimRequests, 2)
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertFalse(manager.status().message?.contains("restored to configured maximum") == true)
    }

    func testActiveServicePressureKeepsConfiguredGuestCapacity() throws {
        let policy = Self.policy()
        let lowPressureServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":536870912,"sreclaimable_bytes":0,"container_memory_current":3355443200,"container_memory_peak":3355443200,"service_cgroup_memory_current":3355443200,"service_cgroup_anon":3355443200,"service_cgroup_file":0,"service_cgroup_inactive_file":0,"service_cgroup_slab_reclaimable":0,"daemon_cgroup_memory_current":268435456,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let highPressureServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":536870912,"sreclaimable_bytes":0,"container_memory_current":3355443200,"container_memory_peak":3355443200,"service_cgroup_memory_current":3355443200,"service_cgroup_anon":3355443200,"service_cgroup_file":0,"service_cgroup_inactive_file":0,"service_cgroup_slab_reclaimable":0,"daemon_cgroup_memory_current":268435456,"psi_some_avg10":0.0,"psi_full_avg10":0.1,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_postgres","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_postgres.slice","memory_current":3355443200,"anon":3355443200,"file":0,"inactive_file":0,"active_file":0,"slab_reclaimable":0,"slab_unreclaimable":0,"working_set":3355443200,"reclaimable":0,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: lowPressureServiceMetricsBody,
            reclaimBody: #"{"accepted":false,"epoch":1,"state":"ignored","source":"test"}"#,
            serviceSlicesBody: serviceSlicesBody
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

        try manager.forceRecompute(reason: "manual.reclaim")
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(appliedTargets.values, [])

        connector.setBody(highPressureServiceMetricsBody)
        connector.setServiceSlicesBody(#"{"version":1,"slices":[],"source":"test"}"#)

        try manager.forceRecompute(reason: "guest.event")
        try manager.forceRecompute(reason: "guest.event")
        try manager.forceRecompute(reason: "guest.event")

        XCTAssertFalse(appliedTargets.values.contains(8192), "\(appliedTargets.values)")
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertFalse(manager.status().trace?.contains { $0.action == "restore" } == true)
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

        XCTAssertEqual(connector.reclaimRequests, 2)
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

    func testMissingGuestReclaimEndpointFallsBackToIdleBalloonDrop() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
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

        try manager.forceRecompute(reason: "docker.containerStopped")

        let status = manager.status()
        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [512])
        XCTAssertEqual(status.currentTargetMiB, 512)
        XCTAssertEqual(status.balloonedMiB, 7680)
        XCTAssertEqual(status.trace?.last?.action, "idle-autodrop")
        XCTAssertEqual(status.trace?.last?.reason, "docker.containerStopped.guest-reclaim-unavailable.autodrop")
        XCTAssertTrue(status.message?.contains("guest reclaim endpoint unavailable") == true)
    }

    func testMissingGuestReclaimEndpointKeepsActiveServiceCapacityAfterRealtimeAttempt() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":3221225472,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":3221225472,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: serviceMetricsBody,
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

        let status = manager.status()
        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(connector.serviceReclaimRequests, 0)
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(status.currentTargetMiB, 8192)
        XCTAssertEqual(status.guestWorkloadDetected, true)
        XCTAssertEqual(status.trace?.last?.action, "reclaim")
    }

    func testMissingGuestReclaimEndpointFallsBackWhenStopStreamIsStillOpen() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":1073741824,"mem_free":536870912,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
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

        manager.handleDockerActivity(DockerMemoryActivity(
            kind: .streamOpened,
            workload: .stop,
            activeStreams: 1,
            pressureStreams: 1,
            buildLike: false
        ))
        try manager.forceRecompute(reason: "docker.containerStopped")

        let status = manager.status()
        XCTAssertEqual(status.activeDockerStreams, 1)
        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [640])
        XCTAssertEqual(status.currentTargetMiB, 640)
        XCTAssertEqual(status.trace?.last?.reason, "docker.containerStopped.guest-reclaim-unavailable.autodrop")
    }

    func testMissingGuestReclaimEndpointFallsBackForStoppedWorkloadUnderPSIPressure() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":4294967296,"mem_free":536870912,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":2.0,"psi_full_avg10":0.1,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
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

        try manager.forceRecompute(reason: "docker.containerStopped")

        let status = manager.status()
        XCTAssertEqual(status.pressure, .high)
        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [512])
        XCTAssertEqual(status.currentTargetMiB, 512)
        XCTAssertEqual(status.trace?.last?.reason, "docker.containerStopped.guest-reclaim-unavailable.autodrop")
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

    func testStatusUsesServiceCgroupWorkingSetWhenServiceCacheIsInactive() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":1083179008,"sreclaimable_bytes":67108864,"container_memory_current":3670016,"container_memory_peak":11755520,"container_inactive_file":0,"build_cgroup_memory_current":0,"daemon_cgroup_memory_current":145752064,"service_cgroup_memory_current":945815552,"service_cgroup_anon":106954752,"service_cgroup_file":838860800,"service_cgroup_inactive_file":734003200,"service_cgroup_active_file":104857600,"service_cgroup_slab":134217728,"service_cgroup_slab_reclaimable":67108864,"service_cgroup_slab_unreclaimable":67108864,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":1,"build_workload_detected":false,"source":"test"}
        """
        let metricsClient = GuestMemoryMetricsClient(
            connector: StaticHTTPGuestConnectionConnector(body: serviceMetricsBody)
        )
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in }
        )

        try manager.forceRecompute(reason: "test.service-cache-status")

        let status = manager.status()
        XCTAssertEqual(status.containerMemoryMiB, 3)
        XCTAssertEqual(status.daemonCgroupMemoryMiB, 139)
        XCTAssertEqual(status.serviceCgroupMemoryMiB, 138)
        XCTAssertEqual(status.guestWorkloadDetected, false)
    }

    func testGuestReclaimUnavailableDoesNotTriggerClassicBalloonPulse() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":268435456,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
            reclaimBody: "temporarily unavailable\n",
            reclaimStatusCode: 503
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

    func testIdleAutodropExpandsInStepsOnHighGuestPressure() throws {
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
        XCTAssertEqual(appliedTargets.values, [640, 1664])
        XCTAssertEqual(status.currentTargetMiB, 1664)
        XCTAssertEqual(status.balloonedMiB, 6528)
        XCTAssertEqual(status.pressure, .high)
        XCTAssertEqual(status.trace?.last?.action, "idle-expand")
        XCTAssertTrue(status.message?.contains("expanded idle target") == true)
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

    func testActiveContainerKeepsConfiguredCapacityInsteadOfWorkingSetTarget() throws {
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

        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 4096)
        XCTAssertEqual(manager.status().balloonedMiB, 0)
        XCTAssertEqual(manager.status().guestWorkloadDetected, true)
        XCTAssertEqual(manager.status().trace?.last?.action, "reclaim-footprint")
    }

    func testGuestEventActiveServiceIdleReclaimsAndDropsToServiceDemandTarget() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":3221225472,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":3221225472,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_worker","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_worker.slice","memory_current":3221225472,"anon":1073741824,"file":2147483648,"inactive_file":2147483648,"active_file":0,"slab_reclaimable":134217728,"slab_unreclaimable":0,"working_set":1073741824,"reclaimable":2281701376,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: serviceMetricsBody,
            serviceSlicesBody: serviceSlicesBody
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
        XCTAssertEqual(connector.serviceReclaimRequests, 1)
        XCTAssertEqual(appliedTargets.values, [4096])
        XCTAssertEqual(manager.status().currentTargetMiB, 4096)
        XCTAssertEqual(manager.status().guestWorkloadDetected, true)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "service-slice-reclaim" } == true)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "idle-autodrop" } == true)
    }

    func testGuestEventActiveServiceIdleWithPersistentNonBuildDockerStreamDropsTarget() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":3221225472,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":3221225472,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_api","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_api.slice","memory_current":3221225472,"anon":1073741824,"file":2147483648,"inactive_file":2147483648,"active_file":0,"slab_reclaimable":134217728,"slab_unreclaimable":0,"working_set":1073741824,"reclaimable":2281701376,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: serviceMetricsBody,
            serviceSlicesBody: serviceSlicesBody
        )
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
        XCTAssertEqual(connector.serviceReclaimRequests, 1)
        XCTAssertEqual(manager.status().activeDockerStreams, 1)
        XCTAssertEqual(manager.status().currentTargetMiB, 4096)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "service-slice-reclaim" } == true)
    }

    func testActiveServiceIdleReportsDockerWorkingSetAndDropsTarget() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":4514119680,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":5952765952,"container_memory_peak":6442450944,"container_anon":4383047680,"container_file":1569718272,"container_inactive_file":1569718272,"daemon_cgroup_memory_current":178257920,"service_cgroup_memory_current":5945425920,"service_cgroup_file":1569718272,"service_cgroup_inactive_file":1569718272,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":4,"build_workload_detected":false,"source":"test"}
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

        let status = manager.status()
        XCTAssertEqual(status.containerMemoryMiB, 4180)
        XCTAssertEqual(status.serviceCgroupMemoryMiB, 4173)
        XCTAssertEqual(appliedTargets.values, [5376])
        XCTAssertEqual(status.currentTargetMiB, 5376)
        XCTAssertEqual(status.activeDockerStreams, 1)
        XCTAssertEqual(status.trace?.last?.action, "idle-autodrop")
    }

    func testActiveServiceIdleRefinesGuestCapacityAsLiveCgroupUsageFalls() throws {
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

    func testActiveServiceIdleExpandsFromLiveCgroupDemandTarget() throws {
        let policy = Self.policy()
        let smallServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":1073741824,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":1073741824,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let largerServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":3221225472,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":134217728,"service_cgroup_memory_current":3221225472,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: smallServiceMetricsBody)
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
        connector.setBody(largerServiceMetricsBody)
        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(appliedTargets.values, [1792, 4096])
        XCTAssertEqual(manager.status().currentTargetMiB, 4096)
        XCTAssertEqual(manager.status().balloonedMiB, 4096)
        XCTAssertEqual(manager.status().guestWorkloadDetected, true)
        XCTAssertEqual(manager.status().trace?.last?.action, "idle-expand")
    }

    func testActiveServicePressureKeepsConfiguredCapacityAfterIdleDrop() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":0,"service_cgroup_memory_current":0,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let pressuredServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":1967128576,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":173015040,"service_cgroup_memory_current":1967128576,"psi_some_avg10":0.0,"psi_full_avg10":0.1,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
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
        connector.setBody(pressuredServiceMetricsBody)
        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(appliedTargets.values, [512, 8192])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().balloonedMiB, 0)
        XCTAssertEqual(manager.status().pressure, .high)
        XCTAssertEqual(manager.status().trace?.last?.action, "restore")
    }

    func testActiveServicePressureRestoresRealtimeIdleDrop() throws {
        let policy = Self.policy()
        let largeServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":5575278592,"container_memory_peak":6442450944,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":5575278592,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let pressuredLargeServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":2147483648,"sreclaimable_bytes":134217728,"container_memory_current":5575278592,"container_memory_peak":6442450944,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":5575278592,"psi_some_avg10":0.0,"psi_full_avg10":0.1,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: largeServiceMetricsBody)
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
        connector.setBody(pressuredLargeServiceMetricsBody)
        try manager.forceRecompute(reason: "guest.event")
        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(appliedTargets.values, [6656, 8192])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().pressure, .high)
    }

    func testActiveServicePressureRequestsBoundedServiceSliceReclaim() throws {
        let policy = Self.policy()
        let pressuredServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":2684354560,"sreclaimable_bytes":268435456,"container_memory_current":6442450944,"container_memory_peak":6442450944,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":6442450944,"service_cgroup_anon":3758096384,"service_cgroup_file":2684354560,"service_cgroup_inactive_file":2147483648,"service_cgroup_slab_reclaimable":268435456,"psi_some_avg10":1.0,"psi_full_avg10":0.1,"active_workloads":3,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_api","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_api.slice","memory_current":2147483648,"anon":2130706432,"file":16777216,"inactive_file":16777216,"active_file":0,"slab_reclaimable":0,"slab_unreclaimable":0,"working_set":2130706432,"reclaimable":16777216,"populated":true},{"key":"chum_mem_postgres","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_postgres.slice","memory_current":4294967296,"anon":1610612736,"file":2415919104,"inactive_file":2147483648,"active_file":268435456,"slab_reclaimable":268435456,"slab_unreclaimable":0,"working_set":1879048192,"reclaimable":2415919104,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: pressuredServiceMetricsBody,
            reclaimBody: #"{"accepted":false,"epoch":1,"state":"ignored","source":"test"}"#,
            serviceSlicesBody: serviceSlicesBody
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

        XCTAssertEqual(connector.reclaimRequests, 0)
        XCTAssertEqual(connector.serviceReclaimRequests, 1)
        XCTAssertTrue(connector.lastRequest.contains("/conjet-memory-reclaim/service"))
        XCTAssertTrue(connector.lastRequest.contains("key=chum_mem_postgres"))
        XCTAssertTrue(connector.lastRequest.contains("bytes=1073741824"))
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().pressure, .high)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "service-slice-reclaim" } == true)
    }

    func testIncompleteServiceSliceCoverageFallsBackToAggregateReclaim() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":6442450944,"container_memory_peak":6442450944,"container_inactive_file":3221225472,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":6442450944,"service_cgroup_anon":3221225472,"service_cgroup_file":3221225472,"service_cgroup_inactive_file":3221225472,"service_cgroup_slab_reclaimable":268435456,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":3,"build_workload_detected":false,"source":"test"}
        """
        let partialServiceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_tiny","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_tiny.slice","memory_current":3145728,"anon":3145728,"file":0,"inactive_file":0,"active_file":0,"slab_reclaimable":0,"slab_unreclaimable":0,"working_set":3145728,"reclaimable":0,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: serviceMetricsBody,
            serviceSlicesBody: partialServiceSlicesBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(11 * 1024 * 1024 * 1024),
            UInt64(11 * 1024 * 1024 * 1024)
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

        let status = manager.status()
        XCTAssertEqual(connector.reclaimRequests, 2)
        XCTAssertEqual(connector.serviceReclaimRequests, 0)
        XCTAssertTrue(connector.lastRequest.contains("/conjet-memory-reclaim?reason="))
        XCTAssertTrue(connector.lastRequest.contains("aggregate-incomplete-telemetry"))
        XCTAssertEqual(appliedTargets.values, [4096])
        XCTAssertEqual(status.currentTargetMiB, 4096)
        XCTAssertEqual(status.balloonedMiB, 4096)
        XCTAssertEqual(status.serviceSliceTelemetryComplete, false)
        XCTAssertEqual(status.serviceSliceCoveredMiB, 3)
        XCTAssertEqual(status.serviceSliceUncoveredMiB, 6141)
        XCTAssertTrue(status.trace?.contains { $0.action == "aggregate-reclaim" } == true)
        XCTAssertTrue(status.trace?.contains { $0.action == "idle-autodrop" } == true)
    }

    func testActiveServiceFootprintOverTargetRequestsBoundedServiceSliceReclaim() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":2684354560,"sreclaimable_bytes":268435456,"container_memory_current":6442450944,"container_memory_peak":6442450944,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":6442450944,"service_cgroup_anon":3758096384,"service_cgroup_file":2684354560,"service_cgroup_inactive_file":2147483648,"service_cgroup_slab_reclaimable":268435456,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":3,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_postgres","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_postgres.slice","memory_current":4294967296,"anon":1610612736,"file":2415919104,"inactive_file":2147483648,"active_file":268435456,"slab_reclaimable":268435456,"slab_unreclaimable":0,"working_set":1879048192,"reclaimable":2415919104,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: serviceMetricsBody,
            reclaimBody: #"{"accepted":false,"epoch":1,"state":"ignored","source":"test"}"#,
            serviceSlicesBody: serviceSlicesBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(11 * 1024 * 1024 * 1024)
        ])
        let appliedTargets = AppliedMemoryTargets()
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { bytes in
                appliedTargets.append(Int(bytes / 1024 / 1024))
            },
            hostFootprintBytes: { footprintSamples.next() }
        )

        try manager.forceRecompute(reason: "guest.event")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(connector.serviceReclaimRequests, 1)
        XCTAssertTrue(connector.lastRequest.contains("/conjet-memory-reclaim/service"))
        XCTAssertTrue(connector.lastRequest.contains("key=chum_mem_postgres"))
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().hostFootprintMiB, 11264)
        XCTAssertEqual(manager.status().pressure, .low)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "reclaim" } == true)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "service-slice-reclaim" } == true)
    }

    func testActiveServiceFootprintOverTargetAppliesDemandTargetAfterServiceReclaim() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":6442450944,"container_memory_peak":6442450944,"container_inactive_file":3221225472,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":6442450944,"service_cgroup_anon":3221225472,"service_cgroup_file":3221225472,"service_cgroup_inactive_file":3221225472,"service_cgroup_slab_reclaimable":268435456,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":3,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_postgres","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_postgres.slice","memory_current":6442450944,"anon":3221225472,"file":3221225472,"inactive_file":3221225472,"active_file":0,"slab_reclaimable":268435456,"slab_unreclaimable":0,"working_set":3221225472,"reclaimable":3489660928,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: serviceMetricsBody,
            serviceSlicesBody: serviceSlicesBody
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let footprintSamples = HostFootprintSamples([
            UInt64(11 * 1024 * 1024 * 1024),
            UInt64(11 * 1024 * 1024 * 1024),
            UInt64(11 * 1024 * 1024 * 1024),
            UInt64(11 * 1024 * 1024 * 1024)
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

        let status = manager.status()
        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(connector.serviceReclaimRequests, 1)
        XCTAssertTrue(connector.lastRequest.contains("/conjet-memory-reclaim/service"))
        XCTAssertEqual(appliedTargets.values, [4096])
        XCTAssertEqual(status.currentTargetMiB, 4096)
        XCTAssertEqual(status.balloonedMiB, 4096)
        XCTAssertEqual(status.pressure, .low)
        XCTAssertTrue(status.trace?.contains { $0.action == "service-slice-reclaim" } == true)
        XCTAssertTrue(status.trace?.contains { $0.action == "idle-autodrop" } == true)
    }

    func testStoppedServiceResidualSliceRequestsServiceReclaim() throws {
        let policy = Self.policy()
        let stoppedServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":7516192768,"mem_free":1073741824,"page_cache_bytes":1073741824,"sreclaimable_bytes":67108864,"container_memory_current":3145728,"container_memory_peak":6442450944,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":1073741824,"service_cgroup_anon":0,"service_cgroup_file":1073741824,"service_cgroup_inactive_file":805306368,"service_cgroup_slab_reclaimable":67108864,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_postgres","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_postgres.slice","memory_current":1073741824,"anon":0,"file":1073741824,"inactive_file":805306368,"active_file":268435456,"slab_reclaimable":67108864,"slab_unreclaimable":0,"working_set":201326592,"reclaimable":872415232,"populated":false}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: stoppedServiceMetricsBody,
            reclaimBody: #"{"accepted":false,"epoch":1,"state":"ignored","source":"test"}"#,
            serviceSlicesBody: serviceSlicesBody
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

        try manager.forceRecompute(reason: "docker.containerStopped")

        XCTAssertEqual(connector.serviceReclaimRequests, 1)
        XCTAssertTrue(connector.lastRequest.contains("/conjet-memory-reclaim/service"))
        XCTAssertTrue(connector.lastRequest.contains("reason=docker.containerStopped.slices"))
        XCTAssertTrue(connector.lastRequest.contains("key=chum_mem_postgres"))
        XCTAssertTrue(connector.lastRequest.contains("bytes=872415232"))
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().guestWorkloadDetected, false)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "service-slice-reclaim" } == true)
    }

    func testGuestEventReclaimsStoppedServiceResidualSlice() throws {
        let policy = Self.policy()
        let stoppedServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":7516192768,"mem_free":1073741824,"page_cache_bytes":1073741824,"sreclaimable_bytes":67108864,"container_memory_current":3145728,"container_memory_peak":6442450944,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":1073741824,"service_cgroup_anon":0,"service_cgroup_file":1073741824,"service_cgroup_inactive_file":805306368,"service_cgroup_slab_reclaimable":67108864,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_postgres","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_postgres.slice","memory_current":1073741824,"anon":0,"file":1073741824,"inactive_file":805306368,"active_file":268435456,"slab_reclaimable":67108864,"slab_unreclaimable":0,"working_set":201326592,"reclaimable":872415232,"populated":false}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: stoppedServiceMetricsBody,
            reclaimBody: #"{"accepted":false,"epoch":1,"state":"ignored","source":"test"}"#,
            serviceSlicesBody: serviceSlicesBody
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

        XCTAssertEqual(connector.serviceReclaimRequests, 1)
        XCTAssertTrue(connector.lastRequest.contains("/conjet-memory-reclaim/service"))
        XCTAssertTrue(connector.lastRequest.contains("reason=guest.event.slices"))
        XCTAssertTrue(connector.lastRequest.contains("key=chum_mem_postgres"))
        XCTAssertTrue(connector.lastRequest.contains("bytes=872415232"))
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().guestWorkloadDetected, false)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "service-slice-reclaim" } == true)
    }

    func testActiveServicePressureDoesNotReclaimAnonymousOnlySlice() throws {
        let policy = Self.policy()
        let pressuredServiceMetricsBody = """
        {"mem_total":8589934592,"mem_available":5368709120,"mem_free":1073741824,"page_cache_bytes":67108864,"sreclaimable_bytes":0,"container_memory_current":3221225472,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":3221225472,"service_cgroup_anon":3221225472,"service_cgroup_file":0,"service_cgroup_inactive_file":0,"service_cgroup_slab_reclaimable":0,"psi_some_avg10":1.0,"psi_full_avg10":0.1,"active_workloads":2,"build_workload_detected":false,"source":"test"}
        """
        let serviceSlicesBody = """
        {"version":1,"slices":[{"key":"chum_mem_api","path":"/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_api.slice","memory_current":3221225472,"anon":3221225472,"file":0,"inactive_file":0,"active_file":0,"slab_reclaimable":0,"slab_unreclaimable":0,"working_set":3221225472,"reclaimable":0,"populated":true}],"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: pressuredServiceMetricsBody,
            serviceSlicesBody: serviceSlicesBody
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

        XCTAssertEqual(connector.reclaimRequests, 0)
        XCTAssertEqual(connector.serviceReclaimRequests, 0)
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertEqual(manager.status().pressure, .high)
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

    func testRustVMMBalloonMetricsAppearInRuntimeStatus() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":67108864,"sreclaimable_bytes":33554432,"container_memory_current":0,"container_memory_peak":4294967296,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(body: idleMetricsBody)
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in },
            vmmRuntimeMetrics: {
                DynamicMemoryVMMRuntimeMetrics(
                    hostResidentBytes: UInt64(512 * 1024 * 1024),
                    hostPhysicalFootprintBytes: UInt64(1536 * 1024 * 1024),
                    balloonActualPages: 131_072,
                    balloonInflatePages: 262_144,
                    balloonDeflatePages: 4_096,
                    balloonReportedFreePages: 65_536,
                    balloonReportedFreeBytes: UInt64(512 * 1024 * 1024),
                    balloonReclaimedBytes: UInt64(768 * 1024 * 1024),
                    balloonReportedFreeReclaimedBytes: UInt64(256 * 1024 * 1024),
                    balloonSoftReclaimedBytes: UInt64(128 * 1024 * 1024),
                    balloonHardDecommittedBytes: UInt64(640 * 1024 * 1024),
                    balloonOwnedReclaimedBytes: UInt64(384 * 1024 * 1024),
                    balloonReportInFlightReclaimedBytes: UInt64(384 * 1024 * 1024),
                    balloonReclaimFailures: 2,
                    balloonMalformedReports: 3,
                    balloonPageReportingReady: true,
                    balloonFreePageHintReady: false,
                    memoryLedger: ConjetMemoryLedgerStatus(
                        guestVisibleBytes: UInt64(8192 * 1024 * 1024),
                        hostGranuleBytes: 16_384,
                        hostGranules: 524_288,
                        residentBytes: UInt64(512 * 1024 * 1024),
                        guestOwnedBytes: UInt64(384 * 1024 * 1024),
                        pinnedBytes: UInt64(128 * 1024 * 1024),
                        balloonOwnedBytes: UInt64(256 * 1024 * 1024),
                        reportInFlightBytes: 0,
                        discardedSoftBytes: UInt64(128 * 1024 * 1024),
                        discardedHardZeroBytes: UInt64(7552 * 1024 * 1024),
                        cumulativeSoftDiscardedBytes: UInt64(128 * 1024 * 1024),
                        cumulativeHardDecommittedBytes: UInt64(640 * 1024 * 1024),
                        cumulativeBalloonAuthorizedBytes: UInt64(384 * 1024 * 1024),
                        cumulativeReportAuthorizedBytes: UInt64(384 * 1024 * 1024),
                        guestOwnedReclaimedBytes: 0,
                        pinnedReclaimedBytes: 0,
                        reclaimWithoutAuthorityBytes: 0,
                        reportAckedBeforeReclaimBytes: 0,
                        stateSumMismatchBytes: 0,
                        ok: true
                    )
                )
            },
            hostFootprintConvergenceDelays: [0]
        )

        try manager.forceRecompute(reason: "manual.vmm")

        let status = manager.status()
        XCTAssertEqual(status.hostFootprintMiB, 1536)
        XCTAssertEqual(status.hostResidentMiB, 512)
        XCTAssertEqual(status.balloonActualMiB, 512)
        XCTAssertEqual(status.balloonInflatePages, 262_144)
        XCTAssertEqual(status.balloonDeflatePages, 4_096)
        XCTAssertEqual(status.balloonReportedFreePages, 65_536)
        XCTAssertEqual(status.balloonReportedFreeMiB, 512)
        XCTAssertEqual(status.balloonReclaimedMiB, 768)
        XCTAssertEqual(status.balloonReportedFreeReclaimedMiB, 256)
        XCTAssertEqual(status.balloonSoftReclaimedMiB, 128)
        XCTAssertEqual(status.balloonHardDecommittedMiB, 640)
        XCTAssertEqual(status.balloonOwnedReclaimedMiB, 384)
        XCTAssertEqual(status.balloonReportInFlightReclaimedMiB, 384)
        XCTAssertEqual(status.balloonReclaimFailures, 2)
        XCTAssertEqual(status.balloonMalformedReports, 3)
        XCTAssertEqual(status.balloonPageReportingReady, true)
        XCTAssertEqual(status.balloonFreePageHintReady, false)
        XCTAssertEqual(status.memoryLedger?.guestVisibleBytes, UInt64(8192 * 1024 * 1024))
        XCTAssertEqual(status.memoryLedger?.hostGranuleBytes, 16_384)
        XCTAssertEqual(status.memoryLedger?.cumulativeHardDecommittedBytes, UInt64(640 * 1024 * 1024))
        XCTAssertEqual(status.memoryLedger?.cumulativeReportAuthorizedBytes, UInt64(384 * 1024 * 1024))
        XCTAssertEqual(status.memoryLedger?.guestOwnedReclaimedBytes, 0)
        XCTAssertEqual(status.memoryLedger?.ok, true)
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

    func testGuestEventStreamReconnectsAfterUnavailableResponse() throws {
        let policy = Self.policy()
        let idleMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":0,"container_memory_peak":4294967296,"daemon_cgroup_memory_current":268435456,"service_cgroup_memory_current":0,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":0,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: idleMetricsBody,
            eventResponses: [
                StaticHTTPGuestResponse(statusCode: 503, body: #"{"error":"unavailable"}"#),
                StaticHTTPGuestResponse(statusCode: 200, body: idleMetricsBody)
            ]
        )
        let metricsClient = GuestMemoryMetricsClient(connector: connector)
        let manager = DynamicMemoryManager(
            policy: policy,
            metricsClient: metricsClient,
            setTargetBytes: { _ in },
            eventStreamReconnectBaseDelay: 0.01,
            eventStreamReconnectMaxDelay: 0.02
        )

        manager.start(initialMetrics: GuestMemoryMetrics(
            memTotalBytes: 8 * 1024 * 1024 * 1024,
            memAvailableBytes: 6 * 1024 * 1024 * 1024
        ))
        defer { manager.stop() }

        XCTAssertTrue(waitUntil(timeoutSeconds: 2) {
            connector.eventStreamRequests >= 2
                && (manager.status().guestEventStreamFailures ?? 0) >= 1
        })
        let status = manager.status()
        XCTAssertGreaterThanOrEqual(status.guestEventStreamReconnects ?? 0, 1)
        XCTAssertNotEqual(status.guestEventStreamState, "disabled")
    }

    func testHostPressureActiveServiceAggregateReclaimsInactiveMemoryWithoutTargetDrop() throws {
        let policy = Self.policy()
        let serviceMetricsBody = """
        {"mem_total":8589934592,"mem_available":6442450944,"mem_free":1073741824,"page_cache_bytes":3221225472,"sreclaimable_bytes":268435456,"container_memory_current":4294967296,"container_memory_peak":6442450944,"container_inactive_file":2147483648,"daemon_cgroup_memory_current":180355072,"service_cgroup_memory_current":4294967296,"service_cgroup_anon":1879048192,"service_cgroup_file":2415919104,"service_cgroup_inactive_file":2147483648,"service_cgroup_slab_reclaimable":268435456,"psi_some_avg10":0.0,"psi_full_avg10":0.0,"active_workloads":3,"build_workload_detected":false,"source":"test"}
        """
        let connector = StaticHTTPGuestConnectionConnector(
            body: serviceMetricsBody,
            reclaimBody: #"{"accepted":false,"epoch":1,"state":"ignored","source":"test"}"#,
            serviceSlicesBody: #"{"version":1,"slices":[],"source":"test"}"#
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

        try manager.forceRecompute(reason: "host.pressure.elevated")

        XCTAssertEqual(connector.reclaimRequests, 1)
        XCTAssertEqual(connector.serviceReclaimRequests, 0)
        XCTAssertTrue(connector.lastRequest.contains("reason=host.pressure.elevated"))
        XCTAssertEqual(appliedTargets.values, [])
        XCTAssertEqual(manager.status().currentTargetMiB, 8192)
        XCTAssertTrue(manager.status().trace?.contains { $0.action == "reclaim" && $0.reason == "host.pressure.elevated" } == true)
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

private struct StaticHTTPGuestResponse {
    var statusCode: Int
    var body: String
}

private final class StaticHTTPGuestConnectionConnector: GuestConnectionConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var body: String
    private var reclaimBody: String
    private var reclaimStatusBody: String
    private var serviceSlicesBody: String
    private var eventResponses: [StaticHTTPGuestResponse]
    private var reclaimStatusCode: Int
    private var capturedEventStreamRequests = 0
    private var capturedReclaimRequests = 0
    private var capturedServiceReclaimRequests = 0
    private var capturedReclaimCancelRequests = 0
    private var capturedReclaimStatusRequests = 0
    private var capturedServiceSlicesRequests = 0
    private var capturedLastRequest = ""

    var reclaimRequests: Int {
        lock.lock()
        let value = capturedReclaimRequests
        lock.unlock()
        return value
    }

    var serviceReclaimRequests: Int {
        lock.lock()
        let value = capturedServiceReclaimRequests
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

    var serviceSlicesRequests: Int {
        lock.lock()
        let value = capturedServiceSlicesRequests
        lock.unlock()
        return value
    }

    var eventStreamRequests: Int {
        lock.lock()
        let value = capturedEventStreamRequests
        lock.unlock()
        return value
    }

    init(
        body: String,
        reclaimBody: String? = nil,
        reclaimStatusBody: String? = nil,
        serviceSlicesBody: String? = nil,
        eventResponses: [StaticHTTPGuestResponse] = [],
        reclaimStatusCode: Int = 202
    ) {
        self.body = body
        self.reclaimBody = reclaimBody ?? #"{"accepted":true,"epoch":1,"state":"queued","source":"test"}"#
        self.reclaimStatusBody = reclaimStatusBody ?? #"{"epoch":1,"state":"done","requested_bytes":67108864,"observed_current_drop_bytes":67108864,"source":"test"}"#
        self.serviceSlicesBody = serviceSlicesBody ?? #"{"version":1,"slices":[],"source":"test"}"#
        self.eventResponses = eventResponses
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

    func setServiceSlicesBody(_ body: String) {
        lock.lock()
        self.serviceSlicesBody = body
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
        if request.contains("/conjet-memory-events") {
            capturedEventStreamRequests += 1
            if eventResponses.isEmpty {
                snapshot = body
                statusCode = 200
            } else {
                let response = eventResponses.removeFirst()
                snapshot = response.body
                statusCode = response.statusCode
            }
        } else if request.contains("/conjet-memory-service-slices") {
            capturedServiceSlicesRequests += 1
            snapshot = serviceSlicesBody
            statusCode = 200
        } else if request.contains("/conjet-memory-reclaim/cancel-before") {
            capturedLastRequest = request
            capturedReclaimCancelRequests += 1
            snapshot = #"{"epoch":2,"state":"cancelled","requested_bytes":0,"observed_current_drop_bytes":0,"source":"test"}"#
            statusCode = 200
        } else if request.contains("/conjet-memory-reclaim/status") {
            capturedReclaimStatusRequests += 1
            snapshot = reclaimStatusBody
            statusCode = 200
        } else if request.contains("/conjet-memory-reclaim/service") {
            capturedLastRequest = request
            capturedServiceReclaimRequests += 1
            snapshot = reclaimBody
            statusCode = reclaimStatusCode
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

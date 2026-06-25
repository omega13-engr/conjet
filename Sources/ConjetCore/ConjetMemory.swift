import Foundation

public enum ConjetMemoryPressureState: String, Codable, Equatable, Sendable {
    case unknown
    case low
    case elevated
    case high
    case stale
}

public struct GuestMemoryMetrics: Codable, Equatable, Sendable {
    public var memTotalBytes: UInt64
    public var memAvailableBytes: UInt64
    public var memFreeBytes: UInt64
    public var pageCacheBytes: UInt64
    public var sReclaimableBytes: UInt64
    public var swapTotalBytes: UInt64
    public var swapFreeBytes: UInt64
    public var diskSwapTotalBytes: UInt64
    public var diskSwapFreeBytes: UInt64
    public var zramOrigDataSizeBytes: UInt64
    public var zramComprDataSizeBytes: UInt64
    public var zramMemUsedTotalBytes: UInt64
    public var containerMemoryCurrentBytes: UInt64
    public var containerMemoryPeakBytes: UInt64
    public var containerAnonBytes: UInt64
    public var containerFileBytes: UInt64
    public var containerInactiveFileBytes: UInt64
    public var containerActiveFileBytes: UInt64
    public var containerSlabReclaimableBytes: UInt64
    public var containerSlabUnreclaimableBytes: UInt64
    public var containerSwapCurrentBytes: UInt64
    public var containerMemoryHighEvents: UInt64
    public var containerOOMEvents: UInt64
    public var containerOOMKillEvents: UInt64
    public var buildCgroupMemoryCurrentBytes: UInt64
    public var daemonCgroupMemoryCurrentBytes: UInt64
    public var serviceCgroupMemoryCurrentBytes: UInt64
    public var psiSomeAvg10: Double
    public var psiFullAvg10: Double
    public var activeWorkloads: Int
    public var buildWorkloadDetected: Bool
    public var source: String

    private enum CodingKeys: String, CodingKey {
        case memTotalBytes = "mem_total"
        case memAvailableBytes = "mem_available"
        case memFreeBytes = "mem_free"
        case pageCacheBytes = "page_cache_bytes"
        case sReclaimableBytes = "sreclaimable_bytes"
        case swapTotalBytes = "swap_total"
        case swapFreeBytes = "swap_free"
        case diskSwapTotalBytes = "disk_swap_total"
        case diskSwapFreeBytes = "disk_swap_free"
        case zramOrigDataSizeBytes = "zram_orig_data_size"
        case zramComprDataSizeBytes = "zram_compr_data_size"
        case zramMemUsedTotalBytes = "zram_mem_used_total"
        case containerMemoryCurrentBytes = "container_memory_current"
        case containerMemoryPeakBytes = "container_memory_peak"
        case containerAnonBytes = "container_anon"
        case containerFileBytes = "container_file"
        case containerInactiveFileBytes = "container_inactive_file"
        case containerActiveFileBytes = "container_active_file"
        case containerSlabReclaimableBytes = "container_slab_reclaimable"
        case containerSlabUnreclaimableBytes = "container_slab_unreclaimable"
        case containerSwapCurrentBytes = "container_swap_current"
        case containerMemoryHighEvents = "container_memory_high_events"
        case containerOOMEvents = "container_memory_oom_events"
        case containerOOMKillEvents = "container_memory_oom_kill_events"
        case buildCgroupMemoryCurrentBytes = "build_cgroup_memory_current"
        case daemonCgroupMemoryCurrentBytes = "daemon_cgroup_memory_current"
        case serviceCgroupMemoryCurrentBytes = "service_cgroup_memory_current"
        case psiSomeAvg10 = "psi_some_avg10"
        case psiFullAvg10 = "psi_full_avg10"
        case activeWorkloads = "active_workloads"
        case buildWorkloadDetected = "build_workload_detected"
        case source
    }

    public init(
        memTotalBytes: UInt64,
        memAvailableBytes: UInt64,
        memFreeBytes: UInt64 = 0,
        pageCacheBytes: UInt64 = 0,
        sReclaimableBytes: UInt64 = 0,
        swapTotalBytes: UInt64 = 0,
        swapFreeBytes: UInt64 = 0,
        diskSwapTotalBytes: UInt64 = 0,
        diskSwapFreeBytes: UInt64 = 0,
        zramOrigDataSizeBytes: UInt64 = 0,
        zramComprDataSizeBytes: UInt64 = 0,
        zramMemUsedTotalBytes: UInt64 = 0,
        containerMemoryCurrentBytes: UInt64 = 0,
        containerMemoryPeakBytes: UInt64 = 0,
        containerAnonBytes: UInt64 = 0,
        containerFileBytes: UInt64 = 0,
        containerInactiveFileBytes: UInt64 = 0,
        containerActiveFileBytes: UInt64 = 0,
        containerSlabReclaimableBytes: UInt64 = 0,
        containerSlabUnreclaimableBytes: UInt64 = 0,
        containerSwapCurrentBytes: UInt64 = 0,
        containerMemoryHighEvents: UInt64 = 0,
        containerOOMEvents: UInt64 = 0,
        containerOOMKillEvents: UInt64 = 0,
        buildCgroupMemoryCurrentBytes: UInt64 = 0,
        daemonCgroupMemoryCurrentBytes: UInt64 = 0,
        serviceCgroupMemoryCurrentBytes: UInt64 = 0,
        psiSomeAvg10: Double = 0,
        psiFullAvg10: Double = 0,
        activeWorkloads: Int = 0,
        buildWorkloadDetected: Bool = false,
        source: String = "guest"
    ) {
        self.memTotalBytes = memTotalBytes
        self.memAvailableBytes = memAvailableBytes
        self.memFreeBytes = memFreeBytes
        self.pageCacheBytes = pageCacheBytes
        self.sReclaimableBytes = sReclaimableBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapFreeBytes = swapFreeBytes
        self.diskSwapTotalBytes = diskSwapTotalBytes
        self.diskSwapFreeBytes = diskSwapFreeBytes
        self.zramOrigDataSizeBytes = zramOrigDataSizeBytes
        self.zramComprDataSizeBytes = zramComprDataSizeBytes
        self.zramMemUsedTotalBytes = zramMemUsedTotalBytes
        self.containerMemoryCurrentBytes = containerMemoryCurrentBytes
        self.containerMemoryPeakBytes = containerMemoryPeakBytes
        self.containerAnonBytes = containerAnonBytes
        self.containerFileBytes = containerFileBytes
        self.containerInactiveFileBytes = containerInactiveFileBytes
        self.containerActiveFileBytes = containerActiveFileBytes
        self.containerSlabReclaimableBytes = containerSlabReclaimableBytes
        self.containerSlabUnreclaimableBytes = containerSlabUnreclaimableBytes
        self.containerSwapCurrentBytes = containerSwapCurrentBytes
        self.containerMemoryHighEvents = containerMemoryHighEvents
        self.containerOOMEvents = containerOOMEvents
        self.containerOOMKillEvents = containerOOMKillEvents
        self.buildCgroupMemoryCurrentBytes = buildCgroupMemoryCurrentBytes
        self.daemonCgroupMemoryCurrentBytes = daemonCgroupMemoryCurrentBytes
        self.serviceCgroupMemoryCurrentBytes = serviceCgroupMemoryCurrentBytes
        self.psiSomeAvg10 = psiSomeAvg10
        self.psiFullAvg10 = psiFullAvg10
        self.activeWorkloads = activeWorkloads
        self.buildWorkloadDetected = buildWorkloadDetected
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.memTotalBytes = try container.decodeIfPresent(UInt64.self, forKey: .memTotalBytes) ?? 0
        self.memAvailableBytes = try container.decodeIfPresent(UInt64.self, forKey: .memAvailableBytes) ?? 0
        self.memFreeBytes = try container.decodeIfPresent(UInt64.self, forKey: .memFreeBytes) ?? 0
        self.pageCacheBytes = try container.decodeIfPresent(UInt64.self, forKey: .pageCacheBytes) ?? 0
        self.sReclaimableBytes = try container.decodeIfPresent(UInt64.self, forKey: .sReclaimableBytes) ?? 0
        self.swapTotalBytes = try container.decodeIfPresent(UInt64.self, forKey: .swapTotalBytes) ?? 0
        self.swapFreeBytes = try container.decodeIfPresent(UInt64.self, forKey: .swapFreeBytes) ?? 0
        self.diskSwapTotalBytes = try container.decodeIfPresent(UInt64.self, forKey: .diskSwapTotalBytes) ?? 0
        self.diskSwapFreeBytes = try container.decodeIfPresent(UInt64.self, forKey: .diskSwapFreeBytes) ?? 0
        self.zramOrigDataSizeBytes = try container.decodeIfPresent(UInt64.self, forKey: .zramOrigDataSizeBytes) ?? 0
        self.zramComprDataSizeBytes = try container.decodeIfPresent(UInt64.self, forKey: .zramComprDataSizeBytes) ?? 0
        self.zramMemUsedTotalBytes = try container.decodeIfPresent(UInt64.self, forKey: .zramMemUsedTotalBytes) ?? 0
        self.containerMemoryCurrentBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerMemoryCurrentBytes) ?? 0
        self.containerMemoryPeakBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerMemoryPeakBytes) ?? 0
        self.containerAnonBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerAnonBytes) ?? 0
        self.containerFileBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerFileBytes) ?? 0
        self.containerInactiveFileBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerInactiveFileBytes) ?? 0
        self.containerActiveFileBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerActiveFileBytes) ?? 0
        self.containerSlabReclaimableBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerSlabReclaimableBytes) ?? 0
        self.containerSlabUnreclaimableBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerSlabUnreclaimableBytes) ?? 0
        self.containerSwapCurrentBytes = try container.decodeIfPresent(UInt64.self, forKey: .containerSwapCurrentBytes) ?? 0
        self.containerMemoryHighEvents = try container.decodeIfPresent(UInt64.self, forKey: .containerMemoryHighEvents) ?? 0
        self.containerOOMEvents = try container.decodeIfPresent(UInt64.self, forKey: .containerOOMEvents) ?? 0
        self.containerOOMKillEvents = try container.decodeIfPresent(UInt64.self, forKey: .containerOOMKillEvents) ?? 0
        self.buildCgroupMemoryCurrentBytes = try container.decodeIfPresent(UInt64.self, forKey: .buildCgroupMemoryCurrentBytes) ?? 0
        self.daemonCgroupMemoryCurrentBytes = try container.decodeIfPresent(UInt64.self, forKey: .daemonCgroupMemoryCurrentBytes) ?? 0
        self.serviceCgroupMemoryCurrentBytes = try container.decodeIfPresent(UInt64.self, forKey: .serviceCgroupMemoryCurrentBytes) ?? 0
        self.psiSomeAvg10 = try container.decodeIfPresent(Double.self, forKey: .psiSomeAvg10) ?? 0
        self.psiFullAvg10 = try container.decodeIfPresent(Double.self, forKey: .psiFullAvg10) ?? 0
        self.activeWorkloads = try container.decodeIfPresent(Int.self, forKey: .activeWorkloads) ?? 0
        self.buildWorkloadDetected = try container.decodeIfPresent(Bool.self, forKey: .buildWorkloadDetected) ?? false
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "guest"
    }

    public var diskSwapUsedBytes: UInt64 {
        diskSwapTotalBytes > diskSwapFreeBytes ? diskSwapTotalBytes - diskSwapFreeBytes : 0
    }
}

public struct ConjetMemoryTraceEvent: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var targetMiB: Int
    public var desiredMiB: Int
    public var action: String
    public var reason: String
    public var pressure: ConjetMemoryPressureState
    public var hostFootprintBeforeBytes: UInt64?
    public var hostFootprintAfterBytes: UInt64?
    public var hostFootprintDropBytes: UInt64?

    public init(
        timestamp: Date,
        targetMiB: Int,
        desiredMiB: Int,
        action: String,
        reason: String,
        pressure: ConjetMemoryPressureState,
        hostFootprintBeforeBytes: UInt64? = nil,
        hostFootprintAfterBytes: UInt64? = nil,
        hostFootprintDropBytes: UInt64? = nil
    ) {
        self.timestamp = timestamp
        self.targetMiB = targetMiB
        self.desiredMiB = desiredMiB
        self.action = action
        self.reason = reason
        self.pressure = pressure
        self.hostFootprintBeforeBytes = hostFootprintBeforeBytes
        self.hostFootprintAfterBytes = hostFootprintAfterBytes
        self.hostFootprintDropBytes = hostFootprintDropBytes
    }
}

public struct ConjetQueueRuntimeMetrics: Codable, Equatable, Sendable {
    public var bufferedCount: Int
    public var bufferedBytes: Int
    public var highWaterCount: Int
    public var highWaterBytes: Int
    public var droppedCount: Int
    public var droppedBytes: Int

    public init(
        bufferedCount: Int,
        bufferedBytes: Int,
        highWaterCount: Int,
        highWaterBytes: Int,
        droppedCount: Int,
        droppedBytes: Int
    ) {
        self.bufferedCount = bufferedCount
        self.bufferedBytes = bufferedBytes
        self.highWaterCount = highWaterCount
        self.highWaterBytes = highWaterBytes
        self.droppedCount = droppedCount
        self.droppedBytes = droppedBytes
    }
}

public struct ConjetMemoryRuntimeStatus: Codable, Equatable, Sendable {
    public var dynamicEnabled: Bool
    public var mode: ConjetMemoryProfile
    public var maxMiB: Int
    public var minMiB: Int
    public var currentTargetMiB: Int
    public var balloonedMiB: Int
    public var hostFootprintMiB: Int?
    public var balloonActualMiB: Int?
    public var hostReclaimedMiB: Int?
    public var balloonInflatePages: UInt64?
    public var balloonDeflatePages: UInt64?
    public var balloonReportedFreePages: UInt64?
    public var balloonReportedFreeReclaimedMiB: Int?
    public var balloonReclaimFailures: UInt64?
    public var balloonMalformedReports: UInt64?
    public var queueMetrics: [String: ConjetQueueRuntimeMetrics]?
    public var guestAvailableMiB: Int?
    public var containerMemoryMiB: Int?
    public var buildCgroupMemoryMiB: Int?
    public var daemonCgroupMemoryMiB: Int?
    public var serviceCgroupMemoryMiB: Int?
    public var zramUsedMiB: Int?
    public var diskSwapUsedMiB: Int?
    public var pressure: ConjetMemoryPressureState
    public var activeDockerStreams: Int
    public var buildWorkloadDetected: Bool
    public var guestWorkloadDetected: Bool?
    public var lastAdjustmentReason: String?
    public var lastMetricsAt: Date?
    public var lastTargetChangeAt: Date?
    public var message: String?
    public var trace: [ConjetMemoryTraceEvent]?

    public init(
        dynamicEnabled: Bool,
        mode: ConjetMemoryProfile,
        maxMiB: Int,
        minMiB: Int,
        currentTargetMiB: Int,
        balloonedMiB: Int,
        hostFootprintMiB: Int? = nil,
        balloonActualMiB: Int? = nil,
        hostReclaimedMiB: Int? = nil,
        balloonInflatePages: UInt64? = nil,
        balloonDeflatePages: UInt64? = nil,
        balloonReportedFreePages: UInt64? = nil,
        balloonReportedFreeReclaimedMiB: Int? = nil,
        balloonReclaimFailures: UInt64? = nil,
        balloonMalformedReports: UInt64? = nil,
        queueMetrics: [String: ConjetQueueRuntimeMetrics]? = nil,
        guestAvailableMiB: Int? = nil,
        containerMemoryMiB: Int? = nil,
        buildCgroupMemoryMiB: Int? = nil,
        daemonCgroupMemoryMiB: Int? = nil,
        serviceCgroupMemoryMiB: Int? = nil,
        zramUsedMiB: Int? = nil,
        diskSwapUsedMiB: Int? = nil,
        pressure: ConjetMemoryPressureState = .unknown,
        activeDockerStreams: Int = 0,
        buildWorkloadDetected: Bool = false,
        guestWorkloadDetected: Bool? = nil,
        lastAdjustmentReason: String? = nil,
        lastMetricsAt: Date? = nil,
        lastTargetChangeAt: Date? = nil,
        message: String? = nil,
        trace: [ConjetMemoryTraceEvent]? = nil
    ) {
        self.dynamicEnabled = dynamicEnabled
        self.mode = mode
        self.maxMiB = maxMiB
        self.minMiB = minMiB
        self.currentTargetMiB = currentTargetMiB
        self.balloonedMiB = balloonedMiB
        self.hostFootprintMiB = hostFootprintMiB
        self.balloonActualMiB = balloonActualMiB
        self.hostReclaimedMiB = hostReclaimedMiB
        self.balloonInflatePages = balloonInflatePages
        self.balloonDeflatePages = balloonDeflatePages
        self.balloonReportedFreePages = balloonReportedFreePages
        self.balloonReportedFreeReclaimedMiB = balloonReportedFreeReclaimedMiB
        self.balloonReclaimFailures = balloonReclaimFailures
        self.balloonMalformedReports = balloonMalformedReports
        self.queueMetrics = queueMetrics
        self.guestAvailableMiB = guestAvailableMiB
        self.containerMemoryMiB = containerMemoryMiB
        self.buildCgroupMemoryMiB = buildCgroupMemoryMiB
        self.daemonCgroupMemoryMiB = daemonCgroupMemoryMiB
        self.serviceCgroupMemoryMiB = serviceCgroupMemoryMiB
        self.zramUsedMiB = zramUsedMiB
        self.diskSwapUsedMiB = diskSwapUsedMiB
        self.pressure = pressure
        self.activeDockerStreams = activeDockerStreams
        self.buildWorkloadDetected = buildWorkloadDetected
        self.guestWorkloadDetected = guestWorkloadDetected
        self.lastAdjustmentReason = lastAdjustmentReason
        self.lastMetricsAt = lastMetricsAt
        self.lastTargetChangeAt = lastTargetChangeAt
        self.message = message
        self.trace = trace
    }
}

public struct ConjetMemoryStatus: Codable, Equatable, Sendable {
    public var policy: ConjetMemoryPolicy
    public var runtime: ConjetMemoryRuntimeStatus?

    public init(policy: ConjetMemoryPolicy, runtime: ConjetMemoryRuntimeStatus? = nil) {
        self.policy = policy
        self.runtime = runtime
    }
}

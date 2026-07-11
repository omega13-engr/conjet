use serde::Deserialize;
use serde::Serialize;
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Mutex,
};
use std::time::{Duration, Instant};

use crate::arch::aarch64;
use crate::devices::balloon::{
    self, BalloonMetrics, BalloonQueueHandler, BalloonRestoreMode, GuestMemoryReclaimer,
    IdleBackingCompactionReport, MemoryLedgerSummary, PageRange, ReclaimAuthority, ReclaimReport,
    RestoreReport,
};
use crate::devices::block::{BlockQueueHandler, RawBlockDevice};
use crate::devices::bus::{MmioDevice, MmioError};
use crate::devices::net::{NetQueue, NetQueueHandler, VmnetPacketBridge};
use crate::devices::pl011::Pl011Uart;
use crate::devices::psci::{PsciAction, PsciController};
use crate::devices::virtio::{
    default_device_plan, VirtioDeviceKind, VirtioMmioDevice, VirtioMmioDevicePlan,
};
use crate::devices::vsock::{
    self, HostUnixVsockBridge, VsockQueue, VsockQueueHandler, DEFAULT_GUEST_CID, MEMORY_BRIDGE_PORT,
};
use crate::hvf::ffi::{
    exit_vcpus, HvfError, Vcpu, Vm, HV_MEMORY_EXEC, HV_MEMORY_READ, HV_MEMORY_WRITE, HV_REG_CPSR,
    HV_REG_PC, HV_REG_X0, HV_REG_X1, HV_REG_X2, HV_REG_X3, HV_SYS_REG_MPIDR_EL1,
};
use crate::hvf::gic::{Gic, GicLayout, GicMmio};
use crate::vmm::boot::{load_boot_artifacts, BootArtifacts, BootPlan};
use crate::vmm::config::JetstreamConfig;
use crate::vmm::debug_flags;
use crate::vmm::docker_probe::{DockerProbeReport, DockerSocketReadinessProbe};
use crate::vmm::memory::GuestMemory;
use crate::vmm::vstate::VmState;

const HOST_RECLAIM_CHUNK_BYTES: u64 = 64 * 1024 * 1024;
const MAX_RETAINED_CONSOLE_BYTES: usize = 256 * 1024;
// Leave room for the Linux/Docker control plane and fixed VMM overhead so an
// otherwise idle Core returns below the host-side 700 MiB operating budget.
// Bulk Docker work restores configured capacity; populated services converge
// on a guarded working-set target without changing the stopped-idle floor.
const DEFAULT_CORE_IDLE_TARGET_MIB: u64 = 448;
const DEFAULT_CORE_IDLE_QUIET_DWELL: Duration = Duration::from_secs(8);
const DEFAULT_CORE_IDLE_RECLAIM_SETTLE_DWELL: Duration = Duration::from_secs(2);
const DEFAULT_CORE_IDLE_BACKING_COMPACTION_DWELL: Duration = Duration::from_secs(2);
const DEFAULT_CORE_IDLE_BACKING_COMPACTION_RETRY_DWELL: Duration = Duration::from_millis(250);
const DEFAULT_CORE_IDLE_RETRY_DWELL: Duration = Duration::from_secs(20);
const CORE_IDLE_SENTINEL_DWELL: Duration = Duration::from_secs(1);
const CORE_IDLE_WORKLOAD_NOISE_BYTES: u64 = 64 * 1024 * 1024;
const CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES: u64 = 64 * 1024 * 1024;
const CORE_CONTAINER_ZRAM_SWAP_BUDGET_BYTES: u64 = 8 * 1024 * 1024;
const DEFAULT_CORE_SERVICE_MIN_TARGET_MIB: u64 = 2048;
const DEFAULT_CORE_SERVICE_LEARNING_DWELL: Duration = Duration::from_secs(30);
const DEFAULT_CORE_SERVICE_PROBE_DWELL: Duration = Duration::from_secs(5);
const DEFAULT_CORE_SERVICE_STABILIZATION_DWELL: Duration = Duration::from_secs(10);
const CORE_SERVICE_CONVERGENCE_POLL_DWELL: Duration = Duration::from_secs(1);
const CORE_SERVICE_PRESSURE_WATCHDOG_DWELL: Duration = Duration::from_secs(1);
const CORE_SERVICE_SHRINK_CONVERGENCE_TIMEOUT: Duration = Duration::from_secs(30);
const CORE_SERVICE_EXPANSION_CONVERGENCE_RETRY_DWELL: Duration = Duration::from_secs(5);
const DEFAULT_CORE_SERVICE_SHRINK_STEP_MIB: u64 = 256;
const DEFAULT_CORE_SERVICE_HEADROOM_MIB: u64 = 512;
const DEFAULT_CORE_SERVICE_COOLDOWN_DWELL: Duration = Duration::from_secs(120);
const CORE_SERVICE_TARGET_QUANTUM_MIB: u64 = 128;
const CORE_SERVICE_AVAILABLE_RESERVE_MIB: u64 = 512;
const CORE_SERVICE_REFAULT_MIN_BYTES: u64 = 8 * 1024 * 1024;
const CORE_SERVICE_REFAULT_RATIO_DENOMINATOR: u64 = 50;
const CORE_SERVICE_MAX_LEARNED_HEADROOM_MIB: u64 = 1024;
const CORE_SERVICE_PSI_SOME_LIMIT: f64 = 1.0;
const CORE_SERVICE_PSI_FULL_LIMIT: f64 = 0.05;
const CORE_SERVICE_GLOBAL_PSI_SOME_LIMIT: f64 = 5.0;
const CORE_SERVICE_GLOBAL_PSI_FULL_LIMIT: f64 = 0.5;
const CORE_SERVICE_SAMPLE_WINDOW: usize = 6;
const CORE_RESTORE_RETRY_DWELL: Duration = Duration::from_millis(250);
const MIB_BYTES: u64 = 1024 * 1024;
const MAX_GUEST_MEMORY_RESPONSE_BYTES: usize = 64 * 1024;
const MAX_MEMORY_CONTROL_REQUEST_BYTES: usize = 4 * 1024;
const MEMORY_CONTROL_READ_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Serialize)]
pub struct HvfBootReport {
    pub ok: bool,
    pub message: String,
    pub boot_plan: BootPlan,
    pub boot_artifacts: Option<BootArtifacts>,
    pub exit_count: u64,
    pub console_output: String,
    pub docker_ready: bool,
    pub docker_probe: Option<DockerProbeReport>,
    pub balloon: BalloonMetrics,
    pub stages: Vec<HvfBootStage>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HvfBootStage {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub struct HvfBootOptions {
    pub max_exits: u64,
    pub max_runtime_ms: u64,
    pub host_tick_ms: u64,
    pub require_conjet_ready: bool,
    pub require_docker_ready: bool,
    pub docker_probe_timeout_ms: u64,
    pub hold_after_ready_ms: u64,
    pub hold_after_ready_forever: bool,
    pub balloon_target_mib: Option<u64>,
    pub memory_control_socket: Option<PathBuf>,
}

impl Default for HvfBootOptions {
    fn default() -> Self {
        Self {
            max_exits: 16_384,
            max_runtime_ms: 30_000,
            host_tick_ms: 0,
            require_conjet_ready: true,
            require_docker_ready: false,
            docker_probe_timeout_ms: 0,
            hold_after_ready_ms: 0,
            hold_after_ready_forever: false,
            balloon_target_mib: None,
            memory_control_socket: None,
        }
    }
}

struct BootVcpu {
    vcpu: Vcpu,
    active: bool,
}

struct SecondaryVcpu {
    start_tx: mpsc::Sender<SecondaryStart>,
}

struct SecondaryStart {
    entry_point: u64,
    context_id: u64,
}

struct SecondaryReady {
    cpu_index: u8,
    result: Result<u64, String>,
}

struct SharedBootState {
    vm_state: Mutex<VmState>,
    gic_mmio: Mutex<GicMmio>,
    uart: Mutex<Pl011Uart>,
    psci: Mutex<PsciController>,
    console_output: Mutex<String>,
    stages: Mutex<Vec<HvfBootStage>>,
    event_reclaim: Mutex<EventReclaimMetrics>,
    core_memory: Mutex<CoreMemoryControllerMetrics>,
    allow_balloon_hard_decommit_fallback: Arc<AtomicBool>,
    event_reclaim_inflight: AtomicBool,
    event_reclaim_pending: AtomicBool,
    stop_reason: Mutex<Option<String>>,
    stop_requested: AtomicBool,
}

#[derive(Debug, Clone, Default, Serialize)]
struct EventReclaimMetrics {
    requests: u64,
    successes: u64,
    errors: u64,
    no_range_responses: u64,
    response_bytes: u64,
    parsed_ranges: u64,
    parsed_range_bytes: u64,
    applied_range_bytes: u64,
    last_reason: Option<String>,
    last_error: Option<String>,
}

/// Jetstream owns balloon target transitions. Host-side clients may inspect
/// this state, but they never need to drive the target for normal operation.
#[derive(Debug, Clone, Serialize)]
struct CoreMemoryControllerMetrics {
    enabled: bool,
    idle_target_mib: u64,
    current_target_mib: u64,
    quiet_dwell_ms: u64,
    pending_idle_probe: bool,
    idle_probe_inflight: bool,
    workload_expansions: u64,
    idle_shrinks: u64,
    idle_deferrals: u64,
    idle_probes: u64,
    idle_sentinel_probes: u64,
    transport_activity_events: u64,
    transport_quiet_transitions: u64,
    transport_quiet_reclaims: u64,
    idle_backing_compactions: u64,
    idle_backing_hard_decommitted_bytes: u64,
    idle_backing_compaction_failures: u64,
    service_min_target_mib: u64,
    service_desired_target_mib: u64,
    service_learning: bool,
    service_cooldown: bool,
    service_probes: u64,
    service_shrinks: u64,
    service_expansions: u64,
    service_feedback_passes: u64,
    service_feedback_deferrals: u64,
    service_convergence_waits: u64,
    service_convergence_timeouts: u64,
    service_stabilization_waits: u64,
    service_watchdog_probes: u64,
    service_watchdog_expansions: u64,
    service_generation_resets: u64,
    service_refault_bytes: u64,
    service_learned_headroom_mib: u64,
    restore_retries: u64,
    last_reason: Option<String>,
    last_error: Option<String>,
}

impl Default for CoreMemoryControllerMetrics {
    fn default() -> Self {
        Self {
            enabled: false,
            idle_target_mib: 0,
            current_target_mib: 0,
            quiet_dwell_ms: 0,
            pending_idle_probe: false,
            idle_probe_inflight: false,
            workload_expansions: 0,
            idle_shrinks: 0,
            idle_deferrals: 0,
            idle_probes: 0,
            idle_sentinel_probes: 0,
            transport_activity_events: 0,
            transport_quiet_transitions: 0,
            transport_quiet_reclaims: 0,
            idle_backing_compactions: 0,
            idle_backing_hard_decommitted_bytes: 0,
            idle_backing_compaction_failures: 0,
            service_min_target_mib: 0,
            service_desired_target_mib: 0,
            service_learning: false,
            service_cooldown: false,
            service_probes: 0,
            service_shrinks: 0,
            service_expansions: 0,
            service_feedback_passes: 0,
            service_feedback_deferrals: 0,
            service_convergence_waits: 0,
            service_convergence_timeouts: 0,
            service_stabilization_waits: 0,
            service_watchdog_probes: 0,
            service_watchdog_expansions: 0,
            service_generation_resets: 0,
            service_refault_bytes: 0,
            service_learned_headroom_mib: 0,
            restore_retries: 0,
            last_reason: None,
            last_error: None,
        }
    }
}

#[derive(Debug, Clone)]
struct CoreMemoryPolicy {
    enabled: bool,
    target_mib: u64,
    quiet_dwell: Duration,
    retry_dwell: Duration,
    service_min_target_mib: u64,
    service_learning_dwell: Duration,
    service_probe_dwell: Duration,
    service_stabilization_dwell: Duration,
    service_shrink_step_mib: u64,
    service_headroom_mib: u64,
    service_cooldown_dwell: Duration,
}

impl CoreMemoryPolicy {
    fn from_environment(configured_memory_mib: u64) -> Self {
        let minimum_target_mib = 256.min(configured_memory_mib);
        let target_mib = environment_u64("CONJET_MEM_CORE_IDLE_TARGET_MIB")
            .unwrap_or(DEFAULT_CORE_IDLE_TARGET_MIB)
            .clamp(minimum_target_mib, configured_memory_mib);
        let quiet_dwell = Duration::from_millis(
            environment_u64("CONJET_MEM_CORE_IDLE_DWELL_MS")
                .unwrap_or(DEFAULT_CORE_IDLE_QUIET_DWELL.as_millis() as u64)
                .max(1),
        );
        let service_min_target_mib = environment_u64("CONJET_MEM_CORE_SERVICE_MIN_TARGET_MIB")
            .unwrap_or(DEFAULT_CORE_SERVICE_MIN_TARGET_MIB)
            .clamp(target_mib, configured_memory_mib);
        let service_learning_dwell = Duration::from_millis(
            environment_u64("CONJET_MEM_CORE_SERVICE_LEARNING_MS")
                .unwrap_or(DEFAULT_CORE_SERVICE_LEARNING_DWELL.as_millis() as u64)
                .max(1),
        );
        let service_probe_dwell = Duration::from_millis(
            environment_u64("CONJET_MEM_CORE_SERVICE_PROBE_MS")
                .unwrap_or(DEFAULT_CORE_SERVICE_PROBE_DWELL.as_millis() as u64)
                .max(1),
        );
        let service_shrink_step_mib = environment_u64("CONJET_MEM_CORE_SERVICE_SHRINK_STEP_MIB")
            .unwrap_or(DEFAULT_CORE_SERVICE_SHRINK_STEP_MIB)
            .clamp(
                CORE_SERVICE_TARGET_QUANTUM_MIB,
                configured_memory_mib.max(1),
            );
        let service_headroom_mib = environment_u64("CONJET_MEM_CORE_SERVICE_HEADROOM_MIB")
            .unwrap_or(DEFAULT_CORE_SERVICE_HEADROOM_MIB)
            .min(configured_memory_mib);
        Self {
            enabled: configured_memory_mib > target_mib
                && !debug_flags::enabled("CONJET_MEM_DISABLE_CORE_IDLE_CONTROLLER"),
            target_mib,
            quiet_dwell,
            retry_dwell: DEFAULT_CORE_IDLE_RETRY_DWELL,
            service_min_target_mib,
            service_learning_dwell,
            service_probe_dwell,
            service_stabilization_dwell: DEFAULT_CORE_SERVICE_STABILIZATION_DWELL,
            service_shrink_step_mib,
            service_headroom_mib,
            service_cooldown_dwell: DEFAULT_CORE_SERVICE_COOLDOWN_DWELL,
        }
    }
}

#[derive(Debug)]
struct CoreMemoryController {
    policy: CoreMemoryPolicy,
    configured_memory_mib: u64,
    requested_target_mib: u64,
    runtime_ready: bool,
    idle_deadline: Option<Instant>,
    idle_probe: Option<GuestMemoryProbe>,
    idle_backing_compaction_deadline: Option<Instant>,
    last_docker_transport_activity: Option<Instant>,
    docker_transport_active: bool,
    docker_transport_tracks_bytes: bool,
    classified_workload_streams_active: bool,
    docker_activity_generation: u64,
    service_learning_deadline: Option<Instant>,
    service_cooldown_deadline: Option<Instant>,
    last_guest_snapshot: Option<GuestMemorySnapshot>,
    service_samples: VecDeque<GuestMemorySnapshot>,
    service_adjustment: Option<ServiceCapacityAdjustment>,
    service_watchdog_deadline: Option<Instant>,
    service_learned_headroom_mib: u64,
    pending_restore_retry_deadline: Option<Instant>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GuestMemoryProbeKind {
    Idle,
    ServiceWatchdog,
}

#[derive(Debug)]
struct GuestMemoryProbe {
    kind: GuestMemoryProbeKind,
    receiver: mpsc::Receiver<(u64, Result<GuestMemorySnapshot, String>)>,
}

impl GuestMemoryProbe {
    fn try_recv_for(
        &self,
        expected_kind: GuestMemoryProbeKind,
    ) -> Option<Result<(u64, Result<GuestMemorySnapshot, String>), mpsc::TryRecvError>> {
        (self.kind == expected_kind).then(|| self.receiver.try_recv())
    }
}

#[derive(Debug, Clone, Copy)]
struct ServiceCapacityAdjustment {
    previous_target_mib: u64,
    target_mib: u64,
    baseline: Option<GuestMemorySnapshot>,
    applied_at: Instant,
    next_convergence_observation_at: Instant,
    converged_at: Option<Instant>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ServiceAdjustmentReadiness {
    WaitingForConvergence,
    Stabilizing,
    Ready,
}

impl ServiceCapacityAdjustment {
    fn needs_convergence_observation(&self, now: Instant) -> bool {
        self.converged_at.is_none()
            && (now >= self.next_convergence_observation_at || now >= self.convergence_deadline())
    }

    fn convergence_deadline(&self) -> Instant {
        let dwell = if self.target_mib >= self.previous_target_mib {
            CORE_SERVICE_EXPANSION_CONVERGENCE_RETRY_DWELL
        } else {
            CORE_SERVICE_SHRINK_CONVERGENCE_TIMEOUT
        };
        self.applied_at + dwell
    }

    fn observe(
        &mut self,
        now: Instant,
        balloon_target_converged: Option<bool>,
        stabilization_dwell: Duration,
    ) -> ServiceAdjustmentReadiness {
        let converged_at = match self.converged_at {
            Some(converged_at) => converged_at,
            None => {
                if balloon_target_converged != Some(true) {
                    if balloon_target_converged == Some(false) {
                        self.next_convergence_observation_at =
                            now + CORE_SERVICE_CONVERGENCE_POLL_DWELL;
                    }
                    return ServiceAdjustmentReadiness::WaitingForConvergence;
                }
                self.converged_at = Some(now);
                return ServiceAdjustmentReadiness::Stabilizing;
            }
        };
        if now.duration_since(converged_at) < stabilization_dwell {
            ServiceAdjustmentReadiness::Stabilizing
        } else {
            ServiceAdjustmentReadiness::Ready
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CoreMemoryTargetTransition {
    RestoreConfigured,
    AdjustService(u64),
    ReduceToIdle,
}

impl CoreMemoryController {
    fn new(policy: CoreMemoryPolicy, configured_memory_mib: u64, initial_target_mib: u64) -> Self {
        Self {
            policy,
            configured_memory_mib,
            requested_target_mib: initial_target_mib.min(configured_memory_mib),
            runtime_ready: false,
            idle_deadline: None,
            idle_probe: None,
            idle_backing_compaction_deadline: None,
            last_docker_transport_activity: None,
            docker_transport_active: false,
            docker_transport_tracks_bytes: false,
            classified_workload_streams_active: false,
            docker_activity_generation: 0,
            service_learning_deadline: None,
            service_cooldown_deadline: None,
            last_guest_snapshot: None,
            service_samples: VecDeque::with_capacity(CORE_SERVICE_SAMPLE_WINDOW),
            service_adjustment: None,
            service_watchdog_deadline: None,
            service_learned_headroom_mib: 0,
            pending_restore_retry_deadline: None,
        }
    }

    fn metrics(&self) -> CoreMemoryControllerMetrics {
        CoreMemoryControllerMetrics {
            enabled: self.policy.enabled,
            idle_target_mib: self.policy.target_mib,
            current_target_mib: self.requested_target_mib,
            quiet_dwell_ms: self.policy.quiet_dwell.as_millis() as u64,
            service_min_target_mib: self.policy.service_min_target_mib,
            ..CoreMemoryControllerMetrics::default()
        }
    }

    fn should_observe_balloon_convergence(&self, now: Instant) -> bool {
        self.service_adjustment
            .is_some_and(|adjustment| adjustment.needs_convergence_observation(now))
    }

    fn note_runtime_ready(&mut self, now: Instant, shared: &SharedBootState) {
        if !self.policy.enabled || self.runtime_ready {
            return;
        }
        self.runtime_ready = true;
        if self.idle_target_reached() {
            self.idle_deadline = Some(now + CORE_IDLE_SENTINEL_DWELL);
            return;
        }
        self.idle_deadline = Some(now + self.policy.quiet_dwell);
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        metrics.pending_idle_probe = true;
        metrics.last_reason = Some("runtime ready; waiting for guest idle".to_string());
        metrics.last_error = None;
    }

    fn note_workload_started(
        &mut self,
        now: Instant,
        shared: &SharedBootState,
    ) -> Option<CoreMemoryTargetTransition> {
        if !self.policy.enabled {
            return None;
        }
        self.last_docker_transport_activity = Some(now);
        self.docker_transport_active = true;
        self.docker_transport_tracks_bytes = false;
        self.classified_workload_streams_active = true;
        self.docker_activity_generation = self.docker_activity_generation.wrapping_add(1);
        self.idle_deadline = None;
        self.idle_probe = None;
        self.idle_backing_compaction_deadline = None;
        self.service_learning_deadline = None;
        self.service_cooldown_deadline = None;
        self.last_guest_snapshot = None;
        self.service_samples.clear();
        let capacity_transition_inflight = self.service_adjustment.is_some();
        self.service_adjustment = None;
        self.service_watchdog_deadline = None;
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        metrics.pending_idle_probe = false;
        metrics.idle_probe_inflight = false;
        metrics.last_reason = Some("docker workload active".to_string());
        metrics.last_error = None;
        if self.requested_target_mib >= self.configured_memory_mib && !capacity_transition_inflight
        {
            return None;
        }
        metrics.last_reason = Some(format!(
            "docker workload active; restoring {} MiB",
            self.configured_memory_mib
        ));
        Some(CoreMemoryTargetTransition::RestoreConfigured)
    }

    fn note_workload_finished(
        &mut self,
        now: Instant,
        workload_streams_still_active: bool,
        shared: &SharedBootState,
    ) {
        if workload_streams_still_active {
            self.classified_workload_streams_active = true;
            self.docker_transport_active = true;
            self.docker_transport_tracks_bytes = false;
        } else {
            self.classified_workload_streams_active = false;
            self.docker_transport_active = false;
            self.docker_transport_tracks_bytes = false;
            self.last_docker_transport_activity = None;
        }
        if !self.policy.enabled
            || !self.runtime_ready
            || self.requested_target_mib <= self.policy.target_mib
        {
            return;
        }
        self.idle_deadline = Some(now + self.policy.quiet_dwell);
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        metrics.pending_idle_probe = true;
        metrics.last_reason = Some("docker workload finished; waiting for guest idle".to_string());
        metrics.last_error = None;
    }

    fn note_docker_transport_activity(
        &mut self,
        now: Instant,
        shared: &SharedBootState,
    ) -> Option<CoreMemoryTargetTransition> {
        if !self.policy.enabled {
            return None;
        }
        {
            let mut metrics = shared
                .core_memory
                .lock()
                .expect("core memory controller mutex poisoned");
            metrics.transport_activity_events = metrics.transport_activity_events.saturating_add(1);
        }
        if !self.observe_docker_transport_bytes(now) {
            return None;
        }
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        metrics.pending_idle_probe = false;
        if self.idle_probe.is_none() {
            metrics.idle_probe_inflight = false;
        }
        None
    }

    fn observe_docker_transport_bytes(&mut self, now: Instant) -> bool {
        if self.classified_workload_streams_active {
            // A classified stream is authoritative until VSOCK reports that
            // its active workload count reached zero. Byte silence is expected
            // for interactive and long-running operations and must not demote it.
            self.docker_transport_active = true;
            return true;
        }
        // Aggregate Docker socket bytes do not identify their stream. Do not
        // let benign ping/list/inspect/events traffic arm the quiet heuristic
        // or indefinitely defer service convergence. Bytes may only refresh a
        // stream that an explicit opaque-stream classifier armed beforehand.
        if !self.docker_transport_active || !self.docker_transport_tracks_bytes {
            return false;
        }
        self.last_docker_transport_activity = Some(now);
        self.idle_deadline = None;
        if self
            .idle_probe
            .as_ref()
            .is_some_and(|probe| probe.kind == GuestMemoryProbeKind::Idle)
        {
            self.idle_probe = None;
        }
        true
    }

    fn finish_docker_transport_quiet(&mut self, now: Instant) -> bool {
        if self.classified_workload_streams_active {
            return false;
        }
        self.docker_transport_active = false;
        self.docker_transport_tracks_bytes = false;
        self.last_docker_transport_activity = None;
        if !self.runtime_ready || self.requested_target_mib <= self.policy.target_mib {
            return false;
        }
        // Give the guest reclaimer a short head start. A stop request can finish
        // before container cgroups become empty, so probing immediately would
        // race the cache reclaim that follows the quiet transition.
        self.idle_deadline = Some(now + DEFAULT_CORE_IDLE_RECLAIM_SETTLE_DWELL);
        self.idle_probe = None;
        true
    }

    fn poll_docker_transport_quiet(&mut self, now: Instant, shared: &SharedBootState) -> bool {
        if self.classified_workload_streams_active
            || !self.docker_transport_active
            || !self.docker_transport_tracks_bytes
            || !self
                .last_docker_transport_activity
                .is_some_and(|last| now.duration_since(last) >= self.policy.quiet_dwell)
        {
            return false;
        }
        let should_reclaim = self.finish_docker_transport_quiet(now);
        {
            let mut metrics = shared
                .core_memory
                .lock()
                .expect("core memory controller mutex poisoned");
            metrics.transport_quiet_transitions =
                metrics.transport_quiet_transitions.saturating_add(1);
        }
        if !should_reclaim {
            return false;
        }
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        metrics.pending_idle_probe = true;
        metrics.idle_probe_inflight = false;
        metrics.transport_quiet_reclaims = metrics.transport_quiet_reclaims.saturating_add(1);
        metrics.last_reason =
            Some("docker transport quiet; reclaiming guest caches before idle probe".to_string());
        metrics.last_error = None;
        true
    }

    fn poll(
        &mut self,
        now: Instant,
        memory_socket_path: &std::path::Path,
        balloon_target_converged: Option<bool>,
        shared: &SharedBootState,
    ) -> Option<CoreMemoryTargetTransition> {
        if !self.policy.enabled || !self.runtime_ready {
            return None;
        }
        if self
            .pending_restore_retry_deadline
            .is_some_and(|deadline| now >= deadline)
        {
            self.pending_restore_retry_deadline = None;
            let mut metrics = shared
                .core_memory
                .lock()
                .expect("core memory controller mutex poisoned");
            metrics.restore_retries = metrics.restore_retries.saturating_add(1);
            metrics.last_reason = Some("retrying configured-capacity restore".to_string());
            return Some(CoreMemoryTargetTransition::RestoreConfigured);
        }
        if let Some(mut adjustment) = self.service_adjustment {
            if adjustment.target_mib < adjustment.previous_target_mib {
                let watchdog_result = match self.idle_probe.as_ref() {
                    Some(probe) => {
                        match probe.try_recv_for(GuestMemoryProbeKind::ServiceWatchdog) {
                            Some(Ok(result)) => Some(result),
                            Some(Err(mpsc::TryRecvError::Empty)) | None => None,
                            Some(Err(mpsc::TryRecvError::Disconnected)) => Some((
                                self.docker_activity_generation,
                                Err("service pressure watchdog disconnected".to_string()),
                            )),
                        }
                    }
                    None => None,
                };
                if let Some((probe_generation, result)) = watchdog_result {
                    self.idle_probe = None;
                    self.service_watchdog_deadline =
                        Some(now + CORE_SERVICE_PRESSURE_WATCHDOG_DWELL);
                    shared
                        .core_memory
                        .lock()
                        .expect("core memory controller mutex poisoned")
                        .idle_probe_inflight = false;
                    if probe_generation == self.docker_activity_generation {
                        let snapshot = match result {
                            Ok(snapshot) => snapshot,
                            Err(error) => {
                                self.service_adjustment = None;
                                self.service_watchdog_deadline = None;
                                self.service_cooldown_deadline =
                                    Some(now + self.policy.service_cooldown_dwell);
                                let mut metrics = shared
                                    .core_memory
                                    .lock()
                                    .expect("core memory controller mutex poisoned");
                                metrics.service_feedback_deferrals =
                                    metrics.service_feedback_deferrals.saturating_add(1);
                                metrics.last_reason = Some(
                                    "service watchdog failed; restoring configured capacity"
                                        .to_string(),
                                );
                                metrics.last_error = Some(error);
                                return Some(CoreMemoryTargetTransition::RestoreConfigured);
                            }
                        };
                        let urgent_regression = adjustment.baseline.is_some_and(|baseline| {
                            snapshot.urgent_service_regression_since(&baseline)
                        });
                        if !snapshot.has_live_service_telemetry()
                            || !snapshot.service_feedback_is_safe()
                            || urgent_regression
                        {
                            self.service_adjustment = None;
                            self.service_watchdog_deadline = None;
                            self.service_cooldown_deadline =
                                Some(now + self.policy.service_cooldown_dwell);
                            let mut metrics = shared
                                .core_memory
                                .lock()
                                .expect("core memory controller mutex poisoned");
                            metrics.service_feedback_deferrals =
                                metrics.service_feedback_deferrals.saturating_add(1);
                            metrics.service_cooldown = true;
                            metrics.last_reason = Some(
                                "service pressure watchdog restored configured capacity"
                                    .to_string(),
                            );
                            metrics.last_error = Some(snapshot.idle_block_reason());
                            return Some(CoreMemoryTargetTransition::RestoreConfigured);
                        }
                        let desired_target_mib = snapshot.desired_service_target_mib(
                            self.requested_target_mib,
                            self.configured_memory_mib,
                            &self.policy,
                            self.service_learned_headroom_mib,
                            snapshot.protected_runtime_working_set(),
                        );
                        if desired_target_mib > self.requested_target_mib {
                            self.service_adjustment = None;
                            self.service_watchdog_deadline = None;
                            self.service_cooldown_deadline =
                                Some(now + self.policy.service_cooldown_dwell);
                            let mut metrics = shared
                                .core_memory
                                .lock()
                                .expect("core memory controller mutex poisoned");
                            metrics.service_watchdog_expansions =
                                metrics.service_watchdog_expansions.saturating_add(1);
                            metrics.service_cooldown = true;
                            metrics.service_desired_target_mib = desired_target_mib;
                            metrics.last_reason = Some(format!(
                                "service watchdog expanded capacity to {} MiB",
                                desired_target_mib
                            ));
                            metrics.last_error = None;
                            return Some(CoreMemoryTargetTransition::AdjustService(
                                desired_target_mib,
                            ));
                        }
                    }
                }
                if self.idle_probe.is_none()
                    && self
                        .service_watchdog_deadline
                        .is_none_or(|deadline| now >= deadline)
                {
                    match spawn_guest_memory_probe(
                        memory_socket_path,
                        self.docker_activity_generation,
                        "jetstream-service-pressure-watchdog",
                    ) {
                        Ok(receiver) => {
                            self.idle_probe = Some(GuestMemoryProbe {
                                kind: GuestMemoryProbeKind::ServiceWatchdog,
                                receiver,
                            });
                            self.service_watchdog_deadline =
                                Some(now + CORE_SERVICE_PRESSURE_WATCHDOG_DWELL);
                            let mut metrics = shared
                                .core_memory
                                .lock()
                                .expect("core memory controller mutex poisoned");
                            metrics.idle_probe_inflight = true;
                            metrics.service_watchdog_probes =
                                metrics.service_watchdog_probes.saturating_add(1);
                            metrics.last_reason = Some(
                                "watching service pressure during capacity change".to_string(),
                            );
                            metrics.last_error = None;
                            return None;
                        }
                        Err(error) => {
                            self.service_adjustment = None;
                            self.service_watchdog_deadline = None;
                            self.service_cooldown_deadline =
                                Some(now + self.policy.service_cooldown_dwell);
                            let mut metrics = shared
                                .core_memory
                                .lock()
                                .expect("core memory controller mutex poisoned");
                            metrics.service_feedback_deferrals =
                                metrics.service_feedback_deferrals.saturating_add(1);
                            metrics.service_cooldown = true;
                            metrics.last_reason = Some(
                                "failed to start service watchdog; restoring capacity".to_string(),
                            );
                            metrics.last_error = Some(error);
                            return Some(CoreMemoryTargetTransition::RestoreConfigured);
                        }
                    }
                }
            }
            if adjustment.converged_at.is_none()
                && balloon_target_converged == Some(false)
                && now >= adjustment.convergence_deadline()
            {
                self.service_adjustment = None;
                self.service_cooldown_deadline = Some(now + self.policy.service_cooldown_dwell);
                let mut metrics = shared
                    .core_memory
                    .lock()
                    .expect("core memory controller mutex poisoned");
                metrics.pending_idle_probe = true;
                metrics.service_cooldown = true;
                metrics.service_feedback_deferrals =
                    metrics.service_feedback_deferrals.saturating_add(1);
                metrics.service_convergence_timeouts =
                    metrics.service_convergence_timeouts.saturating_add(1);
                metrics.last_reason = Some(format!(
                    "capacity transition to {} MiB did not converge; restoring configured capacity",
                    adjustment.target_mib
                ));
                metrics.last_error = Some("virtio-balloon convergence timed out".to_string());
                return Some(CoreMemoryTargetTransition::RestoreConfigured);
            }
            match adjustment.observe(
                now,
                balloon_target_converged,
                self.policy.service_stabilization_dwell,
            ) {
                ServiceAdjustmentReadiness::WaitingForConvergence => {
                    self.service_adjustment = Some(adjustment);
                    if balloon_target_converged.is_some() {
                        let mut metrics = shared
                            .core_memory
                            .lock()
                            .expect("core memory controller mutex poisoned");
                        metrics.pending_idle_probe = true;
                        metrics.service_convergence_waits =
                            metrics.service_convergence_waits.saturating_add(1);
                        metrics.last_reason = Some(format!(
                            "waiting {}s for balloon convergence at {} MiB",
                            now.duration_since(adjustment.applied_at).as_secs(),
                            adjustment.target_mib
                        ));
                    }
                    return None;
                }
                ServiceAdjustmentReadiness::Stabilizing => {
                    self.service_adjustment = Some(adjustment);
                    if balloon_target_converged == Some(true) {
                        self.idle_deadline = Some(now + self.policy.service_stabilization_dwell);
                        let mut metrics = shared
                            .core_memory
                            .lock()
                            .expect("core memory controller mutex poisoned");
                        metrics.pending_idle_probe = true;
                        metrics.service_stabilization_waits =
                            metrics.service_stabilization_waits.saturating_add(1);
                        metrics.last_reason = Some(format!(
                            "balloon converged at {} MiB; stabilizing service feedback",
                            adjustment.target_mib
                        ));
                    }
                    return None;
                }
                ServiceAdjustmentReadiness::Ready => {
                    if adjustment.target_mib >= adjustment.previous_target_mib {
                        self.service_adjustment = None;
                    } else {
                        self.service_adjustment = Some(adjustment);
                    }
                }
            }
        }
        // A byte-moving Docker stream is authoritative activity even when an
        // opaque BuildKit session cannot be classified by its request path.
        // Do not race it with an idle probe; `poll_docker_transport_quiet`
        // arms the normal guest-idle verification only after the quiet dwell.
        if self.docker_transport_active {
            return None;
        }
        let probe_result = match self.idle_probe.as_ref() {
            Some(probe) => match probe.try_recv_for(GuestMemoryProbeKind::Idle) {
                Some(Ok(result)) => Some(result),
                Some(Err(mpsc::TryRecvError::Empty)) => return None,
                Some(Err(mpsc::TryRecvError::Disconnected)) => Some((
                    self.docker_activity_generation,
                    Err("guest memory probe disconnected".to_string()),
                )),
                None => None,
            },
            None => None,
        };
        if let Some((probe_generation, result)) = probe_result {
            self.idle_probe = None;
            let mut metrics = shared
                .core_memory
                .lock()
                .expect("core memory controller mutex poisoned");
            metrics.idle_probe_inflight = false;
            if probe_generation != self.docker_activity_generation {
                self.idle_deadline = Some(now + self.policy.service_probe_dwell);
                metrics.pending_idle_probe = true;
                metrics.last_reason =
                    Some("discarded stale guest memory probe after workload activity".to_string());
                return None;
            }
            match result {
                Ok(snapshot) if snapshot.allows_idle_target() => {
                    self.service_learning_deadline = None;
                    self.service_cooldown_deadline = None;
                    self.service_watchdog_deadline = None;
                    self.last_guest_snapshot = None;
                    self.service_samples.clear();
                    self.service_adjustment = None;
                    self.service_learned_headroom_mib = 0;
                    metrics.pending_idle_probe = false;
                    metrics.service_learning = false;
                    metrics.service_cooldown = false;
                    metrics.service_desired_target_mib = self.policy.target_mib;
                    metrics.service_learned_headroom_mib = 0;
                    metrics.last_reason = Some(format!(
                        "guest idle; reducing target to {} MiB",
                        self.policy.target_mib
                    ));
                    metrics.last_error = None;
                    if self.requested_target_mib == self.policy.target_mib {
                        self.idle_deadline = Some(now + CORE_IDLE_SENTINEL_DWELL);
                        metrics.last_reason =
                            Some("idle sentinel confirmed empty services".to_string());
                        return None;
                    }
                    self.idle_deadline = None;
                    return Some(CoreMemoryTargetTransition::ReduceToIdle);
                }
                Ok(snapshot) if snapshot.has_live_service_telemetry() => {
                    metrics.service_probes = metrics.service_probes.saturating_add(1);
                    if !snapshot.service_feedback_is_safe() {
                        self.service_adjustment = None;
                        self.service_cooldown_deadline =
                            Some(now + self.policy.service_cooldown_dwell);
                        self.idle_deadline = Some(now + self.policy.service_probe_dwell);
                        metrics.pending_idle_probe = true;
                        metrics.service_cooldown = true;
                        metrics.service_feedback_deferrals =
                            metrics.service_feedback_deferrals.saturating_add(1);
                        metrics.last_reason =
                            Some("hard guest pressure restored configured capacity".to_string());
                        metrics.last_error = Some(snapshot.idle_block_reason());
                        if self.requested_target_mib < self.configured_memory_mib {
                            return Some(CoreMemoryTargetTransition::RestoreConfigured);
                        }
                        return None;
                    }

                    if let Some(adjustment) = self.service_adjustment.take() {
                        if adjustment.target_mib < adjustment.previous_target_mib {
                            if let Some(baseline) = adjustment.baseline {
                                if let Some(regression) =
                                    snapshot.service_feedback_regression(&baseline, adjustment)
                                {
                                    self.service_cooldown_deadline =
                                        Some(now + self.policy.service_cooldown_dwell);
                                    self.idle_deadline =
                                        Some(now + self.policy.service_probe_dwell);
                                    metrics.pending_idle_probe = true;
                                    metrics.service_cooldown = true;
                                    metrics.service_feedback_deferrals =
                                        metrics.service_feedback_deferrals.saturating_add(1);
                                    metrics.service_refault_bytes = metrics
                                        .service_refault_bytes
                                        .saturating_add(regression.refault_bytes);
                                    metrics.last_error = Some(regression.reason.clone());
                                    match regression.kind {
                                        ServiceFeedbackRegressionKind::HardPressure => {
                                            metrics.last_reason = Some(
                                                "service feedback restored configured capacity"
                                                    .to_string(),
                                            );
                                            return Some(
                                                CoreMemoryTargetTransition::RestoreConfigured,
                                            );
                                        }
                                        ServiceFeedbackRegressionKind::GenerationChanged => {
                                            self.service_samples.clear();
                                            self.last_guest_snapshot = None;
                                            self.service_learning_deadline = None;
                                            self.service_learned_headroom_mib = 0;
                                            metrics.service_generation_resets =
                                                metrics.service_generation_resets.saturating_add(1);
                                            metrics.service_learned_headroom_mib = 0;
                                            metrics.service_learning = true;
                                            metrics.last_reason = Some(
                                                "service generation changed; relearning at configured capacity"
                                                    .to_string(),
                                            );
                                            return Some(
                                                CoreMemoryTargetTransition::RestoreConfigured,
                                            );
                                        }
                                        ServiceFeedbackRegressionKind::Refault => {
                                            let learned_mib = round_up_mib(
                                                regression
                                                    .refault_bytes
                                                    .saturating_add(1024 * 1024 - 1)
                                                    / 1024
                                                    / 1024,
                                                CORE_SERVICE_TARGET_QUANTUM_MIB,
                                            )
                                            .clamp(CORE_SERVICE_TARGET_QUANTUM_MIB, 512);
                                            self.service_learned_headroom_mib = self
                                                .service_learned_headroom_mib
                                                .saturating_add(learned_mib)
                                                .min(
                                                    CORE_SERVICE_MAX_LEARNED_HEADROOM_MIB.min(
                                                        (self.configured_memory_mib / 4)
                                                            .max(CORE_SERVICE_TARGET_QUANTUM_MIB),
                                                    ),
                                                );
                                            metrics.service_learned_headroom_mib =
                                                self.service_learned_headroom_mib;
                                            metrics.last_reason = Some(
                                                "service refault guard restored prior capacity"
                                                    .to_string(),
                                            );
                                        }
                                        ServiceFeedbackRegressionKind::MajorFault => {
                                            metrics.last_reason = Some(
                                                "major-fault guard restored prior capacity without changing learned headroom"
                                                    .to_string(),
                                            );
                                        }
                                    }
                                    let recovery_target = adjustment.previous_target_mib.max(
                                        snapshot.desired_service_target_mib(
                                            self.requested_target_mib,
                                            self.configured_memory_mib,
                                            &self.policy,
                                            self.service_learned_headroom_mib,
                                            snapshot.protected_runtime_working_set(),
                                        ),
                                    );
                                    metrics.service_desired_target_mib = recovery_target;
                                    return Some(CoreMemoryTargetTransition::AdjustService(
                                        recovery_target,
                                    ));
                                }
                            }
                            metrics.service_feedback_passes =
                                metrics.service_feedback_passes.saturating_add(1);
                        }
                    }

                    let membership_changed = self.last_guest_snapshot.is_some_and(|previous| {
                        previous.service_cgroup_cgroup_id != snapshot.service_cgroup_cgroup_id
                            || previous.active_workloads != snapshot.active_workloads
                    });
                    if membership_changed {
                        self.service_samples.clear();
                        self.service_learned_headroom_mib = 0;
                        self.service_learning_deadline =
                            Some(now + self.policy.service_learning_dwell);
                        metrics.service_generation_resets =
                            metrics.service_generation_resets.saturating_add(1);
                        metrics.service_learned_headroom_mib = 0;
                        metrics.service_learning = true;
                    }
                    self.last_guest_snapshot = Some(snapshot);
                    if self.service_samples.len() == CORE_SERVICE_SAMPLE_WINDOW {
                        self.service_samples.pop_front();
                    }
                    self.service_samples.push_back(snapshot);

                    let observed_working_set = self
                        .service_samples
                        .iter()
                        .map(GuestMemorySnapshot::protected_runtime_working_set)
                        .max()
                        .unwrap_or_else(|| snapshot.protected_runtime_working_set());
                    let desired_target_mib = snapshot.desired_service_target_mib(
                        self.requested_target_mib,
                        self.configured_memory_mib,
                        &self.policy,
                        self.service_learned_headroom_mib,
                        observed_working_set,
                    );
                    metrics.service_desired_target_mib = desired_target_mib;
                    metrics.service_learned_headroom_mib = self.service_learned_headroom_mib;
                    if desired_target_mib > self.requested_target_mib {
                        self.idle_deadline = Some(now + self.policy.service_probe_dwell);
                        metrics.pending_idle_probe = true;
                        metrics.last_reason = Some(format!(
                            "live-service working set needs {} MiB",
                            desired_target_mib
                        ));
                        metrics.last_error = None;
                        return Some(CoreMemoryTargetTransition::AdjustService(
                            desired_target_mib,
                        ));
                    }

                    match self.service_learning_deadline {
                        None => {
                            self.service_learning_deadline =
                                Some(now + self.policy.service_learning_dwell);
                            self.idle_deadline = Some(now + self.policy.service_probe_dwell);
                            metrics.pending_idle_probe = true;
                            metrics.service_learning = true;
                            metrics.service_cooldown = false;
                            metrics.last_reason = Some(
                                "live services detected; learning working set before shrink"
                                    .to_string(),
                            );
                            metrics.last_error = None;
                            return None;
                        }
                        Some(deadline) if now < deadline => {
                            self.idle_deadline = Some(now + self.policy.service_probe_dwell);
                            metrics.pending_idle_probe = true;
                            metrics.service_learning = true;
                            metrics.last_reason =
                                Some("learning live-service working set".to_string());
                            metrics.last_error = None;
                            return None;
                        }
                        Some(_) => {
                            metrics.service_learning = false;
                        }
                    }

                    let cooling_down = self
                        .service_cooldown_deadline
                        .is_some_and(|deadline| now < deadline);
                    metrics.service_cooldown = cooling_down;
                    if desired_target_mib < self.requested_target_mib && !cooling_down {
                        let target_mib = self
                            .requested_target_mib
                            .saturating_sub(self.policy.service_shrink_step_mib)
                            .max(desired_target_mib);
                        self.idle_deadline = Some(now + self.policy.service_probe_dwell);
                        metrics.pending_idle_probe = true;
                        metrics.last_reason = Some(format!(
                            "live services stable; reducing capacity toward {} MiB",
                            desired_target_mib
                        ));
                        metrics.last_error = None;
                        return Some(CoreMemoryTargetTransition::AdjustService(target_mib));
                    }

                    self.idle_deadline = Some(now + self.policy.service_probe_dwell);
                    metrics.pending_idle_probe = true;
                    metrics.last_reason = Some(format!(
                        "live services stable at {} MiB capacity",
                        self.requested_target_mib
                    ));
                    metrics.last_error = None;
                    return None;
                }
                Ok(snapshot) => {
                    self.service_learning_deadline = None;
                    self.service_samples.clear();
                    self.last_guest_snapshot = None;
                    self.service_adjustment = None;
                    self.idle_deadline = Some(now + self.policy.retry_dwell);
                    metrics.pending_idle_probe = true;
                    metrics.service_learning = false;
                    metrics.service_cooldown = false;
                    metrics.idle_deferrals = metrics.idle_deferrals.saturating_add(1);
                    metrics.last_reason = Some(
                        "guest telemetry incomplete; retaining safe capacity and relearning"
                            .to_string(),
                    );
                    metrics.last_error = Some(snapshot.idle_block_reason());
                    if self.requested_target_mib < self.configured_memory_mib {
                        return Some(CoreMemoryTargetTransition::RestoreConfigured);
                    }
                    return None;
                }
                Err(error) => {
                    self.service_learning_deadline = None;
                    self.service_samples.clear();
                    self.last_guest_snapshot = None;
                    self.service_adjustment = None;
                    self.idle_deadline = Some(now + self.policy.retry_dwell);
                    metrics.pending_idle_probe = true;
                    metrics.idle_deferrals = metrics.idle_deferrals.saturating_add(1);
                    metrics.last_reason = Some("guest idle probe failed; retrying".to_string());
                    metrics.last_error = Some(error);
                    if self.requested_target_mib < self.configured_memory_mib {
                        return Some(CoreMemoryTargetTransition::RestoreConfigured);
                    }
                    return None;
                }
            }
        }
        if self.idle_deadline.is_some_and(|deadline| now < deadline) {
            return None;
        }
        self.idle_deadline = None;
        let probe_generation = self.docker_activity_generation;
        let idle_sentinel = self.idle_target_reached();
        match spawn_guest_memory_probe(
            memory_socket_path,
            probe_generation,
            "jetstream-guest-memory-probe",
        ) {
            Ok(receiver) => {
                self.idle_probe = Some(GuestMemoryProbe {
                    kind: GuestMemoryProbeKind::Idle,
                    receiver,
                });
                let mut metrics = shared
                    .core_memory
                    .lock()
                    .expect("core memory controller mutex poisoned");
                metrics.pending_idle_probe = true;
                metrics.idle_probe_inflight = true;
                if idle_sentinel {
                    metrics.idle_sentinel_probes = metrics.idle_sentinel_probes.saturating_add(1);
                    metrics.last_reason = Some("probing idle service sentinel".to_string());
                } else {
                    metrics.idle_probes = metrics.idle_probes.saturating_add(1);
                    metrics.last_reason = Some("probing guest idle state".to_string());
                }
                metrics.last_error = None;
            }
            Err(error) => {
                self.idle_deadline = Some(now + self.policy.retry_dwell);
                let mut metrics = shared
                    .core_memory
                    .lock()
                    .expect("core memory controller mutex poisoned");
                metrics.pending_idle_probe = true;
                metrics.idle_deferrals = metrics.idle_deferrals.saturating_add(1);
                metrics.last_reason = Some("failed to start guest idle probe".to_string());
                metrics.last_error = Some(error);
            }
        }
        None
    }

    fn target_mib(&self, transition: CoreMemoryTargetTransition) -> u64 {
        match transition {
            CoreMemoryTargetTransition::RestoreConfigured => self.configured_memory_mib,
            CoreMemoryTargetTransition::AdjustService(target_mib) => target_mib.clamp(
                self.policy.service_min_target_mib,
                self.configured_memory_mib,
            ),
            CoreMemoryTargetTransition::ReduceToIdle => self.policy.target_mib,
        }
    }

    fn idle_target_reached(&self) -> bool {
        self.requested_target_mib <= self.policy.target_mib
    }

    fn record_target_applied(
        &mut self,
        transition: CoreMemoryTargetTransition,
        now: Instant,
        shared: &SharedBootState,
    ) {
        let target_mib = self.target_mib(transition);
        let previous_target_mib = self.requested_target_mib;
        self.requested_target_mib = target_mib;
        // A target change supersedes the observation associated with the old
        // target. In particular, a convergence timeout can leave an async
        // watchdog in flight; retaining it would block the next idle probe.
        self.idle_probe = None;
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        metrics.current_target_mib = target_mib;
        metrics.idle_probe_inflight = false;
        metrics.last_error = None;
        match transition {
            CoreMemoryTargetTransition::RestoreConfigured => {
                self.pending_restore_retry_deadline = None;
                self.service_watchdog_deadline = None;
                self.service_adjustment = Some(ServiceCapacityAdjustment {
                    previous_target_mib,
                    target_mib,
                    baseline: None,
                    applied_at: now,
                    next_convergence_observation_at: now,
                    converged_at: None,
                });
                metrics.workload_expansions = metrics.workload_expansions.saturating_add(1);
                metrics.last_reason = Some(format!(
                    "workload or pressure guard restored {} MiB",
                    self.configured_memory_mib
                ));
            }
            CoreMemoryTargetTransition::AdjustService(_) => {
                metrics.pending_idle_probe = true;
                if target_mib < previous_target_mib {
                    self.service_watchdog_deadline =
                        Some(now + CORE_SERVICE_PRESSURE_WATCHDOG_DWELL);
                    self.service_adjustment = Some(ServiceCapacityAdjustment {
                        previous_target_mib,
                        target_mib,
                        baseline: self.last_guest_snapshot,
                        applied_at: now,
                        next_convergence_observation_at: now,
                        converged_at: None,
                    });
                    metrics.service_shrinks = metrics.service_shrinks.saturating_add(1);
                    metrics.last_reason = Some(format!(
                        "live-service capacity reduced to {} MiB with feedback guard",
                        target_mib
                    ));
                } else if target_mib > previous_target_mib {
                    self.service_watchdog_deadline = None;
                    self.service_adjustment = Some(ServiceCapacityAdjustment {
                        previous_target_mib,
                        target_mib,
                        baseline: None,
                        applied_at: now,
                        next_convergence_observation_at: now,
                        converged_at: None,
                    });
                    metrics.service_expansions = metrics.service_expansions.saturating_add(1);
                    metrics.last_reason = Some(format!(
                        "live-service capacity expanded to {} MiB",
                        target_mib
                    ));
                } else {
                    self.service_adjustment = None;
                    self.service_watchdog_deadline = None;
                }
            }
            CoreMemoryTargetTransition::ReduceToIdle => {
                self.service_adjustment = None;
                self.service_watchdog_deadline = None;
                self.idle_deadline = Some(now + CORE_IDLE_SENTINEL_DWELL);
                metrics.pending_idle_probe = false;
                metrics.idle_shrinks = metrics.idle_shrinks.saturating_add(1);
                metrics.last_reason = Some(format!(
                    "guest idle; reduced target to {} MiB",
                    self.policy.target_mib
                ));
                // Keep reusable backing while Docker is active for fast capacity
                // restoration. Once the guest itself has confirmed idle and the
                // balloon reaches its target, convert it to zero backing so
                // macOS releases the retained working-set footprint promptly.
                self.idle_backing_compaction_deadline =
                    Some(now + DEFAULT_CORE_IDLE_BACKING_COMPACTION_DWELL);
            }
        }
    }

    fn poll_idle_backing_compaction(&mut self, now: Instant) -> bool {
        if self.requested_target_mib > self.policy.target_mib
            || self.docker_transport_active
            || !self
                .idle_backing_compaction_deadline
                .is_some_and(|deadline| now >= deadline)
        {
            return false;
        }
        self.idle_backing_compaction_deadline = None;
        true
    }

    fn defer_idle_backing_compaction(&mut self, now: Instant) {
        self.idle_backing_compaction_deadline =
            Some(now + DEFAULT_CORE_IDLE_BACKING_COMPACTION_RETRY_DWELL);
    }

    fn record_idle_backing_compaction(
        &mut self,
        report: IdleBackingCompactionReport,
        shared: &SharedBootState,
    ) {
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        if report.hard_decommitted_bytes > 0 {
            metrics.idle_backing_compactions = metrics.idle_backing_compactions.saturating_add(1);
            metrics.idle_backing_hard_decommitted_bytes = metrics
                .idle_backing_hard_decommitted_bytes
                .saturating_add(report.hard_decommitted_bytes);
            metrics.last_reason = Some(format!(
                "guest idle; hard-decommitted {} MiB of balloon backing",
                report.hard_decommitted_bytes / 1024 / 1024
            ));
            metrics.last_error = None;
        }
        if report.failed_bytes > 0 {
            metrics.idle_backing_compaction_failures = metrics
                .idle_backing_compaction_failures
                .saturating_add(report.failed_bytes);
            metrics.last_error = Some(format!(
                "failed to hard-decommit {} MiB of reusable balloon backing",
                report.failed_bytes / 1024 / 1024
            ));
        }
    }

    fn record_idle_backing_compaction_error(
        &mut self,
        now: Instant,
        error: String,
        shared: &SharedBootState,
    ) {
        self.defer_idle_backing_compaction(now);
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        metrics.idle_backing_compaction_failures =
            metrics.idle_backing_compaction_failures.saturating_add(1);
        metrics.last_error = Some(error);
    }

    fn record_target_error(
        &mut self,
        transition: CoreMemoryTargetTransition,
        now: Instant,
        error: String,
        shared: &SharedBootState,
    ) {
        self.idle_probe = None;
        match transition {
            CoreMemoryTargetTransition::ReduceToIdle => {
                self.idle_deadline = Some(now + self.policy.retry_dwell);
            }
            CoreMemoryTargetTransition::AdjustService(_) => {
                self.idle_deadline = Some(now + self.policy.service_probe_dwell);
                self.service_adjustment = None;
                self.service_watchdog_deadline = None;
            }
            CoreMemoryTargetTransition::RestoreConfigured => {
                self.pending_restore_retry_deadline = Some(now + CORE_RESTORE_RETRY_DWELL);
                self.service_adjustment = None;
                self.service_watchdog_deadline = None;
            }
        }
        let mut metrics = shared
            .core_memory
            .lock()
            .expect("core memory controller mutex poisoned");
        metrics.idle_probe_inflight = false;
        metrics.pending_idle_probe = true;
        metrics.idle_deferrals = metrics.idle_deferrals.saturating_add(1);
        if transition == CoreMemoryTargetTransition::RestoreConfigured {
            metrics.last_reason =
                Some("configured-capacity restore failed; retry armed".to_string());
        }
        metrics.last_error = Some(error);
    }
}

#[derive(Debug, Clone, Copy, Default, Deserialize)]
struct GuestMemorySnapshot {
    #[serde(default)]
    active_workloads: u64,
    #[serde(default)]
    build_workload_detected: bool,
    #[serde(default)]
    container_memory_current: u64,
    #[serde(default)]
    mem_available: u64,
    #[serde(default)]
    mem_available_known: bool,
    #[serde(default = "default_guest_page_size_bytes")]
    page_size_bytes: u64,
    #[serde(default)]
    daemon_cgroup_working_set: u64,
    #[serde(default)]
    service_cgroup_memory_current: u64,
    #[serde(default)]
    service_cgroup_working_set: u64,
    #[serde(default)]
    service_cgroup_anon: u64,
    #[serde(default)]
    service_cgroup_shmem: u64,
    #[serde(default)]
    service_cgroup_sock: u64,
    #[serde(default)]
    service_cgroup_file_mapped: u64,
    #[serde(default)]
    service_cgroup_slab_unreclaimable: u64,
    #[serde(default)]
    service_cgroup_populated: bool,
    #[serde(default)]
    service_cgroup_population_known: bool,
    #[serde(default)]
    service_cgroup_telemetry_complete: bool,
    #[serde(default)]
    service_cgroup_cgroup_id: u64,
    #[serde(default)]
    service_cgroup_file_dirty: u64,
    #[serde(default)]
    service_cgroup_file_writeback: u64,
    #[serde(default)]
    service_cgroup_workingset_refault_file: u64,
    #[serde(default)]
    service_cgroup_pgmajfault: u64,
    #[serde(default)]
    service_cgroup_memory_events_high: u64,
    #[serde(default)]
    service_cgroup_memory_events_max: u64,
    #[serde(default)]
    service_cgroup_memory_events_oom: u64,
    #[serde(default)]
    service_cgroup_memory_events_oom_kill: u64,
    #[serde(default)]
    service_cgroup_memory_events_oom_group_kill: u64,
    #[serde(default)]
    service_cgroup_memory_events_local_high: u64,
    #[serde(default)]
    service_cgroup_memory_events_local_max: u64,
    #[serde(default)]
    service_cgroup_memory_events_local_oom: u64,
    #[serde(default)]
    service_cgroup_memory_events_local_oom_kill: u64,
    #[serde(default)]
    service_cgroup_memory_events_local_oom_group_kill: u64,
    #[serde(default)]
    service_cgroup_psi_some_avg10: f64,
    #[serde(default)]
    service_cgroup_psi_full_avg10: f64,
    #[serde(default)]
    disk_swap_used: u64,
    #[serde(default)]
    swap_total: u64,
    #[serde(default)]
    swap_free: u64,
    #[serde(default)]
    swap_telemetry_complete: bool,
    #[serde(default)]
    container_swap_current: u64,
    #[serde(default)]
    disk_swap_total: u64,
    #[serde(default)]
    disk_swap_free: u64,
    #[serde(default)]
    disk_swap_telemetry_complete: bool,
    #[serde(default)]
    psi_some_avg10: f64,
    #[serde(default)]
    psi_full_avg10: f64,
    #[serde(default)]
    global_psi_telemetry_complete: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ServiceFeedbackRegressionKind {
    HardPressure,
    GenerationChanged,
    Refault,
    MajorFault,
}

#[derive(Debug, Clone)]
struct ServiceFeedbackRegression {
    kind: ServiceFeedbackRegressionKind,
    reason: String,
    refault_bytes: u64,
}

impl GuestMemorySnapshot {
    fn observed_disk_swap_used(&self) -> u64 {
        self.disk_swap_used
            .max(self.disk_swap_total.saturating_sub(self.disk_swap_free))
    }

    fn observed_total_swap_used(&self) -> u64 {
        self.swap_total.saturating_sub(self.swap_free)
    }

    fn global_control_telemetry_complete(&self) -> bool {
        self.mem_available_known
            && self.swap_telemetry_complete
            && self.disk_swap_telemetry_complete
            && self.global_psi_telemetry_complete
    }

    fn hard_pressure_regressed_since(&self, baseline: &Self) -> bool {
        self.service_cgroup_memory_events_high > baseline.service_cgroup_memory_events_high
            || self.service_cgroup_memory_events_max > baseline.service_cgroup_memory_events_max
            || self.service_cgroup_memory_events_oom > baseline.service_cgroup_memory_events_oom
            || self.service_cgroup_memory_events_oom_kill
                > baseline.service_cgroup_memory_events_oom_kill
            || self.service_cgroup_memory_events_oom_group_kill
                > baseline.service_cgroup_memory_events_oom_group_kill
            || self.service_cgroup_memory_events_local_high
                > baseline.service_cgroup_memory_events_local_high
            || self.service_cgroup_memory_events_local_max
                > baseline.service_cgroup_memory_events_local_max
            || self.service_cgroup_memory_events_local_oom
                > baseline.service_cgroup_memory_events_local_oom
            || self.service_cgroup_memory_events_local_oom_kill
                > baseline.service_cgroup_memory_events_local_oom_kill
            || self.service_cgroup_memory_events_local_oom_group_kill
                > baseline.service_cgroup_memory_events_local_oom_group_kill
            || (self.container_swap_current > CORE_CONTAINER_ZRAM_SWAP_BUDGET_BYTES
                && self.container_swap_current > baseline.container_swap_current)
            || self.observed_disk_swap_used() > baseline.observed_disk_swap_used()
            || (self.observed_total_swap_used() > CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES
                && self.observed_total_swap_used() > baseline.observed_total_swap_used())
    }

    fn service_event_counters_reset_since(&self, baseline: &Self) -> bool {
        self.service_cgroup_memory_events_high < baseline.service_cgroup_memory_events_high
            || self.service_cgroup_memory_events_max < baseline.service_cgroup_memory_events_max
            || self.service_cgroup_memory_events_oom < baseline.service_cgroup_memory_events_oom
            || self.service_cgroup_memory_events_oom_kill
                < baseline.service_cgroup_memory_events_oom_kill
            || self.service_cgroup_memory_events_oom_group_kill
                < baseline.service_cgroup_memory_events_oom_group_kill
            || self.service_cgroup_memory_events_local_high
                < baseline.service_cgroup_memory_events_local_high
            || self.service_cgroup_memory_events_local_max
                < baseline.service_cgroup_memory_events_local_max
            || self.service_cgroup_memory_events_local_oom
                < baseline.service_cgroup_memory_events_local_oom
            || self.service_cgroup_memory_events_local_oom_kill
                < baseline.service_cgroup_memory_events_local_oom_kill
            || self.service_cgroup_memory_events_local_oom_group_kill
                < baseline.service_cgroup_memory_events_local_oom_group_kill
    }

    fn urgent_service_regression_since(&self, baseline: &Self) -> bool {
        self.service_cgroup_cgroup_id != baseline.service_cgroup_cgroup_id
            || self.service_cgroup_pgmajfault < baseline.service_cgroup_pgmajfault
            || self.service_cgroup_workingset_refault_file
                < baseline.service_cgroup_workingset_refault_file
            || self.service_event_counters_reset_since(baseline)
            || self.hard_pressure_regressed_since(baseline)
            || self.service_cgroup_pgmajfault > baseline.service_cgroup_pgmajfault
    }

    fn stopped_service_pinned_bytes(&self) -> u64 {
        self.service_cgroup_anon
            .saturating_add(self.service_cgroup_shmem)
            .saturating_add(self.service_cgroup_sock)
            .saturating_add(self.service_cgroup_file_mapped)
            .saturating_add(self.service_cgroup_file_dirty)
            .saturating_add(self.service_cgroup_file_writeback)
            .saturating_add(self.service_cgroup_slab_unreclaimable)
    }

    fn service_memory_for_idle_gate(&self) -> u64 {
        if self.service_cgroup_population_known && !self.service_cgroup_populated {
            return self.stopped_service_pinned_bytes();
        }
        self.service_cgroup_memory_current
    }

    fn allows_idle_target(&self) -> bool {
        // The aggregate workload count includes the resident container runtime daemon.
        // Service population and measured cgroup bytes are the ownership authority.
        self.global_control_telemetry_complete()
            && !self.build_workload_detected
            && self.service_cgroup_population_known
            && !self.service_cgroup_populated
            && self.container_memory_current < CORE_IDLE_WORKLOAD_NOISE_BYTES
            && self.service_memory_for_idle_gate() < CORE_IDLE_WORKLOAD_NOISE_BYTES
            && self.observed_disk_swap_used() == 0
            && self.observed_total_swap_used() <= CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES
            && self.container_swap_current <= CORE_CONTAINER_ZRAM_SWAP_BUDGET_BYTES
            && self.psi_some_avg10 <= CORE_SERVICE_PSI_SOME_LIMIT
            && self.psi_full_avg10 <= CORE_SERVICE_PSI_FULL_LIMIT
    }

    fn has_live_service_telemetry(&self) -> bool {
        self.global_control_telemetry_complete()
            && !self.build_workload_detected
            && self.service_cgroup_telemetry_complete
            && self.service_cgroup_population_known
            && self.service_cgroup_populated
            && self.service_cgroup_cgroup_id != 0
    }

    fn service_feedback_is_safe(&self) -> bool {
        self.global_control_telemetry_complete()
            && self.observed_disk_swap_used() == 0
            && self.observed_total_swap_used() <= CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES
            && self.container_swap_current <= CORE_CONTAINER_ZRAM_SWAP_BUDGET_BYTES
            && self.psi_some_avg10 <= CORE_SERVICE_GLOBAL_PSI_SOME_LIMIT
            && self.psi_full_avg10 <= CORE_SERVICE_GLOBAL_PSI_FULL_LIMIT
            && self.service_cgroup_psi_some_avg10 <= CORE_SERVICE_PSI_SOME_LIMIT
            && self.service_cgroup_psi_full_avg10 <= CORE_SERVICE_PSI_FULL_LIMIT
    }

    fn protected_runtime_working_set(&self) -> u64 {
        let dirty_writeback = self
            .service_cgroup_file_dirty
            .saturating_add(self.service_cgroup_file_writeback);
        let service_working_set = self
            .service_cgroup_working_set
            .saturating_add(dirty_writeback)
            .min(self.service_cgroup_memory_current);
        service_working_set.saturating_add(self.daemon_cgroup_working_set)
    }

    fn desired_service_target_mib(
        &self,
        current_target_mib: u64,
        configured_memory_mib: u64,
        policy: &CoreMemoryPolicy,
        learned_headroom_mib: u64,
        observed_working_set: u64,
    ) -> u64 {
        let runtime_working_set = self
            .protected_runtime_working_set()
            .max(observed_working_set);
        let proportional_headroom = runtime_working_set / 2;
        let fixed_headroom = policy.service_headroom_mib.saturating_mul(MIB_BYTES);
        let learned_headroom = learned_headroom_mib.saturating_mul(MIB_BYTES);
        let desired_bytes = policy
            .target_mib
            .saturating_mul(MIB_BYTES)
            .saturating_add(runtime_working_set)
            .saturating_add(proportional_headroom.max(fixed_headroom))
            .saturating_add(learned_headroom);
        let desired_mib = desired_bytes.saturating_add(MIB_BYTES - 1) / MIB_BYTES;
        let desired_mib = round_up_mib(desired_mib, CORE_SERVICE_TARGET_QUANTUM_MIB)
            .clamp(policy.service_min_target_mib, configured_memory_mib);

        // Never ask Linux to surrender its final safety reserve merely because
        // its current working-set estimate is small. MemAvailable reflects the
        // guest's own reclaim model and keeps each step inside already-spare
        // capacity whenever possible.
        let safely_available_mib =
            (self.mem_available / MIB_BYTES).saturating_sub(CORE_SERVICE_AVAILABLE_RESERVE_MIB);
        let availability_floor = round_up_mib(
            current_target_mib.saturating_sub(safely_available_mib),
            CORE_SERVICE_TARGET_QUANTUM_MIB,
        );
        let reserve_deficit_mib = CORE_SERVICE_AVAILABLE_RESERVE_MIB
            .saturating_sub(self.mem_available.saturating_add(MIB_BYTES - 1) / MIB_BYTES);
        let reserve_replenishment_target = if reserve_deficit_mib == 0 {
            0
        } else {
            current_target_mib.saturating_add(round_up_mib(
                reserve_deficit_mib,
                CORE_SERVICE_TARGET_QUANTUM_MIB,
            ))
        };
        desired_mib
            .max(availability_floor)
            .max(reserve_replenishment_target)
            .min(configured_memory_mib)
    }

    fn service_feedback_regression(
        &self,
        baseline: &Self,
        adjustment: ServiceCapacityAdjustment,
    ) -> Option<ServiceFeedbackRegression> {
        if self.service_cgroup_cgroup_id != baseline.service_cgroup_cgroup_id
            || self.service_cgroup_workingset_refault_file
                < baseline.service_cgroup_workingset_refault_file
            || self.service_cgroup_pgmajfault < baseline.service_cgroup_pgmajfault
            || self.service_event_counters_reset_since(baseline)
        {
            return Some(ServiceFeedbackRegression {
                kind: ServiceFeedbackRegressionKind::GenerationChanged,
                reason: "service cgroup generation or counters changed".to_string(),
                refault_bytes: 0,
            });
        }
        if self.hard_pressure_regressed_since(baseline) {
            return Some(ServiceFeedbackRegression {
                kind: ServiceFeedbackRegressionKind::HardPressure,
                reason: "memory high/max/OOM or swap growth followed service shrink".to_string(),
                refault_bytes: 0,
            });
        }
        if self.service_cgroup_pgmajfault > baseline.service_cgroup_pgmajfault {
            return Some(ServiceFeedbackRegression {
                kind: ServiceFeedbackRegressionKind::MajorFault,
                reason: "major fault followed service shrink".to_string(),
                refault_bytes: 0,
            });
        }
        let refault_pages = self
            .service_cgroup_workingset_refault_file
            .saturating_sub(baseline.service_cgroup_workingset_refault_file);
        let refault_bytes = refault_pages.saturating_mul(self.page_size_bytes.max(1));
        let shrunk_bytes = adjustment
            .previous_target_mib
            .saturating_sub(adjustment.target_mib)
            .saturating_mul(MIB_BYTES);
        let refault_limit = CORE_SERVICE_REFAULT_MIN_BYTES
            .max(shrunk_bytes / CORE_SERVICE_REFAULT_RATIO_DENOMINATOR);
        if refault_bytes >= refault_limit {
            return Some(ServiceFeedbackRegression {
                kind: ServiceFeedbackRegressionKind::Refault,
                reason: format!(
                    "service refaulted {} MiB after capacity shrink",
                    refault_bytes / 1024 / 1024
                ),
                refault_bytes,
            });
        }
        None
    }

    fn idle_block_reason(&self) -> String {
        format!(
            "active_workloads={} build={} containers={} services={} service_working_set={} stopped_service_pinned={} service_populated={} service_population_known={} service_telemetry_complete={} mem_available_known={} swap_telemetry_complete={} disk_swap_telemetry_complete={} global_psi_telemetry_complete={} total_swap={} disk_swap={} container_swap={} psi_some={:.2} psi_full={:.2}",
            self.active_workloads,
            self.build_workload_detected,
            self.container_memory_current,
            self.service_cgroup_memory_current,
            self.service_cgroup_working_set,
            self.stopped_service_pinned_bytes(),
            self.service_cgroup_populated,
            self.service_cgroup_population_known,
            self.service_cgroup_telemetry_complete,
            self.mem_available_known,
            self.swap_telemetry_complete,
            self.disk_swap_telemetry_complete,
            self.global_psi_telemetry_complete,
            self.observed_total_swap_used(),
            self.observed_disk_swap_used(),
            self.container_swap_current,
            self.psi_some_avg10,
            self.psi_full_avg10
        )
    }
}

fn default_guest_page_size_bytes() -> u64 {
    4096
}

fn round_up_mib(value: u64, quantum: u64) -> u64 {
    if quantum == 0 {
        return value;
    }
    value.saturating_add(quantum - 1) / quantum * quantum
}

fn environment_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok()?.trim().parse().ok()
}

fn spawn_guest_memory_probe(
    socket_path: &std::path::Path,
    probe_generation: u64,
    thread_name: &str,
) -> Result<mpsc::Receiver<(u64, Result<GuestMemorySnapshot, String>)>, String> {
    let socket_path = socket_path.to_path_buf();
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name(thread_name.to_string())
        .spawn(move || {
            let _ = tx.send((
                probe_generation,
                request_guest_memory_snapshot(&socket_path),
            ));
        })
        .map_err(|error| error.to_string())?;
    Ok(rx)
}

#[derive(Debug)]
struct HvfGuestMemoryReclaimer {
    vm: Arc<Vm>,
    flags: u64,
    hard_decommit_only: bool,
    disable_hard_decommit: bool,
    disable_madv_free: bool,
    disable_free_reusable: bool,
    allow_hard_decommit_fallback: Arc<AtomicBool>,
}

impl GuestMemoryReclaimer for HvfGuestMemoryReclaimer {
    fn reclaim_ranges(
        &self,
        memory: &GuestMemory,
        guest_base: u64,
        ranges: &[PageRange],
        authority: ReclaimAuthority,
    ) -> ReclaimReport {
        let mut report = ReclaimReport::default();
        for range in ranges {
            for chunk in host_reclaim_chunks(*range) {
                let Ok(size) = usize::try_from(chunk.size) else {
                    report.discard_skipped_bytes += chunk.size;
                    continue;
                };
                if memory
                    .validate_host_page_aligned(guest_base, chunk.start, size)
                    .is_err()
                {
                    report.discard_skipped_bytes += chunk.size;
                    continue;
                }
                let host_address = match memory.host_address_at(guest_base, chunk.start, size) {
                    Ok(address) => address,
                    Err(_) => {
                        report.discard_skipped_bytes += chunk.size;
                        continue;
                    }
                };
                // Free-page reports are advisory: the guest can return the page to
                // service without a later deflate handshake. Never detach their GPA
                // mapping. Balloon-owned pages have the MUST_TELL_HOST ordering
                // guarantee and may take the deterministic decommit path below.
                if authority == ReclaimAuthority::ReportInFlight {
                    if !self.disable_madv_free
                        && memory.advise_free_at(guest_base, chunk.start, size).is_ok()
                    {
                        report.discard_advised_bytes += chunk.size;
                        report.soft_reclaimed_bytes += chunk.size;
                    } else {
                        report.discard_failed_bytes += chunk.size;
                    }
                    continue;
                }

                let prefer_soft_reclaim = should_prefer_soft_reclaim(
                    authority,
                    self.hard_decommit_only,
                    self.disable_hard_decommit,
                    self.disable_madv_free,
                );
                if prefer_soft_reclaim {
                    if memory.advise_free_at(guest_base, chunk.start, size).is_ok() {
                        report.discard_advised_bytes += chunk.size;
                        report.soft_reclaimed_bytes += chunk.size;
                    } else {
                        report.discard_failed_bytes += chunk.size;
                    }
                    continue;
                }
                let mut guest_mapping_detached = false;
                if !self.hard_decommit_only && !self.disable_free_reusable {
                    if self.vm.unmap_memory(chunk.start, size).is_ok() {
                        guest_mapping_detached = true;
                        // `MADV_FREE_REUSABLE` drops the host footprint while
                        // retaining one contiguous host mapping. Do not follow it
                        // with `MADV_ZERO`: that materializes the pages again and
                        // defeats immediate idle return. MUST_TELL_HOST keeps the
                        // detached GPA inaccessible until deflate restores it.
                        if memory
                            .advise_reusable_at(guest_base, chunk.start, size)
                            .is_ok()
                        {
                            report.discard_advised_bytes += chunk.size;
                            report.soft_reclaimed_bytes += chunk.size;
                            report.reusable_reclaimed_bytes += chunk.size;
                            continue;
                        }
                    }
                }

                if should_attempt_hard_decommit_fallback(
                    self.hard_decommit_only,
                    self.allow_hard_decommit_fallback.load(Ordering::SeqCst),
                    self.disable_hard_decommit,
                ) {
                    if !guest_mapping_detached && self.vm.unmap_memory(chunk.start, size).is_ok() {
                        guest_mapping_detached = true;
                    }
                    if guest_mapping_detached
                        && memory
                            .decommit_zero_at(guest_base, chunk.start, size)
                            .is_ok()
                    {
                        // This is a deterministic fallback when the reusable
                        // advisory path is unavailable. It is more expensive in
                        // VM-map entries, so it is deliberately not the default.
                        report.discard_advised_bytes += chunk.size;
                        report.hard_decommitted_bytes += chunk.size;
                        continue;
                    }
                }

                if guest_mapping_detached {
                    if let Err(error) =
                        self.vm
                            .map_memory(host_address, chunk.start, size, self.flags)
                    {
                        eprintln!(
                            "fatal HVF remap failure after memory reclaim at 0x{:x}+{}: {}",
                            chunk.start, size, error
                        );
                        std::process::abort();
                    }
                }

                if self.hard_decommit_only || self.disable_madv_free {
                    report.discard_failed_bytes += chunk.size;
                    continue;
                }
                match memory.advise_free_at(guest_base, chunk.start, size) {
                    Ok(()) => {
                        report.discard_advised_bytes += chunk.size;
                        report.soft_reclaimed_bytes += chunk.size;
                    }
                    Err(_) => {
                        report.discard_failed_bytes += chunk.size;
                    }
                }
            }
        }
        report
    }

    fn restore_ranges(
        &self,
        memory: &GuestMemory,
        guest_base: u64,
        ranges: &[PageRange],
        mode: BalloonRestoreMode,
    ) -> RestoreReport {
        let mut report = RestoreReport::default();
        for range in ranges {
            for chunk in host_reclaim_chunks(*range) {
                let Ok(size) = usize::try_from(chunk.size) else {
                    report.failed_bytes += chunk.size;
                    continue;
                };
                if mode == BalloonRestoreMode::Reusable
                    && memory
                        .advise_reuse_at(guest_base, chunk.start, size)
                        .is_err()
                {
                    report.failed_bytes += chunk.size;
                    continue;
                }
                let host_address = match memory.host_address_at(guest_base, chunk.start, size) {
                    Ok(address) => address,
                    Err(_) => {
                        report.failed_bytes += chunk.size;
                        continue;
                    }
                };
                match self
                    .vm
                    .map_memory(host_address, chunk.start, size, self.flags)
                {
                    Ok(()) => report.restored_bytes += chunk.size,
                    Err(error) => {
                        eprintln!(
                            "fatal HVF remap failure while restoring balloon memory at 0x{:x}+{}: {}",
                            chunk.start, size, error
                        );
                        std::process::abort();
                    }
                }
            }
        }
        report
    }

    fn hard_decommit_reusable_ranges(
        &self,
        memory: &GuestMemory,
        guest_base: u64,
        ranges: &[PageRange],
    ) -> ReclaimReport {
        let mut report = ReclaimReport::default();
        for range in ranges {
            let Ok(size) = usize::try_from(range.size) else {
                report.discard_failed_bytes += range.size;
                continue;
            };
            if memory
                .validate_host_page_aligned(guest_base, range.start, size)
                .is_err()
            {
                report.discard_failed_bytes += range.size;
                continue;
            }
            // The balloon handler only calls this for fully balloon-owned,
            // already-unmapped GPA ranges. Replacing the retained reusable
            // host mapping with fresh anonymous zero backing is therefore safe
            // and makes the idle footprint deterministic without consulting
            // guest-owned pages.
            match memory.decommit_zero_at(guest_base, range.start, size) {
                Ok(_) => {
                    report.discard_advised_bytes += range.size;
                    report.hard_decommitted_bytes += range.size;
                }
                Err(_) => report.discard_failed_bytes += range.size,
            }
        }
        report
    }
}

fn should_prefer_soft_reclaim(
    authority: ReclaimAuthority,
    hard_decommit_only: bool,
    disable_hard_decommit: bool,
    disable_madv_free: bool,
) -> bool {
    !hard_decommit_only
        && !disable_madv_free
        && (authority == ReclaimAuthority::ReportInFlight || disable_hard_decommit)
}

fn should_attempt_hard_decommit_fallback(
    hard_decommit_only: bool,
    allow_hard_decommit_fallback: bool,
    disable_hard_decommit: bool,
) -> bool {
    !disable_hard_decommit && (hard_decommit_only || allow_hard_decommit_fallback)
}

fn host_reclaim_chunks(range: PageRange) -> Vec<PageRange> {
    let mut chunks = Vec::new();
    let Some(end) = range.start.checked_add(range.size) else {
        return chunks;
    };
    let mut start = range.start;
    while start < end {
        let size = (end - start).min(HOST_RECLAIM_CHUNK_BYTES);
        if size == 0 {
            break;
        }
        chunks.push(PageRange { start, size });
        start = start.saturating_add(size);
    }
    chunks
}

pub struct HvfBootRunner {
    config: JetstreamConfig,
    plan: BootPlan,
    virtio_devices: Vec<VirtioMmioDevicePlan>,
    options: HvfBootOptions,
}

impl HvfBootRunner {
    pub fn new(
        config: JetstreamConfig,
        plan: BootPlan,
        virtio_devices: Vec<VirtioMmioDevicePlan>,
        options: HvfBootOptions,
    ) -> Self {
        Self {
            config,
            plan,
            virtio_devices,
            options,
        }
    }

    pub fn run(self) -> HvfBootReport {
        let mut stages = Vec::new();
        let mut exit_count = 0u64;
        let mut console_output = String::new();

        let memory = match GuestMemory::anonymous(self.plan.ram_size_bytes as usize) {
            Ok(memory) => {
                stage(
                    &mut stages,
                    "guest-memory",
                    true,
                    format!("allocated {} MiB", self.plan.ram_size_bytes / 1024 / 1024),
                );
                memory
            }
            Err(error) => {
                stage(&mut stages, "guest-memory", false, error.to_string());
                return self.finish(
                    false,
                    "guest memory allocation failed",
                    None,
                    exit_count,
                    console_output,
                    stages,
                );
            }
        };
        let mut vm_state = VmState::new(memory, self.plan.vcpu_count);

        let artifacts = match load_boot_artifacts(
            &self.config,
            &self.plan,
            &self.virtio_devices,
            &vm_state.memory,
        ) {
            Ok(artifacts) => {
                stage(
                    &mut stages,
                    "boot-artifacts",
                    true,
                    format!("loaded {} bytes", artifacts.loaded_bytes()),
                );
                artifacts
            }
            Err(error) => {
                stage(&mut stages, "boot-artifacts", false, error.to_string());
                return self.finish(
                    false,
                    "boot artifact load failed",
                    None,
                    exit_count,
                    console_output,
                    stages,
                );
            }
        };

        let vm = match Vm::create() {
            Ok(vm) => {
                stage(
                    &mut stages,
                    "hv_vm_create",
                    true,
                    "created transient HVF VM".to_string(),
                );
                vm
            }
            Err(error) => {
                stage(
                    &mut stages,
                    "hv_vm_create",
                    false,
                    describe_hvf_error(&error),
                );
                return self.finish(
                    false,
                    "HVF VM creation failed",
                    Some(artifacts),
                    exit_count,
                    console_output,
                    stages,
                );
            }
        };
        let vm = Arc::new(vm);

        let gic_layout = GicLayout::new(self.plan.vcpu_count);
        let gic = match Gic::create(gic_layout) {
            Ok(gic) => {
                stage(
                    &mut stages,
                    "hv_gic_create",
                    true,
                    format!(
                        "created GICv3 distributor at 0x{:x} for {} vCPU(s)",
                        self.plan.gic_base, self.plan.vcpu_count
                    ),
                );
                Arc::new(gic)
            }
            Err(error) => {
                stage(&mut stages, "hv_gic_create", false, error.to_string());
                return self.finish(
                    false,
                    "HVF GIC creation failed",
                    Some(artifacts),
                    exit_count,
                    console_output,
                    stages,
                );
            }
        };

        if let Err(error) = vm.map_memory(
            vm_state.memory.as_ptr(),
            self.plan.ram_base,
            vm_state.memory.len(),
            HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC,
        ) {
            stage(&mut stages, "hv_vm_map", false, describe_hvf_error(&error));
            return self.finish(
                false,
                "HVF guest RAM map failed",
                Some(artifacts),
                exit_count,
                console_output,
                stages,
            );
        }
        stage(
            &mut stages,
            "hv_vm_map",
            true,
            format!("mapped RAM at 0x{:x}", self.plan.ram_base),
        );

        let boot_vcpu = match Vcpu::create() {
            Ok(vcpu) => vcpu,
            Err(error) => {
                stage(
                    &mut stages,
                    "hv_vcpu_create",
                    false,
                    format!("cpu 0: {}", describe_hvf_error(&error)),
                );
                let _ = vm.unmap_memory(self.plan.ram_base, vm_state.memory.len());
                return self.finish(
                    false,
                    "HVF boot vCPU creation failed",
                    Some(artifacts),
                    exit_count,
                    console_output,
                    stages,
                );
            }
        };
        if let Err(error) = initialize_boot_vcpu(&boot_vcpu, &artifacts) {
            stage(
                &mut stages,
                "hv_vcpu_set_reg",
                false,
                describe_hvf_error(&error),
            );
            let _ = vm.unmap_memory(self.plan.ram_base, vm_state.memory.len());
            return self.finish(
                false,
                "boot vCPU initialization failed",
                Some(artifacts),
                exit_count,
                console_output,
                stages,
            );
        }
        let mut vcpus: Vec<Option<BootVcpu>> = (0..self.plan.vcpu_count).map(|_| None).collect();
        vcpus[0] = Some(BootVcpu {
            vcpu: boot_vcpu,
            active: true,
        });
        stage(
            &mut stages,
            "hv_vcpu_create",
            true,
            format!(
                "created boot vCPU; {} secondary vCPU(s) will be created on PSCI CPU_ON",
                self.plan.vcpu_count.saturating_sub(1)
            ),
        );
        stage(
            &mut stages,
            "hv_vcpu_set_reg",
            true,
            "initialized boot vCPU reset state".to_string(),
        );

        let uart = Pl011Uart::new(self.plan.uart_base, aarch64::UART_SIZE);
        let psci = match PsciController::new(self.plan.vcpu_count) {
            Ok(psci) => psci,
            Err(error) => {
                stage(&mut stages, "psci", false, error.to_string());
                let _ = vm.unmap_memory(self.plan.ram_base, vm_state.memory.len());
                return self.finish(
                    false,
                    "PSCI setup failed",
                    Some(artifacts),
                    exit_count,
                    console_output,
                    stages,
                );
            }
        };

        let allow_balloon_hard_decommit_fallback = Arc::new(AtomicBool::new(false));
        let memory_reclaimer: Arc<dyn GuestMemoryReclaimer> = Arc::new(HvfGuestMemoryReclaimer {
            vm: vm.clone(),
            flags: HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC,
            hard_decommit_only: debug_flags::enabled("CONJET_MEM_HARD_DECOMMIT_ONLY"),
            disable_hard_decommit: debug_flags::enabled("CONJET_MEM_DISABLE_HARD_DECOMMIT"),
            disable_madv_free: debug_flags::enabled("CONJET_MEM_DISABLE_MADV_FREE"),
            disable_free_reusable: debug_flags::enabled("CONJET_MEM_DISABLE_FREE_REUSABLE"),
            allow_hard_decommit_fallback: allow_balloon_hard_decommit_fallback.clone(),
        });
        match configure_virtio_runtime(
            &self.config,
            &self.virtio_devices,
            &mut vm_state,
            Some(memory_reclaimer),
        ) {
            Ok(detail) => stage(&mut stages, "virtio-runtime", true, detail),
            Err(error) => {
                stage(&mut stages, "virtio-runtime", false, error);
                let _ = vm.unmap_memory(self.plan.ram_base, vm_state.memory.len());
                return self.finish(
                    false,
                    "virtio runtime setup failed",
                    Some(artifacts),
                    exit_count,
                    console_output,
                    stages,
                );
            }
        }

        let mut block_transport_index = 0usize;
        for device in &self.virtio_devices {
            let transport = make_transport(
                &self.config,
                device,
                block_transport_index,
                self.options.balloon_target_mib,
            );
            if device.kind == VirtioDeviceKind::Block {
                block_transport_index += 1;
            }
            if let Err(error) = vm_state.mmio_bus.register(transport) {
                stage(&mut stages, "virtio-mmio", false, error.to_string());
                let _ = vm.unmap_memory(self.plan.ram_base, vm_state.memory.len());
                return self.finish(
                    false,
                    "virtio-mmio registration failed",
                    Some(artifacts),
                    exit_count,
                    console_output,
                    stages,
                );
            }
        }

        stage(
            &mut stages,
            "device-set",
            true,
            format!(
                "registered {} virtio-mmio transports",
                self.virtio_devices.len()
            ),
        );

        let initial_target_mib = self
            .options
            .balloon_target_mib
            .unwrap_or(self.config.memory_mib)
            .min(self.config.memory_mib);
        let core_memory_policy = CoreMemoryPolicy::from_environment(self.config.memory_mib);
        let mut core_memory_controller = CoreMemoryController::new(
            core_memory_policy,
            self.config.memory_mib,
            initial_target_mib,
        );
        let core_memory_metrics = core_memory_controller.metrics();
        let shared = Arc::new(SharedBootState {
            vm_state: Mutex::new(vm_state),
            gic_mmio: Mutex::new(GicMmio::new(gic_layout)),
            uart: Mutex::new(uart),
            psci: Mutex::new(psci),
            console_output: Mutex::new(String::new()),
            stages: Mutex::new(Vec::new()),
            event_reclaim: Mutex::new(EventReclaimMetrics::default()),
            core_memory: Mutex::new(core_memory_metrics),
            allow_balloon_hard_decommit_fallback,
            event_reclaim_inflight: AtomicBool::new(false),
            event_reclaim_pending: AtomicBool::new(false),
            stop_reason: Mutex::new(None),
            stop_requested: AtomicBool::new(false),
        });

        let mut secondaries = Vec::new();
        let (ready_tx, ready_rx) = mpsc::channel();
        for cpu_index in 1..self.plan.vcpu_count {
            secondaries.push(Some(spawn_secondary_vcpu(
                cpu_index,
                self.plan.ram_base,
                shared.clone(),
                gic.clone(),
                ready_tx.clone(),
            )));
        }
        drop(ready_tx);

        let timeout_fired = Arc::new(AtomicBool::new(false));
        let timeout_flag = timeout_fired.clone();
        let vcpu_ids = Arc::new(Mutex::new(vec![vcpus[0].as_ref().unwrap().vcpu.id()]));
        for _ in 1..self.plan.vcpu_count {
            match ready_rx.recv_timeout(Duration::from_secs(5)) {
                Ok(SecondaryReady {
                    cpu_index,
                    result: Ok(vcpu_id),
                }) => {
                    vcpu_ids
                        .lock()
                        .expect("vCPU id mutex poisoned")
                        .push(vcpu_id);
                    stage(
                        &mut stages,
                        "hv_vcpu_secondary_precreate",
                        true,
                        format!("cpu {cpu_index} created and parked vCPU {vcpu_id}"),
                    );
                }
                Ok(SecondaryReady {
                    cpu_index,
                    result: Err(error),
                }) => {
                    stage(
                        &mut stages,
                        "hv_vcpu_secondary_precreate",
                        false,
                        format!("cpu {cpu_index}: {error}"),
                    );
                    let len = shared
                        .vm_state
                        .lock()
                        .expect("VM state mutex poisoned")
                        .memory
                        .len();
                    let _ = vm.unmap_memory(self.plan.ram_base, len);
                    return self.finish(
                        false,
                        "secondary vCPU precreation failed",
                        Some(artifacts),
                        exit_count,
                        console_output,
                        stages,
                    );
                }
                Err(_) => {
                    stage(
                        &mut stages,
                        "hv_vcpu_secondary_precreate",
                        false,
                        "timed out waiting for parked secondary vCPU".to_string(),
                    );
                    let len = shared
                        .vm_state
                        .lock()
                        .expect("VM state mutex poisoned")
                        .memory
                        .len();
                    let _ = vm.unmap_memory(self.plan.ram_base, len);
                    return self.finish(
                        false,
                        "secondary vCPU precreation timed out",
                        Some(artifacts),
                        exit_count,
                        console_output,
                        stages,
                    );
                }
            }
        }
        let memory_control = if let Some(socket_path) = self.options.memory_control_socket.clone() {
            match spawn_memory_control_socket(
                socket_path.clone(),
                shared.clone(),
                self.config.memory_mib,
            ) {
                Ok(handle) => {
                    stage(
                        &mut stages,
                        "memory-control",
                        true,
                        format!("listening on {}", socket_path.display()),
                    );
                    Some(handle)
                }
                Err(error) => {
                    stage(&mut stages, "memory-control", false, error.clone());
                    let len = shared
                        .vm_state
                        .lock()
                        .expect("VM state mutex poisoned")
                        .memory
                        .len();
                    let _ = vm.unmap_memory(self.plan.ram_base, len);
                    return self.finish(
                        false,
                        "memory control socket setup failed",
                        Some(artifacts),
                        exit_count,
                        console_output,
                        stages,
                    );
                }
            }
        } else {
            None
        };
        let docker_probe_enabled =
            self.options.require_docker_ready || self.options.docker_probe_timeout_ms > 0;
        let mut docker_probe = None;
        let docker_probe_rx = if docker_probe_enabled {
            let (tx, rx) = mpsc::channel();
            let socket_path = self.config.boot_source.docker_socket_path.clone();
            let timeout = Duration::from_millis(self.options.docker_probe_timeout_ms);
            let wake_vcpu_ids = vcpu_ids.clone();
            std::thread::Builder::new()
                .name("jetstream-docker-readiness-probe".to_string())
                .spawn(move || {
                    let report = DockerSocketReadinessProbe::new(socket_path).wait_ready(
                        timeout,
                        Duration::from_millis(250),
                        || {
                            let ids = wake_vcpu_ids
                                .lock()
                                .expect("vCPU id mutex poisoned")
                                .clone();
                            let _ = exit_vcpus(&ids);
                        },
                    );
                    let ids = wake_vcpu_ids
                        .lock()
                        .expect("vCPU id mutex poisoned")
                        .clone();
                    let _ = exit_vcpus(&ids);
                    let _ = tx.send(report);
                })
                .expect("failed to spawn Docker readiness probe");
            Some(rx)
        } else {
            None
        };
        let host_tick = if self.options.host_tick_ms > 0 {
            let tick_vcpu_ids = vcpu_ids.clone();
            let tick_shared = shared.clone();
            let interval = Duration::from_millis(self.options.host_tick_ms);
            stage(
                &mut stages,
                "host-tick",
                true,
                format!("waking vCPUs every {} ms", self.options.host_tick_ms),
            );
            Some(
                std::thread::Builder::new()
                    .name("jetstream-host-tick".to_string())
                    .spawn(move || {
                        while !tick_shared.stop_requested.load(Ordering::SeqCst) {
                            std::thread::sleep(interval);
                            let ids = tick_vcpu_ids
                                .lock()
                                .expect("vCPU id mutex poisoned")
                                .clone();
                            let _ = exit_vcpus(&ids);
                        }
                    })
                    .expect("failed to spawn host tick thread"),
            )
        } else {
            None
        };
        let timeout_ms = self.options.max_runtime_ms;
        let watchdog = if timeout_ms > 0 {
            let watchdog_vcpu_ids = vcpu_ids.clone();
            let watchdog_shared = shared.clone();
            Some(std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(timeout_ms));
                timeout_flag.store(true, Ordering::SeqCst);
                watchdog_shared.stop_requested.store(true, Ordering::SeqCst);
                let ids = watchdog_vcpu_ids
                    .lock()
                    .expect("vCPU id mutex poisoned")
                    .clone();
                let _ = exit_vcpus(&ids);
            }))
        } else {
            None
        };

        let mut stop_reason = None;
        let mut conjet_ready_recorded = false;
        let mut docker_probe_finished = false;
        let mut hold_deadline: Option<Instant> = None;
        let mut hold_stop_reason = "ready hold elapsed".to_string();
        let mut last_docker_phase_events = 0u64;
        let mut last_docker_workload_started_events = 0u64;
        let mut last_docker_completed_workload_streams = 0u64;
        let mut last_active_docker_workload_streams = 0u64;
        let mut last_docker_transport_bytes = 0u64;
        let memory_reclaim_socket_path =
            memory_socket_path(&self.config.boot_source.docker_socket_path);
        while exit_count < self.options.max_exits {
            if let Some(deadline) = hold_deadline {
                if Instant::now() >= deadline {
                    stop_reason = Some(hold_stop_reason.clone());
                    break;
                }
            }
            if !docker_probe_finished {
                if let Some(rx) = docker_probe_rx.as_ref() {
                    match rx.try_recv() {
                        Ok(report) => {
                            stage(
                                &mut stages,
                                "docker-api-ready",
                                report.ok,
                                report.message.clone(),
                            );
                            let ok = report.ok;
                            if ok {
                                core_memory_controller.note_runtime_ready(Instant::now(), &shared);
                            }
                            docker_probe = Some(report);
                            docker_probe_finished = true;
                            if ok || self.options.require_docker_ready {
                                if ok && self.options.hold_after_ready_forever {
                                    stage(
                                        &mut stages,
                                        "hold-after-ready",
                                        true,
                                        "holding VM until the host process terminates".to_string(),
                                    );
                                } else if ok && self.options.hold_after_ready_ms > 0 {
                                    hold_deadline = Some(
                                        Instant::now()
                                            + Duration::from_millis(
                                                self.options.hold_after_ready_ms,
                                            ),
                                    );
                                    hold_stop_reason = "Docker API ready".to_string();
                                    stage(
                                        &mut stages,
                                        "hold-after-ready",
                                        true,
                                        format!(
                                            "holding VM for {} ms after Docker readiness",
                                            self.options.hold_after_ready_ms
                                        ),
                                    );
                                } else {
                                    stop_reason = Some(if ok {
                                        "Docker API ready".to_string()
                                    } else {
                                        "Docker API readiness probe failed".to_string()
                                    });
                                    break;
                                }
                            }
                        }
                        Err(mpsc::TryRecvError::Empty) => {}
                        Err(mpsc::TryRecvError::Disconnected) => {
                            if self.options.require_docker_ready {
                                stop_reason =
                                    Some("Docker API readiness probe disconnected".to_string());
                                break;
                            }
                        }
                    }
                }
            }
            if timeout_fired.load(Ordering::SeqCst) {
                stop_reason = Some(format!("boot attempt timed out after {timeout_ms} ms"));
                break;
            }
            let Some(cpu_index) = vcpus
                .iter()
                .position(|vcpu| vcpu.as_ref().is_some_and(|vcpu| vcpu.active))
            else {
                stop_reason = Some("no active vCPUs remain".to_string());
                break;
            };
            let current_vcpu = &vcpus[cpu_index].as_ref().unwrap().vcpu;
            match poll_host_vsock_packets(&shared, self.plan.ram_base, &gic, &self.virtio_devices) {
                Ok(true) => {
                    if let Err(error) = current_vcpu.set_pending_interrupt(0, true) {
                        stage(
                            &mut stages,
                            "hv_vcpu_set_pending_interrupt",
                            false,
                            describe_hvf_error(&error),
                        );
                        stop_reason = Some("vsock interrupt injection failed".to_string());
                        break;
                    }
                }
                Ok(false) => {}
                Err(error) => {
                    stage(&mut stages, "virtio-vsock-host-poll", false, error);
                    stop_reason = Some("virtio-vsock host packet delivery failed".to_string());
                    break;
                }
            }
            let docker_phase_metrics = docker_phase_metrics(&shared);
            let now = Instant::now();
            let docker_transport_bytes = docker_transport_bytes(&docker_phase_metrics);
            let transport_activity = docker_transport_bytes > last_docker_transport_bytes;
            let workload_started =
                docker_phase_metrics.workload_started > last_docker_workload_started_events;
            let workload_active = docker_phase_metrics.active_workload_streams > 0
                && last_active_docker_workload_streams == 0;
            let workload_became_inactive = docker_phase_metrics.active_workload_streams == 0
                && last_active_docker_workload_streams > 0;
            if transport_activity || workload_started || workload_active {
                let transition = if workload_started || workload_active {
                    core_memory_controller.note_workload_started(now, &shared)
                } else {
                    core_memory_controller.note_docker_transport_activity(now, &shared)
                };
                if let Some(transition) = transition {
                    let _ = apply_core_memory_target_transition(
                        &mut core_memory_controller,
                        transition,
                        now,
                        &shared,
                        &gic,
                        &vcpu_ids,
                        &self.virtio_devices,
                        self.config.memory_mib,
                    );
                }
            }
            last_docker_transport_bytes = docker_transport_bytes;
            last_docker_workload_started_events = docker_phase_metrics.workload_started;
            last_active_docker_workload_streams = docker_phase_metrics.active_workload_streams;
            if docker_phase_metrics.total > last_docker_phase_events {
                last_docker_phase_events = docker_phase_metrics.total;
                schedule_guest_memory_reclaim(
                    memory_reclaim_socket_path.clone(),
                    "docker.streamPhaseFinished",
                    shared.clone(),
                );
            }
            if docker_phase_metrics.completed_workload_streams
                > last_docker_completed_workload_streams
            {
                last_docker_completed_workload_streams =
                    docker_phase_metrics.completed_workload_streams;
                schedule_guest_memory_reclaim(
                    memory_reclaim_socket_path.clone(),
                    "docker.workloadFinished",
                    shared.clone(),
                );
                core_memory_controller.note_workload_finished(
                    now,
                    docker_phase_metrics.active_workload_streams > 0,
                    &shared,
                );
            } else if workload_became_inactive {
                core_memory_controller.note_workload_finished(now, false, &shared);
            }
            if core_memory_controller.poll_docker_transport_quiet(now, &shared) {
                schedule_guest_memory_reclaim(
                    memory_reclaim_socket_path.clone(),
                    "docker.transportQuiet",
                    shared.clone(),
                );
            }
            let balloon_target_converged = core_memory_controller
                .should_observe_balloon_convergence(now)
                .then(|| core_balloon_target_converged(&shared));
            if let Some(transition) = core_memory_controller.poll(
                now,
                &memory_reclaim_socket_path,
                balloon_target_converged,
                &shared,
            ) {
                let reduced_to_idle = transition == CoreMemoryTargetTransition::ReduceToIdle;
                let applied = apply_core_memory_target_transition(
                    &mut core_memory_controller,
                    transition,
                    now,
                    &shared,
                    &gic,
                    &vcpu_ids,
                    &self.virtio_devices,
                    self.config.memory_mib,
                );
                if reduced_to_idle && applied {
                    schedule_guest_memory_reclaim(
                        memory_reclaim_socket_path.clone(),
                        "core.idleTarget",
                        shared.clone(),
                    );
                }
            }
            if core_memory_controller.poll_idle_backing_compaction(now) {
                match compact_idle_balloon_backing(&shared, self.plan.ram_base) {
                    Ok(None) => core_memory_controller.defer_idle_backing_compaction(now),
                    Ok(Some(report)) => {
                        core_memory_controller.record_idle_backing_compaction(report, &shared);
                        if report.hard_decommitted_bytes > 0 {
                            schedule_guest_memory_reclaim(
                                memory_reclaim_socket_path.clone(),
                                "core.idleBackingCompacted",
                                shared.clone(),
                            );
                        }
                        if report.failed_bytes > 0 {
                            core_memory_controller.defer_idle_backing_compaction(now);
                        }
                    }
                    Err(error) => core_memory_controller
                        .record_idle_backing_compaction_error(now, error, &shared),
                }
            }
            match poll_host_net_packets(&shared, self.plan.ram_base, &gic, &self.virtio_devices) {
                Ok(true) => {
                    if let Err(error) = current_vcpu.set_pending_interrupt(0, true) {
                        stage(
                            &mut stages,
                            "hv_vcpu_set_pending_interrupt",
                            false,
                            describe_hvf_error(&error),
                        );
                        stop_reason = Some("net interrupt injection failed".to_string());
                        break;
                    }
                }
                Ok(false) => {}
                Err(error) => {
                    stage(&mut stages, "virtio-net-host-poll", false, error);
                    stop_reason = Some("virtio-net host packet delivery failed".to_string());
                    break;
                }
            }
            if let Err(error) = current_vcpu.run() {
                let mut continue_after_probe_wake = false;
                if !docker_probe_finished {
                    if let Some(rx) = docker_probe_rx.as_ref() {
                        if let Ok(report) = rx.try_recv() {
                            stage(
                                &mut stages,
                                "docker-api-ready",
                                report.ok,
                                report.message.clone(),
                            );
                            let ok = report.ok;
                            if ok {
                                core_memory_controller.note_runtime_ready(Instant::now(), &shared);
                            }
                            docker_probe = Some(report);
                            docker_probe_finished = true;
                            if ok || self.options.require_docker_ready {
                                if ok && self.options.hold_after_ready_forever {
                                    stage(
                                        &mut stages,
                                        "hold-after-ready",
                                        true,
                                        "holding VM until the host process terminates".to_string(),
                                    );
                                    continue_after_probe_wake = true;
                                } else if ok && self.options.hold_after_ready_ms > 0 {
                                    hold_deadline = Some(
                                        Instant::now()
                                            + Duration::from_millis(
                                                self.options.hold_after_ready_ms,
                                            ),
                                    );
                                    hold_stop_reason = "Docker API ready".to_string();
                                    stage(
                                        &mut stages,
                                        "hold-after-ready",
                                        true,
                                        format!(
                                            "holding VM for {} ms after Docker readiness",
                                            self.options.hold_after_ready_ms
                                        ),
                                    );
                                    continue_after_probe_wake = true;
                                } else {
                                    stop_reason = Some(if ok {
                                        "Docker API ready".to_string()
                                    } else {
                                        "Docker API readiness probe failed".to_string()
                                    });
                                    break;
                                }
                            }
                        }
                    }
                }
                if continue_after_probe_wake {
                    continue;
                }
                if timeout_fired.load(Ordering::SeqCst) {
                    stop_reason = Some(format!("boot attempt timed out after {timeout_ms} ms"));
                    break;
                }
                stage(
                    &mut stages,
                    "hv_vcpu_run",
                    false,
                    describe_hvf_error(&error),
                );
                stop_reason = Some("hv_vcpu_run failed".to_string());
                break;
            }
            exit_count += 1;
            let Some(exit) = current_vcpu.exit_info() else {
                stage(
                    &mut stages,
                    "hv_vcpu_exit",
                    false,
                    "missing exit pointer".to_string(),
                );
                stop_reason = Some("missing HVF exit pointer".to_string());
                break;
            };
            if exit.reason == 0 {
                continue;
            }
            if exit.reason == 2 {
                if let Err(error) = gic.set_vtimer_pending(current_vcpu.id()) {
                    stage(
                        &mut stages,
                        "hv_gic_set_redistributor_vtimer_pending",
                        false,
                        error.to_string(),
                    );
                    stop_reason = Some("virtual timer GIC injection failed".to_string());
                    break;
                }
                if let Err(error) = current_vcpu.set_pending_interrupt(0, true) {
                    stage(
                        &mut stages,
                        "hv_vcpu_set_pending_interrupt",
                        false,
                        describe_hvf_error(&error),
                    );
                    stop_reason = Some("virtual timer interrupt injection failed".to_string());
                    break;
                }
                continue;
            }
            if exit.reason != 1 {
                stage(
                    &mut stages,
                    "hv_vcpu_exit",
                    false,
                    format!("unsupported exit reason {}", exit.reason),
                );
                stop_reason = Some(format!("unsupported HVF exit reason {}", exit.reason));
                break;
            }

            match handle_exception_exit(
                current_vcpu,
                self.plan.ram_base,
                &gic,
                &shared,
                exit.exception.syndrome,
                exit.exception.physical_address,
            ) {
                Ok(HandledExit::Continue) => {
                    let drained = shared
                        .uart
                        .lock()
                        .expect("UART mutex poisoned")
                        .drain_string();
                    if !drained.is_empty() {
                        append_console_output(&mut console_output, &drained);
                        if console_output.contains("CONJET_INIT_READY") && !conjet_ready_recorded {
                            conjet_ready_recorded = true;
                            stage(
                                &mut stages,
                                "conjet-init",
                                true,
                                "captured CONJET_INIT_READY on serial console".to_string(),
                            );
                            if !self.options.require_docker_ready
                                && self.options.docker_probe_timeout_ms == 0
                            {
                                core_memory_controller.note_runtime_ready(Instant::now(), &shared);
                            }
                            if self.options.require_conjet_ready
                                && !self.options.require_docker_ready
                                && self.options.docker_probe_timeout_ms == 0
                            {
                                if self.options.hold_after_ready_forever {
                                    stage(
                                        &mut stages,
                                        "hold-after-ready",
                                        true,
                                        "holding VM until the host process terminates".to_string(),
                                    );
                                } else if self.options.hold_after_ready_ms > 0 {
                                    hold_deadline = Some(
                                        Instant::now()
                                            + Duration::from_millis(
                                                self.options.hold_after_ready_ms,
                                            ),
                                    );
                                    hold_stop_reason = "conjet-init ready captured".to_string();
                                    stage(
                                        &mut stages,
                                        "hold-after-ready",
                                        true,
                                        format!(
                                            "holding VM for {} ms after conjet-init readiness",
                                            self.options.hold_after_ready_ms
                                        ),
                                    );
                                } else {
                                    stop_reason = Some("conjet-init ready captured".to_string());
                                    break;
                                }
                            }
                        }
                    }
                }
                Ok(HandledExit::Stop(action)) => match action {
                    StopAction::StopVm(reason) => {
                        stop_reason = Some(reason);
                        break;
                    }
                    StopAction::CpuOff => {
                        if let Some(vcpu) = vcpus[cpu_index].as_mut() {
                            vcpu.active = false;
                        }
                    }
                    StopAction::CpuOn {
                        target_cpu,
                        entry_point,
                        context_id,
                    } => {
                        let target = target_cpu as usize;
                        if target == 0 || target > secondaries.len() {
                            continue;
                        }
                        let Some(secondary) = secondaries
                            .get(target - 1)
                            .and_then(|secondary| secondary.as_ref())
                        else {
                            continue;
                        };
                        match secondary.start_tx.send(SecondaryStart {
                            entry_point,
                            context_id,
                        }) {
                            Ok(()) => {
                                let _ = shared
                                    .psci
                                    .lock()
                                    .expect("PSCI mutex poisoned")
                                    .mark_cpu_online(target_cpu);
                                stage(
                                    &mut stages,
                                    "psci-cpu-on",
                                    true,
                                    format!(
                                        "cpu {target_cpu} entry=0x{entry_point:x} context=0x{context_id:x}"
                                    ),
                                );
                            }
                            Err(error) => {
                                stage(
                                    &mut stages,
                                    "psci-cpu-on",
                                    false,
                                    format!(
                                        "cpu {target_cpu}: failed to signal secondary thread: {error}"
                                    ),
                                );
                                stop_reason =
                                    Some("secondary vCPU CPU_ON signal failed".to_string());
                                break;
                            }
                        }
                    }
                },
                Err(error) => {
                    stage(&mut stages, "hv_vcpu_exit", false, error);
                    stop_reason = Some("unsupported exception exit".to_string());
                    break;
                }
            }
            if shared.stop_requested.load(Ordering::SeqCst) {
                stop_reason = shared
                    .stop_reason
                    .lock()
                    .expect("stop reason mutex poisoned")
                    .clone();
                break;
            }
        }

        shared.stop_requested.store(true, Ordering::SeqCst);
        let ids = vcpu_ids.lock().expect("vCPU id mutex poisoned").clone();
        let _ = exit_vcpus(&ids);

        append_console_output(
            &mut console_output,
            &shared
                .console_output
                .lock()
                .expect("console mutex poisoned")
                .clone(),
        );
        stages.extend(
            shared
                .stages
                .lock()
                .expect("stage mutex poisoned")
                .drain(..),
        );

        append_console_output(
            &mut console_output,
            &shared
                .uart
                .lock()
                .expect("UART mutex poisoned")
                .drain_string(),
        );
        if exit_count >= self.options.max_exits {
            stage(
                &mut stages,
                "hv_vcpu_run",
                false,
                format!("stopped after max exit budget {}", self.options.max_exits),
            );
        }
        if timeout_fired.load(Ordering::SeqCst) {
            stage(
                &mut stages,
                "hv_vcpus_exit",
                true,
                format!("watchdog woke vCPUs after {timeout_ms} ms"),
            );
        }
        drop(host_tick);
        drop(memory_control);
        drop(watchdog);
        let len = shared
            .vm_state
            .lock()
            .expect("VM state mutex poisoned")
            .memory
            .len();
        let _ = vm.unmap_memory(self.plan.ram_base, len);

        let ready = conjet_ready_recorded || console_output.contains("CONJET_INIT_READY");
        let message = stop_reason.unwrap_or_else(|| {
            if ready {
                "conjet-init ready captured".to_string()
            } else {
                "boot loop stopped without Conjet readiness".to_string()
            }
        });
        let timed_out = message.contains("timed out");
        let docker_ready = docker_probe
            .as_ref()
            .is_some_and(|probe: &DockerProbeReport| probe.ok);
        let ok = if timed_out {
            false
        } else if self.options.require_docker_ready {
            docker_ready
        } else if self.options.require_conjet_ready {
            ready
        } else {
            !console_output.is_empty()
        };
        let balloon_metrics = shared
            .vm_state
            .lock()
            .expect("VM state mutex poisoned")
            .devices
            .balloon_metrics();
        self.finish_with_docker_probe(
            ok,
            message,
            Some(artifacts),
            exit_count,
            console_output,
            docker_probe,
            balloon_metrics,
            stages,
        )
    }

    fn finish(
        &self,
        ok: bool,
        message: impl Into<String>,
        boot_artifacts: Option<BootArtifacts>,
        exit_count: u64,
        console_output: String,
        stages: Vec<HvfBootStage>,
    ) -> HvfBootReport {
        self.finish_with_docker_probe(
            ok,
            message,
            boot_artifacts,
            exit_count,
            console_output,
            None,
            BalloonMetrics::default(),
            stages,
        )
    }

    fn finish_with_docker_probe(
        &self,
        ok: bool,
        message: impl Into<String>,
        boot_artifacts: Option<BootArtifacts>,
        exit_count: u64,
        console_output: String,
        docker_probe: Option<DockerProbeReport>,
        balloon: BalloonMetrics,
        stages: Vec<HvfBootStage>,
    ) -> HvfBootReport {
        let docker_ready = docker_probe.as_ref().is_some_and(|probe| probe.ok);
        HvfBootReport {
            ok,
            message: message.into(),
            boot_plan: self.plan.clone(),
            boot_artifacts,
            exit_count,
            console_output,
            docker_ready,
            docker_probe,
            balloon,
            stages,
        }
    }
}

enum HandledExit {
    Continue,
    Stop(StopAction),
}

enum StopAction {
    StopVm(String),
    CpuOff,
    CpuOn {
        target_cpu: u64,
        entry_point: u64,
        context_id: u64,
    },
}

fn initialize_boot_vcpu(vcpu: &Vcpu, artifacts: &BootArtifacts) -> Result<(), HvfError> {
    let reset = &artifacts.reset_state;
    vcpu.set_sys_reg(HV_SYS_REG_MPIDR_EL1, 0)?;
    vcpu.set_reg(HV_REG_X0, reset.x0)?;
    vcpu.set_reg(HV_REG_X1, reset.x1)?;
    vcpu.set_reg(HV_REG_X2, reset.x2)?;
    vcpu.set_reg(HV_REG_X3, reset.x3)?;
    vcpu.set_reg(HV_REG_PC, reset.pc)?;
    vcpu.set_reg(HV_REG_CPSR, reset.cpsr)?;
    vcpu.set_vtimer_mask(false)?;
    Ok(())
}

fn initialize_secondary_vcpu(
    vcpu: &Vcpu,
    cpu_index: u8,
    entry_point: u64,
    context_id: u64,
) -> Result<(), HvfError> {
    vcpu.set_sys_reg(HV_SYS_REG_MPIDR_EL1, u64::from(cpu_index))?;
    vcpu.set_reg(HV_REG_X0, context_id)?;
    vcpu.set_reg(HV_REG_X1, 0)?;
    vcpu.set_reg(HV_REG_X2, 0)?;
    vcpu.set_reg(HV_REG_X3, 0)?;
    vcpu.set_reg(HV_REG_PC, entry_point)?;
    vcpu.set_reg(HV_REG_CPSR, 0x3c5)?;
    vcpu.set_vtimer_mask(false)?;
    Ok(())
}

fn spawn_secondary_vcpu(
    cpu_index: u8,
    guest_base: u64,
    shared: Arc<SharedBootState>,
    gic: Arc<Gic>,
    ready_tx: mpsc::Sender<SecondaryReady>,
) -> SecondaryVcpu {
    let (start_tx, start_rx) = mpsc::channel::<SecondaryStart>();
    std::thread::Builder::new()
        .name(format!("jetstream-vcpu-{cpu_index}"))
        .spawn(move || {
            let vcpu = match Vcpu::create() {
                Ok(vcpu) => vcpu,
                Err(error) => {
                    let detail = describe_hvf_error(&error);
                    let _ = ready_tx.send(SecondaryReady {
                        cpu_index,
                        result: Err(detail.clone()),
                    });
                    shared_stage(
                        &shared,
                        "hv_vcpu_create",
                        false,
                        format!("cpu {cpu_index}: {detail}"),
                    );
                    return;
                }
            };
            let vcpu_id = vcpu.id();
            let _ = ready_tx.send(SecondaryReady {
                cpu_index,
                result: Ok(vcpu_id),
            });

            let Ok(start) = start_rx.recv() else {
                return;
            };
            if let Err(error) =
                initialize_secondary_vcpu(&vcpu, cpu_index, start.entry_point, start.context_id)
            {
                let detail = describe_hvf_error(&error);
                shared_stage(
                    &shared,
                    "hv_vcpu_set_reg",
                    false,
                    format!("cpu {cpu_index}: {detail}"),
                );
                request_shared_stop(
                    &shared,
                    format!("secondary cpu {cpu_index} initialization failed"),
                );
                return;
            }
            shared_stage(
                &shared,
                "hv_vcpu_secondary_online",
                true,
                format!(
                    "cpu {cpu_index} vCPU {vcpu_id} pc=0x{:x} x0=0x{:x}",
                    start.entry_point, start.context_id
                ),
            );

            while !shared.stop_requested.load(Ordering::SeqCst) {
                if let Err(error) = vcpu.run() {
                    if shared.stop_requested.load(Ordering::SeqCst) {
                        break;
                    }
                    let detail = describe_hvf_error(&error);
                    shared_stage(
                        &shared,
                        "hv_vcpu_run",
                        false,
                        format!("cpu {cpu_index}: {detail}"),
                    );
                    request_shared_stop(&shared, format!("secondary cpu {cpu_index} run failed"));
                    break;
                }
                let Some(exit) = vcpu.exit_info() else {
                    request_shared_stop(
                        &shared,
                        format!("secondary cpu {cpu_index} missing HVF exit pointer"),
                    );
                    break;
                };
                if exit.reason == 0 {
                    continue;
                }
                if exit.reason == 2 {
                    if let Err(error) = gic.set_vtimer_pending(vcpu.id()) {
                        shared_stage(
                            &shared,
                            "hv_gic_set_redistributor_vtimer_pending",
                            false,
                            format!("cpu {cpu_index}: {error}"),
                        );
                        request_shared_stop(
                            &shared,
                            format!("secondary cpu {cpu_index} virtual timer GIC injection failed"),
                        );
                        break;
                    }
                    if let Err(error) = vcpu.set_pending_interrupt(0, true) {
                        shared_stage(
                            &shared,
                            "hv_vcpu_set_pending_interrupt",
                            false,
                            format!("cpu {cpu_index}: {}", describe_hvf_error(&error)),
                        );
                        request_shared_stop(
                            &shared,
                            format!("secondary cpu {cpu_index} virtual timer injection failed"),
                        );
                        break;
                    }
                    continue;
                }
                if exit.reason != 1 {
                    request_shared_stop(
                        &shared,
                        format!(
                            "secondary cpu {cpu_index} unsupported HVF exit {}",
                            exit.reason
                        ),
                    );
                    break;
                }

                match handle_exception_exit(
                    &vcpu,
                    guest_base,
                    &gic,
                    &shared,
                    exit.exception.syndrome,
                    exit.exception.physical_address,
                ) {
                    Ok(HandledExit::Continue) => {
                        append_shared_console(&shared);
                    }
                    Ok(HandledExit::Stop(StopAction::CpuOff)) => break,
                    Ok(HandledExit::Stop(StopAction::StopVm(reason))) => {
                        request_shared_stop(&shared, reason);
                        break;
                    }
                    Ok(HandledExit::Stop(StopAction::CpuOn { .. })) => {
                        request_shared_stop(
                            &shared,
                            format!("secondary cpu {cpu_index} attempted nested CPU_ON"),
                        );
                        break;
                    }
                    Err(error) => {
                        shared_stage(
                            &shared,
                            "hv_vcpu_exit",
                            false,
                            format!("cpu {cpu_index}: {error}"),
                        );
                        request_shared_stop(
                            &shared,
                            format!("secondary cpu {cpu_index} unsupported exception exit"),
                        );
                        break;
                    }
                }
            }
        })
        .expect("failed to spawn secondary vCPU thread");
    SecondaryVcpu { start_tx }
}

fn shared_stage(shared: &SharedBootState, name: &'static str, ok: bool, detail: String) {
    shared
        .stages
        .lock()
        .expect("stage mutex poisoned")
        .push(HvfBootStage { name, ok, detail });
}

fn append_shared_console(shared: &SharedBootState) {
    let drained = shared
        .uart
        .lock()
        .expect("UART mutex poisoned")
        .drain_string();
    if !drained.is_empty() {
        append_console_output(
            &mut shared
                .console_output
                .lock()
                .expect("console mutex poisoned"),
            &drained,
        );
    }
}

fn append_console_output(output: &mut String, incoming: &str) {
    output.push_str(incoming);
    if output.len() <= MAX_RETAINED_CONSOLE_BYTES {
        return;
    }
    let mut retained_start = output.len().saturating_sub(MAX_RETAINED_CONSOLE_BYTES);
    while retained_start < output.len() && !output.is_char_boundary(retained_start) {
        retained_start += 1;
    }
    *output = output[retained_start..].to_owned();
}

fn request_shared_stop(shared: &SharedBootState, reason: String) {
    *shared
        .stop_reason
        .lock()
        .expect("stop reason mutex poisoned") = Some(reason);
    shared.stop_requested.store(true, Ordering::SeqCst);
}

fn handle_exception_exit(
    vcpu: &Vcpu,
    guest_base: u64,
    gic: &Gic,
    shared: &SharedBootState,
    syndrome: u64,
    physical_address: u64,
) -> Result<HandledExit, String> {
    let exception_class = (syndrome >> 26) & 0x3f;
    match exception_class {
        0x16 => {
            let mut psci = shared.psci.lock().expect("PSCI mutex poisoned");
            handle_hvc(vcpu, &mut psci)
        }
        0x24 | 0x25 => {
            let mut vm_state = shared.vm_state.lock().expect("VM state mutex poisoned");
            let mut gic_mmio = shared.gic_mmio.lock().expect("GIC MMIO mutex poisoned");
            let mut uart = shared.uart.lock().expect("UART mutex poisoned");
            handle_data_abort(
                vcpu,
                &mut vm_state,
                guest_base,
                &mut gic_mmio,
                &mut uart,
                gic,
                syndrome,
                physical_address,
            )
        }
        0x18 => {
            advance_pc(vcpu).map_err(|error| describe_hvf_error(&error))?;
            Ok(HandledExit::Continue)
        }
        _ => Err(format!(
            "unsupported exception syndrome=0x{syndrome:x} ec=0x{exception_class:x} pa=0x{physical_address:x}"
        )),
    }
}

fn handle_hvc(vcpu: &Vcpu, psci: &mut PsciController) -> Result<HandledExit, String> {
    let function_id = vcpu
        .get_reg(HV_REG_X0)
        .map_err(|error| describe_hvf_error(&error))? as u32;
    let x1 = vcpu
        .get_reg(HV_REG_X1)
        .map_err(|error| describe_hvf_error(&error))?;
    let x2 = vcpu
        .get_reg(HV_REG_X2)
        .map_err(|error| describe_hvf_error(&error))?;
    let x3 = vcpu
        .get_reg(HV_REG_X3)
        .map_err(|error| describe_hvf_error(&error))?;
    let response = psci.handle(function_id, x1, x2, x3);
    vcpu.set_reg(HV_REG_X0, response.return_value)
        .map_err(|error| describe_hvf_error(&error))?;
    match response.action {
        PsciAction::SystemOff => Ok(HandledExit::Stop(StopAction::StopVm(
            "guest requested PSCI SYSTEM_OFF".to_string(),
        ))),
        PsciAction::SystemReset => Ok(HandledExit::Stop(StopAction::StopVm(
            "guest requested PSCI SYSTEM_RESET".to_string(),
        ))),
        PsciAction::CpuOff => Ok(HandledExit::Stop(StopAction::CpuOff)),
        PsciAction::CpuOn { target_cpu, .. } => Ok(HandledExit::Stop(StopAction::CpuOn {
            target_cpu,
            entry_point: x2,
            context_id: x3,
        })),
        PsciAction::None => Ok(HandledExit::Continue),
    }
}

fn handle_data_abort(
    vcpu: &Vcpu,
    vm_state: &mut VmState,
    guest_base: u64,
    gic_mmio: &mut GicMmio,
    uart: &mut Pl011Uart,
    gic: &Gic,
    syndrome: u64,
    physical_address: u64,
) -> Result<HandledExit, String> {
    if ((syndrome >> 24) & 1) != 1 {
        return Err("data abort exit did not include a valid instruction syndrome".to_string());
    }
    let access_size = 1u8 << ((syndrome >> 22) & 0x3);
    let is_write = ((syndrome >> 6) & 1) == 1;
    let register = ((syndrome >> 16) & 0x1f) as u32;
    if is_write {
        let value = if register == 31 {
            0
        } else {
            vcpu.get_reg(register)
                .map_err(|error| describe_hvf_error(&error))?
        };
        if physical_address >= uart.base() && physical_address < uart.base() + uart.size() {
            uart.write(physical_address - uart.base(), value, access_size)
                .map_err(describe_mmio_error)?;
        } else if gic_mmio.contains(physical_address) {
            gic_mmio.write(physical_address, value, access_size)?;
        } else {
            vm_state
                .mmio_bus
                .write(physical_address, value, access_size)
                .map_err(describe_mmio_error)?;
            maybe_deassert_virtio_irq(vm_state, gic, physical_address, value)?;
            execute_virtio_notification(vm_state, guest_base, physical_address)
                .map_err(|error| format!("virtio queue execution failed: {error}"))?;
            if maybe_assert_virtio_irq(vm_state, gic, physical_address)? {
                vcpu.set_pending_interrupt(0, true)
                    .map_err(|error| describe_hvf_error(&error))?;
            }
        }
    } else {
        let value =
            if physical_address >= uart.base() && physical_address < uart.base() + uart.size() {
                uart.read(physical_address - uart.base(), access_size)
                    .map_err(describe_mmio_error)?
            } else if gic_mmio.contains(physical_address) {
                gic_mmio.read(physical_address, access_size)?
            } else {
                vm_state
                    .mmio_bus
                    .read(physical_address, access_size)
                    .map_err(describe_mmio_error)?
            };
        if register != 31 {
            vcpu.set_reg(register, value)
                .map_err(|error| describe_hvf_error(&error))?;
        }
    }
    advance_pc(vcpu).map_err(|error| describe_hvf_error(&error))?;
    Ok(HandledExit::Continue)
}

fn configure_virtio_runtime(
    config: &JetstreamConfig,
    devices: &[VirtioMmioDevicePlan],
    vm_state: &mut VmState,
    memory_reclaimer: Option<Arc<dyn GuestMemoryReclaimer>>,
) -> Result<String, String> {
    let mut block_paths = vec![config.boot_source.root_disk_path.clone()];
    if let Some(path) = config.boot_source.data_disk_path.clone() {
        block_paths.push(path);
    }
    if let Some(path) = config.boot_source.swap_disk_path.clone() {
        block_paths.push(path);
    }
    let mut next_block = 0usize;
    let mut block_count = 0usize;
    let mut net_count = 0usize;
    let mut vsock_count = 0usize;
    for device in devices {
        match device.kind {
            VirtioDeviceKind::Block => {
                let path = block_paths.get(next_block).ok_or_else(|| {
                    "missing block backing path for virtio-blk device".to_string()
                })?;
                let raw = RawBlockDevice::open(path, format!("conjet-blk{next_block}"), false)
                    .map_err(|error| error.to_string())?;
                vm_state
                    .devices
                    .block
                    .insert(device.mmio_base, BlockQueueHandler::new(raw));
                next_block += 1;
                block_count += 1;
            }
            VirtioDeviceKind::Net => {
                let bridge = if let Some(existing) = vm_state.devices.vmnet_bridge.as_ref() {
                    existing.clone()
                } else {
                    let bridge = std::sync::Arc::new(std::sync::Mutex::new(
                        VmnetPacketBridge::start_default().map_err(|error| error.to_string())?,
                    ));
                    vm_state.devices.vmnet_bridge = Some(bridge.clone());
                    bridge
                };
                vm_state
                    .devices
                    .net
                    .insert(device.mmio_base, NetQueueHandler::with_bridge(bridge));
                net_count += 1;
            }
            VirtioDeviceKind::Vsock => {
                let docker_bridge = if let Some(existing) = vm_state.devices.docker_bridge.as_ref()
                {
                    existing.state.clone()
                } else {
                    let bridge = HostUnixVsockBridge::bind(&config.boot_source.docker_socket_path)
                        .map_err(|error| error.to_string())?;
                    let state = bridge.state.clone();
                    vm_state.devices.docker_bridge = Some(bridge);
                    state
                };
                let memory_socket_path = memory_socket_path(&config.boot_source.docker_socket_path);
                let memory_bridge = if let Some(existing) = vm_state.devices.memory_bridge.as_ref()
                {
                    existing.state.clone()
                } else {
                    let bridge = HostUnixVsockBridge::bind_with_guest_port(
                        &memory_socket_path,
                        MEMORY_BRIDGE_PORT,
                        50_000,
                    )
                    .map_err(|error| error.to_string())?;
                    let state = bridge.state.clone();
                    vm_state.devices.memory_bridge = Some(bridge);
                    state
                };
                vm_state.devices.vsock.insert(
                    device.mmio_base,
                    VsockQueueHandler::with_bridges(vec![docker_bridge, memory_bridge]),
                );
                vsock_count += 1;
            }
            VirtioDeviceKind::Balloon => {
                let handler = if let Some(reclaimer) = memory_reclaimer.clone() {
                    BalloonQueueHandler::with_reclaimer(reclaimer)
                } else {
                    BalloonQueueHandler::new()
                };
                vm_state.devices.balloon.insert(device.mmio_base, handler);
            }
            VirtioDeviceKind::Rng => {}
        }
    }
    Ok(format!(
        "configured {block_count} block backend(s), {net_count} net backend(s), {vsock_count} vsock backend(s), docker socket {}, memory socket {}",
        config.boot_source.docker_socket_path.display(),
        memory_socket_path(&config.boot_source.docker_socket_path).display()
    ))
}

struct MemoryControlSocket {
    stop: Arc<AtomicBool>,
    socket_path: PathBuf,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Drop for MemoryControlSocket {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = UnixStream::connect(&self.socket_path);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum MemoryControlRequest {
    Metrics,
    SetTargetBytes { target_bytes: u64 },
    SetTargetMib { target_mib: u64 },
}

fn memory_control_target_mutation_error(request: &MemoryControlRequest) -> Option<String> {
    match request {
        MemoryControlRequest::Metrics => None,
        MemoryControlRequest::SetTargetBytes { target_bytes } => Some(format!(
            "target mutation is disabled; Jetstream owns automatic memory policy (requested {target_bytes} bytes)"
        )),
        MemoryControlRequest::SetTargetMib { target_mib } => Some(format!(
            "target mutation is disabled; Jetstream owns automatic memory policy (requested {target_mib} MiB)"
        )),
    }
}

#[derive(Debug, Serialize)]
struct MemoryControlResponse {
    ok: bool,
    message: String,
    configured_mib: u64,
    target_mib: u64,
    target_pages: u32,
    docker_phase_events: DockerPhaseControlMetrics,
    event_reclaim: EventReclaimMetrics,
    core_memory: CoreMemoryControllerMetrics,
    balloon: BalloonMetrics,
    memory_ledger: MemoryLedgerSummary,
    host_memory: HostMemoryFootprint,
}

#[derive(Debug, Clone, Default, Serialize)]
struct DockerPhaseControlMetrics {
    total: u64,
    request: u64,
    response: u64,
    workload_started: u64,
    completed_streams: u64,
    completed_workload_streams: u64,
    active_workload_streams: u64,
    request_bytes: u64,
    response_bytes: u64,
}

#[derive(Debug, Clone, Copy, Default, Serialize)]
struct HostMemoryFootprint {
    resident_bytes: Option<u64>,
    physical_footprint_bytes: Option<u64>,
}

fn spawn_memory_control_socket(
    socket_path: PathBuf,
    shared: Arc<SharedBootState>,
    configured_memory_mib: u64,
) -> Result<MemoryControlSocket, String> {
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    if socket_path.exists() {
        std::fs::remove_file(&socket_path).map_err(|error| error.to_string())?;
    }
    let listener = UnixListener::bind(&socket_path).map_err(|error| error.to_string())?;
    std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| error.to_string())?;
    listener
        .set_nonblocking(true)
        .map_err(|error| error.to_string())?;
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let thread_path = socket_path.clone();
    let thread = std::thread::Builder::new()
        .name("jetstream-memory-control".to_string())
        .spawn(move || {
            while !thread_stop.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        handle_memory_control_stream(stream, &shared, configured_memory_mib);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(25));
                    }
                    Err(_) => break,
                }
            }
            let _ = std::fs::remove_file(thread_path);
        })
        .map_err(|error| error.to_string())?;
    Ok(MemoryControlSocket {
        stop,
        socket_path,
        thread: Some(thread),
    })
}

fn handle_memory_control_stream(
    mut stream: UnixStream,
    shared: &SharedBootState,
    configured_memory_mib: u64,
) {
    let _ = stream.set_read_timeout(Some(MEMORY_CONTROL_READ_TIMEOUT));
    let response = match stream.try_clone() {
        Ok(clone) => {
            let mut reader = BufReader::new(clone);
            let mut request = Vec::new();
            match reader
                .by_ref()
                .take((MAX_MEMORY_CONTROL_REQUEST_BYTES + 1) as u64)
                .read_until(b'\n', &mut request)
            {
                Ok(0) => memory_control_error("empty request", configured_memory_mib),
                Ok(_) if request.len() > MAX_MEMORY_CONTROL_REQUEST_BYTES => memory_control_error(
                    &format!("request exceeds {MAX_MEMORY_CONTROL_REQUEST_BYTES} byte limit"),
                    configured_memory_mib,
                ),
                Ok(_) => match serde_json::from_slice::<MemoryControlRequest>(&request) {
                    Ok(request) => {
                        handle_memory_control_request(request, shared, configured_memory_mib)
                            .unwrap_or_else(|error| {
                                memory_control_error(&error, configured_memory_mib)
                            })
                    }
                    Err(error) => memory_control_error(
                        &format!("invalid request: {error}"),
                        configured_memory_mib,
                    ),
                },
                Err(error) => {
                    memory_control_error(&format!("read failed: {error}"), configured_memory_mib)
                }
            }
        }
        Err(error) => memory_control_error(
            &format!("stream clone failed: {error}"),
            configured_memory_mib,
        ),
    };
    let _ = serde_json::to_writer(&mut stream, &response);
    let _ = stream.write_all(b"\n");
    let _ = stream.flush();
}

fn handle_memory_control_request(
    request: MemoryControlRequest,
    shared: &SharedBootState,
    configured_memory_mib: u64,
) -> Result<MemoryControlResponse, String> {
    if let Some(error) = memory_control_target_mutation_error(&request) {
        return Err(error);
    }
    memory_control_snapshot(shared, configured_memory_mib)
}

fn set_balloon_target_bytes(
    shared: &SharedBootState,
    gic: &Gic,
    devices: &[VirtioMmioDevicePlan],
    configured_memory_mib: u64,
    target_bytes: u64,
) -> Result<(), String> {
    let target_pages = balloon_target_pages(configured_memory_mib, target_bytes);
    let mut vm_state = shared.vm_state.lock().expect("VM state mutex poisoned");
    let mut updated = 0usize;
    for device in devices
        .iter()
        .filter(|device| device.kind == VirtioDeviceKind::Balloon)
    {
        let base = device.mmio_base;
        let actual_pages = vm_state
            .devices
            .balloon
            .get(&base)
            .map(|handler| handler.metrics().actual_pages.min(u64::from(u32::MAX)) as u32)
            .unwrap_or(0);
        if let Some(transport) = vm_state.mmio_bus.virtio_mut_at(base) {
            let free_page_hint_cmd_id = balloon_free_page_hint_cmd_id(transport);
            transport.update_configuration(
                balloon::configuration(target_pages, actual_pages, free_page_hint_cmd_id),
                true,
            );
            gic.set_spi(transport.plan.irq, true)
                .map_err(|error| error.to_string())?;
            updated += 1;
        }
    }
    if updated == 0 {
        return Err("virtio-balloon device is not registered".to_string());
    }
    Ok(())
}

/// Converts already-detached reusable balloon ranges only after every balloon
/// device has actually reached the idle target. This keeps the fast reusable
/// path while Docker is active, then returns the retained host footprint once
/// the guest has proven idle.
fn compact_idle_balloon_backing(
    shared: &SharedBootState,
    guest_base: u64,
) -> Result<Option<IdleBackingCompactionReport>, String> {
    let mut vm_state = shared.vm_state.lock().expect("VM state mutex poisoned");
    let balloon_bases = vm_state.devices.balloon.keys().copied().collect::<Vec<_>>();
    if balloon_bases.is_empty() {
        return Err("virtio-balloon device is not registered".to_string());
    }

    for base in &balloon_bases {
        let target_pages = vm_state
            .mmio_bus
            .virtio_mut_at(*base)
            .and_then(|transport| {
                transport
                    .configuration_bytes()
                    .get(..4)
                    .and_then(|bytes| bytes.try_into().ok())
                    .map(u32::from_le_bytes)
            })
            .ok_or_else(|| format!("virtio-balloon device at 0x{base:x} is unavailable"))?;
        let actual_pages = vm_state
            .devices
            .balloon
            .get(base)
            .map(|handler| handler.metrics().actual_pages.min(u64::from(u32::MAX)) as u32)
            .ok_or_else(|| format!("balloon handler at 0x{base:x} is unavailable"))?;
        if actual_pages < target_pages {
            return Ok(None);
        }
    }

    let memory = &vm_state.memory as *const GuestMemory;
    let mut total = IdleBackingCompactionReport::default();
    for base in balloon_bases {
        let Some(handler) = vm_state.devices.balloon.get_mut(&base) else {
            continue;
        };
        let report = handler.hard_decommit_reusable_balloon_backing(
            // `memory` belongs to the same locked VmState and the mutable
            // handler borrow cannot move or invalidate it.
            unsafe { &*memory },
            guest_base,
        );
        total.hard_decommitted_bytes = total
            .hard_decommitted_bytes
            .saturating_add(report.hard_decommitted_bytes);
        total.failed_bytes = total.failed_bytes.saturating_add(report.failed_bytes);
    }
    Ok(Some(total))
}

fn apply_core_memory_target_transition(
    controller: &mut CoreMemoryController,
    transition: CoreMemoryTargetTransition,
    now: Instant,
    shared: &SharedBootState,
    gic: &Gic,
    vcpu_ids: &Arc<Mutex<Vec<u64>>>,
    devices: &[VirtioMmioDevicePlan],
    configured_memory_mib: u64,
) -> bool {
    let target_mib = controller.target_mib(transition);
    let previous_hard_fallback = shared.allow_balloon_hard_decommit_fallback.swap(
        transition == CoreMemoryTargetTransition::ReduceToIdle,
        Ordering::SeqCst,
    );
    match set_balloon_target_bytes(
        shared,
        gic,
        devices,
        configured_memory_mib,
        target_mib.saturating_mul(1024 * 1024),
    ) {
        Ok(()) => {
            controller.record_target_applied(transition, now, shared);
            let ids = vcpu_ids.lock().expect("vCPU id mutex poisoned").clone();
            let _ = exit_vcpus(&ids);
            true
        }
        Err(error) => {
            let fallback_after_error = if transition == CoreMemoryTargetTransition::ReduceToIdle {
                previous_hard_fallback
            } else {
                false
            };
            shared
                .allow_balloon_hard_decommit_fallback
                .store(fallback_after_error, Ordering::SeqCst);
            controller.record_target_error(transition, now, error, shared);
            false
        }
    }
}

fn docker_phase_metrics(shared: &SharedBootState) -> crate::vmm::vstate::DockerPhaseMetrics {
    let vm_state = shared.vm_state.lock().expect("VM state mutex poisoned");
    vm_state.devices.docker_phase_events()
}

fn docker_transport_bytes(metrics: &crate::vmm::vstate::DockerPhaseMetrics) -> u64 {
    metrics.request_bytes.saturating_add(metrics.response_bytes)
}

fn balloon_free_page_hint_cmd_id(transport: &crate::devices::virtio::VirtioMmioDevice) -> u32 {
    let config = transport.configuration_bytes();
    if config.len() < 12 {
        return 0;
    }
    u32::from_le_bytes(
        config[8..12]
            .try_into()
            .expect("free page hint command id field is 4 bytes"),
    )
}

fn core_balloon_target_converged(shared: &SharedBootState) -> bool {
    let mut vm_state = shared.vm_state.lock().expect("VM state mutex poisoned");
    refresh_balloon_transport_metrics(&mut vm_state);
    let balloon_bases = vm_state.devices.balloon.keys().copied().collect::<Vec<_>>();
    !balloon_bases.is_empty()
        && balloon_bases.into_iter().all(|base| {
            let actual_pages = vm_state
                .devices
                .balloon
                .get(&base)
                .map(|handler| handler.metrics().actual_pages);
            let target_pages = vm_state
                .mmio_bus
                .virtio_mut_at(base)
                .and_then(|transport| {
                    transport
                        .configuration_bytes()
                        .get(..4)
                        .and_then(|bytes| bytes.try_into().ok())
                        .map(u32::from_le_bytes)
                })
                .map(u64::from);
            actual_pages.is_some() && actual_pages == target_pages
        })
}

fn balloon_target_pages(configured_memory_mib: u64, target_bytes: u64) -> u32 {
    let configured_bytes = configured_memory_mib.saturating_mul(1024 * 1024);
    let target_bytes = target_bytes.clamp(4096, configured_bytes.max(4096));
    ((configured_bytes.saturating_sub(target_bytes)) / 4096).min(u64::from(u32::MAX)) as u32
}

fn memory_control_snapshot(
    shared: &SharedBootState,
    configured_memory_mib: u64,
) -> Result<MemoryControlResponse, String> {
    let mut vm_state = shared.vm_state.lock().expect("VM state mutex poisoned");
    refresh_balloon_transport_metrics(&mut vm_state);
    let balloon = vm_state.devices.balloon_metrics();
    let memory_ledger = vm_state.devices.memory_ledger_summary(
        vm_state.memory.len() as u64,
        vm_state.memory.host_page_size() as u64,
    );
    let docker_phase_events = vm_state.devices.docker_phase_events();
    let event_reclaim = shared
        .event_reclaim
        .lock()
        .expect("event reclaim mutex poisoned")
        .clone();
    let core_memory = shared
        .core_memory
        .lock()
        .expect("core memory controller mutex poisoned")
        .clone();
    let balloon_bases = vm_state.devices.balloon.keys().copied().collect::<Vec<_>>();
    let target_pages = balloon_bases
        .into_iter()
        .find_map(|base| {
            let transport = vm_state.mmio_bus.virtio_mut_at(base)?;
            let config = transport.configuration_bytes();
            if config.len() >= 4 {
                Some(u32::from_le_bytes(config[0..4].try_into().unwrap()))
            } else {
                None
            }
        })
        .unwrap_or(0);
    let ballooned_mib = u64::from(target_pages) * 4096 / 1024 / 1024;
    let target_mib = configured_memory_mib.saturating_sub(ballooned_mib);
    Ok(MemoryControlResponse {
        ok: true,
        message: "ok".to_string(),
        configured_mib: configured_memory_mib,
        target_mib,
        target_pages,
        docker_phase_events: DockerPhaseControlMetrics {
            total: docker_phase_events.total,
            request: docker_phase_events.request,
            response: docker_phase_events.response,
            workload_started: docker_phase_events.workload_started,
            completed_streams: docker_phase_events.completed_streams,
            completed_workload_streams: docker_phase_events.completed_workload_streams,
            active_workload_streams: docker_phase_events.active_workload_streams,
            request_bytes: docker_phase_events.request_bytes,
            response_bytes: docker_phase_events.response_bytes,
        },
        event_reclaim,
        core_memory,
        balloon,
        memory_ledger,
        host_memory: host_memory_footprint(),
    })
}

fn refresh_balloon_transport_metrics(vm_state: &mut VmState) {
    let bases = vm_state.devices.balloon.keys().copied().collect::<Vec<_>>();
    for base in bases {
        let Some(transport) = vm_state.mmio_bus.virtio_mut_at(base) else {
            continue;
        };
        if let Some(handler) = vm_state.devices.balloon.get_mut(&base) {
            handler.refresh_transport_metrics(transport);
        }
    }
}

fn memory_control_error(message: &str, configured_memory_mib: u64) -> MemoryControlResponse {
    MemoryControlResponse {
        ok: false,
        message: message.to_string(),
        configured_mib: configured_memory_mib,
        target_mib: configured_memory_mib,
        target_pages: 0,
        docker_phase_events: DockerPhaseControlMetrics::default(),
        event_reclaim: EventReclaimMetrics::default(),
        core_memory: CoreMemoryControllerMetrics::default(),
        balloon: BalloonMetrics::default(),
        memory_ledger: MemoryLedgerSummary::default(),
        host_memory: host_memory_footprint(),
    }
}

#[cfg(target_os = "macos")]
fn host_memory_footprint() -> HostMemoryFootprint {
    let mut info = std::mem::MaybeUninit::<libc::rusage_info_v2>::zeroed();
    let rc = unsafe {
        libc::proc_pid_rusage(
            libc::getpid(),
            libc::RUSAGE_INFO_V2,
            info.as_mut_ptr().cast::<libc::rusage_info_t>(),
        )
    };
    if rc == 0 {
        let info = unsafe { info.assume_init() };
        HostMemoryFootprint {
            resident_bytes: Some(info.ri_resident_size),
            physical_footprint_bytes: Some(info.ri_phys_footprint),
        }
    } else {
        HostMemoryFootprint::default()
    }
}

#[cfg(not(target_os = "macos"))]
fn host_memory_footprint() -> HostMemoryFootprint {
    HostMemoryFootprint::default()
}

fn memory_socket_path(docker_socket_path: &std::path::Path) -> std::path::PathBuf {
    let preferred = docker_socket_path
        .parent()
        .map(|parent| parent.join("memory.sock"))
        .unwrap_or_else(|| std::path::PathBuf::from("memory.sock"));
    unix_socket_path_or_fallback(preferred, docker_socket_path, "memory.sock")
}

fn schedule_guest_memory_reclaim(
    socket_path: std::path::PathBuf,
    reason: &'static str,
    shared: Arc<SharedBootState>,
) {
    if shared.event_reclaim_inflight.swap(true, Ordering::SeqCst) {
        shared.event_reclaim_pending.store(true, Ordering::SeqCst);
        return;
    }
    let thread_shared = shared.clone();
    if let Err(error) = std::thread::Builder::new()
        .name(format!("jetstream-event-reclaim-{reason}"))
        .spawn(move || {
            let mut current_reason = reason;
            loop {
                if let Err(error) =
                    request_guest_memory_reclaim(&socket_path, current_reason, &thread_shared)
                {
                    record_event_reclaim_error(&thread_shared, error.to_string());
                }
                if !thread_shared
                    .event_reclaim_pending
                    .swap(false, Ordering::SeqCst)
                {
                    break;
                }
                std::thread::sleep(Duration::from_secs(1));
                current_reason = "docker.workloadFinished";
            }
            thread_shared
                .event_reclaim_inflight
                .store(false, Ordering::SeqCst);
        })
    {
        shared.event_reclaim_inflight.store(false, Ordering::SeqCst);
        record_event_reclaim_error(&shared, error.to_string());
    }
}

fn request_guest_memory_reclaim(
    socket_path: &std::path::Path,
    reason: &str,
    shared: &SharedBootState,
) -> std::io::Result<()> {
    {
        let mut metrics = shared
            .event_reclaim
            .lock()
            .expect("event reclaim mutex poisoned");
        metrics.requests = metrics.requests.saturating_add(1);
        metrics.last_reason = Some(reason.to_string());
        metrics.last_error = None;
    }
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let reason = percent_encode_reason(reason);
    let request = format!(
        "POST /conjet-memory-reclaim?reason={} HTTP/1.1\r\nHost: conjet-memd\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        reason
    );
    stream.write_all(request.as_bytes())?;
    let mut response = Vec::new();
    let mut buffer = [0u8; 1024];
    while response.len() < MAX_GUEST_MEMORY_RESPONSE_BYTES {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                response.extend_from_slice(&buffer[..count]);
                if http_response_body_complete(&response) {
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break;
            }
            Err(error) => return Err(error),
        }
    }
    {
        let mut metrics = shared
            .event_reclaim
            .lock()
            .expect("event reclaim mutex poisoned");
        metrics.response_bytes = metrics.response_bytes.saturating_add(response.len() as u64);
    }
    if response.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "guest memory reclaim returned an empty response",
        ));
    }
    match reclaim_submission_from_http_response(&response) {
        Some(submission) if submission.accepted => {
            let mut metrics = shared
                .event_reclaim
                .lock()
                .expect("event reclaim mutex poisoned");
            metrics.successes = metrics.successes.saturating_add(1);
            metrics.no_range_responses = metrics.no_range_responses.saturating_add(1);
        }
        Some(_) | None => {
            let mut metrics = shared
                .event_reclaim
                .lock()
                .expect("event reclaim mutex poisoned");
            metrics.no_range_responses = metrics.no_range_responses.saturating_add(1);
        }
    }
    Ok(())
}

fn request_guest_memory_snapshot(
    socket_path: &std::path::Path,
) -> Result<GuestMemorySnapshot, String> {
    let mut stream = UnixStream::connect(socket_path).map_err(|error| error.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| error.to_string())?;
    stream
        .write_all(
            b"GET /conjet-memory-metrics HTTP/1.1\r\nHost: conjet-memd\r\nConnection: close\r\n\r\n",
        )
        .map_err(|error| error.to_string())?;
    let mut response = Vec::new();
    let mut buffer = [0u8; 1024];
    while response.len() < MAX_GUEST_MEMORY_RESPONSE_BYTES {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                response.extend_from_slice(&buffer[..count]);
                if http_response_body_complete(&response) {
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break;
            }
            Err(error) => return Err(error.to_string()),
        }
    }
    if response.is_empty() {
        return Err("guest memory metrics returned an empty response".to_string());
    }
    if !http_response_body_complete(&response) {
        return Err(format!(
            "guest memory metrics response was incomplete after {} bytes",
            response.len()
        ));
    }
    if http_response_status(&response) != Some(200) {
        return Err("guest memory metrics returned a non-200 response".to_string());
    }
    let body_start = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| index + 4)
        .ok_or_else(|| "guest memory metrics response lacks HTTP headers".to_string())?;
    serde_json::from_slice::<GuestMemorySnapshot>(&response[body_start..])
        .map_err(|error| format!("invalid guest memory metrics: {error}"))
}

fn record_event_reclaim_error(shared: &SharedBootState, error: String) {
    let mut metrics = shared
        .event_reclaim
        .lock()
        .expect("event reclaim mutex poisoned");
    metrics.errors = metrics.errors.saturating_add(1);
    metrics.last_error = Some(error);
}

#[derive(Debug, Deserialize)]
struct GuestReclaimSubmission {
    accepted: bool,
    #[allow(dead_code)]
    epoch: u64,
    #[allow(dead_code)]
    state: String,
}

fn reclaim_submission_from_http_response(response: &[u8]) -> Option<GuestReclaimSubmission> {
    let status = http_response_status(response)?;
    if status != 200 && status != 202 {
        return None;
    }
    let body_start = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| index + 4)?;
    let body = std::str::from_utf8(&response[body_start..]).ok()?;
    serde_json::from_str::<GuestReclaimSubmission>(body).ok()
}

fn http_response_status(response: &[u8]) -> Option<u16> {
    let line_end = response.windows(2).position(|window| window == b"\r\n")?;
    let status_line = std::str::from_utf8(&response[..line_end]).ok()?;
    status_line.split_whitespace().nth(1)?.parse().ok()
}

fn http_response_body_complete(response: &[u8]) -> bool {
    let Some(body_start) = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| index + 4)
    else {
        return false;
    };
    let headers = &response[..body_start - 4];
    let Ok(headers) = std::str::from_utf8(headers) else {
        return false;
    };
    for line in headers.lines().skip(1) {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if !name.trim().eq_ignore_ascii_case("content-length") {
            continue;
        }
        let Ok(length) = value.trim().parse::<usize>() else {
            return false;
        };
        return response.len().saturating_sub(body_start) >= length;
    }
    false
}

fn percent_encode_reason(reason: &str) -> String {
    let mut out = String::new();
    for byte in reason.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn unix_socket_path_or_fallback(
    preferred: std::path::PathBuf,
    seed: &std::path::Path,
    basename: &str,
) -> std::path::PathBuf {
    const UNIX_SOCKET_PATH_CAPACITY: usize = 104;
    let preferred_len = preferred.to_string_lossy().as_bytes().len() + 1;
    if preferred_len <= UNIX_SOCKET_PATH_CAPACITY {
        return preferred;
    }
    let digest = stable_digest_hex(&seed.to_string_lossy());
    std::path::PathBuf::from("/tmp")
        .join(format!("conjet-{digest}"))
        .join(basename)
}

fn stable_digest_hex(value: &str) -> String {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

fn make_transport(
    config: &JetstreamConfig,
    plan: &VirtioMmioDevicePlan,
    block_index: usize,
    balloon_target_mib: Option<u64>,
) -> VirtioMmioDevice {
    match plan.kind {
        VirtioDeviceKind::Block => {
            let path = block_backing_paths(config)
                .get(block_index)
                .cloned()
                .unwrap_or_else(|| config.boot_source.root_disk_path.clone());
            let config = std::fs::metadata(path)
                .map(|metadata| (metadata.len() / 512).to_le_bytes().to_vec())
                .unwrap_or_default();
            VirtioMmioDevice::new(plan.clone(), config)
        }
        VirtioDeviceKind::Vsock => {
            VirtioMmioDevice::new(plan.clone(), vsock::configuration(DEFAULT_GUEST_CID))
        }
        VirtioDeviceKind::Net => {
            let mut config = vec![0x02, 0x43, 0x4a, 0x45, 0x54, 0x01];
            config.extend_from_slice(&1u16.to_le_bytes());
            VirtioMmioDevice::new(plan.clone(), config)
        }
        VirtioDeviceKind::Balloon => {
            let target_pages = balloon_target_mib
                .map(|target_mib| {
                    balloon_target_pages(config.memory_mib, target_mib.saturating_mul(1024 * 1024))
                })
                .unwrap_or(0);
            VirtioMmioDevice::new(plan.clone(), balloon::configuration(target_pages, 0, 0))
        }
        VirtioDeviceKind::Rng => VirtioMmioDevice::new(plan.clone(), Vec::new()),
    }
}

fn block_backing_paths(config: &JetstreamConfig) -> Vec<std::path::PathBuf> {
    let mut paths = vec![config.boot_source.root_disk_path.clone()];
    if let Some(path) = config.boot_source.data_disk_path.clone() {
        paths.push(path);
    }
    if let Some(path) = config.boot_source.swap_disk_path.clone() {
        paths.push(path);
    }
    paths
}

fn execute_virtio_notification(
    vm_state: &mut VmState,
    guest_base: u64,
    physical_address: u64,
) -> Result<(), String> {
    let Some(transport) = vm_state.mmio_bus.virtio_mut_at(physical_address) else {
        return Ok(());
    };
    let notifications = transport.drain_notifications();
    if notifications.is_empty() {
        return Ok(());
    }
    let base = transport.plan.mmio_base;
    for queue_index in notifications {
        let Some(queue) = transport.queue_state(queue_index) else {
            continue;
        };
        match transport.plan.kind {
            VirtioDeviceKind::Block => {
                if let Some(handler) = vm_state.devices.block.get_mut(&base) {
                    handler
                        .handle_available(queue, transport, &vm_state.memory, guest_base)
                        .map_err(|error| error.to_string())?;
                }
            }
            VirtioDeviceKind::Vsock => {
                if let Some(handler) = vm_state.devices.vsock.get_mut(&base) {
                    handler
                        .handle_available(
                            queue,
                            queue_index,
                            transport,
                            &vm_state.memory,
                            guest_base,
                        )
                        .map_err(|error| error.to_string())?;
                }
            }
            VirtioDeviceKind::Net => {
                if let Some(handler) = vm_state.devices.net.get_mut(&base) {
                    handler
                        .handle_available(
                            queue,
                            queue_index,
                            transport,
                            &vm_state.memory,
                            guest_base,
                        )
                        .map_err(|error| error.to_string())?;
                }
            }
            VirtioDeviceKind::Balloon => {
                if let Some(handler) = vm_state.devices.balloon.get_mut(&base) {
                    handler
                        .handle_available(
                            queue,
                            queue_index,
                            transport,
                            &vm_state.memory,
                            guest_base,
                        )
                        .map_err(|error| error.to_string())?;
                }
            }
            VirtioDeviceKind::Rng => {}
        }
    }
    Ok(())
}

fn poll_host_vsock_packets(
    shared: &SharedBootState,
    guest_base: u64,
    gic: &Gic,
    devices: &[VirtioMmioDevicePlan],
) -> Result<bool, String> {
    let mut vm_state = shared.vm_state.lock().expect("VM state mutex poisoned");
    let memory = &vm_state.memory as *const GuestMemory;
    let mut interrupt_asserted = false;

    for device in devices
        .iter()
        .filter(|device| device.kind == VirtioDeviceKind::Vsock)
    {
        let base = device.mmio_base;
        let Some(mut handler) = vm_state.devices.vsock.remove(&base) else {
            continue;
        };
        let result = {
            let Some(transport) = vm_state.mmio_bus.virtio_mut_at(base) else {
                vm_state.devices.vsock.insert(base, handler);
                continue;
            };
            let Some(queue) = transport.queue_state(VsockQueue::Receive as u32) else {
                vm_state.devices.vsock.insert(base, handler);
                continue;
            };
            if !queue.ready {
                vm_state.devices.vsock.insert(base, handler);
                continue;
            }
            let used = handler
                .handle_available(
                    queue,
                    VsockQueue::Receive as u32,
                    transport,
                    unsafe { &*memory },
                    guest_base,
                )
                .map_err(|error| error.to_string())?;
            if !used.is_empty() || transport.interrupt_status != 0 {
                gic.set_spi(transport.plan.irq, true)
                    .map_err(|error| error.to_string())?;
                true
            } else {
                false
            }
        };
        vm_state.devices.vsock.insert(base, handler);
        interrupt_asserted |= result;
    }

    Ok(interrupt_asserted)
}

fn poll_host_net_packets(
    shared: &SharedBootState,
    guest_base: u64,
    gic: &Gic,
    devices: &[VirtioMmioDevicePlan],
) -> Result<bool, String> {
    let mut vm_state = shared.vm_state.lock().expect("VM state mutex poisoned");
    let memory = &vm_state.memory as *const GuestMemory;
    let mut interrupt_asserted = false;

    for device in devices
        .iter()
        .filter(|device| device.kind == VirtioDeviceKind::Net)
    {
        let base = device.mmio_base;
        let Some(mut handler) = vm_state.devices.net.remove(&base) else {
            continue;
        };
        let result = {
            let Some(transport) = vm_state.mmio_bus.virtio_mut_at(base) else {
                vm_state.devices.net.insert(base, handler);
                continue;
            };
            let Some(queue) = transport.queue_state(NetQueue::Receive as u32) else {
                vm_state.devices.net.insert(base, handler);
                continue;
            };
            if !queue.ready {
                vm_state.devices.net.insert(base, handler);
                continue;
            }
            let used = handler
                .handle_available(
                    queue,
                    NetQueue::Receive as u32,
                    transport,
                    unsafe { &*memory },
                    guest_base,
                )
                .map_err(|error| error.to_string())?;
            if !used.is_empty() || transport.interrupt_status != 0 {
                gic.set_spi(transport.plan.irq, true)
                    .map_err(|error| error.to_string())?;
                true
            } else {
                false
            }
        };
        vm_state.devices.net.insert(base, handler);
        interrupt_asserted |= result;
    }

    Ok(interrupt_asserted)
}

fn maybe_assert_virtio_irq(
    vm_state: &mut VmState,
    gic: &Gic,
    physical_address: u64,
) -> Result<bool, String> {
    let Some(transport) = vm_state.mmio_bus.virtio_mut_at(physical_address) else {
        return Ok(false);
    };
    if transport.interrupt_status == 0 {
        return Ok(false);
    }
    gic.set_spi(transport.plan.irq, true)
        .map_err(|error| error.to_string())?;
    Ok(true)
}

fn maybe_deassert_virtio_irq(
    vm_state: &mut VmState,
    gic: &Gic,
    physical_address: u64,
    value: u64,
) -> Result<(), String> {
    if value == 0 {
        return Ok(());
    }
    let Some(transport) = vm_state.mmio_bus.virtio_mut_at(physical_address) else {
        return Ok(());
    };
    let offset = physical_address - transport.base();
    if offset == 0x064 && transport.interrupt_status == 0 {
        gic.set_spi(transport.plan.irq, false)
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn advance_pc(vcpu: &Vcpu) -> Result<(), HvfError> {
    let pc = vcpu.get_reg(HV_REG_PC)?;
    vcpu.set_reg(HV_REG_PC, pc + 4)
}

fn stage(stages: &mut Vec<HvfBootStage>, name: &'static str, ok: bool, detail: String) {
    stages.push(HvfBootStage { name, ok, detail });
}

fn describe_hvf_error(error: &HvfError) -> String {
    format!("{error}")
}

fn describe_mmio_error(error: MmioError) -> String {
    error.to_string()
}

pub fn default_virtio_plan(config: &JetstreamConfig) -> Vec<VirtioMmioDevicePlan> {
    default_device_plan(
        config.boot_source.data_disk_path.is_some(),
        config.boot_source.swap_disk_path.is_some(),
        true,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_core_memory_policy(target_mib: u64) -> CoreMemoryPolicy {
        CoreMemoryPolicy {
            enabled: true,
            target_mib,
            quiet_dwell: Duration::from_secs(8),
            retry_dwell: Duration::from_secs(20),
            service_min_target_mib: 2048,
            service_learning_dwell: Duration::from_secs(30),
            service_probe_dwell: Duration::from_secs(5),
            service_stabilization_dwell: Duration::from_secs(10),
            service_shrink_step_mib: 256,
            service_headroom_mib: 512,
            service_cooldown_dwell: Duration::from_secs(120),
        }
    }

    fn complete_global_memory_snapshot() -> GuestMemorySnapshot {
        GuestMemorySnapshot {
            mem_available_known: true,
            swap_telemetry_complete: true,
            disk_swap_telemetry_complete: true,
            global_psi_telemetry_complete: true,
            ..GuestMemorySnapshot::default()
        }
    }

    #[test]
    fn balloon_target_pages_encodes_guest_target_as_ballooned_pages() {
        assert_eq!(balloon_target_pages(8192, 8192 * 1024 * 1024), 0);
        assert_eq!(balloon_target_pages(8192, 4096 * 1024 * 1024), 1_048_576);
        assert_eq!(balloon_target_pages(8192, 1024 * 1024 * 1024), 1_835_008);
    }

    #[test]
    fn balloon_target_pages_clamps_to_configured_guest_memory() {
        assert_eq!(balloon_target_pages(8192, 16 * 1024 * 1024 * 1024), 0);
        assert_eq!(balloon_target_pages(8192, 0), 2_097_151);
    }

    #[test]
    fn memory_control_request_decodes_line_protocol_commands() {
        assert!(matches!(
            serde_json::from_str::<MemoryControlRequest>(r#"{"command":"metrics"}"#).unwrap(),
            MemoryControlRequest::Metrics
        ));
        assert!(matches!(
            serde_json::from_str::<MemoryControlRequest>(
                r#"{"command":"set_target_bytes","target_bytes":4294967296}"#
            )
            .unwrap(),
            MemoryControlRequest::SetTargetBytes {
                target_bytes: 4_294_967_296
            }
        ));
        assert!(matches!(
            serde_json::from_str::<MemoryControlRequest>(
                r#"{"command":"set_target_mib","target_mib":4096}"#
            )
            .unwrap(),
            MemoryControlRequest::SetTargetMib { target_mib: 4096 }
        ));
    }

    #[test]
    fn memory_control_rejects_legacy_target_mutation() {
        let metrics = MemoryControlRequest::Metrics;
        assert!(memory_control_target_mutation_error(&metrics).is_none());

        for request in [
            MemoryControlRequest::SetTargetBytes {
                target_bytes: 4_294_967_296,
            },
            MemoryControlRequest::SetTargetMib { target_mib: 4096 },
        ] {
            let error = memory_control_target_mutation_error(&request)
                .expect("legacy target mutations must be rejected");
            assert!(error.contains("target mutation is disabled"));
            assert!(error.contains("Jetstream owns automatic memory policy"));
        }
    }

    #[test]
    fn memory_control_rejects_guest_address_reclaim_commands() {
        assert!(serde_json::from_str::<MemoryControlRequest>(
            r#"{"command":"reclaim_ranges","ranges":[{"start":1073741824,"size":16384}]}"#
        )
        .is_err());
    }

    #[test]
    fn memory_control_response_serializes_host_memory_footprint() {
        let response = memory_control_error("test", 8192);
        let json = serde_json::to_value(response).unwrap();
        assert!(json.get("docker_phase_events").is_some());
        assert_eq!(json["docker_phase_events"]["total"], 0);
        assert!(json.get("core_memory").is_some());
        assert_eq!(json["core_memory"]["enabled"], false);
        assert!(json.get("host_memory").is_some());
        assert!(json["host_memory"].get("resident_bytes").is_some());
        assert!(json["host_memory"]
            .get("physical_footprint_bytes")
            .is_some());
    }

    #[test]
    fn parses_guest_reclaim_submission_from_http_response() {
        let response = b"HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\n\r\n{\"accepted\":true,\"epoch\":42,\"state\":\"queued\",\"source\":\"conjet-memd\"}\n";

        let submission = reclaim_submission_from_http_response(response).unwrap();
        assert!(submission.accepted);
        assert_eq!(submission.epoch, 42);
        assert_eq!(submission.state, "queued");
    }

    #[test]
    fn detects_complete_guest_reclaim_http_body_from_content_length() {
        let complete = b"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"ranges\":[]}";
        let partial = b"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"ranges\"";

        assert!(http_response_body_complete(complete));
        assert!(!http_response_body_complete(partial));
    }

    #[test]
    fn host_reclaim_chunks_bound_large_free_page_reports() {
        let chunks = host_reclaim_chunks(PageRange {
            start: 0x4000_0000,
            size: HOST_RECLAIM_CHUNK_BYTES * 2 + 4096,
        });

        assert_eq!(chunks.len(), 3);
        assert_eq!(chunks[0].start, 0x4000_0000);
        assert_eq!(chunks[0].size, HOST_RECLAIM_CHUNK_BYTES);
        assert_eq!(chunks[1].start, 0x4000_0000 + HOST_RECLAIM_CHUNK_BYTES);
        assert_eq!(chunks[1].size, HOST_RECLAIM_CHUNK_BYTES);
        assert_eq!(chunks[2].start, 0x4000_0000 + HOST_RECLAIM_CHUNK_BYTES * 2);
        assert_eq!(chunks[2].size, 4096);
    }

    #[test]
    fn retained_console_output_is_bounded_on_utf8_boundaries() {
        let mut console = "start:".to_string();
        append_console_output(&mut console, &"界".repeat(MAX_RETAINED_CONSOLE_BYTES));

        assert!(console.len() <= MAX_RETAINED_CONSOLE_BYTES);
        assert!(std::str::from_utf8(console.as_bytes()).is_ok());
        assert!(console.ends_with('界'));
    }

    #[test]
    fn production_reclaim_separates_report_and_balloon_paths() {
        assert!(should_prefer_soft_reclaim(
            ReclaimAuthority::ReportInFlight,
            false,
            false,
            false
        ));
        assert!(!should_prefer_soft_reclaim(
            ReclaimAuthority::BalloonOwned,
            false,
            false,
            false
        ));
        assert!(should_prefer_soft_reclaim(
            ReclaimAuthority::BalloonOwned,
            false,
            true,
            false
        ));
        assert!(!should_prefer_soft_reclaim(
            ReclaimAuthority::ReportInFlight,
            true,
            false,
            false
        ));
        assert!(!should_prefer_soft_reclaim(
            ReclaimAuthority::ReportInFlight,
            false,
            false,
            true
        ));
    }

    #[test]
    fn memory_socket_path_uses_docker_sibling_when_path_fits() {
        assert_eq!(
            memory_socket_path(std::path::Path::new("/tmp/conjet-short/run/docker.sock")),
            std::path::PathBuf::from("/tmp/conjet-short/run/memory.sock")
        );
    }

    #[test]
    fn memory_socket_path_falls_back_when_sibling_exceeds_unix_socket_limit() {
        let long_profile = "nested-profile-segment-".repeat(8);
        let docker_socket = std::path::PathBuf::from(format!(
            "/Volumes/ExternalSSD/dev_workspace/tmp/{long_profile}/run/docker.sock"
        ));
        let path = memory_socket_path(&docker_socket);
        let rendered = path.to_string_lossy();

        assert!(rendered.starts_with("/tmp/conjet-"));
        assert!(rendered.ends_with("/memory.sock"));
        assert!(rendered.as_bytes().len() + 1 <= 104);
    }

    #[test]
    fn percent_encode_reason_keeps_safe_reclaim_reason_bytes_readable() {
        assert_eq!(
            percent_encode_reason("docker.workloadFinished final/1"),
            "docker.workloadFinished%20final%2F1"
        );
    }

    #[test]
    fn guest_memory_snapshot_allows_only_quiet_low_working_set_state() {
        let quiet = GuestMemorySnapshot {
            active_workloads: 0,
            build_workload_detected: false,
            container_memory_current: CORE_IDLE_WORKLOAD_NOISE_BYTES - 1,
            service_cgroup_memory_current: CORE_IDLE_WORKLOAD_NOISE_BYTES - 1,
            service_cgroup_working_set: CORE_IDLE_WORKLOAD_NOISE_BYTES - 1,
            service_cgroup_populated: false,
            service_cgroup_population_known: true,
            disk_swap_used: 0,
            psi_full_avg10: 0.05,
            ..complete_global_memory_snapshot()
        };
        assert!(quiet.allows_idle_target());

        let runtime_infrastructure_only = GuestMemorySnapshot {
            active_workloads: 1,
            ..quiet
        };
        assert!(runtime_infrastructure_only.allows_idle_target());

        let lightweight_live_service = GuestMemorySnapshot {
            active_workloads: 1,
            service_cgroup_populated: true,
            ..quiet
        };
        assert!(!lightweight_live_service.allows_idle_target());

        let build = GuestMemorySnapshot {
            build_workload_detected: true,
            ..quiet
        };
        assert!(!build.allows_idle_target());

        let container = GuestMemorySnapshot {
            container_memory_current: CORE_IDLE_WORKLOAD_NOISE_BYTES,
            ..quiet
        };
        assert!(!container.allows_idle_target());

        let service = GuestMemorySnapshot {
            service_cgroup_memory_current: CORE_IDLE_WORKLOAD_NOISE_BYTES,
            service_cgroup_working_set: CORE_IDLE_WORKLOAD_NOISE_BYTES,
            service_cgroup_anon: CORE_IDLE_WORKLOAD_NOISE_BYTES,
            ..quiet
        };
        assert!(!service.allows_idle_target());

        let stopped_service_cache = GuestMemorySnapshot {
            service_cgroup_memory_current: CORE_IDLE_WORKLOAD_NOISE_BYTES * 2,
            service_cgroup_working_set: CORE_IDLE_WORKLOAD_NOISE_BYTES * 2,
            service_cgroup_populated: false,
            service_cgroup_population_known: true,
            ..quiet
        };
        assert!(stopped_service_cache.allows_idle_target());

        let stopped_service_pinned = GuestMemorySnapshot {
            service_cgroup_anon: CORE_IDLE_WORKLOAD_NOISE_BYTES,
            ..stopped_service_cache
        };
        assert!(!stopped_service_pinned.allows_idle_target());

        let unknown_service_population = GuestMemorySnapshot {
            service_cgroup_memory_current: CORE_IDLE_WORKLOAD_NOISE_BYTES * 2,
            service_cgroup_working_set: CORE_IDLE_WORKLOAD_NOISE_BYTES - 1,
            service_cgroup_populated: false,
            service_cgroup_population_known: false,
            ..quiet
        };
        assert!(!unknown_service_population.allows_idle_target());

        let swap = GuestMemorySnapshot {
            disk_swap_used: 4096,
            ..quiet
        };
        assert!(!swap.allows_idle_target());

        let derived_swap = GuestMemorySnapshot {
            disk_swap_total: 8192,
            disk_swap_free: 4096,
            swap_total: 16384,
            swap_free: 12288,
            ..quiet
        };
        assert_eq!(derived_swap.observed_disk_swap_used(), 4096);
        assert_eq!(derived_swap.observed_total_swap_used(), 4096);
        assert!(!derived_swap.allows_idle_target());

        let bounded_control_plane_zram = GuestMemorySnapshot {
            swap_total: CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES * 2,
            swap_free: CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES,
            ..quiet
        };
        assert!(bounded_control_plane_zram.allows_idle_target());

        let excessive_control_plane_zram = GuestMemorySnapshot {
            swap_total: CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES * 2,
            swap_free: CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES - 1,
            ..quiet
        };
        assert!(!excessive_control_plane_zram.allows_idle_target());

        let bounded_container_zram = GuestMemorySnapshot {
            container_swap_current: CORE_CONTAINER_ZRAM_SWAP_BUDGET_BYTES,
            ..quiet
        };
        assert!(bounded_container_zram.allows_idle_target());

        let container_swap = GuestMemorySnapshot {
            container_swap_current: CORE_CONTAINER_ZRAM_SWAP_BUDGET_BYTES + 1,
            ..quiet
        };
        assert!(!container_swap.allows_idle_target());

        let reclaim_stalled = GuestMemorySnapshot {
            psi_some_avg10: CORE_SERVICE_PSI_SOME_LIMIT + 0.01,
            ..quiet
        };
        assert!(!reclaim_stalled.allows_idle_target());

        let stalled = GuestMemorySnapshot {
            psi_full_avg10: 0.06,
            ..quiet
        };
        assert!(!stalled.allows_idle_target());
    }

    #[test]
    fn core_memory_controller_uses_configured_capacity_and_idle_floor() {
        let controller = CoreMemoryController::new(test_core_memory_policy(512), 8192, 8192);

        let metrics = controller.metrics();
        assert!(metrics.enabled);
        assert_eq!(metrics.idle_target_mib, 512);
        assert_eq!(metrics.current_target_mib, 8192);
        assert_eq!(
            controller.target_mib(CoreMemoryTargetTransition::RestoreConfigured),
            8192
        );
        assert_eq!(
            controller.target_mib(CoreMemoryTargetTransition::ReduceToIdle),
            512
        );
        assert!(!controller.idle_target_reached());

        let mut settled = controller;
        settled.requested_target_mib = 512;
        assert!(settled.idle_target_reached());
    }

    #[test]
    fn quiet_transport_arms_guest_reclaim_settle_before_idle_probe() {
        let now = Instant::now();
        let mut controller = CoreMemoryController::new(test_core_memory_policy(512), 8192, 8192);
        controller.runtime_ready = true;
        controller.docker_transport_active = true;
        controller.last_docker_transport_activity = Some(now);

        assert!(controller.finish_docker_transport_quiet(now));
        assert!(!controller.docker_transport_active);
        assert!(controller.last_docker_transport_activity.is_none());
        assert_eq!(
            controller
                .idle_deadline
                .expect("quiet transition arms an idle deadline")
                .duration_since(now),
            DEFAULT_CORE_IDLE_RECLAIM_SETTLE_DWELL
        );
    }

    #[test]
    fn classified_workload_stream_survives_byte_silence() {
        let now = Instant::now();
        let mut controller = CoreMemoryController::new(test_core_memory_policy(512), 8192, 8192);
        controller.runtime_ready = true;
        controller.classified_workload_streams_active = true;
        controller.docker_transport_active = true;
        controller.docker_transport_tracks_bytes = false;
        controller.last_docker_transport_activity = Some(now - Duration::from_secs(60));

        assert!(!controller.finish_docker_transport_quiet(now));
        assert!(controller.classified_workload_streams_active);
        assert!(controller.docker_transport_active);
        assert!(!controller.docker_transport_tracks_bytes);

        assert!(controller.observe_docker_transport_bytes(now));
        assert!(controller.classified_workload_streams_active);
        assert!(controller.docker_transport_active);
        assert!(!controller.docker_transport_tracks_bytes);
    }

    #[test]
    fn repeated_benign_transport_bytes_do_not_arm_quiet_tracking() {
        let now = Instant::now();
        let mut controller = CoreMemoryController::new(test_core_memory_policy(512), 8192, 8192);
        controller.runtime_ready = true;
        let idle_deadline = now + Duration::from_secs(5);
        controller.idle_deadline = Some(idle_deadline);

        assert!(!controller.observe_docker_transport_bytes(now));
        assert!(!controller.observe_docker_transport_bytes(now + Duration::from_secs(1)));
        assert!(!controller.docker_transport_active);
        assert!(!controller.docker_transport_tracks_bytes);
        assert!(controller.last_docker_transport_activity.is_none());
        assert_eq!(controller.idle_deadline, Some(idle_deadline));
    }

    #[test]
    fn explicitly_tracked_opaque_transport_refreshes_its_quiet_deadline() {
        let now = Instant::now();
        let mut controller = CoreMemoryController::new(test_core_memory_policy(512), 8192, 8192);
        controller.runtime_ready = true;
        controller.docker_transport_active = true;
        controller.docker_transport_tracks_bytes = true;
        controller.last_docker_transport_activity = Some(now - Duration::from_secs(30));

        assert!(controller.observe_docker_transport_bytes(now));
        assert!(controller.docker_transport_active);
        assert!(controller.docker_transport_tracks_bytes);
        assert_eq!(controller.last_docker_transport_activity, Some(now));
    }

    #[test]
    fn idle_backing_compaction_waits_for_a_quiet_idle_target() {
        let now = Instant::now();
        let mut controller = CoreMemoryController::new(test_core_memory_policy(512), 8192, 512);
        controller.idle_backing_compaction_deadline = Some(now);
        controller.docker_transport_active = true;
        assert!(!controller.poll_idle_backing_compaction(now));
        assert!(controller.idle_backing_compaction_deadline.is_some());

        controller.docker_transport_active = false;
        assert!(controller.poll_idle_backing_compaction(now));
        assert!(controller.idle_backing_compaction_deadline.is_none());

        controller.defer_idle_backing_compaction(now);
        assert!(!controller.poll_idle_backing_compaction(now));
        assert!(controller
            .poll_idle_backing_compaction(now + DEFAULT_CORE_IDLE_BACKING_COMPACTION_RETRY_DWELL));
    }

    #[test]
    fn live_service_target_tracks_working_set_with_conservative_headroom() {
        let snapshot = GuestMemorySnapshot {
            mem_available: 6 * 1024 * 1024 * 1024,
            daemon_cgroup_working_set: 300 * 1024 * 1024,
            service_cgroup_memory_current: 900 * 1024 * 1024,
            service_cgroup_working_set: 600 * 1024 * 1024,
            service_cgroup_populated: true,
            service_cgroup_population_known: true,
            service_cgroup_telemetry_complete: true,
            service_cgroup_cgroup_id: 42,
            ..complete_global_memory_snapshot()
        };
        let policy = test_core_memory_policy(448);

        assert!(snapshot.has_live_service_telemetry());
        assert_eq!(
            snapshot.desired_service_target_mib(
                8192,
                8192,
                &policy,
                0,
                snapshot.protected_runtime_working_set(),
            ),
            2560
        );
    }

    #[test]
    fn live_service_target_never_consumes_guest_available_reserve() {
        let snapshot = GuestMemorySnapshot {
            mem_available: 600 * 1024 * 1024,
            service_cgroup_memory_current: 256 * 1024 * 1024,
            service_cgroup_working_set: 128 * 1024 * 1024,
            service_cgroup_populated: true,
            service_cgroup_population_known: true,
            service_cgroup_telemetry_complete: true,
            service_cgroup_cgroup_id: 42,
            ..complete_global_memory_snapshot()
        };
        let policy = test_core_memory_policy(448);

        assert_eq!(
            snapshot.desired_service_target_mib(
                8192,
                8192,
                &policy,
                0,
                snapshot.protected_runtime_working_set(),
            ),
            8192
        );
    }

    #[test]
    fn live_service_target_expands_to_replenish_available_reserve() {
        let snapshot = GuestMemorySnapshot {
            mem_available: 400 * 1024 * 1024,
            service_cgroup_memory_current: 256 * 1024 * 1024,
            service_cgroup_working_set: 128 * 1024 * 1024,
            service_cgroup_populated: true,
            service_cgroup_population_known: true,
            service_cgroup_telemetry_complete: true,
            service_cgroup_cgroup_id: 42,
            ..complete_global_memory_snapshot()
        };
        let policy = test_core_memory_policy(448);

        assert_eq!(
            snapshot.desired_service_target_mib(
                2048,
                8192,
                &policy,
                0,
                snapshot.protected_runtime_working_set(),
            ),
            2176
        );
    }

    #[test]
    fn missing_global_telemetry_blocks_service_capacity_reduction() {
        let complete = GuestMemorySnapshot {
            mem_available: 4 * 1024 * 1024 * 1024,
            service_cgroup_memory_current: 512 * 1024 * 1024,
            service_cgroup_working_set: 384 * 1024 * 1024,
            service_cgroup_populated: true,
            service_cgroup_population_known: true,
            service_cgroup_telemetry_complete: true,
            service_cgroup_cgroup_id: 42,
            ..complete_global_memory_snapshot()
        };
        assert!(complete.global_control_telemetry_complete());
        assert!(complete.has_live_service_telemetry());
        assert!(complete.service_feedback_is_safe());

        for (field, incomplete) in [
            (
                "mem_available_known",
                GuestMemorySnapshot {
                    mem_available_known: false,
                    ..complete
                },
            ),
            (
                "swap_telemetry_complete",
                GuestMemorySnapshot {
                    swap_telemetry_complete: false,
                    ..complete
                },
            ),
            (
                "disk_swap_telemetry_complete",
                GuestMemorySnapshot {
                    disk_swap_telemetry_complete: false,
                    ..complete
                },
            ),
            (
                "global_psi_telemetry_complete",
                GuestMemorySnapshot {
                    global_psi_telemetry_complete: false,
                    ..complete
                },
            ),
        ] {
            assert!(
                !incomplete.global_control_telemetry_complete(),
                "missing {field} must make global telemetry incomplete"
            );
            assert!(
                !incomplete.has_live_service_telemetry(),
                "missing {field} must block live-service shrink"
            );
            assert!(
                !incomplete.service_feedback_is_safe(),
                "missing {field} must fail watchdog feedback closed"
            );
        }

        let infrastructure_psi_blip = GuestMemorySnapshot {
            psi_some_avg10: 0.13,
            psi_full_avg10: 0.13,
            service_cgroup_psi_some_avg10: 0.0,
            service_cgroup_psi_full_avg10: 0.0,
            ..complete
        };
        assert!(infrastructure_psi_blip.service_feedback_is_safe());

        let sustained_global_pressure = GuestMemorySnapshot {
            psi_full_avg10: CORE_SERVICE_GLOBAL_PSI_FULL_LIMIT + 0.01,
            ..infrastructure_psi_blip
        };
        assert!(!sustained_global_pressure.service_feedback_is_safe());

        let service_pressure = GuestMemorySnapshot {
            psi_full_avg10: 0.0,
            service_cgroup_psi_full_avg10: CORE_SERVICE_PSI_FULL_LIMIT + 0.01,
            ..infrastructure_psi_blip
        };
        assert!(!service_pressure.service_feedback_is_safe());

        let legacy_snapshot = serde_json::from_str::<GuestMemorySnapshot>(
            r#"{"mem_available":4294967296,"swap_total":0,"swap_free":0,"psi_some_avg10":0.0,"psi_full_avg10":0.0}"#,
        )
        .unwrap();
        assert!(!legacy_snapshot.global_control_telemetry_complete());
    }

    #[test]
    fn service_adjustment_waits_for_convergence_and_stabilization() {
        let applied_at = Instant::now();
        let mut adjustment = ServiceCapacityAdjustment {
            previous_target_mib: 4096,
            target_mib: 3840,
            baseline: None,
            applied_at,
            next_convergence_observation_at: applied_at,
            converged_at: None,
        };
        assert!(adjustment.needs_convergence_observation(applied_at));
        assert_eq!(
            adjustment.convergence_deadline(),
            applied_at + CORE_SERVICE_SHRINK_CONVERGENCE_TIMEOUT
        );
        assert_eq!(
            adjustment.observe(applied_at, Some(false), Duration::from_secs(10)),
            ServiceAdjustmentReadiness::WaitingForConvergence
        );
        assert!(!adjustment.needs_convergence_observation(
            applied_at + CORE_SERVICE_CONVERGENCE_POLL_DWELL - Duration::from_millis(1)
        ));
        assert!(adjustment
            .needs_convergence_observation(applied_at + CORE_SERVICE_CONVERGENCE_POLL_DWELL));
        let converged_at = applied_at + Duration::from_secs(30);
        assert_eq!(
            adjustment.observe(converged_at, Some(true), Duration::from_secs(10)),
            ServiceAdjustmentReadiness::Stabilizing
        );
        assert_eq!(
            adjustment.observe(
                converged_at + Duration::from_secs(9),
                None,
                Duration::from_secs(10),
            ),
            ServiceAdjustmentReadiness::Stabilizing
        );
        assert_eq!(
            adjustment.observe(
                converged_at + Duration::from_secs(10),
                None,
                Duration::from_secs(10),
            ),
            ServiceAdjustmentReadiness::Ready
        );

        let same_target_restore = ServiceCapacityAdjustment {
            previous_target_mib: 8192,
            target_mib: 8192,
            baseline: None,
            applied_at,
            next_convergence_observation_at: applied_at,
            converged_at: None,
        };
        assert_eq!(
            same_target_restore.convergence_deadline(),
            applied_at + CORE_SERVICE_EXPANSION_CONVERGENCE_RETRY_DWELL
        );

        let deadline = adjustment.convergence_deadline();
        adjustment.converged_at = None;
        adjustment.next_convergence_observation_at = deadline + Duration::from_secs(60);
        assert!(
            adjustment.needs_convergence_observation(deadline),
            "the convergence deadline must force one final device observation"
        );
    }

    #[test]
    fn service_watchdog_cannot_consume_an_idle_feedback_probe() {
        let (tx, rx) = mpsc::channel();
        tx.send((7, Ok(GuestMemorySnapshot::default()))).unwrap();
        let probe = GuestMemoryProbe {
            kind: GuestMemoryProbeKind::Idle,
            receiver: rx,
        };

        assert!(probe
            .try_recv_for(GuestMemoryProbeKind::ServiceWatchdog)
            .is_none());
        let (generation, result) = probe
            .try_recv_for(GuestMemoryProbeKind::Idle)
            .expect("idle probe kind should match")
            .expect("idle result should remain queued");
        assert_eq!(generation, 7);
        assert!(result.is_ok());
    }

    #[test]
    fn active_service_mode_disables_hard_decommit_fallback() {
        assert!(!should_attempt_hard_decommit_fallback(false, false, false));
        assert!(should_attempt_hard_decommit_fallback(false, true, false));
        assert!(should_attempt_hard_decommit_fallback(true, false, false));
        assert!(!should_attempt_hard_decommit_fallback(true, true, true));
    }

    #[test]
    fn live_service_feedback_uses_guest_page_size_for_refault_guard() {
        let baseline = GuestMemorySnapshot {
            page_size_bytes: 16 * 1024,
            service_cgroup_cgroup_id: 42,
            service_cgroup_telemetry_complete: true,
            service_cgroup_population_known: true,
            service_cgroup_populated: true,
            ..complete_global_memory_snapshot()
        };
        let stable = GuestMemorySnapshot {
            service_cgroup_workingset_refault_file: 100,
            ..baseline
        };
        let adjustment = ServiceCapacityAdjustment {
            previous_target_mib: 8192,
            target_mib: 7680,
            baseline: Some(baseline),
            applied_at: Instant::now(),
            next_convergence_observation_at: Instant::now(),
            converged_at: Some(Instant::now()),
        };
        assert!(stable
            .service_feedback_regression(&baseline, adjustment)
            .is_none());

        let refaulting = GuestMemorySnapshot {
            service_cgroup_workingset_refault_file: 700,
            ..baseline
        };
        let regression = refaulting
            .service_feedback_regression(&baseline, adjustment)
            .expect("16 KiB refault pages should cross the feedback budget");
        assert_eq!(regression.kind, ServiceFeedbackRegressionKind::Refault);
        assert_eq!(regression.refault_bytes, 700 * 16 * 1024);
    }

    #[test]
    fn live_service_feedback_observes_hierarchical_memory_events() {
        let baseline = GuestMemorySnapshot {
            service_cgroup_cgroup_id: 42,
            service_cgroup_telemetry_complete: true,
            service_cgroup_population_known: true,
            service_cgroup_populated: true,
            ..complete_global_memory_snapshot()
        };
        let pressured = GuestMemorySnapshot {
            service_cgroup_memory_events_high: 1,
            ..baseline
        };
        let now = Instant::now();
        let adjustment = ServiceCapacityAdjustment {
            previous_target_mib: 4096,
            target_mib: 3840,
            baseline: Some(baseline),
            applied_at: now,
            next_convergence_observation_at: now,
            converged_at: Some(now),
        };
        let regression = pressured
            .service_feedback_regression(&baseline, adjustment)
            .expect("hierarchical memory.high event must fail the shrink");
        assert_eq!(regression.kind, ServiceFeedbackRegressionKind::HardPressure);

        let independently_pressured = GuestMemorySnapshot {
            service_cgroup_memory_events_high: 100,
            service_cgroup_memory_events_local_high: 1,
            ..baseline
        };
        let independent_baseline = GuestMemorySnapshot {
            service_cgroup_memory_events_high: 100,
            ..baseline
        };
        let regression = independently_pressured
            .service_feedback_regression(&independent_baseline, adjustment)
            .expect("a local event increment must not be masked by a larger hierarchical count");
        assert_eq!(regression.kind, ServiceFeedbackRegressionKind::HardPressure);
        assert!(independently_pressured.urgent_service_regression_since(&independent_baseline));

        let bounded_control_plane_zram = GuestMemorySnapshot {
            swap_total: 1024 * 1024 * 1024,
            swap_free: 1024 * 1024 * 1024 - CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES,
            ..baseline
        };
        assert!(bounded_control_plane_zram.service_feedback_is_safe());
        assert!(bounded_control_plane_zram
            .service_feedback_regression(&baseline, adjustment)
            .is_none());

        let swapping = GuestMemorySnapshot {
            swap_total: 1024 * 1024 * 1024,
            swap_free: 1024 * 1024 * 1024 - CORE_CONTROL_PLANE_ZRAM_SWAP_BUDGET_BYTES - 4096,
            ..baseline
        };
        let regression = swapping
            .service_feedback_regression(&baseline, adjustment)
            .expect("swap growth beyond the control-plane budget must fail the shrink");
        assert_eq!(regression.kind, ServiceFeedbackRegressionKind::HardPressure);

        let disk_swap_only = GuestMemorySnapshot {
            disk_swap_used: 4096,
            ..baseline
        };
        let regression = disk_swap_only
            .service_feedback_regression(&baseline, adjustment)
            .expect("disk swap growth must fail even without aggregate swap telemetry");
        assert_eq!(regression.kind, ServiceFeedbackRegressionKind::HardPressure);

        let bounded_container_zram = GuestMemorySnapshot {
            container_swap_current: CORE_CONTAINER_ZRAM_SWAP_BUDGET_BYTES,
            ..baseline
        };
        assert!(bounded_container_zram.service_feedback_is_safe());

        let preexisting_container_swap = GuestMemorySnapshot {
            container_swap_current: CORE_CONTAINER_ZRAM_SWAP_BUDGET_BYTES + 4096,
            ..baseline
        };
        assert!(
            !preexisting_container_swap.service_feedback_is_safe(),
            "existing container swap must block another capacity reduction"
        );
    }

    #[test]
    fn live_service_transition_is_clamped_above_stopped_idle_floor() {
        let mut controller = CoreMemoryController::new(test_core_memory_policy(448), 8192, 8192);
        assert_eq!(
            controller.target_mib(CoreMemoryTargetTransition::AdjustService(512)),
            2048
        );
        assert_eq!(
            controller.target_mib(CoreMemoryTargetTransition::AdjustService(4096)),
            4096
        );
        controller.requested_target_mib = 2048;
        assert!(!controller.idle_target_reached());
    }

    #[test]
    fn docker_transport_bytes_include_both_stream_directions() {
        let metrics = crate::vmm::vstate::DockerPhaseMetrics {
            request_bytes: 17,
            response_bytes: 29,
            ..Default::default()
        };
        assert_eq!(docker_transport_bytes(&metrics), 46);
    }
}

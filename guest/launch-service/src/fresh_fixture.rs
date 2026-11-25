use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use crate::build_snapshot::mounts::LiveMounts;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::handshake::{hex, random};
use crate::image_store::{self, ConnectionId};
use crate::intent::{DIRECTORY, Intent};
use crate::output::{Capture, drain};
use crate::prepared::{CANCEL, ClaimError, RELEASE, SLOT_MEMORY_LIMIT, SLOT_TTL, Slot, TERMINATE};
use crate::socket::Stream;
use crate::spec::{BridgeScope, LaunchRequest, LaunchSpec, ValidatedLaunch};
use crate::wire::{Frame, Kind, WireError, write_error};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Image {
    executable_sha256: String,
    architecture: String,
    os: String,
}

#[derive(Deserialize)]
struct BenchmarkManifest {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    annotations: std::collections::BTreeMap<String, String>,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Handle {
    boot_id: String,
    workload_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Control {
    handle: Handle,
    budget_ms: u64,
    signal: Option<u8>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Claim {
    handle: Handle,
    budget_ms: u64,
    spec: LaunchSpec,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MemoryRequest {
    boot_id: String,
    budget_ms: u64,
    pressure: Option<bool>,
    core_grant: Option<crate::core_admission::Admission>,
    #[serde(default)]
    core_only: bool,
    #[serde(default)]
    watch_pending: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Wait {
    handle: Handle,
    budget_ms: u64,
    after_revision: u64,
    #[serde(default)]
    terminal_output: bool,
    live_output: Option<OutputCursors>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OutputCursors {
    stdout: usize,
    stderr: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Output {
    handle: Handle,
    budget_ms: u64,
    stream: String,
    offset: usize,
    max_bytes: usize,
    #[serde(default)]
    follow: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Exec {
    handle: Handle,
    budget_ms: u64,
    argv: Vec<String>,
    #[serde(default)]
    tty: bool,
    #[serde(default)]
    stdin: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExecStream {
    handle: Handle,
    budget_ms: u64,
    argv: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Inspect {
    budget_ms: u64,
    #[serde(default)]
    workload: Option<Handle>,
    #[serde(default)]
    include_builds: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExecOutput {
    boot_id: String,
    budget_ms: u64,
    output_id: String,
    stream: String,
    offset: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkloadCopy {
    boot_id: String,
    handle: Handle,
    budget_ms: u64,
    operation: crate::workload_copy::Operation,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CopyDownload {
    handle: Handle,
    budget_ms: u64,
    path: String,
    identity: crate::workload_copy::Identity,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CopyUpload {
    handle: Handle,
    budget_ms: u64,
    archive: crate::workload_copy::UploadSpec,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkloadInput {
    handle: Handle,
    budget_ms: u64,
    data: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ImageAccount {
    boot_id: String,
    image_digest: String,
    account: crate::spec::Account,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NetworkRequest {
    boot_id: String,
    budget_ms: u64,
    operation: NetworkOperation,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum NetworkOperation {
    Connect {
        handle: Handle,
        alias: String,
        #[serde(default)]
        scope: Option<BridgeScope>,
    },
    Disconnect {
        handle: Handle,
    },
    Remove,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Dial {
    handle: Handle,
    budget_ms: u64,
    port: u16,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VolumeRequest {
    boot_id: String,
    budget_ms: u64,
    operation: VolumeOperation,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuildSnapshotRequest {
    boot_id: String,
    budget_ms: u64,
    id: String,
    #[serde(default)]
    verify_bundle: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuildRuntimeRequest {
    boot_id: String,
    id: String,
    operation: BuildOperation,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum BuildOperation {
    Run,
    Status { stdout: usize, stderr: usize },
    Kill,
    Delete,
}

#[derive(Default)]
struct BuildRuntime {
    active: Option<ActiveBuild>,
    deleted: Vec<(Option<String>, String)>,
}

struct ActiveBuild {
    id: String,
    handle: Handle,
    owner: Option<String>,
}

struct WorkerBuild {
    owner: String,
    volume: crate::spec::VolumeMount,
    mounts: LiveMounts,
}

struct HelperLaunch {
    spec: String,
    open_stdin: bool,
    live_mounts: Option<LiveMounts>,
    build_owner: Option<String>,
}

const BUILD_GENERATIONS: usize = 256;
const BUILD_SEQUENCE_BASE: u64 = 1 << 63;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum VolumeOperation {
    List {
        #[serde(default)]
        details: bool,
    },
    Create {
        name: String,
        #[serde(default)]
        labels: crate::volume_disk::VolumeLabels,
    },
    Inspect {
        name: String,
    },
    Remove {
        name: String,
    },
}

impl VolumeOperation {
    fn execute(self) -> Reply {
        use crate::volume_disk::guest as volumes;
        if !volumes::available() {
            return Err(("unsupported_option", "native volume disk is not configured"));
        }
        let error = |error: io::Error| match error.kind() {
            io::ErrorKind::InvalidInput => ("malformed", "invalid native volume name"),
            io::ErrorKind::NotFound => ("not_found", "native volume is absent"),
            io::ErrorKind::StorageFull => ("capacity", "native volume storage is full"),
            _ => ("storage_failed", "native volume operation failed"),
        };
        let response = match self {
            Self::List { details: false } => json!({"volumes": volumes::names().map_err(error)?}),
            Self::List { details: true } => {
                let entries = volumes::names()
                    .map_err(error)?
                    .iter()
                    .map(|name| volumes::inspect(name))
                    .collect::<io::Result<Vec<_>>>()
                    .map_err(error)?;
                json!({"volumes": entries})
            }
            Self::Create { name, labels } => json!(volumes::create(&name, &labels).map_err(error)?),
            Self::Inspect { name } => json!(volumes::inspect(&name).map_err(error)?),
            Self::Remove { name } => {
                volumes::remove(&name).map_err(error)?;
                json!({"removed": true})
            }
        };
        Ok((Kind::Volume, response))
    }
}

const OUTPUT_CHUNK_LIMIT: usize = 8192;
const OCI_CONCURRENCY: usize = crate::core_admission::CAPACITY;
const OCI_RECORDS: usize = 24;

fn output_chunk(output: &Capture, offset: usize, limit: usize, terminal: bool) -> Value {
    let next = (offset + limit).min(output.bytes.len());
    json!({
        "offset": offset, "next_offset": next,
        "data": base64::engine::general_purpose::STANDARD.encode(&output.bytes[offset..next]),
        "eof": terminal && next == output.bytes.len(),
        "dropped_bytes": output.dropped,
    })
}

fn output_bundle(record: &Record, stdout: usize, stderr: usize, terminal: bool) -> Value {
    let stdout_limit = (record.stdout.bytes.len() - stdout).min(OUTPUT_CHUNK_LIMIT);
    json!({
        "stdout":output_chunk(&record.stdout, stdout, stdout_limit, terminal),
        "stderr":output_chunk(&record.stderr, stderr, OUTPUT_CHUNK_LIMIT - stdout_limit, terminal),
    })
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Phase {
    Accepted,
    Preparing,
    ChildCreated,
    PreparedReady,
    Claimed,
    Running,
    Exiting,
    Cleaning,
    Removed,
    CleanupFailed,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Preparing => "preparing",
            Self::ChildCreated => "child_created",
            Self::PreparedReady => "prepared_ready",
            Self::Claimed => "claimed",
            Self::Running => "running",
            Self::Exiting => "exiting",
            Self::Cleaning => "cleaning",
            Self::Removed => "removed",
            Self::CleanupFailed => "cleanup_failed",
        }
    }

    fn terminal(self) -> bool {
        matches!(self, Self::Removed | Self::CleanupFailed)
    }
}

struct Record {
    handle: Handle,
    sequence: u64,
    body: [u8; 32],
    image_digest: String,
    exec_context: Option<(LaunchSpec, OwnedFd)>,
    phase: Phase,
    revision: u64,
    exec: &'static str,
    exit: Option<Value>,
    helper_failed: bool,
    network_cleanup: &'static str,
    network_scope: Option<BridgeScope>,
    network_aliases: Vec<String>,
    network_alias_project: Option<String>,
    network_address: Option<std::net::Ipv4Addr>,
    trace: Option<Trace>,
    slot: Option<Slot>,
    slot_expires: Option<Instant>,
    slot_expired: bool,
    memory_limit_bytes: u64,
    volume: Option<crate::spec::VolumeMount>,
    bind_lease: Option<String>,
    build_snapshot: Option<crate::build_snapshot::Snapshot>,
    build_runtime_owned: bool,
    build_parent: Option<String>,
    buildkit_worker: bool,
    buildkit_registry: bool,
    core_admission_deadline: Option<Instant>,
    cancelled: bool,
    terminate_requested: bool,
    control: Option<UnixStream>,
    input: Option<fs::File>,
    stdout: Capture,
    stderr: Capture,
}

struct Trace {
    admitted: Instant,
    events: BTreeMap<&'static str, u128>,
    core: bool,
}

impl Record {
    fn cgroup_path(&self, oci: bool) -> std::path::PathBuf {
        let id = &self.handle.workload_id;
        if let Some(owner) = &self.build_parent {
            return crate::kernel_fixture::build_cgroup_path(owner).join(id);
        }
        if self.buildkit_worker {
            return crate::kernel_fixture::build_cgroup_path(id);
        }
        crate::kernel_fixture::cgroup_scope(id, self.slot.is_some(), oci)
    }

    fn pending_core_admission(&self, now: Instant) -> bool {
        self.phase == Phase::Accepted
            && !self.terminate_requested
            && self
                .core_admission_deadline
                .is_some_and(|deadline| now < deadline)
    }

    fn change(&mut self, phase: Phase) {
        self.phase = phase;
        self.revision += 1;
        self.mark(phase.name());
    }

    fn mark(&mut self, milestone: &'static str) {
        self.mark_at(milestone, self.trace.as_ref().map(|_| Instant::now()));
    }

    fn mark_at(&mut self, milestone: &'static str, time: Option<Instant>) {
        if let (Some(trace), Some(time)) = (&mut self.trace, time) {
            trace.events.insert(
                milestone,
                time.saturating_duration_since(trace.admitted).as_nanos(),
            );
        }
    }

    fn state(&self) -> Value {
        let mut state = json!({
            "handle": self.handle, "revision": self.revision, "phase": self.phase.name(),
            "exec": self.exec, "exit": self.exit, "helper_failed": self.helper_failed,
            "network_cleanup": self.network_cleanup,
            "cleanup": match self.phase {
                Phase::Removed => "complete",
                Phase::CleanupFailed => "failed",
                _ => "pending",
            }
        });
        if let Some(trace) = &self.trace
            && (!trace.core || self.phase.terminal())
        {
            state["guest_phase_ns"] = json!(trace.events);
            if trace.core {
                state["trace_sequence"] = json!(self.sequence);
            }
        }
        if let Some(snapshot) = &self.build_snapshot {
            state["build_snapshot"] = json!(snapshot);
        }
        if let Some(address) = self.network_address {
            state["network_address"] = json!(address);
        }
        if let Some(slot) = &self.slot {
            state["prepared_claimed"] = json!(slot.claimed());
            state["prepared_expired"] = json!(self.slot_expired);
        }
        state
    }

    fn cancel(&mut self) {
        if self.cancelled || self.phase.terminal() {
            return;
        }
        self.cancelled = true;
        if let Some(slot) = &mut self.slot {
            slot.discard();
        }
        if let Some(control) = &mut self.control {
            let _ = control.write_all(&[CANCEL]);
        }
        if matches!(
            self.phase,
            Phase::Accepted
                | Phase::Preparing
                | Phase::ChildCreated
                | Phase::PreparedReady
                | Phase::Claimed
                | Phase::Running
        ) {
            self.change(Phase::Exiting);
        }
    }

    fn terminate(&mut self) -> io::Result<()> {
        if self.cancelled || self.terminate_requested || self.phase.terminal() {
            return Ok(());
        }
        if let Some(control) = &mut self.control {
            control.write_all(&[TERMINATE])?;
        }
        self.terminate_requested = true;
        Ok(())
    }
}

#[derive(Default)]
struct Ledger {
    images: image_store::Store,
    copies: crate::workload_copy::Store,
    highest_sequence: u64,
    closing: bool,
    waiting: usize,
    core_watcher: bool,
    records: VecDeque<Record>,
    pressure: bool,
    pressure_helper: Option<std::process::Child>,
    evictions: u64,
    exec_active: bool,
    exec_streams: usize,
    exec_output: Option<PendingExecOutput>,
    archive_downloads: usize,
}

struct PendingExecOutput {
    id: String,
    owner: ConnectionId,
    streams: [Capture; 2],
    offsets: [usize; 2],
    expires: Instant,
}

impl Ledger {
    fn archive_target(&self, handle: &Handle) -> Result<&(LaunchSpec, OwnedFd), Failure> {
        if self.closing {
            return Err(("busy", "native archive service is draining"));
        }
        let record = self
            .record(&handle.workload_id)
            .filter(|record| record.handle == *handle)
            .ok_or(("not_found", "unknown native workload"))?;
        if record.phase == Phase::Running
            && !record.cancelled
            && !record.terminate_requested
            && let Some(target) = &record.exec_context
        {
            return Ok(target);
        }
        Err(("not_running", "archive requires a running native workload"))
    }

    fn build_worker(&self, cgroup: &str) -> Option<&Record> {
        self.active().find(|record| {
            let id = &record.handle.workload_id;
            record.buildkit_worker
                && record.phase == Phase::Running
                && !record.cancelled
                && !record.terminate_requested
                && cgroup == format!("conjet-native-{id}/workloads/active/{id}/{id}")
        })
    }

    fn exec_target(
        &self,
        handle: &Handle,
        argv: Vec<String>,
    ) -> Result<(LaunchSpec, OwnedFd, [u8; 16]), Failure> {
        let record = self
            .record(&handle.workload_id)
            .filter(|record| record.handle == *handle)
            .ok_or(("stale_generation", "native exec workload is not owned"))?;
        if matches!(
            record.phase,
            Phase::Accepted | Phase::Preparing | Phase::ChildCreated
        ) {
            return Err(("preparing", "native exec target is still starting"));
        }
        let (spec, pidfd) = record
            .exec_context
            .as_ref()
            .filter(|_| record.phase == Phase::Running)
            .ok_or(("not_running", "native exec requires a live OCI process"))?;
        let mut spec = spec.clone();
        spec.set_exec_argv(argv);
        spec.validate_exec()
            .map_err(|_| ("invalid_spec", "invalid native exec argv"))?;
        let pidfd = pidfd
            .try_clone()
            .map_err(|_| ("busy", "cannot retain native exec target"))?;
        let id = crate::handshake::unhex(&handle.workload_id)
            .map_err(|_| ("malformed", "invalid native workload ID"))?;
        Ok((spec, pidfd, id))
    }

    fn complete_exec(
        &mut self,
        result: crate::exec_fixture::ExecResult,
        connection: ConnectionId,
    ) -> Reply {
        let [stdout, stderr] = &result.streams;
        let exit = result.code;
        if stdout.bytes.len() + stderr.bytes.len() <= OUTPUT_CHUNK_LIMIT {
            return Ok((
                Kind::Exec,
                json!({
                    "exit_code":exit,
                    "stdout":output_chunk(stdout, 0, OUTPUT_CHUNK_LIMIT, true),
                    "stderr":output_chunk(stderr, 0, OUTPUT_CHUNK_LIMIT, true),
                }),
            ));
        }
        let id = hex(&random::<16>().map_err(|_| ("busy", "secure exec output ID unavailable"))?);
        let sizes =
            |stream: &Capture| json!({"bytes":stream.bytes.len(),"dropped_bytes":stream.dropped});
        let reply = json!({"exit_code":exit, "output_id":id, "stdout":sizes(stdout), "stderr":sizes(stderr)});
        self.exec_output = Some(PendingExecOutput {
            id,
            owner: connection,
            streams: result.streams,
            offsets: [0; 2],
            expires: Instant::now() + Duration::from_secs(5),
        });
        Ok((Kind::Exec, reply))
    }

    fn read_exec_output(&mut self, request: ExecOutput, connection: ConnectionId) -> Reply {
        let stream = match request.stream.as_str() {
            "stdout" => 0,
            "stderr" => 1,
            _ => return Err(("malformed", "invalid exec output stream")),
        };
        let output = self
            .exec_output
            .as_mut()
            .filter(|output| output.owner == connection && output.id == request.output_id)
            .ok_or((
                "not_found",
                "exec output does not belong to this connection",
            ))?;
        let data = &output.streams[stream];
        if request.offset != output.offsets[stream] || request.offset >= data.bytes.len() {
            return Err(("malformed", "invalid exec output offset"));
        }
        let reply = output_chunk(data, request.offset, OUTPUT_CHUNK_LIMIT, true);
        output.offsets[stream] = (request.offset + OUTPUT_CHUNK_LIMIT).min(data.bytes.len());
        if output
            .streams
            .iter()
            .zip(output.offsets)
            .all(|(data, offset)| data.bytes.len() == offset)
        {
            self.exec_output = None;
        }
        Ok((Kind::ExecOutput, reply))
    }

    fn record(&self, id: &str) -> Option<&Record> {
        self.records
            .iter()
            .find(|record| record.handle.workload_id == id)
    }

    fn record_mut(&mut self, id: &str) -> Option<&mut Record> {
        self.records
            .iter_mut()
            .find(|record| record.handle.workload_id == id)
    }

    fn active(&self) -> impl Iterator<Item = &Record> {
        self.records
            .iter()
            .filter(|record| record.phase != Phase::Removed)
    }

    fn memory_snapshot(&self, oci: bool) -> Value {
        let available = crate::memory::available_bytes();
        let mut snapshot = json!({
            "active": null, "prepared": null,
            "pressure": self.pressure || crate::memory::pressures_reserve(available),
            "requested_pressure": self.pressure, "available_bytes": available,
            "prepared_floor_bytes": crate::memory::MIN_AVAILABLE_BYTES,
            "pressure_evictions": self.evictions,
        });
        let mut active_workloads = Vec::new();
        for record in self.active() {
            let prepared_scope = record.slot.is_some();
            let active = record.slot.as_ref().is_none_or(Slot::claimed);
            let path = record.cgroup_path(oci);
            let observed = crate::cgroups::observation(&path).ok();
            let mut state = json!({
                "handle": record.handle, "phase": record.phase.name(),
                "scope": if prepared_scope { "prepared" } else { "active" },
                "limit_bytes": record.memory_limit_bytes,
                "sample_valid": observed.is_some(),
                "current_bytes": observed.map(|(bytes, _)| bytes),
                "populated": observed.map(|(_, populated)| populated),
            });
            if oci && let Ok(id) = crate::handshake::unhex::<16>(&record.handle.workload_id) {
                let owner = record
                    .build_parent
                    .as_deref()
                    .unwrap_or(&record.handle.workload_id);
                let (mut mount, scope) = crate::kernel_fixture::cgroup_paths(owner, true);
                if record.buildkit_worker || record.build_parent.is_some() {
                    mount = crate::kernel_fixture::CORE_CGROUP_MOUNT.into();
                }
                let overlay = crate::sandbox_fixture::owned_path(id, true);
                state["paths"] = json!({
                    "cgroup_mount":mount,"cgroup_scope":scope,"overlay":overlay,
                    "overlay_present":overlay.is_dir(),"cgroup_directory":path,
                });
                if let Some(owner) = &record.build_parent {
                    state["accounted_by"] = json!(owner);
                }
                if let Ok((limits, active_pids)) =
                    crate::kernel_fixture::cgroup_effective_limits(&path)
                {
                    state["effective_limits"] = limits;
                    state["active_pids"] = json!(active_pids);
                }
            }
            if oci && active {
                active_workloads.push(state.clone());
            }
            snapshot[if active { "active" } else { "prepared" }] = state;
        }
        if oci {
            snapshot["active_workloads"] = json!(active_workloads);
        }
        snapshot
    }

    fn core_admission(
        &mut self,
        now: Instant,
        observing: bool,
    ) -> crate::core_admission::Observation {
        let owned = self.active().count();
        let pending = self
            .records
            .iter_mut()
            .filter(|record| record.pending_core_admission(now))
            .map(|record| {
                if observing && let Some(trace) = &mut record.trace {
                    trace.events.entry("observed").or_insert_with(|| {
                        now.saturating_duration_since(trace.admitted).as_nanos()
                    });
                }
                crate::core_admission::Admission {
                    workload_id: record.handle.workload_id.clone(),
                    sequence: record.sequence,
                }
            })
            .collect();
        crate::core_admission::Observation { owned, pending }
    }

    fn has_pending_core_admission(&self, now: Instant) -> bool {
        self.records
            .iter()
            .any(|record| record.pending_core_admission(now))
    }

    fn grant_core_admission(
        &mut self,
        grant: crate::core_admission::Admission,
        boot: &str,
        now: Instant,
    ) -> Result<(), Failure> {
        let record = self
            .record_mut(&grant.workload_id)
            .filter(|record| record.handle.boot_id == boot && record.sequence == grant.sequence)
            .ok_or(("stale_generation", "Core admission identity changed"))?;
        if record.phase != Phase::Accepted
            || record.terminate_requested
            || record
                .core_admission_deadline
                .is_none_or(|deadline| now >= deadline)
        {
            return Err(("not_pending", "workload has no live Core admission"));
        }
        record.core_admission_deadline = None;
        record.mark("granted");
        Ok(())
    }

    fn set_pressure(&mut self, pressure: bool) {
        self.pressure = pressure;
        if pressure
            && let Some(record) = self.records.back_mut()
            && !record.phase.terminal()
            && !record.cancelled
            && record.slot.as_ref().is_some_and(|slot| !slot.claimed())
        {
            record.cancel();
            self.evictions = self.evictions.saturating_add(1);
        }
    }

    fn set_pressure_fixture(&mut self, pressure: bool) -> io::Result<()> {
        if let Some(helper) = self.pressure_helper.as_mut() {
            if helper.try_wait()?.is_none() {
                if pressure {
                    return Ok(());
                }
                helper.kill()?;
                helper.wait()?;
            }
            self.pressure_helper = None;
        }
        if pressure {
            self.pressure_helper = Some(
                Command::new("/init")
                    .arg("--verify-core-pressure-fixture")
                    .spawn()?,
            );
        }
        Ok(())
    }
}

pub(crate) struct FreshFixture {
    image_digest: String,
    benchmark_digest: Option<String>,
    native: bool,
    oci: bool,
    core_admission: bool,
    core_pressure_fixture: bool,
    trace_benchmark: bool,
    trace_core_latency: bool,
    bridge_available: bool,
    allow_crash: bool,
    intent: Intent,
    ledger: Mutex<Ledger>,
    build_runtime: Mutex<BuildRuntime>,
    build_registry: Mutex<Option<BuildRegistry>>,
    private_networks: Mutex<[Option<crate::bridge_fixture::NetworkOwner>; 2]>,
    changed: Condvar,
}

struct BuildRegistry {
    owner: String,
    address: std::net::Ipv4Addr,
    listener: std::net::TcpListener,
}

pub(crate) struct ConnectionLease<'a> {
    pub(crate) fresh: &'a FreshFixture,
    pub(crate) id: ConnectionId,
}

impl Drop for ConnectionLease<'_> {
    fn drop(&mut self) {
        let mut ledger = self.fresh.ledger.lock().expect("fresh ledger");
        ledger.images.disconnect(self.id);
        ledger.copies.disconnect(self.id);
        if ledger
            .exec_output
            .as_ref()
            .is_some_and(|output| output.owner == self.id)
        {
            ledger.exec_output = None;
        }
    }
}

type Failure = (&'static str, &'static str);
type Reply = Result<(Kind, Value), Failure>;

fn archive_failure(error: io::Error) -> Failure {
    if let Some(publish) = error
        .get_ref()
        .and_then(|cause| cause.downcast_ref::<crate::workload_copy::PublishError>())
    {
        (publish.0, "native workload archive publication failed")
    } else if error.kind() == io::ErrorKind::NotFound {
        ("not_found", "native workload archive path was not found")
    } else {
        (
            "archive_rejected",
            "native workload archive path or file is unsupported",
        )
    }
}

fn bounded_file(path: &str, limit: u64) -> io::Result<Vec<u8>> {
    let mut buffer = Vec::new();
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let info = file.metadata()?;
    if !info.is_file() || info.uid() != 0 || info.mode() & 0o022 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "fixture asset must be root-owned",
        ));
    }
    file.take(limit + 1).read_to_end(&mut buffer)?;
    if buffer.len() as u64 > limit {
        return Err(io::Error::other("fixture input exceeded its bound"));
    }
    Ok(buffer)
}

fn benchmark_image() -> Result<Option<String>, Box<dyn std::error::Error>> {
    let manifest = match bounded_file("/etc/conjet/benchmark-image.json", 8_192) {
        Ok(manifest) => manifest,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let descriptor: BenchmarkManifest = serde_json::from_slice(&manifest)?;
    let workload = bounded_file(
        crate::sandbox_fixture::BENCHMARK_EXECUTABLE,
        4 * 1024 * 1024,
    )?;
    let workload_sha = hex(&Sha256::digest(&workload));
    if descriptor.schema_version != 2
        || descriptor
            .annotations
            .get("dev.conjet.fixture.workload.sha256")
            != Some(&workload_sha)
    {
        return Err("benchmark executable does not match the staged OCI manifest".into());
    }
    Ok(Some(format!("sha256:{}", hex(&Sha256::digest(&manifest)))))
}

impl FreshFixture {
    pub(crate) fn open(
        allow_crash: bool,
        native: bool,
    ) -> Result<Arc<Self>, Box<dyn std::error::Error>> {
        if std::process::id() == 1 || unsafe { libc::getppid() } != 1 {
            return Err("fresh fixture requires a supervisor child of guest init".into());
        }
        let oci_marker = if native {
            match bounded_file("/etc/conjet/native-oci-image", 71) {
                Ok(marker) => Some(String::from_utf8(marker)?),
                Err(error) if error.kind() == io::ErrorKind::NotFound => None,
                Err(error) => return Err(error.into()),
            }
        } else {
            None
        };
        let oci = oci_marker.is_some();
        let core_admission = oci && Path::new(crate::core_admission::MARKER).try_exists()?;
        let core_pressure_fixture =
            core_admission && Path::new(crate::core_admission::PRESSURE_MARKER).try_exists()?;
        let trace_core_latency =
            core_admission && Path::new(crate::core_admission::TRACE_MARKER).try_exists()?;
        let image_digest = if let Some(digest) = oci_marker {
            let hex = digest
                .strip_prefix("sha256:")
                .ok_or("invalid OCI config digest")?;
            crate::handshake::unhex::<32>(hex)?;
            let root = fs::symlink_metadata(crate::sandbox_fixture::OCI_ROOT)?;
            if !root.is_dir() || root.uid() != 0 || root.mode() & 0o022 != 0 {
                return Err("OCI root must be installed by the trusted guest image".into());
            }
            digest
        } else {
            let (spec_file, executable_file) = if native {
                (
                    "/etc/conjet/native-image.json",
                    crate::sandbox_fixture::NATIVE_EXECUTABLE,
                )
            } else {
                ("/etc/conjet/fresh-fixture-image.json", "/init")
            };
            let manifest = bounded_file(spec_file, 4_096)?;
            let image: Image = serde_json::from_slice(&manifest)?;
            let executable = bounded_file(executable_file, 4 * 1024 * 1024)?;
            if image.os != "linux"
                || image.architecture != "arm64"
                || image.executable_sha256 != hex(&Sha256::digest(&executable))
            {
                return Err("launch image identity differs from its verified input".into());
            }
            if native {
                format!("sha256:{}", image.executable_sha256)
            } else {
                format!("sha256:{}", hex(&Sha256::digest(&manifest)))
            }
        };
        let (benchmark_digest, trace_benchmark) = if native {
            (None, false)
        } else {
            let trace = match bounded_file("/etc/conjet/benchmark-timing", 2) {
                Ok(contents) if contents == b"1\n" => true,
                Ok(_) => return Err("invalid benchmark timing marker".into()),
                Err(error) if error.kind() == io::ErrorKind::NotFound => false,
                Err(error) => return Err(error.into()),
            };
            (benchmark_image()?, trace)
        };
        let directory = Path::new(DIRECTORY);
        match fs::DirBuilder::new().mode(0o700).create(directory) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        let metadata = directory.symlink_metadata()?;
        if !metadata.is_dir() || metadata.uid() != 0 || metadata.mode() & 0o777 != 0o700 {
            return Err("fixture intent directory must be private to root".into());
        }
        let intent = Intent::open(directory);
        if intent.read()?.is_some() || (oci && !intent.scoped_inventory()?.is_empty()) {
            return Err("unresolved fresh workload intent".into());
        }
        // Reparent orphans from an interrupted helper here, while the live
        // supervisor still owns their workload intent and cgroup.
        crate::security::checked(unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) })?;
        let bridge_available = !native
            && Command::new("/init")
                .arg("--check-bridge-availability")
                .env_clear()
                .status()?
                .success();
        Ok(Arc::new(Self {
            image_digest,
            benchmark_digest,
            native,
            oci,
            core_admission,
            core_pressure_fixture,
            trace_benchmark,
            trace_core_latency,
            bridge_available,
            allow_crash,
            intent,
            ledger: Mutex::new(Ledger::default()),
            build_runtime: Mutex::default(),
            build_registry: Mutex::default(),
            private_networks: Mutex::new(Default::default()),
            changed: Condvar::new(),
        }))
    }

    pub(crate) fn is_oci(&self) -> bool {
        self.oci
    }

    pub(crate) fn has_core_admission(&self) -> bool {
        self.core_admission
    }

    pub(crate) fn is_native(&self) -> bool {
        self.native
    }

    pub(crate) fn bridge_available(&self) -> bool {
        self.bridge_available
    }

    fn update(&self, id: &str, f: impl FnOnce(&mut Record)) {
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        if let Some(record) = ledger.record_mut(id) {
            f(record);
            self.changed.notify_all();
        }
    }

    fn admit(
        self: &Arc<Self>,
        ready: ValidatedLaunch,
        boot: &str,
        deadline: Instant,
        prepared: bool,
        build: bool,
        live: Option<WorkerBuild>,
    ) -> Reply {
        if ready.request().boot_id != boot {
            return Err(("stale_generation", "unexpected boot ID"));
        }
        if self.native && ready.request().operation_id.is_none() {
            return Err(("invalid_spec", "native admission requires an operation ID"));
        }
        if (ready.request().sequence >= BUILD_SEQUENCE_BASE) != build {
            return Err(("invalid_spec", "invalid launch sequence domain"));
        }
        let spec = &ready.request().spec;
        if spec.buildkit_worker
            && (!crate::image_store::disk_store_enabled()
                || !Path::new(crate::build_snapshot::MARKER).is_file())
        {
            return Err((
                "unsupported_option",
                "BuildKit requires the leased native workspace",
            ));
        }
        if spec.buildkit_registry() && spec.bridge_scope() != Some(BridgeScope::BuiltIn) {
            return Err((
                "unsupported_option",
                "BuildKit registry requires the private built-in bridge",
            ));
        }
        if !self.oci && !spec.fixture_identity() {
            return Err((
                "invalid_spec",
                "the static fixture requires UID and GID 65532",
            ));
        }
        if spec
            .build_snapshot
            .as_ref()
            .is_some_and(|snapshot| snapshot.bundle_policy)
            != build
            || spec
                .build_snapshot
                .as_ref()
                .is_some_and(|snapshot| snapshot.live_worker)
                != live.is_some()
        {
            return Err(("invalid_spec", "invalid build bundle authority"));
        }
        let argv = spec.argv.iter().map(String::as_str).collect::<Vec<_>>();
        let benchmark = self.benchmark_digest.as_ref() == Some(&spec.image_digest);
        let mode = match argv.as_slice() {
            _ if self.oci
                && (spec.network == "none" || spec.network_alias.is_some())
                && !prepared =>
            {
                "native-oci"
            }
            _ if self.oci => {
                return Err((
                    "unsupported_option",
                    "OCI requires a fresh constrained launch with no network or a private DNS alias",
                ));
            }
            _ if spec.docker_resource_defaults => {
                return Err((
                    "unsupported_option",
                    "Docker resource defaults require an OCI boot",
                ));
            }
            ["/bin/probe"]
                if self.native
                    && spec.network == "none"
                    && spec.limits == crate::spec::NATIVE_LIMITS =>
            {
                "native"
            }
            _ if self.native => {
                return Err((
                    "unsupported_option",
                    "native launch requires the fixed, no-network static executable profile",
                ));
            }
            ["/bin/probe"] if benchmark => "benchmark",
            ["/bin/probe", "--verify-workload-fixture"] => "once",
            ["/bin/probe", "--verify-workload-fixture", "--hold"] => "hold",
            ["/bin/probe", "--verify-workload-fixture", "--memory-canary"] => "memory-canary",
            ["/bin/probe", "--verify-workload-fixture", "--fail"] => "fail",
            ["/bin/probe", "--verify-workload-fixture", extra] if self.allow_crash => extra
                .strip_prefix("--")
                .filter(|mode| crate::kernel_fixture::test_mode(mode))
                .ok_or(("unsupported_option", "unknown fixture test option"))?,
            _ => {
                return Err((
                    "unsupported_option",
                    "request does not match the pinned ARM64 fixture",
                ));
            }
        };
        if !self.oci && (spec.cwd != "/work" || !spec.env.is_empty()) {
            return Err((
                "unsupported_option",
                "request does not match the pinned ARM64 executable profile",
            ));
        }
        let scope = spec.bridge_scope();
        let bridge = scope.is_some();
        if prepared
            && (bridge
                || spec.limits.memory_bytes > SLOT_MEMORY_LIMIT
                || !matches!(mode, "once" | "memory-canary" | "benchmark" | "native"))
        {
            return Err((
                "unsupported_option",
                "preparation requires no network and at most 32 MiB",
            ));
        }
        if bridge && !self.oci && (!self.bridge_available || scope == Some(BridgeScope::BuiltIn)) {
            return Err((
                "unsupported_option",
                "private bridge unavailable in this guest",
            ));
        }
        if bridge
            && !self.oci
            && !matches!(
                mode,
                "once"
                    | "hold"
                    | "benchmark"
                    | "pause-cleanup"
                    | "fault-bridge"
                    | "fault-bridge-child"
                    | "fault-cleanup"
            )
        {
            return Err(("unsupported_option", "unsupported bridge workload option"));
        }
        let request = ready.request();
        let mut hash = Sha256::new();
        hash.update([u8::from(prepared)]);
        hash.update(serde_json::to_vec(request).expect("typed request"));
        let body: [u8; 32] = hash.finalize().into();
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        if let Some(volume) = &spec.volume {
            if !self.oci || !crate::volume_disk::guest::available() {
                return Err(("unsupported_option", "native volume disk is not configured"));
            }
            let info = crate::volume_disk::guest::inspect(&volume.name)
                .map_err(|_| ("not_found", "native volume is unavailable"))?;
            if info.inode != volume.inode {
                return Err(("stale_generation", "native volume inode changed"));
            }
        }
        if let Some(bind) = &spec.bind {
            crate::bind_mount::source(&bind.lease)
                .map_err(|_| ("not_found", "native bind lease is unavailable"))?;
        }
        if mode != "benchmark"
            && spec.image_digest != self.image_digest
            && !(self.oci && ledger.images.contains(&spec.image_digest))
        {
            return Err(("unsupported_option", "requested OCI image is not installed"));
        }
        if let Some(record) = ledger
            .records
            .iter()
            .find(|record| record.sequence == request.sequence)
        {
            if record.body != body {
                return Err(("id_conflict", "sequence has a different admitted request"));
            }
            return Ok((Kind::State, record.state()));
        }
        if spec.bind.as_ref().is_some_and(|bind| {
            ledger
                .active()
                .any(|record| record.bind_lease.as_deref() == Some(bind.lease.as_str()))
        }) {
            return Err(("busy", "native bind lease already owns a workload"));
        }
        if let Some(snapshot) = &spec.build_snapshot {
            if !self.oci || !self.core_admission {
                return Err((
                    "unsupported_option",
                    "native build snapshot requires Core admission",
                ));
            }
            if let Some(live) = &live {
                if !ledger.record(&live.owner).is_some_and(|worker| {
                    worker.buildkit_worker
                        && worker.phase == Phase::Running
                        && !worker.cancelled
                        && !worker.terminate_requested
                        && worker.volume.as_ref().is_some_and(|volume| {
                            volume.name == live.volume.name && volume.inode == live.volume.inode
                        })
                }) {
                    return Err((
                        "stale_generation",
                        "BuildKit cache lease ended before RUN admission",
                    ));
                }
            } else {
                let current = crate::build_snapshot::guest::inspect(&snapshot.id)
                    .map_err(|_| ("not_found", "native build snapshot is unavailable"))?;
                if !current.same_mount(snapshot) {
                    return Err(("stale_generation", "native build snapshot identity changed"));
                }
                if snapshot.bundle_policy {
                    let bundle =
                        crate::build_snapshot::guest::load_bundle(&snapshot.id, &spec.image_digest)
                            .map_err(|error| ("unsupported_option", error))?;
                    if spec_digest(&bundle.spec) != spec_digest(spec) {
                        return Err((
                            "spec_mismatch",
                            "native build request differs from the verified bundle",
                        ));
                    }
                }
            }
            if ledger.active().any(|record| {
                record.build_snapshot.as_ref().is_some_and(|owned| {
                    owned.device == snapshot.device && owned.inode == snapshot.inode
                })
            }) {
                return Err(("busy", "native build snapshot already has an owner"));
            }
        }
        let capacity = if self.oci { OCI_CONCURRENCY } else { 1 };
        if ledger.active().count() >= capacity
            || ledger
                .active()
                .any(|record| record.phase == Phase::CleanupFailed)
        {
            return Err(("busy", "native workload capacity is occupied or unresolved"));
        }
        if ledger.closing {
            return Err(("busy", "fresh fixture is draining"));
        }
        if spec.buildkit_worker && ledger.active().any(|record| record.buildkit_worker) {
            return Err(("busy", "native BuildKit worker already owns the workspace"));
        }
        let network_aliases: Vec<_> = spec.aliases().cloned().collect();
        if !network_aliases.is_empty()
            && (!self.oci
                || ledger.active().any(|record| {
                    record.network_scope == scope
                        && crate::spec::network_aliases_conflict(
                            &record.network_aliases,
                            record.network_alias_project.as_deref(),
                            &network_aliases,
                            spec.network_alias_project.as_deref(),
                        )
                }))
        {
            return Err(("unsupported_option", "private network alias is unavailable"));
        }
        if prepared
            && (ledger.pressure
                || crate::memory::pressures_reserve(crate::memory::available_bytes()))
        {
            return Err((
                "memory_pressure",
                "prepared admission paused under pressure",
            ));
        }
        if !build && request.sequence <= ledger.highest_sequence {
            return Err((
                "stale_sequence",
                "sequence was previously admitted or superseded",
            ));
        }
        let resolved = spec
            .account
            .as_ref()
            .map(|account| {
                let (uid, gid) = crate::image_account::resolve_image(&spec.image_digest, account)?;
                let mut runtime = spec.clone();
                runtime.uid = uid;
                runtime.gid = gid;
                runtime.account = None;
                Ok::<_, io::Error>(runtime)
            })
            .transpose()
            .map_err(|_| {
                (
                    "unsupported_option",
                    "unknown or unmapped OCI image account",
                )
            })?;
        let spec = resolved.as_ref().unwrap_or(spec);
        if deadline <= Instant::now() {
            return Err((
                "deadline_exceeded",
                "launch deadline expired before admission",
            ));
        }
        let id: [u8; 16] = random().map_err(|_| ("busy", "secure workload ID unavailable"))?;
        if let Some(volume) = &spec.volume {
            crate::volume_disk::guest::initialize_mount(volume, spec.uid == 0 && spec.gid == 0)
                .map_err(|_| {
                    (
                        "storage_failed",
                        "cannot initialize native volume ownership",
                    )
                })?;
        }
        let record = Record {
            handle: Handle {
                boot_id: boot.into(),
                workload_id: hex(&id),
            },
            sequence: request.sequence,
            body,
            image_digest: spec.image_digest.clone(),
            exec_context: None,
            phase: Phase::Accepted,
            revision: 1,
            exec: "pending",
            exit: None,
            helper_failed: false,
            network_cleanup: if bridge { "pending" } else { "not_applicable" },
            network_scope: scope,
            network_aliases,
            network_alias_project: spec.network_alias_project.clone(),
            network_address: None,
            trace: ((benchmark && self.trace_benchmark) || self.trace_core_latency).then(|| {
                Trace {
                    admitted: Instant::now(),
                    events: BTreeMap::new(),
                    core: self.trace_core_latency,
                }
            }),
            slot: prepared.then(|| Slot::new(spec_digest(spec))),
            slot_expires: prepared.then(|| Instant::now() + SLOT_TTL),
            slot_expired: false,
            memory_limit_bytes: spec.limits.memory_bytes,
            volume: spec
                .volume
                .clone()
                .or_else(|| live.as_ref().map(|build| build.volume.clone())),
            bind_lease: spec.bind.as_ref().map(|bind| bind.lease.clone()),
            build_snapshot: spec.build_snapshot.clone(),
            build_runtime_owned: build,
            build_parent: live.as_ref().map(|build| build.owner.clone()),
            buildkit_worker: spec.buildkit_worker,
            buildkit_registry: spec.buildkit_registry(),
            core_admission_deadline: self.core_admission.then_some(deadline),
            cancelled: false,
            terminate_requested: false,
            control: None,
            input: None,
            stdout: Capture::default(),
            stderr: Capture::default(),
        };
        let reply = record.state();
        if !build {
            ledger.highest_sequence = request.sequence;
        }
        if !self.oci {
            ledger.records.clear();
        } else if ledger.records.len() >= OCI_RECORDS {
            let index = ledger
                .records
                .iter()
                .position(|record| record.phase == Phase::Removed && !record.build_runtime_owned)
                .expect("bounded OCI history contains a terminal record");
            ledger.records.remove(index);
        }
        ledger.records.push_back(record);
        let owner = Arc::clone(self);
        let limits = spec.limits;
        let mode = mode.to_owned();
        let oci_process = self.oci.then(|| HelperLaunch {
            spec: serde_json::to_string(spec).expect("validated OCI spec"),
            open_stdin: spec.open_stdin,
            build_owner: if spec.buildkit_worker {
                Some(hex(&id))
            } else {
                live.as_ref().map(|build| build.owner.clone())
            },
            live_mounts: live.map(|build| build.mounts),
        });
        if thread::Builder::new()
            .name("fresh-workload".into())
            .spawn(move || owner.run_workload(id, limits, &mode, bridge, prepared, oci_process))
            .is_err()
        {
            let record = ledger.records.back_mut().expect("reserved record");
            record.exec = "failed";
            if bridge {
                record.network_cleanup = "complete";
            }
            record.change(Phase::Removed);
            return Ok((Kind::State, record.state()));
        }
        if ledger.core_watcher {
            self.changed.notify_all();
        }
        Ok((Kind::State, reply))
    }

    fn run_workload(
        self: &Arc<Self>,
        id: [u8; 16],
        limits: crate::spec::ResourceLimits,
        mode: &str,
        bridge: bool,
        prepared: bool,
        oci_process: Option<HelperLaunch>,
    ) {
        let workload = hex(&id);
        let is_oci = oci_process.is_some();
        let build_owner = oci_process
            .as_ref()
            .and_then(|launch| launch.build_owner.clone());
        let is_worker = {
            let mut ledger = self.ledger.lock().expect("fresh ledger");
            loop {
                let record = ledger.record_mut(&workload).expect("admitted workload");
                let now = Instant::now();
                let expired = record
                    .core_admission_deadline
                    .is_some_and(|deadline| now >= deadline);
                if record.cancelled
                    || (self.core_admission && (expired || record.terminate_requested))
                {
                    record.exec = "failed";
                    if bridge {
                        record.network_cleanup = "complete";
                    }
                    record.change(Phase::Removed);
                    self.changed.notify_all();
                    return;
                }
                let Some(deadline) = record.core_admission_deadline else {
                    break record.buildkit_worker;
                };
                ledger = self
                    .changed
                    .wait_timeout(ledger, deadline - now)
                    .expect("fresh ledger")
                    .0;
            }
        };
        let scoped;
        let intent = if is_oci {
            scoped = self.intent.scoped(id);
            &scoped
        } else {
            &self.intent
        };
        let mut intent_recorded = None;
        let mut output_drained = None;
        let mut intent_completed = None;
        let trace_stamp = || self.trace_core_latency.then(Instant::now);
        let result = intent.record(id).and_then(|()| {
            intent_recorded = trace_stamp();
            let aggregate = is_worker
                .then(|| {
                    let launch = oci_process
                        .as_ref()
                        .expect("BuildKit worker has an OCI spec");
                    let spec: LaunchSpec = serde_json::from_str(&launch.spec)?;
                    crate::kernel_fixture::BuildAggregate::open(
                        id,
                        limits,
                        spec.memory_swap_disabled,
                    )
                })
                .transpose()?;
            let output = self.run_helper(id, limits, mode, bridge, prepared, oci_process);
            if let Some(aggregate) = aggregate {
                self.drain_worker_builds(&workload)?;
                aggregate.close()?;
            }
            let output = output?;
            output_drained = trace_stamp();
            if is_oci {
                crate::kernel_fixture::assert_owned_cgroup_absent(id)?;
                if let Some(owner) = &build_owner
                    && crate::kernel_fixture::build_cgroup_path(owner)
                        .join(&workload)
                        .try_exists()?
                {
                    return Err(io::Error::other("BuildKit cgroup child remains"));
                }
                crate::sandbox_fixture::assert_owned_absent(id)?;
            }
            intent.complete(id)?;
            intent_completed = trace_stamp();
            Ok(output)
        });
        if let Err(error) = &result {
            eprintln!("fresh fixture did not confirm cleanup: {error}");
        }
        self.update(&workload, |record| {
            record.mark_at("intent_recorded", intent_recorded);
            record.mark_at("helper_reaped_output_drained", output_drained);
            record.mark_at("intent_completed", intent_completed);
            record.control = None;
            record.exec_context = None;
            record.input = None;
            record.network_address = None;
            if let Some(slot) = &mut record.slot {
                slot.discard();
            }
            if let Ok(recovered) = result {
                record.helper_failed = recovered;
                if bridge {
                    record.network_cleanup = "complete";
                }
                if record.exec == "pending" {
                    record.exec = if recovered { "indeterminate" } else { "failed" };
                }
                record.change(Phase::Removed);
            } else {
                record.helper_failed = true;
                if bridge && record.network_cleanup == "pending" {
                    record.network_cleanup = "failed";
                }
                if record.exec == "pending" {
                    record.exec = "indeterminate";
                }
                record.change(Phase::CleanupFailed);
            }
        });
    }

    fn drain_worker_builds(&self, owner: &str) -> io::Result<()> {
        let mut registry = self.build_registry.lock().expect("build registry");
        if registry
            .as_ref()
            .is_some_and(|registry| registry.owner == owner)
        {
            *registry = None;
        }
        drop(registry);
        let deadline = Instant::now() + Duration::from_secs(32);
        {
            let mut ledger = self.ledger.lock().expect("fresh ledger");
            if let Some(worker) = ledger.record_mut(owner) {
                worker.terminate_requested = true;
            }
            loop {
                let mut pending = false;
                for child in ledger
                    .records
                    .iter_mut()
                    .filter(|record| record.build_parent.as_deref() == Some(owner))
                {
                    if child.phase == Phase::CleanupFailed {
                        return Err(io::Error::other("worker RUN cleanup failed"));
                    }
                    if child.phase != Phase::Removed {
                        child.cancel();
                        pending = true;
                    }
                }
                if !pending {
                    break;
                }
                self.changed.notify_all();
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(io::Error::other("worker RUN cleanup deadline elapsed"));
                }
                ledger = self
                    .changed
                    .wait_timeout(ledger, remaining)
                    .expect("fresh ledger")
                    .0;
            }
        }
        let mut runtime = self.build_runtime.lock().expect("build runtime");
        if runtime
            .active
            .as_ref()
            .is_some_and(|build| build.owner.as_deref() == Some(owner))
        {
            let mut ledger = self.ledger.lock().expect("fresh ledger");
            let active = runtime.active.as_ref().expect("checked worker build");
            let record = ledger
                .record_mut(&active.handle.workload_id)
                .filter(|record| record.phase == Phase::Removed && record.handle == active.handle)
                .ok_or_else(|| io::Error::other("missing terminal worker RUN ownership"))?;
            record.build_runtime_owned = false;
            let active = runtime.active.take().expect("checked worker build");
            runtime.deleted.push((active.owner, active.id));
        }
        Ok(())
    }

    fn run_helper(
        self: &Arc<Self>,
        id: [u8; 16],
        limits: crate::spec::ResourceLimits,
        mode: &str,
        bridge: bool,
        prepared: bool,
        mut oci_process: Option<HelperLaunch>,
    ) -> io::Result<bool> {
        const TRANSITION_TIMEOUT: Duration = Duration::from_secs(32);
        let (mut peer, helper) = UnixStream::pair()?;
        peer.set_read_timeout(Some(TRANSITION_TIMEOUT))?;
        let owner = peer.try_clone()?;
        let workload = hex(&id);
        let mut command = Command::new("/init");
        let (input_reader, input_writer) = if oci_process.as_ref().is_some_and(|oci| oci.open_stdin)
        {
            let (reader, writer) = crate::workload_input::pipe()?;
            (Some(reader), Some(writer))
        } else {
            (None, None)
        };
        let input_fd = input_reader.as_ref().map(AsRawFd::as_raw_fd);
        let build_fds = oci_process
            .as_ref()
            .and_then(|oci| oci.live_mounts.as_ref())
            .map(LiveMounts::descriptors);
        if oci_process.is_some() {
            command.process_group(0);
            let owner_pid = std::process::id() as libc::pid_t;
            // Stop this task-owned helper if its supervisor dies before it
            // records cleanup. It never runs outside the disposable guest.
            unsafe {
                command.pre_exec(move || {
                    crate::security::checked(libc::prctl(
                        libc::PR_SET_PDEATHSIG,
                        libc::SIGKILL,
                        0,
                        0,
                        0,
                    ))?;
                    if libc::getppid() != owner_pid {
                        return Err(io::Error::from_raw_os_error(libc::ECHILD));
                    }
                    if let Some(fd) = input_fd {
                        crate::security::checked(libc::fcntl(fd, libc::F_SETFD, 0))?;
                    }
                    for fd in build_fds.into_iter().flatten() {
                        crate::security::checked(libc::fcntl(fd, libc::F_SETFD, 0))?;
                    }
                    Ok(())
                });
            }
        }
        command.env_clear();
        if let Some(fd) = input_fd {
            command.env(crate::workload_input::FD_ENV, fd.to_string());
        }
        if let Some(fds) = build_fds {
            command.env(
                crate::build_snapshot::mounts::LIVE_FDS,
                fds.map(|fd| fd.to_string()).join(","),
            );
        }
        let build_owner = oci_process
            .as_ref()
            .and_then(|launch| launch.build_owner.as_deref());
        if let Some(owner) = build_owner {
            command.env(crate::kernel_fixture::BUILD_CGROUP_OWNER, owner);
        }
        let mut child = command
            .args([
                "--run-fresh-fixture",
                &std::process::id().to_string(),
                &hex(&id),
                &limits.memory_bytes.to_string(),
                &limits.pids.to_string(),
                &limits.cpu_millicores.to_string(),
                if mode == "crash-supervisor" {
                    "hold"
                } else {
                    mode
                },
                if bridge { "bridge" } else { "none" },
                if prepared { "prepared" } else { "fresh" },
            ])
            .args(oci_process.as_ref().map(|oci| &oci.spec))
            .stdin(Stdio::from(OwnedFd::from(helper)))
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        // The command retains its configured stdin. Close the helper-side
        // control descriptor here so an early helper exit yields EOF.
        drop(command);
        drop(input_reader);
        drop(oci_process.as_mut().and_then(|oci| oci.live_mounts.take()));
        let helper_spawned = self.trace_core_latency.then(Instant::now);
        let process_group = -(child.id() as libc::pid_t);
        let out = child.stdout.take().expect("piped stdout");
        let err = child.stderr.take().expect("piped stderr");
        let output_owner = Arc::clone(self);
        let output_id = workload.clone();
        let stdout = thread::spawn(move || {
            drain(out, |data| {
                output_owner.update(&output_id, |record| {
                    let capacity = crate::spec::workload_output_limit(&record.image_digest);
                    record.stdout.append_bounded(data, capacity);
                });
            })
        });
        let error_owner = Arc::clone(self);
        let error_id = workload.clone();
        let stderr = thread::spawn(move || {
            drain(err, |data| {
                error_owner.update(&error_id, |record| {
                    let capacity = crate::spec::workload_output_limit(&record.image_digest);
                    record.stderr.append_bounded(data, capacity);
                });
            })
        });
        self.update(&workload, |record| {
            record.mark_at("helper_spawned", helper_spawned);
            record.control = Some(owner);
            record.input = input_writer;
            if record.cancelled {
                let _ = record.control.as_mut().unwrap().write_all(&[CANCEL]);
            } else if record.terminate_requested {
                let _ = record.control.as_mut().unwrap().write_all(&[TERMINATE]);
            }
        });
        let mut removed = false;
        let mut exit_received = false;
        let mut oom_killed = false;
        let mut network_removed = !bridge;
        let result = (|| -> io::Result<()> {
            while let Some((event, mut descriptors)) =
                crate::exec_fixture::receive_event(peer.as_raw_fd())?
            {
                match event {
                    b'P' => self.update(&workload, |record| {
                        if !record.cancelled {
                            record.change(Phase::Preparing);
                        }
                    }),
                    b'C' => self.update(&workload, |record| {
                        if !record.cancelled {
                            record.change(Phase::ChildCreated);
                        }
                    }),
                    b'Q' if prepared => self.update(&workload, |record| {
                        if !record.cancelled
                            && let (Some(slot), Some(expires)) =
                                (&mut record.slot, record.slot_expires)
                        {
                            slot.ready(expires);
                            record.change(Phase::PreparedReady);
                        }
                    }),
                    b'T' if prepared => self.update(&workload, |record| {
                        record.slot_expired = true;
                        record.slot.as_mut().expect("prepared record").discard();
                        record.change(Phase::Exiting);
                    }),
                    b'M' if prepared => {
                        let mut ledger = self.ledger.lock().expect("fresh ledger");
                        let record = ledger.record_mut(&workload).expect("prepared record");
                        if !record.cancelled {
                            record.cancelled = true;
                            let slot = record.slot.as_mut().expect("prepared slot");
                            slot.discard();
                            record.change(Phase::Exiting);
                            ledger.evictions = ledger.evictions.saturating_add(1);
                            self.changed.notify_all();
                        }
                    }
                    b'V' if bridge && oci_process.is_some() => {
                        let mut response =
                            UnixStream::from(descriptors.pop().expect("bridge response"));
                        let target = fs::File::from(descriptors.pop().expect("bridge target"));
                        let (scope, aliases, project, buildkit_registry) = {
                            let ledger = self.ledger.lock().expect("fresh ledger");
                            let record = ledger.record(&workload).expect("owned workload");
                            (
                                record.network_scope.expect("leased bridge scope"),
                                record.network_aliases.clone(),
                                record.network_alias_project.clone(),
                                record.buildkit_registry,
                            )
                        };
                        let mut networks = self.private_networks.lock().expect("private bridges");
                        let private = &mut networks[scope.subnet() as usize];
                        if private.is_none() {
                            *private = Some(crate::bridge_fixture::NetworkOwner::new(scope)?);
                        }
                        let private = private.as_mut().expect("private bridge");
                        let listener = buildkit_registry
                            .then(|| private.build_registry_listener())
                            .transpose()?;
                        let address = private.attach(id, target, &aliases, project.as_deref())?;
                        if let Some(listener) = listener {
                            *self.build_registry.lock().expect("build registry") =
                                Some(BuildRegistry {
                                    owner: workload.clone(),
                                    address,
                                    listener,
                                });
                        }
                        self.update(&workload, |record| {
                            record.network_address = Some(address);
                            record.revision += 1;
                        });
                        response.write_all(&[1])?;
                    }
                    b'E' => {
                        if mode == "crash-supervisor" {
                            // Only the explicit disposable-guest recovery mode can
                            // request this self-signal after the confirmed exec.
                            let result = unsafe { libc::kill(libc::getpid(), libc::SIGKILL) };
                            return Err(if result == 0 {
                                io::Error::other("supervisor crash signal returned")
                            } else {
                                io::Error::last_os_error()
                            });
                        }
                        if oci_process.is_some() {
                            peer.set_read_timeout(None)?;
                        }
                        self.update(&workload, |record| {
                            if let (Some(oci), Some(target)) =
                                (oci_process.as_ref(), descriptors.pop())
                                && let Ok(spec) = serde_json::from_str(&oci.spec)
                            {
                                record.exec_context = Some((spec, target));
                            }
                            record.exec = "confirmed";
                            record.mark("exec_confirmed");
                            if !record.cancelled {
                                record.change(Phase::Running);
                            }
                        });
                    }
                    b'O' if !exit_received && !oom_killed && oci_process.is_some() => {
                        oom_killed = true
                    }
                    b'X' => {
                        peer.set_read_timeout(Some(TRANSITION_TIMEOUT))?;
                        let mut status = [0; 4];
                        peer.read_exact(&mut status)?;
                        let status = i32::from_le_bytes(status);
                        if exit_received {
                            return Err(io::Error::other("duplicate fixture exit record"));
                        }
                        exit_received = true;
                        self.update(&workload, |record| {
                            record.exit = if libc::WIFEXITED(status) {
                                Some(json!({"code": libc::WEXITSTATUS(status)}))
                            } else if libc::WIFSIGNALED(status) {
                                let signal = libc::WTERMSIG(status);
                                Some(if signal == libc::SIGKILL && oom_killed {
                                    json!({"signal":signal,"oom_killed":true})
                                } else {
                                    json!({"signal":signal})
                                })
                            } else {
                                None
                            };
                            record.change(Phase::Cleaning);
                        });
                    }
                    b'N' if !exit_received => {
                        peer.set_read_timeout(Some(TRANSITION_TIMEOUT))?;
                        exit_received = true;
                        self.update(&workload, |record| record.change(Phase::Cleaning));
                    }
                    b'R' if exit_received && bridge && oci_process.is_some() => {
                        self.release_private_network(id)?;
                        removed = true;
                        break;
                    }
                    b'B' if exit_received && !network_removed => {
                        network_removed = true;
                        self.update(&workload, |record| {
                            record.network_cleanup = "complete";
                            record.revision += 1;
                            record.mark("network_removed");
                        });
                    }
                    b'R' if exit_received && network_removed => {
                        removed = true;
                        break;
                    }
                    _ => return Err(io::Error::other("invalid fixture helper state")),
                }
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = peer.shutdown(std::net::Shutdown::Both);
            self.update(&workload, |record| record.control = None);
            child.kill()?;
        }
        let finished = child.wait()?;
        let recovered = result.is_err() || !finished.success() || !removed;
        if recovered {
            if let Some(owner) = oci_process
                .as_ref()
                .and_then(|launch| launch.build_owner.as_deref())
            {
                crate::kernel_fixture::recover_build_child(owner, &workload)?;
            } else {
                crate::kernel_fixture::recover_cgroup(id, oci_process.is_some())?;
            }
            crate::recovery_fixture::reap_owned_children(if oci_process.is_some() {
                process_group
            } else {
                -1
            })?;
            crate::sandbox_fixture::recover(id, oci_process.is_some())?;
            if bridge && oci_process.is_some() {
                self.release_private_network(id)?;
            }
            println!("conjet-launchd recovered helper failure for {}", hex(&id));
        }
        let stdout = stdout.join();
        let stderr = stderr.join();
        stdout.map_err(|_| io::Error::other("stdout reader failed"))??;
        stderr.map_err(|_| io::Error::other("stderr reader failed"))??;
        Ok(recovered)
    }

    fn release_private_network(&self, id: [u8; 16]) -> io::Result<()> {
        for network in self
            .private_networks
            .lock()
            .expect("private bridges")
            .iter_mut()
            .flatten()
        {
            network.detach(id)?;
        }
        Ok(())
    }

    fn network(&self, operation: NetworkOperation, boot: &str, deadline: Instant) -> Reply {
        let mut networks = self.private_networks.lock().expect("private bridges");
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        if ledger.closing || deadline <= Instant::now() {
            return Err(("busy", "private bridge is draining"));
        }
        let (handle, requested) = match operation {
            NetworkOperation::Remove => {
                if ledger.active().any(|record| {
                    record
                        .network_scope
                        .as_ref()
                        .is_some_and(|scope| scope.subnet() == 0)
                        && !record.network_aliases.is_empty()
                }) {
                    return Err(("busy", "private bridge still owns workloads"));
                }
                if let Some(owned) = networks[BridgeScope::Custom.subnet() as usize].take() {
                    owned
                        .close()
                        .map_err(|_| ("cleanup_failed", "cannot verify bridge removal"))?;
                }
                return Ok((Kind::Network, json!({"removed":true})));
            }
            NetworkOperation::Connect {
                handle,
                alias,
                scope,
            } => {
                let scope = scope.unwrap_or(BridgeScope::Custom);
                if !crate::bridge_dns::valid_name(&alias) {
                    return Err(("unsupported_option", "invalid private network alias"));
                }
                if ledger.active().any(|record| {
                    record.network_scope == Some(scope)
                        && record
                            .network_aliases
                            .iter()
                            .any(|name| name.eq_ignore_ascii_case(&alias))
                }) {
                    return Err(("busy", "private network alias is already owned"));
                }
                (handle, Some((scope, alias)))
            }
            NetworkOperation::Disconnect { handle } => (handle, None),
        };
        if handle.boot_id != boot {
            return Err(("stale_generation", "unexpected native workload boot ID"));
        }
        let record = ledger
            .record_mut(&handle.workload_id)
            .filter(|record| record.handle == handle && record.phase == Phase::Running)
            .ok_or((
                "not_running",
                "native network requires the current running workload",
            ))?;
        let (_, pidfd) = record.exec_context.as_ref().ok_or((
            "unsupported_option",
            "workload was not admitted with bridge permissions",
        ))?;
        let scope = record.network_scope.ok_or((
            "unsupported_option",
            "workload was not admitted with bridge permissions",
        ))?;
        let network = &mut networks[scope.subnet() as usize];
        let id = crate::handshake::unhex::<16>(&handle.workload_id)
            .map_err(|_| ("malformed", "invalid workload ID"))?;
        if let Some((desired_scope, alias)) = requested {
            if desired_scope != scope {
                return Err((
                    "unsupported_option",
                    "cannot change a running workload's bridge scope",
                ));
            }
            if record.network_address.is_some() {
                return Err(("busy", "workload already owns a bridge port"));
            }
            let target = crate::exec_fixture::target_network(pidfd)
                .map_err(|_| ("not_running", "cannot retain its live network namespace"))?;
            if network.is_none() {
                *network = Some(
                    crate::bridge_fixture::NetworkOwner::new(scope)
                        .map_err(|_| ("network_failed", "cannot create the private bridge"))?,
                );
            }
            let address = network
                .as_mut()
                .expect("private bridge")
                .attach(id, target, std::slice::from_ref(&alias), None)
                .map_err(|_| ("network_failed", "private bridge peer attachment failed"))?;
            record.network_address = Some(address);
            record.network_aliases = vec![alias];
            record.network_alias_project = None;
        } else {
            if record.network_address.is_none() {
                return Err(("not_found", "workload has no bridge port"));
            }
            network
                .as_mut()
                .ok_or(("cleanup_failed", "private bridge was not allocated"))?
                .detach(id)
                .map_err(|_| ("cleanup_failed", "cannot verify peer removal"))?;
            record.network_address = None;
            record.network_aliases.clear();
            record.network_alias_project = None;
        }
        record.revision += 1;
        let response = json!({"network_address":record.network_address});
        self.changed.notify_all();
        Ok((Kind::Network, response))
    }

    pub(crate) fn dial(&self, frame: &Frame, boot: &str) -> Result<std::net::TcpStream, Failure> {
        let arrival = Instant::now();
        let request: Dial = frame
            .decode()
            .map_err(|_| ("malformed", "invalid native TCP target"))?;
        if !(1..=500).contains(&request.budget_ms) || request.port == 0 {
            return Err(("malformed", "native TCP port or connect budget is invalid"));
        }
        if request.handle.boot_id != boot {
            return Err(("stale_generation", "unexpected native workload boot ID"));
        }
        // Acquire bridge ownership before observing the workload, the same
        // order used by peer admission and live network operations.
        let networks = self.private_networks.lock().expect("private bridges");
        let ledger = self.ledger.lock().expect("fresh ledger");
        let scope = ledger
            .record(&request.handle.workload_id)
            .filter(|record| {
                record.handle == request.handle
                    && record.phase == Phase::Running
                    && record.network_address.is_some()
                    && !ledger.closing
            })
            .and_then(|record| record.network_scope)
            .ok_or((
                "not_running",
                "native TCP target has no active bridge lease",
            ))?;
        drop(ledger);
        let budget = Duration::from_millis(request.budget_ms).saturating_sub(arrival.elapsed());
        if budget.is_zero() {
            return Err(("deadline_exceeded", "native TCP connect budget expired"));
        }
        let id = crate::handshake::unhex::<16>(&request.handle.workload_id)
            .map_err(|_| ("malformed", "invalid native workload ID"))?;
        networks[scope.subnet() as usize]
            .as_ref()
            .ok_or(("not_running", "private bridge is absent"))?
            .dial(id, request.port, budget)
            .map_err(|error| match error.kind() {
                io::ErrorKind::ConnectionRefused => {
                    ("connection_refused", "native TCP target refused connection")
                }
                io::ErrorKind::TimedOut => {
                    ("deadline_exceeded", "native TCP connect budget expired")
                }
                _ => (
                    "connection_failed",
                    "native TCP target could not be reached",
                ),
            })
    }

    pub(crate) fn serve_exec_stream(
        &self,
        frame: &Frame,
        boot: &str,
        stream: &mut Stream,
    ) -> Result<(), WireError> {
        let opened = (|| -> Result<_, Failure> {
            let request: ExecStream = frame
                .decode()
                .map_err(|_| ("malformed", "invalid exec stream payload"))?;
            if request.handle.boot_id != boot {
                return Err(("stale_generation", "unexpected native exec boot ID"));
            }
            if !(1..=crate::wire::BUILDKIT_EXEC_BUDGET_MS).contains(&request.budget_ms) {
                return Err(("malformed", "invalid exec stream budget"));
            }
            let mut ledger = self.ledger.lock().expect("fresh ledger");
            if ledger.closing || ledger.exec_streams >= 2 {
                return Err(("busy", "native exec stream slots are occupied"));
            }
            let target = ledger.exec_target(&request.handle, request.argv)?;
            if request.budget_ms > crate::wire::EXEC_STREAM_BUDGET_MS
                && !crate::spec::buildkit_control_exec(&target.0.image_digest, &target.0.argv)
            {
                return Err((
                    "invalid_spec",
                    "long exec stream budgets require the pinned BuildKit control command",
                ));
            }
            ledger.exec_streams += 1;
            Ok((
                target,
                Instant::now() + Duration::from_millis(request.budget_ms),
            ))
        })();
        let ((spec, pidfd, id), deadline) = match opened {
            Ok(opened) => opened,
            Err((code, detail)) => return write_error(stream, frame.id, code, detail),
        };
        let result = (|| {
            Frame::write(
                &mut *stream,
                Kind::ExecStream,
                frame.id,
                &json!({"attached":true}),
            )?;
            Ok::<_, WireError>(crate::exec_fixture::execute_stream(
                pidfd, id, spec, stream, deadline,
            ))
        })();
        self.ledger.lock().expect("fresh ledger").exec_streams -= 1;
        self.changed.notify_all();
        stream.deadline(Some(Instant::now() + Duration::from_secs(2)));
        match result? {
            Ok(code) => crate::wire::write_exec_stream(stream, 4, &[code as u8])?,
            Err(error) => {
                eprintln!("native exec stream failed: {error}");
                let reason = if error.kind() == io::ErrorKind::TimedOut {
                    "native exec stream deadline exceeded"
                } else {
                    "native exec stream ended before completion"
                };
                crate::wire::write_exec_stream(&mut *stream, 3, reason.as_bytes())?;
                crate::wire::write_exec_stream(stream, 4, &[125])?;
            }
        }
        Ok(())
    }

    fn wait_for_archive_start<'a>(
        &self,
        ledger: MutexGuard<'a, Ledger>,
        handle: &Handle,
        expires: Instant,
    ) -> MutexGuard<'a, Ledger> {
        self.changed
            .wait_timeout_while(
                ledger,
                expires.saturating_duration_since(Instant::now()),
                |ledger| {
                    !ledger.closing
                        && ledger.record(&handle.workload_id).is_some_and(|record| {
                            record.handle == *handle
                                && !record.cancelled
                                && !record.terminate_requested
                                && matches!(
                                    record.phase,
                                    Phase::Accepted
                                        | Phase::Preparing
                                        | Phase::ChildCreated
                                        | Phase::Claimed
                                )
                        })
                },
            )
            .expect("fresh ledger")
            .0
    }

    pub(crate) fn serve_copy_download(
        &self,
        frame: &Frame,
        boot: &str,
        stream: &mut Stream,
    ) -> Result<(), WireError> {
        let open = || -> Result<_, Failure> {
            let request: CopyDownload = frame
                .decode()
                .map_err(|_| ("malformed", "invalid archive download payload"))?;
            if request.handle.boot_id != boot {
                return Err(("stale_generation", "unexpected native archive boot ID"));
            }
            if !(1..=30_000).contains(&request.budget_ms) {
                return Err(("malformed", "invalid archive download budget"));
            }
            let deadline = Instant::now() + Duration::from_millis(request.budget_ms);
            let download = crate::workload_copy::DownloadRequest {
                path: request.path,
                identity: request.identity,
            };
            let mut ledger = self.ledger.lock().expect("fresh ledger");
            if ledger.archive_downloads >= 2 {
                return Err(("busy", "native archive download slots are occupied"));
            }
            let (_, pidfd) = ledger.archive_target(&request.handle)?;
            let target = pidfd
                .try_clone()
                .map_err(|_| ("busy", "cannot retain native archive target"))?;
            let root = crate::exec_fixture::target_root(&target)
                .map_err(|_| ("not_running", "cannot retain native archive root"))?;
            let file = download.open(&root).map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    ("not_found", "native workload archive path was not found")
                } else {
                    (
                        "archive_rejected",
                        "native workload archive file is unsupported",
                    )
                }
            })?;
            ledger.archive_downloads += 1;
            Ok((request.handle, deadline, target, file, download))
        };
        let (handle, deadline, target, mut file, download) = match open() {
            Ok(opened) => opened,
            Err((code, detail)) => return write_error(stream, frame.id, code, detail),
        };
        let current = || {
            self.ledger
                .lock()
                .expect("fresh ledger")
                .archive_target(&handle)
                .map(|_| ())
        };
        let result = (|| {
            let idle_deadline = || deadline.min(Instant::now() + Duration::from_secs(2));
            stream.deadline(Some(idle_deadline()));
            Frame::write(
                &mut *stream,
                Kind::CopyDownload,
                frame.id,
                &json!({"size": download.size()}),
            )?;
            download.transfer(&mut file, |bytes| {
                current().map_err(|(_, detail)| io::Error::other(detail))?;
                stream.deadline(Some(idle_deadline()));
                stream.write_all(bytes)
            })?;
            stream.deadline(Some(idle_deadline()));
            if let Err((code, detail)) = current() {
                return write_error(stream, frame.id, code, detail);
            }
            let root = crate::exec_fixture::target_root(&target)?;
            if download.verify_path(&root).is_err() {
                return write_error(
                    stream,
                    frame.id,
                    "archive_rejected",
                    "native archive file changed",
                );
            }
            Frame::write(
                stream,
                Kind::CopyDownload,
                frame.id,
                &json!({"copied": download.size()}),
            )
        })();
        drop((file, target));
        self.ledger.lock().expect("fresh ledger").archive_downloads -= 1;
        self.changed.notify_all();
        result
    }

    pub(crate) fn serve_copy_upload(
        &self,
        frame: &Frame,
        boot: &str,
        stream: &mut Stream,
        connection: ConnectionId,
    ) -> Result<(), WireError> {
        let prepare = || -> Result<_, Failure> {
            let request: CopyUpload = frame
                .decode()
                .map_err(|_| ("malformed", "invalid archive upload payload"))?;
            if request.handle.boot_id != boot {
                return Err(("stale_generation", "unexpected native archive boot ID"));
            }
            if !(1..=30_000).contains(&request.budget_ms) {
                return Err(("malformed", "invalid archive upload budget"));
            }
            let started = Instant::now();
            let deadline = started + Duration::from_millis(request.budget_ms);
            let ready_by = deadline.min(started + Duration::from_secs(1));
            let ledger = self.ledger.lock().expect("fresh ledger");
            let mut ledger = self.wait_for_archive_start(ledger, &request.handle, ready_by);
            if Instant::now() >= ready_by {
                return Err(("deadline_exceeded", "native archive startup expired"));
            }
            let (spec, pidfd) = ledger.archive_target(&request.handle)?;
            let uid = spec.uid;
            let target = pidfd
                .try_clone()
                .map_err(|_| ("busy", "cannot retain native archive target"))?;
            let root = crate::exec_fixture::target_root(&target)
                .map_err(|_| ("not_running", "cannot retain native archive root"))?;
            let upload = ledger
                .copies
                .begin_stream(
                    &root,
                    request.archive,
                    connection,
                    &request.handle.workload_id,
                    uid,
                )
                .map_err(archive_failure)?;
            Ok((request.handle, deadline, target, upload))
        };
        let (handle, deadline, target, mut upload) = match prepare() {
            Ok(prepared) => prepared,
            Err((code, detail)) => return write_error(stream, frame.id, code, detail),
        };
        let result = (|| {
            let idle_deadline = || deadline.min(Instant::now() + Duration::from_secs(2));
            stream.deadline(Some(idle_deadline()));
            Frame::write(
                &mut *stream,
                Kind::CopyUpload,
                frame.id,
                &json!({"offset":0}),
            )?;
            upload.receive(|bytes| {
                self.ledger
                    .lock()
                    .expect("fresh ledger")
                    .archive_target(&handle)
                    .map_err(|(_, detail)| io::Error::other(detail))?;
                stream.deadline(Some(idle_deadline()));
                stream.read_exact(bytes)
            })?;
            stream.deadline(Some(idle_deadline()));
            let commit: Value = Frame::read(&mut *stream)?.expect(Kind::CopyUpload, frame.id)?;
            if commit != json!({"commit":true}) {
                return write_error(stream, frame.id, "malformed", "invalid archive commit");
            }
            let committed = (|| {
                let ledger = self.ledger.lock().expect("fresh ledger");
                ledger.archive_target(&handle)?;
                if Instant::now() >= deadline {
                    return Err(("deadline_exceeded", "native archive upload expired"));
                }
                let root = crate::exec_fixture::target_root(&target)
                    .map_err(|_| ("not_running", "cannot retain native archive root"))?;
                upload.commit(&root).map_err(archive_failure)
            })();
            match committed {
                Ok(reply) => Frame::write(stream, Kind::CopyUpload, frame.id, &reply),
                Err((code, detail)) => write_error(stream, frame.id, code, detail),
            }
        })();
        drop(target);
        self.ledger
            .lock()
            .expect("fresh ledger")
            .copies
            .finish_stream();
        self.changed.notify_all();
        result
    }

    fn operation(self: &Arc<Self>, frame: &Frame, boot: &str, connection: ConnectionId) -> Reply {
        fn parse<T: serde::de::DeserializeOwned>(frame: &Frame) -> Result<T, Failure> {
            frame
                .decode()
                .map_err(|_| ("malformed", "invalid request payload"))
        }
        let arrival = Instant::now();
        let deadline = |ms| {
            if (1..=30_000).contains(&ms) {
                Ok(arrival + Duration::from_millis(ms))
            } else {
                Err(("malformed", "invalid budget"))
            }
        };
        let mut guard = self.ledger.lock().expect("fresh ledger");
        if guard
            .exec_output
            .as_ref()
            .is_some_and(|output| arrival >= output.expires)
        {
            guard.exec_output = None;
        }
        let check = |ledger: &Ledger, handle: &Handle| {
            if handle.boot_id != boot {
                return Err(("stale_generation", "unexpected boot ID"));
            }
            if ledger
                .record(&handle.workload_id)
                .is_none_or(|record| record.handle != *handle)
            {
                return Err(("not_found", "unknown native workload"));
            }
            Ok(())
        };
        match frame.kind {
            Kind::Launch | Kind::Prepare => {
                drop(guard);
                let request: LaunchRequest = parse(frame)?;
                let ready = if self.oci {
                    request.validate_oci()
                } else {
                    request.validate()
                }
                .map_err(|err| (err.code(), "invalid native launch spec"))?;
                let expires = deadline(ready.request().budget_ms)?;
                self.admit(
                    ready,
                    boot,
                    expires,
                    frame.kind == Kind::Prepare,
                    false,
                    None,
                )
            }
            Kind::Claim => {
                let request: Claim = parse(frame)?;
                let expires = deadline(request.budget_ms)?;
                check(&guard, &request.handle)?;
                if guard.pressure
                    || crate::memory::pressures_reserve(crate::memory::available_bytes())
                {
                    return Err(("memory_pressure", "prepared claim paused under pressure"));
                }
                if guard.closing || Instant::now() >= expires {
                    return Err(("slot_unavailable", "prepared claim is no longer admissible"));
                }
                let record = guard
                    .record_mut(&request.handle.workload_id)
                    .expect("checked record");
                let slot = record
                    .slot
                    .as_mut()
                    .ok_or(("slot_unavailable", "handle has no prepared slot"))?;
                slot.claim(spec_digest(&request.spec), Instant::now())
                    .map_err(|error| match error {
                        ClaimError::Unavailable => {
                            ("slot_unavailable", "prepared slot is unavailable")
                        }
                        ClaimError::Mismatch => ("spec_mismatch", "prepared specification differs"),
                    })?;
                let control = record
                    .control
                    .as_mut()
                    .expect("ready slot owns control socket");
                if control.write_all(&[RELEASE]).is_err() {
                    let _ = control.shutdown(std::net::Shutdown::Both);
                    record.cancel();
                    self.changed.notify_all();
                    return Err((
                        "claim_indeterminate",
                        "query original handle for terminal state",
                    ));
                }
                record.change(Phase::Claimed);
                self.changed.notify_all();
                Ok((Kind::State, record.state()))
            }
            Kind::Inspect if self.native => {
                let request: Inspect = parse(frame)?;
                let expires = deadline(request.budget_ms)?;
                if let Some(handle) = request.workload {
                    check(&guard, &handle)?;
                    if !self.oci
                        || !guard
                            .record(&handle.workload_id)
                            .is_some_and(|record| record.phase == Phase::Running)
                    {
                        return Err((
                            "not_running",
                            "native statistics require a running workload",
                        ));
                    }
                    let path = guard
                        .record(&handle.workload_id)
                        .expect("checked workload")
                        .cgroup_path(true);
                    let usage = crate::cgroups::usage(&path).map_err(|_| {
                        (
                            "stats_unavailable",
                            "workload cgroup statistics are unavailable",
                        )
                    })?;
                    if Instant::now() >= expires {
                        return Err(("deadline_exceeded", "workload statistics budget elapsed"));
                    }
                    return Ok((Kind::Inspect, json!({"handle":handle,"usage":usage})));
                }
                if request.include_builds {
                    let builds = guard
                        .records
                        .iter()
                        .filter(|record| record.buildkit_worker || record.build_parent.is_some())
                        .map(|record| {
                            let mut state = record.state();
                            state["sequence"] = json!(record.sequence);
                            state["worker"] = json!(record.buildkit_worker);
                            state["parent"] = json!(record.build_parent);
                            state
                        })
                        .collect::<Vec<_>>();
                    return Ok((
                        Kind::Inspect,
                        json!({
                            "boot_id": boot,
                            "last_sequence": guard.highest_sequence,
                            "builds": builds,
                        }),
                    ));
                }
                Ok((
                    Kind::Inspect,
                    json!({
                        "boot_id": boot,
                        "image_digest": self.image_digest,
                        "last_sequence": guard.highest_sequence,
                        "workload": guard.records.back().map(Record::state),
                        "installed_images": guard.images.snapshot(),
                        "disk_image_store": crate::image_store::disk_store_enabled(),
                        "exec_active": guard.exec_active,
                        "exec_streams": guard.exec_streams,
                        "active_workloads": guard.active().map(Record::state).collect::<Vec<_>>(),
                    }),
                ))
            }
            Kind::Image if self.oci => {
                let request: image_store::Request = parse(frame)?;
                if request.boot_id != boot {
                    return Err(("stale_generation", "unexpected boot ID"));
                }
                let expires = deadline(request.budget_ms)?;
                if guard.closing {
                    return Err(("busy", "fresh fixture is draining"));
                }
                let live_images: BTreeSet<_> = guard
                    .active()
                    .map(|record| record.image_digest.clone())
                    .collect();
                let response = guard.images.handle(
                    request,
                    connection,
                    &self.image_digest,
                    &live_images,
                    expires,
                )?;
                Ok((Kind::Image, response))
            }
            Kind::Memory => {
                let request: MemoryRequest = parse(frame)?;
                let observing = request.core_only && request.core_grant.is_none();
                let expires = deadline(request.budget_ms)?;
                if request.boot_id != boot {
                    return Err(("stale_generation", "unexpected boot ID"));
                }
                if Instant::now() >= expires {
                    return Err(("deadline_exceeded", "memory operation budget elapsed"));
                }
                if (request.core_only || request.core_grant.is_some()) && !self.core_admission {
                    return Err(("unsupported_option", "Core admission is disabled"));
                }
                if request.watch_pending {
                    if !observing
                        || request.pressure.is_some()
                        || request.budget_ms > crate::core_admission::PENDING_WATCH_MS
                    {
                        return Err(("malformed", "invalid pending admission watch"));
                    }
                    if guard.core_watcher {
                        return Err(("busy", "a pending admission watch is already active"));
                    }
                    guard.core_watcher = true;
                    // Admission and this predicate share the ledger lock. A new
                    // request can either be observed here or wake the waiter.
                    while !guard.closing && !guard.has_pending_core_admission(Instant::now()) {
                        let remaining = expires.saturating_duration_since(Instant::now());
                        if remaining.is_zero() {
                            break;
                        }
                        guard = self
                            .changed
                            .wait_timeout(guard, remaining)
                            .expect("fresh ledger")
                            .0;
                    }
                    guard.core_watcher = false;
                }
                if let Some(pressure) = request.pressure {
                    if self.core_pressure_fixture {
                        guard.set_pressure_fixture(pressure).map_err(|_| {
                            ("fixture_failed", "could not update Core pressure helper")
                        })?;
                    }
                    guard.set_pressure(pressure);
                    self.changed.notify_all();
                }
                if let Some(grant) = request.core_grant {
                    guard.grant_core_admission(grant, boot, Instant::now())?;
                    self.changed.notify_all();
                }
                let mut snapshot = if request.core_only {
                    json!({})
                } else {
                    guard.memory_snapshot(self.oci)
                };
                if self.core_admission {
                    snapshot["core_admission"] =
                        json!(guard.core_admission(Instant::now(), observing));
                }
                Ok((Kind::Memory, snapshot))
            }
            Kind::Volume if self.oci => {
                let request: VolumeRequest = parse(frame)?;
                if request.boot_id != boot {
                    return Err(("stale_generation", "unexpected native volume boot ID"));
                }
                let expires = deadline(request.budget_ms)?;
                if guard.closing || Instant::now() >= expires {
                    return Err(("busy", "native volume registry is draining"));
                }
                if let VolumeOperation::Remove { name } = &request.operation
                    && guard.active().any(|record| {
                        record
                            .volume
                            .as_ref()
                            .is_some_and(|volume| &volume.name == name)
                    })
                {
                    return Err(("in_use", "native volume is owned by a workload"));
                }
                // Keep the request serialized with shutdown through its last fsync.
                request.operation.execute()
            }
            Kind::BuildSnapshot if self.oci && self.core_admission => {
                let request: BuildSnapshotRequest = parse(frame)?;
                if request.boot_id != boot {
                    return Err((
                        "stale_generation",
                        "unexpected native build snapshot boot ID",
                    ));
                }
                let expires = deadline(request.budget_ms)?;
                if guard.closing || Instant::now() >= expires {
                    return Err(("busy", "native build workspace is draining"));
                }
                if !crate::build_snapshot::valid_id(&request.id) {
                    return Err(("malformed", "invalid native build bundle identity"));
                }
                if request.verify_bundle {
                    drop(guard);
                    let bundle = crate::build_snapshot::guest::inspect_bundle(
                        &request.id,
                        &self.image_digest,
                    )
                    .map_err(|message| ("unsupported_option", message))?;
                    if Instant::now() >= expires {
                        return Err((
                            "deadline_exceeded",
                            "build bundle verification budget elapsed",
                        ));
                    }
                    return Ok((Kind::BuildSnapshot, json!(bundle)));
                }
                let snapshot = crate::build_snapshot::guest::inspect(&request.id)
                    .map_err(|_| ("not_found", "native build snapshot is unavailable"))?;
                Ok((Kind::BuildSnapshot, json!(snapshot)))
            }
            Kind::Network if self.oci => {
                let request: NetworkRequest = parse(frame)?;
                if request.boot_id != boot {
                    return Err(("stale_generation", "unexpected boot ID"));
                }
                let expires = deadline(request.budget_ms)?;
                drop(guard);
                self.network(request.operation, boot, expires)
            }
            Kind::Exec if self.oci => {
                let request: Exec = parse(frame)?;
                let expires = deadline(request.budget_ms)?;
                let stdin = request
                    .stdin
                    .map(|encoded| {
                        base64::engine::general_purpose::STANDARD
                            .decode(encoded)
                            .ok()
                            .filter(|bytes| {
                                bytes.len() <= crate::wire::EXEC_STDIN_LIMIT && !request.tty
                            })
                            .ok_or(("invalid_spec", "invalid attached exec stdin"))
                    })
                    .transpose()?;
                check(&guard, &request.handle)?;
                if guard.closing || guard.exec_active || guard.exec_output.is_some() {
                    return Err(("busy", "the native exec slot is already owned"));
                }
                let (spec, target, id) = guard.exec_target(&request.handle, request.argv)?;
                guard.exec_active = true;
                drop(guard);
                let result =
                    crate::exec_fixture::execute(target, id, spec, request.tty, stdin, expires);
                let mut guard = self.ledger.lock().expect("fresh ledger");
                guard.exec_active = false;
                self.changed.notify_all();
                match result {
                    Ok(result) => guard.complete_exec(result, connection),
                    Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                        Err(("deadline_exceeded", "native exec exceeded its deadline"))
                    }
                    Err(error) => {
                        eprintln!("native exec failed: {error}");
                        Err((
                            "exec_failed",
                            "native exec could not enter its owned workload",
                        ))
                    }
                }
            }
            Kind::ExecOutput if self.oci => {
                let request: ExecOutput = parse(frame)?;
                if request.boot_id != boot {
                    return Err(("stale_generation", "unexpected native exec output boot ID"));
                }
                if guard.closing || Instant::now() >= deadline(request.budget_ms)? {
                    return Err((
                        "busy",
                        "native exec output request expired or guest is draining",
                    ));
                }
                guard.read_exec_output(request, connection)
            }
            Kind::Copy if self.oci => {
                let request: WorkloadCopy = parse(frame)?;
                if request.boot_id != boot {
                    return Err(("stale_generation", "unexpected native archive boot ID"));
                }
                let expires = deadline(request.budget_ms)?;
                check(&guard, &request.handle)?;
                if matches!(
                    &request.operation,
                    crate::workload_copy::Operation::Stat { .. }
                        | crate::workload_copy::Operation::Begin(_)
                ) {
                    guard = self.wait_for_archive_start(guard, &request.handle, expires);
                    check(&guard, &request.handle)?;
                }
                if guard.closing {
                    return Err(("busy", "native archive service is draining"));
                }
                if Instant::now() >= expires {
                    return Err((
                        "deadline_exceeded",
                        "native workload archive request expired",
                    ));
                }
                let (spec, pidfd) = guard
                    .record(&request.handle.workload_id)
                    .filter(|record| record.phase == Phase::Running)
                    .and_then(|record| record.exec_context.as_ref())
                    .ok_or(("not_running", "archive requires a running native workload"))?;
                let uid = spec.uid;
                let target = pidfd
                    .try_clone()
                    .map_err(|_| ("busy", "cannot retain native archive target"))?;
                let root = crate::exec_fixture::target_root(&target)
                    .map_err(|_| ("not_running", "cannot retain native archive root"))?;
                if Instant::now() >= expires {
                    return Err((
                        "deadline_exceeded",
                        "native workload archive request expired",
                    ));
                }
                let reply = guard
                    .copies
                    .operate(
                        &root,
                        request.operation,
                        connection,
                        &request.handle.workload_id,
                        uid,
                    )
                    .map_err(archive_failure)?;
                Ok((Kind::Copy, reply))
            }
            Kind::Account if self.oci => {
                let request: ImageAccount = parse(frame)?;
                if request.boot_id != boot {
                    return Err(("stale_generation", "unexpected image account boot ID"));
                }
                if request.image_digest != self.image_digest
                    && !guard.images.contains(&request.image_digest)
                {
                    return Err(("not_found", "image is not installed for account resolution"));
                }
                let (uid, gid) =
                    crate::image_account::resolve_image(&request.image_digest, &request.account)
                        .map_err(|_| {
                            ("unknown_account", "unknown or unmapped OCI image account")
                        })?;
                Ok((Kind::Account, json!({"uid":uid,"gid":gid})))
            }
            Kind::Input if self.oci => {
                let request: WorkloadInput = parse(frame)?;
                let expires = deadline(request.budget_ms)?;
                check(&guard, &request.handle)?;
                if guard.closing || Instant::now() >= expires {
                    return Err(("busy", "native workload input is unavailable"));
                }
                let record = guard
                    .record_mut(&request.handle.workload_id)
                    .filter(|record| record.phase == Phase::Running)
                    .ok_or(("not_running", "input requires a running native workload"))?;
                let Some(writer) = record.input.as_mut() else {
                    return Err(("input_closed", "native workload input is closed"));
                };
                let accepted = if let Some(data) = request.data {
                    const LIMIT: usize = crate::workload_input::CHUNK;
                    if data.is_empty() || data.len() > LIMIT.div_ceil(3) * 4 {
                        return Err(("malformed", "invalid workload input size"));
                    }
                    let bytes = base64::engine::general_purpose::STANDARD
                        .decode(data)
                        .map_err(|_| ("malformed", "invalid workload input encoding"))?;
                    if bytes.is_empty() || bytes.len() > LIMIT {
                        return Err(("malformed", "invalid workload input size"));
                    }
                    match crate::workload_input::write(writer, &bytes) {
                        Ok(accepted) => accepted,
                        Err(_) => {
                            record.input = None;
                            return Err(("input_closed", "native workload input pipe closed"));
                        }
                    }
                } else {
                    record.input = None;
                    true
                };
                Ok((Kind::Input, json!({"accepted":accepted})))
            }
            Kind::Status | Kind::Cancel => {
                let request: Control = parse(frame)?;
                deadline(request.budget_ms)?;
                check(&guard, &request.handle)?;
                let record = guard
                    .record_mut(&request.handle.workload_id)
                    .expect("checked record");
                match (frame.kind, request.signal) {
                    (Kind::Cancel, None | Some(9)) => {
                        record.cancel();
                        self.changed.notify_all();
                    }
                    (Kind::Cancel, Some(15)) if self.oci => {
                        record
                            .terminate()
                            .map_err(|_| ("control_failed", "native termination channel failed"))?;
                        if self.core_admission {
                            self.changed.notify_all();
                        }
                    }
                    (Kind::Status, None) => {}
                    _ => return Err(("unsupported_option", "unsupported native control signal")),
                }
                Ok((Kind::State, record.state()))
            }
            Kind::Wait => {
                let request: Wait = parse(frame)?;
                let expires = deadline(request.budget_ms)?;
                check(&guard, &request.handle)?;
                if guard.waiting >= crate::handshake::MAX_CONNECTIONS - 1 {
                    return Err(("busy", "one connection is reserved for cancellation"));
                }
                guard.waiting += 1;
                let reply = loop {
                    if let Err(error) = check(&guard, &request.handle) {
                        break Err(error);
                    }
                    let record = guard
                        .record(&request.handle.workload_id)
                        .expect("checked record");
                    let cursors = request.live_output.as_ref();
                    if cursors.is_some_and(|cursors| {
                        cursors.stdout > record.stdout.bytes.len()
                            || cursors.stderr > record.stderr.bytes.len()
                    }) {
                        break Err(("malformed", "live output cursor exceeds captured data"));
                    }
                    if record.revision > request.after_revision || record.phase.terminal() {
                        let mut state = record.state();
                        if request.terminal_output && record.phase == Phase::Removed {
                            let (stdout, stderr) =
                                cursors.map_or((0, 0), |cursors| (cursors.stdout, cursors.stderr));
                            state["terminal_output"] = output_bundle(record, stdout, stderr, true);
                        }
                        if record.phase.terminal()
                            && self.trace_core_latency
                            && let Some(trace) = &record.trace
                        {
                            state["guest_phase_ns"]["terminal_reply"] =
                                json!(trace.admitted.elapsed().as_nanos());
                        }
                        break Ok((Kind::State, state));
                    }
                    if let Some(cursors) = cursors.filter(|cursors| {
                        cursors.stdout < record.stdout.bytes.len()
                            || cursors.stderr < record.stderr.bytes.len()
                    }) {
                        let mut state = record.state();
                        state["live_output"] =
                            output_bundle(record, cursors.stdout, cursors.stderr, false);
                        break Ok((Kind::State, state));
                    }
                    let remaining = expires.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        break Err(("deadline_exceeded", "workload remains admitted"));
                    }
                    guard = self
                        .changed
                        .wait_timeout(guard, remaining)
                        .expect("fresh ledger")
                        .0;
                };
                guard.waiting -= 1;
                reply
            }
            Kind::Output => {
                let request: Output = parse(frame)?;
                let expires = deadline(request.budget_ms)?;
                if !matches!(request.stream.as_str(), "stdout" | "stderr")
                    || !(1..=OUTPUT_CHUNK_LIMIT).contains(&request.max_bytes)
                {
                    return Err(("malformed", "invalid output stream or reply bound"));
                }
                loop {
                    check(&guard, &request.handle)?;
                    let record = guard
                        .record(&request.handle.workload_id)
                        .expect("checked record");
                    let output = if request.stream == "stdout" {
                        &record.stdout
                    } else {
                        &record.stderr
                    };
                    if request.offset > output.bytes.len() {
                        return Err(("malformed", "invalid output cursor"));
                    }
                    if !request.follow
                        || request.offset < output.bytes.len()
                        || output.dropped != 0
                        || record.phase.terminal()
                    {
                        return Ok((
                            Kind::OutputChunk,
                            output_chunk(
                                output,
                                request.offset,
                                request.max_bytes,
                                record.phase.terminal(),
                            ),
                        ));
                    }
                    let remaining = expires.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(("deadline_exceeded", "no further output is available"));
                    }
                    if guard.waiting >= crate::handshake::MAX_CONNECTIONS - 1 {
                        return Err(("busy", "one connection is reserved for cancellation"));
                    }
                    guard.waiting += 1;
                    guard = self
                        .changed
                        .wait_timeout(guard, remaining)
                        .expect("fresh ledger")
                        .0;
                    guard.waiting -= 1;
                }
            }
            _ => Err((
                "unsupported_option",
                "operation is not available in this fixture",
            )),
        }
    }

    pub(crate) fn dispatch(
        self: &Arc<Self>,
        frame: Frame,
        stream: &mut Stream,
        boot: &str,
        connection: ConnectionId,
    ) -> Result<(), WireError> {
        let reply = self.operation(&frame, boot, connection);
        stream.deadline(Some(Instant::now() + Duration::from_secs(2)));
        match reply {
            Ok((kind, reply)) => Frame::write(stream, kind, frame.id, &reply),
            Err((code, message)) => write_error(stream, frame.id, code, message),
        }
    }

    pub(crate) fn dispatch_build(
        self: &Arc<Self>,
        frame: Frame,
        stream: &mut Stream,
        boot: &str,
        worker_cgroup: Option<&str>,
    ) -> Result<(), WireError> {
        stream.deadline(Some(Instant::now() + Duration::from_secs(2)));
        let reply = frame
            .decode()
            .map_err(|_| ("malformed", "invalid build runtime request"))
            .and_then(|request| {
                let owner = worker_cgroup
                    .map(|cgroup| {
                        self.ledger
                            .lock()
                            .expect("fresh ledger")
                            .build_worker(cgroup)
                            .map(|record| record.handle.workload_id.clone())
                            .ok_or(("stale_generation", "BuildKit worker lease ended"))
                    })
                    .transpose()?;
                self.build_operation(request, boot, owner)
            });
        match reply {
            Ok(body) => Frame::write(stream, Kind::BuildRuntime, frame.id, &body),
            Err((code, detail)) => write_error(stream, frame.id, code, detail),
        }
    }

    pub(crate) fn owns_build_worker(&self, cgroup: &str) -> bool {
        self.ledger
            .lock()
            .expect("fresh ledger")
            .build_worker(cgroup)
            .is_some()
    }

    pub(crate) fn build_registry_current(&self, owner: &str) -> bool {
        self.build_registry
            .lock()
            .expect("build registry")
            .as_ref()
            .is_some_and(|registry| registry.owner == owner)
            && self
                .ledger
                .lock()
                .expect("fresh ledger")
                .record(owner)
                .is_some_and(|record| {
                    record.buildkit_registry
                        && !record.cancelled
                        && !record.terminate_requested
                        && !record.phase.terminal()
                })
    }

    pub(crate) fn accept_build_registry(&self) -> io::Result<(String, std::net::TcpStream)> {
        let (owner, expected, stream, peer) = {
            let registry = self.build_registry.lock().expect("build registry");
            let registry = registry.as_ref().ok_or(io::ErrorKind::WouldBlock)?;
            crate::socket::wait(
                registry.listener.as_raw_fd(),
                libc::POLLIN,
                None,
                Some(Instant::now() + Duration::from_millis(150)),
            )?;
            let (stream, peer) = registry.listener.accept()?;
            (registry.owner.clone(), registry.address, stream, peer)
        };
        if peer.ip() != std::net::IpAddr::V4(expected) || !self.build_registry_current(&owner) {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        Ok((owner, stream))
    }

    fn prepare_worker_build(
        &self,
        owner: &str,
        id: &str,
    ) -> Result<(LaunchSpec, WorkerBuild), Failure> {
        let (pidfd, volume, snapshotter) = {
            let ledger = self.ledger.lock().expect("fresh ledger");
            let record = ledger
                .record(owner)
                .filter(|record| {
                    record.phase == Phase::Running
                        && record.buildkit_worker
                        && !record.cancelled
                        && !record.terminate_requested
                })
                .ok_or(("stale_generation", "BuildKit worker lease ended"))?;
            let (worker, pidfd) = record
                .exec_context
                .as_ref()
                .ok_or(("stale_generation", "missing BuildKit worker process lease"))?;
            let snapshotter = worker
                .buildkit_snapshotter()
                .ok_or(("stale_generation", "missing BuildKit snapshotter identity"))?;
            let volume = record
                .volume
                .clone()
                .ok_or(("stale_generation", "missing BuildKit worker cache lease"))?;
            (
                pidfd
                    .try_clone()
                    .map_err(|_| ("busy", "could not retain BuildKit process lease"))?,
                volume,
                snapshotter,
            )
        };
        let root = crate::exec_fixture::target_root(&pidfd).map_err(|_| {
            (
                "stale_generation",
                "could not open live BuildKit worker root",
            )
        })?;
        let mountinfo = crate::exec_fixture::target_mountinfo(&pidfd).map_err(|_| {
            (
                "stale_generation",
                "could not open live BuildKit worker mounts",
            )
        })?;
        let bundle = crate::build_snapshot::guest::read_worker_config(
            &root,
            &mountinfo,
            &volume,
            id,
            snapshotter,
        )
        .map_err(|error| {
            eprintln!("BuildKit bundle verification failed: {error}");
            (
                "stale_generation",
                "could not verify live BuildKit bundle and rootfs",
            )
        })?;
        let snapshot = bundle.identity(id.to_owned()).map_err(|_| {
            (
                "stale_generation",
                "could not retain live BuildKit root identity",
            )
        })?;
        let (mut spec, hosts) = crate::build_snapshot::bundle::parse_live(
            &bundle.config,
            snapshot,
            &self.image_digest,
            snapshotter,
        )
        .map_err(|reason| ("unsupported_option", reason))?;
        let home = spec.env.iter().position(|value| value.starts_with("HOME="));
        if home.is_none_or(|index| spec.env[index] == "HOME=") {
            let home_value = bundle.default_home(spec.uid).map_err(|_| {
                (
                    "invalid_spec",
                    "could not read BuildKit snapshot home directory",
                )
            })?;
            let home_value = format!("HOME={home_value}");
            if let Some(index) = home {
                spec.env[index] = home_value;
            } else {
                spec.env.push(home_value);
            }
        }
        let detached = bundle.clone_root(&pidfd).map_err(|error| {
            eprintln!("BuildKit detach verification failed: {error}");
            (
                "invalid_spec",
                "could not detach verified BuildKit snapshot",
            )
        })?;
        let mounts = LiveMounts::capture(detached, &bundle.executor, &bundle.cache, &hosts)
            .map_err(|_| {
                (
                    "invalid_spec",
                    "could not pin verified BuildKit auxiliary mounts",
                )
            })?;
        Ok((
            spec,
            WorkerBuild {
                owner: owner.to_owned(),
                volume,
                mounts,
            },
        ))
    }

    fn build_operation(
        self: &Arc<Self>,
        request: BuildRuntimeRequest,
        boot: &str,
        owner: Option<String>,
    ) -> Result<Value, Failure> {
        if !self.oci || !self.core_admission {
            return Err(("unsupported_option", "build runtime requires native Core"));
        }
        if request.boot_id != boot {
            return Err(("stale_generation", "unexpected build runtime boot"));
        }
        if !crate::build_snapshot::valid_id(&request.id) {
            return Err(("malformed", "invalid build runtime ID"));
        }
        let mut runtime = self.build_runtime.lock().expect("build runtime");
        if runtime
            .deleted
            .iter()
            .any(|(scope, id)| scope == &owner && id == &request.id)
        {
            return match request.operation {
                BuildOperation::Delete => Ok(json!({"deleted": true})),
                _ => Err(("stale_generation", "build runtime was already deleted")),
            };
        }
        if matches!(request.operation, BuildOperation::Run) && runtime.active.is_none() {
            if runtime.deleted.len() >= BUILD_GENERATIONS {
                return Err(("busy", "build runtime boot generation budget is exhausted"));
            }
            let (spec, live) = if let Some(owner) = &owner {
                let (spec, live) = self.prepare_worker_build(owner, &request.id)?;
                (spec, Some(live))
            } else {
                let bundle = crate::build_snapshot::guest::seal_worker_bundle(
                    &request.id,
                    &self.image_digest,
                )
                .map_err(|reason| ("unsupported_option", reason))?;
                (bundle.spec, None)
            };
            let intent: [u8; 16] = random().map_err(|_| ("busy", "unavailable build identity"))?;
            let expires = Instant::now() + Duration::from_secs(3);
            // A locally allocated sequence must not consume the host
            // adapter's authenticated request sequence.
            let launch = LaunchRequest {
                boot_id: boot.to_owned(),
                sequence: BUILD_SEQUENCE_BASE + runtime.deleted.len() as u64 + 1,
                operation_id: Some(hex(&intent)),
                budget_ms: 3000,
                spec,
            };
            let launch = launch
                .validate()
                .map_err(|error| (error.code(), "invalid build launch"))?;
            let (_, state) = self.admit(launch, boot, expires, false, true, live)?;
            let handle = serde_json::from_value(state["handle"].clone())
                .expect("typed build workload handle");
            runtime.active = Some(ActiveBuild {
                id: request.id,
                handle,
                owner,
            });
            return Ok(state);
        }
        let active = runtime
            .active
            .as_ref()
            .ok_or(("not_found", "unknown build runtime ID"))?;
        if active.id != request.id || active.owner != owner {
            return Err(("busy", "another build runtime owns this worker"));
        }
        let handle = &active.handle;
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        let record = ledger
            .record_mut(&handle.workload_id)
            .filter(|record| record.handle == *handle)
            .ok_or((
                "cleanup_failed",
                "build runtime ownership could not be reconciled",
            ))?;
        match request.operation {
            BuildOperation::Run => Ok(record.state()),
            BuildOperation::Status { stdout, stderr } => {
                if stdout > record.stdout.bytes.len() || stderr > record.stderr.bytes.len() {
                    return Err(("malformed", "invalid build output cursor"));
                }
                let mut state = record.state();
                state["cancelled"] = json!(record.cancelled);
                state["build_output"] =
                    output_bundle(record, stdout, stderr, record.phase.terminal());
                Ok(state)
            }
            BuildOperation::Kill => {
                record.cancel();
                self.changed.notify_all();
                Ok(record.state())
            }
            BuildOperation::Delete => {
                if record.phase != Phase::Removed {
                    return Err(("busy", "build runtime cleanup has not been verified"));
                }
                record.build_runtime_owned = false;
                runtime.active = None;
                runtime.deleted.push((owner, request.id));
                Ok(json!({"deleted": true}))
            }
        }
    }

    pub(crate) fn drain(&self, deadline: Instant) -> bool {
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        ledger.closing = true;
        loop {
            if !ledger.exec_active
                && ledger.exec_streams == 0
                && ledger.archive_downloads == 0
                && !ledger.copies.stream_active()
                && ledger.records.iter().all(|record| record.phase.terminal())
            {
                let cleaned = !ledger
                    .active()
                    .any(|record| record.phase == Phase::CleanupFailed);
                drop(ledger);
                let mut networks = self.private_networks.lock().expect("private bridges");
                return networks
                    .iter_mut()
                    .filter_map(Option::take)
                    .fold(cleaned, |clean, network| network.close().is_ok() && clean);
            }
            for record in &mut ledger.records {
                record.cancel();
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            ledger = self
                .changed
                .wait_timeout(ledger, remaining)
                .expect("fresh ledger")
                .0;
        }
    }
}

fn spec_digest(spec: &LaunchSpec) -> [u8; 32] {
    Sha256::digest(serde_json::to_vec(spec).expect("typed specification")).into()
}

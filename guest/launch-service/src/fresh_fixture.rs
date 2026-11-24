use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

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
use crate::spec::{LaunchRequest, LaunchSpec, ValidatedLaunch};
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
    Connect { handle: Handle, alias: String },
    Disconnect { handle: Handle },
    Remove,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Dial {
    handle: Handle,
    budget_ms: u64,
    port: u16,
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
    network_alias: Option<String>,
    network_address: Option<std::net::Ipv4Addr>,
    trace: Option<Trace>,
    slot: Option<Slot>,
    slot_expires: Option<Instant>,
    slot_expired: bool,
    memory_limit_bytes: u64,
    core_admission_deadline: Option<Instant>,
    cancelled: bool,
    terminate_requested: bool,
    control: Option<UnixStream>,
    stdout: Capture,
    stderr: Capture,
}

struct Trace {
    admitted: Instant,
    events: BTreeMap<&'static str, u128>,
}

impl Record {
    fn change(&mut self, phase: Phase) {
        self.phase = phase;
        self.revision += 1;
        self.mark(phase.name());
    }

    fn mark(&mut self, milestone: &'static str) {
        if let Some(trace) = &mut self.trace {
            trace
                .events
                .insert(milestone, trace.admitted.elapsed().as_nanos());
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
        if let Some(trace) = &self.trace {
            state["guest_phase_ns"] = json!(trace.events);
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
    highest_sequence: u64,
    closing: bool,
    waiting: usize,
    records: VecDeque<Record>,
    pressure: bool,
    evictions: u64,
    exec_active: bool,
}

impl Ledger {
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
            let observed = crate::kernel_fixture::cgroup_observation(
                &record.handle.workload_id,
                prepared_scope,
                oci,
            )
            .ok();
            let mut state = json!({
                "handle": record.handle, "phase": record.phase.name(),
                "scope": if prepared_scope { "prepared" } else { "active" },
                "limit_bytes": record.memory_limit_bytes,
                "sample_valid": observed.is_some(),
                "current_bytes": observed.map(|(bytes, _)| bytes),
                "populated": observed.map(|(_, populated)| populated),
            });
            if oci && let Ok(id) = crate::handshake::unhex::<16>(&record.handle.workload_id) {
                let (mount, scope) =
                    crate::kernel_fixture::cgroup_paths(&record.handle.workload_id, true);
                let overlay = crate::sandbox_fixture::owned_path(id, true);
                state["paths"] = json!({
                    "cgroup_mount":mount,"cgroup_scope":scope,"overlay":overlay,
                    "overlay_present":overlay.is_dir(),
                });
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

    fn core_admission(&self, now: Instant) -> crate::core_admission::Observation {
        let pending = self
            .active()
            .filter(|record| {
                record.phase == Phase::Accepted
                    && !record.terminate_requested
                    && record
                        .core_admission_deadline
                        .is_some_and(|deadline| now < deadline)
            })
            .map(|record| crate::core_admission::Admission {
                workload_id: record.handle.workload_id.clone(),
                sequence: record.sequence,
            })
            .collect();
        crate::core_admission::Observation {
            owned: self.active().count(),
            pending,
        }
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
}

pub(crate) struct FreshFixture {
    image_digest: String,
    benchmark_digest: Option<String>,
    native: bool,
    oci: bool,
    core_admission: bool,
    trace_benchmark: bool,
    bridge_available: bool,
    allow_crash: bool,
    intent: Intent,
    ledger: Mutex<Ledger>,
    private_network: Mutex<Option<crate::bridge_fixture::NetworkOwner>>,
    changed: Condvar,
}

pub(crate) struct ConnectionLease<'a> {
    pub(crate) fresh: &'a FreshFixture,
    pub(crate) id: ConnectionId,
}

impl Drop for ConnectionLease<'_> {
    fn drop(&mut self) {
        self.fresh
            .ledger
            .lock()
            .expect("fresh ledger")
            .images
            .disconnect(self.id);
    }
}

type Failure = (&'static str, &'static str);
type Reply = Result<(Kind, Value), Failure>;

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
            trace_benchmark,
            bridge_available,
            allow_crash,
            intent,
            ledger: Mutex::new(Ledger::default()),
            private_network: Mutex::new(None),
            changed: Condvar::new(),
        }))
    }

    pub(crate) fn is_oci(&self) -> bool {
        self.oci
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
    ) -> Reply {
        if ready.request().boot_id != boot {
            return Err(("stale_generation", "unexpected boot ID"));
        }
        if self.native && ready.request().operation_id.is_none() {
            return Err(("invalid_spec", "native admission requires an operation ID"));
        }
        let spec = &ready.request().spec;
        let argv = spec.argv.iter().map(String::as_str).collect::<Vec<_>>();
        let benchmark = self.benchmark_digest.as_ref() == Some(&spec.image_digest);
        let mode = match argv.as_slice() {
            _ if self.oci
                && (spec.network == "none" || spec.network_alias.is_some())
                && spec.limits == crate::spec::NATIVE_LIMITS
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
        let bridge = spec.network == "bridge";
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
        if bridge && !self.oci && !self.bridge_available {
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
        if let Some(alias) = &spec.network_alias
            && (!self.oci
                || ledger.active().any(|record| {
                    record
                        .network_alias
                        .as_ref()
                        .is_some_and(|active| active.eq_ignore_ascii_case(alias))
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
        if request.sequence <= ledger.highest_sequence {
            return Err((
                "stale_sequence",
                "sequence was previously admitted or superseded",
            ));
        }
        if deadline <= Instant::now() {
            return Err((
                "deadline_exceeded",
                "launch deadline expired before admission",
            ));
        }
        let id: [u8; 16] = random().map_err(|_| ("busy", "secure workload ID unavailable"))?;
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
            network_alias: spec.network_alias.clone(),
            network_address: None,
            trace: (benchmark && self.trace_benchmark).then(|| Trace {
                admitted: Instant::now(),
                events: BTreeMap::new(),
            }),
            slot: prepared.then(|| Slot::new(spec_digest(spec))),
            slot_expires: prepared.then(|| Instant::now() + SLOT_TTL),
            slot_expired: false,
            memory_limit_bytes: spec.limits.memory_bytes,
            core_admission_deadline: self.core_admission.then_some(deadline),
            cancelled: false,
            terminate_requested: false,
            control: None,
            stdout: Capture::default(),
            stderr: Capture::default(),
        };
        let reply = record.state();
        ledger.highest_sequence = request.sequence;
        if !self.oci {
            ledger.records.clear();
        } else if ledger.records.len() >= OCI_RECORDS {
            let index = ledger
                .records
                .iter()
                .position(|record| record.phase == Phase::Removed)
                .expect("bounded OCI history contains a terminal record");
            ledger.records.remove(index);
        }
        ledger.records.push_back(record);
        let owner = Arc::clone(self);
        let limits = spec.limits;
        let mode = mode.to_owned();
        let oci_process = self
            .oci
            .then(|| serde_json::to_string(spec).expect("validated OCI spec"));
        if thread::Builder::new()
            .name("fresh-workload".into())
            .spawn(move || {
                owner.run_workload(id, limits, &mode, bridge, prepared, oci_process.as_deref())
            })
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
        Ok((Kind::State, reply))
    }

    fn run_workload(
        self: &Arc<Self>,
        id: [u8; 16],
        limits: crate::spec::ResourceLimits,
        mode: &str,
        bridge: bool,
        prepared: bool,
        oci_process: Option<&str>,
    ) {
        let workload = hex(&id);
        {
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
                    break;
                };
                ledger = self
                    .changed
                    .wait_timeout(ledger, deadline - now)
                    .expect("fresh ledger")
                    .0;
            }
        }
        let scoped;
        let intent = if oci_process.is_some() {
            scoped = self.intent.scoped(id);
            &scoped
        } else {
            &self.intent
        };
        let result = intent.record(id).and_then(|()| {
            let output = self.run_helper(id, limits, mode, bridge, prepared, oci_process)?;
            if oci_process.is_some() {
                crate::kernel_fixture::assert_owned_cgroup_absent(id)?;
                crate::sandbox_fixture::assert_owned_absent(id)?;
            }
            intent.complete(id)?;
            Ok(output)
        });
        if let Err(error) = &result {
            eprintln!("fresh fixture did not confirm cleanup: {error}");
        }
        self.update(&workload, |record| {
            record.control = None;
            record.exec_context = None;
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

    fn run_helper(
        self: &Arc<Self>,
        id: [u8; 16],
        limits: crate::spec::ResourceLimits,
        mode: &str,
        bridge: bool,
        prepared: bool,
        oci_process: Option<&str>,
    ) -> io::Result<bool> {
        let (mut peer, helper) = UnixStream::pair()?;
        peer.set_read_timeout(Some(Duration::from_secs(32)))?;
        let owner = peer.try_clone()?;
        let workload = hex(&id);
        let mut command = Command::new("/init");
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
                    Ok(())
                });
            }
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
            .args(oci_process)
            .env_clear()
            .stdin(Stdio::from(OwnedFd::from(helper)))
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let process_group = -(child.id() as libc::pid_t);
        let out = child.stdout.take().expect("piped stdout");
        let err = child.stderr.take().expect("piped stderr");
        let output_owner = Arc::clone(self);
        let output_id = workload.clone();
        let stdout = thread::spawn(move || {
            drain(out, |data| {
                output_owner.update(&output_id, |record| record.stdout.append(data));
            })
        });
        let error_owner = Arc::clone(self);
        let error_id = workload.clone();
        let stderr = thread::spawn(move || {
            drain(err, |data| {
                error_owner.update(&error_id, |record| record.stderr.append(data));
            })
        });
        self.update(&workload, |record| {
            record.control = Some(owner);
            if record.cancelled {
                let _ = record.control.as_mut().unwrap().write_all(&[CANCEL]);
            } else if record.terminate_requested {
                let _ = record.control.as_mut().unwrap().write_all(&[TERMINATE]);
            }
        });
        let mut removed = false;
        let mut exit_received = false;
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
                        let alias = self
                            .ledger
                            .lock()
                            .expect("fresh ledger")
                            .record(&workload)
                            .expect("owned workload")
                            .network_alias
                            .clone()
                            .ok_or_else(|| io::Error::other("missing bridge alias"))?;
                        let mut private = self.private_network.lock().expect("private bridge");
                        if private.is_none() {
                            *private = Some(crate::bridge_fixture::NetworkOwner::new()?);
                        }
                        let address = private
                            .as_mut()
                            .expect("private bridge")
                            .attach(id, target, &alias)?;
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
                        self.update(&workload, |record| {
                            if let (Some(spec), Some(target)) = (oci_process, descriptors.pop())
                                && let Ok(spec) = serde_json::from_str(spec)
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
                    b'X' => {
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
                                Some(json!({"signal": libc::WTERMSIG(status)}))
                            } else {
                                None
                            };
                            record.change(Phase::Cleaning);
                        });
                    }
                    b'N' if !exit_received => {
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
            crate::kernel_fixture::recover_cgroup(id, oci_process.is_some())?;
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
        if let Some(network) = self
            .private_network
            .lock()
            .expect("private bridge")
            .as_mut()
        {
            network.detach(id)?;
        }
        Ok(())
    }

    fn network(&self, operation: NetworkOperation, boot: &str, deadline: Instant) -> Reply {
        let mut network = self.private_network.lock().expect("private bridge");
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        if ledger.closing || deadline <= Instant::now() {
            return Err(("busy", "private bridge is draining"));
        }
        let (handle, alias) = match operation {
            NetworkOperation::Remove => {
                if ledger.active().any(|record| record.network_alias.is_some()) {
                    return Err(("busy", "private bridge still owns workloads"));
                }
                if let Some(owned) = network.take() {
                    owned
                        .close()
                        .map_err(|_| ("cleanup_failed", "cannot verify bridge removal"))?;
                }
                return Ok((Kind::Network, json!({"removed":true})));
            }
            NetworkOperation::Connect { handle, alias } => {
                if !crate::bridge_dns::valid_name(&alias) {
                    return Err(("unsupported_option", "invalid private network alias"));
                }
                if ledger.active().any(|record| {
                    record
                        .network_alias
                        .as_ref()
                        .is_some_and(|name| name.eq_ignore_ascii_case(&alias))
                }) {
                    return Err(("busy", "private network alias is already owned"));
                }
                (handle, Some(alias))
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
        let (_, pidfd) = record
            .exec_context
            .as_ref()
            .filter(|(spec, _)| spec.network == "bridge")
            .ok_or((
                "unsupported_option",
                "workload was not admitted with bridge permissions",
            ))?;
        let id = crate::handshake::unhex::<16>(&handle.workload_id)
            .map_err(|_| ("malformed", "invalid workload ID"))?;
        if let Some(alias) = alias {
            if record.network_address.is_some() {
                return Err(("busy", "workload already owns a bridge port"));
            }
            let target = crate::exec_fixture::target_network(pidfd)
                .map_err(|_| ("not_running", "cannot retain its live network namespace"))?;
            if network.is_none() {
                *network = Some(
                    crate::bridge_fixture::NetworkOwner::new()
                        .map_err(|_| ("network_failed", "cannot create the private bridge"))?,
                );
            }
            let address = network
                .as_mut()
                .expect("private bridge")
                .attach(id, target, &alias)
                .map_err(|_| ("network_failed", "private bridge peer attachment failed"))?;
            record.network_address = Some(address);
            record.network_alias = Some(alias);
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
            record.network_alias = None;
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
        let network = self.private_network.lock().expect("private bridge");
        let ledger = self.ledger.lock().expect("fresh ledger");
        let active = ledger
            .record(&request.handle.workload_id)
            .is_some_and(|record| {
                record.handle == request.handle
                    && record.phase == Phase::Running
                    && record.network_address.is_some()
            });
        if ledger.closing || !active {
            return Err((
                "not_running",
                "native TCP target has no active bridge lease",
            ));
        }
        drop(ledger);
        let budget = Duration::from_millis(request.budget_ms).saturating_sub(arrival.elapsed());
        if budget.is_zero() {
            return Err(("deadline_exceeded", "native TCP connect budget expired"));
        }
        let id = crate::handshake::unhex::<16>(&request.handle.workload_id)
            .map_err(|_| ("malformed", "invalid native workload ID"))?;
        network
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
                let ready = request
                    .validate()
                    .map_err(|err| (err.code(), "invalid native launch spec"))?;
                let expires = deadline(ready.request().budget_ms)?;
                self.admit(ready, boot, expires, frame.kind == Kind::Prepare)
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
                let request: crate::server::Budget = parse(frame)?;
                deadline(request.budget_ms)?;
                Ok((
                    Kind::Inspect,
                    json!({
                        "boot_id": boot,
                        "image_digest": self.image_digest,
                        "last_sequence": guard.highest_sequence,
                        "workload": guard.records.back().map(Record::state),
                        "installed_images": guard.images.snapshot(),
                        "exec_active": guard.exec_active,
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
                if let Some(pressure) = request.pressure {
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
                    snapshot["core_admission"] = json!(guard.core_admission(Instant::now()));
                }
                Ok((Kind::Memory, snapshot))
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
                check(&guard, &request.handle)?;
                if guard.closing || guard.exec_active {
                    return Err(("busy", "the native exec slot is already owned"));
                }
                let record = guard
                    .record(&request.handle.workload_id)
                    .expect("checked record");
                let (spec, target) = record
                    .exec_context
                    .as_ref()
                    .filter(|_| record.phase == Phase::Running)
                    .ok_or(("not_running", "native exec requires a live OCI process"))?;
                let mut spec = spec.clone();
                spec.argv = request.argv;
                spec.validate_exec()
                    .map_err(|_| ("invalid_spec", "invalid native exec argv"))?;
                let target = target
                    .try_clone()
                    .map_err(|_| ("busy", "cannot retain native exec target"))?;
                let id = crate::handshake::unhex(&request.handle.workload_id)
                    .map_err(|_| ("malformed", "invalid native workload ID"))?;
                guard.exec_active = true;
                drop(guard);
                let result = crate::exec_fixture::execute(target, id, spec, expires);
                let mut guard = self.ledger.lock().expect("fresh ledger");
                guard.exec_active = false;
                self.changed.notify_all();
                match result {
                    Ok(reply) => Ok((Kind::Exec, reply)),
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

    pub(crate) fn drain(&self, deadline: Instant) -> bool {
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        ledger.closing = true;
        loop {
            if !ledger.exec_active && ledger.records.iter().all(|record| record.phase.terminal()) {
                let cleaned = !ledger
                    .active()
                    .any(|record| record.phase == Phase::CleanupFailed);
                drop(ledger);
                let mut network = self.private_network.lock().expect("private bridge");
                return cleaned && network.take().is_none_or(|network| network.close().is_ok());
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

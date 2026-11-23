use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
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
use crate::intent::{DIRECTORY, Intent};
use crate::output::{Capture, capture};
use crate::prepared::{CANCEL, ClaimError, RELEASE, SLOT_MEMORY_LIMIT, SLOT_TTL, Slot};
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
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Wait {
    handle: Handle,
    budget_ms: u64,
    after_revision: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Output {
    handle: Handle,
    budget_ms: u64,
    stream: String,
    offset: usize,
    max_bytes: usize,
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
    phase: Phase,
    revision: u64,
    exec: &'static str,
    exit: Option<Value>,
    helper_failed: bool,
    network_cleanup: &'static str,
    trace: Option<Trace>,
    slot: Option<Slot>,
    slot_expires: Option<Instant>,
    slot_expired: bool,
    memory_limit_bytes: u64,
    cancelled: bool,
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
}

#[derive(Default)]
struct Ledger {
    highest_sequence: u64,
    closing: bool,
    waiting: usize,
    record: Option<Record>,
    pressure: bool,
    evictions: u64,
}

impl Ledger {
    fn memory_snapshot(&self) -> Value {
        let available = crate::memory::available_bytes();
        let mut snapshot = json!({
            "active": null, "prepared": null,
            "pressure": self.pressure || crate::memory::pressures_reserve(available),
            "requested_pressure": self.pressure, "available_bytes": available,
            "prepared_floor_bytes": crate::memory::MIN_AVAILABLE_BYTES,
            "pressure_evictions": self.evictions,
        });
        if let Some(record) = self
            .record
            .as_ref()
            .filter(|record| record.phase != Phase::Removed)
        {
            let prepared_scope = record.slot.is_some();
            let active = record.slot.as_ref().is_none_or(Slot::claimed);
            let observed = crate::kernel_fixture::cgroup_observation(
                &record.handle.workload_id,
                prepared_scope,
            )
            .ok();
            snapshot[if active { "active" } else { "prepared" }] = json!({
                "handle": record.handle, "phase": record.phase.name(),
                "scope": if prepared_scope { "prepared" } else { "active" },
                "limit_bytes": record.memory_limit_bytes,
                "sample_valid": observed.is_some(),
                "current_bytes": observed.map(|(bytes, _)| bytes),
                "populated": observed.map(|(_, populated)| populated),
            });
        }
        snapshot
    }

    fn set_pressure(&mut self, pressure: bool) {
        self.pressure = pressure;
        if pressure
            && let Some(record) = &mut self.record
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
    trace_benchmark: bool,
    bridge_available: bool,
    allow_crash: bool,
    intent: Intent,
    ledger: Mutex<Ledger>,
    changed: Condvar,
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
        if intent.read()?.is_some() {
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
            trace_benchmark,
            bridge_available,
            allow_crash,
            intent,
            ledger: Mutex::new(Ledger::default()),
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

    fn update(&self, f: impl FnOnce(&mut Record)) {
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        if let Some(record) = &mut ledger.record {
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
                && spec.network == "none"
                && spec.limits == crate::spec::NATIVE_LIMITS
                && !prepared =>
            {
                "native-oci"
            }
            _ if self.oci => {
                return Err((
                    "unsupported_option",
                    "OCI requires a fresh, constrained no-network launch",
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
        if (mode != "benchmark" && spec.image_digest != self.image_digest)
            || (!self.oci && (spec.cwd != "/work" || !spec.env.is_empty()))
        {
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
        if bridge && !self.bridge_available {
            return Err((
                "unsupported_option",
                "private bridge unavailable in this guest",
            ));
        }
        if bridge
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
        if let Some(record) = &ledger.record {
            if record.sequence == request.sequence {
                if record.body != body {
                    return Err(("id_conflict", "sequence has a different admitted request"));
                }
                return Ok((Kind::State, record.state()));
            }
            if !record.phase.terminal() || record.phase == Phase::CleanupFailed {
                return Err((
                    "busy",
                    "native service already owns a workload or unresolved cleanup",
                ));
            }
        }
        if ledger.closing {
            return Err(("busy", "fresh fixture is draining"));
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
            phase: Phase::Accepted,
            revision: 1,
            exec: "pending",
            exit: None,
            helper_failed: false,
            network_cleanup: if bridge { "pending" } else { "not_applicable" },
            trace: (benchmark && self.trace_benchmark).then(|| Trace {
                admitted: Instant::now(),
                events: BTreeMap::new(),
            }),
            slot: prepared.then(|| Slot::new(spec_digest(spec))),
            slot_expires: prepared.then(|| Instant::now() + SLOT_TTL),
            slot_expired: false,
            memory_limit_bytes: spec.limits.memory_bytes,
            cancelled: false,
            control: None,
            stdout: Capture::default(),
            stderr: Capture::default(),
        };
        let reply = record.state();
        ledger.highest_sequence = request.sequence;
        ledger.record = Some(record);
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
            let record = ledger.record.as_mut().expect("reserved record");
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
        &self,
        id: [u8; 16],
        limits: crate::spec::ResourceLimits,
        mode: &str,
        bridge: bool,
        prepared: bool,
        oci_process: Option<&str>,
    ) {
        {
            let mut ledger = self.ledger.lock().expect("fresh ledger");
            let record = ledger.record.as_mut().expect("admitted workload");
            if record.cancelled {
                record.exec = "failed";
                if bridge {
                    record.network_cleanup = "complete";
                }
                record.change(Phase::Removed);
                self.changed.notify_all();
                return;
            }
        }
        let result = self.intent.record(id).and_then(|()| {
            let output = self.run_helper(id, limits, mode, bridge, prepared, oci_process)?;
            self.intent.complete(id)?;
            Ok(output)
        });
        if let Err(error) = &result {
            eprintln!("fresh fixture did not confirm cleanup: {error}");
        }
        self.update(|record| {
            record.control = None;
            if let Some(slot) = &mut record.slot {
                slot.discard();
            }
            if let Ok((stdout, stderr, recovered)) = result {
                record.stdout = stdout;
                record.stderr = stderr;
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
        &self,
        id: [u8; 16],
        limits: crate::spec::ResourceLimits,
        mode: &str,
        bridge: bool,
        prepared: bool,
        oci_process: Option<&str>,
    ) -> io::Result<(Capture, Capture, bool)> {
        let (mut peer, helper) = UnixStream::pair()?;
        peer.set_read_timeout(Some(Duration::from_secs(32)))?;
        let owner = peer.try_clone()?;
        let mut child = Command::new("/init")
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
        let out = child.stdout.take().expect("piped stdout");
        let err = child.stderr.take().expect("piped stderr");
        let stdout = thread::spawn(move || capture(out));
        let stderr = thread::spawn(move || capture(err));
        self.update(|record| {
            record.control = Some(owner);
            if record.cancelled {
                let _ = record.control.as_mut().unwrap().write_all(&[CANCEL]);
            }
        });
        let mut removed = false;
        let mut exit_received = false;
        let mut network_removed = !bridge;
        let result = (|| -> io::Result<()> {
            let mut code = [0];
            while peer.read(&mut code)? == 1 {
                match code[0] {
                    b'P' => self.update(|record| {
                        if !record.cancelled {
                            record.change(Phase::Preparing);
                        }
                    }),
                    b'C' => self.update(|record| {
                        if !record.cancelled {
                            record.change(Phase::ChildCreated);
                        }
                    }),
                    b'Q' if prepared => self.update(|record| {
                        if !record.cancelled
                            && let (Some(slot), Some(expires)) =
                                (&mut record.slot, record.slot_expires)
                        {
                            slot.ready(expires);
                            record.change(Phase::PreparedReady);
                        }
                    }),
                    b'T' if prepared => self.update(|record| {
                        record.slot_expired = true;
                        record.slot.as_mut().expect("prepared record").discard();
                        record.change(Phase::Exiting);
                    }),
                    b'M' if prepared => {
                        let mut ledger = self.ledger.lock().expect("fresh ledger");
                        let record = ledger.record.as_mut().expect("prepared record");
                        if !record.cancelled {
                            record.cancelled = true;
                            let slot = record.slot.as_mut().expect("prepared slot");
                            slot.discard();
                            record.change(Phase::Exiting);
                            ledger.evictions = ledger.evictions.saturating_add(1);
                            self.changed.notify_all();
                        }
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
                        self.update(|record| {
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
                        self.update(|record| {
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
                        self.update(|record| record.change(Phase::Cleaning));
                    }
                    b'B' if exit_received && !network_removed => {
                        network_removed = true;
                        self.update(|record| {
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
            self.update(|record| record.control = None);
            child.kill()?;
        }
        let finished = child.wait()?;
        let recovered = result.is_err() || !finished.success() || !removed;
        if recovered {
            crate::kernel_fixture::recover_cgroup(id)?;
            crate::recovery_fixture::reap_owned_children(-1)?;
            crate::sandbox_fixture::recover()?;
            println!("conjet-launchd recovered helper failure for {}", hex(&id));
        }
        let stdout = stdout
            .join()
            .map_err(|_| io::Error::other("stdout reader failed"))??;
        let stderr = stderr
            .join()
            .map_err(|_| io::Error::other("stderr reader failed"))??;
        Ok((stdout, stderr, recovered))
    }

    fn operation(self: &Arc<Self>, frame: &Frame, boot: &str) -> Reply {
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
                .record
                .as_ref()
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
                let record = guard.record.as_mut().expect("checked record");
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
                        "workload": guard.record.as_ref().map(Record::state),
                    }),
                ))
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
                if let Some(pressure) = request.pressure {
                    guard.set_pressure(pressure);
                    self.changed.notify_all();
                }
                Ok((Kind::Memory, guard.memory_snapshot()))
            }
            Kind::Status | Kind::Cancel => {
                let request: Control = parse(frame)?;
                deadline(request.budget_ms)?;
                check(&guard, &request.handle)?;
                let record = guard.record.as_mut().expect("checked record");
                if frame.kind == Kind::Cancel {
                    record.cancel();
                    self.changed.notify_all();
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
                    let record = guard.record.as_ref().expect("checked record");
                    if record.revision > request.after_revision || record.phase.terminal() {
                        break Ok((Kind::State, record.state()));
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
                deadline(request.budget_ms)?;
                check(&guard, &request.handle)?;
                let record = guard.record.as_ref().expect("checked record");
                let output = match request.stream.as_str() {
                    "stdout" => &record.stdout,
                    "stderr" => &record.stderr,
                    _ => return Err(("malformed", "invalid output stream")),
                };
                if request.offset > output.bytes.len() || !(1..=8192).contains(&request.max_bytes) {
                    return Err(("malformed", "invalid output cursor or reply bound"));
                }
                let next = (request.offset + request.max_bytes).min(output.bytes.len());
                let bytes = &output.bytes[request.offset..next];
                Ok((
                    Kind::OutputChunk,
                    json!({
                        "offset": request.offset, "next_offset": next,
                        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
                        "eof": record.phase.terminal() && next == output.bytes.len(),
                        "dropped_bytes": output.dropped,
                    }),
                ))
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
    ) -> Result<(), WireError> {
        let reply = self.operation(&frame, boot);
        stream.deadline(Some(Instant::now() + Duration::from_secs(2)));
        match reply {
            Ok((kind, reply)) => Frame::write(stream, kind, frame.id, &reply),
            Err((code, message)) => write_error(stream, frame.id, code, message),
        }
    }

    pub(crate) fn drain(&self, deadline: Instant) -> bool {
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        ledger.closing = true;
        while let Some(record) = &mut ledger.record {
            if record.phase.terminal() {
                return record.phase == Phase::Removed;
            }
            record.cancel();
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
        true
    }
}

fn spec_digest(spec: &LaunchSpec) -> [u8; 32] {
    Sha256::digest(serde_json::to_vec(spec).expect("typed specification")).into()
}

use std::fs::{File, OpenOptions, Permissions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context};
use clap::{Args, ValueEnum};
use conjet_launch_service::handshake::{hex, random, unhex};
use conjet_launch_service::{core_admission, wire::Kind};
use jetstream::hvf::native_memory::NativeMemoryAdmission;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256, Sha512};

use super::client;
use super::volume_disk::VolumeDisk;
use crate::{HvfBootOptions, JetstreamConfig, MachineBuilder};
use jetstream::vmm::config::BootSource;

pub(super) const ENDPOINT: &str = "native-launch.sock";
pub(super) const KEY: &str = "launch.key";
pub(super) const MANIFEST: &str = "native-session.json";
pub(super) const LOCK: &str = "admission.lock";
const WORKLOAD_LIMIT: u64 = 4 * 1024 * 1024;
static INTERRUPTED: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Args)]
pub(super) struct Options {
    /// Existing directory in which to create a temporary private session.
    #[arg(long)]
    pub(super) scratch: PathBuf,
    /// Maximum guest memory; Core continues to grow and reclaim within this ceiling.
    #[arg(long, default_value_t = 2048, value_parser = clap::value_parser!(u64).range(512..=8192))]
    memory_mib: u64,
    /// Verified Conjet Core AArch64 Linux Image.
    #[arg(long)]
    kernel: PathBuf,
    /// Expected SHA-512 of the trusted Core release kernel.
    #[arg(long)]
    kernel_sha512: String,
    /// Static Linux ARM64 executable to run without arguments.
    #[arg(
        long,
        required_unless_present = "oci_package",
        conflicts_with = "oci_package"
    )]
    executable: Option<PathBuf>,
    /// Experimental preverified Linux ARM64 OCI staging package.
    #[arg(long, value_name = "PATH")]
    pub(super) oci_package: Option<PathBuf>,
    /// Expected SHA-256 of the executable or OCI staging package.
    #[arg(long)]
    sha256: String,
    /// Trusted branch-built guest supervisor, for development builds.
    #[arg(long)]
    guest_init: Option<PathBuf>,
    /// Trusted static Core memory service for a native telemetry canary.
    #[arg(long, requires_all = ["guest_reclaimd", "oci_package"])]
    guest_memd: Option<PathBuf>,
    /// Trusted static Core reclaim helper paired with the memory service.
    #[arg(long, requires = "guest_memd")]
    guest_reclaimd: Option<PathBuf>,
    /// Enable the Core controller and require its per-workload admission grant.
    #[arg(long, requires = "guest_memd")]
    core_dynamic_memory: bool,
    /// Collect bounded host and guest Core latency spans for diagnostics.
    #[arg(long, requires = "core_dynamic_memory")]
    trace_core_admission: bool,
    /// Select the admission delivery mechanism for isolated comparison.
    #[arg(
        long,
        value_enum,
        default_value = "event",
        requires = "core_dynamic_memory"
    )]
    core_admission_wake: AdmissionWake,
    /// Set a diagnostic pending-discovery interval for an isolated release comparison.
    #[arg(long, value_enum, requires = "trace_core_admission")]
    core_discovery_ms: Option<DiscoveryCadence>,
    /// Select periodic or authenticated event-driven pending discovery.
    #[arg(long, value_enum, requires = "core_dynamic_memory")]
    core_discovery_mode: Option<DiscoveryMode>,
    /// Select the VMM evaluation wake for isolated A/B qualification.
    #[arg(long, value_enum, requires = "core_dynamic_memory")]
    core_evaluation_mode: Option<EvaluationMode>,
    /// Enable the bounded service pressure fixture on this diagnostic boot.
    #[arg(long, requires = "core_dynamic_memory")]
    core_pressure_fixture: bool,
    /// Exclusively leased ext4 disk for the isolated native Core guest.
    #[arg(long, requires = "core_dynamic_memory")]
    volume_disk: Option<PathBuf>,
    /// Mount the leased disk as a private BuildKit workspace for diagnostics.
    #[arg(long, requires = "volume_disk")]
    build_snapshot_disk: bool,
    /// Stage transferred OCI roots on the isolated Core guest's leased filesystem.
    #[arg(long, requires = "volume_disk")]
    disk_image_store: bool,
    /// Admit an authenticated host filesystem relay for isolated bind mounts.
    #[arg(long, requires = "core_dynamic_memory")]
    bind_filesystem: bool,
    /// Maximum lifetime of the disposable VM.
    #[arg(long, default_value_t = 600, value_parser = clap::value_parser!(u64).range(30..=1800))]
    lifetime_seconds: u64,
}

struct MemoryHelpers {
    memd: Vec<u8>,
    reclaimd: Vec<u8>,
    core_admission: bool,
    core_pressure_fixture: bool,
    trace_core_admission: bool,
}

struct GuestBootFiles<'a> {
    memory: Option<&'a MemoryHelpers>,
    disk: Option<GuestDisk>,
    bind_filesystem: bool,
}

struct GuestDisk {
    volume: [u8; 24],
    build_workspace: bool,
    image_store: bool,
}

struct AdmissionControl<'a> {
    gate: &'a NativeMemoryAdmission,
    trace: bool,
    wake: AdmissionWake,
    cadence: DiscoveryCadence,
    discovery: DiscoveryMode,
}

#[derive(Clone, Copy)]
enum SessionOwner {
    Foreground(u64),
    Supervisor(libc::pid_t),
}

const TRACE_LIMIT: usize = 8192;

struct AdmissionTrace {
    origin: Instant,
    host_clock_ns: Option<u64>,
    rows: Vec<AdmissionSpan>,
    lost: usize,
    polls: usize,
    polls_by_second: Vec<usize>,
    cadence: DiscoveryCadence,
    discovery: DiscoveryMode,
}

#[derive(Serialize)]
#[serde(tag = "event")]
enum AdmissionSpan {
    #[serde(rename = "core_observation")]
    Observation {
        boot_id: String,
        id: String,
        sequence: u64,
        h0_ns: u128,
        h1_ns: u128,
        owned: usize,
        pending: usize,
        watch_pending: bool,
    },
    #[serde(rename = "core_admission")]
    Grant {
        boot_id: String,
        id: String,
        sequence: u64,
        h1_ns: u128,
        h2_ns: u128,
        first_evaluated_ns: Option<u128>,
        capacity_held: bool,
        h3_ns: u128,
        observed_to_approval_ns: u128,
        approval_to_send_ns: u128,
        reply_ns: u128,
        accepted: bool,
    },
}

impl AdmissionTrace {
    fn new(control: &AdmissionControl<'_>) -> Self {
        Self {
            origin: Instant::now(),
            host_clock_ns: host_monotonic_ns(),
            rows: Vec::with_capacity(TRACE_LIMIT),
            lost: 0,
            polls: 0,
            polls_by_second: Vec::new(),
            cadence: control.cadence,
            discovery: control.discovery,
        }
    }

    fn push(&mut self, row: AdmissionSpan) {
        if self.rows.len() < TRACE_LIMIT {
            self.rows.push(row);
        } else {
            self.lost += 1;
        }
    }

    fn ns(&self, stamp: Instant) -> u128 {
        stamp.saturating_duration_since(self.origin).as_nanos()
    }

    fn record_poll(&mut self, stamp: Instant) {
        self.polls += 1;
        let second = stamp.saturating_duration_since(self.origin).as_secs() as usize;
        if second < 1_825 {
            if self.polls_by_second.len() <= second {
                self.polls_by_second.resize(second + 1, 0);
            }
            self.polls_by_second[second] += 1;
        }
    }
}

impl Drop for AdmissionTrace {
    fn drop(&mut self) {
        let mut output = std::io::stderr().lock();
        for row in &self.rows {
            let _ = serde_json::to_writer(&mut output, row);
            let _ = writeln!(output);
        }
        let _ = writeln!(
            output,
            "{}",
            json!({
                "event": "core_trace_summary", "rows": self.rows.len(), "lost": self.lost,
                "polls": self.polls,
                "discovery_interval_ms": self.cadence.interval().as_millis(),
                "discovery_mode": self.discovery,
                "host_clock_ns": self.host_clock_ns,
                "polls_by_second": self.polls_by_second,
            })
        );
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum AdmissionWake {
    Poll,
    Event,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, ValueEnum, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryMode {
    Poll,
    #[default]
    Watch,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, ValueEnum)]
enum EvaluationMode {
    Tick,
    #[default]
    Wake,
}

impl AdmissionControl<'_> {
    fn can_watch(&self, peer: &client::Connection) -> bool {
        self.discovery == DiscoveryMode::Watch
            && matches!(self.cadence, DiscoveryCadence::Normal)
            && matches!(self.wake, AdmissionWake::Event)
            && peer.pending_watch
    }
}

#[derive(Clone, Copy, Debug, Default, ValueEnum)]
enum DiscoveryCadence {
    #[value(name = "30")]
    #[default]
    Normal,
    #[value(name = "5")]
    Fast,
}

impl DiscoveryCadence {
    fn interval(self) -> Duration {
        Duration::from_millis(match self {
            Self::Normal => core_admission::PENDING_WATCH_MS,
            Self::Fast => 5,
        })
    }
}

pub(super) fn host_monotonic_ns() -> Option<u64> {
    let mut stamp = std::mem::MaybeUninit::<libc::timespec>::uninit();
    // The diagnostic client reads this same macOS clock for the API boundary.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, stamp.as_mut_ptr()) } != 0 {
        return None;
    }
    let stamp = unsafe { stamp.assume_init() };
    Some(stamp.tv_sec as u64 * 1_000_000_000 + stamp.tv_nsec as u64)
}

fn default_memory_mib() -> u64 {
    2048
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Identity {
    #[serde(default = "default_memory_mib")]
    pub(super) memory_mib: u64,
    pub(super) pid: libc::pid_t,
    pub(super) image_digest: String,
}

extern "C" fn interrupted(_: libc::c_int) {
    INTERRUPTED.store(true, Ordering::Release);
}

pub(super) fn serve(
    options: Options,
    docker_root: Option<&Path>,
    parent: Option<libc::pid_t>,
) -> anyhow::Result<()> {
    ensure!(
        !options.core_pressure_fixture
            || options.volume_disk.is_none()
            || (parent.is_some()
                && docker_root
                    .is_some_and(|root| { root.starts_with(super::docker::COMPARISON_SCRATCH) })),
        "the Core pressure fixture can share a volume disk only in a managed qualification profile"
    );
    let kernel_expected = unhex::<64>(&options.kernel_sha512).context("invalid kernel SHA-512")?;
    let expected = unhex::<32>(&options.sha256).context("invalid executable SHA-256")?;
    let (workload, oci, image_digest) = if let Some(path) = options.oci_package {
        let package = read_regular(&path, super::oci::PACKAGE_LIMIT)?;
        ensure!(
            Sha256::digest(&package)[..] == expected,
            "OCI staging package SHA-256 mismatch"
        );
        let root = super::oci::Root::read(&package)?;
        let image_digest = root.config_digest.clone();
        (Vec::new(), Some(root), image_digest)
    } else {
        let path = options
            .executable
            .as_ref()
            .context("missing workload executable")?;
        let workload = read_regular(path, WORKLOAD_LIMIT)?;
        ensure!(
            Sha256::digest(&workload)[..] == expected,
            "workload SHA-256 mismatch"
        );
        validate_executable(&workload)?;
        (workload, None, format!("sha256:{}", hex(&expected)))
    };
    let guest_path = match options.guest_init {
        Some(path) => path,
        None => std::env::current_exe()?.with_file_name("conjet-launchd-linux-arm64"),
    };
    let guest = read_regular(&guest_path, WORKLOAD_LIMIT).with_context(|| {
        format!(
            "trusted native guest supervisor missing at {}",
            guest_path.display()
        )
    })?;
    validate_executable(&guest).context("invalid guest supervisor")?;
    let memory_helpers = options
        .guest_memd
        .zip(options.guest_reclaimd)
        .map(|(memd, reclaimd)| -> anyhow::Result<_> {
            let memd = read_regular(&memd, WORKLOAD_LIMIT)?;
            let reclaimd = read_regular(&reclaimd, WORKLOAD_LIMIT)?;
            validate_executable(&memd).context("invalid Core memory service")?;
            validate_executable(&reclaimd).context("invalid Core reclaim helper")?;
            Ok(MemoryHelpers {
                memd,
                reclaimd,
                core_admission: options.core_dynamic_memory,
                core_pressure_fixture: options.core_pressure_fixture,
                trace_core_admission: options.trace_core_admission,
            })
        })
        .transpose()?;
    let kernel = read_regular(&options.kernel, 64 * 1024 * 1024)?;
    ensure!(
        Sha512::digest(&kernel)[..] == kernel_expected,
        "Core kernel SHA-512 mismatch"
    );
    let scratch = options.scratch.canonicalize()?;
    ensure!(scratch.is_dir(), "scratch must be a directory");
    let volume = options
        .volume_disk
        .map(|path| {
            VolumeDisk::lease(
                path,
                &scratch,
                docker_root,
                options.disk_image_store,
                options.build_snapshot_disk,
            )
        })
        .transpose()?;
    let session = tempfile::Builder::new()
        .prefix("cn-")
        .permissions(Permissions::from_mode(0o700))
        .tempdir_in(&scratch)?;
    let directory = session.path();
    ensure!(
        directory.join(ENDPOINT).as_os_str().len() < 104,
        "scratch path leaves no room for the private Unix socket"
    );
    let key = random::<32>()?;
    let identity = Identity {
        memory_mib: options.memory_mib,
        pid: std::process::id().try_into()?,
        image_digest,
    };
    private_file(&directory.join(KEY), &key)?;
    private_file(&directory.join(LOCK), &[])?;
    private_file(&directory.join(MANIFEST), &serde_json::to_vec(&identity)?)?;
    private_file(&directory.join("Image"), &kernel)?;
    File::create(directory.join("blank.raw"))?.set_len(16 * 1024 * 1024)?;
    let descriptor = serde_json::to_vec(&json!({
        "architecture": "arm64", "os": "linux", "executable_sha256": options.sha256,
    }))?;
    build_archive(
        &directory.join("init.cpio"),
        &guest,
        &workload,
        &descriptor,
        &key,
        oci.as_ref(),
        GuestBootFiles {
            memory: memory_helpers.as_ref(),
            bind_filesystem: options.bind_filesystem,
            disk: volume.as_ref().map(|disk| GuestDisk {
                volume: disk.identity.encode(),
                build_workspace: options.build_snapshot_disk,
                image_store: options.disk_image_store,
            }),
        },
    )?;
    let machine = MachineBuilder::new(JetstreamConfig {
        memory_mib: options.memory_mib,
        vcpu_count: 2,
        boot_source: BootSource {
            name: if parent.is_some() {
                "native-docker"
            } else {
                "experimental-native"
            }
            .into(),
            kernel_path: directory.join("Image"),
            initrd_path: Some(directory.join("init.cpio")),
            root_disk_path: directory.join("blank.raw"),
            data_disk_path: volume.as_ref().map(|disk| disk.path.clone()),
            swap_disk_path: None,
            serial_log_path: directory.join("serial.log"),
            docker_socket_path: directory.join("unused.sock"),
            cmdline: "console=ttyAMA0 rdinit=/init --serve-native quiet".into(),
        },
    })
    .build()?;
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        // The handler only sets a lock-free flag. HVF and file operations
        // remain on their normal threads.
        if unsafe { libc::signal(signal, interrupted as *const () as libc::sighandler_t) }
            == libc::SIG_ERR
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    let force_stop = Arc::new(AtomicBool::new(false));
    let admission = options.core_dynamic_memory.then(|| {
        Arc::new(NativeMemoryAdmission::new(
            options.trace_core_admission,
            options.core_evaluation_mode.unwrap_or_default() == EvaluationMode::Wake,
        ))
    });
    let finished = AtomicBool::new(false);
    let owner = parent.map_or(
        SessionOwner::Foreground(options.lifetime_seconds),
        SessionOwner::Supervisor,
    );
    let orderly = std::thread::scope(|scope| -> anyhow::Result<bool> {
        let control_stop = Arc::clone(&force_stop);
        let finished_signal = &finished;
        let session_identity = &identity;
        let admission_control = admission.as_deref().map(|gate| AdmissionControl {
            gate,
            trace: options.trace_core_admission,
            wake: options.core_admission_wake,
            cadence: options.core_discovery_ms.unwrap_or_default(),
            discovery: options.core_discovery_mode.unwrap_or_default(),
        });
        let boot_gate = admission.clone();
        let control = scope.spawn(move || {
            manage_session(
                directory,
                session_identity,
                &key,
                finished_signal,
                &control_stop,
                owner,
                admission_control,
            )
        });
        let report = machine.run(HvfBootOptions {
            max_exits: u64::MAX,
            max_runtime_ms: match owner {
                SessionOwner::Supervisor(_) => 0,
                SessionOwner::Foreground(seconds) => (seconds + 12) * 1_000,
            },
            host_tick_ms: 25,
            require_conjet_ready: false,
            enable_native_launch: true,
            native_airgap: true,
            enable_native_memory_bridge: memory_helpers.is_some(),
            native_memory_admission: boot_gate,
            leased_data_disk: volume.as_ref().map(|disk| Arc::clone(&disk.file)),
            memory_control_socket: options
                .core_dynamic_memory
                .then(|| directory.join("memory-control.sock")),
            external_stop: Some(force_stop),
            ..Default::default()
        });
        finished.store(true, Ordering::Release);
        let manager = control
            .join()
            .map_err(|_| anyhow::anyhow!("session manager failed"))?;
        if !report.ok || report.message != "guest requested PSCI SYSTEM_OFF" {
            let diagnostics = report
                .stages
                .iter()
                .filter(|stage| !stage.ok)
                .map(|stage| format!("{}: {}", stage.name, stage.detail))
                .collect::<Vec<_>>()
                .join(", ");
            bail!(
                "native VM did not confirm shutdown: {}. {} {}",
                report.message,
                diagnostics,
                report.console_output
            );
        }
        let orderly = manager?;
        if let Some(volume) = &volume {
            volume
                .file
                .sync_all()
                .context("flush leased volume after guest shutdown")?;
        }
        let mut output = std::io::stdout().lock();
        writeln!(
            output,
            "{}",
            json!({
                "event": "shutdown", "guest_cleanup": "complete",
                "free_page_reporting": report.balloon.page_reporting_negotiated,
                "reported_free_bytes": report.balloon.reported_free_bytes,
                "reported_free_reclaimed_bytes": report.balloon.reported_free_reclaimed_bytes,
                "reclaim_failures": report.balloon.reclaim_failures,
            })
        )?;
        Ok(orderly)
    })?;
    ensure!(
        orderly,
        "native session did not reach authenticated readiness"
    );
    ensure!(
        !directory.join(ENDPOINT).exists(),
        "native endpoint remained after VM shutdown"
    );
    session.close()?;
    Ok(())
}

fn manage_session(
    directory: &Path,
    identity: &Identity,
    key: &[u8; 32],
    finished: &AtomicBool,
    force_stop: &AtomicBool,
    owner: SessionOwner,
    admission: Option<AdmissionControl<'_>>,
) -> anyhow::Result<bool> {
    let mut trace = admission
        .as_ref()
        .filter(|control| control.trace)
        .map(AdmissionTrace::new);
    let start = Instant::now();
    let startup = start + Duration::from_secs(15);
    let deadline = match owner {
        SessionOwner::Foreground(seconds) => Some(start + Duration::from_secs(seconds)),
        SessionOwner::Supervisor(_) => None,
    };
    let mut ready = false;
    let mut admission_boot = None;
    let mut admission_peer = None;
    let mut pending = false;
    while !finished.load(Ordering::Acquire) {
        let mut authenticated = false;
        let connect = !ready || (admission.is_some() && admission_peer.is_none());
        if let Some(mut peer) = connect
            .then(|| client::Connection::open(directory, identity, key).ok())
            .flatten()
        {
            if let Some(control) = &admission {
                if admission_boot
                    .as_ref()
                    .is_some_and(|boot| boot != &peer.boot)
                {
                    control.gate.invalidate();
                    force_stop.store(true, Ordering::Release);
                    bail!("native admission supervisor generation changed");
                }
                if let Ok(has_pending) =
                    poll_native_admission(&mut peer, control, trace.as_mut(), false)
                {
                    admission_boot = Some(peer.boot.clone());
                    admission_peer = Some(peer);
                    authenticated = true;
                    pending = has_pending;
                }
            } else {
                authenticated = true;
            }
        }
        if !ready && authenticated {
            let mut output = std::io::stdout().lock();
            if let Err(error) = writeln!(
                output,
                "{}",
                json!({
                    "experimental": matches!(owner, SessionOwner::Foreground(_)),
                    "owner": "native", "session": directory,
                    "pid": identity.pid, "image_digest": identity.image_digest,
                })
            )
            .and_then(|()| output.flush())
            {
                force_stop.store(true, Ordering::Release);
                return Err(error.into());
            }
            ready = true;
        }
        if INTERRUPTED.load(Ordering::Acquire)
            || matches!(owner, SessionOwner::Supervisor(pid) if unsafe { libc::getppid() } != pid)
            || (if ready { deadline } else { Some(startup) })
                .is_some_and(|limit| Instant::now() >= limit)
        {
            if client::stop_with_identity(directory, identity, key).is_err() {
                force_stop.store(true, Ordering::Release);
            } else {
                let poweroff = Instant::now() + Duration::from_secs(5);
                while !finished.load(Ordering::Acquire) && Instant::now() < poweroff {
                    std::thread::sleep(Duration::from_millis(25));
                }
                if !finished.load(Ordering::Acquire) {
                    force_stop.store(true, Ordering::Release);
                }
            }
            break;
        }
        if let (Some(control), Some(peer)) = (&admission, admission_peer.as_mut()) {
            let can_watch = control.can_watch(peer);
            match poll_native_admission(peer, control, trace.as_mut(), can_watch && !pending) {
                Ok(has_pending) => {
                    pending = has_pending;
                    if can_watch && !pending {
                        // One owner uses request/reply on this stream. With no
                        // demand awaiting approval, start a bounded watch.
                        continue;
                    }
                }
                Err(_) => {
                    control.gate.invalidate();
                    admission_peer = None;
                }
            }
        }
        match &admission {
            Some(control) if matches!(control.wake, AdmissionWake::Event) => {
                control.gate.wait_for_approval(control.cadence.interval());
            }
            Some(control) => std::thread::sleep(control.cadence.interval()),
            None => std::thread::sleep(Duration::from_millis(100)),
        }
    }
    Ok(ready)
}

fn poll_native_admission(
    peer: &mut client::Connection,
    control: &AdmissionControl<'_>,
    mut trace: Option<&mut AdmissionTrace>,
    watch_pending: bool,
) -> anyhow::Result<bool> {
    let request = |grant: Option<&core_admission::Admission>, boot: &str| {
        json!({
            "boot_id": boot, "budget_ms": 150, "core_only": true, "core_grant": grant,
        })
    };
    let timeout = Duration::from_millis(150);
    for grant in control.gate.take_grants(Instant::now()) {
        // Cancellation or deadline can win after the observation. Only the
        // guest authority can grant the exact live ID.
        let sent = Instant::now();
        let result = peer.exchange(
            Kind::Memory,
            Kind::Memory,
            &request(Some(&grant.admission), &peer.boot),
            timeout,
        );
        if let Some(trace) = trace.as_mut() {
            trace.push(AdmissionSpan::Grant {
                boot_id: peer.boot.clone(),
                id: grant.admission.workload_id,
                sequence: grant.admission.sequence,
                h1_ns: trace.ns(grant.observed_at),
                h2_ns: trace.ns(grant.approved_at),
                first_evaluated_ns: grant.first_evaluated_at.map(|stamp| trace.ns(stamp)),
                capacity_held: grant.capacity_held,
                h3_ns: trace.ns(sent),
                observed_to_approval_ns: grant
                    .approved_at
                    .saturating_duration_since(grant.observed_at)
                    .as_nanos(),
                approval_to_send_ns: sent.saturating_duration_since(grant.approved_at).as_nanos(),
                reply_ns: sent.elapsed().as_nanos(),
                accepted: result.is_ok(),
            });
        }
        match result {
            Ok(_) | Err(conjet_launch_service::wire::WireError::PeerError(_)) => {}
            Err(error) => return Err(error.into()),
        }
    }
    let request = if watch_pending {
        json!({
            "boot_id": peer.boot, "budget_ms": core_admission::PENDING_WATCH_MS,
            "core_only": true, "watch_pending": true,
        })
    } else {
        request(None, &peer.boot)
    };
    let sent = trace.as_ref().map(|_| Instant::now());
    let value = peer.exchange(Kind::Memory, Kind::Memory, &request, timeout)?;
    let report: core_admission::Observation =
        serde_json::from_value(value["core_admission"].clone())?;
    let has_pending = !report.pending.is_empty();
    let received = Instant::now();
    if let (Some(trace), Some(sent)) = (trace, sent) {
        trace.record_poll(received);
        for pending in &report.pending {
            trace.push(AdmissionSpan::Observation {
                boot_id: peer.boot.clone(),
                id: pending.workload_id.clone(),
                sequence: pending.sequence,
                h0_ns: trace.ns(sent),
                h1_ns: trace.ns(received),
                owned: report.owned,
                pending: report.pending.len(),
                watch_pending,
            });
        }
    }
    ensure!(
        control.gate.publish(report, received),
        "invalid native admission observation"
    );
    Ok(has_pending)
}

fn read_regular(path: &Path, limit: u64) -> anyhow::Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let info = file.metadata()?;
    ensure!(
        info.is_file() && info.len() <= limit,
        "invalid or oversized file {}",
        path.display()
    );
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(
        (bytes.len() as u64) <= limit,
        "oversized file {}",
        path.display()
    );
    Ok(bytes)
}

fn private_file(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?
        .write_all(bytes)?;
    Ok(())
}

fn validate_executable(elf: &[u8]) -> anyhow::Result<()> {
    ensure!(
        elf.len() >= 64 && elf[..7] == *b"\x7fELF\x02\x01\x01",
        "expected little-endian ELF64"
    );
    let u16_at = |start| u16::from_le_bytes(elf[start..start + 2].try_into().unwrap());
    ensure!(
        matches!(u16_at(16), 2 | 3) && u16_at(18) == 183,
        "expected a Linux ARM64 executable"
    );
    let offset = usize::try_from(u64::from_le_bytes(elf[32..40].try_into()?))?;
    let entry = usize::from(u16_at(54));
    let count = usize::from(u16_at(56));
    let size = entry * count;
    let table = elf
        .get(
            offset
                ..offset
                    .checked_add(size)
                    .context("oversized ELF program table")?,
        )
        .context("truncated ELF program header table")?;
    ensure!(
        entry == 56 && count > 0 && offset >= 64,
        "invalid ELF program header table"
    );
    let mut loadable = false;
    for header in table.chunks_exact(entry) {
        let kind = u32::from_le_bytes(header[..4].try_into()?);
        ensure!(
            kind != 3,
            "executable has an interpreter; static linking required"
        );
        if kind == 1 {
            let start = u64::from_le_bytes(header[8..16].try_into()?);
            let size = u64::from_le_bytes(header[32..40].try_into()?);
            ensure!(
                start
                    .checked_add(size)
                    .is_some_and(|end| end <= elf.len() as u64),
                "invalid ELF segment extent"
            );
            loadable = true;
        }
    }
    ensure!(loadable, "ELF requires a loadable segment");
    Ok(())
}

fn build_archive(
    path: &Path,
    guest: &[u8],
    workload: &[u8],
    descriptor: &[u8],
    key: &[u8],
    oci: Option<&super::oci::Root>,
    files: GuestBootFiles<'_>,
) -> anyhow::Result<()> {
    let mut archive = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    let mut inode = 0u32;
    let mut append_entry = |name: &str,
                            mode: u32,
                            data: &[u8],
                            major: u32,
                            minor: u32,
                            uid: u32,
                            gid: u32,
                            link: Option<(u32, u32)>|
     -> std::io::Result<()> {
        inode += 1;
        let (ino, nlink) = link.unwrap_or((inode, 1));
        write!(archive,
            "070701{ino:08x}{mode:08x}{uid:08x}{gid:08x}{nlink:08x}00000000{:08x}0000000000000000{major:08x}{minor:08x}{:08x}00000000",
            data.len(), name.len() + 1
        )?;
        archive.write_all(name.as_bytes())?;
        archive.write_all(&[0; 4][..1 + (4 - (110 + name.len() + 1) % 4) % 4])?;
        archive.write_all(data)?;
        archive.write_all(&[0; 3][..(4 - data.len() % 4) % 4])
    };
    let mut append = |name: &str, mode, data: &[u8], major, minor, uid, gid| {
        append_entry(name, mode, data, major, minor, uid, gid, None)
    };
    for name in [
        "dev",
        "proc",
        "sys",
        "run",
        "run/conjet",
        "etc",
        "etc/conjet",
    ] {
        append(name, 0o040755, &[], 0, 0, 0, 0)?;
    }
    append("dev/console", 0o020600, &[], 5, 1, 0, 0)?;
    append("dev/null", 0o020666, &[], 1, 3, 0, 0)?;
    append("dev/zero", 0o020666, &[], 1, 5, 0, 0)?;
    append("dev/full", 0o020666, &[], 1, 7, 0, 0)?;
    append("dev/random", 0o020666, &[], 1, 8, 0, 0)?;
    append("dev/urandom", 0o020666, &[], 1, 9, 0, 0)?;
    if files.bind_filesystem {
        append("dev/fuse", 0o020600, &[], 10, 229, 0, 0)?;
    }
    append("init", 0o100755, guest, 0, 0, 0, 0)?;
    append("etc/conjet/launch.key", 0o100600, key, 0, 0, 0, 0)?;
    if let Some(helpers) = files.memory {
        append(
            "etc/conjet/conjet-memd",
            0o100500,
            &helpers.memd,
            0,
            0,
            0,
            0,
        )?;
        append(
            "etc/conjet/conjet-reclaimd",
            0o100500,
            &helpers.reclaimd,
            0,
            0,
            0,
            0,
        )?;
        if helpers.core_admission {
            append(
                core_admission::MARKER.trim_start_matches('/'),
                0o100400,
                &[],
                0,
                0,
                0,
                0,
            )?;
        }
        if helpers.trace_core_admission {
            append(
                core_admission::TRACE_MARKER.trim_start_matches('/'),
                0o100400,
                &[],
                0,
                0,
                0,
                0,
            )?;
        }
        if helpers.core_pressure_fixture {
            append(
                core_admission::PRESSURE_MARKER.trim_start_matches('/'),
                0o100400,
                &[],
                0,
                0,
                0,
                0,
            )?;
        }
    }
    if let Some(root) = oci {
        if let Some(disk) = files.disk {
            append(
                conjet_launch_service::volume_disk::MARKER.trim_start_matches('/'),
                0o100400,
                &disk.volume,
                0,
                0,
                0,
                0,
            )?;
            for (enabled, marker) in [
                (
                    disk.build_workspace,
                    conjet_launch_service::build_snapshot::MARKER,
                ),
                (
                    disk.image_store,
                    conjet_launch_service::oci::DISK_STORE_MARKER,
                ),
            ] {
                if !enabled {
                    continue;
                }
                append(marker.trim_start_matches('/'), 0o100400, &[], 0, 0, 0, 0)?;
            }
        }
        append(
            "etc/conjet/native-oci-image",
            0o100400,
            root.config_digest.as_bytes(),
            0,
            0,
            0,
            0,
        )?;
        let groups = root.link_groups();
        if !groups.is_empty() {
            let groups = serde_json::to_vec(&groups)?;
            ensure!(
                groups.len() <= 5 * 1024 * 1024,
                "OCI hard-link manifest exceeds its bound"
            );
            append(
                "etc/conjet/native-oci-hardlinks.json",
                0o100400,
                &groups,
                0,
                0,
                0,
                0,
            )?;
        }
        super::oci::append(root, |name, mode, uid, gid, data, link| {
            append_entry(name, mode, data, 0, 0, uid, gid, link)
        })?;
        append_entry("TRAILER!!!", 0, &[], 0, 0, 0, 0, None)?;
        return Ok(());
    } else {
        append(
            "etc/conjet/native-executable",
            0o100500,
            workload,
            0,
            0,
            0,
            0,
        )?;
        append(
            "etc/conjet/native-image.json",
            0o100400,
            descriptor,
            0,
            0,
            0,
            0,
        )?;
    }
    append("TRAILER!!!", 0, &[], 0, 0, 0, 0)?;
    Ok(())
}

#[cfg(test)]
mod memory_configuration_tests {
    use super::*;
    use clap::Parser;

    #[derive(Parser)]
    struct Command {
        #[command(flatten)]
        options: Options,
    }

    #[test]
    fn boot_archive_provides_verified_standard_devices() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "conjet-devices-{}-{unique}.cpio",
            std::process::id()
        ));
        build_archive(
            &path,
            b"init",
            b"probe",
            b"{}",
            b"key",
            None,
            GuestBootFiles {
                memory: None,
                disk: None,
                bind_filesystem: false,
            },
        )
        .unwrap();
        let bytes = std::fs::read(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        let mut offset = 0;
        let mut devices = std::collections::BTreeMap::new();
        while offset < bytes.len() {
            let header = &bytes[offset..offset + 110];
            assert_eq!(&header[..6], b"070701");
            let field = |index: usize| {
                usize::from_str_radix(
                    std::str::from_utf8(&header[6 + index * 8..14 + index * 8]).unwrap(),
                    16,
                )
                .unwrap()
            };
            let size = field(6);
            let namesize = field(11);
            let name =
                std::str::from_utf8(&bytes[offset + 110..offset + 110 + namesize - 1]).unwrap();
            if name.starts_with("dev/") {
                devices.insert(name.to_owned(), (field(1), field(9), field(10)));
            }
            offset = (offset + 110 + namesize + 3) & !3;
            offset = (offset + size + 3) & !3;
        }
        for (name, minor) in [
            ("null", 3),
            ("zero", 5),
            ("full", 7),
            ("random", 8),
            ("urandom", 9),
        ] {
            assert_eq!(
                devices.get(&format!("dev/{name}")),
                Some(&(0o020666, 1, minor))
            );
        }
    }

    #[test]
    fn native_memory_ceiling_is_bounded_and_retains_legacy_default() {
        let base = [
            "probe",
            "--scratch",
            "/tmp",
            "--kernel",
            "/Image",
            "--kernel-sha512",
            "unused",
            "--executable",
            "/probe",
            "--sha256",
            "unused",
        ];
        assert_eq!(
            Command::try_parse_from(base).unwrap().options.memory_mib,
            2048
        );
        for memory in ["512", "4096", "8192"] {
            assert_eq!(
                Command::try_parse_from(base.into_iter().chain(["--memory-mib", memory]))
                    .unwrap()
                    .options
                    .memory_mib,
                memory.parse::<u64>().unwrap()
            );
        }
        for memory in ["0", "511", "8193"] {
            assert!(
                Command::try_parse_from(base.into_iter().chain(["--memory-mib", memory])).is_err()
            );
        }
        let legacy: Identity =
            serde_json::from_value(json!({"pid":1,"image_digest":"test"})).unwrap();
        assert_eq!(legacy.memory_mib, 2048);
    }
}

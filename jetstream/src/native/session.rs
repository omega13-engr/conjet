use std::fs::{File, OpenOptions, Permissions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context};
use clap::Args;
use conjet_launch_service::handshake::{hex, random, unhex};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256, Sha512};

use super::client;
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
    scratch: PathBuf,
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
    oci_package: Option<PathBuf>,
    /// Expected SHA-256 of the executable or OCI staging package.
    #[arg(long)]
    sha256: String,
    /// Trusted branch-built guest supervisor, for development builds.
    #[arg(long)]
    guest_init: Option<PathBuf>,
    /// Maximum lifetime of the disposable VM.
    #[arg(long, default_value_t = 600, value_parser = clap::value_parser!(u64).range(30..=1800))]
    lifetime_seconds: u64,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Identity {
    pub(super) pid: libc::pid_t,
    pub(super) image_digest: String,
}

extern "C" fn interrupted(_: libc::c_int) {
    INTERRUPTED.store(true, Ordering::Release);
}

pub(super) fn serve(options: Options) -> anyhow::Result<()> {
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
    let kernel = read_regular(&options.kernel, 64 * 1024 * 1024)?;
    ensure!(
        Sha512::digest(&kernel)[..] == kernel_expected,
        "Core kernel SHA-512 mismatch"
    );
    let scratch = options.scratch.canonicalize()?;
    ensure!(scratch.is_dir(), "scratch must be a directory");
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
    )?;
    let machine = MachineBuilder::new(JetstreamConfig {
        memory_mib: 2048,
        vcpu_count: 2,
        boot_source: BootSource {
            name: "experimental-native".into(),
            kernel_path: directory.join("Image"),
            initrd_path: Some(directory.join("init.cpio")),
            root_disk_path: directory.join("blank.raw"),
            data_disk_path: None,
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
    let finished = AtomicBool::new(false);
    let orderly = std::thread::scope(|scope| -> anyhow::Result<bool> {
        let control_stop = Arc::clone(&force_stop);
        let finished_signal = &finished;
        let session_identity = &identity;
        let control = scope.spawn(move || {
            manage_session(
                directory,
                session_identity,
                &key,
                finished_signal,
                &control_stop,
                options.lifetime_seconds,
            )
        });
        let report = machine.run(HvfBootOptions {
            max_exits: u64::MAX,
            max_runtime_ms: (options.lifetime_seconds + 12) * 1_000,
            host_tick_ms: 25,
            require_conjet_ready: false,
            enable_native_launch: true,
            native_airgap: true,
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
    lifetime: u64,
) -> anyhow::Result<bool> {
    let start = Instant::now();
    let startup = start + Duration::from_secs(15);
    let deadline = start + Duration::from_secs(lifetime);
    let mut ready = false;
    while !finished.load(Ordering::Acquire) {
        if !ready && client::Connection::open(directory, identity, key).is_ok() {
            let mut output = std::io::stdout().lock();
            if let Err(error) = writeln!(
                output,
                "{}",
                json!({
                    "experimental": true, "owner": "native", "session": directory,
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
            || Instant::now() >= if ready { deadline } else { startup }
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
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(ready)
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
) -> anyhow::Result<()> {
    let mut archive = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    let mut inode = 0u32;
    let mut append = |name: &str,
                      mode: u32,
                      data: &[u8],
                      major: u32,
                      minor: u32,
                      uid: u32,
                      gid: u32|
     -> std::io::Result<()> {
        inode += 1;
        write!(archive,
            "070701{inode:08x}{mode:08x}{uid:08x}{gid:08x}0000000100000000{:08x}0000000000000000{major:08x}{minor:08x}{:08x}00000000",
            data.len(), name.len() + 1
        )?;
        archive.write_all(name.as_bytes())?;
        archive.write_all(&[0; 4][..1 + (4 - (110 + name.len() + 1) % 4) % 4])?;
        archive.write_all(data)?;
        archive.write_all(&[0; 3][..(4 - data.len() % 4) % 4])
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
    append("init", 0o100755, guest, 0, 0, 0, 0)?;
    append("etc/conjet/launch.key", 0o100600, key, 0, 0, 0, 0)?;
    if let Some(root) = oci {
        append(
            "etc/conjet/native-oci-image",
            0o100400,
            root.config_digest.as_bytes(),
            0,
            0,
            0,
            0,
        )?;
        root.append(|name, mode, uid, gid, data| append(name, mode, data, 0, 0, uid, gid))?;
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

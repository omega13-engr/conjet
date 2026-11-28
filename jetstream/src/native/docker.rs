//! Bounded Docker compatibility endpoint for the isolated OCI candidate.
mod archive;
mod bind;
mod bind_fuse;
mod build_api;
mod build_mirror;
mod build_proxy;
mod build_registry;
mod buildkit;
mod container_store;
mod discovery;
mod events;
mod exec;
mod health;
mod http;
mod image;
mod network;
mod port;
mod public_registry;
mod registry;
mod request;
mod restart_policy;
mod volume;
mod workload_copy;
mod workload_input;

pub(super) use image::{install, InstallOptions};

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fs;
use std::io::{self, Read};
use std::net::SocketAddr;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{ensure, Context};
use base64::Engine;
use clap::Args;
use conjet_launch_service::handshake::{hex, random, Key};
use conjet_launch_service::spec::{workload_output_limit, BridgeScope, REGISTRY_CONFIG};
use conjet_launch_service::wire::{Kind, WireError};
use serde_json::{json, Value};

use super::{client, session};

pub(super) const COMPARISON_SCRATCH: &str = "/Volumes/ExternalSSD/dev_workspace/tmp";
const BACKEND: &str = "jetstream-native-oci";
const PLATFORM: &str = "Conjet Native OCI";
const CONNECTIONS: usize = 32;
const CONTAINERS: usize = 8;
const KILL: u8 = 9;
const TERM: u8 = 15;
const CHUNK: usize = 8192;
static STOP: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Args)]
pub(super) struct Options {
    #[arg(long)]
    native_session: PathBuf,
    #[arg(long)]
    socket: PathBuf,
    #[arg(long)]
    receipt: PathBuf,
    #[arg(long)]
    image: String,
    #[arg(long)]
    image_store: Option<PathBuf>,
    #[arg(long, requires = "image_store")]
    registry: Option<SocketAddr>,
    /// Enable the isolated comparison's immutable public image references.
    #[arg(long, requires = "image_store")]
    pinned_public_registry: bool,
    /// Allow the pinned BuildKit worker to retrieve immutable public objects.
    #[arg(long, requires = "pinned_public_registry")]
    pinned_build_registry: bool,
    /// Pinned local Docker client for translating uploaded build contexts.
    #[arg(long, requires_all = ["pinned_build_registry", "build_client_config"])]
    build_client_docker: Option<PathBuf>,
    /// Private Docker configuration holding the pinned Buildx plug-in.
    #[arg(long, requires = "build_client_docker")]
    build_client_config: Option<PathBuf>,
    /// Retain verified source layers for exporting the base image.
    #[arg(long, requires = "image_store")]
    boot_layout: Option<PathBuf>,
    /// Seed a verified frozen image from a private offline OCI layout.
    #[arg(long, requires = "pinned_public_registry")]
    seed_layout: Vec<PathBuf>,
    /// Existing private ExternalSSD directory authorized for native host binds.
    #[arg(long)]
    bind_root: Option<PathBuf>,
    /// Record methods, paths and parameter names in the isolated diagnostic.
    #[arg(long)]
    trace_requests: bool,
}

extern "C" fn stop_signal(_: libc::c_int) {
    STOP.store(true, Ordering::Release);
}

fn signal_handlers() -> io::Result<()> {
    for signal in [libc::SIGINT, libc::SIGTERM] {
        let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
        action.sa_sigaction = stop_signal as *const () as usize;
        if unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

pub(super) fn session_root(profile: Option<&Path>) -> anyhow::Result<&Path> {
    let Some(profile) = profile else {
        return Ok(Path::new(COMPARISON_SCRATCH));
    };
    private_directory(profile, profile)?;
    Ok(profile)
}

fn private_directory(directory: &Path, root: &Path) -> anyhow::Result<()> {
    let info = directory.symlink_metadata()?;
    ensure!(
        directory.starts_with(root)
            && directory.canonicalize()? == directory
            && info.is_dir()
            && info.uid() == unsafe { libc::geteuid() }
            && info.mode() & 0o077 == 0,
        "expected a canonical private directory inside the native Docker root"
    );
    Ok(())
}

#[cfg(test)]
#[test]
fn managed_paths_require_the_same_canonical_private_profile_root() {
    use std::os::unix::fs::{symlink, DirBuilderExt};

    let workspace = tempfile::tempdir().unwrap();
    let directory = workspace.path().canonicalize().unwrap();
    let profile = directory.join("profile");
    let session = profile.join("session");
    let other = directory.join("profile-other");
    for directory in [&profile, &session, &other] {
        fs::DirBuilder::new().mode(0o700).create(directory).unwrap();
    }
    assert_eq!(session_root(Some(&profile)).unwrap(), profile);
    private_directory(&session, &profile).unwrap();
    assert!(private_directory(&other, &profile).is_err());

    let alias = profile.join("alias");
    symlink(&session, &alias).unwrap();
    assert!(private_directory(&alias, &profile).is_err());
    fs::set_permissions(&session, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(private_directory(&session, &profile).is_err());
    assert_eq!(session_root(None).unwrap(), Path::new(COMPARISON_SCRATCH));
}

pub(super) fn stop(directory: &Path, root: &Path) -> anyhow::Result<()> {
    private_directory(directory, root)?;
    let (identity, key) = client::load(directory)?;
    let peer = client::Connection::open(directory, &identity, &key)?;
    ensure!(peer.oci, "Docker stop requires an OCI guest");
    client::stop_peer(peer)
}

pub(super) fn boot(
    options: session::Options,
    root: &Path,
    parent: Option<libc::pid_t>,
) -> anyhow::Result<()> {
    ensure!(
        options.oci_package.is_some() && options.scratch.canonicalize()? == root,
        "Docker boot requires an OCI package and the configured native Docker root"
    );
    session::serve(options, Some(root), parent)
}

struct OwnedSocket(PathBuf);

impl Drop for OwnedSocket {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub(super) fn serve(
    options: Options,
    root: &Path,
    parent: Option<libc::pid_t>,
) -> anyhow::Result<()> {
    if let Some(registry) = options.registry.filter(|_| parent.is_some()) {
        ensure!(
            root.starts_with(COMPARISON_SCRATCH)
                && registry.ip() == std::net::Ipv4Addr::LOCALHOST
                && registry.port() >= 1024,
            "managed fixture registries require an ExternalSSD qualification profile and a private loopback authority"
        );
    }
    private_directory(&options.native_session, root)?;
    private_directory(
        options
            .socket
            .parent()
            .context("missing Docker socket directory")?,
        root,
    )?;
    ensure_endpoint_available(&options.socket, parent.is_some())?;
    let receipt = options.receipt.canonicalize()?;
    ensure!(
        receipt == options.receipt && receipt.starts_with(root),
        "receipt must reside inside the native Docker root"
    );
    let admitted = fs::File::open(&receipt)?;
    ensure!(
        admitted.metadata()?.is_file() && admitted.metadata()?.len() <= 65536,
        "invalid OCI receipt"
    );
    let mut bytes = Vec::new();
    admitted.take(65537).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= 65536, "OCI receipt exceeds its bound");
    let metadata = request::Image::new(options.image, serde_json::from_slice(&bytes)?)?;

    let _lock = admission_lock(&options.native_session)?;
    let (identity, key) = client::load(&options.native_session)?;
    let mut peer = client::Connection::open(&options.native_session, &identity, &key)?;
    ensure!(peer.oci, "native Docker requires OCI capability");
    let status = peer.inspect()?;
    ensure!(
        status["image_digest"] == identity.image_digest
            && (status["image_digest"] == metadata.config_digest
                || status["installed_images"].as_array().is_some_and(|images| {
                    images
                        .iter()
                        .any(|image| image["config_digest"] == metadata.config_digest)
                }))
            && (status["workload"].is_null() || status["workload"]["cleanup"] == "complete")
            && status["active_workloads"]
                .as_array()
                .map_or(true, Vec::is_empty),
        "native guest must be dedicated, idle and own the requested image"
    );
    let store = options
        .image_store
        .map(|store_root| {
            registry::Store::open(
                store_root,
                root,
                options.registry,
                options.pinned_public_registry,
                &status,
            )
        })
        .transpose()?;
    if let Some(layout) = options.boot_layout {
        store
            .as_ref()
            .expect("boot layout requires a store")
            .seed_layout(&layout, &metadata.reference, &metadata.config_digest)?;
    }
    for layout in options.seed_layout {
        store
            .as_ref()
            .context("offline layouts require an image store")?
            .seed_frozen_layout(&layout)?;
    }
    let sequence = status["last_sequence"]
        .as_u64()
        .context("missing sequence")?;
    let native = Native {
        mapped_ids: peer.mapped_ids,
        pool: vec![peer],
        peer_directory: options.native_session,
        identity,
        key,
        boot: status["boot_id"]
            .as_str()
            .context("missing boot ID")?
            .to_owned(),
        sequence,
        pending: BTreeMap::new(),
        broken: false,
        supervisor_pid: parent,
    };
    let build_client = options
        .build_client_docker
        .zip(options.build_client_config)
        .map(|(docker, config)| build_api::Client::new(docker, config, &options.socket, root))
        .transpose()?;
    serve_endpoint(
        options.socket,
        metadata,
        native,
        store,
        options
            .bind_root
            .map(|path| bind::Root::open(path, root))
            .transpose()?,
        options.trace_requests,
        options.pinned_build_registry,
        build_client,
    )
}

fn ensure_endpoint_available(path: &Path, managed: bool) -> anyhow::Result<()> {
    let existing = match path.symlink_metadata() {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        metadata => metadata?,
    };
    ensure!(
        managed && existing.file_type().is_socket() && existing.uid() == unsafe { libc::geteuid() },
        "Docker endpoint already exists or is inaccessible"
    );
    ensure!(
        socket_connection_refused(path)?,
        "Docker endpoint still has a listener; stop its engine before starting native Docker"
    );
    let current = path.symlink_metadata()?;
    ensure!(
        current.file_type().is_socket()
            && current.dev() == existing.dev()
            && current.ino() == existing.ino(),
        "Docker endpoint changed during ownership verification"
    );
    fs::remove_file(path).context("could not remove the stopped profile's Docker endpoint")
}

fn socket_connection_refused(path: &Path) -> io::Result<bool> {
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    let path = path.as_os_str().as_bytes();
    if path.contains(&0) || path.len() >= address.sun_path.len() {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (byte, target) in path.iter().zip(&mut address.sun_path) {
        *target = *byte as libc::c_char;
    }
    let length = std::mem::offset_of!(libc::sockaddr_un, sun_path) + path.len() + 1;
    #[cfg(target_os = "macos")]
    {
        address.sun_len = length as u8;
    }
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let socket = unsafe { OwnedFd::from_raw_fd(fd) };
    if unsafe { libc::fcntl(socket.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    let result = unsafe {
        libc::connect(
            socket.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            length as libc::socklen_t,
        )
    };
    Ok(result < 0 && io::Error::last_os_error().kind() == io::ErrorKind::ConnectionRefused)
}

#[cfg(test)]
#[test]
fn managed_endpoint_recovers_only_a_stopped_socket() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("docker.sock");
    let listener = UnixListener::bind(&path).unwrap();
    assert!(ensure_endpoint_available(&path, true).is_err());
    assert!(path.exists());
    drop(listener);
    assert!(ensure_endpoint_available(&path, false).is_err());
    ensure_endpoint_available(&path, true).unwrap();
    assert!(!path.exists());

    let file = directory.path().join("keep");
    fs::write(&file, b"retained").unwrap();
    symlink(&file, &path).unwrap();
    assert!(ensure_endpoint_available(&path, true).is_err());
    assert_eq!(fs::read(&file).unwrap(), b"retained");
}

fn admission_lock(directory: &Path) -> anyhow::Result<fs::File> {
    let lock = client::open_private(&directory.join(session::LOCK))?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::last_os_error()).context("native admission already owned");
    }
    Ok(lock)
}

fn serve_endpoint(
    socket: PathBuf,
    metadata: request::Image,
    native: Native,
    store: Option<registry::Store>,
    bind_root: Option<bind::Root>,
    trace_requests: bool,
    pinned_build_registry: bool,
    build_client: Option<build_api::Client>,
) -> anyhow::Result<()> {
    let boot = &native.boot;
    let supervisor_pid = native.supervisor_pid;
    signal_handlers()?;
    let listener = UnixListener::bind(&socket)?;
    let _socket = OwnedSocket(socket);
    fs::set_permissions(&_socket.0, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let ready = json!({"socket":_socket.0, "boot_id":boot, "backend":BACKEND});
    let owner = Arc::new(Owner::new(
        metadata,
        native,
        store,
        bind_root,
        pinned_build_registry,
        build_client,
    )?);
    // Managed boot logs retain the pinned registry's source and digest without
    // enabling the standalone diagnostic trace for general Docker requests.
    let _registry = pinned_build_registry
        .then(|| build_registry::Relay::start(&owner, trace_requests || supervisor_pid.is_some()))
        .transpose()?;
    owner.resume_restart_policies();
    println!("{ready}");
    let mut handlers: Vec<JoinHandle<()>> = Vec::with_capacity(CONNECTIONS);
    let result = loop {
        for i in (0..handlers.len()).rev() {
            if handlers[i].is_finished() {
                let _ = handlers.swap_remove(i).join();
            }
        }
        if STOP.load(Ordering::Acquire)
            || supervisor_pid.is_some_and(|pid| unsafe { libc::getppid() } != pid)
        {
            STOP.store(true, Ordering::Release);
            break Ok(());
        }
        match listener.accept() {
            Ok((stream, _)) if handlers.len() < CONNECTIONS => {
                let owner = owner.clone();
                match thread::Builder::new().spawn(move || {
                    let _ = http::serve(stream, &owner, trace_requests);
                }) {
                    Ok(handler) => handlers.push(handler),
                    Err(error) => break Err(error),
                }
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let mut poll = libc::pollfd {
                    fd: listener.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                // The timeout also bounds how long we take to observe shutdown.
                unsafe { libc::poll(&mut poll, 1, 100) };
            }
            Err(error) => break Err(error),
        }
    };
    drop(listener);
    owner.shutdown();
    for handler in handlers {
        let _ = handler.join();
    }
    result.context("native Docker listener stopped")
}

struct Native {
    mapped_ids: bool,
    pool: Vec<client::Connection>,
    peer_directory: PathBuf,
    identity: session::Identity,
    key: Key,
    boot: String,
    sequence: u64,
    pending: BTreeMap<u64, Value>,
    broken: bool,
    supervisor_pid: Option<libc::pid_t>,
}

struct Admission {
    peer: client::Connection,
    state: Value,
    sequence: u64,
    began: Instant,
    admitted: Instant,
}

struct Terminal {
    code: i64,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    witness: Value,
    delivery_error: Option<String>,
}

fn read_stream(
    peer: &mut client::Connection,
    handle: &Value,
    name: &str,
    inline: Option<Value>,
    mut data: Vec<u8>,
    calls: &mut u32,
    capacity: usize,
) -> anyhow::Result<(Vec<u8>, bool)> {
    let mut initial = inline;
    let mut truncated = false;
    loop {
        let from_bundle = initial.is_some();
        let chunk = match initial.take() {
            Some(chunk) => chunk,
            None => {
                *calls += 1;
                peer.exchange(
                    Kind::Output,
                    Kind::OutputChunk,
                    &json!({"handle":handle, "budget_ms":1000, "stream":name,
                            "offset":data.len(), "max_bytes":CHUNK}),
                    Duration::from_secs(2),
                )?
            }
        };
        let piece = base64::engine::general_purpose::STANDARD
            .decode(chunk["data"].as_str().context("missing native output")?)?;
        let next = data.len() + piece.len();
        ensure!(
            chunk["offset"].as_u64() == Some(data.len() as u64)
                && chunk["next_offset"].as_u64() == Some(next as u64)
                && piece.len() <= CHUNK
                && next <= capacity,
            "invalid native output cursor or chunk bound"
        );
        truncated |= chunk["dropped_bytes"]
            .as_u64()
            .context("missing dropped-byte count")?
            > 0;
        data.extend_from_slice(&piece);
        if chunk["eof"].as_bool().context("missing native EOF flag")? {
            return Ok((data, truncated));
        }
        ensure!(
            from_bundle || !piece.is_empty(),
            "native output did not advance"
        );
    }
}

impl Native {
    fn begin(&mut self, spec: &Value) -> anyhow::Result<Admission> {
        ensure!(
            !self.broken && self.pending.len() < CONTAINERS,
            "native admission is exhausted or unresolved"
        );
        let began = Instant::now();
        let mut peer = match self.pool.pop() {
            Some(peer) => peer,
            None => client::Connection::open(&self.peer_directory, &self.identity, &self.key)?,
        };
        ensure!(
            peer.boot == self.boot && peer.oci,
            "native guest generation changed"
        );
        let operation = hex(&random::<16>()?);
        self.sequence = self
            .sequence
            .checked_add(1)
            .context("native sequence exhausted")?;
        let sequence = self.sequence;
        let identity = json!({"boot_id":peer.boot,"sequence":sequence,"operation_id":operation});
        self.pending.insert(sequence, identity);
        // This is an upper bound, not a delay. A cold Core restore can exceed
        // the old fixture's one-second grant budget at larger memory ceilings.
        let result = peer.exchange(
            Kind::Launch, Kind::State,
            &json!({"boot_id":peer.boot,"sequence":sequence,"operation_id":operation,"budget_ms":30_000,"spec":spec}),
            Duration::from_secs(2),
        ).context("native launch outcome is unresolved");
        let state = match result {
            Ok(state)
                if state["handle"]["boot_id"] == peer.boot
                    && state["handle"]["workload_id"].is_string() =>
            {
                state
            }
            other => {
                self.broken = true;
                return other.and_then(|_| anyhow::bail!("unexpected native launch identity"));
            }
        };
        self.pending.get_mut(&sequence).expect("pending launch")["handle"] =
            state["handle"].clone();
        Ok(Admission {
            peer,
            state,
            sequence,
            began,
            admitted: Instant::now(),
        })
    }

    fn finish(&mut self, admission: Admission, verified: bool) {
        if verified {
            self.pending.remove(&admission.sequence);
            self.pool.push(admission.peer);
        } else {
            self.broken = true;
        }
    }
}

fn wait_for_native(
    owner: &Owner,
    admission: &mut Admission,
    item: &Item,
    generation: u64,
) -> anyhow::Result<Terminal> {
    const TRANSITION_TIMEOUT: Duration = Duration::from_secs(32);
    const OBSERVE_INTERVAL: Duration = Duration::from_secs(2);
    let mut state = std::mem::take(&mut admission.state);
    let peer = &mut admission.peer;
    let began = admission.began;
    let admitted = admission.admitted;
    let handle = state["handle"].clone();
    let mut sent_signal = 0;
    let mut waits = 0;
    let mut awaiting_address = item.state().network.is_some();
    let mut awaiting_health = item.container.healthcheck.is_some();
    let mut next_observation = admitted + OBSERVE_INTERVAL;
    let mut teardown_deadline = None;
    let mut reconnected = false;
    while state["cleanup"] != "complete" {
        let now = Instant::now();
        let requested = item.container.cancel.load(Ordering::Acquire);
        if requested != 0 || matches!(state["phase"].as_str(), Some("exiting" | "cleaning")) {
            teardown_deadline.get_or_insert(now + TRANSITION_TIMEOUT);
        }
        ensure!(
            state["cleanup"] != "failed" && teardown_deadline.is_none_or(|deadline| now < deadline),
            "native guest cleanup remains unresolved"
        );
        ensure!(
            teardown_deadline.is_some()
                || state["exec"] == "confirmed"
                || now < admitted + TRANSITION_TIMEOUT,
            "native guest startup remained unresolved"
        );
        if requested == 0 && item.container.healthcheck.is_some() && state["phase"] == "running" {
            awaiting_health = false;
            health::probe(owner, item, generation, &handle);
        }
        let cancelling = requested != 0 && requested != sent_signal;
        let result = if cancelling {
            sent_signal = requested;
            peer.exchange(
                Kind::Cancel,
                Kind::State,
                &json!({"handle":handle,"budget_ms":1000,"signal":requested}),
                Duration::from_secs(2),
            )
        } else {
            waits += 1;
            // Probe intermediary states only for longer-running workloads so
            // short operations can keep using the terminal-output fast path.
            let after_revision = if now >= next_observation {
                next_observation = now + OBSERVE_INTERVAL;
                0
            } else if awaiting_address || awaiting_health {
                state["revision"]
                    .as_u64()
                    .context("invalid workload revision")?
            } else {
                u64::MAX
            };
            let (stdout, stderr) = {
                let status = item.state();
                (status.live[0].len(), status.live[1].len())
            };
            peer.exchange(
                Kind::Wait, Kind::State,
                &json!({"handle":handle,"after_revision":after_revision,"budget_ms":100,"terminal_output":true,
                        "live_output":{"stdout":stdout,"stderr":stderr}}),
                Duration::from_secs(2),
            )
        };
        match result {
            Err(WireError::PeerError(code)) if code == "deadline_exceeded" => {
                reconnected = false;
                continue;
            }
            Err(error)
                if item.container.buildkit_worker
                    && !cancelling
                    && !reconnected
                    && interrupted_worker_observation(&error) =>
            {
                // Wait reads the admitted generation. Reopen a fresh
                // authenticated channel before reading it again, since the
                // old socket may still contain a partial or late reply.
                peer.disconnect();
                *peer = owner
                    .scoped_peer()
                    .map_err(|error| anyhow::anyhow!(error.1))
                    .context("reconnect native BuildKit worker observation")?;
                ensure!(
                    handle["boot_id"] == peer.boot,
                    "native worker observation generation changed"
                );
                reconnected = true;
                continue;
            }
            other => {
                state = other.context("observe native workload generation")?;
                reconnected = false;
            }
        }
        ensure!(
            state["handle"] == handle,
            "native workload identity changed"
        );
        if let (true, Some("running"), Some(address)) = (
            awaiting_address,
            state["phase"].as_str(),
            state["network_address"].as_str(),
        ) {
            let mut lifecycle = item.state();
            if lifecycle.network_address.is_none() {
                if let Some(attachment) = &lifecycle.network {
                    lifecycle.network_address =
                        Some(checked_network_address(address, attachment.network.scope)?);
                    if let Some(port) = item.published.lock().unwrap().as_ref() {
                        port.set_target(Some(handle.clone()));
                    }
                    item.changed.notify_all();
                }
            }
            awaiting_address = false;
        }
        if let Some(live) = state.get("live_output") {
            item.publish_output(generation, live)?;
        }
    }
    let terminal = Instant::now();
    if let Some(stamp) = state
        .get("trace_sequence")
        .and_then(|_| super::session::host_monotonic_ns())
    {
        state["host_terminal_ns"] = json!(stamp);
    }
    let (code, failed_exec) = terminal_code(&state, sent_signal)?;
    let bundle = state
        .as_object_mut()
        .and_then(|map| map.remove("terminal_output"));
    let mut calls = 0;
    let mut streams = bundle
        .map(|value| -> anyhow::Result<_> {
            let map = value
                .as_object()
                .context("invalid terminal stream bundle")?;
            ensure!(
                map.len() == 2 && map.contains_key("stdout") && map.contains_key("stderr"),
                "terminal output lacks a stream"
            );
            Ok(map.clone())
        })
        .transpose()?
        .unwrap_or_default();
    let [live_stdout, live_stderr] = item.state().live.clone();
    let capacity = item.container.output_capacity();
    let (stdout, stdout_dropped) = read_stream(
        peer,
        &handle,
        "stdout",
        streams.remove("stdout"),
        live_stdout,
        &mut calls,
        capacity,
    )
    .context("drain native workload stdout")?;
    let (stderr, stderr_dropped) = read_stream(
        peer,
        &handle,
        "stderr",
        streams.remove("stderr"),
        live_stderr,
        &mut calls,
        capacity,
    )
    .context("drain native workload stderr")?;
    let delivery_error = if failed_exec {
        Some(format!(
            "native guest could not execute the OCI command (exit {code})"
        ))
    } else {
        (stdout_dropped || stderr_dropped)
            .then(|| "OCI output exceeds the Docker adapter limit".into())
    };
    state["adapter_timings_ns"] = json!({
        "authenticate":0, "admit":(admitted-began).as_nanos(),
        "terminal":(terminal-admitted).as_nanos(), "output":terminal.elapsed().as_nanos(),
    });
    state["adapter_wait_calls"] = json!(waits);
    state["adapter_output_calls"] = json!(calls);
    Ok(Terminal {
        code,
        stdout,
        stderr,
        witness: state,
        delivery_error,
    })
}

fn terminal_code(state: &Value, sent_signal: u8) -> anyhow::Result<(i64, bool)> {
    ensure!(
        state["cleanup"] == "complete" && state["helper_failed"] == false,
        "native guest did not verify OCI teardown (helper_failed={}, cleanup={})",
        state["helper_failed"],
        state["cleanup"]
    );
    if sent_signal != 0 && state["exit"].is_null() {
        return Ok((128 + i64::from(sent_signal), false));
    }
    let code = state["exit"]["code"].as_i64();
    // The helper reported an execution failure and the guest proved teardown.
    // Release this admission without treating the rest of the engine as lost.
    if let (Some("failed"), Some(code @ (126 | 127))) = (state["exec"].as_str(), code) {
        return Ok((code, true));
    }
    ensure!(
        state["exec"] == "confirmed",
        "native guest did not confirm OCI exec (exec={}, exit={})",
        state["exec"],
        state["exit"]
    );
    let code = match code {
        Some(code) => code,
        None => {
            128 + state["exit"]["signal"]
                .as_i64()
                .context("missing guest exit status")?
        }
    };
    Ok((code, false))
}

#[cfg(test)]
#[test]
fn only_verified_command_failures_are_releasable_terminal_results() {
    let state = json!({"exec": "failed", "exit": {"code": 127},
                       "cleanup": "complete", "helper_failed": false});
    assert_eq!(terminal_code(&state, 0).unwrap(), (127, true));
    for (field, value) in [
        ("exec", json!("indeterminate")),
        ("cleanup", json!("failed")),
        ("helper_failed", json!(true)),
        ("exit", json!({"code": 0})),
        ("exit", Value::Null),
    ] {
        let mut invalid = state.clone();
        invalid[field] = value;
        assert!(terminal_code(&invalid, 0).is_err(), "{invalid}");
    }
}

fn interrupted_worker_observation(error: &WireError) -> bool {
    matches!(error, WireError::Io(error) if matches!(
        error.kind(),
        io::ErrorKind::TimedOut
            | io::ErrorKind::UnexpectedEof
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionReset
    ))
}

#[cfg(test)]
#[test]
fn worker_observation_recovers_transport_loss_without_accepting_invalid_replies() {
    assert!(interrupted_worker_observation(
        &io::Error::from(io::ErrorKind::TimedOut).into()
    ));
    assert!(interrupted_worker_observation(
        &io::Error::from(io::ErrorKind::UnexpectedEof).into()
    ));
    assert!(!interrupted_worker_observation(&WireError::Unauthorized));
    assert!(!interrupted_worker_observation(
        &WireError::UnexpectedMessage
    ));
    assert!(!interrupted_worker_observation(&WireError::PeerError(
        "stale_generation".into()
    )));
}

#[derive(Debug)]
struct Rejected(u16, String);

impl Rejected {
    fn bad(message: impl Into<String>) -> Self {
        Self(400, message.into())
    }
    fn internal(message: impl Into<String>) -> Self {
        Self(500, message.into())
    }
}

struct Container {
    id: String,
    name: Mutex<String>,
    config: Value,
    spec: Value,
    volume: Option<conjet_launch_service::spec::VolumeMount>,
    bind: Option<bind::Binding>,
    created: u64,
    healthcheck: Option<health::Config>,
    auto_remove: bool,
    buildkit_worker: bool,
    restart_policy: restart_policy::Policy,
    cancel: AtomicU8,
}

impl Container {
    fn name(&self) -> MutexGuard<'_, String> {
        self.name.lock().unwrap()
    }

    fn output_capacity(&self) -> usize {
        workload_output_limit(self.spec["image_digest"].as_str().unwrap_or_default())
    }

    fn mounts(&self) -> Vec<Value> {
        self.volume
            .iter()
            .map(volume::mount_metadata)
            .chain(self.bind.iter().flat_map(bind::Binding::metadata))
            .collect()
    }

    fn owns_registry(&self) -> bool {
        self.spec["image_digest"] == REGISTRY_CONFIG
            && self.spec["argv"] == json!(["/entrypoint.sh", "/etc/docker/registry/config.yml"])
            && self.spec["env"]
                == json!(["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"])
            && self
                .volume
                .as_ref()
                .is_some_and(|mount| !mount.read_only && mount.target == "/var/lib/registry")
    }
}

#[derive(Default)]
struct Lifecycle {
    started: bool,
    started_at: Option<String>,
    terminal: Option<Arc<Terminal>>,
    error: Option<String>,
    removed: bool,
    generation: u64,
    restart_count: u64,
    manually_stopped: bool,
    restarting: bool,
    paused: bool,
    resource_override: Option<(Value, request::ResourceOptions)>,
    previous: VecDeque<(u64, Arc<Terminal>)>,
    live: [Vec<u8>; 2],
    native_handle: Option<Value>,
    network: Option<network::Attachment>,
    network_address: Option<String>,
    health: Option<health::State>,
    replacement_name: Option<String>,
}

impl Lifecycle {
    fn status(&self) -> &'static str {
        if self.paused {
            "paused"
        } else if self.restarting {
            "restarting"
        } else if self.terminal.is_some() || self.error.is_some() {
            "exited"
        } else if self.started {
            "running"
        } else {
            "created"
        }
    }

    fn terminal_for(&self, generation: u64) -> Option<&Arc<Terminal>> {
        if self.generation == generation {
            self.terminal.as_ref()
        } else {
            self.previous
                .iter()
                .find(|(id, _)| *id == generation)
                .map(|(_, terminal)| terminal)
        }
    }
}

struct Item {
    container: Container,
    state: Mutex<Lifecycle>,
    control: Mutex<()>,
    input_attachment: Mutex<()>,
    changed: Condvar,
    published: Mutex<Option<port::PublishedPort>>,
}

impl Item {
    fn state(&self) -> MutexGuard<'_, Lifecycle> {
        self.state.lock().unwrap()
    }

    fn port_metadata(&self, active: bool) -> Value {
        self.published
            .lock()
            .unwrap()
            .as_ref()
            .map_or_else(|| json!({}), |published| published.inspect(active))
    }

    fn publish_output(&self, generation: u64, bundle: &Value) -> anyhow::Result<()> {
        let mut state = self.state();
        ensure!(
            state.generation == generation,
            "live output generation changed"
        );
        let mut total = 0;
        for (index, name) in ["stdout", "stderr"].iter().enumerate() {
            let chunk = &bundle[*name];
            let stream = &mut state.live[index];
            let data = base64::engine::general_purpose::STANDARD
                .decode(chunk["data"].as_str().context("missing live output data")?)?;
            let next = stream.len() + data.len();
            total += data.len();
            ensure!(
                chunk["offset"].as_u64() == Some(stream.len() as u64)
                    && chunk["next_offset"].as_u64() == Some(next as u64)
                    && chunk["eof"] == false
                    && next <= self.container.output_capacity()
                    && total <= CHUNK,
                "invalid live output cursor or bounds"
            );
            stream.extend(data);
        }
        ensure!(total != 0, "native live output did not advance");
        self.changed.notify_all();
        Ok(())
    }

    fn wait_for(
        &self,
        until: impl Fn(&Lifecycle) -> bool,
        seconds: u64,
    ) -> Result<MutexGuard<'_, Lifecycle>, Rejected> {
        let (state, _) = self
            .changed
            .wait_timeout_while(self.state(), Duration::from_secs(seconds), |state| {
                !until(state)
            })
            .unwrap();
        if until(&state) {
            Ok(state)
        } else {
            Err(Rejected::internal("wait deadline elapsed"))
        }
    }
}

#[derive(Default)]
struct Ledger {
    active: Vec<Arc<Item>>,
    tags: image::Tags,
    saved_containers: container_store::Records,
    transient_build_archives: BTreeSet<String>,
    registry_images: BTreeMap<String, String>,
    history: VecDeque<Arc<Item>>,
    events: VecDeque<Value>,
    discarded_events: usize,
    workers: Vec<JoinHandle<()>>,
    execs: VecDeque<Arc<exec::Entry>>,
    poisoned: bool,
    closing: bool,
    network: Option<network::Network>,
}

fn checked_network_address(address: &str, scope: BridgeScope) -> anyhow::Result<String> {
    let octets = address.parse::<std::net::Ipv4Addr>()?.octets();
    ensure!(
        matches!(octets, [198, 18, subnet, 2..=9] if subnet == scope.subnet()),
        "invalid private bridge address"
    );
    Ok(address.to_owned())
}

struct Owner {
    memory_bytes: u64,
    image: request::Image,
    mapped_ids: bool,
    native: Mutex<Native>,
    ledger: Mutex<Ledger>,
    store: Option<Mutex<registry::Store>>,
    archive_root: Option<PathBuf>,
    retain_containers: bool,
    bind_root: Option<bind::Root>,
    pinned_build_registry: bool,
    build_client: Option<build_api::Client>,
    built_in_bridge: network::Network,
    exec_peer: Mutex<Option<client::Connection>>,
    event_changed: Condvar,
}

impl Owner {
    fn new(
        image: request::Image,
        native: Native,
        store: Option<registry::Store>,
        bind_root: Option<bind::Root>,
        pinned_build_registry: bool,
        build_client: Option<build_api::Client>,
    ) -> anyhow::Result<Self> {
        let tags = store
            .as_ref()
            .map(|store| image::Tags::load(store.root()))
            .transpose()?
            .unwrap_or_default();
        let retain_containers = native.supervisor_pid.is_some() && store.is_some();
        let saved_containers = if let Some(store) = store.as_ref().filter(|_| retain_containers) {
            container_store::load(store.root())?
        } else {
            container_store::Records::new()
        };
        let owner = Self {
            memory_bytes: native.identity.memory_mib * 1024 * 1024,
            image,
            mapped_ids: native.mapped_ids,
            archive_root: store.as_ref().map(|store| store.root().to_owned()),
            retain_containers,
            bind_root,
            pinned_build_registry,
            build_client,
            built_in_bridge: network::Network::built_in(&native.boot),
            native: Mutex::new(native),
            ledger: Mutex::new(Ledger {
                tags,
                saved_containers: saved_containers.clone(),
                ..Ledger::default()
            }),
            store: store.map(Mutex::new),
            exec_peer: Mutex::new(None),
            event_changed: Condvar::new(),
        };
        for (id, record) in &saved_containers {
            let result = if record.removing {
                let mut ledger = owner.ledger.lock().unwrap();
                owner.remove_saved_container(&mut ledger, id)
            } else {
                owner
                    .create_item(
                        Some(&record.name),
                        record.config.clone(),
                        Some((id, record)),
                    )
                    .map(|_| ())
            };
            result.map_err(|error| {
                anyhow::anyhow!("cannot restore native container {id}: {}", error.1)
            })?;
        }
        Ok(owner)
    }

    fn publish_containers(
        &self,
        ledger: &mut Ledger,
        records: container_store::Records,
    ) -> Result<(), Rejected> {
        let root = self
            .archive_root
            .as_ref()
            .ok_or_else(|| Rejected::internal("container record store is unavailable"))?;
        container_store::save(root, &records).map_err(|error| {
            Rejected::internal(format!("cannot save native container records: {error:#}"))
        })?;
        ledger.saved_containers = records;
        Ok(())
    }

    fn remove_saved_container(&self, ledger: &mut Ledger, id: &str) -> Result<(), Rejected> {
        let mut records = ledger.saved_containers.clone();
        let Some(record) = records.get_mut(id) else {
            return Ok(());
        };
        if !record.removing {
            record.removing = true;
            self.publish_containers(ledger, records.clone())?;
        }
        volume::remove_layer(self, id)?;
        records.remove(id);
        self.publish_containers(ledger, records)
    }

    fn publish_tags(&self, ledger: &mut Ledger, tags: image::Tags) -> Result<(), Rejected> {
        if let Some(root) = &self.archive_root {
            tags.save(root).map_err(|error| {
                Rejected::internal(format!("cannot persist image tags: {error:#}"))
            })?;
        }
        ledger.tags = tags;
        Ok(())
    }

    fn boot_reference(&self, reference: &str) -> bool {
        reference == self.image.reference || reference == self.image.config_digest
    }

    fn owned_registry(ledger: &Ledger) -> Option<std::net::SocketAddr> {
        let mut addresses = ledger.active.iter().filter_map(|item| {
            if !item.container.owns_registry() {
                return None;
            }
            item.published.lock().unwrap().as_ref()?.live_address(5000)
        });
        let address = addresses.next()?;
        addresses.next().is_none().then_some(address)
    }

    fn has_build_registry_worker(&self) -> bool {
        let ledger = self.ledger.lock().unwrap();
        !ledger.closing
            && ledger
                .active
                .iter()
                .any(|item| item.container.buildkit_worker && item.state().started)
    }

    fn image_store(&self, ledger: &Ledger) -> Result<MutexGuard<'_, registry::Store>, Rejected> {
        let mut store = self
            .store
            .as_ref()
            .map(|store| store.lock().unwrap())
            .ok_or_else(|| Rejected(501, "native registry store is not configured".into()))?;
        store.use_owned_registry(Self::owned_registry(ledger));
        Ok(store)
    }

    fn with_guest<T>(
        &self,
        call: impl FnOnce(&mut client::Connection) -> anyhow::Result<T>,
    ) -> Result<T, Rejected> {
        let mut native = self.native.lock().unwrap();
        if native.broken {
            return Err(Rejected::internal(
                "authenticated native channel is unresolved",
            ));
        }
        let peer = native
            .pool
            .last_mut()
            .ok_or_else(|| Rejected::internal("native channel is occupied"))?;
        let result = call(peer);
        if let Err(error) = &result {
            if error
                .downcast_ref::<WireError>()
                .is_some_and(|err| !matches!(err, WireError::PeerError(_)))
            {
                native.broken = true;
                native.pool.clear();
            }
        }
        result.map_err(|error| Rejected::internal(format!("{error:#}")))
    }

    fn scoped_peer(&self) -> Result<client::Connection, Rejected> {
        let native = self.native.lock().unwrap();
        if native.broken {
            return Err(Rejected::internal(
                "authenticated native channel is unresolved",
            ));
        }
        let peer = client::Connection::open(&native.peer_directory, &native.identity, &native.key)
            .map_err(|error| Rejected::internal(error.to_string()))?;
        if !peer.oci || peer.boot != native.boot {
            return Err(Rejected::internal("native control boot generation changed"));
        }
        Ok(peer)
    }

    fn process(&self, ledger: &Ledger, config: &Value) -> Result<Value, Rejected> {
        let requested = config["Image"]
            .as_str()
            .ok_or_else(|| Rejected::bad("missing Docker image reference"))?;
        let reference = ledger.tags.resolve(requested);
        let process = |image: &request::Image| {
            if requested == image.reference {
                image.process(config, self.mapped_ids)
            } else {
                let mut canonical = config.clone();
                canonical["Image"] = json!(image.reference);
                image.process(&canonical, self.mapped_ids)
            }
        };
        if self.boot_reference(reference) {
            return self.resolve_account(process(&self.image)?);
        }
        if self.store.is_none() {
            // Preserve the existing request validation on the boot-only route.
            return self.resolve_account(self.image.process(config, self.mapped_ids)?);
        }
        let mut store = self.image_store(ledger)?;
        let image = store
            .get(reference)
            .map_err(|error| Rejected::bad(error.to_string()))?
            .ok_or_else(|| Rejected(404, "image is not staged".into()))?;
        let spec = process(&image.metadata)?;
        if image.metadata.config_digest == self.image.config_digest {
            return self.resolve_account(spec);
        }
        if !store
            .installed(&image)
            .map_err(|error| Rejected::internal(error.to_string()))?
        {
            if ledger
                .active
                .iter()
                .any(|item| item.container.buildkit_worker)
            {
                // The worker's lifetime holds the pooled connection.
                let mut peer = self.scoped_peer()?;
                let install = store.ensure_guest(&mut peer, &image);
                let archive_capacity = reference.starts_with(&format!("{}@", archive::LOCAL))
                    && install.as_ref().is_err_and(|error| {
                        matches!(error.downcast_ref::<WireError>(),
                            Some(WireError::PeerError(code)) if code == "capacity")
                    });
                if archive_capacity {
                    let active = ledger
                        .active
                        .iter()
                        .filter_map(|item| item.container.spec["image_digest"].as_str())
                        .collect();
                    store
                        .evict_idle_guest_roots(&mut peer, &active)
                        .and_then(|()| store.ensure_guest(&mut peer, &image))
                        .map_err(|error| Rejected::internal(format!("{error:#}")))?;
                } else {
                    install.map_err(|error| Rejected::internal(format!("{error:#}")))?;
                }
            } else {
                self.with_guest(|peer| store.ensure_guest(peer, &image))?;
            }
        }
        self.resolve_account(spec)
    }

    fn resolve_account(&self, mut spec: Value) -> Result<Value, Rejected> {
        if spec["account"].is_null() {
            return Ok(spec);
        }
        let mut peer = self.scoped_peer()?;
        let reply = peer.exchange(Kind::Account, Kind::Account, &json!({
            "boot_id":peer.boot,"image_digest":spec["image_digest"],"account":spec["account"],
        }), Duration::from_secs(2)).map_err(|error| match error {
            WireError::PeerError(code) if code == "unknown_account" =>
                Rejected::bad("unknown or unmapped OCI image account"),
            _ => Rejected::internal(error.to_string()),
        })?;
        for field in ["uid", "gid"] {
            let id = reply[field]
                .as_u64()
                .filter(|id| *id < u64::from(conjet_launch_service::spec::ID_MAP_WIDTH))
                .ok_or_else(|| {
                    Rejected::internal("invalid native image account acknowledgement")
                })?;
            spec[field] = json!(id);
        }
        spec.as_object_mut()
            .expect("typed native process")
            .remove("account");
        Ok(spec)
    }

    fn check_network_aliases(
        ledger: &Ledger,
        attachment: &network::Attachment,
        replacing: Option<&str>,
    ) -> Result<(), Rejected> {
        if ledger.active.iter().any(|item| {
            if replacing == Some(item.container.id.as_str()) {
                return false;
            }
            item.state().network.as_ref().is_some_and(|entry| {
                entry.network.id == attachment.network.id
                    && conjet_launch_service::spec::network_aliases_conflict(
                        &entry.aliases,
                        entry.alias_project.as_deref(),
                        &attachment.aliases,
                        attachment.alias_project.as_deref(),
                    )
            })
        }) {
            return Err(Rejected(409, "private DNS alias is already owned".into()));
        }
        Ok(())
    }

    fn compose_replacement(
        ledger: &Ledger,
        name: &str,
        config: &Value,
        attachment: &network::Attachment,
    ) -> Option<(String, String)> {
        let (previous, final_name) = name.split_once('_')?;
        let project = config["Labels"]["com.docker.compose.project"].as_str()?;
        let service = config["Labels"]["com.docker.compose.service"].as_str()?;
        let number = config["Labels"]["com.docker.compose.container-number"].as_str()?;
        if previous.len() != 12
            || attachment.network.labels["com.docker.compose.project"] != project
            || final_name != format!("{project}-{service}-{number}")
        {
            return None;
        }
        ledger.active.iter().find_map(|item| {
            let old = &item.container;
            let labels = &old.config["Labels"];
            if &old.id[..12] != previous
                || old.name().as_str() != final_name
                || labels["com.docker.compose.project"] != project
                || labels["com.docker.compose.service"] != service
                || labels["com.docker.compose.container-number"] != number
            {
                return None;
            }
            item.state()
                .network
                .as_ref()
                .filter(|entry| {
                    entry.network.id == attachment.network.id && entry.aliases == attachment.aliases
                })
                .map(|_| (old.id.clone(), final_name.to_owned()))
        })
    }

    fn create_network(&self, config: Value) -> Result<Value, Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        if ledger.closing || ledger.poisoned || ledger.network.is_some() {
            return Err(Rejected(
                409,
                "private bridge is occupied or unresolved".into(),
            ));
        }
        let id =
            hex(&random::<32>()
                .map_err(|_| Rejected::internal("cannot allocate network identity"))?);
        ledger.network = Some(network::Network::new(&config, id.clone())?);
        Ok(json!({"Id":id,"Warning":""}))
    }

    fn list_networks(&self, filters: &discovery::Filters) -> Value {
        let ledger = self.ledger.lock().unwrap();
        json!(std::iter::once(&self.built_in_bridge)
            .chain(ledger.network.iter())
            .filter(|network| filters.matches(&network.name, &network.labels))
            .map(|network| network.inspect(json!({})))
            .collect::<Vec<_>>())
    }

    fn list_containers(&self, filters: &discovery::Filters, all: bool) -> Value {
        let ledger = self.ledger.lock().unwrap();
        let selected = ledger.active.iter().filter_map(|item| {
            let state = item.state();
            let container = &item.container;
            let labels = &container.config["Labels"];
            let name = container.name();
            if (!all && state.status() != "running") || !filters.matches(&name, labels) {
                return None;
            }
            let command = container.spec["argv"].as_array().expect("validated native argv")
                .iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ");
            let networks = state.network.as_ref().map_or_else(|| json!({}), |attachment| {
                json!({(attachment.network.name.as_str()):attachment.inspect(state.network_address.as_deref())})
            });
            let ports = item.published.lock().unwrap().as_ref()
                .filter(|_| state.network_address.is_some())
                .map(port::PublishedPort::summary).unwrap_or_default();
            Some(json!({"Id":container.id,"Names":[format!("/{name}")],
                        "Image":container.config["Image"],"ImageID":container.spec["image_digest"],
                        "Command":command,"Created":container.created,"Labels":labels,
                        "State":state.status(),"Status":state.status(),
                        "NetworkSettings":{"Networks":networks},"Ports":ports,
                        "Mounts":container.mounts() }))
        }).collect::<Vec<_>>();
        json!(selected)
    }

    fn find_network<'a>(
        &'a self,
        ledger: &'a Ledger,
        reference: &str,
    ) -> Option<&'a network::Network> {
        std::iter::once(&self.built_in_bridge)
            .chain(ledger.network.iter())
            .find(|entry| entry.matches(reference))
    }

    fn inspect_network(&self, reference: &str) -> Result<Value, Rejected> {
        let ledger = self.ledger.lock().unwrap();
        let network = self
            .find_network(&ledger, reference)
            .ok_or_else(|| Rejected(404, "private bridge was not found".into()))?;
        let mut endpoints = serde_json::Map::new();
        for item in &ledger.active {
            let state = item.state();
            if let Some(ip) = &state.network_address {
                if state
                    .network
                    .as_ref()
                    .is_some_and(|entry| entry.network.id == network.id)
                {
                    endpoints.insert(item.container.id.clone(),
                        json!({"Name":item.container.name().as_str(),"IPv4Address":format!("{ip}/28"),"IPv6Address":""}));
                }
            }
        }
        Ok(network.inspect(Value::Object(endpoints)))
    }

    fn remove_network(&self, reference: &str) -> Result<(), Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        if self.built_in_bridge.matches(reference) {
            return Err(Rejected(
                403,
                "the built-in bridge cannot be removed".into(),
            ));
        }
        if !ledger
            .network
            .as_ref()
            .is_some_and(|network| network.matches(reference))
        {
            return Err(Rejected(404, "private bridge was not found".into()));
        }
        if ledger.active.iter().any(|item| {
            item.state()
                .network
                .as_ref()
                .is_some_and(|entry| entry.network.scope.subnet() == 0)
        }) {
            return Err(Rejected(
                409,
                "private bridge still has attached containers".into(),
            ));
        }
        let reply = self.exchange_network(json!({"action":"remove"}))?;
        if reply["removed"] != true {
            ledger.poisoned = true;
            return Err(Rejected::internal(
                "bridge removal acknowledgement was invalid",
            ));
        }
        ledger.network = None;
        Ok(())
    }

    fn change_network(
        &self,
        reference: &str,
        item: &Item,
        endpoint: Option<&Value>,
    ) -> Result<(), Rejected> {
        let _control = item.control.lock().unwrap();
        let mut ledger = self.ledger.lock().unwrap();
        if ledger.closing || ledger.poisoned {
            return Err(Rejected(
                409,
                "private bridge is draining or unresolved".into(),
            ));
        }
        let network = self
            .find_network(&ledger, reference)
            .ok_or_else(|| Rejected(404, "private bridge was not found".into()))?;
        let attachment = endpoint
            .map(|endpoint| network::Attachment::new(network, endpoint, &item.container.name()))
            .transpose()?;
        if let Some(entry) = &attachment {
            Self::check_network_aliases(&ledger, entry, None)?;
        }
        let mut state = item.state();
        if state.removed || state.error.is_some() {
            return Err(Rejected(
                404,
                "container no longer owns an eligible lifecycle".into(),
            ));
        }
        // Before start a client can select a custom network after creating a
        // container on the implicit bridge. No guest endpoint exists yet.
        let replacing_default = attachment.is_some()
            && !state.started
            && request::falsey(&item.container.config["HostConfig"]["NetworkMode"])
            && request::falsey(&item.container.config["NetworkingConfig"])
            && state.network.as_ref().is_some_and(|current| {
                current.network.scope == conjet_launch_service::spec::BridgeScope::BuiltIn
            });
        if state.network.is_some() == attachment.is_some() && !replacing_default {
            return Err(Rejected(
                409,
                "container already has that network disposition".into(),
            ));
        }
        if attachment.is_none()
            && state
                .network
                .as_ref()
                .is_some_and(|entry| entry.network.id != network.id)
        {
            return Err(Rejected(
                404,
                "container is not attached to that bridge".into(),
            ));
        }
        if state.started && state.terminal.is_none() {
            if attachment
                .as_ref()
                .is_some_and(|entry| entry.aliases.len() != 1)
            {
                return Err(Rejected::bad(
                    "live bridge attachment supports one private DNS alias",
                ));
            }
            let handle = state
                .native_handle
                .as_ref()
                .ok_or_else(|| Rejected(409, "container launch is still pending".into()))?;
            let operation = attachment.as_ref().map_or_else(
                || json!({"action":"disconnect","handle":handle}),
                |entry| {
                    json!({"action":"connect","handle":handle,"alias":entry.aliases[0],
                    "scope":entry.network.scope})
                },
            );
            let reply = self.exchange_network(operation)?;
            let address = reply["network_address"]
                .as_str()
                .map(|address| checked_network_address(address, network.scope))
                .transpose();
            match address {
                Ok(address) if address.is_some() == attachment.is_some() => {
                    state.network_address = address;
                    if let Some(published) = item.published.lock().unwrap().as_ref() {
                        published.set_target(state.network_address.as_ref().map(|_| {
                            state
                                .native_handle
                                .as_ref()
                                .expect("confirmed native handle")
                                .clone()
                        }));
                    }
                }
                _ => {
                    ledger.poisoned = true;
                    return Err(Rejected::internal(
                        "bridge change acknowledgement was invalid",
                    ));
                }
            }
        }
        state.network = attachment;
        Ok(())
    }

    fn exchange_network(&self, operation: Value) -> Result<Value, Rejected> {
        let mut native = self.native.lock().unwrap();
        if native.broken {
            return Err(Rejected::internal(
                "authenticated native channel is unresolved",
            ));
        }
        let mut transient;
        let boot = native.boot.clone();
        let peer = if let Some(peer) = native.pool.last_mut() {
            peer
        } else {
            transient =
                client::Connection::open(&native.peer_directory, &native.identity, &native.key)
                    .map_err(|error| Rejected::internal(error.to_string()))?;
            if transient.boot != boot {
                return Err(Rejected::internal(
                    "private bridge guest generation changed",
                ));
            }
            &mut transient
        };
        match peer.exchange(
            Kind::Network,
            Kind::Network,
            &json!({"boot_id":boot,"budget_ms":2500,"operation":operation}),
            Duration::from_secs(3),
        ) {
            Ok(reply) => Ok(reply),
            Err(WireError::PeerError(code)) => match code.as_str() {
                "not_found" | "not_running" | "busy" => {
                    Err(Rejected(409, format!("private bridge: {code}")))
                }
                "unsupported_option" => Err(Rejected::bad(
                    "container requires bridge permissions at start",
                )),
                "cleanup_failed" => {
                    native.broken = true;
                    Err(Rejected::internal("private bridge cleanup is unresolved"))
                }
                _ => Err(Rejected::internal(format!(
                    "private bridge rejected operation: {code}"
                ))),
            },
            Err(error) => {
                native.broken = true;
                native.pool.clear();
                Err(Rejected::internal(error.to_string()))
            }
        }
    }

    fn inspect_image(&self, reference: &str) -> Result<Value, Rejected> {
        let ledger = self.ledger.lock().unwrap();
        let reference = ledger.tags.resolve(reference);
        if self.boot_reference(reference) {
            return Ok(Self::image_info(&ledger, &self.image));
        }
        let missing = || Rejected(404, "image is not staged".into());
        let store = self.image_store(&ledger).map_err(|_| missing())?;
        store
            .get(reference)
            .map_err(|_| missing())?
            .as_ref()
            .map(|image| Self::image_info(&ledger, &image.metadata))
            .ok_or_else(missing)
    }

    fn image_info(ledger: &Ledger, image: &request::Image) -> Value {
        json!({
            "Id":image.config_digest,"Os":"linux","Architecture":"arm64",
            "Config":image.defaults,"RepoDigests":[image.reference],
            "RepoTags":ledger.tags.names_for(&image.reference).collect::<Vec<_>>(),
        })
    }

    fn list_images(&self) -> Result<Value, Rejected> {
        let ledger = self.ledger.lock().unwrap();
        let mut images = vec![Self::image_info(&ledger, &self.image)];
        if self.store.is_some() {
            let staged = self
                .image_store(&ledger)?
                .list(&ledger.registry_images)
                .map_err(|error| Rejected::internal(error.to_string()))?;
            images.extend(
                staged
                    .iter()
                    .filter(|image| image.metadata.reference != self.image.reference)
                    .map(|image| Self::image_info(&ledger, &image.metadata)),
            );
        }
        Ok(json!(images))
    }

    fn tag_image(&self, source: &str, repository: &str, tag: &str) -> Result<(), Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        if ledger.poisoned || ledger.closing {
            return Err(Rejected(409, "native OCI state is unresolved".into()));
        }
        let reference = ledger.tags.resolve(source);
        let target = if self.boot_reference(reference) {
            self.image.reference.clone()
        } else {
            self.image_store(&ledger)
                .map_err(|_| Rejected(404, "image is not staged".into()))?
                .get(reference)
                .map_err(|_| Rejected(404, "image is not staged".into()))?
                .ok_or_else(|| Rejected(404, "image is not staged".into()))?
                .metadata
                .reference
        };
        let mut tags = ledger.tags.clone();
        tags.insert(repository, tag, target)?;
        self.publish_tags(&mut ledger, tags)
    }

    fn pull_image(&self, reference: &str) -> Result<Value, Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        let owned = Self::owned_registry(&ledger).is_some_and(|address| {
            reference
                .split_once('/')
                .is_some_and(|(authority, _)| authority == address.to_string())
        });
        if (!ledger.active.is_empty() && !owned) || ledger.poisoned || ledger.closing {
            return Err(Rejected(
                409,
                "native guest must be idle to pull an image".into(),
            ));
        }
        if self.boot_reference(reference) {
            return Ok(json!({"status":"Image is already staged","id":reference}));
        }
        let mut store = self.image_store(&ledger)?;
        let tagged = if reference.contains('@') {
            store
                .validate_reference(reference)
                .map_err(|error| Rejected::bad(error.to_string()))?;
            None
        } else {
            Some(
                public_registry::tagged(reference)
                    .map_err(|error| Rejected::bad(error.to_string()))?,
            )
        };
        let mut tags = ledger.tags.clone();
        if let Some((repository, tag)) = &tagged {
            tags.insert(&format!("docker.io/{repository}"), tag, String::new())?;
        }
        let image = match &tagged {
            Some((repository, tag)) => store
                .prepare_tagged(repository, tag)
                .map(|(image, _)| image),
            None => store.prepare(reference),
        }
        .map_err(|error| Rejected::internal(format!("{error:#}")))?;
        if owned {
            // Keep the verified host image addressable if guest
            // installation fails and the caller needs to remove it.
            ledger
                .registry_images
                .insert(reference.into(), image.metadata.config_digest.clone());
            let mut peer = self.scoped_peer()?;
            store
                .ensure_guest(&mut peer, &image)
                .map_err(|error| Rejected::internal(format!("{error:#}")))?;
        } else {
            // This pull owns an idle guest. Host-staged images keep their identity
            // and can reinstall their guest roots on demand after an eviction.
            self.with_guest(|peer| {
                let install = store.ensure_guest(peer, &image);
                if install.as_ref().is_err_and(|error| {
                    matches!(error.downcast_ref::<WireError>(),
                        Some(WireError::PeerError(code)) if code == "capacity")
                }) {
                    store.evict_idle_guest_roots(peer, &BTreeSet::new())?;
                    return store.ensure_guest(peer, &image);
                }
                install
            })?;
        }
        if let Some((repository, tag)) = tagged {
            tags.insert(
                &format!("docker.io/{repository}"),
                tag,
                image.metadata.reference.clone(),
            )?;
            self.publish_tags(&mut ledger, tags)?;
        }
        Ok(json!({"status":"Image is staged","id":reference}))
    }

    fn load_archive(&self, file: &fs::File) -> Result<Vec<u8>, Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        // Buildx loads the export while the pinned worker owns its cache.
        // Loading publishes verified host content. The guest receives the
        // image only when a workload starts from it.
        if ledger.poisoned
            || ledger.closing
            || ledger
                .active
                .iter()
                .any(|item| !item.container.buildkit_worker)
        {
            return Err(Rejected(
                409,
                "native guest must be idle to load an archive".into(),
            ));
        }
        let mut store = self.image_store(&ledger)?;
        let archive = archive::read(file, store.archive_layer_limit())
            .map_err(|error| Rejected::bad(format!("{error:#}")))?;
        let reference = archive.reference();
        let mut tags = ledger.tags.clone();
        let mut response = Vec::new();
        for name in &archive.tags {
            let (repo, tag) = name
                .rsplit_once(':')
                .ok_or_else(|| Rejected::bad("untagged Docker archive name"))?;
            tags.insert(repo, tag, reference.clone())?;
            serde_json::to_writer(
                &mut response,
                &json!({"stream":format!("Loaded image: {name}\n")}),
            )
            .map_err(|_| Rejected::internal("cannot report loaded Docker tag"))?;
            response.push(b'\n');
        }
        if response.is_empty() {
            serde_json::to_writer(
                &mut response,
                &json!({"stream":format!("Loaded image: {}\n", archive.manifest)}),
            )
            .map_err(|_| Rejected::internal("cannot report loaded Docker image"))?;
            response.push(b'\n');
        }
        self.retire_build_archives(&mut ledger, &mut store)?;
        let transient = !archive.tags.is_empty()
            && ledger
                .active
                .iter()
                .any(|item| item.container.buildkit_worker)
            && store
                .get(&reference)
                .map_err(|error| Rejected::internal(error.to_string()))?
                .is_none();
        store
            .import(archive)
            .map_err(|error| Rejected::bad(format!("{error:#}")))?;
        self.publish_tags(&mut ledger, tags)?;
        if transient {
            ledger.transient_build_archives.insert(reference);
        }
        Ok(response)
    }

    fn retire_build_archives(
        &self,
        ledger: &mut Ledger,
        store: &mut registry::Store,
    ) -> Result<(), Rejected> {
        // A tag can be removed while a workload still references the export.
        // Revisit those archives before a later load reserves host capacity.
        let untagged: Vec<_> = ledger
            .transient_build_archives
            .iter()
            .filter(|image| !ledger.tags.references_manifest(image))
            .cloned()
            .collect();
        for reference in untagged {
            self.retire_build_archive(ledger, store, &reference)?;
        }
        Ok(())
    }

    fn retire_build_archive(
        &self,
        ledger: &mut Ledger,
        store: &mut registry::Store,
        reference: &str,
    ) -> Result<Option<String>, Rejected> {
        let image = store
            .get(reference)
            .map_err(|error| Rejected::internal(error.to_string()))?
            .ok_or_else(|| Rejected::internal("tracked build archive is missing"))?;
        if ledger
            .active
            .iter()
            .any(|item| item.container.spec["image_digest"] == image.metadata.config_digest)
        {
            return Ok(None);
        }
        let config = image.metadata.config_digest.clone();
        let mut peer = self.scoped_peer()?;
        store
            .remove(&mut peer, image)
            .map_err(|error| Rejected::internal(format!("{error:#}")))?;
        ledger.transient_build_archives.remove(reference);
        Ok(Some(config))
    }

    fn save_archive(&self, name: &str) -> Result<fs::File, Rejected> {
        let ledger = self.ledger.lock().unwrap();
        let reference = ledger.tags.resolve(name);
        let store = self.image_store(&ledger)?;
        let canonical = if self.boot_reference(reference) {
            &self.image.reference
        } else if store.get(reference).ok().flatten().is_some() {
            reference
        } else {
            return Err(Rejected(404, "image is not staged".into()));
        };
        let manifest = canonical
            .rsplit_once('@')
            .expect("immutable image reference")
            .1;
        let tags = if name == reference {
            ledger
                .tags
                .names_for(canonical)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        } else {
            vec![image::Tags::key(name).into_owned()]
        };
        archive::export(store.root(), manifest, &tags, store.archive_layer_limit())
            .map_err(|error| Rejected(404, format!("image archive source unavailable: {error:#}")))
    }

    fn remove_image(&self, reference: &str) -> Result<Value, Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        if ledger.poisoned || ledger.closing {
            return Err(Rejected(409, "native OCI state is unresolved".into()));
        }
        let reference_target = ledger.tags.resolve(reference).to_owned();
        let mut tags = ledger.tags.clone();
        if let Some(tag) = tags.remove(reference) {
            let mut response = vec![json!({"Untagged":tag})];
            self.publish_tags(&mut ledger, tags)?;
            if ledger.transient_build_archives.contains(&reference_target)
                && !ledger.tags.references_manifest(&reference_target)
            {
                let mut store = self.image_store(&ledger)?;
                if let Some(config) =
                    self.retire_build_archive(&mut ledger, &mut store, &reference_target)?
                {
                    response.push(json!({"Deleted":config}));
                }
            }
            return Ok(json!(response));
        }
        let mut registered = ledger
            .registry_images
            .iter()
            .filter(|(name, config)| reference == name.as_str() || reference == config.as_str());
        let owned = registered.next().map(|(name, _)| name.clone());
        if registered.next().is_some() {
            return Err(Rejected(
                409,
                "image config belongs to several registry references".into(),
            ));
        }
        if self.boot_reference(reference) {
            return Err(Rejected(409, "image is referenced by the boot".into()));
        }
        if owned.is_none() {
            // A removed local tag is not a request to resolve a registry pull.
            if !reference.contains('@') {
                return Err(Rejected(404, "image is not staged".into()));
            }
            if !ledger.active.is_empty() {
                return Err(Rejected(409, "image is referenced by a container".into()));
            }
        }
        let mut store = self.image_store(&ledger)?;
        let image = store
            .get(owned.as_deref().unwrap_or(reference))
            .map_err(|error| Rejected::bad(error.to_string()))?
            .ok_or_else(|| Rejected(404, "image is not staged".into()))?;
        if ledger.tags.references_manifest(&image.metadata.reference)
            || ledger
                .active
                .iter()
                .any(|item| item.container.spec["image_digest"] == image.metadata.config_digest)
        {
            return Err(Rejected(409, "image has local tags".into()));
        }
        let config = image.metadata.config_digest.clone();
        let target = image.metadata.reference.clone();
        if owned.is_some() {
            let mut peer = self.scoped_peer()?;
            store
                .remove(&mut peer, image)
                .map_err(|error| Rejected::internal(format!("{error:#}")))?;
        } else {
            self.with_guest(|peer| store.remove(peer, image))?;
        }
        if let Some(owned) = owned {
            ledger.registry_images.remove(&owned);
        }
        ledger.transient_build_archives.remove(&target);
        Ok(json!([{"Untagged":reference},{"Deleted":config}]))
    }

    fn event(&self, ledger: &mut Ledger, action: &str, item: &Item, terminal: Option<&Terminal>) {
        let mut attributes = json!({"name":item.container.name().as_str(),"image":item.container.config["Image"],"conjet.backend":BACKEND});
        if let Some(labels) = item.container.config["Labels"].as_object() {
            let fields = attributes.as_object_mut().expect("event attributes");
            for (key, value) in labels {
                fields.entry(key.clone()).or_insert_with(|| value.clone());
            }
        }
        if let Some(terminal) = terminal {
            let state = &terminal.witness;
            attributes["exitCode"] = json!(terminal.code.to_string());
            attributes["conjet.guest_cleanup"] =
                json!(state["cleanup"].as_str().unwrap_or("not_admitted"));
            attributes["conjet.native_handle"] =
                json!(state["handle"]["workload_id"].as_str().unwrap_or(""));
            if let Some(verified) = state["bind_cleanup"].as_str() {
                attributes["conjet.bind_cleanup"] = json!(verified);
            }
            if let Some(sequence) = state["trace_sequence"].as_u64() {
                let trace = json!({
                    "boot_id": state["handle"]["boot_id"],
                    "sequence": sequence,
                    "guest_phase_ns": state["guest_phase_ns"],
                    "h4_ns": state["host_terminal_ns"],
                });
                attributes["conjet.latency_trace"] = json!(trace.to_string());
            }
            for key in ["authenticate", "admit", "terminal", "output"] {
                if let Some(value) = state["adapter_timings_ns"][key].as_u64() {
                    attributes[format!("conjet.timing.{key}")] = json!(value.to_string());
                }
            }
            for (field, key) in [
                ("adapter_wait_calls", "conjet.wait_calls"),
                ("adapter_output_calls", "conjet.output_calls"),
            ] {
                if let Some(value) = state[field].as_u64() {
                    attributes[key] = json!(value.to_string());
                }
            }
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        if ledger.events.len() == 64 {
            ledger.events.pop_front();
            ledger.discarded_events += 1;
        }
        ledger
            .events
            .push_back(json!({"Type":"container","Action":action,
                                      "Actor":{"ID":item.container.id,"Attributes":attributes},
                                      "time":now.as_secs(),"timeNano":now.as_nanos()}));
        self.event_changed.notify_all();
    }

    fn create(&self, name: Option<&str>, config: Value) -> Result<Arc<Item>, Rejected> {
        self.create_item(name, config, None)
    }

    fn create_item(
        &self,
        name: Option<&str>,
        mut config: Value,
        restored: Option<(&str, &container_store::Record)>,
    ) -> Result<Arc<Item>, Rejected> {
        if name.is_some_and(|name| !request::name(name)) {
            return Err(Rejected::bad("invalid container name"));
        }
        let mut ledger = self.ledger.lock().unwrap();
        if ledger.active.len() >= CONTAINERS || ledger.poisoned || ledger.closing {
            return Err(Rejected(
                409,
                "native OCI capacity is occupied or unresolved".into(),
            ));
        }
        if let Some(name) = name {
            if ledger
                .active
                .iter()
                .any(|item| item.container.name().as_str() == name)
            {
                return Err(Rejected(
                    409,
                    "native container name is already owned".into(),
                ));
            }
        }
        let id = match restored {
            Some((id, _)) => id.to_owned(),
            None => hex(&random::<32>()
                .map_err(|_| Rejected::internal("cannot allocate container identity"))?),
        };
        let name = name.unwrap_or(&id[..12]).to_owned();
        let requested_image = config["Image"].clone();
        if let Some((_, record)) = restored {
            config["Image"] = json!(record.image);
        }
        let bind = bind::Binding::requested(&config, self.bind_root.as_ref())?;
        let mount = if bind.is_none() {
            volume::requested(&config)?
        } else {
            None
        };
        let worker_config = buildkit::requested(
            &name,
            &config,
            ledger
                .tags
                .resolve(config["Image"].as_str().unwrap_or_default()),
            mount.as_ref(),
        )?;
        let buildkit_worker = worker_config.is_some();
        let volume = mount
            .as_ref()
            .filter(|_| !buildkit_worker)
            .map(|mount| self.volume_mount(mount, false))
            .transpose()?;
        let network = network::configured(
            &config,
            &self.built_in_bridge,
            ledger.network.as_ref(),
            if buildkit_worker { &id[..12] } else { &name },
        )?;
        let replacement = network
            .as_ref()
            .and_then(|entry| Self::compose_replacement(&ledger, &name, &config, entry));
        if let Some(attachment) = &network {
            Self::check_network_aliases(
                &ledger,
                attachment,
                replacement.as_ref().map(|pair| pair.0.as_str()),
            )?;
        }
        let publication = port::RequestedPort::parse(&config)?;
        if publication.is_some() && network.is_none() {
            return Err(Rejected::bad(
                "loopback port publication requires a private bridge",
            ));
        }
        let mut spec = if network.is_some() || mount.is_some() || bind.is_some() {
            let mut process = config.clone();
            if network.is_some() {
                process["HostConfig"]["NetworkMode"] = json!("none");
                process["NetworkingConfig"] = Value::Null;
            }
            if mount.is_some() || bind.is_some() {
                let host = process["HostConfig"]
                    .as_object_mut()
                    .expect("Docker host config");
                host.remove("Mounts");
                host.remove("Binds");
            }
            if buildkit_worker {
                let host = process["HostConfig"]
                    .as_object_mut()
                    .expect("BuildKit host config");
                for field in ["Privileged", "Init", "RestartPolicy"] {
                    host.remove(field);
                }
            }
            if publication.is_some() {
                process["HostConfig"]
                    .as_object_mut()
                    .expect("Docker host config")
                    .remove("PortBindings");
                process
                    .as_object_mut()
                    .expect("Docker config")
                    .remove("ExposedPorts");
            }
            self.process(&ledger, &process)?
        } else {
            self.process(&ledger, &config)?
        };
        let volume = if let Some(expected) = worker_config {
            if spec["image_digest"] != expected || spec["uid"] != 0 || spec["gid"] != 0 {
                return Err(Rejected::bad(
                    "BuildKit worker image has a different verified identity",
                ));
            }
            Some(self.volume_mount(mount.as_ref().expect("approved BuildKit cache"), true)?)
        } else {
            volume
        };
        if let Some(volume) = &volume {
            spec["volume"] = json!(volume);
        }
        if buildkit_worker {
            use conjet_launch_service::spec::{
                BUILDKIT_NATIVE_ARGS, BUILDKIT_PATH, BUILDKIT_REGISTRY_CONFIG,
                BUILDKIT_SNAPSHOTTER_ARG,
            };
            let mut args = BUILDKIT_NATIVE_ARGS.iter().copied().collect::<Vec<_>>();
            args[BUILDKIT_SNAPSHOTTER_ARG] =
                conjet_launch_service::build_snapshot::Snapshotter::Overlay.worker_arg();
            if self.pinned_build_registry {
                args.push(BUILDKIT_REGISTRY_CONFIG);
            }
            if let Some(flags) = config["Cmd"].as_array() {
                args.extend(flags.iter().filter_map(Value::as_str));
            }
            spec["argv"] = json!(args);
            spec["env"] = json!([BUILDKIT_PATH]);
            spec["buildkit_worker"] = json!(true);
            spec["docker_default_capabilities"] = json!(false);
        }
        if spec["image_digest"] == conjet_launch_service::spec::REDIS_CONFIG
            && config["HostConfig"]["CapDrop"] != json!(["ALL"])
            && serde_json::from_value::<conjet_launch_service::spec::LaunchSpec>(spec.clone())
                .is_ok_and(|spec| spec.can_bootstrap_redis())
        {
            spec["redis_bootstrap"] = json!(true);
        }
        if bind.is_some() && (spec["uid"] != 0 || spec["gid"] != 0 || !spec["account"].is_null()) {
            return Err(Rejected::bad(
                "isolated host binds require the mapped root identity",
            ));
        }
        let healthcheck = health::Config::parse(&config["Healthcheck"], &spec)?;
        let published = publication
            .map(|request| {
                let endpoint = {
                    let native = self.native.lock().unwrap();
                    port::Endpoint {
                        directory: native.peer_directory.clone(),
                        identity: native.identity.clone(),
                        key: native.key,
                        boot: native.boot.clone(),
                    }
                };
                port::PublishedPort::bind(request, endpoint)
            })
            .transpose()?;
        let auto_remove = config["HostConfig"]["AutoRemove"] == true;
        let retained = self.retain_containers
            && !auto_remove
            && !buildkit_worker
            && bind.is_none()
            && network
                .as_ref()
                .is_none_or(|entry| entry.network.scope == BridgeScope::BuiltIn);
        let restart_policy = if buildkit_worker {
            restart_policy::Policy::No
        } else {
            restart_policy::Policy::parse(&config["HostConfig"]["RestartPolicy"])?
        };
        if restart_policy != restart_policy::Policy::No && !retained {
            return Err(Rejected::bad(
                "restart policy requires a retained native container",
            ));
        }
        if restored.is_some() && !retained {
            return Err(Rejected::internal(
                "saved container no longer supports retained state",
            ));
        }
        if retained {
            spec["retained_layer"] = json!(id);
        }
        let created = restored.map_or_else(
            || {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs()
            },
            |(_, record)| record.created,
        );
        if let Some((_, _)) = restored {
            config["Image"] = requested_image;
        } else if retained {
            let image = ledger
                .tags
                .resolve(config["Image"].as_str().expect("validated image"))
                .to_owned();
            let mut records = ledger.saved_containers.clone();
            records.insert(
                id.clone(),
                container_store::Record {
                    name: name.clone(),
                    created,
                    config: config.clone(),
                    image,
                    generation: 0,
                    started_at: None,
                    exit_code: None,
                    restart_count: 0,
                    manually_stopped: false,
                    removing: false,
                },
            );
            self.publish_containers(&mut ledger, records)?;
        }
        let mut state = Lifecycle {
            network,
            replacement_name: replacement.map(|(_, final_name)| final_name),
            ..Lifecycle::default()
        };
        if let Some((_, record)) = restored {
            state.started = record.started_at.is_some();
            state.started_at = record.started_at.clone();
            state.generation = record.generation;
            state.restart_count = record.restart_count;
            state.manually_stopped = record.manually_stopped;
            if state.started {
                state.terminal = Some(Arc::new(Terminal {
                    code: record.exit_code.unwrap_or(137),
                    stdout: vec![],
                    stderr: vec![],
                    witness: json!({}),
                    delivery_error: None,
                }));
            }
        }
        let item = Arc::new(Item {
            container: Container {
                id,
                name: Mutex::new(name),
                config,
                spec,
                volume,
                bind,
                created,
                healthcheck,
                auto_remove,
                buildkit_worker,
                restart_policy,
                cancel: AtomicU8::new(0),
            },
            state: Mutex::new(state),
            control: Mutex::new(()),
            input_attachment: Mutex::new(()),
            changed: Condvar::new(),
            published: Mutex::new(published),
        });
        ledger.active.push(item.clone());
        if restored.is_none() {
            self.event(&mut ledger, "create", &item, None);
        }
        Ok(item)
    }

    fn volume_mount(
        &self,
        mount: &volume::Mount<'_>,
        create_if_missing: bool,
    ) -> Result<conjet_launch_service::spec::VolumeMount, Rejected> {
        let info = match volume::ask(self, "inspect", Some(mount.name)) {
            Err(Rejected(404, _)) if create_if_missing => {
                volume::ask(self, "create", Some(mount.name))?
            }
            result => result?,
        };
        let inode = info["inode"]
            .as_u64()
            .filter(|value| *value > 0)
            .ok_or_else(|| Rejected::internal("native volume has no inode identity"))?;
        Ok(conjet_launch_service::spec::VolumeMount {
            name: mount.name.into(),
            read_only: mount.read_only,
            inode,
            target: mount.target.into(),
        })
    }

    fn accept_buildkit_config(
        &self,
        item: &Item,
        path: &str,
        archive: &fs::File,
    ) -> Result<bool, Rejected> {
        if !item.container.buildkit_worker {
            return Ok(false);
        }
        let _control = item.control.lock().unwrap();
        let state = item.state();
        if state.started || state.removed {
            return Err(Rejected(
                409,
                "BuildKit bootstrap requires an unstarted worker".into(),
            ));
        }
        buildkit::accept_empty_config(path, archive)?;
        Ok(true)
    }

    fn remove_volume(&self, name: &str) -> Result<(), Rejected> {
        let ledger = self.ledger.lock().unwrap();
        if ledger.active.iter().any(|item| {
            item.container
                .volume
                .as_ref()
                .is_some_and(|volume| volume.name == name)
        }) {
            return Err(Rejected(
                409,
                "native volume is referenced by a container".into(),
            ));
        }
        volume::ask(self, "remove", Some(name)).map(|_| ())
    }

    fn lookup(&self, id: &str) -> Result<Arc<Item>, Rejected> {
        let ledger = self.ledger.lock().unwrap();
        ledger
            .active
            .iter()
            .chain(&ledger.history)
            .find(|item| {
                let container = &item.container;
                id == container.id || id == &container.id[..12] || id == container.name().as_str()
            })
            .cloned()
            .ok_or_else(|| Rejected(404, "container was not found".into()))
    }

    fn start(self: &Arc<Self>, item: &Arc<Item>) -> Result<bool, Rejected> {
        let _control = item.control.lock().unwrap();
        {
            let state = item.state();
            if state.started && state.terminal.is_none() && state.error.is_none() && !state.removed
            {
                return Ok(false);
            }
        }
        self.submit(item, false)?;
        Self::wait_for_network_start(item)?;
        Ok(true)
    }

    fn resume_restart_policies(self: &Arc<Self>) {
        let items = self.ledger.lock().unwrap().active.clone();
        for item in items {
            let resume = {
                let state = item.state();
                item.container
                    .restart_policy
                    .after_daemon_restart(state.started, state.manually_stopped)
            };
            if resume {
                let _control = item.control.lock().unwrap();
                if let Err(error) = self.submit(&item, false) {
                    item.state().error = Some(error.1);
                    item.changed.notify_all();
                }
            }
        }
    }

    fn wait_for_network_start(item: &Item) -> Result<(), Rejected> {
        let published = item.published.lock().unwrap().is_some();
        if !published && item.state().network.is_none() {
            return Ok(());
        }
        let state = item.wait_for(
            |state| {
                state.network_address.is_some()
                    || state.terminal.is_some()
                    || state.error.is_some()
                    || state.removed
            },
            30,
        )?;
        if published && state.network_address.is_none() {
            return Err(Rejected(
                409,
                "workload exited before loopback publication".into(),
            ));
        }
        Ok(())
    }

    fn workload_control(
        &self,
        handle: &Value,
        operation: conjet_launch_service::wire::WorkloadControl,
    ) -> Result<(), Rejected> {
        let mut peer = self.scoped_peer()?;
        let response = peer
            .exchange(
                Kind::WorkloadControl,
                Kind::WorkloadControl,
                &json!({"handle":handle,"operation":operation,"budget_ms":1000}),
                Duration::from_millis(1250),
            )
            .map_err(|error| match error {
                WireError::PeerError(code) if code == "not_running" || code == "busy" => {
                    Rejected(409, "native workload is no longer running".into())
                }
                WireError::PeerError(code) if code == "invalid_spec" => {
                    Rejected::bad("invalid resource update")
                }
                _ => Rejected::internal(format!("native cgroup operation failed: {error}")),
            })?;
        if response["handle"] != *handle || response["confirmed"] != true {
            return Err(Rejected::internal(
                "native cgroup operation lost its workload identity",
            ));
        }
        Ok(())
    }

    fn pause(&self, item: &Item, frozen: bool) -> Result<(), Rejected> {
        let _control = item.control.lock().unwrap();
        self.change_pause(item, frozen)
    }

    fn change_pause(&self, item: &Item, frozen: bool) -> Result<(), Rejected> {
        let (handle, generation) = {
            let state = item.state();
            if state.paused == frozen {
                return Err(Rejected(
                    409,
                    "workload already has that pause state".into(),
                ));
            }
            let handle = state
                .native_handle
                .clone()
                .ok_or_else(|| Rejected(409, "pause requires a running native container".into()))?;
            (handle, state.generation)
        };
        self.workload_control(
            &handle,
            conjet_launch_service::wire::WorkloadControl::Freeze { frozen },
        )?;
        let mut state = item.state();
        if state.generation != generation || state.removed || (frozen && state.terminal.is_some()) {
            return Err(Rejected(
                409,
                "workload stopped during the pause operation".into(),
            ));
        }
        state.paused = frozen;
        drop(state);
        self.event(
            &mut self.ledger.lock().unwrap(),
            if frozen { "pause" } else { "unpause" },
            item,
            None,
        );
        item.changed.notify_all();
        Ok(())
    }

    fn update_resources(&self, item: &Item, patch: &Value) -> Result<(), Rejected> {
        use conjet_launch_service::wire::WorkloadControl;
        const LIMITS: &[&str] = &[
            "Memory",
            "MemorySwap",
            "NanoCpus",
            "PidsLimit",
            "CpuPeriod",
            "CpuQuota",
            "CpusetCpus",
        ];
        let fields = patch
            .as_object()
            .ok_or_else(|| Rejected::bad("expected a Docker resource update object"))?;
        if fields.keys().any(|field| !LIMITS.contains(&field.as_str())) {
            return Err(Rejected::bad("unsupported native Docker resource update"));
        }
        let _control = item.control.lock().unwrap();
        let (after, previous, handle) = {
            let state = item.state();
            if state.removed
                || state.error.is_some()
                || item.container.buildkit_worker
                || (state.started && state.terminal.is_none() && state.native_handle.is_none())
            {
                return Err(Rejected(
                    409,
                    "native workload is not available for resource update".into(),
                ));
            }
            let current = state
                .resource_override
                .as_ref()
                .map_or(&item.container.config["HostConfig"], |(host, _)| host);
            let previous = request::resource_options(current)?;
            let mut updated = current.clone();
            for (field, value) in fields {
                if !value.is_null() && !(field == "CpusetCpus" && value == "") {
                    updated[field] = value.clone();
                }
            }
            (updated, previous, state.native_handle.clone())
        };
        // Validate the complete resulting configuration before any kernel write.
        let updated = request::resource_options(&after)?;
        let apply = |handle: &Value, resources: request::ResourceOptions| {
            self.workload_control(
                handle,
                WorkloadControl::Limits {
                    limits: resources.limits,
                    disable_swap: resources.disable_swap,
                },
            )
        };
        if let Some(handle) = &handle {
            apply(handle, updated)?;
        }
        let mut ledger = self.ledger.lock().unwrap();
        let mut records = ledger.saved_containers.clone();
        if let Some(record) = records.get_mut(&item.container.id) {
            record.config["HostConfig"] = after.clone();
            if let Err(error) = self.publish_containers(&mut ledger, records) {
                drop(ledger);
                if let Some(handle) = &handle {
                    apply(handle, previous)?;
                }
                return Err(error);
            }
        }
        item.state().resource_override = Some((after, updated));
        self.event(&mut ledger, "update", item, None);
        Ok(())
    }

    fn stats(&self, item: &Item, one_shot: bool) -> Result<Value, Rejected> {
        use conjet_launch_service::wire::CgroupUsage;

        let (handle, generation) = {
            let state = item.wait_for(
                |state| {
                    state.native_handle.is_some()
                        || !state.started
                        || state.terminal.is_some()
                        || state.error.is_some()
                        || state.removed
                },
                1,
            )?;
            let handle = state.native_handle.clone().ok_or_else(|| {
                Rejected(409, "statistics require a running native container".into())
            })?;
            (handle, state.generation)
        };
        let mut peer = self.scoped_peer()?;
        let request = json!({"workload": handle, "budget_ms": 500});
        let mut read = || {
            let reply = peer
                .exchange(
                    Kind::Inspect,
                    Kind::Inspect,
                    &request,
                    Duration::from_secs(1),
                )
                .map_err(|error| match error {
                    WireError::PeerError(code) if code == "not_running" => {
                        Rejected(409, "statistics require a running native container".into())
                    }
                    _ => Rejected::internal(error.to_string()),
                })?;
            if reply["handle"] != handle {
                return Err(Rejected::internal("statistics workload identity changed"));
            }
            serde_json::from_value::<CgroupUsage>(reply["usage"].clone())
                .map_err(|_| Rejected::internal("invalid native workload statistics"))
        };
        let started = events::daemon_time()?;
        let previous = if one_shot {
            None
        } else {
            let counters = read()?;
            thread::sleep(Duration::from_millis(100));
            Some(counters)
        };
        let current = read()?;
        let observed = events::daemon_time()?;
        let state = item.state();
        if state.generation != generation || state.native_handle.as_ref() != Some(&handle) {
            return Err(Rejected(
                409,
                "statistics target generation has exited".into(),
            ));
        }
        let cpu = |sample: &CgroupUsage| {
            json!({
                "cpu_usage":{"total_usage":sample.cpu_ns},
                "system_cpu_usage":sample.system_ns,"online_cpus":sample.cpus,
                "throttling_data":{
                    "periods":sample.cpu_periods,
                    "throttled_periods":sample.cpu_throttled_periods,
                    "throttled_time":sample.cpu_throttled_ns,
                },
            })
        };
        Ok(json!({
            "id":item.container.id, "name":format!("/{}", item.container.name().as_str()),
            "read":observed, "preread":started,
            "cpu_stats":cpu(&current),
            "precpu_stats":previous.as_ref().map(cpu).unwrap_or_else(|| json!({})),
            "memory_stats":{"usage":current.memory_bytes,"limit":current.memory_limit,
                            "stats":{"inactive_file":current.inactive_file}},
            "pids_stats":{"current":current.tasks},
        }))
    }

    fn rename(&self, item: &Arc<Item>, name: &str) -> Result<(), Rejected> {
        let _control = item.control.lock().unwrap();
        let mut ledger = self.ledger.lock().unwrap();
        let mut state = item.state();
        if state.removed || state.started || state.replacement_name.as_deref() != Some(name) {
            return Err(Rejected::bad(
                "rename requires an unstarted owned Compose replacement",
            ));
        }
        if ledger.closing
            || ledger.poisoned
            || ledger
                .active
                .iter()
                .any(|entry| entry.container.name().as_str() == name)
        {
            return Err(Rejected(
                409,
                "container name is occupied or unresolved".into(),
            ));
        }
        *item.container.name() = name.to_owned();
        state.replacement_name = None;
        self.event(&mut ledger, "rename", item, None);
        Ok(())
    }

    fn submit(self: &Arc<Self>, item: &Arc<Item>, emit_restart: bool) -> Result<(), Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        let mut state = item.state();
        if !ledger.active.iter().any(|active| Arc::ptr_eq(active, item))
            || (state.started && state.terminal.is_none())
            || ledger.poisoned
            || ledger.closing
            || ledger
                .saved_containers
                .get(&item.container.id)
                .is_some_and(|record| record.removing)
        {
            return Err(Rejected(
                409,
                "container has already been submitted or removed".into(),
            ));
        }
        if state.replacement_name.is_some() {
            return Err(Rejected(
                409,
                "Compose replacement must be renamed before start".into(),
            ));
        }
        if item.container.buildkit_worker {
            state.started_at = Some(events::daemon_time()?);
        }
        for index in (0..ledger.workers.len()).rev() {
            if ledger.workers[index].is_finished() {
                let _ = ledger.workers.swap_remove(index).join();
            }
        }
        if ledger.workers.len() >= CONTAINERS {
            return Err(Rejected(409, "native launch workers are occupied".into()));
        }
        let generation = if state.started {
            state
                .generation
                .checked_add(1)
                .ok_or_else(|| Rejected::internal("container generation exhausted"))?
        } else {
            state.generation
        };
        let spec = Self::generation_spec(item, &state);
        let previous_records = if ledger.saved_containers.contains_key(&item.container.id) {
            let previous = ledger.saved_containers.clone();
            let mut records = previous.clone();
            let record = records
                .get_mut(&item.container.id)
                .expect("saved container");
            record.started_at = Some(events::daemon_time()?);
            record.exit_code = None;
            record.generation = generation;
            record.restart_count = 0;
            record.manually_stopped = false;
            self.publish_containers(&mut ledger, records)?;
            Some(previous)
        } else {
            None
        };
        item.container.cancel.store(0, Ordering::Release);
        let owner = self.clone();
        let work = item.clone();
        let worker = match thread::Builder::new().spawn(move || owner.run(work, generation, spec)) {
            Ok(worker) => worker,
            Err(_) => {
                if let Some(records) = previous_records {
                    self.publish_containers(&mut ledger, records)?;
                }
                return Err(Rejected::internal("native worker allocation failed"));
            }
        };
        ledger.workers.push(worker);
        self.begin_generation(&mut ledger, item, &mut state, generation, emit_restart);
        Ok(())
    }

    fn generation_spec(item: &Item, state: &Lifecycle) -> Option<Value> {
        if state.network.is_none() && state.resource_override.is_none() {
            return None;
        }
        let mut spec = item.container.spec.clone();
        if let Some(attachment) = &state.network {
            spec["network"] = json!(attachment.network.scope.wire_mode());
            spec["network_alias"] = json!(attachment.aliases[0]);
            if let Some(alias) = attachment.aliases.get(1) {
                spec["secondary_network_alias"] = json!(alias);
            }
            if let Some(project) = &attachment.alias_project {
                spec["network_alias_project"] = json!(project);
            }
        } else {
            spec["network"] = json!("none");
        }
        if let Some((_, resources)) = &state.resource_override {
            spec["limits"] = json!(resources.limits);
            spec["docker_resource_defaults"] = json!(resources.limits.has_unlimited());
            spec["memory_swap_disabled"] = json!(resources.disable_swap);
        }
        Some(spec)
    }

    fn begin_generation(
        &self,
        ledger: &mut Ledger,
        item: &Item,
        state: &mut Lifecycle,
        generation: u64,
        emit_restart: bool,
    ) {
        if let Some(record) = ledger.saved_containers.get(&item.container.id) {
            state.started_at.clone_from(&record.started_at);
            state.restart_count = record.restart_count;
        }
        if let Some(terminal) = state.terminal.take() {
            if state.previous.len() == 4 {
                state.previous.pop_front();
            }
            state.previous.push_back((state.generation, terminal));
        }
        state.generation = generation;
        state.error = None;
        state.manually_stopped = false;
        state.restarting = false;
        state.paused = false;
        state.live = Default::default();
        state.native_handle = None;
        state.network_address = None;
        state.health = item
            .container
            .healthcheck
            .as_ref()
            .map(|_| health::State::starting(Instant::now()));
        state.started = true;
        if emit_restart {
            self.event(ledger, "restart", item, None);
        }
        self.event(ledger, "start", item, None);
        item.changed.notify_all();
    }

    fn run(&self, item: Arc<Item>, mut generation: u64, mut spec: Option<Value>) {
        let mut delay = Duration::ZERO;
        loop {
            let began = Instant::now();
            if !self.run_generation(&item, generation, spec.as_ref()) {
                return;
            }
            delay = restart_policy::backoff(delay, began.elapsed());
            if !self.wait_restart_delay(&item, generation, delay) {
                return;
            }
            let _control = item.control.lock().unwrap();
            let mut ledger = self.ledger.lock().unwrap();
            let mut state = item.state();
            if ledger.closing
                || ledger.poisoned
                || state.removed
                || !state.restarting
                || state.manually_stopped
                || state.generation != generation
            {
                return;
            }
            match self.prepare_automatic_restart(&mut ledger, &item, &state) {
                Ok(next) => {
                    generation = next;
                    spec = Self::generation_spec(&item, &state);
                    self.begin_generation(&mut ledger, &item, &mut state, generation, true);
                }
                Err(error) => {
                    state.restarting = false;
                    state.error = Some(error.1);
                    item.changed.notify_all();
                    return;
                }
            }
        }
    }

    fn wait_restart_delay(&self, item: &Item, generation: u64, delay: Duration) -> bool {
        let state = item.state();
        let (state, _) = item
            .changed
            .wait_timeout_while(state, delay, |state| {
                state.restarting
                    && !state.manually_stopped
                    && state.generation == generation
                    && !state.removed
            })
            .unwrap();
        state.restarting
            && !state.manually_stopped
            && state.generation == generation
            && !state.removed
    }

    fn prepare_automatic_restart(
        &self,
        ledger: &mut Ledger,
        item: &Item,
        state: &Lifecycle,
    ) -> Result<u64, Rejected> {
        let next = state
            .generation
            .checked_add(1)
            .ok_or_else(|| Rejected::internal("container generation exhausted"))?;
        let mut records = ledger.saved_containers.clone();
        let record = records
            .get_mut(&item.container.id)
            .ok_or_else(|| Rejected::internal("restart policy lost its retained record"))?;
        record.generation = next;
        record.restart_count = record.restart_count.saturating_add(1);
        record.started_at = Some(events::daemon_time()?);
        record.exit_code = None;
        self.publish_containers(ledger, records)?;
        Ok(next)
    }

    fn run_generation(&self, item: &Arc<Item>, generation: u64, spec: Option<&Value>) -> bool {
        let signal = item.container.cancel.load(Ordering::Acquire);
        let terminal = if signal != 0 {
            Ok(Terminal {
                code: 128 + i64::from(signal),
                stdout: Vec::new(),
                stderr: Vec::new(),
                delivery_error: None,
                witness: json!({"cleanup":"not_admitted"}),
            })
        } else {
            self.run_admitted(item, generation, spec.unwrap_or(&item.container.spec))
        };
        let mut ledger = self.ledger.lock().unwrap();
        let mut state = item.state();
        state.native_handle = None;
        state.network_address = None;
        state.paused = false;
        if let Some(published) = item.published.lock().unwrap().as_ref() {
            published.set_target(None);
        }
        match terminal {
            Ok(terminal) => {
                if ledger.saved_containers.contains_key(&item.container.id) {
                    let mut records = ledger.saved_containers.clone();
                    let record = records
                        .get_mut(&item.container.id)
                        .expect("saved container");
                    record.exit_code = Some(terminal.code);
                    if let Err(error) = self.publish_containers(&mut ledger, records) {
                        state.error = Some(error.1);
                    }
                }
                self.event(&mut ledger, "die", item, Some(&terminal));
                state.live = Default::default();
                state.restarting = !ledger.closing
                    && !state.manually_stopped
                    && state.error.is_none()
                    && item
                        .container
                        .restart_policy
                        .after_exit(terminal.code, state.restart_count);
                state.terminal = Some(Arc::new(terminal));
                if item.container.auto_remove {
                    self.retire(&mut ledger, item, &mut state);
                }
            }
            Err(error) => {
                ledger.poisoned = true;
                state.error = Some(format!("{error:#}"));
            }
        }
        item.changed.notify_all();
        state.restarting
    }

    fn run_admitted(&self, item: &Item, generation: u64, spec: &Value) -> anyhow::Result<Terminal> {
        let bind = item
            .container
            .bind
            .as_ref()
            .map(|bind| bind.start(self))
            .transpose()?;
        let bound_spec = bind.as_ref().map(|lease| {
            let mut spec = spec.clone();
            spec["binds"] = json!(lease.bindings());
            spec
        });
        let admitted = self
            .native
            .lock()
            .unwrap()
            .begin(bound_spec.as_ref().unwrap_or(spec));
        let mut result = admitted.and_then(|mut admitted| {
            item.state().native_handle = Some(admitted.state["handle"].clone());
            item.changed.notify_all();
            let result = wait_for_native(self, &mut admitted, item, generation);
            self.native.lock().unwrap().finish(admitted, result.is_ok());
            result
        });
        if let Some(bind) = bind {
            bind.finish()?;
            if let Ok(terminal) = &mut result {
                terminal.witness["bind_cleanup"] = json!("complete");
            }
        }
        result
    }

    fn retire(&self, ledger: &mut Ledger, item: &Arc<Item>, state: &mut Lifecycle) {
        drop(item.published.lock().unwrap().take());
        state.removed = true;
        ledger
            .active
            .retain(|candidate| !Arc::ptr_eq(candidate, item));
        if ledger.history.len() == 16 {
            ledger.history.pop_back();
        }
        ledger.history.push_front(item.clone());
        self.event(ledger, "destroy", item, None);
        item.changed.notify_all();
    }

    fn stop(&self, item: &Arc<Item>, signal: u8, grace: u64) -> Result<bool, Rejected> {
        let _control = item.control.lock().unwrap();
        if item.state().paused {
            return Err(Rejected(409, "cannot stop a paused container".into()));
        }
        let cancelled = self.mark_stopped(item)?;
        self.stop_generation(item, signal, grace)
            .map(|stopped| stopped || cancelled)
    }

    fn mark_stopped(&self, item: &Item) -> Result<bool, Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        let mut state = item.state();
        self.stop_restart_policy(&mut ledger, item, &mut state)
    }

    fn stop_restart_policy(
        &self,
        ledger: &mut Ledger,
        item: &Item,
        state: &mut Lifecycle,
    ) -> Result<bool, Rejected> {
        if !state.started
            || state.removed
            || item.container.restart_policy == restart_policy::Policy::No
        {
            return Ok(false);
        }
        let mut records = ledger.saved_containers.clone();
        let record = records
            .get_mut(&item.container.id)
            .ok_or_else(|| Rejected::internal("restart policy lost its retained record"))?;
        record.manually_stopped = true;
        self.publish_containers(ledger, records)?;
        state.manually_stopped = true;
        let was_restarting = std::mem::take(&mut state.restarting);
        item.changed.notify_all();
        Ok(was_restarting)
    }

    fn stop_generation(&self, item: &Item, signal: u8, grace: u64) -> Result<bool, Rejected> {
        {
            let state = item.state();
            if state.removed {
                return Err(Rejected(404, "container was removed".into()));
            }
            if let Some(error) = &state.error {
                return Err(Rejected::internal(error));
            }
            if state.paused {
                return Err(Rejected(
                    409,
                    "unpause the container before stopping it".into(),
                ));
            }
            if !state.started || state.terminal.is_some() {
                return Ok(false);
            }
        }
        let finished = |state: &Lifecycle| state.terminal.is_some() || state.error.is_some();
        let termination = if signal == TERM && grace > 0 {
            let _ = item.container.cancel.compare_exchange(
                0,
                TERM,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
            item.wait_for(finished, grace).ok()
        } else {
            None
        };
        let state = match termination {
            Some(state) => state,
            None => {
                item.container.cancel.store(KILL, Ordering::Release);
                item.wait_for(finished, 5)?
            }
        };
        if let Some(error) = &state.error {
            return Err(Rejected::internal(error));
        }
        Ok(true)
    }

    fn restart(self: &Arc<Self>, item: &Arc<Item>, grace: u64) -> Result<(), Rejected> {
        let _control = item.control.lock().unwrap();
        if item.container.auto_remove {
            return Err(Rejected::bad("restart requires a retained container"));
        }
        self.mark_stopped(item)?;
        self.stop_generation(item, TERM, grace)?;
        self.submit(item, true)?;
        Self::wait_for_network_start(item)
    }

    fn remove(&self, item: &Arc<Item>, force: bool) -> Result<(), Rejected> {
        let _control = item.control.lock().unwrap();
        let mut cancelled = false;
        loop {
            let mut ledger = self.ledger.lock().unwrap();
            let mut state = item.state();
            if state.removed {
                if cancelled {
                    return Ok(());
                }
                return Err(Rejected(404, "container was already removed".into()));
            }
            if state.error.is_some() {
                return Err(Rejected::internal("guest cleanup is unresolved"));
            }
            if !state.started || state.terminal.is_some() {
                self.remove_saved_container(&mut ledger, &item.container.id)?;
                self.retire(&mut ledger, item, &mut state);
                return Ok(());
            }
            if !force {
                return Err(Rejected(409, "container is running".into()));
            }
            if state.paused {
                drop(state);
                drop(ledger);
                self.change_pause(item, false)?;
                continue;
            }
            self.stop_restart_policy(&mut ledger, item, &mut state)?;
            item.container.cancel.store(KILL, Ordering::Release);
            cancelled = true;
            drop(state);
            drop(ledger);
            drop(item.wait_for(
                |state| state.terminal.is_some() || state.error.is_some(),
                35,
            )?);
        }
    }

    fn shutdown(&self) {
        let worker = {
            let mut ledger = self.ledger.lock().unwrap();
            ledger.closing = true;
            self.event_changed.notify_all();
            for item in &ledger.active {
                item.container.cancel.store(KILL, Ordering::Release);
                // Unstarted admissions own no guest resources.
                let mut state = item.state();
                state.restarting = false;
                if !state.started {
                    state.error = Some("native Docker owner is shutting down".into());
                }
                item.changed.notify_all();
            }
            std::mem::take(&mut ledger.workers)
        };
        for worker in worker {
            let _ = worker.join();
        }
        let ledger = self.ledger.lock().unwrap();
        for item in &ledger.active {
            drop(item.published.lock().unwrap().take());
        }
    }
}

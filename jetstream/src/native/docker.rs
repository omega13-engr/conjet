//! Bounded Docker compatibility endpoint for the isolated OCI candidate.
mod discovery;
mod events;
mod exec;
mod health;
mod http;
mod image;
mod network;
mod port;
mod registry;
mod request;
mod volume;

pub(super) use image::{install, InstallOptions};

use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::io::{self, Read};
use std::net::SocketAddr;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
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
use conjet_launch_service::wire::{Kind, WireError};
use serde_json::{json, Value};

use super::{client, session};

const SCRATCH: &str = "/Volumes/ExternalSSD/dev_workspace/tmp";
const BACKEND: &str = "jetstream-native-oci";
const PLATFORM: &str = "Conjet Native OCI";
const CONNECTIONS: usize = 32;
const CONTAINERS: usize = 8;
const KILL: u8 = 9;
const TERM: u8 = 15;
const CHUNK: usize = 8192;
const STREAM_LIMIT: usize = 65536;
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
    #[arg(long, requires = "registry")]
    image_store: Option<PathBuf>,
    #[arg(long, requires = "image_store")]
    registry: Option<SocketAddr>,
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

fn private_scratch(directory: &Path) -> anyhow::Result<()> {
    let info = directory.symlink_metadata()?;
    ensure!(
        directory.starts_with(SCRATCH)
            && directory.canonicalize()? == directory
            && info.is_dir()
            && info.uid() == unsafe { libc::geteuid() }
            && info.mode() & 0o077 == 0,
        "expected a private ExternalSSD directory"
    );
    Ok(())
}

pub(super) fn stop(directory: &Path) -> anyhow::Result<()> {
    private_scratch(directory)?;
    let (identity, key) = client::load(directory)?;
    let peer = client::Connection::open(directory, &identity, &key)?;
    ensure!(peer.oci, "Docker stop requires an OCI guest");
    client::stop_peer(peer)
}

pub(super) fn boot(options: session::Options) -> anyhow::Result<()> {
    ensure!(
        options.oci_package.is_some() && options.scratch.canonicalize()? == Path::new(SCRATCH),
        "Docker boot requires an OCI package and ExternalSSD scratch"
    );
    session::serve(options)
}

struct OwnedSocket(PathBuf);

impl Drop for OwnedSocket {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub(super) fn serve(options: Options) -> anyhow::Result<()> {
    private_scratch(&options.native_session)?;
    private_scratch(
        options
            .socket
            .parent()
            .context("missing Docker socket directory")?,
    )?;
    ensure!(
        options
            .socket
            .symlink_metadata()
            .is_err_and(|error| error.kind() == io::ErrorKind::NotFound),
        "Docker endpoint already exists or is inaccessible"
    );
    let receipt = options.receipt.canonicalize()?;
    ensure!(
        receipt == options.receipt && receipt.starts_with(SCRATCH),
        "receipt must reside on ExternalSSD"
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
        .zip(options.registry)
        .map(|(root, address)| registry::Store::open(root, address, &status))
        .transpose()?;
    let sequence = status["last_sequence"]
        .as_u64()
        .context("missing sequence")?;
    let native = Native {
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
    };
    serve_endpoint(
        options.socket,
        metadata,
        native,
        store,
        options.trace_requests,
    )
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
    trace_requests: bool,
) -> anyhow::Result<()> {
    let boot = &native.boot;
    signal_handlers()?;
    let listener = UnixListener::bind(&socket)?;
    let _socket = OwnedSocket(socket);
    fs::set_permissions(&_socket.0, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    println!(
        "{}",
        json!({"socket":_socket.0, "boot_id":boot, "backend":BACKEND})
    );
    let owner = Arc::new(Owner::new(metadata, native, store));
    let mut handlers: Vec<JoinHandle<()>> = Vec::with_capacity(CONNECTIONS);
    let result = loop {
        for i in (0..handlers.len()).rev() {
            if handlers[i].is_finished() {
                let _ = handlers.swap_remove(i).join();
            }
        }
        if STOP.load(Ordering::Acquire) {
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
    pool: Vec<client::Connection>,
    peer_directory: PathBuf,
    identity: session::Identity,
    key: Key,
    boot: String,
    sequence: u64,
    pending: BTreeMap<u64, Value>,
    broken: bool,
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
                && next <= STREAM_LIMIT,
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
        let result = peer.exchange(
            Kind::Launch, Kind::State,
            &json!({"boot_id":peer.boot,"sequence":sequence,"operation_id":operation,"budget_ms":1000,"spec":spec}),
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
    let mut state = std::mem::take(&mut admission.state);
    let peer = &mut admission.peer;
    let began = admission.began;
    let admitted = admission.admitted;
    let handle = state["handle"].clone();
    let mut sent_signal = 0;
    let mut waits = 0;
    let mut awaiting_address = item.state().network.is_some();
    let mut awaiting_health = item.container.healthcheck.is_some();
    while state["cleanup"] != "complete" {
        ensure!(
            state["cleanup"] != "failed" && admitted.elapsed() < Duration::from_secs(32),
            "native guest cleanup remains unresolved"
        );
        let requested = item.container.cancel.load(Ordering::Acquire);
        if requested == 0 && item.container.healthcheck.is_some() && state["phase"] == "running" {
            awaiting_health = false;
            health::probe(owner, item, generation, &handle);
        }
        let result = if requested != 0 && requested != sent_signal {
            sent_signal = requested;
            peer.exchange(
                Kind::Cancel,
                Kind::State,
                &json!({"handle":handle,"budget_ms":1000,"signal":requested}),
                Duration::from_secs(2),
            )
        } else {
            waits += 1;
            let (stdout, stderr) = {
                let status = item.state();
                (status.live[0].len(), status.live[1].len())
            };
            peer.exchange(
                Kind::Wait, Kind::State,
                &json!({"handle":handle,"after_revision":if awaiting_address || awaiting_health { state["revision"].as_u64().context("invalid workload revision")? } else { u64::MAX },"budget_ms":100,"terminal_output":true,
                        "live_output":{"stdout":stdout,"stderr":stderr}}),
                Duration::from_secs(2),
            )
        };
        match result {
            Err(WireError::PeerError(code)) if code == "deadline_exceeded" => continue,
            other => state = other?,
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
            if lifecycle.network.is_some() && lifecycle.network_address.is_none() {
                lifecycle.network_address = Some(checked_network_address(address)?);
                if let Some(port) = item.published.lock().unwrap().as_ref() {
                    port.set_target(Some(handle.clone()));
                }
            }
            awaiting_address = false;
        }
        if let Some(live) = state.get("live_output") {
            item.publish_output(generation, live)?;
        }
    }
    let terminal = Instant::now();
    let code = if sent_signal != 0 && state["exit"].is_null() && state["helper_failed"] == false {
        128 + i64::from(sent_signal)
    } else {
        ensure!(
            state["exec"] == "confirmed" && state["helper_failed"] == false,
            "native guest did not confirm OCI exec"
        );
        match state["exit"]["code"].as_i64() {
            Some(code) => code,
            None => {
                128 + state["exit"]["signal"]
                    .as_i64()
                    .context("missing guest exit status")?
            }
        }
    };
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
    let (stdout, stdout_dropped) = read_stream(
        peer,
        &handle,
        "stdout",
        streams.remove("stdout"),
        live_stdout,
        &mut calls,
    )?;
    let (stderr, stderr_dropped) = read_stream(
        peer,
        &handle,
        "stderr",
        streams.remove("stderr"),
        live_stderr,
        &mut calls,
    )?;
    let delivery_error = (stdout_dropped || stderr_dropped)
        .then(|| "OCI output exceeds the Docker adapter limit".into());
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
    name: String,
    config: Value,
    spec: Value,
    volume: Option<conjet_launch_service::spec::VolumeMount>,
    created: u64,
    healthcheck: Option<health::Config>,
    auto_remove: bool,
    cancel: AtomicU8,
}

#[derive(Default)]
struct Lifecycle {
    started: bool,
    terminal: Option<Arc<Terminal>>,
    error: Option<String>,
    removed: bool,
    generation: u64,
    previous: VecDeque<(u64, Arc<Terminal>)>,
    live: [Vec<u8>; 2],
    native_handle: Option<Value>,
    network: Option<network::Attachment>,
    network_address: Option<String>,
    health: Option<health::State>,
}

impl Lifecycle {
    fn status(&self) -> &'static str {
        if self.terminal.is_some() || self.error.is_some() {
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
                    && next <= STREAM_LIMIT
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
    history: VecDeque<Arc<Item>>,
    events: VecDeque<Value>,
    discarded_events: usize,
    workers: Vec<JoinHandle<()>>,
    execs: VecDeque<Arc<exec::Entry>>,
    poisoned: bool,
    closing: bool,
    network: Option<network::Network>,
}

fn checked_network_address(address: &str) -> anyhow::Result<String> {
    let octets = address.parse::<std::net::Ipv4Addr>()?.octets();
    ensure!(
        matches!(octets, [198, 18, 0, 2..=9]),
        "invalid private bridge address"
    );
    Ok(address.to_owned())
}

struct Owner {
    image: request::Image,
    native: Mutex<Native>,
    ledger: Mutex<Ledger>,
    store: Option<Mutex<registry::Store>>,
    exec_peer: Mutex<Option<client::Connection>>,
    event_changed: Condvar,
}

impl Owner {
    fn new(image: request::Image, native: Native, store: Option<registry::Store>) -> Self {
        Self {
            image,
            native: Mutex::new(native),
            ledger: Mutex::new(Ledger::default()),
            store: store.map(Mutex::new),
            exec_peer: Mutex::new(None),
            event_changed: Condvar::new(),
        }
    }

    fn boot_reference(&self, reference: &str) -> bool {
        reference == self.image.reference || reference == self.image.config_digest
    }

    fn image_store(&self) -> Result<MutexGuard<'_, registry::Store>, Rejected> {
        self.store
            .as_ref()
            .map(|store| store.lock().unwrap())
            .ok_or_else(|| Rejected(501, "native registry store is not configured".into()))
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

    fn process(&self, config: &Value) -> Result<Value, Rejected> {
        let reference = config["Image"]
            .as_str()
            .ok_or_else(|| Rejected::bad("require an immutable image reference"))?;
        if reference == self.image.reference || self.store.is_none() {
            return self.image.process(config);
        }
        let mut store = self.image_store()?;
        let image = store
            .get(reference)
            .map_err(|error| Rejected::bad(error.to_string()))?
            .ok_or_else(|| Rejected(404, "image is not staged".into()))?;
        let spec = image.metadata.process(config)?;
        if !store
            .installed(&image)
            .map_err(|error| Rejected::internal(error.to_string()))?
        {
            self.with_guest(|peer| store.ensure_guest(peer, &image))?;
        }
        Ok(spec)
    }

    fn check_network_aliases(ledger: &Ledger, aliases: &[String]) -> Result<(), Rejected> {
        if ledger.active.iter().any(|item| {
            item.state().network.as_ref().is_some_and(|entry| {
                entry
                    .aliases
                    .iter()
                    .any(|old| aliases.iter().any(|alias| old.eq_ignore_ascii_case(alias)))
            })
        }) {
            return Err(Rejected(409, "private DNS alias is already owned".into()));
        }
        Ok(())
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
        json!(ledger
            .network
            .iter()
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
            if (!all && state.status() != "running") || !filters.matches(&container.name, labels) {
                return None;
            }
            let command = container.spec["argv"].as_array().expect("validated native argv")
                .iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ");
            let networks = state.network.as_ref().map_or_else(|| json!({}), |attachment| {
                json!({(attachment.network.name.as_str()):attachment.inspect(state.network_address.as_deref())})
            });
            let ports = item.published.lock().unwrap().as_ref()
                .filter(|_| state.network_address.is_some())
                .map(port::PublishedPort::summary).into_iter().collect::<Vec<_>>();
            Some(json!({"Id":container.id,"Names":[format!("/{}",container.name)],
                        "Image":container.config["Image"],"ImageID":container.spec["image_digest"],
                        "Command":command,"Created":container.created,"Labels":labels,
                        "State":state.status(),"Status":state.status(),
                        "NetworkSettings":{"Networks":networks},"Ports":ports,
                        "Mounts":container.volume.iter().map(volume::mount_metadata).collect::<Vec<_>>() }))
        }).collect::<Vec<_>>();
        json!(selected)
    }

    fn inspect_network(&self, reference: &str) -> Result<Value, Rejected> {
        let ledger = self.ledger.lock().unwrap();
        let network = ledger
            .network
            .as_ref()
            .filter(|entry| entry.matches(reference))
            .ok_or_else(|| Rejected(404, "private bridge was not found".into()))?;
        let mut endpoints = serde_json::Map::new();
        for item in &ledger.active {
            let state = item.state();
            if let Some(ip) = &state.network_address {
                endpoints.insert(item.container.id.clone(),
                    json!({"Name":item.container.name,"IPv4Address":format!("{ip}/28"),"IPv6Address":""}));
            }
        }
        Ok(network.inspect(Value::Object(endpoints)))
    }

    fn remove_network(&self, reference: &str) -> Result<(), Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        if !ledger
            .network
            .as_ref()
            .is_some_and(|network| network.matches(reference))
        {
            return Err(Rejected(404, "private bridge was not found".into()));
        }
        if ledger
            .active
            .iter()
            .any(|item| item.state().network.is_some())
        {
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
        let network = ledger
            .network
            .as_ref()
            .filter(|entry| entry.matches(reference))
            .ok_or_else(|| Rejected(404, "private bridge was not found".into()))?;
        let attachment = endpoint
            .map(|endpoint| network::Attachment::new(network, endpoint, &item.container.name))
            .transpose()?;
        if let Some(entry) = &attachment {
            Self::check_network_aliases(&ledger, &entry.aliases)?;
        }
        let mut state = item.state();
        if state.removed || state.error.is_some() {
            return Err(Rejected(
                404,
                "container no longer owns an eligible lifecycle".into(),
            ));
        }
        if state.network.is_some() == attachment.is_some() {
            return Err(Rejected(
                409,
                "container already has that network disposition".into(),
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
                |entry| json!({"action":"connect","handle":handle,"alias":entry.aliases[0]}),
            );
            let reply = self.exchange_network(operation)?;
            let address = reply["network_address"]
                .as_str()
                .map(checked_network_address)
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
        let info = |image: &request::Image| {
            json!({
                "Id":image.config_digest,"Os":"linux","Architecture":"arm64",
                "Config":image.defaults,"RepoDigests":[image.reference],
            })
        };
        if self.boot_reference(reference) {
            return Ok(info(&self.image));
        }
        let missing = || Rejected(404, "image is not staged".into());
        let store = self.store.as_ref().ok_or_else(missing)?.lock().unwrap();
        store
            .get(reference)
            .map_err(|_| missing())?
            .as_ref()
            .map(|image| info(&image.metadata))
            .ok_or_else(missing)
    }

    fn pull_image(&self, reference: &str) -> Result<Value, Rejected> {
        let ledger = self.ledger.lock().unwrap();
        if !ledger.active.is_empty() || ledger.poisoned || ledger.closing {
            return Err(Rejected(
                409,
                "native guest must be idle to pull an image".into(),
            ));
        }
        if self.boot_reference(reference) {
            return Ok(json!({"status":"Image is already staged","id":reference}));
        }
        let mut store = self.image_store()?;
        store
            .validate_reference(reference)
            .map_err(|error| Rejected::bad(error.to_string()))?;
        let image = store
            .prepare(reference)
            .map_err(|error| Rejected::internal(format!("{error:#}")))?;
        self.with_guest(|peer| store.ensure_guest(peer, &image))?;
        Ok(json!({"status":"Image is staged","id":reference}))
    }

    fn remove_image(&self, reference: &str) -> Result<Value, Rejected> {
        let ledger = self.ledger.lock().unwrap();
        if !ledger.active.is_empty()
            || ledger.poisoned
            || ledger.closing
            || self.boot_reference(reference)
        {
            return Err(Rejected(
                409,
                "image is referenced by the boot or a container".into(),
            ));
        }
        let mut store = self.image_store()?;
        let image = store
            .get(reference)
            .map_err(|error| Rejected::bad(error.to_string()))?
            .ok_or_else(|| Rejected(404, "image is not staged".into()))?;
        let config = image.metadata.config_digest.clone();
        self.with_guest(|peer| store.remove(peer, image))?;
        Ok(json!([{"Untagged":reference},{"Deleted":config}]))
    }

    fn event(&self, ledger: &mut Ledger, action: &str, item: &Item, terminal: Option<&Terminal>) {
        let mut attributes = json!({"name":item.container.name,"image":item.container.config["Image"],"conjet.backend":BACKEND});
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
            if ledger.active.iter().any(|item| item.container.name == name) {
                return Err(Rejected(
                    409,
                    "native container name is already owned".into(),
                ));
            }
        }
        let id = hex(&random::<32>()
            .map_err(|_| Rejected::internal("cannot allocate container identity"))?);
        let name = name.unwrap_or(&id[..12]).to_owned();
        let volume = volume::requested(&config)?
            .map(|(name, read_only)| {
                let info = volume::ask(self, "inspect", Some(name))?;
                let inode = info["inode"]
                    .as_u64()
                    .filter(|value| *value > 0)
                    .ok_or_else(|| Rejected::internal("native volume has no inode identity"))?;
                Ok::<_, Rejected>(conjet_launch_service::spec::VolumeMount {
                    name: name.into(),
                    read_only,
                    inode,
                })
            })
            .transpose()?;
        let network = network::configured(&config, ledger.network.as_ref(), &name)?;
        if let Some(attachment) = &network {
            Self::check_network_aliases(&ledger, &attachment.aliases)?;
        }
        let publication = port::RequestedPort::parse(&config)?;
        if publication.is_some() {
            if network.is_none() {
                return Err(Rejected::bad(
                    "loopback port publication requires an internal bridge",
                ));
            }
            if ledger
                .active
                .iter()
                .any(|entry| entry.published.lock().unwrap().is_some())
            {
                return Err(Rejected(
                    409,
                    "the native loopback binding is already owned".into(),
                ));
            }
        }
        let mut spec = if network.is_some() || volume.is_some() {
            let mut process = config.clone();
            if network.is_some() {
                process["HostConfig"]["NetworkMode"] = json!("none");
                process["NetworkingConfig"] = Value::Null;
            }
            if volume.is_some() {
                let host = process["HostConfig"]
                    .as_object_mut()
                    .expect("Docker host config");
                host.remove("Mounts");
                host.remove("Binds");
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
            self.process(&process)?
        } else {
            self.process(&config)?
        };
        if let Some(volume) = &volume {
            spec["volume"] = json!(volume);
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
        let item = Arc::new(Item {
            container: Container {
                id,
                name,
                config,
                spec,
                volume,
                created: SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs(),
                healthcheck,
                auto_remove,
                cancel: AtomicU8::new(0),
            },
            state: Mutex::new(Lifecycle {
                network,
                ..Lifecycle::default()
            }),
            control: Mutex::new(()),
            changed: Condvar::new(),
            published: Mutex::new(published),
        });
        ledger.active.push(item.clone());
        self.event(&mut ledger, "create", &item, None);
        Ok(item)
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
                id == container.id || id == &container.id[..12] || id == container.name
            })
            .cloned()
            .ok_or_else(|| Rejected(404, "container was not found".into()))
    }

    fn start(self: &Arc<Self>, item: &Arc<Item>) -> Result<(), Rejected> {
        let _control = item.control.lock().unwrap();
        self.submit(item, false)
    }

    fn submit(self: &Arc<Self>, item: &Arc<Item>, restart: bool) -> Result<(), Rejected> {
        let mut ledger = self.ledger.lock().unwrap();
        let mut state = item.state();
        if !ledger.active.iter().any(|active| Arc::ptr_eq(active, item))
            || (state.started && (!restart || state.terminal.is_none()))
            || ledger.poisoned
            || ledger.closing
        {
            return Err(Rejected(
                409,
                "container has already been submitted or removed".into(),
            ));
        }
        for index in (0..ledger.workers.len()).rev() {
            if ledger.workers[index].is_finished() {
                let _ = ledger.workers.swap_remove(index).join();
            }
        }
        if ledger.workers.len() >= CONTAINERS {
            return Err(Rejected(409, "native launch workers are occupied".into()));
        }
        let generation = if restart && state.started {
            state
                .generation
                .checked_add(1)
                .ok_or_else(|| Rejected::internal("container generation exhausted"))?
        } else {
            state.generation
        };
        item.container.cancel.store(0, Ordering::Release);
        let spec = state.network.as_ref().map(|attachment| {
            let mut spec = item.container.spec.clone();
            spec["network"] = json!("bridge");
            spec["network_alias"] = json!(attachment.aliases[0]);
            if let Some(alias) = attachment.aliases.get(1) {
                spec["secondary_network_alias"] = json!(alias);
            }
            spec
        });
        let owner = self.clone();
        let work = item.clone();
        let worker = thread::Builder::new()
            .spawn(move || owner.run(work, generation, spec.as_ref()))
            .map_err(|_| Rejected::internal("native worker allocation failed"))?;
        ledger.workers.push(worker);
        if let Some(terminal) = state.terminal.take() {
            let previous = state.generation;
            if state.previous.len() == 4 {
                state.previous.pop_front();
            }
            state.previous.push_back((previous, terminal));
        }
        state.generation = generation;
        state.live = Default::default();
        state.native_handle = None;
        state.network_address = None;
        state.health = item
            .container
            .healthcheck
            .as_ref()
            .map(|_| health::State::starting(Instant::now()));
        state.started = true;
        if restart {
            self.event(&mut ledger, "restart", item, None);
        }
        self.event(&mut ledger, "start", item, None);
        item.changed.notify_all();
        Ok(())
    }

    fn run(&self, item: Arc<Item>, generation: u64, spec: Option<&Value>) {
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
            let admitted = self
                .native
                .lock()
                .unwrap()
                .begin(spec.unwrap_or(&item.container.spec));
            admitted.and_then(|mut admitted| {
                item.state().native_handle = Some(admitted.state["handle"].clone());
                let result = wait_for_native(self, &mut admitted, &item, generation);
                self.native.lock().unwrap().finish(admitted, result.is_ok());
                result
            })
        };
        let mut ledger = self.ledger.lock().unwrap();
        let mut state = item.state();
        state.native_handle = None;
        state.network_address = None;
        if let Some(published) = item.published.lock().unwrap().as_ref() {
            published.set_target(None);
        }
        match terminal {
            Ok(terminal) => {
                self.event(&mut ledger, "die", &item, Some(&terminal));
                state.live = Default::default();
                state.terminal = Some(Arc::new(terminal));
                if item.container.auto_remove {
                    self.retire(&mut ledger, &item, &mut state);
                }
            }
            Err(error) => {
                ledger.poisoned = true;
                state.error = Some(error.to_string());
            }
        }
        item.changed.notify_all();
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
        self.stop_generation(item, signal, grace)
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
        self.stop_generation(item, TERM, grace)?;
        self.submit(item, true)
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
                self.retire(&mut ledger, item, &mut state);
                return Ok(());
            }
            if !force {
                return Err(Rejected(409, "container is running".into()));
            }
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

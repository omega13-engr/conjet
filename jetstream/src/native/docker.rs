//! Bounded Docker compatibility endpoint for the isolated OCI candidate.
mod http;
mod request;

use std::collections::VecDeque;
use std::fs;
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{ensure, Context};
use base64::Engine;
use clap::Args;
use conjet_launch_service::handshake::{hex, random};
use conjet_launch_service::wire::{Kind, WireError};
use serde_json::{json, Value};

use super::{client, session};

const SCRATCH: &str = "/Volumes/ExternalSSD/dev_workspace/tmp";
const BACKEND: &str = "jetstream-native-oci";
const PLATFORM: &str = "Conjet Native OCI";
const CONNECTIONS: usize = 8;
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

    let lock = client::open_private(&options.native_session.join(session::LOCK))?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::last_os_error()).context("native admission already owned");
    }
    // The lock outlives the authenticated connection and all Docker handlers.
    let (identity, key) = client::load(&options.native_session)?;
    ensure!(
        identity.image_digest == metadata.config_digest,
        "native image mismatch"
    );
    let mut peer = client::Connection::open(&options.native_session, &identity, &key)?;
    ensure!(peer.oci, "native Docker requires OCI capability");
    let status = peer.inspect()?;
    ensure!(
        status["image_digest"] == metadata.config_digest && status["workload"].is_null(),
        "native guest must start dedicated and idle"
    );
    let boot = peer.boot.clone();
    let sequence = status["last_sequence"]
        .as_u64()
        .context("missing sequence")?;
    let native = Native {
        peer: Some(peer),
        sequence,
        pending: None,
    };

    signal_handlers()?;
    let listener = UnixListener::bind(&options.socket)?;
    let _socket = OwnedSocket(options.socket);
    fs::set_permissions(&_socket.0, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    println!(
        "{}",
        json!({"socket":_socket.0, "boot_id":boot, "backend":BACKEND})
    );
    let owner = Arc::new(Owner::new(metadata, native));
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
                    let _ = http::serve(stream, &owner);
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
    peer: Option<client::Connection>,
    sequence: u64,
    pending: Option<Value>,
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
    calls: &mut u32,
) -> anyhow::Result<(Vec<u8>, bool)> {
    let mut data = Vec::new();
    let mut initial = inline;
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
        if chunk["dropped_bytes"]
            .as_u64()
            .context("missing dropped-byte count")?
            > 0
        {
            return Ok((Vec::new(), true));
        }
        data.extend_from_slice(&piece);
        if chunk["eof"].as_bool().context("missing native EOF flag")? {
            return Ok((data, false));
        }
        ensure!(
            from_bundle || !piece.is_empty(),
            "native output did not advance"
        );
    }
}

impl Native {
    fn run(&mut self, spec: &Value, cancellation: &AtomicBool) -> anyhow::Result<Terminal> {
        let mut peer = self
            .peer
            .take()
            .context("authenticated native channel is closed")?;
        if cancellation.load(Ordering::Acquire) {
            self.peer = Some(peer);
            return Ok(Terminal {
                code: 137,
                stdout: Vec::new(),
                stderr: Vec::new(),
                delivery_error: None,
                witness: json!({"cleanup":"not_admitted"}),
            });
        }

        let operation = hex(&random::<16>()?);
        self.sequence = self
            .sequence
            .checked_add(1)
            .context("native sequence exhausted")?;
        self.pending =
            Some(json!({"boot_id":peer.boot,"sequence":self.sequence,"operation_id":operation}));
        let result = execute(&mut peer, self.sequence, &operation, spec, cancellation);
        match result {
            Ok(terminal) => {
                self.pending = None;
                self.peer = Some(peer);
                Ok(terminal)
            }
            Err(error) => Err(error.context(format!("native operation {operation} unresolved"))),
        }
    }
}

fn execute(
    peer: &mut client::Connection,
    sequence: u64,
    operation: &str,
    spec: &Value,
    cancellation: &AtomicBool,
) -> anyhow::Result<Terminal> {
    let began = Instant::now();
    let mut state = peer.exchange(
        Kind::Launch, Kind::State,
        &json!({"boot_id":peer.boot,"sequence":sequence,"operation_id":operation,"budget_ms":1000,"spec":spec}),
        Duration::from_secs(2),
    )?;
    let admitted = Instant::now();
    let handle = state["handle"].clone();
    ensure!(
        handle["boot_id"] == peer.boot && handle["workload_id"].as_str().is_some(),
        "unexpected native launch identity"
    );
    let mut cancelled = false;
    let mut waits = 0;
    while state["cleanup"] != "complete" {
        ensure!(
            state["cleanup"] != "failed" && admitted.elapsed() < Duration::from_secs(32),
            "native guest cleanup remains unresolved"
        );
        let result = if cancellation.load(Ordering::Acquire) && !cancelled {
            cancelled = true;
            peer.exchange(
                Kind::Cancel,
                Kind::State,
                &json!({"handle":handle,"budget_ms":1000}),
                Duration::from_secs(2),
            )
        } else {
            waits += 1;
            peer.exchange(
                Kind::Wait, Kind::State,
                &json!({"handle":handle,"after_revision":u64::MAX,"budget_ms":100,"terminal_output":true}),
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
    }
    let terminal = Instant::now();
    let code = if cancelled && state["exit"].is_null() && state["helper_failed"] == false {
        137
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
    let (mut stdout, stdout_dropped) = read_stream(
        peer,
        &handle,
        "stdout",
        streams.remove("stdout"),
        &mut calls,
    )?;
    let (mut stderr, stderr_dropped) = read_stream(
        peer,
        &handle,
        "stderr",
        streams.remove("stderr"),
        &mut calls,
    )?;
    let delivery_error = (stdout_dropped || stderr_dropped).then(|| {
        stdout.clear();
        stderr.clear();
        "OCI output exceeds the Docker adapter limit".into()
    });
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
    auto_remove: bool,
    cancel: AtomicBool,
}

#[derive(Default)]
struct Lifecycle {
    started: bool,
    terminal: Option<Arc<Terminal>>,
    error: Option<String>,
    removed: bool,
}

struct Item {
    container: Container,
    state: Mutex<Lifecycle>,
    changed: Condvar,
}

impl Item {
    fn state(&self) -> MutexGuard<'_, Lifecycle> {
        self.state.lock().unwrap()
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
    active: Option<Arc<Item>>,
    history: VecDeque<Arc<Item>>,
    events: VecDeque<Value>,
    worker: Option<JoinHandle<()>>,
    poisoned: bool,
    closing: bool,
}

struct Owner {
    image: request::Image,
    native: Mutex<Native>,
    ledger: Mutex<Ledger>,
}

impl Owner {
    fn new(image: request::Image, native: Native) -> Self {
        Self {
            image,
            native: Mutex::new(native),
            ledger: Mutex::new(Ledger::default()),
        }
    }

    fn event(&self, ledger: &mut Ledger, action: &str, item: &Item, terminal: Option<&Terminal>) {
        let mut attributes = json!({"name":item.container.name,"image":self.image.reference,"conjet.backend":BACKEND});
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
        if ledger.events.len() == 16 {
            ledger.events.pop_front();
        }
        ledger
            .events
            .push_back(json!({"Type":"container","Action":action,
                                      "Actor":{"ID":item.container.id,"Attributes":attributes},
                                      "time":now.as_secs(),"timeNano":now.as_nanos()}));
    }

    fn create(&self, name: Option<&str>, config: Value) -> Result<Arc<Item>, Rejected> {
        let spec = self.image.process(&config)?;
        if name.is_some_and(|name| !request::name(name)) {
            return Err(Rejected::bad("invalid container name"));
        }
        let mut ledger = self.ledger.lock().unwrap();
        if ledger.active.is_some() || ledger.poisoned || ledger.closing {
            return Err(Rejected(
                409,
                "native OCI capacity is occupied or unresolved".into(),
            ));
        }
        let id = hex(&random::<32>()
            .map_err(|_| Rejected::internal("cannot allocate container identity"))?);
        let name = name.unwrap_or(&id[..12]).to_owned();
        let auto_remove = config["HostConfig"]["AutoRemove"] == true;
        let item = Arc::new(Item {
            container: Container {
                id,
                name,
                config,
                spec,
                auto_remove,
                cancel: AtomicBool::new(false),
            },
            state: Mutex::new(Lifecycle::default()),
            changed: Condvar::new(),
        });
        ledger.active = Some(item.clone());
        self.event(&mut ledger, "create", &item, None);
        Ok(item)
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
        let mut ledger = self.ledger.lock().unwrap();
        let mut state = item.state();
        if !ledger
            .active
            .as_ref()
            .is_some_and(|active| Arc::ptr_eq(active, item))
            || state.started
            || ledger.closing
        {
            return Err(Rejected(
                409,
                "container has already been submitted or removed".into(),
            ));
        }
        // The previous worker released the ledger before this record could be
        // created. Joining it here bounds the number of launch workers.
        if let Some(worker) = ledger.worker.take() {
            let _ = worker.join();
        }
        let owner = self.clone();
        let work = item.clone();
        let worker = thread::Builder::new()
            .spawn(move || owner.run(work))
            .map_err(|_| Rejected::internal("native worker allocation failed"))?;
        ledger.worker = Some(worker);
        state.started = true;
        self.event(&mut ledger, "start", item, None);
        Ok(())
    }

    fn run(&self, item: Arc<Item>) {
        let terminal = self
            .native
            .lock()
            .unwrap()
            .run(&item.container.spec, &item.container.cancel);
        let mut ledger = self.ledger.lock().unwrap();
        let mut state = item.state();
        match terminal {
            Ok(terminal) => {
                self.event(&mut ledger, "die", &item, Some(&terminal));
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
        state.removed = true;
        ledger.active = None;
        if ledger.history.len() == 4 {
            ledger.history.pop_back();
        }
        ledger.history.push_front(item.clone());
        self.event(ledger, "destroy", item, None);
        item.changed.notify_all();
    }

    fn remove(&self, item: &Arc<Item>, force: bool) -> Result<(), Rejected> {
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
            item.container.cancel.store(true, Ordering::Release);
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
            if let Some(item) = &ledger.active {
                item.container.cancel.store(true, Ordering::Release);
                // Unstarted admissions own no guest resources.
                let mut state = item.state();
                if !state.started {
                    state.error = Some("native Docker owner is shutting down".into());
                }
                item.changed.notify_all();
            }
            ledger.worker.take()
        };
        if let Some(worker) = worker {
            let _ = worker.join();
        }
    }
}

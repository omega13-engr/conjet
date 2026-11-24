use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context};
use base64::Engine;
use clap::{Args, ValueEnum};
use conjet_launch_service::handshake::{hex, host, random, unhex, Key};
use conjet_launch_service::socket::{read_key, Stream};
use conjet_launch_service::spec::{
    LaunchRequest, LaunchSpec, NATIVE_LIMITS, WORKLOAD_GID, WORKLOAD_UID,
};
use conjet_launch_service::wire::{Frame, Kind, WireError};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::session::{Identity, ENDPOINT, KEY, LOCK, MANIFEST};

#[derive(Debug, Args)]
pub(super) struct Target {
    /// Private directory printed by the foreground session.
    #[arg(long)]
    session: PathBuf,
    /// Deadline for the operation, followed by bounded cleanup if it times out.
    #[arg(long, default_value_t = 3000, value_parser = clap::value_parser!(u64).range(100..=30000))]
    timeout_ms: u64,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
pub(super) enum Pressure {
    On,
    Off,
}

pub(super) enum Operation {
    Run,
    Prepare,
    Claim(String),
    Status,
    Cancel(String),
    Memory(Option<Pressure>),
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Handle {
    boot_id: String,
    workload_id: String,
}

impl Handle {
    fn parse(token: &str) -> anyhow::Result<Self> {
        let (boot_id, workload_id) = token.split_once('.').context("invalid workload token")?;
        unhex::<16>(boot_id).context("invalid token generation")?;
        unhex::<16>(workload_id).context("invalid workload ID")?;
        Ok(Self {
            boot_id: boot_id.into(),
            workload_id: workload_id.into(),
        })
    }

    fn token(&self) -> String {
        format!("{}.{}", self.boot_id, self.workload_id)
    }
}

pub(super) struct Connection {
    pub(super) boot: String,
    pub(super) oci: bool,
    pub(super) mapped_ids: bool,
    pub(super) pending_watch: bool,
    stream: Stream,
}

impl Connection {
    pub(super) fn poll_build_registry(&mut self) -> anyhow::Result<bool> {
        let result = self.exchange(
            Kind::BuildRegistry,
            Kind::BuildRegistry,
            &json!({"boot_id":self.boot.clone()}),
            Duration::from_secs(2),
        );
        match result {
            Ok(response) if response["connected"] == true => Ok(true),
            Err(WireError::PeerError(code)) if matches!(code.as_str(), "not_found" | "busy") => {
                Ok(false)
            }
            Err(error) => Err(error.into()),
            _ => anyhow::bail!("invalid BuildKit registry connection acknowledgement"),
        }
    }

    pub(super) fn into_build_registry(mut self) -> Stream {
        self.stream
            .deadline(Some(Instant::now() + Duration::from_secs(180)));
        self.stream
    }

    pub(super) fn open(directory: &Path, identity: &Identity, key: &Key) -> anyhow::Result<Self> {
        let unix = UnixStream::connect(directory.join(ENDPOINT))?;
        let mut pid: libc::pid_t = 0;
        let mut size = std::mem::size_of_val(&pid) as libc::socklen_t;
        // LOCAL_PEERPID is provided by the kernel for the connected socket.
        let result = unsafe {
            libc::getsockopt(
                unix.as_raw_fd(),
                libc::SOL_LOCAL,
                libc::LOCAL_PEERPID,
                (&mut pid as *mut libc::pid_t).cast(),
                &mut size,
            )
        };
        ensure!(
            result == 0
                && pid > 0
                && pid == identity.pid
                && size as usize == std::mem::size_of_val(&pid),
            "native session peer PID mismatch"
        );
        let mut stream = Stream::unix(unix, None)?;
        stream.deadline(Some(Instant::now() + Duration::from_secs(1)));
        let hello = host(&mut stream, key)?;
        let oci = hello
            .capabilities
            .iter()
            .any(|value| value == "native_oci_arm64_v1");
        ensure!(
            oci || hello
                .capabilities
                .iter()
                .any(|value| value == "native_static_arm64_v1"),
            "peer lacks the experimental native protocol"
        );
        Ok(Self {
            boot: hello.boot_id,
            oci,
            mapped_ids: hello
                .capabilities
                .iter()
                .any(|value| value == conjet_launch_service::spec::MAPPED_IDS_CAPABILITY),
            pending_watch: hello.capabilities.iter().any(|value| {
                value == conjet_launch_service::core_admission::PENDING_WATCH_CAPABILITY
            }),
            stream,
        })
    }

    pub(super) fn exchange(
        &mut self,
        kind: Kind,
        response: Kind,
        body: &impl Serialize,
        timeout: Duration,
    ) -> Result<Value, WireError> {
        self.stream.deadline(Some(Instant::now() + timeout));
        let id = random()?;
        Frame::write(&mut self.stream, kind, id, body)?;
        Frame::read(&mut self.stream)?.expect(response, id)
    }

    pub(super) fn inspect(&mut self) -> anyhow::Result<Value> {
        let status = self.exchange(
            Kind::Inspect,
            Kind::Inspect,
            &json!({"budget_ms":1000}),
            Duration::from_secs(2),
        )?;
        ensure!(
            status["boot_id"] == self.boot,
            "native guest generation changed"
        );
        Ok(status)
    }

    pub(super) fn dial(mut self, handle: &Value, port: u16) -> anyhow::Result<Stream> {
        let response = self.exchange(
            Kind::Dial,
            Kind::Dial,
            &json!({"handle":handle, "budget_ms":500, "port":port}),
            Duration::from_secs(2),
        )?;
        ensure!(
            response["connected"] == true,
            "invalid native TCP acknowledgement"
        );
        self.stream.deadline(None);
        Ok(self.stream)
    }

    pub(super) fn exec_stream(
        mut self,
        handle: &Value,
        argv: &[String],
        budget_ms: u64,
    ) -> anyhow::Result<Stream> {
        let deadline = Instant::now() + Duration::from_millis(budget_ms) + Duration::from_secs(5);
        let response = self.exchange(
            Kind::ExecStream,
            Kind::ExecStream,
            &json!({"handle":handle,"argv":argv,"budget_ms":budget_ms}),
            Duration::from_secs(2),
        )?;
        ensure!(
            response["attached"] == true,
            "invalid native exec stream acknowledgement"
        );
        self.stream.deadline(Some(deadline));
        Ok(self.stream)
    }

    pub(super) fn bind(mut self, lease: &str, read_only: bool) -> anyhow::Result<Stream> {
        let reply = self.exchange(
            Kind::Bind,
            Kind::Bind,
            &json!({"boot_id":self.boot,"lease":lease,"read_only":read_only}),
            Duration::from_secs(5),
        )?;
        ensure!(
            reply["lease"] == lease,
            "invalid native bind lease acknowledgement"
        );
        self.stream.deadline(None);
        Ok(self.stream)
    }

    fn state(&mut self, kind: Kind, handle: &Handle) -> anyhow::Result<Value> {
        let state = self.exchange(
            kind,
            Kind::State,
            &json!({"handle":handle, "budget_ms":1000}),
            Duration::from_secs(2),
        )?;
        verify_state(&state, handle)?;
        Ok(state)
    }

    fn wait(
        &mut self,
        handle: &Handle,
        mut state: Value,
        ready: bool,
        deadline: Instant,
    ) -> anyhow::Result<Value> {
        loop {
            let phase = state["phase"].as_str().context("missing workload phase")?;
            if matches!(phase, "removed" | "cleanup_failed") || (ready && phase == "prepared_ready")
            {
                return Ok(state);
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            let budget_ms = remaining.as_millis().min(30_000) as u64;
            ensure!(budget_ms != 0, "operation deadline elapsed");
            let after = state["revision"]
                .as_u64()
                .context("missing workload revision")?;
            state = self.exchange(
                Kind::Wait,
                Kind::State,
                &json!({"handle":handle, "budget_ms":budget_ms, "after_revision":after}),
                remaining + Duration::from_millis(250),
            )?;
            verify_state(&state, handle)?;
        }
    }

    fn collect(&mut self, handle: &Handle, output: &str) -> anyhow::Result<Value> {
        let mut bytes = Vec::new();
        loop {
            let message = self.exchange(Kind::Output, Kind::OutputChunk,
                &json!({"handle":handle, "budget_ms":1000, "stream":output, "offset":bytes.len(), "max_bytes":8192}),
                Duration::from_secs(2))?;
            ensure!(
                message["offset"].as_u64() == Some(bytes.len() as u64),
                "invalid output offset"
            );
            let data = base64::engine::general_purpose::STANDARD
                .decode(message["data"].as_str().context("missing output data")?)?;
            let next = bytes.len() + data.len();
            ensure!(
                data.len() <= 8192
                    && next <= 65536
                    && message["next_offset"].as_u64() == Some(next as u64),
                "native output exceeded the protocol bounds"
            );
            bytes.extend(data);
            if message["eof"] == true {
                return Ok(json!({
                    "base64": base64::engine::general_purpose::STANDARD.encode(bytes),
                    "dropped_bytes": message["dropped_bytes"].as_u64().context("missing output loss count")?,
                }));
            }
            ensure!(
                next > message["offset"].as_u64().unwrap() as usize,
                "output cursor did not advance"
            );
        }
    }
}

fn verify_state(state: &Value, expected: &Handle) -> anyhow::Result<()> {
    ensure!(
        state["handle"]["boot_id"] == expected.boot_id
            && state["handle"]["workload_id"] == expected.workload_id,
        "native workload identity changed"
    );
    Ok(())
}

pub(super) fn open_private(path: &Path) -> anyhow::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o077 == 0,
        "invalid private native session file"
    );
    Ok(file)
}

pub(super) fn load(directory: &Path) -> anyhow::Result<(Identity, Key)> {
    let meta = directory.symlink_metadata()?;
    ensure!(
        meta.is_dir() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o077 == 0,
        "invalid private native session directory"
    );
    let identity: Identity =
        serde_json::from_reader(open_private(&directory.join(MANIFEST))?.take(2048))?;
    let key = read_key(&directory.join(KEY))?;
    Ok((identity, key))
}

pub(super) fn stop(directory: &Path) -> anyhow::Result<()> {
    let (identity, key) = load(directory)?;
    stop_with_identity(directory, &identity, &key)
}

pub(super) fn stop_with_identity(
    directory: &Path,
    identity: &Identity,
    key: &Key,
) -> anyhow::Result<()> {
    stop_peer(Connection::open(directory, identity, key)?)
}

pub(super) fn stop_peer(mut peer: Connection) -> anyhow::Result<()> {
    let ack = peer.exchange(
        Kind::Shutdown,
        Kind::ShutdownAck,
        &json!({"budget_ms":5000}),
        Duration::from_secs(6),
    )?;
    ensure!(
        ack["boot_id"] == peer.boot && ack["state"] == "stopped",
        "guest did not acknowledge drain"
    );
    Ok(())
}

pub(super) fn invoke(target: Target, op: Operation) -> anyhow::Result<()> {
    let (identity, key) = load(&target.session)?;
    let mut peer = Connection::open(&target.session, &identity, &key)?;
    let budget = Duration::from_millis(target.timeout_ms);
    match op {
        Operation::Status => {
            let mut status = peer.inspect()?;
            if let Some(handle) = status["workload"]["handle"].as_object() {
                let handle: Handle = serde_json::from_value(Value::Object(handle.clone()))?;
                status["workload"]["token"] = json!(handle.token());
            }
            emit("status", status)
        }
        Operation::Cancel(token) => {
            let handle = Handle::parse(&token)?;
            let state = peer.state(Kind::Cancel, &handle)?;
            let terminal = peer.wait(&handle, state, false, Instant::now() + budget)?;
            emit("cancel", terminal.clone())?;
            ensure!(terminal["cleanup"] == "complete", "guest cleanup failed");
            Ok(())
        }
        Operation::Memory(pressure) => {
            let observation = peer.exchange(
                Kind::Memory,
                Kind::Memory,
                &json!({
                    "boot_id": peer.boot, "budget_ms":target.timeout_ms,
                    "pressure":pressure.map(|value| matches!(value, Pressure::On)),
                }),
                budget,
            )?;
            emit("memory", observation)
        }
        Operation::Run | Operation::Prepare | Operation::Claim(_) => {
            ensure!(
                !peer.oci,
                "OCI launch requires an explicit process spec over the authenticated API"
            );
            let lock = open_private(&target.session.join(LOCK))?;
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::WouldBlock {
                    bail!("native admission busy; no request was sent");
                }
                return Err(error.into());
            }
            execute(&mut peer, &identity, &target, &key, op, budget)
        }
    }
}

fn emit(mode: &str, value: Value) -> anyhow::Result<()> {
    let mut out = std::io::stdout().lock();
    serde_json::to_writer(
        &mut out,
        &json!({"experimental":true, "owner":"native", "mode":mode, "result":value}),
    )?;
    writeln!(&mut out)?;
    Ok(())
}

fn execute(
    peer: &mut Connection,
    identity: &Identity,
    target: &Target,
    key: &Key,
    op: Operation,
    budget: Duration,
) -> anyhow::Result<()> {
    let spec = LaunchSpec {
        docker_resource_defaults: false,
        memory_swap_disabled: false,
        open_stdin: false,
        redis_bootstrap: false,
        buildkit_worker: false,
        image_digest: identity.image_digest.clone(),
        argv: vec!["/bin/probe".into()],
        cwd: "/work".into(),
        env: vec![],
        uid: WORKLOAD_UID,
        gid: WORKLOAD_GID,
        account: None,
        network: "none".into(),
        network_alias: None,
        secondary_network_alias: None,
        network_alias_project: None,
        volume: None,
        bind: None,
        build_snapshot: None,
        limits: NATIVE_LIMITS,
    };
    let started = Instant::now();
    let deadline = started + budget;
    let remaining = || -> anyhow::Result<(u64, Duration)> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let millis = remaining.as_millis() as u64;
        ensure!(millis != 0, "operation deadline elapsed before submission");
        Ok((millis, remaining))
    };
    let (mode, state) = match op {
        Operation::Claim(token) => {
            let handle = Handle::parse(&token)?;
            ensure!(
                handle.boot_id == peer.boot,
                "workload token belongs to another boot"
            );
            let (budget_ms, time) = remaining()?;
            let reply = peer.exchange(
                Kind::Claim,
                Kind::State,
                &json!({"handle":handle, "budget_ms":budget_ms, "spec":spec}),
                time,
            );
            ("prepared", admission(reply)?)
        }
        Operation::Run | Operation::Prepare => {
            let status = peer.inspect()?;
            ensure!(
                status["image_digest"] == identity.image_digest,
                "native guest image digest mismatch"
            );
            let sequence = status["last_sequence"]
                .as_u64()
                .and_then(|seq| seq.checked_add(1))
                .context("invalid native admission sequence")?;
            let prepared = matches!(op, Operation::Prepare);
            let (budget_ms, time) = remaining()?;
            let request = LaunchRequest {
                boot_id: peer.boot.clone(),
                sequence,
                operation_id: Some(hex(&random::<16>()?)),
                budget_ms,
                spec,
            };
            let reply = peer.exchange(
                if prepared {
                    Kind::Prepare
                } else {
                    Kind::Launch
                },
                Kind::State,
                &request,
                time,
            );
            (
                if prepared { "prepare" } else { "fresh" },
                admission(reply)?,
            )
        }
        _ => unreachable!("only workload operations allocate the admission lock"),
    };
    let handle: Handle = serde_json::from_value(state["handle"].clone())
        .context("missing admitted workload token")?;
    ensure!(
        handle.boot_id == peer.boot,
        "workload response has a different generation"
    );
    let wait = peer.wait(&handle, state, mode == "prepare", deadline);
    let state = match wait {
        Ok(state) => state,
        Err(error) => {
            // A request may have executed. Only inspect or cancel this exact handle.
            drop_recover(target, identity, key, &handle, budget)?;
            return Err(error.context(format!(
                "operation failed; verified cleanup of {}",
                handle.token()
            )));
        }
    };
    let mut result =
        json!({"token":handle.token(), "elapsed_ns":started.elapsed().as_nanos(), "state":state});
    if mode == "prepare" {
        emit(mode, result)?;
        ensure!(
            state["phase"] == "prepared_ready",
            "preparation produced no ready slot"
        );
    } else {
        if state["cleanup"] == "complete" {
            result["stdout"] = peer.collect(&handle, "stdout")?;
            result["stderr"] = peer.collect(&handle, "stderr")?;
        }
        emit(mode, result)?;
        ensure!(
            state["cleanup"] == "complete"
                && state["exec"] == "confirmed"
                && state["helper_failed"] == false
                && state["exit"] == json!({"code":0}),
            "workload did not complete successfully"
        );
    }
    Ok(())
}

fn admission(reply: Result<Value, WireError>) -> anyhow::Result<Value> {
    match reply {
        Ok(state) => Ok(state),
        Err(WireError::PeerError(code)) if code != "claim_indeterminate" => {
            Err(WireError::PeerError(code).into())
        }
        Err(error) => Err(error).context(
            "execution may have begun; inspect session status before taking further action",
        ),
    }
}

fn drop_recover(
    target: &Target,
    identity: &Identity,
    key: &Key,
    handle: &Handle,
    budget: Duration,
) -> anyhow::Result<()> {
    let recover = || -> anyhow::Result<()> {
        let mut recovery = Connection::open(&target.session, identity, key)?;
        ensure!(recovery.boot == handle.boot_id, "guest generation changed");
        let state = recovery.state(Kind::Cancel, handle)?;
        let terminal = recovery.wait(
            handle,
            state,
            false,
            Instant::now() + budget.max(Duration::from_secs(3)),
        )?;
        ensure!(
            terminal["cleanup"] == "complete",
            "cleanup did not complete"
        );
        Ok(())
    };
    recover().with_context(|| {
        format!(
            "execution may have begun; cleanup unverified for {}",
            handle.token()
        )
    })
}

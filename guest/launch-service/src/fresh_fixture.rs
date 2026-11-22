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
use crate::socket::Stream;
use crate::spec::{LaunchRequest, ValidatedLaunch};
use crate::wire::{Frame, Kind, WireError, write_error};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Image {
    executable_sha256: String,
    architecture: String,
    os: String,
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
    ChildCreated,
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
            Self::ChildCreated => "child_created",
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
    cancelled: bool,
    control: Option<UnixStream>,
    stdout: Capture,
    stderr: Capture,
}

impl Record {
    fn change(&mut self, phase: Phase) {
        self.phase = phase;
        self.revision += 1;
    }

    fn state(&self) -> Value {
        json!({
            "handle": self.handle, "revision": self.revision, "phase": self.phase.name(),
            "exec": self.exec, "exit": self.exit,
            "cleanup": match self.phase {
                Phase::Removed => "complete",
                Phase::CleanupFailed => "failed",
                _ => "pending",
            }
        })
    }

    fn cancel(&mut self) {
        if !self.cancelled
            && matches!(
                self.phase,
                Phase::Accepted | Phase::ChildCreated | Phase::Running
            )
        {
            self.cancelled = true;
            if let Some(control) = &mut self.control {
                let _ = control.write_all(&[1]);
            }
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
}

pub(crate) struct FreshFixture {
    image_digest: String,
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

impl FreshFixture {
    pub(crate) fn open(allow_crash: bool) -> Result<Arc<Self>, Box<dyn std::error::Error>> {
        if std::process::id() == 1 || unsafe { libc::getppid() } != 1 {
            return Err("fresh fixture requires a supervisor child of guest init".into());
        }
        let manifest = bounded_file("/etc/conjet/fresh-fixture-image.json", 4_096)?;
        let image: Image = serde_json::from_slice(&manifest)?;
        let executable = bounded_file("/init", 4 * 1024 * 1024)?;
        if image.os != "linux"
            || image.architecture != "arm64"
            || image.executable_sha256 != hex(&Sha256::digest(&executable))
        {
            return Err("fresh fixture image identity differs from its verified input".into());
        }
        let image_digest = format!("sha256:{}", hex(&Sha256::digest(&manifest)));
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
        Ok(Arc::new(Self {
            image_digest,
            allow_crash,
            intent,
            ledger: Mutex::new(Ledger::default()),
            changed: Condvar::new(),
        }))
    }

    fn update(&self, f: impl FnOnce(&mut Record)) {
        let mut ledger = self.ledger.lock().expect("fresh ledger");
        if let Some(record) = &mut ledger.record {
            f(record);
            self.changed.notify_all();
        }
    }

    fn admit(self: &Arc<Self>, ready: ValidatedLaunch, boot: &str, deadline: Instant) -> Reply {
        if ready.request().boot_id != boot {
            return Err(("stale_generation", "unexpected boot ID"));
        }
        let spec = &ready.request().spec;
        let argv = spec.argv.iter().map(String::as_str).collect::<Vec<_>>();
        let mode = match argv.as_slice() {
            ["/bin/probe", "--verify-workload-fixture"] => "once",
            ["/bin/probe", "--verify-workload-fixture", "--hold"] => "hold",
            ["/bin/probe", "--verify-workload-fixture", "--fail"] => "fail",
            [
                "/bin/probe",
                "--verify-workload-fixture",
                "--crash-supervisor",
            ] if self.allow_crash => "crash-supervisor",
            _ => {
                return Err((
                    "unsupported_option",
                    "request does not match the pinned ARM64 fixture",
                ));
            }
        };
        if spec.image_digest != self.image_digest || spec.cwd != "/work" || !spec.env.is_empty() {
            return Err((
                "unsupported_option",
                "request does not match the pinned ARM64 fixture",
            ));
        }
        let request = ready.request();
        let body: [u8; 32] =
            Sha256::digest(serde_json::to_vec(request).expect("typed request")).into();
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
                    "fresh fixture already owns a workload or unresolved cleanup",
                ));
            }
        }
        if ledger.closing {
            return Err(("busy", "fresh fixture is draining"));
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
        if thread::Builder::new()
            .name("fresh-workload".into())
            .spawn(move || owner.run_workload(id, limits, mode))
            .is_err()
        {
            let record = ledger.record.as_mut().expect("reserved record");
            record.exec = "failed";
            record.change(Phase::Removed);
            return Ok((Kind::State, record.state()));
        }
        Ok((Kind::State, reply))
    }

    fn run_workload(&self, id: [u8; 16], limits: crate::spec::ResourceLimits, mode: &str) {
        {
            let mut ledger = self.ledger.lock().expect("fresh ledger");
            let record = ledger.record.as_mut().expect("admitted workload");
            if record.cancelled {
                record.exec = "failed";
                record.change(Phase::Removed);
                self.changed.notify_all();
                return;
            }
        }
        let result = self.intent.record(id).and_then(|()| {
            let output = self.run_helper(id, limits, mode)?;
            self.intent.complete(id)?;
            Ok(output)
        });
        if let Err(error) = &result {
            eprintln!("fresh fixture did not confirm cleanup: {error}");
        }
        self.update(|record| {
            record.control = None;
            if let Ok((stdout, stderr)) = result {
                record.stdout = stdout;
                record.stderr = stderr;
                if record.exec == "pending" {
                    record.exec = "failed";
                }
                record.change(Phase::Removed);
            } else {
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
    ) -> io::Result<(Capture, Capture)> {
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
            ])
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
                let _ = record.control.as_mut().unwrap().write_all(&[1]);
            }
        });
        let mut removed = false;
        let mut exit_received = false;
        let result = (|| -> io::Result<()> {
            let mut code = [0];
            while peer.read(&mut code)? == 1 {
                match code[0] {
                    b'C' => self.update(|record| {
                        if !record.cancelled {
                            record.change(Phase::ChildCreated);
                        }
                    }),
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
                    b'R' if exit_received => {
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
        }
        let finished = child.wait()?;
        let stdout = stdout
            .join()
            .map_err(|_| io::Error::other("stdout reader failed"))??;
        let stderr = stderr
            .join()
            .map_err(|_| io::Error::other("stderr reader failed"))??;
        result?;
        if !finished.success() || !removed {
            return Err(io::Error::other("fixture helper did not confirm cleanup"));
        }
        Ok((stdout, stderr))
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
            Kind::Launch => {
                drop(guard);
                let request: LaunchRequest = parse(frame)?;
                let ready = request
                    .validate()
                    .map_err(|err| (err.code(), "invalid native launch spec"))?;
                let expires = deadline(ready.request().budget_ms)?;
                self.admit(ready, boot, expires)
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

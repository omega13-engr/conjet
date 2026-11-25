use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::handshake::{self, BootId, Key, MAX_QUEUED_CONTROL, hex};
use crate::socket::{Shutdown, Stream};
use crate::spec::LaunchRequest;
use crate::wire::{Frame, Kind, RequestId, WireError, write_error};

const FRAME_TIMEOUT: Duration = Duration::from_secs(2);
pub const FIXTURE_WORKLOAD: &str = "00000000000000000000000000000000";
const CAPABILITIES: &[&str] = &["ping", "shutdown", "request_cancel", "fixture_wait"];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Scope {
    Host,
    #[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
    BuildSnapshot,
}

pub struct Server {
    boot_id: BootId,
    key: Key,
    shutdown: Arc<Shutdown>,
    waiting: AtomicUsize,
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    fresh: Option<Arc<crate::fresh_fixture::FreshFixture>>,
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    relays: AtomicUsize,
}

impl Server {
    pub fn new(key: Key) -> Result<Arc<Self>, WireError> {
        Ok(Arc::new(Self {
            boot_id: handshake::random()?,
            key,
            shutdown: Shutdown::new()?,
            waiting: AtomicUsize::new(0),
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            fresh: None,
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            relays: AtomicUsize::new(0),
        }))
    }

    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    pub(crate) fn with_fresh(
        key: Key,
        fresh: Arc<crate::fresh_fixture::FreshFixture>,
    ) -> Result<Arc<Self>, WireError> {
        let mut server = Self::new(key)?;
        Arc::get_mut(&mut server).expect("unshared server").fresh = Some(fresh);
        Ok(server)
    }

    fn capabilities(&self) -> &'static [&'static str] {
        #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
        if let Some(fresh) = &self.fresh {
            if fresh.has_core_admission() {
                return &[
                    "ping",
                    "shutdown",
                    "native_oci_arm64_v1",
                    crate::spec::MAPPED_IDS_CAPABILITY,
                    "memory",
                    crate::core_admission::PENDING_WATCH_CAPABILITY,
                    crate::wire::COPY_DOWNLOAD_CAPABILITY,
                    crate::wire::COPY_UPLOAD_CAPABILITY,
                ];
            }
            if fresh.is_oci() {
                return &[
                    "ping",
                    "shutdown",
                    "native_oci_arm64_v1",
                    crate::spec::MAPPED_IDS_CAPABILITY,
                    "memory",
                    crate::wire::COPY_DOWNLOAD_CAPABILITY,
                    crate::wire::COPY_UPLOAD_CAPABILITY,
                ];
            }
            if fresh.is_native() {
                return &[
                    "ping",
                    "shutdown",
                    "native_static_arm64_v1",
                    "prepare",
                    "memory",
                ];
            }
            if fresh.bridge_available() {
                return &[
                    "ping",
                    "shutdown",
                    "fresh_arm64_fixture",
                    "private_bridge_fixture",
                    "prepared_arm64_fixture",
                    "native_memory_fixture",
                ];
            }
            return &[
                "ping",
                "shutdown",
                "fresh_arm64_fixture",
                "prepared_arm64_fixture",
                "native_memory_fixture",
            ];
        }
        CAPABILITIES
    }

    pub fn shutdown(&self) -> Arc<Shutdown> {
        Arc::clone(&self.shutdown)
    }

    pub fn serve(&self, stream: Stream) -> Result<(), WireError> {
        self.serve_scoped(stream, Scope::Host)
    }

    #[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
    pub(crate) fn serve_build_snapshot(&self, stream: Stream) -> Result<(), WireError> {
        self.serve_scoped(stream, Scope::BuildSnapshot)
    }

    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    pub(crate) fn serve_build_worker(
        &self,
        mut stream: Stream,
        key: &Key,
        peer: &std::os::fd::OwnedFd,
    ) -> Result<(), WireError> {
        let fresh = self.fresh.as_ref().ok_or(WireError::Unauthorized)?;
        let cgroup = crate::build_snapshot::worker_control::peer_cgroup(peer)?;
        if !fresh.owns_build_worker(&cgroup) {
            return Err(WireError::Unauthorized);
        }
        stream.deadline(Some(Instant::now() + FRAME_TIMEOUT));
        handshake::guest(&mut stream, key, self.boot_id, &["native_build_runtime_v1"])?;
        let frame = Frame::read(&mut stream)?;
        if frame.kind != Kind::BuildRuntime
            || crate::build_snapshot::worker_control::peer_cgroup(peer)? != cgroup
            || !fresh.owns_build_worker(&cgroup)
        {
            return Err(WireError::Unauthorized);
        }
        fresh.dispatch_build(frame, &mut stream, &hex(&self.boot_id), Some(&cgroup))
    }

    fn serve_scoped(&self, mut stream: Stream, scope: Scope) -> Result<(), WireError> {
        stream.deadline(Some(Instant::now() + FRAME_TIMEOUT));
        let capabilities = if scope == Scope::Host {
            self.capabilities()
        } else {
            &[
                "ping",
                "native_build_snapshot_v1",
                "native_build_runtime_v1",
            ]
        };
        handshake::guest(&mut stream, &self.key, self.boot_id, capabilities)?;
        let boot_id = hex(&self.boot_id);
        #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
        let lease = self
            .fresh
            .as_ref()
            .map(|fresh| {
                handshake::random().map(|id| crate::fresh_fixture::ConnectionLease { fresh, id })
            })
            .transpose()?;
        let mut pending: Option<Pending<'_>> = None;
        loop {
            let wait_deadline = if scope == Scope::Host {
                pending.as_ref().map(|request| request.due)
            } else {
                Some(Instant::now() + FRAME_TIMEOUT)
            };
            match stream.readable(wait_deadline) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::TimedOut && pending.is_some() => {
                    let request = pending.take().expect("pending wait");
                    stream.deadline(Some(Instant::now() + FRAME_TIMEOUT));
                    write_error(
                        &mut stream,
                        request.id,
                        "deadline_exceeded",
                        "fixture wait expired",
                    )?;
                    continue;
                }
                Err(error) if error.kind() == io::ErrorKind::ConnectionAborted => return Ok(()),
                Err(error) => return Err(error.into()),
            }
            stream.deadline(Some(Instant::now() + FRAME_TIMEOUT));
            let frame = match Frame::read(&mut stream) {
                Ok(frame) => frame,
                Err(WireError::Io(error)) if error.kind() == io::ErrorKind::UnexpectedEof => {
                    return Ok(());
                }
                Err(error) => return Err(error),
            };
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            if scope != Scope::Host
                && frame.kind == Kind::BuildRuntime
                && let Some(fresh) = &self.fresh
            {
                fresh.dispatch_build(frame, &mut stream, &boot_id, None)?;
                continue;
            }
            if scope != Scope::Host && !matches!(frame.kind, Kind::Ping | Kind::BuildSnapshot) {
                write_error(
                    &mut stream,
                    frame.id,
                    "unsupported_option",
                    "operation is outside the local build snapshot scope",
                )?;
                continue;
            }
            if pending
                .as_ref()
                .is_some_and(|request| request.due <= Instant::now())
            {
                let request = pending.take().unwrap();
                write_error(
                    &mut stream,
                    request.id,
                    "deadline_exceeded",
                    "fixture wait expired",
                )?;
            }
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            if frame.kind == Kind::Bind && self.fresh.as_ref().is_some_and(|fresh| fresh.is_oci()) {
                let Some(request) = decode::<crate::bind_mount::Request>(&frame, &mut stream)?
                else {
                    continue;
                };
                if request.boot_id != boot_id {
                    write_error(
                        &mut stream,
                        frame.id,
                        "stale_generation",
                        "unexpected native bind boot",
                    )?;
                    continue;
                }
                let Some(_slot) = RelaySlot::reserve(&self.relays) else {
                    write_error(
                        &mut stream,
                        frame.id,
                        "busy",
                        "native relay slots are occupied",
                    )?;
                    continue;
                };
                let mount = match crate::bind_mount::Mount::open(&request) {
                    Ok(mount) => mount,
                    Err(error) => {
                        eprintln!("native bind mount setup failed: {error}");
                        write_error(
                            &mut stream,
                            frame.id,
                            "storage_failed",
                            "native bind mount setup failed",
                        )?;
                        continue;
                    }
                };
                Frame::write(
                    &mut stream,
                    Kind::Bind,
                    frame.id,
                    &serde_json::json!({"lease":request.lease}),
                )?;
                mount.relay(&mut stream, &self.shutdown)?;
                return Ok(());
            }
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            if frame.kind == Kind::BuildRegistry
                && scope == Scope::Host
                && let Some(fresh) = &self.fresh
            {
                let request: serde_json::Value = frame.decode()?;
                if request["boot_id"].as_str() != Some(boot_id.as_str()) {
                    write_error(
                        &mut stream,
                        frame.id,
                        "stale_generation",
                        "unexpected registry boot",
                    )?;
                    continue;
                }
                let Some(_slot) = RelaySlot::reserve(&self.relays) else {
                    write_error(
                        &mut stream,
                        frame.id,
                        "busy",
                        "native relay slots are occupied",
                    )?;
                    continue;
                };
                if let Ok((owner, registry)) = fresh.accept_build_registry() {
                    Frame::write(
                        &mut stream,
                        Kind::BuildRegistry,
                        frame.id,
                        &serde_json::json!({"connected":true}),
                    )?;
                    let _ =
                        crate::relay::pump(&stream, &registry, Duration::from_secs(180), || {
                            self.shutdown.requested() || !fresh.build_registry_current(&owner)
                        });
                    return Ok(());
                }
                write_error(
                    &mut stream,
                    frame.id,
                    "not_found",
                    "no pending BuildKit registry connection",
                )?;
                continue;
            }
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            if let Some(fresh) = &self.fresh
                && scope == Scope::Host
                && fresh.is_oci()
                && frame.kind == Kind::CopyDownload
            {
                return fresh.serve_copy_download(&frame, &boot_id, &mut stream);
            }
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            if let Some(fresh) = &self.fresh
                && scope == Scope::Host
                && fresh.is_oci()
                && frame.kind == Kind::CopyUpload
            {
                return fresh.serve_copy_upload(
                    &frame,
                    &boot_id,
                    &mut stream,
                    lease.as_ref().expect("fixture lease").id,
                );
            }
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            if let Some(fresh) = &self.fresh
                && fresh.is_oci()
                && frame.kind == Kind::ExecStream
            {
                return fresh.serve_exec_stream(&frame, &boot_id, &mut stream);
            }
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            if let Some(fresh) = &self.fresh
                && fresh.is_oci()
                && frame.kind == Kind::Dial
            {
                let Some(_slot) = RelaySlot::reserve(&self.relays) else {
                    write_error(
                        &mut stream,
                        frame.id,
                        "busy",
                        "native TCP slots are occupied",
                    )?;
                    continue;
                };
                match fresh.dial(&frame, &boot_id) {
                    Ok(target) => {
                        Frame::write(
                            &mut stream,
                            Kind::Dial,
                            frame.id,
                            &serde_json::json!({"connected":true}),
                        )?;
                        let _ =
                            crate::relay::pump(&stream, &target, Duration::from_secs(15), || {
                                self.shutdown.requested()
                            });
                        return Ok(());
                    }
                    Err((code, message)) => write_error(&mut stream, frame.id, code, message)?,
                }
                continue;
            }
            #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
            if let Some(fresh) = &self.fresh
                && matches!(
                    frame.kind,
                    Kind::Launch
                        | Kind::Status
                        | Kind::Wait
                        | Kind::Cancel
                        | Kind::Output
                        | Kind::Prepare
                        | Kind::Claim
                        | Kind::Memory
                        | Kind::Inspect
                        | Kind::Image
                        | Kind::Exec
                        | Kind::ExecOutput
                        | Kind::Copy
                        | Kind::Input
                        | Kind::Account
                        | Kind::Network
                        | Kind::Volume
                        | Kind::BuildSnapshot
                )
            {
                fresh.dispatch(
                    frame,
                    &mut stream,
                    &boot_id,
                    lease.as_ref().expect("fixture lease").id,
                )?;
                continue;
            }
            match frame.kind {
                Kind::Ping | Kind::Shutdown => {
                    let Some(budget) = decode::<Budget>(&frame, &mut stream)? else {
                        continue;
                    };
                    let Some(deadline) = budget_deadline(budget.budget_ms) else {
                        write_error(&mut stream, frame.id, "malformed", "invalid budget")?;
                        continue;
                    };
                    stream.deadline(Some(deadline));
                    if frame.kind == Kind::Ping {
                        Frame::write(
                            &mut stream,
                            Kind::Pong,
                            frame.id,
                            &Pong { boot_id: &boot_id },
                        )?;
                    } else {
                        #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
                        if let Some(fresh) = &self.fresh
                            && !fresh.drain(deadline)
                        {
                            stream.deadline(Some(Instant::now() + FRAME_TIMEOUT));
                            write_error(
                                &mut stream,
                                frame.id,
                                "cleanup_failed",
                                "fresh fixture could not drain",
                            )?;
                            continue;
                        }
                        // Stop after the authenticated acknowledgement and any owned workload drain.
                        stream.deadline(Some(Instant::now() + FRAME_TIMEOUT));
                        Frame::write(
                            &mut stream,
                            Kind::ShutdownAck,
                            frame.id,
                            &ShutdownAck {
                                boot_id: &boot_id,
                                state: "stopped",
                            },
                        )?;
                        self.shutdown.request()?;
                        return Ok(());
                    }
                }
                Kind::Wait => {
                    let Some(wait) = decode::<Wait>(&frame, &mut stream)? else {
                        continue;
                    };
                    let Some(due) = budget_deadline(wait.budget_ms) else {
                        write_error(&mut stream, frame.id, "malformed", "invalid budget")?;
                        continue;
                    };
                    if wait.handle.boot_id != boot_id {
                        write_error(
                            &mut stream,
                            frame.id,
                            "stale_generation",
                            "unexpected boot ID",
                        )?;
                    } else if wait.handle.workload_id != FIXTURE_WORKLOAD
                        || wait.after_revision != 0
                    {
                        write_error(
                            &mut stream,
                            frame.id,
                            "not_found",
                            "fixture handle required",
                        )?;
                    } else if pending.is_some() {
                        write_error(&mut stream, frame.id, "busy", "connection already waiting")?;
                    } else if let Some(slot) = Pending::reserve(&self.waiting, frame.id, due) {
                        pending = Some(slot);
                    } else {
                        write_error(&mut stream, frame.id, "busy", "wait queue full")?;
                    }
                }
                Kind::Cancel => {
                    let Some(cancel) = decode::<Cancel>(&frame, &mut stream)? else {
                        continue;
                    };
                    let Some(deadline) = budget_deadline(cancel.budget_ms) else {
                        write_error(&mut stream, frame.id, "malformed", "invalid budget")?;
                        continue;
                    };
                    let Some(id) = handshake::unhex::<16>(&cancel.request_id).ok() else {
                        write_error(&mut stream, frame.id, "malformed", "invalid request ID")?;
                        continue;
                    };
                    stream.deadline(Some(deadline));
                    if pending.as_ref().is_some_and(|request| request.id == id) {
                        pending.take();
                        write_error(&mut stream, id, "cancelled", "fixture wait cancelled")?;
                        Frame::write(
                            &mut stream,
                            Kind::Cancel,
                            frame.id,
                            &CancelAck {
                                request_id: &cancel.request_id,
                                cancelled: true,
                            },
                        )?;
                    } else {
                        write_error(&mut stream, frame.id, "not_found", "pending wait not found")?;
                    }
                }
                Kind::Launch => {
                    let Some(request) = decode::<LaunchRequest>(&frame, &mut stream)? else {
                        continue;
                    };
                    if let Err(error) = request.validate() {
                        write_error(&mut stream, frame.id, error.code(), &error.to_string())?;
                    } else {
                        write_error(
                            &mut stream,
                            frame.id,
                            "unsupported_option",
                            "fresh execution unavailable",
                        )?;
                    }
                }
                _ => write_error(
                    &mut stream,
                    frame.id,
                    "unsupported_option",
                    "fixture cannot launch workloads",
                )?,
            }
        }
    }
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
struct RelaySlot<'a>(&'a AtomicUsize);

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
impl<'a> RelaySlot<'a> {
    fn reserve(slots: &'a AtomicUsize) -> Option<Self> {
        slots
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < 2).then_some(count + 1)
            })
            .ok()?;
        Some(Self(slots))
    }
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
impl Drop for RelaySlot<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Release);
    }
}

fn budget_deadline(budget_ms: u64) -> Option<Instant> {
    (1..=30_000)
        .contains(&budget_ms)
        .then(|| Instant::now() + Duration::from_millis(budget_ms))
}

fn decode<T: serde::de::DeserializeOwned>(
    frame: &Frame,
    stream: &mut Stream,
) -> Result<Option<T>, WireError> {
    match frame.decode() {
        Ok(request) => Ok(Some(request)),
        Err(_) => {
            write_error(stream, frame.id, "malformed", "invalid request payload")?;
            Ok(None)
        }
    }
}

struct Pending<'a> {
    counter: &'a AtomicUsize,
    id: RequestId,
    due: Instant,
}

impl<'a> Pending<'a> {
    fn reserve(counter: &'a AtomicUsize, id: RequestId, due: Instant) -> Option<Self> {
        counter
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < MAX_QUEUED_CONTROL).then_some(n + 1)
            })
            .ok()?;
        Some(Self { counter, id, due })
    }
}

impl Drop for Pending<'_> {
    fn drop(&mut self) {
        self.counter.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Budget {
    pub budget_ms: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Handle {
    boot_id: String,
    workload_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Wait {
    handle: Handle,
    after_revision: u64,
    budget_ms: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cancel {
    request_id: String,
    budget_ms: u64,
}

#[derive(Serialize)]
struct CancelAck<'a> {
    request_id: &'a str,
    cancelled: bool,
}

#[derive(Serialize)]
struct Pong<'a> {
    boot_id: &'a str,
}

#[derive(Serialize)]
struct ShutdownAck<'a> {
    boot_id: &'a str,
    state: &'static str,
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;
    use std::thread;

    use serde_json::json;

    use super::*;
    use crate::wire::ErrorReply;

    fn endpoint(server: &Arc<Server>) -> (Stream, thread::JoinHandle<Result<(), WireError>>) {
        let (host, guest) = UnixStream::pair().unwrap();
        let mut client = Stream::unix(host, None).unwrap();
        client.deadline(Some(Instant::now() + Duration::from_secs(2)));
        let socket = Stream::unix(guest, Some(server.shutdown())).unwrap();
        let owner = Arc::clone(server);
        (client, thread::spawn(move || owner.serve(socket)))
    }

    fn send(stream: &mut Stream, kind: Kind, id: u8, request: serde_json::Value) {
        Frame::write(stream, kind, [id; 16], &request).unwrap();
    }

    fn expect_error(stream: &mut Stream, id: u8, expected: &str) {
        let frame = Frame::read(stream).unwrap();
        assert_eq!(frame.kind, Kind::Error);
        assert_eq!(frame.id, [id; 16]);
        assert_eq!(frame.decode::<ErrorReply>().unwrap().code, expected);
    }

    fn wait_request(boot: &str, budget_ms: u32) -> serde_json::Value {
        json!({"handle": {"boot_id": boot, "workload_id": FIXTURE_WORKLOAD},
               "after_revision": 0, "budget_ms": budget_ms})
    }

    #[test]
    fn ping_requires_handshake_and_valid_budget() {
        let owner = Server::new([19; 32]).unwrap();
        let (mut host, worker) = endpoint(&owner);
        send(&mut host, Kind::Ping, 1, json!({"budget_ms": 150}));
        expect_error(&mut host, 1, "unauthorized");
        assert!(matches!(
            worker.join().unwrap(),
            Err(WireError::Unauthorized)
        ));
        let (mut host, worker) = endpoint(&owner);
        handshake::host(&mut host, &[19; 32]).unwrap();
        send(&mut host, Kind::Ping, 2, json!({"budget_ms": 0}));
        expect_error(&mut host, 2, "malformed");
        send(&mut host, Kind::Ping, 3, json!({"budget_ms": 500}));
        let response = Frame::read(&mut host).unwrap();
        assert_eq!(response.kind, Kind::Pong);
        assert_eq!(response.id, [3; 16]);
        drop(host);
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn local_snapshot_connection_cannot_launch_or_stop_host_workloads() {
        let key = [43; 32];
        let server = Server::new(key).unwrap();
        let (client, guest) = UnixStream::pair().unwrap();
        let owner = Arc::clone(&server);
        let worker = thread::spawn(move || {
            let socket = Stream::unix(guest, Some(owner.shutdown())).unwrap();
            owner.serve_build_snapshot(socket)
        });
        let mut stream = Stream::unix(client, None).unwrap();
        stream.deadline(Some(Instant::now() + Duration::from_secs(2)));
        let hello = handshake::host(&mut stream, &key).unwrap();
        let (mut host, host_worker) = endpoint(&server);
        let control = handshake::host(&mut host, &key).unwrap();
        assert_eq!(hello.boot_id, control.boot_id);
        assert!(
            hello
                .capabilities
                .iter()
                .any(|cap| cap == "native_build_runtime_v1")
        );
        assert!(
            !control
                .capabilities
                .iter()
                .any(|cap| cap == "native_build_runtime_v1")
        );
        send(
            &mut host,
            Kind::BuildRuntime,
            6,
            json!({"boot_id":control.boot_id,
             "id":"fixture1","operation":{"action":"run"}}),
        );
        expect_error(&mut host, 6, "unsupported_option");
        for (id, operation) in [(1, Kind::Launch), (2, Kind::Cancel), (3, Kind::Shutdown)] {
            send(&mut stream, operation, id, json!({"budget_ms": 500}));
            expect_error(&mut stream, id, "unsupported_option");
        }
        send(&mut stream, Kind::Ping, 4, json!({"budget_ms":500}));
        assert_eq!(Frame::read(&mut stream).unwrap().kind, Kind::Pong);
        assert!(!server.shutdown().requested());
        send(&mut host, Kind::Shutdown, 5, json!({"budget_ms":500}));
        assert_eq!(Frame::read(&mut host).unwrap().kind, Kind::ShutdownAck);
        worker.join().unwrap().unwrap();
        host_worker.join().unwrap().unwrap();
    }

    #[test]
    fn pending_wait_times_out_and_can_be_cancelled_when_connection_is_saturated() {
        let owner = Server::new([21; 32]).unwrap();
        let (mut host, worker) = endpoint(&owner);
        let caps = handshake::host(&mut host, &[21; 32]).unwrap();
        send(&mut host, Kind::Wait, 8, wait_request(&caps.boot_id, 20));
        expect_error(&mut host, 8, "deadline_exceeded");
        send(&mut host, Kind::Wait, 9, wait_request(&caps.boot_id, 1_000));
        send(
            &mut host,
            Kind::Wait,
            10,
            wait_request(&caps.boot_id, 1_000),
        );
        expect_error(&mut host, 10, "busy");
        send(
            &mut host,
            Kind::Cancel,
            11,
            json!({"request_id": hex(&[9; 16]), "budget_ms": 500}),
        );
        expect_error(&mut host, 9, "cancelled");
        let response = Frame::read(&mut host).unwrap();
        assert_eq!(response.kind, Kind::Cancel);
        assert_eq!(response.id, [11; 16]);
        assert_eq!(owner.waiting.load(Ordering::Acquire), 0);
        drop(host);
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn shutdown_wakes_an_idle_authenticated_connection() {
        let owner = Server::new([33; 32]).unwrap();
        let (mut idle, idle_worker) = endpoint(&owner);
        handshake::host(&mut idle, &[33; 32]).unwrap();
        let (mut host, worker) = endpoint(&owner);
        handshake::host(&mut host, &[33; 32]).unwrap();
        send(&mut host, Kind::Shutdown, 12, json!({"budget_ms": 500}));
        let reply = Frame::read(&mut host).unwrap();
        assert_eq!(reply.kind, Kind::ShutdownAck);
        worker.join().unwrap().unwrap();
        idle_worker.join().unwrap().unwrap();
        assert!(owner.shutdown().requested());
    }

    #[test]
    fn disconnect_returns_the_pending_wait_reservation() {
        let owner = Server::new([37; 32]).unwrap();
        let (mut host, worker) = endpoint(&owner);
        let caps = handshake::host(&mut host, &[37; 32]).unwrap();
        send(
            &mut host,
            Kind::Wait,
            13,
            wait_request(&caps.boot_id, 1_000),
        );
        send(&mut host, Kind::Ping, 14, json!({"budget_ms": 500}));
        assert_eq!(Frame::read(&mut host).unwrap().kind, Kind::Pong);
        assert_eq!(owner.waiting.load(Ordering::Acquire), 1);
        drop(host);
        worker.join().unwrap().unwrap();
        assert_eq!(owner.waiting.load(Ordering::Acquire), 0);
    }
}

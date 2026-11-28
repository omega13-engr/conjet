//! Owned execution and bounded duplex I/O for verified BuildKit workers.

use std::error::Error;
use std::io::{self, Read, Write};
use std::os::linux::net::SocketAddrExt;
use std::os::unix::net::{SocketAddr, UnixStream};
use std::path::Path;
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};

use crate::build_snapshot::worker_control;
use crate::build_snapshot::{CONTROL_ADDRESS, Snapshotter, valid_id};
use crate::handshake::{host, random};
use crate::socket::{Stream, read_key};
use crate::wire::{ErrorReply, Frame, Kind, WireError};

const EXECUTOR: &str = "/run/conjet/buildkit/worker/runc-native/executor";
const KEY: &str = "/etc/conjet/launch.key";
const POLL: Duration = Duration::from_millis(10);

#[derive(Debug, thiserror::Error)]
enum RuntimeError {
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Wire(#[from] WireError),
    #[error("{code}: {message}")]
    Peer { code: String, message: String },
}

pub fn run() -> Result<i32, Box<dyn Error>> {
    let worker = Path::new(worker_control::KEY).try_exists()?;
    let args: Vec<_> = std::env::args().skip(1).collect();
    let words: Vec<_> = args.iter().map(String::as_str).collect();
    let ["--log", log, "--log-format", "json", command @ ..] = words.as_slice() else {
        return Err("unsupported BuildKit runtime global options".into());
    };
    let matches_log = |executor| *log == format!("{executor}/runc-log.json");
    let executor = if worker {
        [Snapshotter::Native, Snapshotter::Overlay]
            .into_iter()
            .map(Snapshotter::executor)
            .find(|&executor| matches_log(executor))
    } else {
        matches_log(EXECUTOR).then_some(EXECUTOR)
    }
    .ok_or("unexpected BuildKit log path")?;
    match command {
        ["run", "--bundle", bundle, "--keep", id]
            if valid_id(id) && *bundle == format!("{executor}/{id}") =>
        {
            run_workload(worker, id)
        }
        ["kill", id, "9"] if valid_id(id) => {
            exchange(worker, id, json!({"action":"kill"}))?;
            Ok(0)
        }
        ["delete", id] if valid_id(id) => {
            let expires = Instant::now() + Duration::from_secs(3);
            loop {
                match exchange(worker, id, json!({"action":"delete"})) {
                    Ok(_) => return Ok(0),
                    Err(RuntimeError::Peer { code, .. })
                        if code == "busy" && Instant::now() < expires =>
                    {
                        std::thread::sleep(POLL);
                    }
                    Err(error) => return Err(error.into()),
                }
            }
        }
        _ => Err("unsupported BuildKit runtime command".into()),
    }
}

fn exchange(worker: bool, id: &str, operation: Value) -> Result<Value, RuntimeError> {
    let (path, socket) = if worker {
        (
            worker_control::KEY,
            UnixStream::connect(worker_control::SOCKET)?,
        )
    } else {
        let address = SocketAddr::from_abstract_name(CONTROL_ADDRESS)?;
        (KEY, UnixStream::connect_addr(&address)?)
    };
    let key = read_key(Path::new(path))?;
    let mut stream = Stream::unix(socket, None)?;
    stream.deadline(Some(Instant::now() + Duration::from_secs(2)));
    let hello = host(&mut stream, &key)?;
    if !hello
        .capabilities
        .iter()
        .any(|value| value == "native_build_runtime_v1")
    {
        return Err(WireError::UnsupportedVersion.into());
    }
    let id_in_wire = random()?;
    Frame::write(
        &mut stream,
        Kind::BuildRuntime,
        id_in_wire,
        &json!({
            "boot_id":hello.boot_id,"id":id,"operation":operation,
        }),
    )?;
    let reply = Frame::read(stream)?;
    if reply.kind == Kind::Error && reply.id == id_in_wire {
        let error: ErrorReply = reply.decode()?;
        return Err(RuntimeError::Peer {
            code: error.code,
            message: error.message,
        });
    }
    Ok(reply.expect(Kind::BuildRuntime, id_in_wire)?)
}

fn forward(
    chunk: &Value,
    cursor: &mut usize,
    output: &mut dyn Write,
) -> Result<bool, Box<dyn Error>> {
    let data = base64::engine::general_purpose::STANDARD
        .decode(chunk["data"].as_str().ok_or("missing build output")?)?;
    if chunk["offset"].as_u64() != Some(*cursor as u64)
        || chunk["next_offset"].as_u64() != Some((*cursor + data.len()) as u64)
        || chunk["dropped_bytes"].as_u64() != Some(0)
    {
        return Err("build output cannot be delivered without loss".into());
    }
    output.write_all(&data)?;
    output.flush()?;
    *cursor += data.len();
    Ok(chunk["eof"].as_bool().ok_or("missing build output EOF")?)
}

fn run_workload(worker: bool, id: &str) -> Result<i32, Box<dyn Error>> {
    let admitted = exchange(worker, id, json!({"action":"run"}))?;
    let handle = &admitted["handle"];
    let mut stdout = 0;
    let mut stderr = 0;
    let mut input = Vec::new();
    let mut eof = false;
    let mut input_closed = false;
    let mut cleanup = CancelOnDrop {
        worker,
        id,
        complete: false,
    };
    loop {
        if admitted["stdin"] == true && !input_closed {
            if input.is_empty() && !eof {
                let mut fd = libc::pollfd {
                    fd: 0,
                    events: libc::POLLIN,
                    revents: 0,
                };
                let ready = unsafe { libc::poll(&mut fd, 1, 0) };
                if ready < 0 {
                    return Err(io::Error::last_os_error().into());
                }
                if ready > 0 {
                    let mut bytes = [0u8; 4096];
                    let count = unsafe { libc::read(0, bytes.as_mut_ptr().cast(), bytes.len()) };
                    if count < 0 {
                        return Err(io::Error::last_os_error().into());
                    }
                    eof = count == 0;
                    input.extend_from_slice(&bytes[..count as usize]);
                }
            }
            if !input.is_empty() || eof {
                let data = (!input.is_empty())
                    .then(|| base64::engine::general_purpose::STANDARD.encode(&input));
                match exchange(worker, id, json!({"action":"input", "data":data})) {
                    Ok(reply) if reply["accepted"] == true => {
                        input.clear();
                        input_closed = eof;
                    }
                    Ok(_) => {}
                    Err(RuntimeError::Peer { code, .. }) if code == "input_closed" => {
                        // A process may finish between output polls. Drain its
                        // final output and report its exit, not a pipe race.
                        input.clear();
                        input_closed = true;
                    }
                    Err(error) => return Err(error.into()),
                }
            }
        }
        let state = exchange(
            worker,
            id,
            json!({"action":"status","stdout":stdout,"stderr":stderr}),
        )?;
        if state["handle"] != *handle || state["cleanup"] == "failed" {
            return Err("build workload generation or cleanup could not be verified".into());
        }
        let out = forward(
            &state["build_output"]["stdout"],
            &mut stdout,
            &mut io::stdout().lock(),
        )?;
        let err = forward(
            &state["build_output"]["stderr"],
            &mut stderr,
            &mut io::stderr().lock(),
        )?;
        if out && err && state["cleanup"] == "complete" {
            if state["helper_failed"] != false || state["exec"] != "confirmed" {
                if state["cancelled"] == true && state["helper_failed"] == false {
                    cleanup.complete = true;
                    return Ok(137);
                }
                return Err("build workload exec could not be verified".into());
            }
            let code = state["exit"]["code"]
                .as_i64()
                .or_else(|| state["exit"]["signal"].as_i64().map(|signal| 128 + signal))
                .filter(|&code| (0..=255).contains(&code))
                .ok_or("missing build exit status")?;
            cleanup.complete = true;
            return Ok(code as i32);
        }
        std::thread::sleep(POLL);
    }
}

struct CancelOnDrop<'a> {
    worker: bool,
    id: &'a str,
    complete: bool,
}
impl Drop for CancelOnDrop<'_> {
    fn drop(&mut self) {
        if !self.complete {
            let _ = exchange(self.worker, self.id, json!({"action":"kill"}));
        }
    }
}

/// Executed by the packaged E2E fixture inside a real BuildKit RUN container.
pub fn verify_policy() -> Result<(), Box<dyn Error>> {
    let stage = |name: &str, error: io::Error| io::Error::other(format!("{name}: {error}"));
    let status = std::fs::read_to_string("/proc/self/status")
        .map_err(|e| stage("read process status", e))?;
    if !status
        .lines()
        .any(|line| line.split_whitespace().collect::<Vec<_>>() == ["CapEff:", "00000000a80425fb"])
    {
        return Err("build RUN capabilities differ from the admitted OCI policy".into());
    }
    let map =
        std::fs::read_to_string("/proc/self/uid_map").map_err(|e| stage("read uid map", e))?;
    if map.split_whitespace().collect::<Vec<_>>() != ["0", "100000", "65536"] {
        return Err("build RUN escaped its mapped user identity".into());
    }
    let fd = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM, 0) };
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
        return Err("build RUN can create host vsock sockets".into());
    }
    if io::Error::last_os_error().raw_os_error() != Some(libc::EPERM) {
        return Err("vsock was not denied by the build policy".into());
    }
    if unsafe { libc::unshare(libc::CLONE_NEWNS) } == 0
        || io::Error::last_os_error().raw_os_error() != Some(libc::EPERM)
    {
        return Err("build RUN can create an unapproved namespace".into());
    }
    let mut groups = [0u32; 128];
    let count = unsafe { libc::getgroups(groups.len() as i32, groups.as_mut_ptr()) };
    if count < 0 {
        return Err(io::Error::last_os_error().into());
    }
    let check = |operation: &str, result| -> io::Result<()> {
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::other(format!(
                "{operation}: {}",
                io::Error::last_os_error()
            )))
        }
    };
    check("setgroups nobody", unsafe {
        libc::setgroups(1, [65534u32].as_ptr())
    })?;
    check("restore groups", unsafe {
        libc::setgroups(count as usize, groups.as_ptr())
    })?;
    check("setegid 65534", unsafe { libc::setegid(65534) })?;
    check("setegid 0", unsafe { libc::setegid(0) })?;
    check("seteuid 42", unsafe { libc::seteuid(42) })?;
    check("seteuid 0", unsafe { libc::seteuid(0) })?;
    for (resource, expected) in [
        (libc::RLIMIT_NOFILE, crate::security::BUILDKIT_OPEN_FILES),
        (libc::RLIMIT_FSIZE, crate::security::BUILDKIT_FILE_SIZE),
    ] {
        let mut limits = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        check("getrlimit", unsafe {
            libc::getrlimit(resource, &mut limits)
        })?;
        if limits.rlim_cur != expected || limits.rlim_max != expected {
            return Err("container resource limits differ from the admitted policy".into());
        }
    }
    let mut random = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .map_err(|e| stage("open urandom", e))?
        .read_exact(&mut random)
        .map_err(|e| stage("read urandom", e))?;
    let metadata = std::fs::metadata("/dev/urandom").map_err(|e| stage("stat urandom", e))?;
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    if !metadata.file_type().is_char_device()
        || libc::major(metadata.rdev()) != 1
        || libc::minor(metadata.rdev()) != 9
    {
        return Err("urandom is not the verified Linux random device".into());
    }
    let path = "/tmp/conjet-build-policy-file";
    let mut file = std::fs::File::create_new(path).map_err(|e| stage("create probe file", e))?;
    let bytes = vec![0x5a; 1024 * 1024];
    for _ in 0..32 {
        file.write_all(&bytes)
            .map_err(|e| stage("write probe file", e))?;
    }
    file.sync_all().map_err(|e| stage("sync probe file", e))?;
    if file
        .metadata()
        .map_err(|e| stage("stat probe file", e))?
        .len()
        != 32 * 1024 * 1024
    {
        return Err("large build file was truncated".into());
    }
    drop(file);
    std::fs::remove_file(path).map_err(|e| stage("remove probe file", e))?;
    println!("conjet-build-policy-ok");
    Ok(())
}

/// Session-scoped E2E server for the packaged multiple-bind/port fixture.
pub fn serve_bind_fixture() -> Result<(), Box<dyn Error>> {
    let mut body = Vec::new();
    for name in ["data", "keys", "skills"] {
        body.extend(std::fs::read(format!("/app/{name}/marker"))?);
    }
    std::fs::write("/app/data/index.html", &body)?;
    let listeners = [
        std::net::TcpListener::bind("0.0.0.0:8787")?,
        std::net::TcpListener::bind("0.0.0.0:8788")?,
    ];
    for listener in &listeners {
        listener.set_nonblocking(true)?;
    }
    let deadline = Instant::now() + Duration::from_secs(90);
    std::thread::scope(|scope| -> io::Result<()> {
        let handles = listeners
            .into_iter()
            .map(|listener| {
                let body = &body;
                scope.spawn(move || -> io::Result<()> {
                    while Instant::now() < deadline {
                        let (mut stream, _) = match listener.accept() {
                            Ok(pair) => pair,
                            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                                std::thread::sleep(Duration::from_millis(10));
                                continue;
                            }
                            Err(error) => return Err(error),
                        };
                        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
                        stream.set_write_timeout(Some(Duration::from_secs(3)))?;
                        let mut header = Vec::new();
                        let mut byte = [0u8];
                        while !header.ends_with(b"\r\n\r\n") {
                            if header.len() == 4096 {
                                return Err(io::Error::other(
                                    "fixture request header exceeded bound",
                                ));
                            }
                            stream.read_exact(&mut byte)?;
                            header.push(byte[0]);
                        }
                        write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        )?;
                        stream.write_all(body)?;
                    }
                    Ok(())
                })
            })
            .collect::<Vec<_>>();
        for handle in handles {
            handle
                .join()
                .map_err(|_| io::Error::other("fixture server panicked"))??;
        }
        Ok(())
    })?;
    Ok(())
}

/// Hold eight public TLS tunnels while requiring a ninth registry request to progress.
pub fn verify_relay_capacity() -> Result<(), Box<dyn Error>> {
    fn header(stream: &mut std::net::TcpStream) -> io::Result<Vec<u8>> {
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            if bytes.len() == 4096 {
                return Err(io::Error::other("relay probe header exceeded bound"));
            }
            let mut byte = [0];
            stream.read_exact(&mut byte)?;
            bytes.push(byte[0]);
        }
        Ok(bytes)
    }
    let open = || -> io::Result<std::net::TcpStream> {
        let socket = std::net::TcpStream::connect_timeout(
            &"198.18.1.1:5001".parse().expect("fixture proxy address"),
            Duration::from_secs(5),
        )?;
        socket.set_read_timeout(Some(Duration::from_secs(5)))?;
        socket.set_write_timeout(Some(Duration::from_secs(5)))?;
        Ok(socket)
    };
    let mut held = Vec::new();
    for _ in 0..8 {
        let mut socket = open()?;
        socket.write_all(
            b"CONNECT registry-1.docker.io:443 HTTP/1.1\r\nHost: registry-1.docker.io:443\r\n\r\n",
        )?;
        if !header(&mut socket)?.starts_with(b"HTTP/1.1 200 ") {
            return Err("relay probe TLS tunnel failed".into());
        }
        held.push(socket);
    }
    println!("conjet-relay-eight-tunnels-held");
    let mut ping = open()?;
    ping.write_all(b"GET /v2/ HTTP/1.1\r\nHost: registry\r\nConnection: close\r\n\r\n")?;
    if !header(&mut ping)?.starts_with(b"HTTP/1.1 200 ") {
        return Err("registry request did not progress beside held TLS tunnels".into());
    }
    drop(held);
    println!("conjet-relay-capacity-ok");
    Ok(())
}

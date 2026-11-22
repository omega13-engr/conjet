use std::error::Error;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use conjet_launch_service::handshake::{host, random};
use conjet_launch_service::server::Budget;
use conjet_launch_service::socket::{Stream, read_key};
#[cfg(target_os = "macos")]
use conjet_launch_service::spec::{LaunchRequest, LaunchSpec, MIN_MEMORY_BYTES, ResourceLimits};
use conjet_launch_service::wire::{Frame, Kind};
use serde::Deserialize;
#[cfg(target_os = "macos")]
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Pong {
    boot_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ShutdownAck {
    boot_id: String,
    state: String,
}

#[cfg(target_os = "macos")]
fn launch(
    stream: &mut Stream,
    boot_id: &str,
    image_digest: String,
    network: String,
    sequence: u64,
) -> Result<(), Box<dyn Error>> {
    let request = LaunchRequest {
        boot_id: boot_id.into(),
        sequence,
        operation_id: None,
        budget_ms: 3_000,
        spec: LaunchSpec {
            image_digest,
            argv: vec!["/bin/probe".into()],
            env: Vec::new(),
            cwd: "/work".into(),
            uid: conjet_launch_service::spec::WORKLOAD_UID,
            gid: conjet_launch_service::spec::WORKLOAD_GID,
            network,
            limits: ResourceLimits {
                memory_bytes: MIN_MEMORY_BYTES,
                pids: 4,
                cpu_millicores: 500,
            },
        },
    };
    let request = request.validate()?;
    let id = random()?;
    let started = Instant::now();
    let deadline = started + Duration::from_secs(3);
    stream.deadline(Some(deadline));
    Frame::write(&mut *stream, Kind::Launch, id, request.request())?;
    let accepted: Value = Frame::read(&mut *stream)?.expect(Kind::State, id)?;
    let handle = accepted.get("handle").ok_or("expected workload handle")?;
    if handle.get("boot_id").and_then(Value::as_str) != Some(boot_id) {
        return Err("launch response changed boot generation".into());
    }
    let id = random()?;
    let budget = deadline
        .saturating_duration_since(Instant::now())
        .as_millis() as u64;
    if budget == 0 {
        return Err("launch exceeded its deadline".into());
    }
    Frame::write(
        &mut *stream,
        Kind::Wait,
        id,
        &json!({"handle":handle, "after_revision": u64::MAX, "budget_ms":budget}),
    )?;
    let removed: Value = Frame::read(stream)?.expect(Kind::State, id)?;
    if removed.get("handle") != Some(handle) {
        return Err("workload handle changed".into());
    }
    println!(
        "{}",
        json!({"elapsed_ns": started.elapsed().as_nanos(), "state": removed})
    );
    if removed["cleanup"] != "complete"
        || removed["exec"] != "confirmed"
        || removed["exit"] != json!({"code":0})
        || removed["helper_failed"] != false
    {
        return Err("fixture did not complete successfully".into());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn verify_peer(socket: &UnixStream, expected: libc::pid_t) -> Result<(), Box<dyn Error>> {
    use std::os::fd::AsRawFd;
    let mut peer = 0 as libc::pid_t;
    let mut size = std::mem::size_of_val(&peer) as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut peer as *mut libc::pid_t).cast(),
            &mut size,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if peer != expected || size as usize != std::mem::size_of_val(&peer) {
        return Err("unexpected native launch peer PID".into());
    }
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args_os().skip(1);
    let socket = PathBuf::from(args.next().ok_or("launch socket path required")?);
    let key_file = PathBuf::from(args.next().ok_or("private key path required")?);
    let action = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("ping count or --launch required")?;
    if action == "--launch" {
        #[cfg(target_os = "macos")]
        {
            let mut next = || {
                args.next()
                    .and_then(|value| value.into_string().ok())
                    .ok_or("usage: conjet-launch-client SOCKET KEY --launch DIGEST NETWORK SEQUENCE PEER_PID")
            };
            let image = next()?;
            let network = next()?;
            let sequence = next()?.parse()?;
            let peer = next()?.parse()?;
            if args.next().is_some() {
                return Err("unexpected native launch argument".into());
            }
            let key = read_key(&key_file)?;
            let socket = UnixStream::connect(socket)?;
            verify_peer(&socket, peer)?;
            let mut stream = Stream::unix(socket, None)?;
            stream.deadline(Some(Instant::now() + Duration::from_secs(2)));
            let capabilities = host(&mut stream, &key)?;
            return launch(&mut stream, &capabilities.boot_id, image, network, sequence);
        }
        #[cfg(not(target_os = "macos"))]
        return Err("the native benchmark CLI requires a macOS host peer check".into());
    }
    let samples: usize = action.parse()?;
    let shutdown = match args.next() {
        None => false,
        Some(value) if value == "--shutdown" => true,
        Some(_) => return Err("expected --shutdown".into()),
    };
    if samples > 100_000 || args.next().is_some() {
        return Err("usage: conjet-launch-client SOCKET KEY COUNT [--shutdown]".into());
    }
    let key = read_key(&key_file)?;
    let mut stream = Stream::unix(UnixStream::connect(socket)?, None)?;
    let started = Instant::now();
    stream.deadline(Some(started + Duration::from_secs(2)));
    let capabilities = host(&mut stream, &key)?;
    let handshake_ns = started.elapsed().as_nanos();
    let budget = Budget { budget_ms: 1_000 };
    let mut elapsed = Vec::with_capacity(samples);
    for _ in 0..samples {
        let id = random()?;
        let start = Instant::now();
        stream.deadline(Some(start + Duration::from_millis(budget.budget_ms)));
        Frame::write(&mut stream, Kind::Ping, id, &budget)?;
        let reply: Pong = Frame::read(&mut stream)?.expect(Kind::Pong, id)?;
        if reply.boot_id != capabilities.boot_id {
            return Err("ping response changed boot generation".into());
        }
        elapsed.push(start.elapsed().as_nanos());
    }
    if shutdown {
        let id = random()?;
        stream.deadline(Some(Instant::now() + Duration::from_secs(1)));
        Frame::write(&mut stream, Kind::Shutdown, id, &budget)?;
        let reply: ShutdownAck = Frame::read(&mut stream)?.expect(Kind::ShutdownAck, id)?;
        if reply.boot_id != capabilities.boot_id || reply.state != "stopped" {
            return Err("invalid shutdown acknowledgement".into());
        }
    }
    println!(
        "{}",
        serde_json::json!({
            "handshake_ns": handshake_ns,
            "capabilities": capabilities,
            "ping_roundtrip_ns": elapsed,
            "shutdown": shutdown,
        })
    );
    Ok(())
}

use std::error::Error;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use conjet_launch_service::handshake::{host, random};
use conjet_launch_service::server::Budget;
use conjet_launch_service::socket::{Stream, read_key};
use conjet_launch_service::wire::{Frame, Kind};
use serde::Deserialize;

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

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args_os().skip(1);
    let socket = PathBuf::from(args.next().ok_or("launch socket path required")?);
    let key_file = PathBuf::from(args.next().ok_or("private key path required")?);
    let samples: usize = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("ping count required")?
        .parse()?;
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

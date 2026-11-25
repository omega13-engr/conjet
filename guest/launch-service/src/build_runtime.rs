//! Standalone noninteractive runtime verbs used by the pinned BuildKit worker.

use std::error::Error;
use std::io::{self, Write};
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
    let deadline = Instant::now() + Duration::from_secs(33);
    loop {
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
                    return Ok(137);
                }
                return Err("build workload exec could not be verified".into());
            }
            let code = state["exit"]["code"]
                .as_i64()
                .or_else(|| state["exit"]["signal"].as_i64().map(|signal| 128 + signal))
                .filter(|&code| (0..=255).contains(&code))
                .ok_or("missing build exit status")?;
            return Ok(code as i32);
        }
        if Instant::now() >= deadline {
            return Err("build runtime wait exceeded its verified cleanup deadline".into());
        }
        std::thread::sleep(POLL);
    }
}

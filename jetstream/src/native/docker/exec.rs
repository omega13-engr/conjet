use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use conjet_launch_service::handshake::{hex, random, unhex};
use conjet_launch_service::spec::LaunchSpec;
use conjet_launch_service::wire::{Kind, WireError, EXEC_OUTPUT_LIMIT};
use serde_json::{json, Value};

use super::{client, Item, Owner, Rejected, CHUNK};

const CAPACITY: usize = 32;
const BUDGET_MS: u64 = 2000;

enum State {
    Created,
    Submitted,
    Finished(i64),
}

pub(super) struct Entry {
    id: String,
    container: Arc<Item>,
    generation: u64,
    argv: Vec<String>,
    output: [bool; 2],
    tty: bool,
    state: Mutex<State>,
    created: Instant,
}

pub(super) struct Result {
    pub(super) output: [Vec<u8>; 2],
    pub(super) error: Option<String>,
}

fn apply_defaults(value: &Value, config: &Value) -> std::result::Result<Vec<String>, Rejected> {
    let options = value
        .as_object()
        .ok_or_else(|| Rejected::bad("expected a Docker exec request"))?;
    for (name, value) in options {
        let supported = match name.as_str() {
            "Cmd" => value.is_array(),
            "AttachStdout" | "AttachStderr" => value.is_boolean(),
            "AttachStdin" | "Privileged" => value.is_null() || value == false,
            "Tty" => value.is_null() || value.is_boolean(),
            "User" | "WorkingDir" | "DetachKeys" => value.is_null() || value == "",
            "Env" => value.is_null() || value.as_array().is_some_and(Vec::is_empty),
            _ => false,
        };
        if !supported {
            return Err(Rejected::bad(format!(
                "unsupported Docker exec option {name}"
            )));
        }
    }
    let mut spec: LaunchSpec = serde_json::from_value(config.clone())
        .map_err(|_| Rejected::internal("could not read container process defaults"))?;
    spec.argv = serde_json::from_value(value["Cmd"].clone())
        .map_err(|_| Rejected::bad("exec requires an argv array"))?;
    spec.validate_exec()
        .map_err(|error| Rejected::bad(error.to_string()))?;
    Ok(spec.argv)
}

impl Entry {
    fn open(
        item: Arc<Item>,
        generation: u64,
        argv: Vec<String>,
        data: &Value,
    ) -> std::result::Result<Self, Rejected> {
        let id = hex(&random::<32>().map_err(|_| Rejected::internal("cannot allocate exec ID"))?);
        Ok(Self {
            id,
            container: item,
            generation,
            argv,
            output: [data["AttachStdout"] == true, data["AttachStderr"] == true],
            tty: data["Tty"] == true,
            state: Mutex::new(State::Created),
            created: Instant::now(),
        })
    }

    pub(super) fn tty(&self) -> bool {
        self.tty
    }

    pub(super) fn inspect(&self) -> Value {
        let state = self.state.lock().unwrap();
        let spec = &self.container.container.spec;
        let user = format!("{}:{}", spec["uid"], spec["gid"]);
        json!({
            "ID":self.id, "ContainerID":self.container.container.id,
            "Running":matches!(*state, State::Submitted),
            "ExitCode":match *state {State::Finished(code)=>Some(code), _=>None},
            "ProcessConfig":{"entrypoint":self.argv[0],"arguments":self.argv[1..],"tty":self.tty,"user":user},
            "OpenStdin":false, "OpenStdout":self.output[0], "OpenStderr":self.output[1],
        })
    }

    pub(super) fn reserve(&self, body: &[u8]) -> std::result::Result<Value, Rejected> {
        let data: Value =
            serde_json::from_slice(body).map_err(|_| Rejected::bad("invalid exec start body"))?;
        let data = data
            .as_object()
            .ok_or_else(|| Rejected::bad("invalid exec start body"))?;
        for (name, value) in data {
            let supported = match name.as_str() {
                "Detach" => value.is_null() || value == false,
                "Tty" => value.is_null() || value.is_boolean(),
                "ConsoleSize" => value.is_null() || value == &json!([0, 0]),
                _ => false,
            };
            if !supported {
                return Err(Rejected::bad(format!(
                    "unsupported exec start option {name}"
                )));
            }
        }
        if data.get("Tty").and_then(Value::as_bool).unwrap_or(false) != self.tty {
            return Err(Rejected::bad(
                "exec start TTY differs from the created exec",
            ));
        }
        let mut state = self.state.lock().unwrap();
        if !matches!(*state, State::Created) {
            return Err(Rejected(409, "native exec already submitted".into()));
        }
        if self.created.elapsed() >= Duration::from_secs(30) {
            return Err(Rejected(404, "native exec reservation expired".into()));
        }
        let no_longer_running = |container: &super::Lifecycle| {
            !container.started
                || container.removed
                || container.terminal.is_some()
                || container.error.is_some()
                || container.generation != self.generation
        };
        let (container, _) = self
            .container
            .changed
            .wait_timeout_while(
                self.container.state(),
                Duration::from_millis(500),
                |container| !no_longer_running(container) && container.native_handle.is_none(),
            )
            .unwrap();
        if no_longer_running(&container) {
            return Err(Rejected(
                409,
                "native exec target is no longer running".into(),
            ));
        }
        let handle = container
            .native_handle
            .clone()
            .ok_or_else(|| Rejected(409, "native exec target is preparing".into()))?;
        *state = State::Submitted;
        Ok(handle)
    }

    pub(super) fn run(&self, owner: &Owner, handle: Value) -> Result {
        let enabled = if self.tty {
            [self.output[0] || self.output[1], false]
        } else {
            self.output
        };
        let result = execute(owner, handle, &self.argv, enabled, self.tty, BUDGET_MS);
        let (status, reply) = match result {
            Ok(result) => result,
            Err(error) => (
                125,
                Result {
                    output: Default::default(),
                    error: Some(error),
                },
            ),
        };
        *self.state.lock().unwrap() = State::Finished(status);
        reply
    }
}

pub(super) fn execute(
    owner: &Owner,
    handle: Value,
    argv: &[String],
    enabled: [bool; 2],
    tty: bool,
    budget_ms: u64,
) -> std::result::Result<(i64, Result), String> {
    let mut control = owner
        .exec_peer
        .try_lock()
        .map_err(|_| "native exec slot is occupied")?;
    if control.is_none() {
        let native = owner.native.lock().unwrap();
        let candidate =
            client::Connection::open(&native.peer_directory, &native.identity, &native.key)
                .map_err(|error| error.to_string())?;
        if !candidate.oci || candidate.boot != native.boot {
            return Err("native exec boot generation changed".into());
        }
        *control = Some(candidate);
    }
    let connected = control.as_mut().expect("exec peer");
    let mut request = json!({"handle":handle,"budget_ms":budget_ms,"argv":argv});
    if tty {
        request["tty"] = json!(true);
    }
    let deadline = Instant::now() + Duration::from_millis(budget_ms);
    let reply = loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("native exec startup budget elapsed".into());
        }
        request["budget_ms"] = json!((remaining.as_millis() as u64).max(1));
        match connected.exchange(
            Kind::Exec,
            Kind::Exec,
            &request,
            remaining + Duration::from_secs(1),
        ) {
            Ok(reply) => break reply,
            Err(WireError::PeerError(code)) if code == "preparing" => {
                std::thread::sleep(remaining.min(Duration::from_millis(5)));
            }
            Err(WireError::PeerError(code)) => return Err(format!("native exec rejected: {code}")),
            Err(error) => {
                *control = None;
                return Err(format!("native exec outcome is unresolved: {error}"));
            }
        }
    };
    let result = decode_output(connected, reply, enabled);
    if result.is_err() {
        *control = None;
    }
    result
}

fn decode_output(
    peer: &mut client::Connection,
    reply: Value,
    enabled: [bool; 2],
) -> std::result::Result<(i64, Result), String> {
    let code = reply["exit_code"]
        .as_i64()
        .filter(|code| (0..=255).contains(code))
        .ok_or("invalid native exec exit status")?;
    let mut output: [Vec<u8>; 2] = Default::default();
    let mut overflow = false;
    let mut bytes = 0;
    let output_id = match reply.get("output_id") {
        Some(value) => Some(
            value
                .as_str()
                .filter(|value| unhex::<16>(value).is_ok())
                .ok_or("invalid native exec output identity")?,
        ),
        None => None,
    };
    for (index, stream) in ["stdout", "stderr"].iter().enumerate() {
        let decoded = if let Some(output_id) = output_id {
            let size = reply[*stream]["bytes"]
                .as_u64()
                .filter(|size| *size <= EXEC_OUTPUT_LIMIT as u64)
                .ok_or("native exec output exceeds its retained limit")?
                as usize;
            let dropped = reply[*stream]["dropped_bytes"]
                .as_u64()
                .ok_or("missing exec drop count")?;
            read_exec_chunks(peer, output_id, stream, size, dropped)?
        } else {
            decode_chunk(&reply[*stream])?
        };
        bytes += decoded.len();
        if output_id.is_none() && bytes > CHUNK {
            return Err("native exec output exceeds its wire bound".into());
        }
        overflow |= reply[*stream]["dropped_bytes"]
            .as_u64()
            .ok_or("missing exec drop count")?
            != 0;
        if enabled[index] {
            output[index] = decoded;
        }
    }
    Ok((
        code,
        Result {
            output,
            error: overflow.then(|| "native exec output exceeds the retained limit".into()),
        },
    ))
}

fn decode_chunk(reply: &Value) -> std::result::Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD
        .decode(reply["data"].as_str().ok_or("missing native exec output")?)
        .map_err(|_| "invalid native exec encoding".into())
}

fn read_exec_chunks(
    peer: &mut client::Connection,
    output_id: &str,
    stream: &str,
    size: usize,
    dropped: u64,
) -> std::result::Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(size);
    while output.len() < size {
        let offset = output.len();
        let reply = peer
            .exchange(
                Kind::ExecOutput,
                Kind::ExecOutput,
                &json!({"boot_id":peer.boot,"budget_ms":1000,"output_id":output_id,
                    "stream":stream,"offset":offset}),
                Duration::from_secs(2),
            )
            .map_err(|error| format!("native exec output transfer failed: {error}"))?;
        let chunk = decode_chunk(&reply)?;
        let next = offset + chunk.len();
        if chunk.is_empty()
            || chunk.len() > CHUNK
            || next > size
            || reply["offset"].as_u64() != Some(offset as u64)
            || reply["next_offset"].as_u64() != Some(next as u64)
            || reply["dropped_bytes"].as_u64() != Some(dropped)
            || reply["eof"].as_bool() != Some(next == size)
        {
            return Err("invalid native exec output chunk".into());
        }
        output.extend_from_slice(&chunk);
    }
    Ok(output)
}

impl Owner {
    pub(super) fn create_exec(
        &self,
        item: Arc<Item>,
        data: Value,
    ) -> std::result::Result<Value, Rejected> {
        let argv = apply_defaults(&data, &item.container.spec)?;
        let mut ledger = self.ledger.lock().unwrap();
        ledger.execs.retain(|entry| {
            if !matches!(*entry.state.lock().unwrap(), State::Created) {
                return true;
            }
            let target = entry.container.state();
            !target.removed
                && target.generation == entry.generation
                && entry.created.elapsed() < Duration::from_secs(30)
        });
        let generation = {
            let state = item.state();
            if !state.started || state.removed || state.terminal.is_some() || state.error.is_some()
            {
                return Err(Rejected(409, "native exec target is not running".into()));
            }
            state.generation
        };
        if ledger.execs.len() == CAPACITY {
            let expired = ledger
                .execs
                .iter()
                .position(|entry| matches!(*entry.state.lock().unwrap(), State::Finished(_)));
            if let Some(expired) = expired {
                ledger.execs.remove(expired);
            } else {
                return Err(Rejected(409, "native exec capacity is occupied".into()));
            }
        }
        let entry = Arc::new(Entry::open(item, generation, argv, &data)?);
        let receipt = json!({"Id":entry.id});
        ledger.execs.push_back(entry);
        Ok(receipt)
    }

    pub(super) fn lookup_exec(&self, id: &str) -> std::result::Result<Arc<Entry>, Rejected> {
        self.ledger
            .lock()
            .unwrap()
            .execs
            .iter()
            .find(|entry| id == entry.id)
            .cloned()
            .ok_or_else(|| Rejected(404, "native exec does not exist".into()))
    }
}

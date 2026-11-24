use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use conjet_launch_service::handshake::{hex, random};
use conjet_launch_service::spec::LaunchSpec;
use conjet_launch_service::wire::{Kind, WireError};
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
            "AttachStdin" | "Privileged" | "Tty" => value.is_null() || value == false,
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
            state: Mutex::new(State::Created),
            created: Instant::now(),
        })
    }

    pub(super) fn inspect(&self) -> Value {
        let state = self.state.lock().unwrap();
        let spec = &self.container.container.spec;
        let user = format!("{}:{}", spec["uid"], spec["gid"]);
        json!({
            "ID":self.id, "ContainerID":self.container.container.id,
            "Running":matches!(*state, State::Submitted),
            "ExitCode":match *state {State::Finished(code)=>Some(code), _=>None},
            "ProcessConfig":{"entrypoint":self.argv[0],"arguments":self.argv[1..],"tty":false,"user":user},
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
                "Tty" | "Detach" => value.is_null() || value == false,
                "ConsoleSize" => value.is_null() || value == &json!([0, 0]),
                _ => false,
            };
            if !supported {
                return Err(Rejected::bad(format!(
                    "unsupported exec start option {name}"
                )));
            }
        }
        let mut state = self.state.lock().unwrap();
        if !matches!(*state, State::Created) {
            return Err(Rejected(409, "native exec already submitted".into()));
        }
        if self.created.elapsed() >= Duration::from_secs(30) {
            return Err(Rejected(404, "native exec reservation expired".into()));
        }
        let container = self.container.state();
        if container.removed
            || container.terminal.is_some()
            || container.error.is_some()
            || container.generation != self.generation
        {
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
        let result = execute(owner, handle, &self.argv, self.output, BUDGET_MS);
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
    let reply = connected.exchange(
        Kind::Exec,
        Kind::Exec,
        &json!({"handle":handle,"budget_ms":budget_ms,"argv":argv}),
        Duration::from_millis(budget_ms + 1000),
    );
    let reply = match reply {
        Ok(reply) => reply,
        Err(WireError::PeerError(code)) => return Err(format!("native exec rejected: {code}")),
        Err(error) => {
            *control = None;
            return Err(format!("native exec outcome is unresolved: {error}"));
        }
    };
    let code = reply["exit_code"]
        .as_i64()
        .filter(|code| (0..=255).contains(code))
        .ok_or("invalid native exec exit status")?;
    let mut output: [Vec<u8>; 2] = Default::default();
    let mut overflow = false;
    let mut bytes = 0;
    for (index, stream) in ["stdout", "stderr"].iter().enumerate() {
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(
                reply[*stream]["data"]
                    .as_str()
                    .ok_or("missing native exec output")?,
            )
            .map_err(|_| "invalid native exec encoding")?;
        bytes += decoded.len();
        if bytes > CHUNK {
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

use std::io::{self, BufReader, Read};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use base64::Engine;
use conjet_launch_service::wire::{Kind, WireError};
use serde_json::{json, Value};

use super::{client, Item, Owner};

const CHUNK: usize = 4096;

pub(super) fn relay(
    owner: &Owner,
    item: &Item,
    generation: u64,
    mut reader: BufReader<UnixStream>,
) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(35);
    let active_generation = |state: &super::Lifecycle| {
        state.generation == generation
            && state.terminal.is_none()
            && state.error.is_none()
            && !state.removed
    };
    let handle = {
        let mut state = item.state();
        loop {
            if !active_generation(&state) || Instant::now() >= deadline {
                return Ok(());
            }
            if let Some(handle) = &state.native_handle {
                break handle.clone();
            }
            let (next, _) = item
                .changed
                .wait_timeout(state, Duration::from_millis(25))
                .unwrap();
            state = next;
        }
    };
    let mut guest = owner
        .scoped_peer()
        .map_err(|error| io::Error::other(error.1))?;
    reader
        .get_ref()
        .set_read_timeout(Some(Duration::from_millis(250)))?;
    let active = || active_generation(&item.state());
    let mut bytes = [0; CHUNK];
    while Instant::now() < deadline && active() {
        let data = match reader.read(&mut bytes) {
            Ok(0) => {
                if item.container.config["StdinOnce"] != true {
                    return Ok(());
                }
                None
            }
            Ok(count) => Some(base64::engine::general_purpose::STANDARD.encode(&bytes[..count])),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted
                        | io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                ) =>
            {
                continue
            }
            Err(error) => return Err(error),
        };
        while Instant::now() < deadline && active() {
            if send(&mut guest, &handle, data.as_deref())? {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        if data.is_none() {
            return Ok(());
        }
    }
    Ok(())
}

fn send(peer: &mut client::Connection, handle: &Value, data: Option<&str>) -> io::Result<bool> {
    let reply = peer.exchange(
        Kind::Input,
        Kind::Input,
        &json!({"handle":handle,"budget_ms":1000,"data":data}),
        Duration::from_secs(2),
    );
    match reply {
        Ok(reply) => reply["accepted"]
            .as_bool()
            .ok_or_else(|| io::Error::other("invalid native workload input acknowledgement")),
        Err(WireError::PeerError(code)) if code == "input_closed" => Ok(true),
        Err(WireError::PeerError(code)) if code == "not_running" => Ok(false),
        Err(error) => Err(io::Error::other(error)),
    }
}

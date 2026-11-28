use std::io::{self, BufReader, Read};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use base64::Engine;
use conjet_launch_service::wire::{Kind, WireError};
use serde_json::{json, Value};

use super::{client, Item, Owner, Rejected};

const CHUNK: usize = 4096;

pub(super) fn detach_keys(data: &str) -> Result<Vec<u8>, Rejected> {
    if data.is_empty() {
        return Ok(vec![16, 17]);
    }
    let mut bytes = Vec::new();
    for key in data.split(',') {
        let byte = match key.as_bytes() {
            [key] if key.is_ascii_graphic() => *key,
            [b'c', b't', b'r', b'l', b'-', key]
                if key.is_ascii_alphabetic() || (b'@'..=b'_').contains(key) =>
            {
                key & 31
            }
            _ => return Err(Rejected::bad("invalid Docker detach key")),
        };
        if bytes.len() == 16 {
            return Err(Rejected::bad("too many Docker detach keys"));
        }
        bytes.push(byte);
    }
    Ok(bytes)
}

fn filter(key: &[u8], pending: &mut Vec<u8>, input: &[u8]) -> (Vec<u8>, bool) {
    let mut output = Vec::with_capacity(input.len() + pending.len());
    for &byte in input {
        pending.push(byte);
        while !key.starts_with(pending) {
            output.push(pending.remove(0));
        }
        if pending.len() == key.len() {
            pending.clear();
            return (output, true);
        }
    }
    (output, false)
}

pub(super) fn relay(
    owner: &Owner,
    item: &Item,
    generation: u64,
    mut reader: BufReader<UnixStream>,
    detach: Option<&[u8]>,
) -> io::Result<bool> {
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
                return Ok(false);
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
    let mut pending = Vec::new();
    let mut forward = |data: Option<&str>| -> io::Result<()> {
        while Instant::now() < deadline && active() {
            if send(&mut guest, &handle, data)? {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Ok(())
    };
    while Instant::now() < deadline && active() {
        let length = match reader.read(&mut bytes) {
            Ok(length) => length,
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
        let (output, detached) = if length == 0 {
            (std::mem::take(&mut pending), false)
        } else if let Some(detach) = detach {
            filter(detach, &mut pending, &bytes[..length])
        } else {
            (bytes[..length].to_vec(), false)
        };
        for chunk in output.chunks(CHUNK) {
            let data = base64::engine::general_purpose::STANDARD.encode(chunk);
            forward(Some(&data))?;
        }
        if detached {
            return Ok(true);
        }
        if length == 0 {
            if detach.is_none() && item.container.config["StdinOnce"] == true {
                forward(None)?;
            }
            return Ok(false);
        }
    }
    Ok(false)
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

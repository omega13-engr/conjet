use std::fs::File;
use std::io::{Seek, Write};
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use base64::Engine;
use conjet_launch_service::wire::{Kind, WireError, COPY_LIMIT};
use serde::Deserialize;
use serde_json::{json, Value};

use super::{client, events, Item, Owner, Rejected, CHUNK};

#[derive(Deserialize)]
struct Info {
    name: String,
    directory: bool,
    mode: u32,
    identity: Value,
}

impl Info {
    fn bytes(&self) -> anyhow::Result<u64> {
        self.identity["bytes"]
            .as_u64()
            .context("invalid archive file size")
    }

    fn modified(&self) -> anyhow::Result<(i64, u32)> {
        let seconds = self.identity["modified"][0]
            .as_i64()
            .context("invalid archive timestamp")?;
        let nanos = self.identity["modified"][1]
            .as_u64()
            .filter(|value| *value < 1_000_000_000)
            .context("invalid archive timestamp")? as u32;
        Ok((seconds, nanos))
    }

    fn header(&self) -> Result<String, Rejected> {
        let bytes = self
            .bytes()
            .map_err(|error| Rejected::internal(error.to_string()))?;
        let (seconds, nanos) = self
            .modified()
            .map_err(|error| Rejected::internal(error.to_string()))?;
        let mode = self.mode | if self.directory { 1 << 31 } else { 0 };
        Ok(base64::engine::general_purpose::STANDARD.encode(
            json!({"name":self.name,"size":bytes,"mode":mode,
                   "mtime":events::format_time(seconds, nanos)?,"linkTarget":""})
            .to_string(),
        ))
    }
}

fn exchange(
    peer: &mut client::Connection,
    handle: &Value,
    operation: Value,
) -> Result<Value, WireError> {
    peer.exchange(
        Kind::Copy,
        Kind::Copy,
        &json!({"boot_id":peer.boot,"handle":handle,"budget_ms":1000,"operation":operation}),
        Duration::from_secs(2),
    )
}

fn file_archive(
    peer: &mut client::Connection,
    handle: &Value,
    scratch: &std::path::Path,
    info: &Info,
    path: &str,
) -> anyhow::Result<File> {
    let size = info.bytes()?;
    ensure!(
        size <= COPY_LIMIT,
        "workload archive file exceeds its byte bound"
    );
    ensure!(
        !info.name.contains('/') && !matches!(info.name.as_str(), "" | "." | ".."),
        "invalid workload archive member name"
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut data = tempfile::tempfile_in(scratch)?;
    let mut offset = 0;
    while offset < size {
        ensure!(Instant::now() < deadline, "workload archive read timed out");
        let reply = exchange(
            peer,
            handle,
            json!({
                "action":"read","path":path,"identity":info.identity,"offset":offset,
            }),
        )?;
        let bytes = base64::engine::general_purpose::STANDARD.decode(
            reply["data"]
                .as_str()
                .context("missing workload archive bytes")?,
        )?;
        let next = offset + bytes.len() as u64;
        ensure!(
            !bytes.is_empty()
                && bytes.len() <= CHUNK
                && next <= size
                && reply["offset"].as_u64() == Some(offset)
                && reply["next_offset"].as_u64() == Some(next)
                && reply["eof"].as_bool() == Some(next == size),
            "invalid workload archive chunk",
        );
        data.write_all(&bytes)?;
        offset = next;
    }
    data.rewind()?;
    let mut tar = tar::Builder::new(tempfile::tempfile_in(scratch)?);
    let mut header = tar::Header::new_ustar();
    header.set_size(size);
    header.set_mode(info.mode);
    header.set_mtime(u64::try_from(info.modified()?.0)?);
    header.set_cksum();
    tar.append_data(&mut header, &info.name, data)?;
    let mut archive = tar.into_inner()?;
    archive.rewind()?;
    Ok(archive)
}

impl Owner {
    fn archive_peer(&self) -> Result<client::Connection, Rejected> {
        let native = self.native.lock().unwrap();
        if native.broken {
            return Err(Rejected::internal(
                "authenticated native channel is unresolved",
            ));
        }
        let peer = client::Connection::open(&native.peer_directory, &native.identity, &native.key)
            .map_err(|error| Rejected::internal(error.to_string()))?;
        if !peer.oci || peer.boot != native.boot {
            return Err(Rejected::internal("native archive boot generation changed"));
        }
        Ok(peer)
    }

    pub(super) fn workload_archive(
        &self,
        item: &Item,
        path: &str,
        head: bool,
    ) -> Result<(String, Option<File>), Rejected> {
        let _control = item.control.lock().unwrap();
        let handle = {
            let state = item.state();
            if state.removed || state.terminal.is_some() || state.error.is_some() {
                return Err(Rejected(
                    409,
                    "archive requires a running native workload".into(),
                ));
            }
            state
                .native_handle
                .clone()
                .ok_or_else(|| Rejected(409, "native workload is still preparing".into()))?
        };
        let trimmed = path.trim_end_matches('/');
        let path = if path.starts_with('/') {
            if trimmed.is_empty() {
                "/".into()
            } else {
                trimmed.to_owned()
            }
        } else if trimmed.is_empty() {
            return Err(Rejected::bad("missing workload archive path"));
        } else {
            format!("/{trimmed}")
        };
        let mut peer = self.archive_peer()?;
        let stat = exchange(&mut peer, &handle, json!({"action":"stat","path":path})).map_err(
            |error| match error {
                WireError::PeerError(code) if code == "not_found" => {
                    Rejected(404, "native workload path was not found".into())
                }
                WireError::PeerError(code) => {
                    Rejected::bad(format!("native workload archive rejected: {code}"))
                }
                _ => Rejected::internal(error.to_string()),
            },
        )?;
        let info: Info = serde_json::from_value(stat)
            .map_err(|_| Rejected::internal("invalid native file metadata"))?;
        let stat = info.header()?;
        if head {
            return Ok((stat, None));
        }
        if info.directory {
            return Err(Rejected::bad(
                "native archive export requires a regular file",
            ));
        }
        let scratch = self
            .archive_root
            .as_deref()
            .ok_or_else(|| Rejected(501, "native archive scratch is not configured".into()))?;
        let archive = file_archive(&mut peer, &handle, scratch, &info, &path)
            .map_err(|error| Rejected::internal(format!("{error:#}")))?;
        Ok((stat, Some(archive)))
    }
}

use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use base64::Engine;
use conjet_launch_service::wire::{Kind, WireError, COPY_LIMIT};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::{client, events, Item, Owner, Rejected, CHUNK};

pub(super) const UPLOAD_LIMIT: usize = COPY_LIMIT as usize + 64 * 1024;

struct Upload {
    name: String,
    size: u64,
    mode: u32,
    offset: u64,
    digest: [u8; 32],
}

impl Upload {
    fn parse(mut file: &File) -> anyhow::Result<Self> {
        let mut archive = tar::Archive::new(file);
        let mut entries = archive.entries()?;
        let mut entry = entries.next().context("workload archive is empty")??;
        ensure!(
            entry.header().entry_type().is_file(),
            "workload archive requires a regular file"
        );
        let size = entry.size();
        let offset = entry.raw_file_position();
        let mode = entry.header().mode()?;
        let name = std::str::from_utf8(entry.path_bytes().as_ref())?.to_owned();
        ensure!(
            size <= COPY_LIMIT && mode & !0o777 == 0,
            "unsupported workload archive size or mode"
        );
        ensure!(
            name.len() <= 255
                && !name.contains(['/', '\0'])
                && !matches!(name.as_str(), "" | "." | ".."),
            "workload archive requires one unqualified file name"
        );
        let mut hash = Sha256::new();
        ensure!(
            std::io::copy(&mut entry, &mut hash)? == size,
            "incomplete workload archive entry"
        );
        ensure!(
            entries.next().transpose()?.is_none(),
            "workload archive requires exactly one file"
        );
        file.seek(SeekFrom::Start(offset + size.div_ceil(512) * 512))?;
        let mut trailer = [0; 1024];
        file.read_exact(&mut trailer)?;
        ensure!(
            trailer.iter().all(|byte| *byte == 0),
            "invalid workload archive trailer"
        );
        loop {
            let count = file.read(&mut trailer)?;
            ensure!(
                trailer[..count].iter().all(|byte| *byte == 0),
                "invalid workload archive trailer"
            );
            if count == 0 {
                break;
            }
        }
        Ok(Self {
            name,
            size,
            mode,
            offset,
            digest: hash.finalize().into(),
        })
    }

    fn send(
        &self,
        mut file: &File,
        peer: &mut client::Connection,
        handle: &Value,
        path: &str,
    ) -> anyhow::Result<()> {
        let deadline = Instant::now() + Duration::from_secs(30);
        exchange(
            peer,
            handle,
            json!({
                "action":"begin","path":path,"name":self.name,"size":self.size,"mode":self.mode,"digest":self.digest,
            }),
        ).context("begin workload archive upload")?;
        file.seek(SeekFrom::Start(self.offset))?;
        let mut offset = 0;
        let mut bytes = [0; CHUNK];
        while offset < self.size {
            ensure!(
                Instant::now() < deadline,
                "workload archive upload timed out"
            );
            let count = (self.size - offset).min(CHUNK as u64) as usize;
            file.read_exact(&mut bytes[..count])?;
            let result = exchange(
                peer,
                handle,
                json!({
                    "action":"write","offset":offset,"data":base64::engine::general_purpose::STANDARD.encode(&bytes[..count]),
                }),
            ).context("write workload archive chunk")?;
            offset += count as u64;
            ensure!(
                result["offset"].as_u64() == Some(offset),
                "invalid archive upload cursor"
            );
        }
        let result = exchange(peer, handle, json!({"action":"commit"}))
            .context("commit workload archive upload")?;
        ensure!(
            result["offset"].as_u64() == Some(self.size),
            "invalid archive upload acknowledgement"
        );
        Ok(())
    }
}

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
    let mut tar = tar::Builder::new(tempfile::tempfile_in(scratch)?);
    let mut header = tar::Header::new_ustar();
    header.set_size(size);
    header.set_mode(info.mode);
    header.set_mtime(u64::try_from(info.modified()?.0)?);
    header.set_cksum();
    if peer.copy_download && size > CHUNK as u64 {
        let mut entry = tar.append_writer(&mut header, &info.name)?;
        peer.copy_download(
            &json!({"handle":handle,"path":path,"identity":info.identity,"budget_ms":30000}),
            size,
            &mut entry,
        )?;
        entry.finish()?;
    } else {
        let data = read_archive_chunks(peer, handle, scratch, info, path, size)?;
        tar.append_data(&mut header, &info.name, data)?;
    }
    let mut archive = tar.into_inner()?;
    archive.rewind()?;
    Ok(archive)
}

fn read_archive_chunks(
    peer: &mut client::Connection,
    handle: &Value,
    scratch: &std::path::Path,
    info: &Info,
    path: &str,
    size: u64,
) -> anyhow::Result<File> {
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
    Ok(data)
}

impl Owner {
    pub(super) fn workload_archive(
        &self,
        item: &Item,
        path: &str,
        head: bool,
    ) -> Result<(String, Option<File>), Rejected> {
        let _control = item.control.lock().unwrap();
        let handle = archive_handle(item)?;
        let path = archive_path(path)?;
        let mut peer = self.scoped_peer()?;
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

    pub(super) fn workload_upload(
        &self,
        item: &Item,
        path: &str,
        file: &File,
    ) -> Result<(), Rejected> {
        let upload = Upload::parse(file)
            .map_err(|error| Rejected::bad(format!("invalid workload archive: {error}")))?;
        let path = archive_path(path)?;
        let _control = item.control.lock().unwrap();
        let handle = archive_handle(item)?;
        let mut peer = self.scoped_peer()?;
        upload
            .send(file, &mut peer, &handle, &path)
            .map_err(|error| match error.downcast_ref::<WireError>() {
                Some(WireError::PeerError(code)) if code == "not_found" => {
                    Rejected(404, "native archive destination was not found".into())
                }
                Some(WireError::PeerError(_)) => Rejected::bad(format!("{error:#}")),
                _ => Rejected::internal(format!("{error:#}")),
            })
    }
}

fn archive_handle(item: &Item) -> Result<Value, Rejected> {
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
        .ok_or_else(|| Rejected(409, "native workload is still preparing".into()))
}

fn archive_path(path: &str) -> Result<String, Rejected> {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.starts_with('/') {
            Ok("/".into())
        } else {
            Err(Rejected::bad("missing workload archive path"))
        };
    }
    if path.starts_with('/') {
        Ok(trimmed.into())
    } else {
        Ok(format!("/{trimmed}"))
    }
}

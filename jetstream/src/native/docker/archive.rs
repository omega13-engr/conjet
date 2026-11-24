//! Bounded Docker archive import and export using the verified OCI store.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use anyhow::{ensure, Context};
use conjet_launch_service::handshake::hex;
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};

use crate::native::oci_stage;

pub(super) const LIMIT: usize = 64 * 1024 * 1024;
pub(super) const LOCAL: &str = "conjet.local/archive";
const MAX_MEMBERS: usize = 128;

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Record {
    config: String,
    repo_tags: Option<Vec<String>>,
    layers: Vec<String>,
}

pub(super) struct Import {
    pub(super) manifest: String,
    pub(super) blobs: BTreeMap<String, Vec<u8>>,
    pub(super) tags: Vec<String>,
}

impl Import {
    pub(super) fn reference(&self) -> String {
        format!("{LOCAL}@{}", self.manifest)
    }
}

fn digest(bytes: &[u8]) -> String {
    format!("sha256:{}", hex(&Sha256::digest(bytes)))
}

fn member(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 512
        && name.split('/').all(|part| {
            !matches!(part, "" | "." | "..")
                && part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        })
}

pub(super) fn read(mut file: &File) -> anyhow::Result<Import> {
    ensure!(
        file.metadata()?.len() <= LIMIT as u64,
        "Docker archive exceeds its byte bound"
    );
    let mut parts = BTreeMap::new();
    let mut archive = tar::Archive::new(&mut file);
    let mut end = 0;
    let mut members = 0;
    for part in archive.entries()?.raw(true) {
        let mut part = part?;
        members += 1;
        ensure!(members <= MAX_MEMBERS, "too many Docker archive members");
        let kind = part.header().entry_type();
        let raw = part.path_bytes();
        let decoded = std::str::from_utf8(&raw)?.trim_end_matches('/');
        if kind.is_dir() && decoded == "." {
            ensure!(part.size() == 0, "invalid Docker archive directory");
            end = part.raw_file_position();
            continue;
        }
        let name = decoded.strip_prefix("./").unwrap_or(decoded).to_owned();
        ensure!(member(&name), "invalid Docker archive member name");
        ensure!(
            part.size() <= LIMIT as u64,
            "Docker archive member exceeds bound"
        );
        end = part.raw_file_position() + part.size().div_ceil(512) * 512;
        if kind.is_dir() {
            ensure!(part.size() == 0, "invalid Docker archive directory");
            continue;
        }
        ensure!(kind.is_file(), "unsupported Docker archive member");
        let bound = if name == "manifest.json" {
            oci_stage::METADATA_LIMIT
        } else {
            LIMIT
        };
        ensure!(
            part.size() <= bound as u64,
            "Docker archive member exceeds bound"
        );
        let mut data = Vec::new();
        part.read_to_end(&mut data)?;
        ensure!(
            parts.insert(name, data).is_none(),
            "duplicate Docker archive member"
        );
    }
    let file = archive.into_inner();
    ensure!(
        file.metadata()?.len() >= end + 1024,
        "incomplete Docker archive terminator"
    );
    file.seek(SeekFrom::Start(end))?;
    let mut padding = [0; 8192];
    loop {
        let size = file.read(&mut padding)?;
        if size == 0 {
            break;
        }
        ensure!(
            padding[..size].iter().all(|b| *b == 0),
            "unexpected Docker archive trailing bytes"
        );
    }
    let records: Vec<Record> = serde_json::from_slice(
        &parts
            .remove("manifest.json")
            .context("missing Docker archive manifest")?,
    )?;
    let [record]: [Record; 1] = records
        .try_into()
        .ok()
        .context("expected one Docker image")?;
    ensure!(
        (1..=16).contains(&record.layers.len()),
        "invalid Docker archive layer count"
    );
    let config = parts
        .remove(&record.config)
        .context("missing Docker archive config")?;
    ensure!(
        config.len() <= oci_stage::METADATA_LIMIT,
        "Docker archive config exceeds bound"
    );
    let config_digest = digest(&config);
    let expected = config_digest
        .strip_prefix("sha256:")
        .expect("SHA-256 digest");
    ensure!(
        record.config == format!("{expected}.json")
            || record.config == format!("blobs/sha256/{expected}"),
        "Docker archive config digest mismatch"
    );
    let mut layers = Vec::with_capacity(record.layers.len());
    let mut blobs = BTreeMap::from([(config_digest.clone(), config)]);
    let mut total = 0;
    for name in record.layers {
        let data = parts.get(&name).context("missing Docker archive layer")?;
        total += data.len();
        ensure!(
            total <= oci_stage::LAYER_BUDGET,
            "Docker archive layers exceed their ingest bound"
        );
        let image_digest = digest(data);
        if let Some(expected) = name.strip_prefix("blobs/sha256/") {
            ensure!(
                image_digest == format!("sha256:{expected}"),
                "Docker archive layer digest mismatch"
            );
        }
        let media = if data.starts_with(&[0x1f, 0x8b]) {
            "application/vnd.oci.image.layer.v1.tar+gzip"
        } else {
            "application/vnd.oci.image.layer.v1.tar"
        };
        layers.push(json!({"mediaType":media,"digest":image_digest,"size":data.len()}));
        blobs.entry(image_digest).or_insert_with(|| data.clone());
    }
    let config_len = blobs[&config_digest].len();
    let oci = serde_json::to_vec(&json!({
        "schemaVersion":2, "mediaType":"application/vnd.oci.image.manifest.v1+json",
        "config":{"mediaType":"application/vnd.oci.image.config.v1+json",
                  "digest":config_digest,"size":config_len},
        "layers":layers,
    }))?;
    let manifest = digest(&oci);
    blobs.insert(manifest.clone(), oci);
    Ok(Import {
        manifest,
        blobs,
        tags: record.repo_tags.unwrap_or_default(),
    })
}

pub(super) fn export(root: &Path, manifest: &str, tags: &[String]) -> anyhow::Result<File> {
    let image = oci_stage::read_manifest(root, manifest)?;
    let config = image
        .config
        .digest
        .strip_prefix("sha256:")
        .context("invalid config digest")?;
    let config = format!("{config}.json");
    let spool = tempfile::tempfile_in(root)?;
    let mut tar = tar::Builder::new(spool);
    let mut append = |name: &str, bytes: &[u8]| -> anyhow::Result<()> {
        let mut header = tar::Header::new_ustar();
        header.set_size(bytes.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, name, bytes)?;
        Ok(())
    };
    append(
        &config,
        &oci_stage::blob(root, &image.config.digest, oci_stage::METADATA_LIMIT)?,
    )?;
    let mut layers = Vec::with_capacity(image.layers.len());
    let mut budget = oci_stage::LAYER_BUDGET;
    for (index, layer) in image.layers.iter().enumerate() {
        let path = format!("layer-{index}/layer.tar");
        let bytes = oci_stage::blob(root, &layer.digest, budget)?;
        ensure!(bytes.len() == layer.size, "stored layer size changed");
        budget -= bytes.len();
        append(&path, &bytes)?;
        layers.push(path);
    }
    append(
        "manifest.json",
        &serde_json::to_vec(&json!([{
            "Config":config, "RepoTags":tags, "Layers":layers
        }]))?,
    )?;
    let mut spool = tar.into_inner()?;
    spool.flush()?;
    spool.rewind()?;
    Ok(spool)
}

//! Bounded Docker archive import and export using the verified OCI store.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::path::Path;

use anyhow::{ensure, Context};
use conjet_launch_service::handshake::hex;
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};

use crate::native::oci_stage;

// Archive payloads are spooled to private files, not retained in RAM.
// The OCI store independently enforces its encoding-specific ingest budget.
pub(super) const LIMIT: usize = 4 * 1024 * 1024 * 1024;
pub(super) const LOCAL: &str = "conjet.local/archive";
const MAX_MEMBERS: usize = 4 * oci_stage::LAYERS_LIMIT + 16;

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Record {
    config: String,
    repo_tags: Option<Vec<String>>,
    layers: Vec<String>,
}

pub(super) enum Blob<'a> {
    Inline(Vec<u8>),
    Extent { file: &'a File, bytes: Range<u64> },
}

impl Blob<'_> {
    pub(super) fn len(&self) -> u64 {
        match self {
            Self::Inline(bytes) => bytes.len() as u64,
            Self::Extent { bytes, .. } => bytes.end - bytes.start,
        }
    }

    pub(super) fn copy_to(&self, target: &mut impl Write) -> anyhow::Result<()> {
        match self {
            Self::Inline(bytes) => target.write_all(bytes)?,
            Self::Extent { file, bytes } => {
                let mut source = *file;
                source.seek(SeekFrom::Start(bytes.start))?;
                ensure!(
                    io::copy(&mut source.take(self.len()), target)? == self.len(),
                    "Docker archive layer ended during import"
                );
            }
        }
        Ok(())
    }
}

pub(super) struct Import<'a> {
    pub(super) manifest: String,
    pub(super) blobs: BTreeMap<String, Blob<'a>>,
    pub(super) tags: Vec<String>,
}

impl Import<'_> {
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

fn read_metadata(mut file: &File, extent: Range<u64>) -> anyhow::Result<Vec<u8>> {
    let size = extent.end - extent.start;
    ensure!(
        size <= oci_stage::METADATA_LIMIT as u64,
        "Docker archive metadata exceeds its bound"
    );
    let mut bytes = vec![0; size as usize];
    file.seek(SeekFrom::Start(extent.start))?;
    file.read_exact(&mut bytes)?;
    Ok(bytes)
}

pub(super) fn read(mut file: &File, layer_limit: u64) -> anyhow::Result<Import<'_>> {
    let length = file.metadata()?.len();
    ensure!(
        length <= LIMIT as u64,
        "Docker archive exceeds its byte bound"
    );
    let mut parts = BTreeMap::new();
    let mut archive = tar::Archive::new(&mut file);
    let mut end = 0;
    let mut members = 0;
    for part in archive.entries_with_seek()?.raw(true) {
        let part = part?;
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
        ensure!(end <= length, "truncated Docker archive member");
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
        let start = part.raw_file_position();
        ensure!(
            parts.insert(name, start..start + part.size()).is_none(),
            "duplicate Docker archive member"
        );
    }
    archive.into_inner();
    ensure!(length >= end + 1024, "incomplete Docker archive terminator");
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
    let records: Vec<Record> = serde_json::from_slice(&read_metadata(
        file,
        parts
            .remove("manifest.json")
            .context("missing Docker archive manifest")?,
    )?)?;
    let [record]: [Record; 1] = records
        .try_into()
        .ok()
        .context("expected one Docker image")?;
    ensure!(
        (1..=oci_stage::LAYERS_LIMIT).contains(&record.layers.len()),
        "invalid Docker archive layer count"
    );
    let config = read_metadata(
        file,
        parts
            .remove(&record.config)
            .context("missing Docker archive config")?,
    )?;
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
    let config_len = config.len();
    let mut blobs = BTreeMap::from([(config_digest.clone(), Blob::Inline(config))]);
    let mut total = 0;
    for name in record.layers {
        let bytes = parts.get(&name).context("missing Docker archive layer")?;
        let layer = Blob::Extent {
            file,
            bytes: bytes.clone(),
        };
        let size = layer.len();
        total += size;
        ensure!(
            total <= layer_limit,
            "Docker archive layers exceed their ingest bound"
        );
        let mut hash = Sha256::new();
        layer.copy_to(&mut hash)?;
        let image_digest = format!("sha256:{}", hex(&hash.finalize()));
        if let Some(expected) = name.strip_prefix("blobs/sha256/") {
            ensure!(
                image_digest == format!("sha256:{expected}"),
                "Docker archive layer digest mismatch"
            );
        }
        let mut magic = [0; 2];
        if size >= 2 {
            file.seek(SeekFrom::Start(bytes.start))?;
            file.read_exact(&mut magic)?;
        }
        let media = if magic == [0x1f, 0x8b] {
            "application/vnd.oci.image.layer.v1.tar+gzip"
        } else {
            "application/vnd.oci.image.layer.v1.tar"
        };
        layers.push(json!({"mediaType":media,"digest":image_digest,"size":size}));
        blobs.entry(image_digest).or_insert(layer);
    }
    let oci = serde_json::to_vec(&json!({
        "schemaVersion":2, "mediaType":"application/vnd.oci.image.manifest.v1+json",
        "config":{"mediaType":"application/vnd.oci.image.config.v1+json",
                  "digest":config_digest,"size":config_len},
        "layers":layers,
    }))?;
    let manifest = digest(&oci);
    blobs.insert(manifest.clone(), Blob::Inline(oci));
    Ok(Import {
        manifest,
        blobs,
        tags: record.repo_tags.unwrap_or_default(),
    })
}

pub(super) fn export(
    root: &Path,
    manifest: &str,
    tags: &[String],
    mut budget: u64,
) -> anyhow::Result<File> {
    let image = oci_stage::read_manifest(root, manifest)?;
    let config = image
        .config
        .digest
        .strip_prefix("sha256:")
        .context("invalid config digest")?;
    let config = format!("{config}.json");
    let spool = tempfile::tempfile_in(root)?;
    let mut tar = tar::Builder::new(spool);
    let mut append = |name: &str, size: u64, data: &mut dyn Read| -> anyhow::Result<()> {
        let mut header = tar::Header::new_ustar();
        header.set_size(size);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, name, data.take(size))?;
        Ok(())
    };
    let config_bytes = oci_stage::blob(root, &image.config.digest, oci_stage::METADATA_LIMIT)?;
    append(
        &config,
        config_bytes.len() as u64,
        &mut config_bytes.as_slice(),
    )?;
    let mut layers = Vec::with_capacity(image.layers.len());
    for (index, layer) in image.layers.iter().enumerate() {
        let path = format!("layer-{index}/layer.tar");
        let size = layer.size as u64;
        budget = budget
            .checked_sub(size)
            .context("Docker export exceeds its layer budget")?;
        let expected = layer
            .digest
            .strip_prefix("sha256:")
            .context("missing layer digest")?;
        conjet_launch_service::handshake::unhex::<32>(expected)?;
        let mut source =
            oci_stage::open_bounded(root, &root.join("blobs/sha256").join(expected), size)?;
        ensure!(
            oci_stage::digest_file(&mut source, size)? == expected,
            "stored layer digest changed"
        );
        append(&path, size, &mut source)?;
        layers.push(path);
    }
    let metadata = serde_json::to_vec(&json!([{
        "Config":config, "RepoTags":tags, "Layers":layers
    }]))?;
    append(
        "manifest.json",
        metadata.len() as u64,
        &mut metadata.as_slice(),
    )?;
    let mut spool = tar.into_inner()?;
    spool.flush()?;
    ensure!(
        spool.metadata()?.len() <= LIMIT as u64,
        "Docker archive exceeds its byte bound"
    );
    spool.rewind()?;
    Ok(spool)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archive_and_oci_manifest_share_the_layer_count_bound() {
        for count in [17, oci_stage::LAYERS_LIMIT, oci_stage::LAYERS_LIMIT + 1] {
            let mut builder = tar::Builder::new(tempfile::tempfile().unwrap());
            let config = b"{}";
            let name = format!("{}.json", hex(&Sha256::digest(config)));
            let layers = (0..count)
                .map(|i| format!("layer-{i}.tar"))
                .collect::<Vec<_>>();
            let metadata = serde_json::to_vec(&json!([{"Config":name,"Layers":layers}])).unwrap();
            for (name, bytes) in [
                (name.as_str(), config.as_slice()),
                ("manifest.json", metadata.as_slice()),
            ]
            .into_iter()
            .chain(
                layers
                    .iter()
                    .map(|name| (name.as_str(), b"layer".as_slice())),
            ) {
                let mut header = tar::Header::new_ustar();
                header.set_size(bytes.len() as u64);
                header.set_mode(0o644);
                header.set_cksum();
                builder.append_data(&mut header, name, bytes).unwrap();
            }
            let mut file = builder.into_inner().unwrap();
            file.rewind().unwrap();
            let result = read(&file, 1024 * 1024);
            if count > oci_stage::LAYERS_LIMIT {
                assert!(result.err().unwrap().to_string().contains("layer count"));
                continue;
            }
            let imported = result.unwrap();
            let root = tempfile::tempdir().unwrap();
            let blobs = root.path().join("blobs/sha256");
            std::fs::create_dir_all(&blobs).unwrap();
            let manifest = imported.manifest.strip_prefix("sha256:").unwrap();
            let mut output = File::create(blobs.join(manifest)).unwrap();
            imported.blobs[&imported.manifest]
                .copy_to(&mut output)
                .unwrap();
            assert_eq!(
                oci_stage::read_manifest(root.path(), &imported.manifest)
                    .unwrap()
                    .layers
                    .len(),
                count
            );
        }
    }

    #[test]
    fn large_image_layers_are_file_backed_and_respect_ingest_budget() {
        let size = 65 * 1024 * 1024;
        let file = tempfile::tempfile().unwrap();
        let mut archive = tar::Builder::new(file);
        let config = b"{}";
        let name = format!("{}.json", hex(&Sha256::digest(config)));
        let metadata = serde_json::to_vec(&json!([{
            "Config": name, "RepoTags":["large:local"], "Layers":["layer.tar"]
        }]))
        .unwrap();
        for (name, bytes) in [
            (name.as_str(), config.as_slice()),
            ("manifest.json", metadata.as_slice()),
        ] {
            let mut header = tar::Header::new_ustar();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            archive.append_data(&mut header, name, bytes).unwrap();
        }
        let mut header = tar::Header::new_ustar();
        header.set_size(size);
        header.set_mode(0o644);
        header.set_cksum();
        archive
            .append_data(&mut header, "layer.tar", io::repeat(0).take(size))
            .unwrap();
        let mut file = archive.into_inner().unwrap();
        file.rewind().unwrap();
        let image = read(&file, size).unwrap();
        assert!(image.blobs.values().any(
            |blob| matches!(blob, Blob::Extent { bytes, .. } if bytes.end - bytes.start == size)
        ));
        drop(image);
        file.rewind().unwrap();
        assert!(read(&file, size - 1)
            .err()
            .unwrap()
            .to_string()
            .contains("ingest bound"));
    }
}

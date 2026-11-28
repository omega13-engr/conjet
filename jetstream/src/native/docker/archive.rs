//! Bounded Docker archive import and export using the verified OCI store.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::path::Path;

use anyhow::{ensure, Context};
use conjet_launch_service::handshake::{hex, unhex};
use flate2::read::MultiGzDecoder;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::native::oci_stage;

// Archive payloads are spooled to private files, not retained in RAM.
// The OCI store independently enforces its encoding-specific ingest budget.
pub(super) const LIMIT: usize = 4 * 1024 * 1024 * 1024;
pub(super) const LOCAL: &str = "conjet.local/archive";
pub(super) const MAX_IMAGES: usize = 8;
const MAX_MEMBERS: usize = MAX_IMAGES * (4 * oci_stage::LAYERS_LIMIT + 16);

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

pub(super) fn decompress(mut file: &File, scratch: &Path) -> anyhow::Result<Option<File>> {
    file.rewind()?;
    let mut magic = [0; 2];
    file.read_exact(&mut magic)?;
    file.rewind()?;
    if magic != [0x1f, 0x8b] {
        return Ok(None);
    }
    let mut output = tempfile::tempfile_in(scratch)?;
    let mut gzip = MultiGzDecoder::new(file).take(LIMIT as u64 + 1);
    ensure!(
        io::copy(&mut gzip, &mut output)? <= LIMIT as u64,
        "uncompressed Docker archive exceeds its byte bound"
    );
    output.rewind()?;
    Ok(Some(output))
}

pub(super) fn read(mut file: &File, layer_limit: u64) -> anyhow::Result<Vec<Import<'_>>> {
    file.rewind()?;
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
    ensure!(
        (1..=MAX_IMAGES).contains(&records.len()),
        "invalid Docker archive image count"
    );
    let mut descriptors = BTreeMap::new();
    records
        .into_iter()
        .map(|record| read_record(file, &parts, &mut descriptors, record, layer_limit))
        .collect()
}

struct Layer {
    digest: String,
    media: &'static str,
}

fn read_record<'a>(
    mut file: &'a File,
    parts: &BTreeMap<String, Range<u64>>,
    descriptors: &mut BTreeMap<String, Layer>,
    record: Record,
    layer_limit: u64,
) -> anyhow::Result<Import<'a>> {
    ensure!(
        (1..=oci_stage::LAYERS_LIMIT).contains(&record.layers.len()),
        "invalid Docker archive layer count"
    );
    let config = read_metadata(
        file,
        parts
            .get(&record.config)
            .cloned()
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
        let descriptor = match descriptors.entry(name) {
            std::collections::btree_map::Entry::Occupied(entry) => entry.into_mut(),
            std::collections::btree_map::Entry::Vacant(entry) => {
                let mut hash = Sha256::new();
                layer.copy_to(&mut hash)?;
                let digest = format!("sha256:{}", hex(&hash.finalize()));
                if let Some(expected) = entry.key().strip_prefix("blobs/sha256/") {
                    ensure!(
                        digest == format!("sha256:{expected}"),
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
                entry.insert(Layer { digest, media })
            }
        };
        layers.push(json!({"mediaType":descriptor.media,"digest":descriptor.digest,"size":size}));
        blobs.entry(descriptor.digest.clone()).or_insert(layer);
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

#[derive(serde::Deserialize)]
struct HistoryStep {
    created: Option<String>,
    #[serde(default)]
    created_by: String,
    #[serde(default)]
    comment: String,
    #[serde(default)]
    empty_layer: bool,
}

pub(super) fn image_time(value: &str) -> anyhow::Result<i64> {
    let (base, zone) = value
        .get(..19)
        .zip(value.get(19..))
        .context("short image timestamp")?;
    let zone = if let Some(fraction) = zone.strip_prefix('.') {
        let zone = fraction.trim_start_matches(|c: char| c.is_ascii_digit());
        ensure!(
            zone.len() < fraction.len(),
            "invalid image timestamp fraction"
        );
        zone
    } else {
        zone
    };
    let offset = if zone == "Z" {
        0
    } else {
        let (sign, rest) = zone
            .get(..1)
            .zip(zone.get(1..))
            .context("missing image timestamp zone")?;
        let (hours, minutes) = rest
            .split_once(':')
            .context("invalid image timestamp zone")?;
        ensure!(
            hours.len() == 2 && minutes.len() == 2,
            "invalid image timestamp zone"
        );
        let (hours, minutes) = (hours.parse::<u8>()?, minutes.parse::<u8>()?);
        ensure!(hours < 24 && minutes < 60, "invalid image timestamp offset");
        let seconds = i64::from(hours) * 3600 + i64::from(minutes) * 60;
        match sign {
            "+" => seconds,
            "-" => -seconds,
            _ => anyhow::bail!("invalid image timestamp zone"),
        }
    };
    let base = std::ffi::CString::new(base)?;
    let mut time: libc::tm = unsafe { std::mem::zeroed() };
    // The format consumes only the bounded local date fields. Apply the
    // explicitly parsed offset without consulting the daemon's time zone.
    let end = unsafe { libc::strptime(base.as_ptr(), c"%Y-%m-%dT%H:%M:%S".as_ptr(), &mut time) };
    ensure!(
        end.cast_const() == unsafe { base.as_ptr().add(19) },
        "invalid image timestamp"
    );
    Ok(unsafe { libc::timegm(&mut time) } - offset)
}

pub(super) fn history(root: &Path, manifest: &str, tags: &[String]) -> anyhow::Result<Value> {
    let manifest = oci_stage::read_manifest(root, manifest)?;
    let bytes = oci_stage::blob(root, &manifest.config.digest, oci_stage::METADATA_LIMIT)?;
    let config: Value = serde_json::from_slice(&bytes)?;
    let history = serde_json::from_value::<Option<Vec<HistoryStep>>>(config["history"].clone())?
        .unwrap_or_default();
    let mut layers = manifest.layers.iter();
    let mut records = Vec::with_capacity(history.len());
    for step in history {
        let bytes = if step.empty_layer {
            0
        } else {
            layers
                .next()
                .context("image history has excess filesystem layers")?
                .size
        };
        let created = step
            .created
            .as_deref()
            .map(image_time)
            .transpose()?
            .unwrap_or_default();
        records.push(json!({
            "Id":"<missing>", "Created":created, "CreatedBy":step.created_by,
            "Tags":Value::Null, "Size":bytes, "Comment":step.comment,
        }));
    }
    records.reverse();
    if let Some(record) = records.first_mut() {
        record["Id"] = json!(manifest.config.digest);
        if !tags.is_empty() {
            record["Tags"] = json!(tags);
        }
    }
    Ok(json!(records))
}

pub(super) fn export(
    root: &Path,
    targets: BTreeMap<&str, BTreeSet<String>>,
    mut budget: u64,
) -> anyhow::Result<File> {
    let spool = tempfile::tempfile_in(root)?;
    let mut tar = tar::Builder::new(spool);
    let mut bytes = 0;
    let mut append = |name: &str, size: u64, data: &mut dyn Read| -> anyhow::Result<()> {
        bytes += 512 + size.div_ceil(512) * 512;
        ensure!(
            bytes + 1024 <= LIMIT as u64,
            "Docker archive exceeds its byte bound"
        );
        let mut header = tar::Header::new_ustar();
        header.set_size(size);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, name, data.take(size))?;
        Ok(())
    };
    let mut records = Vec::with_capacity(targets.len());
    let mut written = BTreeSet::new();
    for (manifest, tags) in targets {
        let image = oci_stage::read_manifest(root, manifest)?;
        let config = image
            .config
            .digest
            .strip_prefix("sha256:")
            .context("invalid config digest")?;
        let config = format!("{config}.json");
        if written.insert(config.clone()) {
            let data = oci_stage::blob(root, &image.config.digest, oci_stage::METADATA_LIMIT)?;
            append(&config, data.len() as u64, &mut data.as_slice())?;
        }
        let mut layers = Vec::with_capacity(image.layers.len());
        for layer in image.layers {
            let expected = layer
                .digest
                .strip_prefix("sha256:")
                .context("missing layer digest")?;
            unhex::<32>(expected)?;
            let path = format!("blobs/sha256/{expected}");
            if written.insert(path.clone()) {
                let size = layer.size as u64;
                budget = budget
                    .checked_sub(size)
                    .context("Docker export exceeds its layer budget")?;
                let mut source = oci_stage::open_bounded(root, &root.join(&path), size)?;
                ensure!(
                    oci_stage::digest_file(&mut source, size)? == expected,
                    "stored layer digest changed"
                );
                append(&path, size, &mut source)?;
            }
            layers.push(path);
        }
        records.push(json!({"Config":config,"RepoTags":tags,"Layers":layers}));
    }
    let metadata = serde_json::to_vec(&records)?;
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
            assert_eq!(imported.len(), 1);
            let imported = &imported[0];
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
    fn gzip_requires_a_complete_verified_stream() {
        use flate2::{write::GzEncoder, Compression};

        let root = tempfile::tempdir().unwrap();
        let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
        let bytes = b"uncompressed Docker archive";
        encoder.write_all(bytes).unwrap();
        let gzip = encoder.finish().unwrap();
        let mut input = tempfile::tempfile_in(root.path()).unwrap();

        input.write_all(bytes).unwrap();
        assert!(decompress(&input, root.path()).unwrap().is_none());

        input.set_len(0).unwrap();
        input.rewind().unwrap();
        input.write_all(&gzip).unwrap();
        let mut unpacked = decompress(&input, root.path()).unwrap().unwrap();
        let mut actual = Vec::new();
        unpacked.read_to_end(&mut actual).unwrap();
        assert_eq!(actual, bytes);

        input.set_len(gzip.len() as u64 - 1).unwrap();
        assert!(decompress(&input, root.path()).is_err());
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
        let images = read(&file, size).unwrap();
        assert_eq!(images.len(), 1);
        assert!(images[0].blobs.values().any(
            |blob| matches!(blob, Blob::Extent { bytes, .. } if bytes.end - bytes.start == size)
        ));
        drop(images);
        file.rewind().unwrap();
        assert!(read(&file, size - 1)
            .err()
            .unwrap()
            .to_string()
            .contains("ingest bound"));
    }
}

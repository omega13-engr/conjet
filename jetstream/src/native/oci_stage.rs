use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{self, BufReader, Cursor, Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{ensure, Context};
use base64::Engine;
use clap::Args;
use conjet_launch_service::handshake::{hex, unhex};
use conjet_launch_service::oci::{self, packed, Kind, Record, Root};
use flate2::read::MultiGzDecoder;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const SCRATCH: &str = "/Volumes/ExternalSSD/dev_workspace/tmp";
pub(super) const METADATA_LIMIT: usize = 64 * 1024;
pub(super) const LAYER_BUDGET: usize = 40 * 1024 * 1024;
const LAYERS_LIMIT: usize = 16;
pub(super) const DISK_COMPRESSED_BUDGET: u64 = 512 * 1024 * 1024;

#[derive(Debug, Args)]
pub(super) struct Options {
    #[arg(long)]
    layout: PathBuf,
    #[arg(long)]
    manifest_digest: String,
    #[arg(long)]
    output: PathBuf,
    /// Stage verified file extents for the leased native disk image store.
    #[arg(long)]
    disk_package: bool,
}

#[derive(Deserialize)]
pub(super) struct Descriptor {
    #[serde(rename = "mediaType")]
    media_type: String,
    pub(super) size: usize,
    pub(super) digest: String,
}

#[derive(Deserialize)]
pub(super) struct Manifest {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    pub(super) config: Descriptor,
    pub(super) layers: Vec<Descriptor>,
}

struct Entry {
    mode: u32,
    uid: u32,
    gid: u32,
    kind: Kind,
    layer: usize,
    data: Range<u64>,
    target: String,
}

type Tree = BTreeMap<String, Arc<Entry>>;

pub(super) fn open_bounded(root: &Path, path: &Path, bound: u64) -> anyhow::Result<File> {
    ensure!(
        path.starts_with(root) && path.canonicalize()? == path,
        "invalid OCI blob path"
    );
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.len() <= bound,
        "OCI blob exceeds its byte bound or is not a file"
    );
    Ok(file)
}

pub(super) fn read_bounded(root: &Path, path: &Path, bound: usize) -> anyhow::Result<Vec<u8>> {
    let file = open_bounded(root, path, bound as u64)?;
    let mut bytes = Vec::new();
    file.take(bound as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= bound, "OCI blob exceeds its byte bound");
    Ok(bytes)
}

pub(super) fn blob(root: &Path, digest: &str, bound: usize) -> anyhow::Result<Vec<u8>> {
    let suffix = digest
        .strip_prefix("sha256:")
        .context("expected a SHA-256 OCI digest")?;
    let expected = unhex::<32>(suffix)?;
    let bytes = read_bounded(root, &root.join("blobs/sha256").join(suffix), bound)?;
    ensure!(
        Sha256::digest(&bytes)[..] == expected,
        "OCI blob digest mismatch"
    );
    Ok(bytes)
}

fn read_descriptor(root: &Path, descriptor: &Descriptor, bound: usize) -> anyhow::Result<Vec<u8>> {
    ensure!(
        descriptor.size <= bound,
        "OCI descriptor exceeds its byte budget"
    );
    let bytes = blob(root, &descriptor.digest, descriptor.size)?;
    ensure!(
        descriptor.size == bytes.len(),
        "OCI descriptor size mismatch"
    );
    Ok(bytes)
}

fn text_path(bytes: &[u8], directory: bool) -> anyhow::Result<String> {
    let raw = std::str::from_utf8(bytes).context("invalid rootfs path encoding")?;
    let raw = if directory {
        raw.trim_end_matches('/')
    } else {
        raw
    };
    let path = raw.strip_prefix("./").unwrap_or(raw);
    ensure!(oci::root_path(path), "invalid rootfs entry path");
    Ok(path.to_owned())
}

#[derive(Default)]
struct PaxPaths {
    path: Option<Vec<u8>>,
    link: Option<Vec<u8>>,
}

fn pax_paths(mut bytes: &[u8]) -> anyhow::Result<PaxPaths> {
    let mut paths = PaxPaths::default();
    ensure!(!bytes.is_empty(), "empty OCI PAX header");
    while !bytes.is_empty() {
        let separator = bytes
            .iter()
            .position(|byte| *byte == b' ')
            .context("invalid OCI PAX length")?;
        let length = std::str::from_utf8(&bytes[..separator])?;
        ensure!(
            !length.is_empty() && length.bytes().all(|byte| byte.is_ascii_digit()),
            "invalid OCI PAX length"
        );
        let length: usize = length.parse()?;
        ensure!(
            length > separator + 1 && length <= bytes.len(),
            "invalid OCI PAX record size"
        );
        let record = bytes[separator + 1..length]
            .strip_suffix(b"\n")
            .context("missing OCI PAX record terminator")?;
        let equals = record
            .iter()
            .position(|byte| *byte == b'=')
            .context("missing OCI PAX field value")?;
        let (key, value) = (&record[..equals], &record[equals + 1..]);
        ensure!(
            !value.is_empty() && value.len() <= 1024 && !value.contains(&0),
            "invalid OCI PAX path"
        );
        let slot = match key {
            b"path" => &mut paths.path,
            b"linkpath" => &mut paths.link,
            _ => anyhow::bail!("unsupported OCI PAX field"),
        };
        ensure!(
            slot.replace(value.to_vec()).is_none(),
            "duplicate OCI PAX field"
        );
        bytes = &bytes[length..];
    }
    Ok(paths)
}

fn archive(
    source: &mut (impl Read + Seek),
    length: u64,
    layer: usize,
    limit: usize,
) -> anyhow::Result<BTreeMap<String, Entry>> {
    let mut entries = BTreeMap::new();
    let mut tar = tar::Archive::new(source);
    let mut end = 0;
    let mut root_seen = false;
    let mut extended = None;
    for entry in tar.entries_with_seek()?.raw(true) {
        let mut entry = entry?;
        let header = entry.header();
        let file_type = header.entry_type();
        ensure!(
            entry.raw_file_position() <= length && entry.size() <= length,
            "OCI tar member exceeds layer size"
        );
        end = entry.raw_file_position() + entry.size().div_ceil(512) * 512;
        ensure!(end <= length, "truncated OCI tar padding");
        if file_type == tar::EntryType::XHeader {
            ensure!(
                extended.is_none() && entry.size() <= 4096,
                "invalid OCI PAX header sequence or size"
            );
            let mut payload = Vec::new();
            entry.read_to_end(&mut payload)?;
            ensure!(
                payload.len() == entry.size() as usize,
                "truncated OCI PAX header"
            );
            extended = Some(pax_paths(&payload)?);
            continue;
        }
        let kind = match file_type {
            tar::EntryType::Regular => Kind::File,
            tar::EntryType::Directory => Kind::Directory,
            tar::EntryType::Symlink => Kind::Symlink,
            tar::EntryType::Link => Kind::Hardlink,
            _ => anyhow::bail!("unsupported OCI tar entry type"),
        };
        let extended = extended.take().unwrap_or_default();
        let raw = extended
            .path
            .map(std::borrow::Cow::Owned)
            .unwrap_or_else(|| entry.path_bytes());
        let mode = header.mode()?;
        let uid = u32::try_from(header.uid()?)?;
        let gid = u32::try_from(header.gid()?)?;
        ensure!(
            mode & !oci::mode_mask(kind) == 0 && uid <= 65535 && gid <= 65535,
            "unsafe OCI mode or ownership"
        );
        if kind == Kind::Directory && matches!(raw.as_ref(), b"." | b"./") {
            ensure!(
                !root_seen
                    && extended.link.is_none()
                    && entry.size() == 0
                    && mode == 0o755
                    && uid == 0
                    && gid == 0,
                "unsupported OCI root directory metadata"
            );
            root_seen = true;
            continue;
        }
        let path = text_path(&raw, kind == Kind::Directory)?;
        let link = extended
            .link
            .map(std::borrow::Cow::Owned)
            .or_else(|| entry.link_name_bytes());
        let target = match kind {
            Kind::Symlink => {
                let target =
                    std::str::from_utf8(link.as_deref().context("missing OCI symlink target")?)?;
                ensure!(
                    oci::rooted_symlink(&path, target),
                    "OCI symlink target escapes the guest root"
                );
                target.to_owned()
            }
            Kind::Hardlink => text_path(
                link.as_deref().context("missing OCI hard link target")?,
                false,
            )?,
            _ => {
                ensure!(link.is_none(), "unexpected OCI link target");
                String::new()
            }
        };
        let data = if kind == Kind::File {
            let start = entry.raw_file_position();
            start..start + entry.size()
        } else {
            ensure!(entry.size() == 0, "unexpected OCI tar payload");
            0..0
        };
        ensure!(
            entries.len() < limit
                && entries
                    .insert(
                        path,
                        Entry {
                            mode,
                            uid,
                            gid,
                            kind,
                            layer,
                            data,
                            target
                        }
                    )
                    .is_none(),
            "duplicate or too many OCI tar entries"
        );
    }
    ensure!(extended.is_none(), "unattached OCI PAX header");
    ensure!(
        length % 512 == 0 && length - end >= 1024,
        "malformed OCI tar trailer"
    );
    let source = tar.into_inner();
    source.seek(SeekFrom::Start(end))?;
    let mut buffer = [0; 8192];
    while end < length {
        let chunk = (length - end).min(buffer.len() as u64) as usize;
        source.read_exact(&mut buffer[..chunk])?;
        ensure!(
            buffer[..chunk].iter().all(|byte| *byte == 0),
            "malformed OCI tar trailer"
        );
        end += chunk as u64;
    }
    Ok(entries)
}

fn parent(path: &str) -> (&str, &str) {
    path.rsplit_once('/').unwrap_or(("", path))
}

fn is_under(path: &str, directory: &str) -> bool {
    directory.is_empty()
        || path
            .strip_prefix(directory)
            .is_some_and(|suffix| suffix.starts_with('/'))
}

fn parents(tree: &mut Tree, path: &str) -> anyhow::Result<()> {
    for (index, _) in path.match_indices('/') {
        let prefix = &path[..index];
        let entry = tree.entry(prefix.to_owned()).or_insert_with(|| {
            Arc::new(Entry {
                mode: 0o755,
                uid: 0,
                gid: 0,
                kind: Kind::Directory,
                layer: 0,
                data: 0..0,
                target: String::new(),
            })
        });
        ensure!(
            entry.kind == Kind::Directory,
            "OCI entry traverses a non-directory"
        );
    }
    Ok(())
}

fn apply(tree: &mut Tree, mut layer: BTreeMap<String, Entry>, limit: usize) -> anyhow::Result<()> {
    for (path, entry) in &layer {
        let (directory, name) = parent(path);
        let Some(whiteout) = name.strip_prefix(".wh.") else {
            continue;
        };
        ensure!(
            entry.kind == Kind::File && entry.data.is_empty(),
            "malformed OCI whiteout"
        );
        for (index, _) in path.match_indices('/') {
            let prefix = &path[..index];
            if let Some(ancestor) = layer
                .get(prefix)
                .map(|node| node.kind)
                .or_else(|| tree.get(prefix).map(|node| node.kind))
            {
                ensure!(
                    ancestor == Kind::Directory,
                    "OCI whiteout traverses a non-directory"
                );
            }
        }
        if whiteout == ".wh..opq" {
            tree.retain(|existing, _| !is_under(existing, directory));
        } else {
            ensure!(
                oci::root_path(whiteout) && !whiteout.starts_with(".wh."),
                "invalid OCI whiteout target"
            );
            let target = if directory.is_empty() {
                whiteout.to_owned()
            } else {
                format!("{directory}/{whiteout}")
            };
            tree.retain(|existing, _| existing != &target && !is_under(existing, &target));
        }
    }
    layer.retain(|path, _| !parent(path).1.starts_with(".wh."));
    let mut links = Vec::new();
    for (path, entry) in layer {
        parents(tree, &path)?;
        if entry.kind != Kind::Directory {
            tree.retain(|existing, _| !is_under(existing, &path));
        }
        if entry.kind == Kind::Hardlink {
            tree.remove(&path);
            links.push((path, entry.target));
        } else {
            tree.insert(path, Arc::new(entry));
        }
        ensure!(
            tree.len() + links.len() <= limit,
            "OCI rootfs exceeds its entry bound"
        );
    }
    // This subset accepts direct hard links to a regular entry and aliases
    // to already-resolved links. It rejects dangling links and cycles.
    while !links.is_empty() {
        let before = links.len();
        links.retain(|(path, target)| {
            if let Some(entry) = tree
                .get(target)
                .filter(|entry| entry.kind == Kind::File)
                .cloned()
            {
                tree.insert(path.clone(), entry);
                false
            } else {
                true
            }
        });
        ensure!(
            links.len() < before,
            "OCI hard link does not resolve to a regular file"
        );
    }
    Ok(())
}

fn records(tree: &Tree) -> impl Iterator<Item = (Record, Option<&Entry>)> {
    let mut targets = BTreeMap::new();
    tree.iter().map(move |(path, node)| {
        let mut kind = node.kind;
        let mut target = node.target.clone();
        let mut data = None;
        if kind == Kind::File {
            match targets.entry(Arc::as_ptr(node)) {
                std::collections::btree_map::Entry::Occupied(entry) => {
                    kind = Kind::Hardlink;
                    target = String::clone(entry.get());
                }
                std::collections::btree_map::Entry::Vacant(entry) => {
                    entry.insert(path.clone());
                    data = Some(node.as_ref());
                }
            }
        }
        (
            Record {
                path: path.clone(),
                mode: node.mode,
                uid: node.uid,
                gid: node.gid,
                kind,
                target,
                data: String::new(),
            },
            data,
        )
    })
}

fn process_metadata(config: &Value) -> anyhow::Result<Value> {
    let process = config["config"]
        .as_object()
        .context("missing OCI process config")?;
    let mut defaults = json!({});
    for key in ["Entrypoint", "Cmd", "Env"] {
        defaults[key] = match process.get(key) {
            None | Some(Value::Null) => json!([]),
            Some(value) if value.is_array() => value.clone(),
            _ => anyhow::bail!("invalid OCI process {key}"),
        };
    }
    for (key, fallback) in [("WorkingDir", "/"), ("User", "")] {
        defaults[key] = match process.get(key) {
            None | Some(Value::Null) => json!(fallback),
            Some(Value::String(value)) if value.is_empty() => json!(fallback),
            Some(Value::String(value)) => json!(value),
            _ => anyhow::bail!("invalid OCI process {key}"),
        };
    }
    Ok(defaults)
}

pub(super) fn read_manifest(layout: &Path, manifest_digest: &str) -> anyhow::Result<Manifest> {
    let manifest: Manifest =
        serde_json::from_slice(&blob(layout, manifest_digest, METADATA_LIMIT)?)?;
    ensure!(
        manifest.schema_version == 2
            && (1..=LAYERS_LIMIT).contains(&manifest.layers.len())
            && matches!(
                manifest.config.media_type.as_str(),
                "application/vnd.oci.image.config.v1+json"
                    | "application/vnd.docker.container.image.v1+json"
            ),
        "expected a bounded OCI image manifest"
    );
    Ok(manifest)
}

fn verify_metadata(layout: &Path, manifest_digest: &str) -> anyhow::Result<(Manifest, Value)> {
    let manifest = read_manifest(layout, manifest_digest)?;
    let config: Value =
        serde_json::from_slice(&read_descriptor(layout, &manifest.config, METADATA_LIMIT)?)?;
    ensure!(
        config["os"] == "linux"
            && config["architecture"] == "arm64"
            && config["rootfs"]["type"] == "layers",
        "expected a Linux ARM64 OCI rootfs"
    );
    let diff_ids = config["rootfs"]["diff_ids"]
        .as_array()
        .context("missing OCI diff IDs")?;
    ensure!(
        diff_ids.len() == manifest.layers.len(),
        "OCI layer and diff ID counts differ"
    );
    let receipt = json!({"config_digest":manifest.config.digest, "manifest_digest":manifest_digest,
                         "diff_ids":diff_ids, "layers":manifest.layers.iter().map(|layer| &layer.digest).collect::<Vec<_>>(),
                         "process":process_metadata(&config)?, "platform":"linux/arm64"});
    Ok((manifest, receipt))
}

fn verify(layout: &Path, manifest_digest: &str) -> anyhow::Result<(Root, Value)> {
    let (manifest, mut receipt) = verify_metadata(layout, manifest_digest)?;
    let mut budget = LAYER_BUDGET;
    let mut compressed_budget = LAYER_BUDGET;
    let mut tree = Tree::new();
    let mut layers = Vec::new();
    for (index, descriptor) in manifest.layers.iter().enumerate() {
        let content = read_descriptor(layout, descriptor, compressed_budget)?;
        compressed_budget -= content.len();
        let layer = match descriptor.media_type.as_str() {
            "application/vnd.oci.image.layer.v1.tar" => content,
            "application/vnd.oci.image.layer.v1.tar+gzip"
            | "application/vnd.docker.image.rootfs.diff.tar.gzip" => {
                let mut bytes = Vec::new();
                MultiGzDecoder::new(content.as_slice())
                    .take(budget as u64 + 1)
                    .read_to_end(&mut bytes)?;
                bytes
            }
            _ => anyhow::bail!("unsupported OCI layer media type"),
        };
        ensure!(
            layer.len() <= budget,
            "OCI layers exceed the uncompressed byte budget"
        );
        ensure!(
            receipt["diff_ids"][index] == format!("sha256:{}", hex(&Sha256::digest(&layer))),
            "uncompressed OCI diff ID mismatch"
        );
        let len = layer.len();
        budget -= len;
        layers.push(layer);
        let entries = archive(
            &mut Cursor::new(&layers[index]),
            len as u64,
            index,
            oci::MAX_RECORDS,
        )?;
        apply(&mut tree, entries, oci::MAX_RECORDS)?;
    }
    let root = Root {
        config_digest: manifest.config.digest,
        records: records(&tree)
            .map(|(mut record, entry)| {
                if let Some(entry) = entry {
                    let range = entry.data.start as usize..entry.data.end as usize;
                    record.data = base64::engine::general_purpose::STANDARD
                        .encode(&layers[entry.layer][range]);
                }
                record
            })
            .collect(),
    };
    receipt["rootfs_entries"] = json!(root.records.len());
    Ok((root, receipt))
}

pub(super) fn digest_file(file: &mut File, size: u64) -> anyhow::Result<String> {
    file.rewind()?;
    let mut hash = Sha256::new();
    ensure!(
        io::copy(&mut file.take(size + 1), &mut hash)? == size,
        "OCI file size changed during verification"
    );
    file.rewind()?;
    Ok(hex(&hash.finalize()))
}

fn disk_layer(
    layout: &Path,
    workspace: &Path,
    descriptor: &Descriptor,
    budget: u64,
) -> anyhow::Result<(File, u64)> {
    let digest = descriptor
        .digest
        .strip_prefix("sha256:")
        .context("expected an OCI digest")?;
    unhex::<32>(digest)?;
    let mut source = open_bounded(
        layout,
        &layout.join("blobs/sha256").join(digest),
        descriptor.size as u64,
    )?;
    ensure!(
        digest_file(&mut source, descriptor.size as u64)? == digest,
        "OCI blob digest mismatch"
    );
    let mut output = tempfile::tempfile_in(workspace)?;
    let size = match descriptor.media_type.as_str() {
        "application/vnd.oci.image.layer.v1.tar" => {
            io::copy(&mut source.take(budget + 1), &mut output)?
        }
        "application/vnd.oci.image.layer.v1.tar+gzip"
        | "application/vnd.docker.image.rootfs.diff.tar.gzip" => {
            let decoder = MultiGzDecoder::new(BufReader::new(source));
            io::copy(&mut decoder.take(budget + 1), &mut output)?
        }
        _ => anyhow::bail!("unsupported OCI layer media type"),
    };
    ensure!(
        size <= budget,
        "OCI layers exceed the uncompressed byte budget"
    );
    Ok((output, size))
}

fn write_disk_package(
    layout: &Path,
    manifest: &str,
    workspace: &Path,
) -> anyhow::Result<(String, Value)> {
    let (manifest, mut receipt) = verify_metadata(layout, manifest)?;
    let mut compressed_budget = DISK_COMPRESSED_BUDGET;
    let mut budget = packed::BYTE_LIMIT;
    let mut tree = Tree::new();
    let mut layers = Vec::new();
    for (index, descriptor) in manifest.layers.iter().enumerate() {
        compressed_budget = compressed_budget
            .checked_sub(descriptor.size as u64)
            .context("OCI descriptor exceeds its disk byte budget")?;
        let (mut layer, size) = disk_layer(layout, workspace, descriptor, budget)?;
        ensure!(
            receipt["diff_ids"][index] == format!("sha256:{}", digest_file(&mut layer, size)?),
            "uncompressed OCI diff ID mismatch"
        );
        budget -= size;
        let entries = archive(
            &mut BufReader::new(&mut layer),
            size,
            index,
            packed::RECORD_LIMIT,
        )?;
        apply(&mut tree, entries, packed::RECORD_LIMIT)?;
        layers.push(layer);
    }
    let mut package = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(workspace.join("package.cjoci"))?;
    packed::write_header(&mut package, &manifest.config.digest, tree.len())?;
    for (record, entry) in records(&tree) {
        if let Some(entry) = entry {
            let layer = &mut layers[entry.layer];
            layer.seek(SeekFrom::Start(entry.data.start))?;
            packed::write_record(
                &mut package,
                &record,
                layer,
                entry.data.end - entry.data.start,
            )?;
        } else {
            packed::write_record(&mut package, &record, &mut io::empty(), 0)?;
        }
    }
    let size = package.metadata()?.len();
    package.rewind()?;
    packed::Index::read(&mut BufReader::new(&mut package), size)?;
    let sha256 = digest_file(&mut package, size)?;
    package.sync_all()?;
    receipt["rootfs_entries"] = json!(tree.len());
    receipt["package_encoding"] = json!(oci::PackageEncoding::DiskV2);
    Ok((sha256, receipt))
}

pub(super) fn stage(options: Options) -> anyhow::Result<()> {
    let root = Path::new(SCRATCH);
    let layout = options.layout.canonicalize()?;
    let parent = options
        .output
        .parent()
        .context("staging output lacks a parent")?
        .canonicalize()?;
    ensure!(
        layout.starts_with(root) && parent.starts_with(root),
        "OCI staging requires ExternalSSD scratch"
    );
    let name = options
        .output
        .file_name()
        .context("missing staging directory name")?;
    let output = parent.join(name);
    let package_sha256 = publish_with_encoding(
        &layout,
        &options.manifest_digest,
        &output,
        if options.disk_package {
            oci::PackageEncoding::DiskV2
        } else {
            oci::PackageEncoding::Json
        },
    )?;
    println!(
        "{}",
        json!({"output":output, "package_sha256":package_sha256,
                         "manifest_digest":options.manifest_digest})
    );
    Ok(())
}

pub(super) fn publish_with_encoding(
    layout: &Path,
    manifest: &str,
    output: &Path,
    encoding: oci::PackageEncoding,
) -> anyhow::Result<String> {
    let parent = output.parent().context("missing OCI output parent")?;
    let staged = tempfile::tempdir_in(parent)?;
    let write = |name: &str, data: &[u8]| -> std::io::Result<()> {
        let mut file = File::create(staged.path().join(name))?;
        file.write_all(data)?;
        file.sync_all()
    };
    let (package_sha256, mut receipt) = match encoding {
        oci::PackageEncoding::Json => {
            let (tree, receipt) = verify(layout, manifest)?;
            let package = serde_json::to_vec(&tree)?;
            Root::read(&package)?;
            write("package.json", &package)?;
            (hex(&Sha256::digest(&package)), receipt)
        }
        oci::PackageEncoding::DiskV2 => write_disk_package(layout, manifest, staged.path())?,
    };
    receipt["package_sha256"] = json!(package_sha256);
    write("receipt.json", &serde_json::to_vec(&receipt)?)?;
    let source = std::ffi::CString::new(staged.path().as_os_str().as_bytes())?;
    let destination = std::ffi::CString::new(output.as_os_str().as_bytes())?;
    // Exclusive rename publishes both complete outputs without replacing
    // a directory belonging to an earlier invocation.
    if unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) } != 0 {
        return Err(std::io::Error::last_os_error()).context("cannot publish staged OCI package");
    }
    let _ = staged.keep();
    Ok(package_sha256)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_layer(layer: &[u8]) -> anyhow::Result<BTreeMap<String, Entry>> {
        archive(
            &mut Cursor::new(layer),
            layer.len() as u64,
            0,
            oci::MAX_RECORDS,
        )
    }

    fn link_layer(fields: &[(&str, &[u8])]) -> Vec<u8> {
        let mut archive = tar::Builder::new(Vec::new());
        archive
            .append_pax_extensions(fields.iter().copied())
            .unwrap();
        let mut header = tar::Header::new_ustar();
        header.set_entry_type(tar::EntryType::Symlink);
        header.set_mode(0o755);
        header.set_uid(0);
        header.set_gid(0);
        header.set_size(0);
        header.set_link_name("placeholder").unwrap();
        archive
            .append_data(&mut header, "old-name", &[][..])
            .unwrap();
        archive.into_inner().unwrap()
    }

    #[test]
    fn local_pax_paths_override_the_immediately_following_member() {
        let entries = read_layer(&link_layer(&[
            ("path", b"etc/renamed"),
            ("linkpath", b"../bin/probe"),
        ]))
        .unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries["etc/renamed"].target, "../bin/probe");
    }

    #[test]
    fn pax_cannot_override_ownership_or_bypass_root_path_validation() {
        for field in [
            ("uid", b"0".as_slice()),
            ("path", b"../outside".as_slice()),
            ("linkpath", b"../../outside".as_slice()),
        ] {
            assert!(read_layer(&link_layer(&[field])).is_err());
        }
        assert!(read_layer(&link_layer(&[("path", b"first"), ("path", b"second")])).is_err());
        let mut dangling = tar::Builder::new(Vec::new());
        dangling
            .append_pax_extensions([("path", b"unused".as_slice())])
            .unwrap();
        assert!(read_layer(&dangling.into_inner().unwrap()).is_err());
    }
}

use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Cursor, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{ensure, Context};
use base64::Engine;
use clap::Args;
use conjet_launch_service::handshake::{hex, unhex};
use flate2::read::MultiGzDecoder;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::oci::{self, Kind, Record, Root};

const SCRATCH: &str = "/Volumes/ExternalSSD/dev_workspace/tmp";
const METADATA_LIMIT: usize = 64 * 1024;
const LAYER_BUDGET: usize = 40 * 1024 * 1024;
const LAYERS_LIMIT: usize = 16;

#[derive(Debug, Args)]
pub(super) struct Options {
    #[arg(long)]
    layout: PathBuf,
    #[arg(long)]
    manifest_digest: String,
    #[arg(long)]
    output: PathBuf,
}

#[derive(Deserialize)]
struct Descriptor {
    #[serde(rename = "mediaType")]
    media_type: String,
    size: usize,
    digest: String,
}

#[derive(Deserialize)]
struct Manifest {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    config: Descriptor,
    layers: Vec<Descriptor>,
}

struct Entry {
    mode: u32,
    uid: u32,
    gid: u32,
    kind: Kind,
    data: Vec<u8>,
    target: String,
}

type Tree = BTreeMap<String, Arc<Entry>>;

fn read_bounded(root: &Path, path: &Path, bound: usize) -> anyhow::Result<Vec<u8>> {
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
        metadata.is_file() && metadata.len() <= bound as u64,
        "OCI blob exceeds its byte bound or is not a file"
    );
    let mut bytes = Vec::new();
    file.take(bound as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= bound, "OCI blob exceeds its byte bound");
    Ok(bytes)
}

fn blob(root: &Path, digest: &str, bound: usize) -> anyhow::Result<Vec<u8>> {
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

fn archive(layer: &[u8]) -> anyhow::Result<BTreeMap<String, Entry>> {
    let mut entries = BTreeMap::new();
    let mut tar = tar::Archive::new(Cursor::new(layer));
    let mut end = 0;
    let mut root_seen = false;
    for entry in tar.entries()?.raw(true) {
        let mut entry = entry?;
        let header = entry.header();
        let file_type = header.entry_type();
        let kind = match file_type {
            tar::EntryType::Regular => Kind::File,
            tar::EntryType::Directory => Kind::Directory,
            tar::EntryType::Symlink => Kind::Symlink,
            tar::EntryType::Link => Kind::Hardlink,
            _ => anyhow::bail!("unsupported OCI tar entry type"),
        };
        ensure!(
            entry.size() <= layer.len() as u64,
            "OCI tar member exceeds layer size"
        );
        end = entry.raw_file_position() + entry.size().div_ceil(512) * 512;
        let raw = entry.path_bytes();
        let mode = header.mode()?;
        let uid = u32::try_from(header.uid()?)?;
        let gid = u32::try_from(header.gid()?)?;
        ensure!(
            mode & !0o1777 == 0 && uid <= 65535 && gid <= 65535,
            "unsafe OCI mode or ownership"
        );
        if kind == Kind::Directory && matches!(raw.as_ref(), b"." | b"./") {
            ensure!(
                !root_seen && entry.size() == 0 && mode == 0o755 && uid == 0 && gid == 0,
                "unsupported OCI root directory metadata"
            );
            root_seen = true;
            continue;
        }
        let path = text_path(&raw, kind == Kind::Directory)?;
        let link = entry.link_name_bytes();
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
        let mut data = Vec::new();
        if kind == Kind::File {
            entry.read_to_end(&mut data)?;
            ensure!(
                data.len() == entry.size() as usize,
                "truncated OCI tar member"
            );
        } else {
            ensure!(entry.size() == 0, "unexpected OCI tar payload");
        }
        ensure!(
            entries.len() < oci::MAX_RECORDS
                && entries
                    .insert(
                        path,
                        Entry {
                            mode,
                            uid,
                            gid,
                            kind,
                            data,
                            target
                        }
                    )
                    .is_none(),
            "duplicate or too many OCI tar entries"
        );
    }
    let trailer = layer
        .get(end as usize..)
        .context("truncated OCI tar padding")?;
    ensure!(
        layer.len() % 512 == 0 && trailer.len() >= 1024 && trailer.iter().all(|byte| *byte == 0),
        "malformed OCI tar trailer"
    );
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
                data: Vec::new(),
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

fn apply(tree: &mut Tree, mut layer: BTreeMap<String, Entry>) -> anyhow::Result<()> {
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
            tree.len() + links.len() <= oci::MAX_RECORDS,
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

fn flatten(config_digest: String, tree: Tree) -> Root {
    let mut targets = BTreeMap::new();
    let records = tree
        .iter()
        .map(|(path, node)| {
            let mut kind = node.kind;
            let mut target = node.target.clone();
            let mut data = String::new();
            if kind == Kind::File {
                match targets.entry(Arc::as_ptr(node)) {
                    std::collections::btree_map::Entry::Occupied(entry) => {
                        kind = Kind::Hardlink;
                        target = String::clone(entry.get());
                    }
                    std::collections::btree_map::Entry::Vacant(entry) => {
                        entry.insert(path.clone());
                        data = base64::engine::general_purpose::STANDARD.encode(&node.data);
                    }
                }
            }
            Record {
                path: path.clone(),
                mode: node.mode,
                uid: node.uid,
                gid: node.gid,
                kind,
                target,
                data,
            }
        })
        .collect();
    Root {
        config_digest,
        records,
    }
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

fn verify(layout: &Path, manifest_digest: &str) -> anyhow::Result<(Root, Value)> {
    let manifest: Manifest =
        serde_json::from_slice(&blob(layout, manifest_digest, METADATA_LIMIT)?)?;
    ensure!(
        manifest.schema_version == 2
            && (1..=LAYERS_LIMIT).contains(&manifest.layers.len())
            && manifest.config.media_type == "application/vnd.oci.image.config.v1+json",
        "expected a bounded OCI image manifest"
    );
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
    let mut budget = LAYER_BUDGET;
    let mut compressed_budget = LAYER_BUDGET;
    let mut tree = Tree::new();
    for (descriptor, diff_id) in manifest.layers.iter().zip(diff_ids) {
        let content = read_descriptor(layout, descriptor, compressed_budget)?;
        compressed_budget -= content.len();
        let layer = match descriptor.media_type.as_str() {
            "application/vnd.oci.image.layer.v1.tar" => content,
            "application/vnd.oci.image.layer.v1.tar+gzip" => {
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
            *diff_id == format!("sha256:{}", hex(&Sha256::digest(&layer))),
            "uncompressed OCI diff ID mismatch"
        );
        budget -= layer.len();
        apply(&mut tree, archive(&layer)?)?;
    }
    let root = flatten(manifest.config.digest.clone(), tree);
    let receipt = json!({"config_digest":manifest.config.digest, "manifest_digest":manifest_digest,
                         "diff_ids":diff_ids, "layers":manifest.layers.iter().map(|layer| &layer.digest).collect::<Vec<_>>(),
                         "rootfs_entries":root.records.len(), "process":process_metadata(&config)?,
                         "platform":"linux/arm64"});
    Ok((root, receipt))
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
    let (tree, receipt) = verify(&layout, &options.manifest_digest)?;
    let package = serde_json::to_vec(&tree)?;
    ensure!(
        package.len() <= oci::PACKAGE_LIMIT as usize,
        "staged rootfs exceeds package bound"
    );
    Root::read(&package)?;
    let staged = tempfile::tempdir_in(parent)?;
    File::create(staged.path().join("package.json"))?.write_all(&package)?;
    File::create(staged.path().join("receipt.json"))?.write_all(&serde_json::to_vec(&receipt)?)?;
    let source = std::ffi::CString::new(staged.path().as_os_str().as_bytes())?;
    let destination = std::ffi::CString::new(output.as_os_str().as_bytes())?;
    // Exclusive rename publishes both complete outputs without replacing
    // a directory belonging to an earlier invocation.
    if unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) } != 0 {
        return Err(std::io::Error::last_os_error()).context("cannot publish staged OCI package");
    }
    let _ = staged.keep();
    println!(
        "{}",
        json!({"output":output, "package_sha256":hex(&Sha256::digest(&package)),
                         "manifest_digest":options.manifest_digest})
    );
    Ok(())
}

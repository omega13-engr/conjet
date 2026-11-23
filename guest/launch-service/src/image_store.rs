use std::collections::{BTreeMap, BTreeSet};
use std::ffi::CString;
use std::fs::{self, Permissions};
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::handshake::{hex, unhex};
use crate::oci::{Kind, PACKAGE_LIMIT, Root};
use crate::spec::{GID_BASE, UID_BASE};

const DIRECTORY: &str = "/run/conjet/oci-images";
const MAX_IMAGES: usize = 3;
const CHUNK: usize = 8192;
const TOTAL_BYTES: u64 = PACKAGE_LIMIT;
const IDLE: Duration = Duration::from_secs(10);

type Failure = (&'static str, &'static str);
pub(crate) type ConnectionId = [u8; 16];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Request {
    pub(crate) boot_id: String,
    pub(crate) budget_ms: u64,
    operation: Action,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, tag = "action", rename_all = "snake_case")]
enum Action {
    Begin {
        transfer: String,
        config_digest: String,
        package_digest: String,
        size: u64,
    },
    Write {
        transfer: String,
        offset: u64,
        data: String,
    },
    Commit {
        transfer: String,
    },
    Abort {
        transfer: String,
    },
    Remove {
        config_digest: String,
    },
}

struct Pending {
    owner: ConnectionId,
    transfer: String,
    config_digest: String,
    package_digest: [u8; 32],
    size: u64,
    bytes: Vec<u8>,
    seen: Instant,
}

struct Image {
    bytes: u64,
    package_digest: String,
}

#[derive(Default)]
pub(crate) struct Store {
    pending: Option<Pending>,
    images: BTreeMap<String, Image>,
}

fn digest(value: &str) -> Result<(&str, [u8; 32]), Failure> {
    let suffix = value
        .strip_prefix("sha256:")
        .ok_or(("malformed", "expected a SHA-256 digest"))?;
    let bytes = unhex(suffix).map_err(|_| ("malformed", "invalid SHA-256 digest"))?;
    Ok((suffix, bytes))
}

pub(crate) fn imported_root(config_digest: &str) -> Option<PathBuf> {
    let (suffix, _) = digest(config_digest).ok()?;
    Some(Path::new(DIRECTORY).join(suffix))
}

impl Store {
    pub(crate) fn contains(&self, config_digest: &str) -> bool {
        self.images.contains_key(config_digest)
    }

    pub(crate) fn snapshot(&self) -> Value {
        json!(self.images.iter().map(|(digest, image)| json!({
            "config_digest":digest, "package_digest":image.package_digest, "size":image.bytes
        })).collect::<Vec<_>>())
    }

    pub(crate) fn disconnect(&mut self, owner: ConnectionId) {
        if self
            .pending
            .as_ref()
            .is_some_and(|state| state.owner == owner)
        {
            self.pending = None;
        }
    }

    fn transfer(&mut self, id: &str, owner: ConnectionId) -> Result<&mut Pending, Failure> {
        self.pending
            .as_mut()
            .filter(|state| state.owner == owner && state.transfer == id)
            .ok_or(("not_found", "unknown OCI transfer"))
    }

    pub(crate) fn handle(
        &mut self,
        request: Request,
        owner: ConnectionId,
        boot_image: &str,
        live_images: &BTreeSet<String>,
        deadline: Instant,
    ) -> Result<Value, Failure> {
        if self
            .pending
            .as_ref()
            .is_some_and(|state| state.seen.elapsed() >= IDLE)
        {
            self.pending = None;
        }
        if Instant::now() >= deadline {
            return Err(("deadline_exceeded", "OCI transfer deadline elapsed"));
        }
        match request.operation {
            Action::Begin {
                transfer,
                config_digest,
                package_digest,
                size,
            } => {
                unhex::<16>(&transfer).map_err(|_| ("malformed", "invalid OCI transfer ID"))?;
                digest(&config_digest)?;
                let (_, package_digest) = digest(&package_digest)?;
                if config_digest == boot_image || self.contains(&config_digest) {
                    return Err(("id_conflict", "OCI image is already installed"));
                }
                if self.pending.is_some() {
                    return Err(("busy", "one OCI transfer is already owned"));
                }
                let used: u64 = self.images.values().map(|image| image.bytes).sum();
                if size == 0 || size > TOTAL_BYTES - used || self.images.len() >= MAX_IMAGES {
                    return Err(("capacity", "guest OCI image capacity exceeded"));
                }
                let mut bytes = Vec::new();
                bytes
                    .try_reserve_exact(size as usize)
                    .map_err(|_| ("capacity", "cannot reserve guest OCI transfer"))?;
                self.pending = Some(Pending {
                    owner,
                    transfer,
                    config_digest,
                    package_digest,
                    size,
                    bytes,
                    seen: Instant::now(),
                });
                Ok(json!({"offset":0}))
            }
            Action::Write {
                transfer,
                offset,
                data,
            } => {
                let state = self.transfer(&transfer, owner)?;
                let data = base64::engine::general_purpose::STANDARD
                    .decode(data)
                    .map_err(|_| ("malformed", "invalid OCI transfer encoding"))?;
                if offset != state.bytes.len() as u64
                    || data.is_empty()
                    || data.len() > CHUNK
                    || offset + data.len() as u64 > state.size
                {
                    return Err(("malformed", "invalid OCI transfer offset or chunk size"));
                }
                state.bytes.extend_from_slice(&data);
                state.seen = Instant::now();
                Ok(json!({"offset":state.bytes.len()}))
            }
            Action::Commit { transfer } => {
                self.transfer(&transfer, owner)?;
                let state = self.pending.take().expect("checked OCI transfer");
                if state.bytes.len() as u64 != state.size
                    || Sha256::digest(&state.bytes)[..] != state.package_digest
                {
                    return Err(("integrity", "OCI transfer package digest differs"));
                }
                let root = Root::read(&state.bytes)
                    .map_err(|_| ("integrity", "invalid staged OCI root"))?;
                if root.config_digest != state.config_digest {
                    return Err(("integrity", "staged OCI config digest differs"));
                }
                drop(state.bytes);
                if install(&root, &state.transfer, deadline).is_err() {
                    return Err(("image_install_failed", "cannot publish staged OCI image"));
                }
                self.images.insert(
                    state.config_digest.clone(),
                    Image {
                        bytes: state.size,
                        package_digest: format!("sha256:{}", hex(&state.package_digest)),
                    },
                );
                Ok(json!({"config_digest":state.config_digest,"state":"installed"}))
            }
            Action::Abort { transfer } => {
                self.transfer(&transfer, owner)?;
                self.pending = None;
                Ok(json!({"state":"aborted"}))
            }
            Action::Remove { config_digest } => {
                let path =
                    imported_root(&config_digest).ok_or(("malformed", "invalid OCI digest"))?;
                if config_digest == boot_image || live_images.contains(&config_digest) {
                    return Err(("busy", "OCI root is currently referenced"));
                }
                if !self.contains(&config_digest) {
                    return Err(("not_found", "OCI image was not installed"));
                }
                fs::remove_dir_all(path)
                    .map_err(|_| ("image_remove_failed", "cannot remove OCI image"))?;
                self.images.remove(&config_digest);
                Ok(json!({"state":"removed"}))
            }
        }
    }
}

pub(crate) fn reset_generation() -> io::Result<()> {
    let path = Path::new(DIRECTORY);
    match path.symlink_metadata() {
        Ok(metadata)
            if metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o777 == 0o711 =>
        {
            fs::remove_dir_all(path)
        }
        Ok(_) => Err(io::Error::other("invalid guest OCI generation store")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn owner_mode(path: &Path, uid: u32, gid: u32, mode: Option<u32>) -> io::Result<()> {
    let path_arg = CString::new(path.as_os_str().as_bytes())?;
    crate::security::checked(unsafe {
        libc::lchown(path_arg.as_ptr(), UID_BASE + uid, GID_BASE + gid)
    })?;
    if let Some(mode) = mode {
        fs::set_permissions(path, Permissions::from_mode(mode))?;
    }
    Ok(())
}

fn install(root: &Root, transfer: &str, deadline: Instant) -> io::Result<()> {
    let directory = Path::new(DIRECTORY);
    match fs::DirBuilder::new().mode(0o711).create(directory) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            let metadata = directory.symlink_metadata()?;
            if !metadata.is_dir() || metadata.uid() != 0 || metadata.mode() & 0o777 != 0o711 {
                return Err(io::Error::other("invalid guest OCI store"));
            }
        }
        Err(error) => return Err(error),
    }
    let staging = directory.join(format!(".{transfer}"));
    fs::DirBuilder::new().mode(0o700).create(&staging)?;
    let result = (|| {
        let image = staging.join("root");
        fs::create_dir(&image)?;
        fs::set_permissions(&image, Permissions::from_mode(0o755))?;
        let mut entries = root.records.iter().collect::<Vec<_>>();
        entries.sort_unstable_by_key(|part| &part.path);
        for record in &entries {
            if Instant::now() >= deadline {
                return Err(io::Error::other("OCI installation deadline elapsed"));
            }
            let target = image.join(&record.path);
            match record.kind {
                Kind::Directory => fs::create_dir(&target)?,
                Kind::File => {
                    let data = base64::engine::general_purpose::STANDARD
                        .decode(&record.data)
                        .map_err(io::Error::other)?;
                    fs::File::create_new(&target)?.write_all(&data)?;
                    owner_mode(&target, record.uid, record.gid, Some(record.mode))?;
                }
                Kind::Symlink => {
                    symlink(&record.target, &target)?;
                    owner_mode(&target, record.uid, record.gid, None)?;
                }
                Kind::Hardlink => {}
            }
        }
        for record in entries.into_iter().rev() {
            let target = image.join(&record.path);
            match record.kind {
                Kind::Directory => owner_mode(&target, record.uid, record.gid, Some(record.mode))?,
                Kind::Hardlink => fs::hard_link(image.join(&record.target), &target)?,
                _ => {}
            }
        }
        let groups = root.link_groups();
        if !groups.is_empty() {
            let groups = serde_json::to_vec(&groups)?;
            if groups.len() > 5 * 1024 * 1024 {
                return Err(io::Error::other("OCI hard-link manifest exceeds its bound"));
            }
            fs::write(staging.join("hardlinks.json"), groups)?;
        }
        fs::set_permissions(&staging, Permissions::from_mode(0o711))?;
        let path = imported_root(&root.config_digest)
            .ok_or_else(|| io::Error::other("invalid OCI config digest"))?;
        if path.symlink_metadata().is_ok() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "guest OCI image already exists",
            ));
        }
        fs::rename(&staging, &path)
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(staging);
    }
    result
}

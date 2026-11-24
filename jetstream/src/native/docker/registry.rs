use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use conjet_launch_service::handshake::unhex;
use conjet_launch_service::oci::PackageEncoding;
use serde_json::Value;

use super::{archive, client, image, private_scratch, public_registry, request, STOP};
use crate::native::oci_stage;

const MAX_STORED: u64 = 256 * 1024 * 1024;
const MAX_DISK_STORED: u64 = 4 * 1024 * 1024 * 1024;
const MAX_IMAGES: usize = 16;
const MAX_HEADERS: usize = 8192;
const IO_TIMEOUT: Duration = Duration::from_secs(4);
const METADATA: usize = oci_stage::METADATA_LIMIT;
const LAYERS: usize = oci_stage::LAYER_BUDGET;
const STORE_VERSION: &[u8] = b"conjet-native-image-store-1\n";

pub(super) struct Store {
    root: PathBuf,
    registry: Option<SocketAddr>,
    public: public_registry::Pins,
    encoding: PackageEncoding,
    installed: BTreeMap<String, String>,
    _lock: File,
}

struct Reference<'a> {
    repository: &'a str,
    manifest: &'a str,
    origin: Origin,
}

enum Origin {
    Loopback(SocketAddr),
    Public,
}

struct Download {
    free: u64,
    created: Vec<PathBuf>,
    deadline: Instant,
    token: Option<public_registry::Token>,
}

fn incomplete_entry(name: &str) -> bool {
    name.starts_with(".tmp") || name.starts_with(".deleted-")
}

pub(super) struct Image {
    pub(super) metadata: request::Image,
    receipt: Value,
    manifest: String,
}

fn suffix(digest: &str) -> anyhow::Result<&str> {
    let value = digest
        .strip_prefix("sha256:")
        .context("expected an immutable SHA-256 digest")?;
    unhex::<32>(value)?;
    Ok(value)
}

fn package_encoding(receipt: &Value) -> anyhow::Result<PackageEncoding> {
    match receipt.get("package_encoding") {
        None => Ok(PackageEncoding::Json),
        Some(value) => Ok(serde_json::from_value(value.clone())?),
    }
}

fn package_name(encoding: PackageEncoding) -> &'static str {
    match encoding {
        PackageEncoding::Json => "package.json",
        PackageEncoding::DiskV2 => "package.cjoci",
    }
}

impl Store {
    pub(super) fn open(
        root: PathBuf,
        registry: Option<SocketAddr>,
        allow_public: bool,
        status: &Value,
    ) -> anyhow::Result<Self> {
        private_scratch(&root)?;
        ensure!(
            registry.is_none_or(|address| address.ip().is_loopback() && address.port() > 0),
            "registry must be an explicit loopback socket"
        );
        let marker = root.join(".conjet-native-store");
        let initialise = !marker.exists();
        if initialise {
            ensure!(
                root.read_dir()?.next().is_none(),
                "image store must begin in a dedicated empty directory"
            );
        }
        let mut lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(initialise)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(marker)?;
        let meta = lock.metadata()?;
        ensure!(
            meta.is_file() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o077 == 0,
            "invalid image store ownership"
        );
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error()).context("image store is already owned");
        }
        if initialise {
            fs::create_dir(root.join("images"))?;
            fs::create_dir_all(root.join("blobs/sha256"))?;
            lock.write_all(STORE_VERSION)?;
            lock.sync_all()?;
        } else {
            let mut version = Vec::new();
            (&lock).take(128).read_to_end(&mut version)?;
            ensure!(version == STORE_VERSION, "unrecognised image store version");
        }
        for directory in ["images", "blobs", "blobs/sha256"] {
            let path = root.join(directory);
            ensure!(
                path.canonicalize()? == path && path.is_dir(),
                "invalid image store directory"
            );
        }
        let installed = status["installed_images"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|image| {
                Some((
                    image["config_digest"].as_str()?.to_owned(),
                    image["package_digest"]
                        .as_str()?
                        .strip_prefix("sha256:")?
                        .to_owned(),
                ))
            })
            .collect();
        let store = Self {
            root,
            registry,
            public: if allow_public {
                public_registry::Pins::frozen()?
            } else {
                public_registry::Pins::default()
            },
            encoding: if status["disk_image_store"] == true {
                PackageEncoding::DiskV2
            } else {
                PackageEncoding::Json
            },
            installed,
            _lock: lock,
        };
        store.recover()?;
        Ok(store)
    }

    fn reference<'s>(&'s self, reference: &'s str) -> anyhow::Result<Reference<'s>> {
        let (name, manifest) = reference
            .rsplit_once('@')
            .context("native pull requires a pinned registry digest")?;
        suffix(manifest)?;
        if let Some(repository) = self.public.repository(name, manifest) {
            return Ok(Reference {
                repository,
                manifest,
                origin: Origin::Public,
            });
        }
        let registry = self
            .registry
            .context("image is outside the frozen public registry pins")?;
        let (authority, repository) = name
            .split_once('/')
            .context("native pull requires the allowlisted registry")?;
        ensure!(
            authority == registry.to_string()
                && repository.len() <= 200
                && repository.split('/').all(|part| {
                    !part.is_empty()
                        && part.as_bytes()[0].is_ascii_alphanumeric()
                        && part.bytes().all(|byte| {
                            byte.is_ascii_lowercase()
                                || byte.is_ascii_digit()
                                || b"._-".contains(&byte)
                        })
                }),
            "native pull requires a valid repository at the allowlisted registry"
        );
        Ok(Reference {
            repository,
            manifest,
            origin: Origin::Loopback(registry),
        })
    }

    fn path(&self, manifest: &str) -> anyhow::Result<PathBuf> {
        Ok(self.root.join("images").join(suffix(manifest)?))
    }

    fn receipt(&self, manifest: &str) -> anyhow::Result<Value> {
        let bytes = oci_stage::read_bounded(
            &self.root,
            &self.path(manifest)?.join("receipt.json"),
            METADATA,
        )?;
        let receipt: Value = serde_json::from_slice(&bytes)?;
        ensure!(
            receipt["manifest_digest"] == manifest,
            "cached OCI receipt identity differs"
        );
        Ok(receipt)
    }

    fn references(receipt: &Value) -> anyhow::Result<BTreeSet<String>> {
        let layers = receipt["layers"]
            .as_array()
            .context("missing layer identities")?;
        let mut referenced = BTreeSet::new();
        for field in layers
            .iter()
            .chain([&receipt["manifest_digest"], &receipt["config_digest"]])
        {
            let id = field.as_str().context("invalid cached OCI descriptor")?;
            suffix(id)?;
            referenced.insert(id.to_owned());
        }
        Ok(referenced)
    }

    fn inventory(&self) -> anyhow::Result<BTreeSet<String>> {
        let mut referenced = BTreeSet::new();
        for item in self.root.join("images").read_dir()? {
            let item = item?;
            let name = item.file_name();
            let name = name.to_str().context("invalid image directory name")?;
            if incomplete_entry(name) && item.file_type()?.is_dir() {
                // Internal tempfile output left by an interrupted publisher.
                continue;
            }
            ensure!(
                item.file_type()?.is_dir(),
                "unexpected image directory type"
            );
            let manifest = format!("sha256:{name}");
            referenced.extend(Self::references(&self.receipt(&manifest)?)?);
        }
        Ok(referenced)
    }

    fn recover(&self) -> anyhow::Result<()> {
        let refs = self.inventory()?;
        for item in self.root.join("images").read_dir()? {
            let item = item?;
            if item.file_type()?.is_dir() && incomplete_entry(&item.file_name().to_string_lossy()) {
                fs::remove_dir_all(item.path())?;
            }
        }
        for item in self.root.join("blobs/sha256").read_dir()? {
            let item = item?;
            ensure!(item.file_type()?.is_file(), "unexpected blob backing type");
            let name = item.file_name();
            let name = name.to_str().context("invalid blob name")?;
            if !name.starts_with(".tmp") {
                let digest = format!("sha256:{name}");
                suffix(&digest)?;
                if refs.contains(&digest) {
                    continue;
                }
            }
            fs::remove_file(item.path())?;
        }
        Ok(())
    }

    fn stored_bytes(&self) -> anyhow::Result<u64> {
        let mut bytes = 0u64;
        for item in self.root.join("blobs/sha256").read_dir()? {
            bytes = bytes.saturating_add(item?.metadata()?.len());
        }
        for item in self.root.join("images").read_dir()? {
            let item = item?;
            let name = item.file_name();
            let digest = format!(
                "sha256:{}",
                name.to_str().context("invalid image directory name")?
            );
            let encoding = package_encoding(&self.receipt(&digest)?)?;
            let package = oci_stage::open_bounded(
                &self.root,
                &item.path().join(package_name(encoding)),
                encoding.byte_limit(),
            )?;
            bytes = bytes.saturating_add(package.metadata()?.len());
        }
        Ok(bytes)
    }

    fn free_bytes(&self) -> anyhow::Result<u64> {
        let capacity = match self.encoding {
            PackageEncoding::Json => MAX_STORED,
            PackageEncoding::DiskV2 => MAX_DISK_STORED,
        };
        Ok(capacity.saturating_sub(self.stored_bytes()?))
    }

    pub(super) fn get(&self, reference: &str) -> anyhow::Result<Option<Image>> {
        let manifest = match reference
            .strip_prefix(archive::LOCAL)
            .and_then(|r| r.strip_prefix('@'))
        {
            Some(manifest) => manifest,
            None => self.reference(reference)?.manifest,
        };
        let path = self.path(manifest)?;
        if !path.try_exists()? {
            return Ok(None);
        }
        let receipt = self.receipt(manifest)?;
        let metadata = request::Image::new(reference.to_owned(), receipt.clone())?;
        Ok(Some(Image {
            metadata,
            receipt,
            manifest: manifest.to_owned(),
        }))
    }

    pub(super) fn root(&self) -> &Path {
        &self.root
    }

    pub(super) fn archive_layer_limit(&self) -> u64 {
        match self.encoding {
            PackageEncoding::Json => LAYERS as u64,
            PackageEncoding::DiskV2 => archive::LIMIT as u64,
        }
    }

    pub(super) fn import(&self, archive: archive::Import<'_>) -> anyhow::Result<()> {
        self.publish_blobs(&archive.manifest, archive.blobs)
    }

    pub(super) fn seed_layout(
        &self,
        layout: &Path,
        reference: &str,
        config: &str,
    ) -> anyhow::Result<()> {
        private_scratch(layout)?;
        let (_, manifest) = reference
            .rsplit_once('@')
            .context("missing boot manifest digest")?;
        let image = oci_stage::read_manifest(layout, manifest)?;
        ensure!(
            image.config.digest == config,
            "boot OCI layout has a different config identity"
        );
        let mut blobs = BTreeMap::from([
            (
                manifest.to_owned(),
                archive::Blob::Inline(oci_stage::blob(layout, manifest, METADATA)?),
            ),
            (
                config.to_owned(),
                archive::Blob::Inline(oci_stage::blob(layout, config, METADATA)?),
            ),
        ]);
        let mut budget = match self.encoding {
            PackageEncoding::Json => LAYERS as u64,
            PackageEncoding::DiskV2 => oci_stage::DISK_COMPRESSED_BUDGET,
        };
        let mut layers = Vec::with_capacity(image.layers.len());
        for layer in image.layers {
            let size = layer.size as u64;
            budget = budget
                .checked_sub(size)
                .context("boot layout exceeds OCI layer budget")?;
            let path = layout.join("blobs/sha256").join(suffix(&layer.digest)?);
            let file = oci_stage::open_bounded(layout, &path, size)?;
            ensure!(
                file.metadata()?.len() == size,
                "boot layout layer size differs"
            );
            layers.push((layer.digest, file, size));
        }
        for (digest, file, size) in &layers {
            blobs.insert(
                digest.clone(),
                archive::Blob::Extent {
                    file,
                    bytes: 0..*size,
                },
            );
        }
        self.publish_blobs(manifest, blobs)
    }

    pub(super) fn seed_frozen_layout(&self, layout: &Path) -> anyhow::Result<()> {
        private_scratch(layout)?;
        let index: Value = serde_json::from_slice(&oci_stage::read_bounded(
            layout,
            &layout.join("index.json"),
            METADATA,
        )?)?;
        let Some([manifest]) = index["manifests"].as_array().map(Vec::as_slice) else {
            anyhow::bail!("offline source must contain exactly one frozen manifest");
        };
        let digest = manifest["digest"]
            .as_str()
            .context("missing offline manifest digest")?;
        suffix(digest)?;
        let matrix: Value = serde_json::from_str(public_registry::FIXTURES)?;
        let frozen = matrix["images"]
            .as_object()
            .context("missing frozen image inventory")?;
        let (reference, config) = frozen
            .values()
            .find_map(|image| {
                let reference = image["ref"].as_str()?;
                let (_, pinned) = reference.rsplit_once('@')?;
                (pinned == digest).then_some((reference, image["config_digest"].as_str()))
            })
            .context("offline OCI layout is not a frozen image")?;
        let manifest = oci_stage::read_manifest(layout, digest)?;
        self.seed_layout(layout, reference, config.unwrap_or(&manifest.config.digest))
    }

    fn publish_blobs(
        &self,
        manifest: &str,
        blobs: BTreeMap<String, archive::Blob<'_>>,
    ) -> anyhow::Result<()> {
        let target = self.path(manifest)?;
        if target.try_exists()? {
            self.receipt(manifest)?;
            return Ok(());
        }
        ensure!(
            self.root.join("images").read_dir()?.count() < MAX_IMAGES,
            "ExternalSSD OCI image capacity exceeded"
        );
        let mut free = self.free_bytes()?;
        let mut created = Vec::new();
        let result = (|| {
            for (digest, blob) in blobs {
                let expected = suffix(&digest)?;
                let path = self.root.join("blobs/sha256").join(expected);
                if path.try_exists()? {
                    let mut file = oci_stage::open_bounded(&self.root, &path, blob.len())?;
                    ensure!(
                        oci_stage::digest_file(&mut file, blob.len())? == expected,
                        "cached Docker archive blob digest differs"
                    );
                    continue;
                }
                free = free
                    .checked_sub(blob.len())
                    .context("ExternalSSD OCI image capacity exceeded")?;
                let mut pending =
                    tempfile::NamedTempFile::new_in(path.parent().expect("blob parent"))?;
                blob.copy_to(&mut pending)?;
                ensure!(
                    oci_stage::digest_file(pending.as_file_mut(), blob.len())? == expected,
                    "Docker archive blob changed before publication"
                );
                pending.as_file().sync_all()?;
                pending.persist_noclobber(&path)?;
                created.push(path);
            }
            ensure!(
                free >= self.encoding.byte_limit(),
                "ExternalSSD OCI package capacity exceeded"
            );
            oci_stage::publish_with_encoding(&self.root, manifest, &target, self.encoding)?;
            Ok(())
        })();
        if result.is_err() {
            for path in created {
                fs::remove_file(path).context("cannot roll back an archive blob")?;
            }
        }
        result
    }

    pub(super) fn prepare(&mut self, reference: &str) -> anyhow::Result<Image> {
        if let Some(image) = self.get(reference)? {
            return Ok(image);
        }
        let name = self.reference(reference)?;
        ensure!(
            self.root.join("images").read_dir()?.count() < MAX_IMAGES,
            "ExternalSSD OCI image capacity exceeded"
        );
        let disk = self.encoding == PackageEncoding::DiskV2;
        let mut download = Download {
            free: self.free_bytes()?,
            created: Vec::new(),
            deadline: Instant::now() + Duration::from_secs(if disk { 110 } else { 25 }),
            token: None,
        };
        let mut total_layer = if disk {
            oci_stage::DISK_COMPRESSED_BUDGET as usize
        } else {
            LAYERS
        };
        let results = (|| {
            self.receive(&name, "manifests", name.manifest, METADATA, &mut download)?;
            let manifest = oci_stage::read_manifest(&self.root, name.manifest)?;
            self.receive(
                &name,
                "blobs",
                &manifest.config.digest,
                manifest.config.size.min(METADATA),
                &mut download,
            )?;
            for layer in manifest.layers {
                ensure!(
                    layer.size <= total_layer,
                    "OCI layer descriptors exceed network budget"
                );
                self.receive(&name, "blobs", &layer.digest, layer.size, &mut download)?;
                total_layer -= layer.size;
            }
            ensure!(
                download.free >= self.encoding.byte_limit(),
                "ExternalSSD OCI package capacity exceeded"
            );
            oci_stage::publish_with_encoding(
                &self.root,
                name.manifest,
                &self.path(name.manifest)?,
                self.encoding,
            )?;
            self.get(reference)?
                .context("published OCI receipt is missing")
        })();
        if results.is_err() && !self.path(name.manifest)?.try_exists()? {
            for path in download.created {
                fs::remove_file(path).context("could not roll back a newly downloaded OCI blob")?;
            }
        }
        results
    }

    pub(super) fn validate_reference(&self, reference: &str) -> anyhow::Result<()> {
        self.reference(reference).map(|_| ())
    }

    fn receive(
        &self,
        name: &Reference,
        kind: &str,
        digest: &str,
        bound: usize,
        download: &mut Download,
    ) -> anyhow::Result<()> {
        let expected = suffix(digest)?;
        let file = self.root.join("blobs/sha256").join(expected);
        if file.try_exists()? {
            let mut stored = oci_stage::open_bounded(&self.root, &file, bound as u64)?;
            let size = stored.metadata()?.len();
            ensure!(
                oci_stage::digest_file(&mut stored, size)? == expected,
                "cached OCI blob digest mismatch"
            );
            return Ok(());
        }
        let bound = bound.min(download.free as usize);
        let mut pending = tempfile::NamedTempFile::new_in(file.parent().expect("blob parent"))?;
        let size = match name.origin {
            Origin::Loopback(address) => receive(
                address,
                &format!("/v2/{}/{kind}/{digest}", name.repository),
                bound,
                download.deadline,
                &mut pending,
            )?,
            Origin::Public => {
                if download.token.is_none() {
                    download.token = Some(public_registry::Token::acquire(
                        name.repository,
                        download.deadline,
                    )?);
                }
                download
                    .token
                    .as_ref()
                    .expect("scoped public token")
                    .download(
                        name.repository,
                        kind,
                        digest,
                        bound,
                        download.deadline,
                        &mut pending,
                    )?
            }
        };
        ensure!(
            oci_stage::digest_file(pending.as_file_mut(), size)? == expected,
            "registry blob digest mismatch"
        );
        pending.as_file().sync_all()?;
        pending.persist_noclobber(&file)?;
        download.free -= size;
        download.created.push(file);
        Ok(())
    }

    pub(super) fn ensure_guest(
        &mut self,
        peer: &mut client::Connection,
        image: &Image,
    ) -> anyhow::Result<()> {
        if self.installed(image)? {
            return Ok(());
        }
        let digest = &image.metadata.config_digest;
        let hash = image.receipt["package_sha256"]
            .as_str()
            .context("missing staged OCI package digest")?;
        let encoding = package_encoding(&image.receipt)?;
        ensure!(
            encoding != PackageEncoding::DiskV2 || self.encoding == PackageEncoding::DiskV2,
            "the cached image requires the native disk store"
        );
        let mut package = oci_stage::open_bounded(
            &self.root,
            &self.path(&image.manifest)?.join(package_name(encoding)),
            encoding.byte_limit(),
        )?;
        let size = package.metadata()?.len();
        ensure!(
            oci_stage::digest_file(&mut package, size)? == hash,
            "staged OCI package digest mismatch"
        );
        image::install_reader(peer, digest, hash, encoding, size, BufReader::new(package))?;
        self.installed.insert(digest.to_owned(), hash.to_owned());
        Ok(())
    }

    pub(super) fn installed(&self, image: &Image) -> anyhow::Result<bool> {
        let Some(hash) = self.installed.get(&image.metadata.config_digest) else {
            return Ok(false);
        };
        ensure!(
            image.receipt["package_sha256"] == *hash,
            "guest config has different staged content"
        );
        Ok(true)
    }

    pub(super) fn remove(
        &mut self,
        peer: &mut client::Connection,
        image: Image,
    ) -> anyhow::Result<()> {
        let removed = Self::references(&image.receipt)?;
        if self.installed.contains_key(&image.metadata.config_digest) {
            // Another manifest can share the same config and the installed root.
            let mut keep = false;
            for item in self.root.join("images").read_dir()? {
                let item = item?;
                let name = item
                    .file_name()
                    .into_string()
                    .map_err(|_| io::Error::other("invalid image store entry"))?;
                let digest = format!("sha256:{name}");
                if digest != image.manifest
                    && self.receipt(&digest)?["config_digest"] == image.metadata.config_digest
                {
                    keep = true;
                }
            }
            if !keep {
                image::image_request(
                    peer,
                    serde_json::json!({
                        "action":"remove", "config_digest":image.metadata.config_digest
                    }),
                    1000,
                )?;
                self.installed.remove(&image.metadata.config_digest);
            }
        }
        let retired = self
            .root
            .join("images")
            .join(format!(".deleted-{}", suffix(&image.manifest)?));
        fs::rename(self.path(&image.manifest)?, &retired)?;
        let used = self.inventory()?;
        for digest in removed.difference(&used) {
            fs::remove_file(self.root.join("blobs/sha256").join(suffix(digest)?))?;
        }
        fs::remove_dir_all(retired)?;
        Ok(())
    }
}

pub(super) fn remaining(deadline: Instant) -> anyhow::Result<Duration> {
    ensure!(
        !STOP.load(Ordering::Acquire),
        "native Docker owner is stopping"
    );
    let remaining = deadline.saturating_duration_since(Instant::now());
    ensure!(!remaining.is_zero(), "registry request deadline elapsed");
    Ok(remaining.min(IO_TIMEOUT))
}

fn receive(
    address: SocketAddr,
    path: &str,
    bound: usize,
    deadline: Instant,
    target: &mut impl Write,
) -> anyhow::Result<u64> {
    let mut socket = TcpStream::connect_timeout(&address, remaining(deadline)?)?;
    socket.set_write_timeout(Some(remaining(deadline)?))?;
    write!(socket, "GET {path} HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\nAccept: application/vnd.oci.image.manifest.v1+json, application/octet-stream\r\n\r\n")?;
    let mut reader = BufReader::new(socket);
    let mut headers = 0usize;
    let mut length = None;
    loop {
        reader
            .get_ref()
            .set_read_timeout(Some(remaining(deadline)?))?;
        let mut line = String::new();
        let read = (&mut reader)
            .take((MAX_HEADERS - headers) as u64)
            .read_line(&mut line)?;
        ensure!(
            read > 0 && line.ends_with("\r\n"),
            "invalid registry HTTP headers"
        );
        if headers == 0 {
            ensure!(
                line.starts_with("HTTP/1.1 200 ") || line.starts_with("HTTP/1.0 200 "),
                "registry request failed"
            );
        } else if line == "\r\n" {
            break;
        } else {
            let (key, value) = line
                .split_once(':')
                .context("invalid registry HTTP header")?;
            ensure!(
                !key.eq_ignore_ascii_case("transfer-encoding"),
                "registry must send a bounded fixed-length blob"
            );
            if key.eq_ignore_ascii_case("content-length") {
                ensure!(length.is_none(), "duplicate registry content length");
                length = Some(value.trim().parse::<usize>()?);
            }
        }
        headers += read;
    }
    let length = length
        .filter(|length| *length <= bound)
        .context("registry blob is missing its length or exceeds its bound")?;
    let mut written = 0;
    let mut buffer = [0; 8192];
    while written < length {
        reader
            .get_ref()
            .set_read_timeout(Some(remaining(deadline)?))?;
        let count = buffer.len().min(length - written);
        let read = reader.read(&mut buffer[..count])?;
        ensure!(read > 0, "registry blob transfer was interrupted");
        target.write_all(&buffer[..read])?;
        written += read;
    }
    Ok(written as u64)
}

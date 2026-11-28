use std::borrow::Cow;
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

use super::{archive, client, image, private_directory, public_registry, request, STOP};
use crate::native::oci_stage;

const MAX_STORED: u64 = 256 * 1024 * 1024;
const MAX_DISK_STORED: u64 = 16 * 1024 * 1024 * 1024;
const MAX_IMAGES: usize = 16;
const MAX_HEADERS: usize = 8192;
const IO_TIMEOUT: Duration = Duration::from_secs(4);
const METADATA: usize = oci_stage::METADATA_LIMIT;
const LAYERS: usize = oci_stage::LAYER_BUDGET;
const STORE_VERSION: &[u8] = b"conjet-native-image-store-1\n";

pub(super) struct Store {
    root: PathBuf,
    session_root: PathBuf,
    registry: Option<SocketAddr>,
    owned_registry: Option<SocketAddr>,
    public: public_registry::Pins,
    resolved_public: BTreeMap<String, String>,
    build_mirror: Option<super::build_mirror::Cache>,
    encoding: PackageEncoding,
    installed: BTreeMap<String, String>,
    _lock: File,
}

struct Reference<'a> {
    repository: Cow<'a, str>,
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
        session_root: &Path,
        registry: Option<SocketAddr>,
        allow_public: bool,
        status: &Value,
    ) -> anyhow::Result<Self> {
        private_directory(&root, session_root)?;
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
        let indexes = root.join("indexes");
        match fs::create_dir(&indexes) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        for directory in ["images", "blobs", "blobs/sha256", "indexes"] {
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
            session_root: session_root.to_owned(),
            registry,
            owned_registry: None,
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
            resolved_public: BTreeMap::new(),
            build_mirror: None,
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
        let hub = public_registry::hub_repository(name);
        if let Some(repository) = self.public.repository(name, manifest).or_else(|| {
            self.resolved_public
                .get(manifest)
                .filter(|repo| repo.as_str() == hub)
                .map(String::as_str)
        }) {
            return Ok(Reference {
                repository: repository.into(),
                manifest,
                origin: Origin::Public,
            });
        }
        if self.public.enabled() {
            if let Ok((repository, manifest)) = public_registry::pinned(reference) {
                return Ok(Reference {
                    repository,
                    manifest,
                    origin: Origin::Public,
                });
            }
        }
        let (authority, repository) = name
            .split_once('/')
            .context("native pull requires the allowlisted registry")?;
        let registry = [self.registry, self.owned_registry]
            .into_iter()
            .flatten()
            .find(|address| authority == address.to_string())
            .context("image is outside the frozen public pins and allowlisted registry")?;
        ensure!(
            repository.len() <= 200
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
            repository: repository.into(),
            manifest,
            origin: Origin::Loopback(registry),
        })
    }

    pub(super) fn use_owned_registry(&mut self, address: Option<SocketAddr>) {
        self.owned_registry = address;
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
        for entry in self.root.join("indexes").read_dir()? {
            let entry = entry?;
            ensure!(entry.file_type()?.is_file(), "invalid index proof type");
            let name = entry.file_name();
            let name = name.to_str().context("invalid index proof name")?;
            if name.starts_with(".tmp") {
                fs::remove_file(entry.path())?;
                continue;
            }
            let digest = format!("sha256:{name}");
            suffix(&digest)?;
            let bytes = oci_stage::read_bounded(&self.root, &entry.path(), METADATA)?;
            let child = public_registry::verified_manifest(&bytes, &digest)?;
            if !self.path(&child.digest)?.try_exists()? {
                fs::remove_file(entry.path())?;
            }
        }
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
        for entry in self.root.join("indexes").read_dir()? {
            let metadata = entry?.metadata()?;
            ensure!(
                metadata.is_file() && metadata.len() <= METADATA as u64,
                "invalid index proof cache entry"
            );
            bytes = bytes.saturating_add(metadata.len());
        }
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
        if self.public.enabled() {
            if let Ok((repository, pinned)) = public_registry::pinned(reference) {
                let proof = self.root.join("indexes").join(suffix(pinned)?);
                if proof.try_exists()? {
                    let bytes = oci_stage::read_bounded(&self.root, &proof, METADATA)?;
                    let resolved = public_registry::verified_manifest(&bytes, pinned)?;
                    let child = format!("docker.io/{repository}@{}", resolved.digest);
                    let mut image = self.get_manifest(&child, &resolved.digest)?;
                    if let Some(image) = &mut image {
                        image.metadata.reference = format!("docker.io/{repository}@{pinned}");
                    }
                    return Ok(image);
                }
            }
        }
        let manifest = match reference
            .strip_prefix(archive::LOCAL)
            .and_then(|r| r.strip_prefix('@'))
        {
            Some(manifest) => manifest,
            None => self.reference(reference)?.manifest,
        };
        self.get_manifest(reference, manifest)
    }

    fn get_manifest(&self, reference: &str, manifest: &str) -> anyhow::Result<Option<Image>> {
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

    pub(super) fn list(
        &self,
        registry_images: &BTreeMap<String, String>,
    ) -> anyhow::Result<Vec<Image>> {
        let mut images = Vec::new();
        for entry in self.root.join("images").read_dir()? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_str().context("invalid OCI store entry")?;
            if incomplete_entry(name) {
                continue;
            }
            let manifest = format!("sha256:{name}");
            suffix(&manifest)?;
            let reference = registry_images
                .keys()
                .find(|reference| {
                    reference
                        .rsplit_once('@')
                        .is_some_and(|(_, digest)| digest == manifest)
                })
                .cloned()
                .or_else(|| self.public.reference_for(&manifest))
                .or_else(|| {
                    self.resolved_public
                        .get(&manifest)
                        .map(|repo| format!("docker.io/{repo}@{manifest}"))
                })
                .unwrap_or_else(|| format!("{}@{manifest}", archive::LOCAL));
            let receipt = self.receipt(&manifest)?;
            images.push(Image {
                metadata: request::Image::new(reference, receipt.clone())?,
                receipt,
                manifest,
            });
        }
        Ok(images)
    }

    pub(super) fn root(&self) -> &Path {
        &self.root
    }

    pub(super) fn worker_registry_file(
        &mut self,
        repository: &str,
        digest: &str,
        manifest_request: bool,
    ) -> anyhow::Result<(File, &'static str, String, bool)> {
        ensure!(self.public.enabled(), "public build mirror is disabled");
        if self.build_mirror.is_none() {
            self.build_mirror = Some(super::build_mirror::Cache::new(
                self.root.join("build-mirror"),
            )?);
        }
        self.build_mirror
            .as_mut()
            .unwrap()
            .read(repository, digest, manifest_request)
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
        private_directory(layout, &self.session_root)?;
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
        private_directory(layout, &self.session_root)?;
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
                let mut verified = oci_stage::DigestWriter::new(&mut pending);
                blob.copy_to(&mut verified)?;
                ensure!(
                    verified.finish() == expected,
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
        let mut download = self.download()?;
        if matches!(name.origin, Origin::Public) {
            self.receive(&name, "manifests", name.manifest, METADATA, &mut download)?;
            let bytes = oci_stage::read_bounded(
                &self.root,
                &self.root.join("blobs/sha256").join(suffix(name.manifest)?),
                METADATA,
            )?;
            let resolved = public_registry::verified_manifest(&bytes, name.manifest)?;
            if resolved.digest != name.manifest {
                let index_path = self.root.join("indexes").join(suffix(name.manifest)?);
                ensure!(
                    index_path.try_exists()? || self.root.join("indexes").read_dir()?.count() < 64,
                    "native public index cache capacity exceeded"
                );
                let child_ref = format!("docker.io/{}@{}", name.repository, resolved.digest);
                let child = Reference {
                    repository: name.repository.clone(),
                    manifest: &resolved.digest,
                    origin: Origin::Public,
                };
                let mut image =
                    self.prepare_reference(&child_ref, &child, Some(resolved.size), download)?;
                if !index_path.try_exists()? {
                    let mut proof = tempfile::NamedTempFile::new_in(self.root.join("indexes"))?;
                    proof.write_all(&bytes)?;
                    proof.as_file().sync_all()?;
                    proof.persist_noclobber(&index_path)?;
                    File::open(self.root.join("indexes"))?.sync_all()?;
                }
                image.metadata.reference =
                    format!("docker.io/{}@{}", name.repository, name.manifest);
                let repository = name.repository.into_owned();
                self.resolved_public.insert(resolved.digest, repository);
                return Ok(image);
            }
        }
        self.prepare_reference(reference, &name, None, download)
    }

    pub(super) fn prepare_tagged(
        &mut self,
        repository: &str,
        tag: &str,
    ) -> anyhow::Result<(Image, bool)> {
        ensure!(
            self.public.manifest_for(repository).is_some()
                && matches!(repository, "library/alpine" | "moby/buildkit")
                && public_registry::valid_tag(tag),
            "tagged pulls are disabled for this repository"
        );
        let mut download = self.download()?;
        let token = public_registry::Token::acquire(repository, download.deadline)?;
        let resolved = token.resolve(repository, tag, download.deadline)?;
        if repository == "moby/buildkit" && tag == "buildx-stable-1" {
            ensure!(
                super::buildkit::approved_manifest(&resolved.digest),
                "Docker Hub's default BuildKit worker has an unqualified manifest {}",
                resolved.digest
            );
        }
        download.token = Some(token);
        let reference = format!("docker.io/{repository}@{}", resolved.digest);
        let name = Reference {
            repository: repository.into(),
            manifest: &resolved.digest,
            origin: Origin::Public,
        };
        let cached = self.path(name.manifest)?.try_exists()?;
        let image = self.prepare_reference(&reference, &name, Some(resolved.size), download)?;
        self.resolved_public
            .insert(resolved.digest, repository.to_owned());
        Ok((image, cached))
    }

    fn download(&self) -> anyhow::Result<Download> {
        let seconds = if self.encoding == PackageEncoding::DiskV2 {
            110
        } else {
            25
        };
        Ok(Download {
            free: self.free_bytes()?,
            created: Vec::new(),
            deadline: Instant::now() + Duration::from_secs(seconds),
            token: None,
        })
    }

    fn prepare_reference(
        &self,
        reference: &str,
        name: &Reference<'_>,
        manifest_size: Option<usize>,
        mut download: Download,
    ) -> anyhow::Result<Image> {
        if let Some(image) = self.get_manifest(reference, name.manifest)? {
            return Ok(image);
        }
        ensure!(
            self.root.join("images").read_dir()?.count() < MAX_IMAGES,
            "ExternalSSD OCI image capacity exceeded"
        );
        let disk = self.encoding == PackageEncoding::DiskV2;
        let mut total_layer = if disk {
            oci_stage::DISK_COMPRESSED_BUDGET as usize
        } else {
            LAYERS
        };
        let results = (|| {
            self.receive(
                name,
                "manifests",
                name.manifest,
                manifest_size.unwrap_or(METADATA),
                &mut download,
            )?;
            if let Some(size) = manifest_size {
                let path = self.root.join("blobs/sha256").join(suffix(name.manifest)?);
                ensure!(
                    fs::metadata(path)?.len() == size as u64,
                    "registry manifest size differs"
                );
            }
            let manifest = oci_stage::read_manifest(&self.root, name.manifest)?;
            self.receive(
                name,
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
                self.receive(name, "blobs", &layer.digest, layer.size, &mut download)?;
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
            self.get_manifest(reference, name.manifest)?
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
                        &name.repository,
                        download.deadline,
                    )?);
                }
                download
                    .token
                    .as_ref()
                    .expect("scoped public token")
                    .download(
                        &name.repository,
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

    pub(super) fn evict_idle_guest_roots(
        &mut self,
        peer: &mut client::Connection,
        active: &BTreeSet<&str>,
    ) -> anyhow::Result<()> {
        let idle: Vec<_> = self
            .installed
            .keys()
            .filter(|digest| !active.contains(digest.as_str()))
            .cloned()
            .collect();
        for digest in idle {
            self.remove_guest_root(peer, &digest)?;
        }
        Ok(())
    }

    fn remove_guest_root(
        &mut self,
        peer: &mut client::Connection,
        digest: &str,
    ) -> anyhow::Result<()> {
        image::image_request(
            peer,
            serde_json::json!({"action":"remove", "config_digest":digest}),
            1000,
        )?;
        self.installed.remove(digest);
        Ok(())
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
                self.remove_guest_root(peer, &image.metadata.config_digest)?;
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
        self.resolved_public.remove(&image.manifest);
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
    write!(socket, "GET {path} HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\nAccept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/octet-stream\r\n\r\n")?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn index_identity_survives_reopen_and_rejects_changed_proof() {
        use sha2::{Digest, Sha256};
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root = temp.path().canonicalize().unwrap();
        let open = || {
            Store::open(
                root.clone(),
                root.parent().unwrap(),
                None,
                true,
                &serde_json::json!({}),
            )
            .unwrap()
        };
        let store = open();
        let child = format!("sha256:{}", "b".repeat(64));
        let config = format!("sha256:{}", "c".repeat(64));
        let index = serde_json::to_vec(&serde_json::json!({"schemaVersion":2,
            "mediaType":"application/vnd.oci.image.index.v1+json", "manifests":[{
                "mediaType":"application/vnd.oci.image.manifest.v1+json", "digest":child,"size":512,
                "platform":{"os":"linux","architecture":"arm64"}}]}))
        .unwrap();
        let pinned = format!("sha256:{:x}", Sha256::digest(&index));
        let path = store.path(&child).unwrap();
        fs::create_dir(&path).unwrap();
        fs::write(
            path.join("receipt.json"),
            serde_json::to_vec(&serde_json::json!({
                "manifest_digest":child,"config_digest":config,"layers":[],"process":{}
            }))
            .unwrap(),
        )
        .unwrap();
        let proof = root.join("indexes").join(suffix(&pinned).unwrap());
        fs::write(&proof, &index).unwrap();
        let reference = format!("postgres:16-alpine@{pinned}");
        let check = |store: &Store| {
            let image = store.get(&reference).unwrap().unwrap();
            assert_eq!(image.manifest, child);
            assert_eq!(
                image.metadata.reference,
                format!("docker.io/library/postgres@{pinned}")
            );
        };
        check(&store);
        drop(store);
        let store = open();
        check(&store);
        fs::write(&proof, [index.as_slice(), b" "].concat()).unwrap();
        assert!(store
            .get(&reference)
            .err()
            .unwrap()
            .to_string()
            .contains("digest mismatch"));
    }

    #[test]
    fn registry_errors_roll_back_downloaded_objects() {
        use sha2::{Digest, Sha256};
        use std::net::TcpListener;
        use std::os::unix::fs::PermissionsExt;
        use std::thread;

        let untouched = |root: &Path| {
            assert_eq!(root.join("blobs/sha256").read_dir().unwrap().count(), 0);
            assert_eq!(root.join("images").read_dir().unwrap().count(), 0);
        };

        for (status, body, expected) in [
            ("200 OK", "wrong", "registry blob digest mismatch"),
            ("404 Not Found", "", "registry request failed"),
        ] {
            let root = tempfile::tempdir().unwrap();
            fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
            let root_path = root.path().canonicalize().unwrap();
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let config = format!("sha256:{:x}", Sha256::digest(b"right"));
            let layer = serde_json::json!({
                "mediaType":"application/vnd.oci.image.layer.v1.tar+gzip",
                "size":5,"digest":config
            });
            let manifest = serde_json::json!({
                "schemaVersion":2,
                "config":{"mediaType":"application/vnd.oci.image.config.v1+json","size":5,"digest":config},
                "layers":[layer]
            }).to_string();
            let digest = format!("sha256:{:x}", Sha256::digest(manifest.as_bytes()));
            let serve = thread::spawn(move || {
                for (status, body) in [("200 OK", manifest.as_str()), (status, body)] {
                    let (mut client, _) = listener.accept().unwrap();
                    let mut request = BufReader::new(&client);
                    loop {
                        let mut line = String::new();
                        request.read_line(&mut line).unwrap();
                        if line == "\r\n" {
                            break;
                        }
                        assert!(!line.is_empty());
                    }
                    write!(
                        client,
                        "HTTP/1.1 {status}\r\nContent-Length: {}\r\n\r\n{body}",
                        body.len()
                    )
                    .unwrap();
                }
            });
            let store = Store::open(
                root_path.clone(),
                root_path.parent().unwrap(),
                Some(address),
                false,
                &serde_json::json!({}),
            )
            .unwrap();
            let reference = format!("{address}/fixture@{digest}");
            let parsed = store.reference(&reference).unwrap();
            let result =
                store.prepare_reference(&reference, &parsed, None, store.download().unwrap());
            serve.join().unwrap();
            assert_eq!(result.err().unwrap().to_string(), expected);
            untouched(root.path());
        }
    }

    #[test]
    fn extent_mutation_keeps_the_blob_and_image_private() {
        let root = tempfile::tempdir().unwrap();
        let store = Store {
            root: root.path().to_owned(),
            session_root: root.path().to_owned(),
            registry: None,
            owned_registry: None,
            public: public_registry::Pins::default(),
            resolved_public: BTreeMap::new(),
            build_mirror: None,
            encoding: PackageEncoding::DiskV2,
            installed: BTreeMap::new(),
            _lock: tempfile::tempfile().unwrap(),
        };
        fs::create_dir(root.path().join("images")).unwrap();
        fs::create_dir(root.path().join("indexes")).unwrap();
        fs::create_dir_all(root.path().join("blobs/sha256")).unwrap();
        let mut source = tempfile::tempfile().unwrap();
        source.write_all(b"original").unwrap();
        let digest = format!("sha256:{}", oci_stage::digest_file(&mut source, 8).unwrap());
        source.write_all(b"modified").unwrap();
        let blobs = BTreeMap::from([(
            digest.clone(),
            archive::Blob::Extent {
                file: &source,
                bytes: 0..8,
            },
        )]);

        let error = store.publish_blobs(&digest, blobs).unwrap_err();

        assert_eq!(
            error.to_string(),
            "Docker archive blob changed before publication"
        );
        assert_eq!(
            root.path().join("blobs/sha256").read_dir().unwrap().count(),
            0
        );
        assert_eq!(root.path().join("images").read_dir().unwrap().count(), 0);
    }
}

//! Content-addressed Docker Hub reads for BuildKit, without importing images
//! into the container runtime. Only manifest-authorized blobs can be served.
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use serde_json::Value;

use super::{public_registry, request};
use crate::native::oci_stage;

const METADATA: usize = 1024 * 1024;
const BLOB: usize = 1024 * 1024 * 1024;
const CACHE_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const OBJECTS: usize = 8192;
const OCI_MANIFEST: &str = "application/vnd.oci.image.manifest.v1+json";
const DOCKER_MANIFEST: &str = "application/vnd.docker.distribution.manifest.v2+json";
const OCI_INDEX: &str = "application/vnd.oci.image.index.v1+json";
const DOCKER_INDEX: &str = "application/vnd.docker.distribution.manifest.list.v2+json";

pub(super) fn repository(name: &str) -> bool {
    if name.is_empty() || name.len() > 255 {
        return false;
    }
    name.split('/').all(|part| {
        let bytes = part.as_bytes();
        let mut offset = 0;
        loop {
            let start = offset;
            while offset < bytes.len()
                && (bytes[offset].is_ascii_lowercase() || bytes[offset].is_ascii_digit())
            {
                offset += 1;
            }
            if offset == start {
                return false;
            }
            if offset == bytes.len() {
                return true;
            }
            match bytes[offset] {
                b'.' => offset += 1,
                b'_' => {
                    offset += 1;
                    if bytes.get(offset) == Some(&b'_') {
                        offset += 1;
                    }
                }
                b'-' => {
                    while bytes.get(offset) == Some(&b'-') {
                        offset += 1;
                    }
                }
                _ => return false,
            }
        }
    })
}

#[derive(Clone, Copy)]
struct Descriptor {
    size: usize,
    manifest: bool,
}

pub(super) struct Cache {
    root: PathBuf,
    grants: BTreeMap<(String, String), Descriptor>,
}

impl Cache {
    pub(super) fn new(root: PathBuf) -> anyhow::Result<Self> {
        match std::fs::DirBuilder::new().mode(0o700).create(&root) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        super::private_directory(&root, root.parent().context("missing mirror parent")?)?;
        Ok(Self {
            root,
            grants: BTreeMap::new(),
        })
    }

    pub(super) fn read(
        &mut self,
        repo: &str,
        reference: &str,
        manifest: bool,
    ) -> anyhow::Result<(File, &'static str, String, bool)> {
        ensure!(repository(repo), "invalid Docker Hub repository");
        let digest = request::digest(reference);
        ensure!(
            digest || (manifest && public_registry::valid_tag(reference)),
            "invalid registry reference"
        );
        let descriptor = self
            .grants
            .get(&(repo.to_owned(), reference.to_owned()))
            .copied();
        let bound = if manifest {
            ensure!(
                descriptor.is_none_or(|d| d.manifest),
                "object is not a manifest"
            );
            METADATA
        } else {
            let d = descriptor.context("blob is not authorized by a verified manifest")?;
            ensure!(!d.manifest, "object is not a blob");
            d.size
        };
        let cached_path = digest.then(|| self.root.join(&reference[7..]));
        let cached = cached_path.as_ref().is_some_and(|p| p.is_file());
        let mut file = if cached {
            oci_stage::open_bounded(&self.root, cached_path.as_ref().unwrap(), bound as u64)?
        } else {
            ensure!(
                self.root.read_dir()?.count() < OBJECTS,
                "mirror object capacity exceeded"
            );
            let used = self.root.read_dir()?.try_fold(0u64, |total, entry| {
                total
                    .checked_add(entry?.metadata()?.len())
                    .context("mirror size overflow")
            })?;
            ensure!(
                used <= CACHE_BYTES.saturating_sub(bound as u64),
                "build mirror cache capacity exceeded"
            );
            let deadline = Instant::now() + Duration::from_secs(110);
            let token = public_registry::Token::acquire(repo, deadline)?;
            let mut pending = tempfile::NamedTempFile::new_in(&self.root)?;
            token.download(
                repo,
                if manifest { "manifests" } else { "blobs" },
                reference,
                bound,
                deadline,
                &mut pending,
            )?;
            let size = pending.as_file().metadata()?.len();
            ensure!(size > 0, "empty registry object");
            let actual = oci_stage::digest_file(pending.as_file_mut(), size)?;
            ensure!(
                !digest || actual == reference[7..],
                "registry object digest mismatch"
            );
            if let Some(d) = descriptor {
                ensure!(size == d.size as u64, "registry descriptor size mismatch");
            }
            // Validate metadata before publishing any file or granting blob access.
            if manifest {
                pending.as_file_mut().seek(SeekFrom::Start(0))?;
                let mut body = Vec::new();
                pending.as_file_mut().read_to_end(&mut body)?;
                metadata(&body)?;
            }
            pending.as_file().sync_all()?;
            let path = self.root.join(actual);
            match pending.persist_noclobber(&path) {
                Ok(file) => file,
                Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {
                    oci_stage::open_bounded(&self.root, &path, bound as u64)?
                }
                Err(error) => return Err(error.into()),
            }
        };
        let size = file.metadata()?.len();
        let actual = format!("sha256:{}", oci_stage::digest_file(&mut file, size)?);
        ensure!(
            !digest || actual == reference,
            "cached registry digest mismatch"
        );
        if let Some(d) = descriptor {
            ensure!(size == d.size as u64, "cached descriptor size mismatch");
        }
        let content_type = if manifest {
            file.seek(SeekFrom::Start(0))?;
            let mut body = Vec::new();
            file.read_to_end(&mut body)?;
            let (kind, descriptors) = metadata(&body)?;
            ensure!(
                self.grants.len().saturating_add(
                    descriptors
                        .iter()
                        .filter(|(hash, _)| !self
                            .grants
                            .contains_key(&(repo.to_owned(), hash.clone())))
                        .count()
                ) <= OBJECTS,
                "mirror descriptor capacity exceeded"
            );
            for (hash, descriptor) in descriptors {
                self.grants.insert((repo.to_owned(), hash), descriptor);
            }
            kind
        } else {
            "application/octet-stream"
        };
        file.seek(SeekFrom::Start(0))?;
        Ok((file, content_type, actual, cached))
    }
}

fn metadata(body: &[u8]) -> anyhow::Result<(&'static str, Vec<(String, Descriptor)>)> {
    let v: Value = serde_json::from_slice(body)?;
    ensure!(v["schemaVersion"] == 2, "unsupported manifest schema");
    let (kind, children, manifest) = match v["mediaType"].as_str() {
        Some(OCI_INDEX) => (
            OCI_INDEX,
            v["manifests"]
                .as_array()
                .context("missing index descriptors")?
                .clone(),
            true,
        ),
        Some(DOCKER_INDEX) => (
            DOCKER_INDEX,
            v["manifests"]
                .as_array()
                .context("missing list descriptors")?
                .clone(),
            true,
        ),
        Some(OCI_MANIFEST | DOCKER_MANIFEST) => {
            let mut children = v["layers"].as_array().context("missing layers")?.clone();
            children.push(v["config"].clone());
            (
                if v["mediaType"] == OCI_MANIFEST {
                    OCI_MANIFEST
                } else {
                    DOCKER_MANIFEST
                },
                children,
                false,
            )
        }
        _ => anyhow::bail!("unsupported manifest media type"),
    };
    ensure!(
        !children.is_empty() && children.len() <= 1024,
        "invalid descriptor count"
    );
    let mut result = Vec::new();
    for entry in children {
        let hash = entry["digest"]
            .as_str()
            .filter(|s| request::digest(s))
            .context("invalid descriptor digest")?;
        let size = entry["size"]
            .as_u64()
            .filter(|s| *s > 0 && *s <= if manifest { METADATA } else { BLOB } as u64)
            .context("invalid descriptor size")? as usize;
        result.push((hash.to_owned(), Descriptor { size, manifest }));
    }
    Ok((kind, result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    #[test]
    fn cached_blobs_require_a_manifest_grant_and_matching_content() {
        let root = tempfile::tempdir().unwrap();
        let mut cache = Cache::new(root.path().join("mirror")).unwrap();
        let blob = b"verified blob";
        let blob_hash = format!("sha256:{:x}", Sha256::digest(blob));
        std::fs::write(cache.root.join(&blob_hash[7..]), blob).unwrap();
        assert!(cache.read("library/test", &blob_hash, false).is_err());
        let manifest = serde_json::to_vec(&serde_json::json!({
            "schemaVersion":2,"mediaType":OCI_MANIFEST,
            "config":{"digest":blob_hash,"size":blob.len()},"layers":[]
        }))
        .unwrap();
        let hash = format!("sha256:{:x}", Sha256::digest(&manifest));
        std::fs::write(cache.root.join(&hash[7..]), &manifest).unwrap();
        let (_, kind, identity, cached) = cache.read("library/test", &hash, true).unwrap();
        assert_eq!(kind, OCI_MANIFEST);
        assert_eq!(identity, hash);
        assert!(cached);
        assert!(cache.read("library/other", &blob_hash, false).is_err());
        assert!(cache.read("library/test", &blob_hash, false).is_ok());
        std::fs::write(cache.root.join(&blob_hash[7..]), b"corrupt blob!").unwrap();
        assert!(cache.read("library/test", &blob_hash, false).is_err());
    }

    #[test]
    fn repositories_cannot_change_the_registry_origin_or_query() {
        for name in ["docker/dockerfile", "library/node", "org/nested/image"] {
            assert!(repository(name));
        }
        for name in [
            "",
            "../alpine",
            "library//node",
            "https://evil/x",
            "org/x?scope=y",
            "org/x%2fy",
            "UPPER/x",
            "a..b/c",
            "a___b/c",
            "a.-b/c",
        ] {
            assert!(!repository(name));
        }
    }
    #[test]
    fn descriptors_bound_blob_downloads_and_preserve_index_identity() {
        let hash = format!("sha256:{:x}", Sha256::digest(b"blob"));
        let mut value = serde_json::json!({"schemaVersion":2,"mediaType":OCI_INDEX,
            "manifests":[{"digest":hash,"size":100}]});
        let (kind, d) = metadata(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert_eq!(kind, OCI_INDEX);
        assert!(d[0].1.manifest);
        assert_eq!(d[0].1.size, 100);
        value["manifests"][0]["size"] = (METADATA + 1).into();
        assert!(metadata(&serde_json::to_vec(&value).unwrap()).is_err());
    }
}

use std::collections::BTreeMap;
use std::io::{self, BufReader, Read, Seek};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use base64::Engine;
use clap::Args;
use conjet_launch_service::handshake::{hex, random, unhex};
use conjet_launch_service::oci::{packed, PackageEncoding, Root};
use conjet_launch_service::wire::Kind;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::{admission_lock, client, private_scratch, Rejected, CHUNK, SCRATCH};

const MAX_TAGS: usize = 64;

#[derive(Clone, Default)]
pub(super) struct Tags(BTreeMap<String, String>);

impl Tags {
    pub(super) fn insert(
        &mut self,
        repository: &str,
        tag: &str,
        target: String,
    ) -> Result<(), Rejected> {
        let tag = if tag.is_empty() { "latest" } else { tag };
        let repository = Self::familiar(repository);
        let valid_repository = !repository.is_empty()
            && repository.len() <= 200
            && repository != "sha256"
            && repository.split('/').all(|part| {
                part.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit())
                    && part.bytes().all(|b| {
                        b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b)
                    })
            });
        let valid_tag = tag.len() <= 128
            && tag.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_')
            && tag
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b));
        if !valid_repository || !valid_tag {
            return Err(Rejected::bad("invalid local Docker image tag"));
        }
        let name = format!("{repository}:{tag}");
        if self.0.len() >= MAX_TAGS && !self.0.contains_key(&name) {
            return Err(Rejected(409, "native image tag capacity exceeded".into()));
        }
        self.0.insert(name, target);
        Ok(())
    }

    fn familiar(reference: &str) -> &str {
        reference
            .strip_prefix("docker.io/")
            .or_else(|| reference.strip_prefix("index.docker.io/"))
            .map_or(reference, |name| {
                name.strip_prefix("library/").unwrap_or(name)
            })
    }

    pub(super) fn key(reference: &str) -> std::borrow::Cow<'_, str> {
        if reference.contains('@') {
            return reference.into();
        }
        let reference = Self::familiar(reference);
        let last = reference.rsplit('/').next().expect("reference component");
        if last.contains(':') {
            reference.into()
        } else {
            format!("{reference}:latest").into()
        }
    }

    pub(super) fn resolve<'a>(&'a self, reference: &'a str) -> &'a str {
        if self.0.is_empty() {
            return reference;
        }
        self.0
            .get(Self::key(reference).as_ref())
            .map_or(reference, String::as_str)
    }

    pub(super) fn names_for<'a>(&'a self, reference: &'a str) -> impl Iterator<Item = &'a str> {
        self.0
            .iter()
            .filter_map(move |(name, target)| (target == reference).then_some(name.as_str()))
    }

    pub(super) fn remove(&mut self, reference: &str) -> Option<String> {
        let key = Self::key(reference);
        self.0.remove(key.as_ref()).map(|_| key.into_owned())
    }

    pub(super) fn references_manifest(&self, reference: &str) -> bool {
        let digest = reference.rsplit_once('@').map(|(_, digest)| digest);
        self.0.values().any(|target| {
            target
                .rsplit_once('@')
                .is_some_and(|(_, target)| Some(target) == digest)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_resolve_retarget_and_remove_without_network_access() {
        let mut tags = Tags::default();
        let first = "localhost/one@sha256:1";
        let second = "localhost/two@sha256:2";
        assert_eq!(tags.resolve("local"), "local");
        tags.insert("docker.io/library/local", "", first.into())
            .unwrap();
        assert_eq!(tags.resolve("local"), first);
        assert_eq!(tags.resolve("docker.io/library/local:latest"), first);
        assert!(tags.references_manifest("localhost/other@sha256:1"));
        tags.insert("local", "latest", second.into()).unwrap();
        assert_eq!(tags.resolve("local:latest"), second);
        assert!(!tags.references_manifest(first));
        assert_eq!(tags.names_for(second).collect::<Vec<_>>(), ["local:latest"]);
        assert_eq!(tags.remove("local").as_deref(), Some("local:latest"));
        assert_eq!(tags.resolve("local"), "local");
    }

    #[test]
    fn tag_namespace_is_bounded_and_cannot_shadow_digests() {
        let mut tags = Tags::default();
        for repository in ["", "a//b", "../a", "CAPS", "sha256", "repo@sha256:abc"] {
            assert!(tags.insert(repository, "latest", "target".into()).is_err());
        }
        assert!(tags.insert("local", ".bad", "target".into()).is_err());
        for index in 0..MAX_TAGS {
            tags.insert("local", &format!("tag{index}"), "target".into())
                .unwrap();
        }
        assert!(tags.insert("another", "latest", "target".into()).is_err());
        assert!(tags.insert("local", "tag0", "replacement".into()).is_ok());
    }
}

#[derive(Debug, Args)]
pub(in crate::native) struct InstallOptions {
    #[arg(long)]
    session: PathBuf,
    #[arg(long)]
    package: PathBuf,
    #[arg(long)]
    sha256: String,
    /// Install a streamed v2 package on a guest with the disk image profile.
    #[arg(long)]
    disk_package: bool,
}

pub(in crate::native) fn install(options: InstallOptions) -> anyhow::Result<()> {
    private_scratch(&options.session)?;
    let path = options.package.canonicalize()?;
    ensure!(
        path == options.package && path.starts_with(SCRATCH),
        "expected ExternalSSD OCI package"
    );
    let encoding = if options.disk_package {
        PackageEncoding::DiskV2
    } else {
        PackageEncoding::Json
    };
    let file = std::fs::File::open(path)?;
    let metadata = file.metadata()?;
    let size = metadata.len();
    ensure!(
        metadata.is_file() && size > 0 && size <= encoding.byte_limit(),
        "invalid OCI package file"
    );
    let mut file = BufReader::new(file);
    let digest = unhex::<32>(&options.sha256)?;
    let mut hash = Sha256::new();
    ensure!(
        io::copy(&mut (&mut file).take(size + 1), &mut hash)? == size
            && hash.finalize()[..] == digest,
        "OCI package SHA-256 mismatch"
    );
    file.rewind()?;
    let image = match encoding {
        PackageEncoding::DiskV2 => packed::Index::read(&mut file, size)?.root.config_digest,
        PackageEncoding::Json => {
            let mut package = Vec::new();
            (&mut file).take(size + 1).read_to_end(&mut package)?;
            Root::read(&package)?.config_digest
        }
    };
    file.rewind()?;
    let _lock = admission_lock(&options.session)?;
    let (identity, key) = client::load(&options.session)?;
    let mut peer = client::Connection::open(&options.session, &identity, &key)?;
    ensure!(peer.oci, "native guest lacks OCI capability");
    let state = peer.inspect()?;
    ensure!(
        (state["workload"].is_null() || state["workload"]["cleanup"] == "complete")
            && state["active_workloads"]
                .as_array()
                .map_or(true, Vec::is_empty),
        "native image installation requires an idle Docker guest"
    );
    let response = install_reader(&mut peer, &image, &options.sha256, encoding, size, file)?;
    println!(
        "{}",
        json!({"boot_id":peer.boot,"image":response,"package_sha256":options.sha256})
    );
    Ok(())
}

pub(super) fn image_request(
    peer: &mut client::Connection,
    operation: Value,
    budget_ms: u64,
) -> anyhow::Result<Value> {
    Ok(peer.exchange(
        Kind::Image,
        Kind::Image,
        &json!({"boot_id":peer.boot, "budget_ms":budget_ms, "operation":operation}),
        Duration::from_millis(budget_ms + 1000),
    )?)
}

pub(super) fn install_reader(
    peer: &mut client::Connection,
    image: &str,
    sha256: &str,
    encoding: PackageEncoding,
    size: u64,
    mut package: impl Read,
) -> anyhow::Result<Value> {
    let timeout = match encoding {
        PackageEncoding::Json => 45,
        PackageEncoding::DiskV2 => 180,
    };
    let deadline = Instant::now() + Duration::from_secs(timeout);
    let transfer = hex(&random::<16>()?);
    let mut operation = json!({
        "action":"begin", "transfer":transfer, "config_digest":image,
        "package_digest":format!("sha256:{sha256}"), "size":size
    });
    if encoding == PackageEncoding::DiskV2 {
        operation["encoding"] = json!(encoding);
    }
    let begin = image_request(peer, operation, 1000)?;
    ensure!(
        begin["offset"] == 0,
        "unexpected initial OCI transfer offset"
    );
    let mut offset = 0u64;
    let mut buffer = [0; CHUNK];
    while offset < size {
        ensure!(
            Instant::now() < deadline && !super::STOP.load(std::sync::atomic::Ordering::Acquire),
            "OCI transfer deadline elapsed or the owner stopped"
        );
        let chunk = &mut buffer[..(size - offset).min(CHUNK as u64) as usize];
        package.read_exact(chunk)?;
        let reply = image_request(
            peer,
            json!({
                "action":"write", "transfer":transfer, "offset":offset,
                "data":base64::engine::general_purpose::STANDARD.encode(&*chunk)
            }),
            1000,
        )?;
        offset += chunk.len() as u64;
        ensure!(
            reply["offset"].as_u64() == Some(offset),
            "unexpected OCI transfer acknowledgement"
        );
    }
    // A lost commit reply may have published the image. Drop the
    // connection and use Inspect to reconcile before attempting again.
    let budget = deadline
        .saturating_duration_since(Instant::now())
        .as_millis()
        .min(if encoding == PackageEncoding::DiskV2 {
            30_000
        } else {
            10_000
        }) as u64;
    ensure!(budget > 0, "OCI transfer deadline elapsed");
    let reply = image_request(peer, json!({"action":"commit","transfer":transfer}), budget)
        .context("OCI commit outcome requires inspection if the connection was lost")?;
    ensure!(
        reply["state"] == "installed" && reply["config_digest"] == image,
        "invalid OCI installation acknowledgement"
    );
    Ok(reply)
}

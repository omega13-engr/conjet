use std::collections::BTreeMap;
use std::io::Read;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use base64::Engine;
use clap::Args;
use conjet_launch_service::handshake::{hex, random, unhex};
use conjet_launch_service::oci::{Root, PACKAGE_LIMIT};
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
}

pub(in crate::native) fn install(options: InstallOptions) -> anyhow::Result<()> {
    private_scratch(&options.session)?;
    let path = options.package.canonicalize()?;
    ensure!(
        path == options.package && path.starts_with(SCRATCH),
        "expected ExternalSSD OCI package"
    );
    let file = std::fs::File::open(path)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.len() <= PACKAGE_LIMIT,
        "invalid OCI package file"
    );
    let mut package = Vec::new();
    file.take(PACKAGE_LIMIT + 1).read_to_end(&mut package)?;
    let digest = unhex::<32>(&options.sha256)?;
    ensure!(
        Sha256::digest(&package)[..] == digest,
        "OCI package SHA-256 mismatch"
    );
    let image = Root::read(&package)?.config_digest;
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
    let response = install_with_peer(&mut peer, &image, &options.sha256, &package)?;
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

pub(super) fn install_with_peer(
    peer: &mut client::Connection,
    image: &str,
    sha256: &str,
    package: &[u8],
) -> anyhow::Result<Value> {
    let deadline = Instant::now() + Duration::from_secs(45);
    let transfer = hex(&random::<16>()?);
    let begin = image_request(
        peer,
        json!({
            "action":"begin", "transfer":transfer, "config_digest":image,
            "package_digest":format!("sha256:{sha256}"), "size":package.len()
        }),
        1000,
    )?;
    ensure!(
        begin["offset"] == 0,
        "unexpected initial OCI transfer offset"
    );
    let mut offset = 0;
    for chunk in package.chunks(CHUNK) {
        ensure!(
            Instant::now() < deadline && !super::STOP.load(std::sync::atomic::Ordering::Acquire),
            "OCI transfer deadline elapsed or the owner stopped"
        );
        let reply = image_request(
            peer,
            json!({
                "action":"write", "transfer":transfer, "offset":offset,
                "data":base64::engine::general_purpose::STANDARD.encode(chunk)
            }),
            1000,
        )?;
        offset += chunk.len();
        ensure!(
            reply["offset"].as_u64() == Some(offset as u64),
            "unexpected OCI transfer acknowledgement"
        );
    }
    // A lost commit reply may have published the image. Drop the
    // connection and use Inspect to reconcile before attempting again.
    let budget = deadline
        .saturating_duration_since(Instant::now())
        .as_millis()
        .min(10000) as u64;
    ensure!(budget > 0, "OCI transfer deadline elapsed");
    let reply = image_request(peer, json!({"action":"commit","transfer":transfer}), budget)
        .context("OCI commit outcome requires inspection if the connection was lost")?;
    ensure!(
        reply["state"] == "installed" && reply["config_digest"] == image,
        "invalid OCI installation acknowledgement"
    );
    Ok(reply)
}

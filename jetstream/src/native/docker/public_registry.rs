//! Bounded anonymous pulls from the explicitly enabled Docker Hub source.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub(super) const FIXTURES: &str =
    include_str!("../../../../benchmarks/scenarios/docker-comparison-v1.json");

#[derive(Default)]
pub(super) struct Pins(BTreeMap<String, String>);

impl Pins {
    pub(super) fn frozen() -> anyhow::Result<Self> {
        let fixture: Value = serde_json::from_str(FIXTURES)?;
        let entries = fixture["images"]
            .as_object()
            .context("missing frozen image pins")?;
        let mut pins = BTreeMap::new();
        for image in entries.values() {
            let (repository, digest) = image["ref"]
                .as_str()
                .and_then(|name| name.strip_prefix("docker.io/"))
                .and_then(|name| name.split_once('@'))
                .context("invalid frozen Docker Hub pin")?;
            ensure!(
                repository.split('/').count() == 2
                    && repository.bytes().all(|b| b.is_ascii_lowercase()
                        || b.is_ascii_digit()
                        || b"._-/".contains(&b))
                    && super::request::digest(digest),
                "invalid frozen public registry pin"
            );
            ensure!(
                pins.insert(repository.to_owned(), digest.to_owned())
                    .is_none(),
                "duplicate frozen registry repository"
            );
        }
        Ok(Self(pins))
    }

    pub(super) fn repository(&self, name: &str, digest: &str) -> Option<&str> {
        let repository = hub_repository(name);
        self.0
            .get_key_value(repository.as_ref())
            .filter(|(_, pinned)| *pinned == digest)
            .map(|(canonical, _)| canonical.as_str())
    }

    pub(super) fn reference_for(&self, manifest: &str) -> Option<String> {
        self.0
            .iter()
            .find(|(_, digest)| digest.as_str() == manifest)
            .map(|(name, _)| format!("docker.io/{name}@{manifest}"))
    }

    pub(super) fn manifest_for(&self, repository: &str) -> Option<&str> {
        self.0.get(repository).map(String::as_str)
    }
}

pub(super) fn hub_repository(name: &str) -> Cow<'_, str> {
    let name = name
        .strip_prefix("docker.io/")
        .or_else(|| name.strip_prefix("index.docker.io/"))
        .unwrap_or(name);
    if name.contains('/') {
        Cow::Borrowed(name)
    } else {
        Cow::Owned(format!("library/{name}"))
    }
}

pub(super) fn valid_tag(tag: &str) -> bool {
    !tag.is_empty()
        && tag.len() <= 128
        && tag.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_')
        && tag
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
}

pub(super) fn tagged(reference: &str) -> anyhow::Result<(Cow<'_, str>, &str)> {
    // Validate before passing a component into the Docker Hub URL or token scope.
    let (name, tag) = reference.rsplit_once(':').unwrap_or((reference, "latest"));
    let repository = hub_repository(name);
    ensure!(
        matches!(repository.as_ref(), "library/alpine" | "moby/buildkit"),
        "Tagged pulls are limited to Alpine and BuildKit on Docker Hub. Other sources require an immutable SHA-256 digest."
    );
    ensure!(valid_tag(tag), "invalid Docker Hub tag");
    Ok((repository, tag))
}

const IMAGE_MANIFEST: &str = "application/vnd.oci.image.manifest.v1+json";
const DOCKER_MANIFEST: &str = "application/vnd.docker.distribution.manifest.v2+json";
const IMAGE_INDEX: &str = "application/vnd.oci.image.index.v1+json";
const DOCKER_LIST: &str = "application/vnd.docker.distribution.manifest.list.v2+json";

#[derive(Debug)]
pub(super) struct ResolvedManifest {
    pub(super) digest: String,
    pub(super) size: usize,
}

fn resolve_manifest(body: &[u8]) -> anyhow::Result<ResolvedManifest> {
    let document: Value = serde_json::from_slice(body)?;
    ensure!(
        document["schemaVersion"] == 2,
        "unsupported registry schema version"
    );
    match document["mediaType"].as_str() {
        Some(IMAGE_MANIFEST | DOCKER_MANIFEST) => Ok(ResolvedManifest {
            digest: format!("sha256:{:x}", Sha256::digest(body)),
            size: body.len(),
        }),
        Some(IMAGE_INDEX | DOCKER_LIST) => {
            let entry = document["manifests"]
                .as_array()
                .context("registry index lacks manifest descriptors")?
                .iter()
                .find(|entry| {
                    let platform = &entry["platform"];
                    platform["os"] == "linux"
                        && platform["architecture"] == "arm64"
                        && (platform["variant"].is_null() || platform["variant"] == "v8")
                })
                .context("registry index lacks a Linux ARM64 manifest")?;
            ensure!(
                matches!(
                    entry["mediaType"].as_str(),
                    Some(IMAGE_MANIFEST | DOCKER_MANIFEST)
                ),
                "selected registry object is not an image manifest"
            );
            let digest = entry["digest"]
                .as_str()
                .filter(|digest| super::request::digest(digest))
                .context("invalid registry manifest digest")?;
            let size = entry["size"]
                .as_u64()
                .filter(|size| (1..=super::super::oci_stage::METADATA_LIMIT as u64).contains(size))
                .context("invalid registry manifest size")?;
            Ok(ResolvedManifest {
                digest: digest.to_owned(),
                size: size as usize,
            })
        }
        _ => anyhow::bail!("unsupported registry manifest media type"),
    }
}

pub(super) struct Token(String);

impl Token {
    pub(super) fn acquire(repository: &str, deadline: Instant) -> anyhow::Result<Self> {
        let url = format!(
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repository}:pull"
        );
        let mut body = Vec::new();
        get(&url, None, 65_536, deadline, &mut body).context("request Docker Hub pull token")?;
        let entry: Value = serde_json::from_slice(&body)?;
        let token = entry["token"]
            .as_str()
            .context("public registry response lacks a token")?;
        ensure!(
            !token.is_empty()
                && token.len() <= 8192
                && token
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)),
            "invalid public registry token"
        );
        Ok(Self(token.into()))
    }

    pub(super) fn resolve(
        &self,
        repository: &str,
        tag: &str,
        deadline: Instant,
    ) -> anyhow::Result<ResolvedManifest> {
        let mut body = Vec::new();
        self.download(
            repository,
            "manifests",
            tag,
            super::super::oci_stage::METADATA_LIMIT,
            deadline,
            &mut body,
        )
        .with_context(|| format!("could not resolve Docker Hub tag {repository}:{tag}"))?;
        resolve_manifest(&body)
    }

    pub(super) fn download(
        &self,
        repository: &str,
        kind: &str,
        digest: &str,
        bound: usize,
        deadline: Instant,
        target: &mut impl Write,
    ) -> anyhow::Result<u64> {
        get(
            &format!("https://registry-1.docker.io/v2/{repository}/{kind}/{digest}"),
            Some(&self.0),
            bound,
            deadline,
            target,
        )
        .with_context(|| format!("fetch Docker Hub {repository}/{kind}/{digest}"))
    }
}

fn get(
    url: &str,
    token: Option<&str>,
    bound: usize,
    deadline: Instant,
    target: &mut impl Write,
) -> anyhow::Result<u64> {
    ensure!(
        bound != 0,
        "public registry response has no remaining byte budget"
    );
    for retry in 0..=2 {
        let (bytes, status) = attempt(url, token, bound, deadline, target)?;
        if status.success() {
            return Ok(bytes);
        }
        if retry == 2 || bytes != 0 || status.code() != Some(28) {
            anyhow::bail!("public Docker Hub request failed ({status})");
        }
        // Retry a GET timeout only when
        // the previous attempt could not have written any response bytes.
        let pause = Duration::from_millis(150 * (retry + 1));
        std::thread::sleep(super::registry::remaining(deadline)?.min(pause));
    }
    unreachable!("bounded public registry retry must return")
}

fn attempt(
    url: &str,
    token: Option<&str>,
    bound: usize,
    deadline: Instant,
    target: &mut impl Write,
) -> anyhow::Result<(u64, ExitStatus)> {
    super::registry::remaining(deadline)?;
    // A Docker Hub edge or its blob CDN can take more than the loopback I/O
    // timeout to respond. Keep both the attempt and the entire pull bounded.
    let attempt_limit = if bound > super::super::oci_stage::LAYER_BUDGET {
        Duration::from_secs(90)
    } else {
        Duration::from_secs(20)
    };
    let time = deadline
        .saturating_duration_since(Instant::now())
        .min(attempt_limit)
        .as_secs_f64();
    let mut command = Command::new("/usr/bin/curl");
    command.env_clear().args([
        "--disable", "--fail", "--silent", "--location", "--max-redirs", "4",
        "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "5",
        "--max-time", &format!("{:.3}", time.max(0.001)), "--max-filesize", &bound.to_string(),
        "--header", "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json",
    ]);
    if token.is_some() {
        // curl drops Authorization when a blob redirect changes origin.
        command.args(["--header", "@-"]).stdin(Stdio::piped());
    } else {
        command.stdin(Stdio::null());
    }
    let mut child = command
        .arg(url)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let result = (|| {
        if let Some(token) = token {
            writeln!(
                child.stdin.take().expect("piped registry header"),
                "Authorization: Bearer {token}"
            )?;
        }
        let mut body = child
            .stdout
            .take()
            .expect("piped registry body")
            .take(bound as u64 + 1);
        let bytes = io::copy(&mut body, target)?;
        ensure!(
            bytes <= bound as u64,
            "public registry response exceeds its byte bound"
        );
        Ok((bytes, child.wait()?))
    })();
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docker_hub_tag_forms_and_unsafe_components() {
        for name in [
            "alpine:3.21",
            "library/alpine:3.21",
            "docker.io/alpine:3.21",
            "index.docker.io/library/alpine:3.21",
        ] {
            let (repository, tag) = tagged(name).unwrap();
            assert_eq!((repository.as_ref(), tag), ("library/alpine", "3.21"));
        }
        assert_eq!(tagged("alpine").unwrap().1, "latest");
        for rejected in [
            "alpine:",
            "alpine:.tag",
            "alpine:tag?x",
            "alpine:tag/path",
            "alpine@sha256:dead",
            "http://docker.io/alpine:3.21",
            "localhost/alpine:3.21",
            "example.com/moby/buildkit:latest",
            "docker.io/library//alpine:3.21",
            "docker.io/library/golang:latest",
        ] {
            assert!(tagged(rejected).is_err(), "{rejected}");
        }
    }

    #[test]
    fn selects_the_verified_arm64_descriptor_and_rejects_other_platforms() {
        let arm_digest = format!("sha256:{}", "ab".repeat(32));
        let index = serde_json::json!({
            "schemaVersion":2, "mediaType": IMAGE_INDEX,
            "manifests": [
                {"platform":{"os":"linux","architecture":"amd64"}},
                {"platform":{"os":"linux","architecture":"arm64","variant":"v9"}},
                {"platform":{"os":"linux","architecture":"arm64","variant":"v8"},
                 "digest":arm_digest, "size":42, "mediaType":IMAGE_MANIFEST}
            ]
        });
        let resolve = |index: &Value| resolve_manifest(&serde_json::to_vec(index).unwrap());
        let descriptor = resolve(&index).unwrap();
        assert_eq!(descriptor.digest, arm_digest);
        assert_eq!(descriptor.size, 42);

        let mut unsupported = index.clone();
        unsupported["manifests"].as_array_mut().unwrap().pop();
        assert!(resolve(&unsupported).is_err());
        for (field, bad) in [
            ("size", serde_json::json!(65537)),
            ("digest", serde_json::json!("sha256:bad")),
            ("mediaType", serde_json::json!(IMAGE_INDEX)),
        ] {
            let mut bad_index = index.clone();
            bad_index["manifests"][2][field] = bad;
            assert!(resolve(&bad_index).is_err());
        }
    }

    #[test]
    fn a_single_manifest_is_content_addressed() {
        let body = br#"{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}"#;
        let resolved = resolve_manifest(body).unwrap();
        assert_eq!(
            resolved.digest,
            format!("sha256:{:x}", Sha256::digest(body))
        );
        assert_eq!(resolved.size, body.len());
    }

    #[test]
    fn public_registry_accepts_only_exact_frozen_repository_and_digest() {
        let pins = Pins::frozen().unwrap();
        let (first, digest) = pins.0.first_key_value().unwrap();
        let full = format!("docker.io/{first}");
        assert_eq!(pins.repository(&full, digest), Some(first.as_str()));
        assert!(pins
            .repository(&format!("localhost/{first}"), digest)
            .is_none());
        assert!(pins.repository(&full, "latest").is_none());
        assert!(Pins::default().repository(&full, digest).is_none());
    }
}

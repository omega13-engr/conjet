//! The isolated candidate's explicitly enabled, frozen Docker Hub source.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use serde_json::Value;

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
        let name = name
            .strip_prefix("docker.io/")
            .or_else(|| name.strip_prefix("index.docker.io/"))
            .unwrap_or(name);
        let repository = if name.contains('/') {
            Cow::Borrowed(name)
        } else {
            Cow::Owned(format!("library/{name}"))
        };
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

pub(super) struct Token(String);

impl Token {
    pub(super) fn acquire(repository: &str, deadline: Instant) -> anyhow::Result<Self> {
        let url = format!(
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repository}:pull"
        );
        let mut body = Vec::new();
        get(&url, None, 65_536, deadline, &mut body)?;
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
        // The request is a digest-pinned GET. Retry a timeout only when
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
    let remaining = super::registry::remaining(deadline)?;
    let time = if bound > super::super::oci_stage::LAYER_BUDGET {
        deadline
            .saturating_duration_since(Instant::now())
            .min(std::time::Duration::from_secs(90))
    } else {
        remaining
    }
    .as_secs_f64();
    let mut command = Command::new("/usr/bin/curl");
    command.env_clear().args([
        "--disable", "--fail", "--silent", "--location", "--max-redirs", "4",
        "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "5",
        "--max-time", &format!("{:.3}", time.max(0.001)), "--max-filesize", &bound.to_string(),
        "--header", "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json",
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

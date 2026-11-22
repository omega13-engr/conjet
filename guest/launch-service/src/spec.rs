use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::handshake;

pub const WORKLOAD_UID: u32 = 65_532;
pub const WORKLOAD_GID: u32 = 65_532;
pub const MIN_MEMORY_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_MEMORY_BYTES: u64 = 256 * 1024 * 1024;
pub const MAX_PIDS: u32 = 64;
pub const MIN_CPU_MILLICORES: u32 = 10;
pub const MAX_CPU_MILLICORES: u32 = 1_000;
const MAX_ENTRIES: usize = 32;
const MAX_VALUE_BYTES: usize = 1_024;
const MAX_ARG_ENV_BYTES: usize = 8 * 1_024;

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LaunchRequest {
    pub sequence: u64,
    pub budget_ms: u64,
    pub spec: LaunchSpec,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LaunchSpec {
    pub image_digest: String,
    pub argv: Vec<String>,
    pub env: Vec<String>,
    pub cwd: String,
    pub uid: u32,
    pub gid: u32,
    pub network: String,
    pub limits: ResourceLimits,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ResourceLimits {
    pub memory_bytes: u64,
    pub pids: u32,
    pub cpu_millicores: u32,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum SpecError {
    #[error("launch sequence must be nonzero")]
    Sequence,
    #[error("launch budget must be between 1 and 30,000 ms")]
    Budget,
    #[error("image must identify a single lowercase SHA256 digest")]
    Image,
    #[error("argument and environment limits exceeded")]
    Strings,
    #[error("executable and working directory must use canonical absolute paths")]
    Path,
    #[error("environment entries require distinct valid names")]
    Environment,
    #[error("native launch requires UID and GID 65532")]
    Identity,
    #[error("this launch profile supports only the none network")]
    Network,
    #[error("resource limits exceed the native launch profile")]
    Resources,
}

impl SpecError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Identity | Self::Network => "unsupported_option",
            _ => "invalid_spec",
        }
    }
}

/// The constructor is the only path from request fields to validated launch data.
/// Artifact verification and resource reservations remain an admission step.
pub struct ValidatedLaunch {
    request: LaunchRequest,
    digest: [u8; 32],
}

impl ValidatedLaunch {
    pub fn request(&self) -> &LaunchRequest {
        &self.request
    }

    pub fn image_digest_bytes(&self) -> [u8; 32] {
        self.digest
    }
}

impl LaunchRequest {
    pub fn validate(self) -> Result<ValidatedLaunch, SpecError> {
        if self.sequence == 0 {
            return Err(SpecError::Sequence);
        }
        if !(1..=30_000).contains(&self.budget_ms) {
            return Err(SpecError::Budget);
        }
        let spec = &self.spec;
        let digest = spec
            .image_digest
            .strip_prefix("sha256:")
            .and_then(|value| handshake::unhex(value).ok())
            .ok_or(SpecError::Image)?;
        if spec.argv.is_empty() || spec.argv.len() > MAX_ENTRIES || spec.env.len() > MAX_ENTRIES {
            return Err(SpecError::Strings);
        }
        let mut strings = 0;
        for entry in spec.argv.iter().chain(&spec.env) {
            if entry.len() > MAX_VALUE_BYTES || entry.as_bytes().contains(&0) {
                return Err(SpecError::Strings);
            }
            strings += entry.len() + 1;
        }
        if strings > MAX_ARG_ENV_BYTES {
            return Err(SpecError::Strings);
        }
        if !canonical_absolute(&spec.argv[0], false) || !canonical_absolute(&spec.cwd, true) {
            return Err(SpecError::Path);
        }
        let mut names = HashSet::with_capacity(spec.env.len());
        for entry in &spec.env {
            let (name, _) = entry.split_once('=').ok_or(SpecError::Environment)?;
            if !env_name(name) || !names.insert(name) {
                return Err(SpecError::Environment);
            }
        }
        if spec.uid != WORKLOAD_UID || spec.gid != WORKLOAD_GID {
            return Err(SpecError::Identity);
        }
        if spec.network != "none" {
            return Err(SpecError::Network);
        }
        let limits = spec.limits;
        if !(MIN_MEMORY_BYTES..=MAX_MEMORY_BYTES).contains(&limits.memory_bytes)
            || !(1..=MAX_PIDS).contains(&limits.pids)
            || !(MIN_CPU_MILLICORES..=MAX_CPU_MILLICORES).contains(&limits.cpu_millicores)
        {
            return Err(SpecError::Resources);
        }
        Ok(ValidatedLaunch {
            request: self,
            digest,
        })
    }
}

fn canonical_absolute(path: &str, allow_root: bool) -> bool {
    if path.len() > MAX_VALUE_BYTES || path.as_bytes().contains(&0) {
        return false;
    }
    let Some(relative) = path.strip_prefix('/') else {
        return false;
    };
    if relative.is_empty() {
        return allow_root;
    }
    relative
        .split('/')
        .all(|part| !matches!(part, "" | "." | ".."))
}

fn env_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'_')
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid() -> LaunchRequest {
        LaunchRequest {
            sequence: 1,
            budget_ms: 500,
            spec: LaunchSpec {
                image_digest: format!("sha256:{}", "a0".repeat(32)),
                argv: vec!["/bin/probe".into()],
                env: vec!["LANG=C".into()],
                cwd: "/".into(),
                uid: WORKLOAD_UID,
                gid: WORKLOAD_GID,
                network: "none".into(),
                limits: ResourceLimits {
                    memory_bytes: MIN_MEMORY_BYTES,
                    pids: 4,
                    cpu_millicores: 500,
                },
            },
        }
    }

    #[test]
    fn validates_a_bounded_native_spec() {
        let ready = valid().validate().unwrap();
        assert_eq!(ready.image_digest_bytes(), [0xa0; 32]);
        assert_eq!(ready.request().spec.cwd, "/");
    }

    #[test]
    fn rejects_paths_with_ambiguous_resolution() {
        for path in ["relative", "/", "/../probe", "/bin/./probe", "/bin//probe"] {
            let mut request = valid();
            request.spec.argv[0] = path.into();
            assert_eq!(request.validate().err(), Some(SpecError::Path));
        }
        let mut request = valid();
        request.spec.argv[0] = "/bad\0".into();
        assert_eq!(request.validate().err(), Some(SpecError::Strings));
    }

    #[test]
    fn rejects_unbounded_and_unsupported_resources() {
        let mut request = valid();
        request.spec.limits.pids = 0;
        assert_eq!(request.validate().err(), Some(SpecError::Resources));
        let mut request = valid();
        request.spec.network = "bridge".into();
        assert_eq!(request.validate().err(), Some(SpecError::Network));
        let mut request = valid();
        request.spec.uid = 0;
        assert_eq!(request.validate().err(), Some(SpecError::Identity));
    }

    #[test]
    fn rejects_extra_oci_options_and_ambiguous_environment() {
        let mut request = valid();
        request.spec.env.push("LANG=override".into());
        assert_eq!(request.validate().err(), Some(SpecError::Environment));
        let mut input = serde_json::to_value(valid()).unwrap();
        input["spec"]["mounts"] = serde_json::json!([]);
        assert!(serde_json::from_value::<LaunchRequest>(input).is_err());
    }
}

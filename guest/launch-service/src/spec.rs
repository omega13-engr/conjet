use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::handshake;

pub const WORKLOAD_UID: u32 = 65_532;
pub const WORKLOAD_GID: u32 = 65_532;
pub const UID_BASE: u32 = 100_000;
pub const GID_BASE: u32 = 100_000;
pub const ID_MAP_WIDTH: u32 = 65_536;
pub const MAPPED_IDS_CAPABILITY: &str = "native_oci_mapped_ids_v1";
pub const VOLUME_TARGET: &str = "/data";
pub const MIN_MEMORY_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_MEMORY_BYTES: u64 = 256 * 1024 * 1024;
pub const MAX_PIDS: u32 = 64;
pub const MIN_CPU_MILLICORES: u32 = 10;
pub const MAX_CPU_MILLICORES: u32 = 1_000;
pub const NATIVE_LIMITS: ResourceLimits = ResourceLimits {
    memory_bytes: MIN_MEMORY_BYTES,
    pids: 4,
    cpu_millicores: 500,
};
const MAX_ENTRIES: usize = 32;
const MAX_VALUE_BYTES: usize = 1_024;
const MAX_OCI_ARGUMENT_BYTES: usize = 4_096;
const MAX_ARG_ENV_BYTES: usize = 8 * 1_024;

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LaunchRequest {
    pub boot_id: String,
    pub sequence: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
    pub budget_ms: u64,
    pub spec: LaunchSpec,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LaunchSpec {
    pub image_digest: String,
    pub argv: Vec<String>,
    pub env: Vec<String>,
    pub cwd: String,
    pub uid: u32,
    pub gid: u32,
    pub network: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_alias: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secondary_network_alias: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volume: Option<VolumeMount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bind: Option<BindMount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build_snapshot: Option<crate::build_snapshot::Snapshot>,
    pub limits: ResourceLimits,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub docker_resource_defaults: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub memory_swap_disabled: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub open_stdin: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeMount {
    pub name: String,
    pub inode: u64,
    pub read_only: bool,
    #[serde(
        default = "default_volume_target",
        skip_serializing_if = "is_data_target"
    )]
    pub target: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BindMount {
    pub lease: String,
    pub read_only: bool,
}

fn default_volume_target() -> String {
    VOLUME_TARGET.into()
}

fn is_data_target(target: &str) -> bool {
    target == VOLUME_TARGET
}

pub fn valid_volume_target(target: &str) -> bool {
    matches!(target, VOLUME_TARGET | "/dataset" | "/var/lib/registry")
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ResourceLimits {
    pub memory_bytes: u64,
    pub pids: u32,
    pub cpu_millicores: u32,
}

impl ResourceLimits {
    pub fn has_unlimited(self) -> bool {
        self.memory_bytes == 0 || self.pids == 0 || self.cpu_millicores == 0
    }

    fn validate(self, defaults: bool) -> bool {
        ((defaults && self.memory_bytes == 0)
            || (MIN_MEMORY_BYTES..=MAX_MEMORY_BYTES).contains(&self.memory_bytes))
            && ((defaults && self.pids == 0) || (1..=MAX_PIDS).contains(&self.pids))
            && ((defaults && self.cpu_millicores == 0)
                || (MIN_CPU_MILLICORES..=MAX_CPU_MILLICORES).contains(&self.cpu_millicores))
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BridgeScope {
    Custom,
    BuiltIn,
}

impl BridgeScope {
    pub const fn subnet(self) -> u8 {
        match self {
            Self::Custom => 0,
            Self::BuiltIn => 1,
        }
    }

    pub const fn gateway(self) -> std::net::Ipv4Addr {
        std::net::Ipv4Addr::new(198, 18, self.subnet(), 1)
    }

    pub const fn wire_mode(self) -> &'static str {
        match self {
            Self::Custom => "bridge",
            Self::BuiltIn => "default_bridge",
        }
    }
}

pub fn valid_network_alias(alias: &str) -> bool {
    crate::bridge_dns::valid_name(alias)
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum SpecError {
    #[error("launch requires a valid boot ID")]
    BootId,
    #[error("launch sequence must be nonzero")]
    Sequence,
    #[error("operation ID must be a lowercase 128-bit hexadecimal value")]
    OperationId,
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
    #[error("native workload credentials do not fit the launch profile's UID/GID map")]
    Identity,
    #[error("this launch profile supports only none and bridge networking")]
    Network,
    #[error("requested native volume identity is invalid")]
    Volume,
    #[error("invalid native build snapshot identity or incompatible mounts")]
    BuildSnapshot,
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
        self.validate_with_path_search(false)
    }

    pub fn validate_oci(self) -> Result<ValidatedLaunch, SpecError> {
        self.validate_with_path_search(true)
    }

    fn validate_with_path_search(self, search_path: bool) -> Result<ValidatedLaunch, SpecError> {
        handshake::unhex::<16>(&self.boot_id).map_err(|_| SpecError::BootId)?;
        if self.sequence == 0 {
            return Err(SpecError::Sequence);
        }
        if self
            .operation_id
            .as_ref()
            .is_some_and(|value| handshake::unhex::<16>(value).is_err())
        {
            return Err(SpecError::OperationId);
        }
        if !(1..=30_000).contains(&self.budget_ms) {
            return Err(SpecError::Budget);
        }
        let digest = self.spec.validate_process(search_path)?;
        Ok(ValidatedLaunch {
            request: self,
            digest,
        })
    }
}

impl LaunchSpec {
    pub fn bridge_scope(&self) -> Option<BridgeScope> {
        match self.network.as_str() {
            "bridge" => Some(BridgeScope::Custom),
            "default_bridge" => Some(BridgeScope::BuiltIn),
            _ => None,
        }
    }

    pub(crate) fn fixture_identity(&self) -> bool {
        self.uid == WORKLOAD_UID && self.gid == WORKLOAD_GID
    }

    pub(crate) fn aliases(&self) -> impl Iterator<Item = &String> {
        self.network_alias
            .iter()
            .chain(&self.secondary_network_alias)
    }

    pub fn validate(&self) -> Result<[u8; 32], SpecError> {
        self.validate_process(false)
    }

    pub fn validate_exec(&self) -> Result<[u8; 32], SpecError> {
        self.validate_process(true)
    }

    fn validate_process(&self, search_path: bool) -> Result<[u8; 32], SpecError> {
        let spec = self;
        if spec.build_snapshot.as_ref().is_some_and(|snapshot| {
            !crate::build_snapshot::valid_id(&snapshot.id)
                || snapshot.inode == 0
                || snapshot.device == 0
                || spec.volume.is_some()
                || spec.bind.is_some()
                || spec.network != "none"
                || spec.open_stdin
        }) {
            return Err(SpecError::BuildSnapshot);
        }
        if spec.volume.as_ref().is_some_and(|volume| {
            volume.inode == 0
                || !crate::volume_disk::valid_name(&volume.name)
                || !valid_volume_target(&volume.target)
        }) {
            return Err(SpecError::Volume);
        }
        if spec.bind.as_ref().is_some_and(|bind| {
            !search_path
                || spec.volume.is_some()
                || spec.uid != 0
                || spec.gid != 0
                || handshake::unhex::<16>(&bind.lease).is_err()
        }) {
            return Err(SpecError::Volume);
        }
        let digest = spec
            .image_digest
            .strip_prefix("sha256:")
            .and_then(|value| handshake::unhex(value).ok())
            .ok_or(SpecError::Image)?;
        if spec.argv.is_empty() || spec.argv.len() > MAX_ENTRIES || spec.env.len() > MAX_ENTRIES {
            return Err(SpecError::Strings);
        }
        let argument_bound = if search_path && spec.build_snapshot.is_none() {
            MAX_OCI_ARGUMENT_BYTES
        } else {
            MAX_VALUE_BYTES
        };
        let mut strings = 0;
        let bounded_values = spec.argv[..1]
            .iter()
            .chain(&spec.env)
            .map(|value| (value, MAX_VALUE_BYTES))
            .chain(spec.argv[1..].iter().map(|value| (value, argument_bound)));
        for (entry, bound) in bounded_values {
            if entry.len() > bound || entry.as_bytes().contains(&0) {
                return Err(SpecError::Strings);
            }
            strings += entry.len() + 1;
        }
        if strings > MAX_ARG_ENV_BYTES {
            return Err(SpecError::Strings);
        }
        let executable = &spec.argv[0];
        let bare = search_path
            && !matches!(executable.as_str(), "" | "." | "..")
            && executable
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte));
        if !(bare || canonical_absolute(executable, false)) || !canonical_absolute(&spec.cwd, true)
        {
            return Err(SpecError::Path);
        }
        let mut names = HashSet::with_capacity(spec.env.len());
        for entry in &spec.env {
            let (name, _) = entry.split_once('=').ok_or(SpecError::Environment)?;
            if !env_name(name) || !names.insert(name) {
                return Err(SpecError::Environment);
            }
        }
        if spec.uid >= ID_MAP_WIDTH
            || spec.gid >= ID_MAP_WIDTH
            || (spec.build_snapshot.is_some() && !spec.fixture_identity())
        {
            return Err(SpecError::Identity);
        }
        let bridge = spec.bridge_scope().is_some();
        if (spec.network != "none" && !bridge)
            || spec
                .aliases()
                .any(|alias| !bridge || !valid_network_alias(alias))
            || spec.secondary_network_alias.as_ref().is_some_and(|second| {
                spec.network_alias
                    .as_ref()
                    .is_none_or(|first| first.eq_ignore_ascii_case(second))
            })
        {
            return Err(SpecError::Network);
        }
        if !spec
            .limits
            .validate(spec.docker_resource_defaults && spec.build_snapshot.is_none())
            || (spec.memory_swap_disabled
                && (!search_path || spec.build_snapshot.is_some() || spec.limits.memory_bytes == 0))
        {
            return Err(SpecError::Resources);
        }
        Ok(digest)
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
            boot_id: "42".repeat(16),
            sequence: 1,
            operation_id: None,
            budget_ms: 500,
            spec: LaunchSpec {
                image_digest: format!("sha256:{}", "a0".repeat(32)),
                argv: vec!["/bin/probe".into()],
                env: vec!["LANG=C".into()],
                cwd: "/".into(),
                uid: WORKLOAD_UID,
                gid: WORKLOAD_GID,
                network: "none".into(),
                network_alias: None,
                secondary_network_alias: None,
                volume: None,
                bind: None,
                build_snapshot: None,
                limits: ResourceLimits {
                    memory_bytes: MIN_MEMORY_BYTES,
                    pids: 4,
                    cpu_millicores: 500,
                },
                docker_resource_defaults: false,
                memory_swap_disabled: false,
                open_stdin: false,
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
    fn accepts_a_bare_oci_program_without_relaxing_static_or_relative_paths() {
        let mut request = valid();
        request.spec.argv[0] = "sleep".into();
        assert_eq!(request.spec.validate().err(), Some(SpecError::Path));
        assert!(request.validate_oci().is_ok());
        let mut request = valid();
        request.spec.argv[0] = "bin/sleep".into();
        assert_eq!(request.validate_oci().err(), Some(SpecError::Path));
    }

    #[test]
    fn admits_storage_program_size_only_as_a_bounded_ordinary_oci_argument() {
        let mut request = valid();
        request.spec.argv.push("x".repeat(2121));
        assert_eq!(request.spec.validate().err(), Some(SpecError::Strings));
        assert!(request.spec.validate_exec().is_ok());
        request.spec.argv[1] = "x".repeat(4097);
        assert_eq!(request.spec.validate_exec().err(), Some(SpecError::Strings));
        request.spec.argv[1] = "x".repeat(4096);
        request.spec.env = vec![format!("NAME={}", "x".repeat(1024))];
        assert_eq!(request.spec.validate_exec().err(), Some(SpecError::Strings));
    }

    #[test]
    fn rejects_unbounded_and_unsupported_resources() {
        let mut request = valid();
        request.spec.limits.pids = 0;
        assert_eq!(request.validate().err(), Some(SpecError::Resources));
        let mut request = valid();
        request.spec.network = "host".into();
        assert_eq!(request.validate().err(), Some(SpecError::Network));
        let mut request = valid();
        request.spec.uid = ID_MAP_WIDTH;
        assert_eq!(request.validate().err(), Some(SpecError::Identity));
    }

    #[test]
    fn permits_independent_docker_resource_omissions_with_explicit_authority() {
        let mut request = valid();
        request.spec.docker_resource_defaults = true;
        request.spec.limits = ResourceLimits {
            memory_bytes: 128 * 1024 * 1024,
            pids: 0,
            cpu_millicores: 0,
        };
        assert!(request.spec.validate().is_ok());
        request.spec.limits.memory_bytes = MAX_MEMORY_BYTES + 1;
        assert_eq!(request.validate().err(), Some(SpecError::Resources));
    }

    #[test]
    fn validates_namespace_root_but_keeps_build_fixture_identity() {
        let mut request = valid();
        request.spec.uid = 0;
        request.spec.gid = 0;
        assert!(request.spec.validate().is_ok());
        request.spec.build_snapshot = Some(crate::build_snapshot::Snapshot {
            id: "fixture".into(),
            device: 1,
            inode: 1,
            bundle_policy: true,
        });
        assert_eq!(request.spec.validate().err(), Some(SpecError::Identity));
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

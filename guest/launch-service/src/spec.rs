use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{build_snapshot::Snapshotter, handshake};

pub const WORKLOAD_UID: u32 = 65_532;
pub const WORKLOAD_GID: u32 = 65_532;
pub const UID_BASE: u32 = 100_000;
pub const GID_BASE: u32 = 100_000;
pub const ID_MAP_WIDTH: u32 = 65_536;
pub const MAPPED_IDS_CAPABILITY: &str = "native_oci_mapped_ids_v1";
pub const VOLUME_TARGET: &str = "/data";
pub const REDIS_CONFIG: &str =
    "sha256:eab78b9649d5ca8b91192621c91136c9c1465a81338fb686fbc02bac4dd851ae";
pub const REGISTRY_CONFIG: &str =
    "sha256:33eeff39e0aaabe61ca826fd7502396183462451be0783133e1a8fa944fc7350";
pub const BUILDKIT_CONFIG: &str =
    "sha256:8ff6bca64af355cd0434480a0fd583a7c571211750a5eb806b992017148bab55";
pub const BUILDKIT_DEFAULT_CONFIG: &str =
    "sha256:8e11cae448ccc48942e94449d6d440319bbe781cd134cde792c16ffdf7dc4e17";

pub fn approved_buildkit_config(image: &str) -> bool {
    matches!(image, BUILDKIT_CONFIG | BUILDKIT_DEFAULT_CONFIG)
}

pub const BUILDKIT_PATH: &str = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
pub const BUILDKIT_SNAPSHOTTER_ARG: usize = 5;
pub const BUILDKIT_NATIVE_ARGS: &[&str] = &[
    "buildkitd",
    "--root=/run/conjet/buildkit/worker",
    "--containerd-worker=false",
    "--oci-worker=true",
    "--oci-worker-rootless",
    Snapshotter::Native.worker_arg(),
    "--oci-worker-binary=/usr/bin/conjet-buildkit-runtime",
    "--oci-worker-net=host",
    "--otel-socket-path=/var/lib/buildkit/otel-grpc.sock",
];
pub const BUILDKIT_NETWORK_ENTITLEMENT: &str = "--allow-insecure-entitlement=network.host";
pub const BUILDKIT_REGISTRY_CONFIG: &str = "--config=/run/conjet/buildkit-registry.toml";
pub const BUILDKIT_REGISTRY_PORT: u16 = 5001;

pub fn buildkit_control_exec(image: &str, argv: &[String]) -> bool {
    approved_buildkit_config(image)
        && match argv {
            [program, operation] => {
                (program == "buildctl" && operation == "dial-stdio")
                    || (program == "buildkitd" && operation == "--version")
            }
            [program, operation, target] => {
                program == "buildctl" && operation == "debug" && target == "workers"
            }
            _ => false,
        }
}

pub fn workload_output_limit(image: &str) -> usize {
    if image == REGISTRY_CONFIG {
        256 * 1024
    } else {
        64 * 1024
    }
}
pub const MIN_MEMORY_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_MEMORY_BYTES: u64 = 256 * 1024 * 1024;
pub const MAX_PIDS: u32 = 64;
pub const CPU_PERIOD_US: u32 = 100_000;
pub const MIN_CPU_MILLICORES: u32 = 10;
pub const MAX_CPU_MILLICORES: u32 = 1_000;
pub const NATIVE_LIMITS: ResourceLimits = ResourceLimits {
    memory_bytes: MIN_MEMORY_BYTES,
    pids: 4,
    cpu_millicores: 500,
    cpu_bandwidth: None,
    cpu_affinity: None,
    memory_reservation_bytes: 0,
    memory_swap_bytes: None,
};
const MAX_ENTRIES: usize = 32;
const MAX_VALUE_BYTES: usize = 1_024;
const MAX_OCI_ARGUMENT_BYTES: usize = 4_096;
const MAX_ARG_ENV_BYTES: usize = 8 * 1_024;
const MAX_BUILD_VALUE_BYTES: usize = 32 * 1024;
const MAX_BUILD_ARG_ENV_BYTES: usize = 64 * 1024;
const MAX_BUILD_ENTRIES: usize = 128;

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retained_layer: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub rootfs_read_only: bool,
    pub argv: Vec<String>,
    pub env: Vec<String>,
    pub cwd: String,
    pub uid: u32,
    pub gid: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<Account>,
    pub network: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_alias: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secondary_network_alias: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_alias_project: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volume: Option<VolumeMount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bind: Option<BindMount>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub binds: Vec<BindMount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build_snapshot: Option<crate::build_snapshot::Snapshot>,
    pub limits: ResourceLimits,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub docker_resource_defaults: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub docker_default_capabilities: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub memory_swap_disabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_files_limit: Option<OpenFilesLimit>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub open_stdin: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub redis_bootstrap: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub buildkit_worker: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct OpenFilesLimit {
    pub soft: u64,
    pub hard: u64,
}

impl OpenFilesLimit {
    pub const MAXIMUM: u64 = 1_048_576;

    pub fn valid(self) -> bool {
        self.soft <= self.hard && self.hard <= Self::MAXIMUM
    }
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
    #[serde(default = "default_bind_target")]
    pub target: String,
    pub lease: String,
    pub read_only: bool,
}

fn default_bind_target() -> String {
    "/dataset".into()
}

pub fn valid_bind_target(path: &str) -> bool {
    canonical_absolute(path, false)
        && !["/proc", "/sys", "/dev", "/run/conjet"].iter().any(|root| {
            path == *root || path.strip_prefix(root).is_some_and(|p| p.starts_with('/'))
        })
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Account {
    pub user: String,
    pub group: Option<String>,
}

impl Account {
    pub fn parse(value: &str) -> Option<Self> {
        let (user, group) = value
            .split_once(':')
            .map_or((value, None), |(user, group)| (user, Some(group)));
        let account = Self {
            user: user.to_owned(),
            group: group.map(str::to_owned),
        };
        account.valid().then_some(account)
    }

    pub(crate) fn valid(&self) -> bool {
        let field = |value: &str| {
            !value.is_empty()
                && value.len() <= 64
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
                && (!value.bytes().all(|byte| byte.is_ascii_digit())
                    || value.parse::<u32>().is_ok_and(|id| id < ID_MAP_WIDTH))
        };
        field(&self.user) && self.group.as_deref().is_none_or(field)
    }
}

fn default_volume_target() -> String {
    VOLUME_TARGET.into()
}

fn is_data_target(target: &str) -> bool {
    target == VOLUME_TARGET
}

pub fn valid_retained_layer_id(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

pub fn valid_volume_target(target: &str) -> bool {
    // Retain the workload setup's runtime and configuration directories.
    valid_bind_target(target) && !matches!(target, "/run" | "/etc") && !target.starts_with("/etc/")
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ResourceLimits {
    pub memory_bytes: u64,
    pub pids: u32,
    pub cpu_millicores: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_bandwidth: Option<CpuBandwidth>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_affinity: Option<u64>,
    #[serde(default, skip_serializing_if = "zero")]
    pub memory_reservation_bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_swap_bytes: Option<u64>,
}

fn zero(value: &u64) -> bool {
    *value == 0
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CpuBandwidth {
    pub period_us: u32,
    pub quota_us: u32,
}

pub fn parse_cpu_set(value: &str) -> Option<u64> {
    let mut mask = 0u64;
    for range in value.split(',') {
        let (first, last) = range.split_once('-').unwrap_or((range, range));
        let first = first.parse::<u32>().ok()?;
        let last = last.parse::<u32>().ok()?;
        if !(first..64).contains(&last) {
            return None;
        }
        for cpu in first..=last {
            mask |= 1 << cpu;
        }
    }
    Some(mask)
}

impl ResourceLimits {
    #[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
    pub(crate) const UNBOUNDED: Self = Self {
        memory_bytes: 0,
        pids: 0,
        cpu_millicores: 0,
        cpu_bandwidth: None,
        cpu_affinity: None,
        memory_reservation_bytes: 0,
        memory_swap_bytes: None,
    };

    pub fn has_unlimited(self) -> bool {
        self.memory_bytes == 0 || self.pids == 0 || self.cpu_bandwidth().quota_us == 0
    }

    pub fn cpu_bandwidth(self) -> CpuBandwidth {
        self.cpu_bandwidth.unwrap_or(CpuBandwidth {
            period_us: CPU_PERIOD_US,
            quota_us: self.cpu_millicores.saturating_mul(CPU_PERIOD_US / 1_000),
        })
    }

    pub fn valid_docker(self) -> bool {
        self.validate(true)
    }

    fn validate(self, defaults: bool) -> bool {
        ((defaults && self.memory_bytes == 0)
            || (MIN_MEMORY_BYTES..=MAX_MEMORY_BYTES).contains(&self.memory_bytes))
            && ((defaults && self.pids == 0) || (1..=MAX_PIDS).contains(&self.pids))
            && (self.memory_reservation_bytes == 0
                || ((6 * 1024 * 1024..=MAX_MEMORY_BYTES).contains(&self.memory_reservation_bytes)
                    && (self.memory_bytes == 0
                        || self.memory_reservation_bytes <= self.memory_bytes)))
            && self.memory_swap_bytes.is_none_or(|swap| {
                self.memory_bytes != 0 && swap <= (i64::MAX as u64 - self.memory_bytes)
            })
            && self.cpu_affinity != Some(0)
            && match self.cpu_bandwidth {
                Some(bandwidth) => {
                    let quota = u64::from(bandwidth.quota_us);
                    let period = u64::from(bandwidth.period_us);
                    self.cpu_millicores == 0
                        && (1_000..=1_000_000).contains(&bandwidth.period_us)
                        && ((defaults && quota == 0)
                            || (quota >= 1_000
                                && (period * u64::from(MIN_CPU_MILLICORES)
                                    ..=period * u64::from(MAX_CPU_MILLICORES))
                                    .contains(&(quota * 1_000))))
                }
                None => {
                    (defaults && self.cpu_millicores == 0)
                        || (MIN_CPU_MILLICORES..=MAX_CPU_MILLICORES).contains(&self.cpu_millicores)
                }
            }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BridgeScope {
    Custom,
    CustomRouted,
    BuiltIn,
}

impl BridgeScope {
    pub const fn subnet(self) -> u8 {
        match self {
            Self::Custom | Self::CustomRouted => 0,
            Self::BuiltIn => 1,
        }
    }

    pub const fn gateway(self) -> std::net::Ipv4Addr {
        std::net::Ipv4Addr::new(198, 18, self.subnet(), 1)
    }

    pub const fn wire_mode(self) -> &'static str {
        match self {
            Self::Custom => "bridge",
            Self::CustomRouted => "routed_bridge",
            Self::BuiltIn => "default_bridge",
        }
    }

    pub const fn has_default_route(self) -> bool {
        matches!(self, Self::CustomRouted | Self::BuiltIn)
    }
}

pub fn valid_network_alias(alias: &str) -> bool {
    crate::bridge_dns::valid_name(alias)
}

pub fn valid_service_alias(project: &str, primary: &str, service: &str) -> bool {
    let Some((prefix, number)) = primary.rsplit_once('-') else {
        return false;
    };
    !project.contains('.')
        && !service.contains('.')
        && valid_network_alias(project)
        && valid_network_alias(service)
        && prefix == format!("{project}-{service}")
        && number
            .parse::<u32>()
            .is_ok_and(|index| index != 0 && index.to_string() == number)
}

pub fn network_aliases_conflict(
    left: &[String],
    left_project: Option<&str>,
    right: &[String],
    right_project: Option<&str>,
) -> bool {
    left.iter().enumerate().any(|(i, name)| {
        right.iter().enumerate().any(|(j, candidate)| {
            name.eq_ignore_ascii_case(candidate)
                && !(i == 1 && j == 1 && left_project.is_some() && left_project == right_project)
        })
    })
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
        if self.spec.buildkit_worker && !self.spec.can_start_buildkit() {
            return Err(SpecError::Identity);
        }
        Ok(ValidatedLaunch {
            request: self,
            digest,
        })
    }
}

impl LaunchSpec {
    pub fn host_binds(&self) -> impl Iterator<Item = &BindMount> {
        self.bind.iter().chain(self.binds.iter())
    }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    pub(crate) fn build_sysfs_view(&self) -> bool {
        self.build_snapshot.as_ref().is_some_and(|snapshot| {
            snapshot.bundle_policy && (!snapshot.live_worker || self.fixture_identity())
        })
    }

    pub fn can_start_buildkit(&self) -> bool {
        approved_buildkit_config(&self.image_digest)
            && self.uid == 0
            && self.gid == 0
            && self.cwd == "/"
            && self.env.as_slice() == [BUILDKIT_PATH]
            && self.build_snapshot.is_none()
            && !self.rootfs_read_only
            && (self.bind.is_none() && self.binds.is_empty())
            && !self.open_stdin
            && !self.redis_bootstrap
            && self
                .volume
                .as_ref()
                .is_some_and(|volume| volume.target == "/var/lib/buildkit" && !volume.read_only)
            && self.buildkit_snapshotter().is_some()
            && self
                .argv
                .get(BUILDKIT_NATIVE_ARGS.len()..)
                .is_some_and(|extra| {
                    let extra = match extra {
                        [flag, rest @ ..] if flag == BUILDKIT_REGISTRY_CONFIG => rest,
                        _ => extra,
                    };
                    extra.is_empty() || extra == [BUILDKIT_NETWORK_ENTITLEMENT]
                })
    }

    pub(crate) fn buildkit_snapshotter(&self) -> Option<Snapshotter> {
        let prefix = self.argv.get(..BUILDKIT_NATIVE_ARGS.len())?;
        let snapshotter = [Snapshotter::Native, Snapshotter::Overlay]
            .into_iter()
            .find(|snapshotter| prefix[BUILDKIT_SNAPSHOTTER_ARG] == snapshotter.worker_arg())?;
        prefix
            .iter()
            .zip(BUILDKIT_NATIVE_ARGS)
            .enumerate()
            .all(|(index, (actual, expected))| {
                index == BUILDKIT_SNAPSHOTTER_ARG || actual == expected
            })
            .then_some(snapshotter)
    }

    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    pub(crate) fn buildkit_registry(&self) -> bool {
        self.buildkit_worker
            && self
                .argv
                .get(BUILDKIT_NATIVE_ARGS.len())
                .is_some_and(|arg| arg == BUILDKIT_REGISTRY_CONFIG)
    }

    pub fn can_bootstrap_redis(&self) -> bool {
        let args = self.argv.iter().map(String::as_str);
        self.image_digest == REDIS_CONFIG
            && self.uid == 0
            && self.gid == 0
            && self.cwd == "/data"
            && self.build_snapshot.is_none()
            && (self.bind.is_none() && self.binds.is_empty())
            && self
                .volume
                .as_ref()
                .is_some_and(|volume| volume.target == "/data" && !volume.read_only)
            && args.eq([
                "docker-entrypoint.sh",
                "redis-server",
                "--appendonly",
                "yes",
                "--appendfsync",
                "always",
            ])
            && self.env.len() == 2
            && self.env.iter().any(|value| {
                value == "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            })
            && self.env.iter().any(|value| value == "REDIS_VERSION=7.4.12")
    }

    pub fn bridge_scope(&self) -> Option<BridgeScope> {
        match self.network.as_str() {
            "bridge" => Some(BridgeScope::Custom),
            "routed_bridge" => Some(BridgeScope::CustomRouted),
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

    pub fn set_exec_argv(&mut self, argv: Vec<String>) {
        self.redis_bootstrap = false;
        self.buildkit_worker &= buildkit_control_exec(&self.image_digest, &argv);
        self.argv = argv;
    }

    fn validate_process(&self, search_path: bool) -> Result<[u8; 32], SpecError> {
        let spec = self;
        if spec.rootfs_read_only && (spec.build_snapshot.is_some() || spec.buildkit_worker) {
            return Err(SpecError::Volume);
        }
        if spec.retained_layer.as_ref().is_some_and(|id| {
            !valid_retained_layer_id(id) || spec.build_snapshot.is_some() || spec.buildkit_worker
        }) {
            return Err(SpecError::Volume);
        }
        if spec.build_snapshot.as_ref().is_some_and(|snapshot| {
            !crate::build_snapshot::valid_id(&snapshot.id)
                || snapshot.inode == 0
                || snapshot.device == 0
                || (snapshot.live_worker && !snapshot.bundle_policy)
                || spec.volume.is_some()
                || (spec.bind.is_some() || !spec.binds.is_empty())
                || spec.network != "none"
                || (spec.open_stdin && !snapshot.live_worker)
                || snapshot
                    .supplementary_groups
                    .as_ref()
                    .is_some_and(|groups| {
                        !snapshot.live_worker
                            || groups.len() > 128
                            || groups.iter().any(|gid| *gid >= ID_MAP_WIDTH)
                    })
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
        let mounts: Vec<_> = spec.host_binds().collect();
        if mounts.len() > 8
            || mounts.iter().enumerate().any(|(index, bind)| {
                mounts[..index].iter().any(|other| {
                    bind.lease == other.lease
                        || bind.target == other.target
                        || bind.target.starts_with(&(other.target.clone() + "/"))
                        || other.target.starts_with(&(bind.target.clone() + "/"))
                })
            })
            || mounts.iter().any(|bind| {
                !search_path
                    || spec.volume.is_some()
                    || spec.uid != 0
                    || spec.gid != 0
                    || !valid_bind_target(&bind.target)
                    || handshake::unhex::<16>(&bind.lease).is_err()
            })
        {
            return Err(SpecError::Volume);
        }
        let digest = spec
            .image_digest
            .strip_prefix("sha256:")
            .and_then(|value| handshake::unhex(value).ok())
            .ok_or(SpecError::Image)?;
        let live_build = spec.build_snapshot.as_ref().is_some_and(|s| s.live_worker);
        let entries = if live_build {
            MAX_BUILD_ENTRIES
        } else {
            MAX_ENTRIES
        };
        if spec.argv.is_empty() || spec.argv.len() > entries || spec.env.len() > entries {
            return Err(SpecError::Strings);
        }
        let argument_bound = if live_build {
            MAX_BUILD_VALUE_BYTES
        } else if search_path && spec.build_snapshot.is_none() {
            MAX_OCI_ARGUMENT_BYTES
        } else {
            MAX_VALUE_BYTES
        };
        let mut strings = 0;
        let environment_bound = if live_build {
            MAX_BUILD_VALUE_BYTES
        } else {
            MAX_VALUE_BYTES
        };
        let bounded_values = spec.argv[..1]
            .iter()
            .map(|value| (value, MAX_VALUE_BYTES))
            .chain(spec.env.iter().map(|value| (value, environment_bound)))
            .chain(spec.argv[1..].iter().map(|value| (value, argument_bound)));
        for (entry, bound) in bounded_values {
            if entry.len() > bound || entry.as_bytes().contains(&0) {
                return Err(SpecError::Strings);
            }
            strings += entry.len() + 1;
        }
        let total_bound = if live_build {
            MAX_BUILD_ARG_ENV_BYTES
        } else {
            MAX_ARG_ENV_BYTES
        };
        // The helper receives a serialized spec as one exec argument. Account for
        // JSON escaping below Linux's 128 KiB single-string limit as well.
        if strings > total_bound
            || (live_build
                && serde_json::to_vec(spec)
                    .map_err(|_| SpecError::Strings)?
                    .len()
                    > 120 * 1024)
        {
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
        if spec.docker_default_capabilities
            && (!search_path || spec.build_snapshot.is_some() || spec.buildkit_worker)
        {
            return Err(SpecError::Identity);
        }
        if spec.uid >= ID_MAP_WIDTH
            || spec.gid >= ID_MAP_WIDTH
            || spec.build_snapshot.as_ref().is_some_and(|snapshot| {
                if snapshot.live_worker {
                    (spec.uid != 0 || spec.gid != 0) && !spec.fixture_identity()
                } else {
                    !spec.fixture_identity()
                }
            })
            || spec.account.as_ref().is_some_and(|account| {
                !search_path
                    || spec.build_snapshot.is_some()
                    || (spec.bind.is_some() || !spec.binds.is_empty())
                    || spec.uid != 0
                    || spec.gid != 0
                    || !account.valid()
            })
            || (spec.redis_bootstrap && (!search_path || !spec.can_bootstrap_redis()))
            || (spec.buildkit_worker
                && (!search_path
                    || (!spec.can_start_buildkit()
                        && !buildkit_control_exec(&spec.image_digest, &spec.argv))))
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
            || spec.network_alias_project.as_ref().is_some_and(|project| {
                spec.bridge_scope() == Some(BridgeScope::BuiltIn)
                    || !spec
                        .network_alias
                        .as_deref()
                        .zip(spec.secondary_network_alias.as_deref())
                        .is_some_and(|(primary, service)| {
                            valid_service_alias(project, primary, service)
                        })
            })
        {
            return Err(SpecError::Network);
        }
        if !spec.limits.validate(
            spec.docker_resource_defaults
                && spec
                    .build_snapshot
                    .as_ref()
                    .is_none_or(|snapshot| snapshot.live_worker),
        ) || (spec.memory_swap_disabled
            && (!search_path
                || spec.build_snapshot.is_some()
                || spec.limits.memory_bytes == 0
                || spec.limits.memory_swap_bytes.is_some()))
            || spec.open_files_limit.is_some_and(|limit| {
                !search_path || spec.build_snapshot.is_some() || !limit.valid()
            })
        {
            return Err(SpecError::Resources);
        }
        Ok(digest)
    }
}

pub(crate) fn canonical_absolute(path: &str, allow_root: bool) -> bool {
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
                retained_layer: None,
                rootfs_read_only: false,
                image_digest: format!("sha256:{}", "a0".repeat(32)),
                argv: vec!["/bin/probe".into()],
                env: vec!["LANG=C".into()],
                cwd: "/".into(),
                uid: WORKLOAD_UID,
                gid: WORKLOAD_GID,
                account: None,
                network: "none".into(),
                network_alias: None,
                secondary_network_alias: None,
                network_alias_project: None,
                volume: None,
                bind: None,
                binds: Vec::new(),
                build_snapshot: None,
                limits: ResourceLimits {
                    memory_bytes: MIN_MEMORY_BYTES,
                    pids: 4,
                    cpu_millicores: 500,
                    cpu_bandwidth: None,
                    cpu_affinity: None,
                    memory_reservation_bytes: 0,
                    memory_swap_bytes: None,
                },
                docker_resource_defaults: false,
                docker_default_capabilities: false,
                memory_swap_disabled: false,
                open_files_limit: None,
                open_stdin: false,
                redis_bootstrap: false,
                buildkit_worker: false,
            },
        }
    }

    #[test]
    fn named_volumes_allow_workload_directories_and_preserve_runtime_mounts() {
        for path in ["/payload", "/data", "/var/lib/postgresql/data"] {
            assert!(valid_volume_target(path));
        }
        for path in [
            "/",
            "relative",
            "/x/../y",
            "/proc",
            "/sys/data",
            "/dev",
            "/run",
            "/run/conjet/data",
            "/etc",
            "/etc/fixture",
        ] {
            assert!(!valid_volume_target(path));
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
    fn long_commands_are_bounded_and_scoped_to_live_builds() {
        let mut spec = valid().spec;
        spec.argv = vec!["/bin/sh".into(), "-c".into(), "x".repeat(12 * 1024)];
        assert_eq!(spec.validate().err(), Some(SpecError::Strings));
        spec.build_snapshot = Some(crate::build_snapshot::Snapshot {
            id: "longRun".into(),
            device: 1,
            inode: 1,
            bundle_policy: true,
            live_worker: true,
            supplementary_groups: None,
        });
        assert!(spec.validate().is_ok());
        spec.argv[2] = "x".repeat(MAX_BUILD_VALUE_BYTES + 1);
        assert_eq!(spec.validate().err(), Some(SpecError::Strings));
        spec.argv[2] = "\u{1}".repeat(MAX_BUILD_VALUE_BYTES);
        assert_eq!(spec.validate().err(), Some(SpecError::Strings));
        spec.argv[2] = "x".repeat(MAX_BUILD_VALUE_BYTES);
        spec.env = vec![
            format!("A={}", "x".repeat(MAX_BUILD_VALUE_BYTES - 2)),
            "B=x".into(),
        ];
        assert_eq!(spec.validate().err(), Some(SpecError::Strings));
    }

    #[test]
    fn binds_require_distinct_owned_leases_and_safe_nonoverlapping_targets() {
        let mut spec = valid().spec;
        spec.uid = 0;
        spec.gid = 0;
        spec.binds = ["/app/data", "/app/keys", "/app/skills"]
            .into_iter()
            .enumerate()
            .map(|(i, target)| BindMount {
                target: target.into(),
                lease: format!("{i:032x}"),
                read_only: false,
            })
            .collect();
        assert!(spec.validate_exec().is_ok());
        assert_eq!(spec.validate().err(), Some(SpecError::Volume));
        let original = spec.binds.clone();
        for target in [
            "/",
            "/proc/self",
            "/dev",
            "/sys/a",
            "/run/conjet/a",
            "/app/../etc",
            "/app/data",
            "/app/data/nested",
        ] {
            spec.binds = original.clone();
            spec.binds[1].target = target.into();
            assert_eq!(
                spec.validate_exec().err(),
                Some(SpecError::Volume),
                "{target}"
            );
        }
        spec.binds = original;
        spec.binds[1].lease = spec.binds[0].lease.clone();
        assert_eq!(spec.validate_exec().err(), Some(SpecError::Volume));
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
            cpu_bandwidth: None,
            cpu_affinity: None,
            memory_reservation_bytes: 0,
            memory_swap_bytes: None,
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
            live_worker: false,
            supplementary_groups: None,
        });
        assert_eq!(request.spec.validate().err(), Some(SpecError::Identity));
    }

    #[test]
    fn redis_bootstrap_requires_the_pinned_process_and_owned_writable_volume() {
        let mut request = valid();
        request.spec.image_digest = REDIS_CONFIG.into();
        request.spec.argv = [
            "docker-entrypoint.sh",
            "redis-server",
            "--appendonly",
            "yes",
            "--appendfsync",
            "always",
        ]
        .map(String::from)
        .to_vec();
        request.spec.env = vec![
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin".into(),
            "REDIS_VERSION=7.4.12".into(),
        ];
        request.spec.cwd = "/data".into();
        request.spec.uid = 0;
        request.spec.gid = 0;
        request.spec.volume = Some(VolumeMount {
            name: "redis-cache".into(),
            target: "/data".into(),
            inode: 14,
            read_only: false,
        });
        request.spec.redis_bootstrap = true;
        assert!(request.spec.validate_exec().is_ok());

        let mut different_entrypoint = request.spec.clone();
        different_entrypoint.argv[0] = "/bin/sh".into();
        assert_eq!(
            different_entrypoint.validate_exec().err(),
            Some(SpecError::Identity)
        );

        let mut different_image = request.spec.clone();
        different_image.image_digest = valid().spec.image_digest;
        assert_eq!(
            different_image.validate_exec().err(),
            Some(SpecError::Identity)
        );

        request.spec.volume.as_mut().unwrap().read_only = true;
        assert_eq!(request.validate_oci().err(), Some(SpecError::Identity));
    }

    #[test]
    fn buildkit_worker_requires_the_pinned_native_runtime_and_writable_cache() {
        let mut spec = valid().spec;
        spec.buildkit_worker = true;
        spec.image_digest = BUILDKIT_CONFIG.into();
        spec.argv = BUILDKIT_NATIVE_ARGS
            .iter()
            .map(ToString::to_string)
            .collect();
        spec.cwd = "/".into();
        spec.uid = 0;
        spec.gid = 0;
        spec.env = vec![BUILDKIT_PATH.into()];
        spec.volume = Some(VolumeMount {
            name: "buildx_buildkit_worker_state".into(),
            target: "/var/lib/buildkit".into(),
            inode: 14,
            read_only: false,
        });
        let validate = |spec| LaunchRequest { spec, ..valid() }.validate_oci();
        assert!(validate(spec.clone()).is_ok());
        let mut overlay = spec.clone();
        overlay.argv[BUILDKIT_SNAPSHOTTER_ARG] = Snapshotter::Overlay.worker_arg().into();
        assert!(validate(overlay.clone()).is_ok());
        overlay.argv[BUILDKIT_SNAPSHOTTER_ARG] = "--oci-worker-snapshotter=auto".into();
        assert_eq!(validate(overlay).err(), Some(SpecError::Identity));

        let mut control = spec.clone();
        control.set_exec_argv(["buildctl", "debug", "workers"].map(String::from).to_vec());
        assert!(control.buildkit_worker);
        assert!(control.validate_exec().is_ok());

        let mut observer = spec.clone();
        observer.set_exec_argv(
            ["/bin/sh", "-c", "cat /sys/fs/cgroup/cpu.stat"]
                .map(String::from)
                .to_vec(),
        );
        assert!(!observer.buildkit_worker);
        assert!(observer.validate_exec().is_ok());

        let mut changed = spec.clone();
        changed.argv.push("--oci-worker-binary=runc".into());
        assert_eq!(validate(changed).err(), Some(SpecError::Identity));

        let mut changed = spec.clone();
        changed.image_digest = valid().spec.image_digest;
        assert_eq!(validate(changed).err(), Some(SpecError::Identity));

        spec.volume.as_mut().unwrap().read_only = true;
        assert_eq!(validate(spec).err(), Some(SpecError::Identity));
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

    #[test]
    fn only_matching_secondary_service_aliases_can_overlap() {
        let first = ["project-app-1", "app"].map(String::from);
        let second = ["project-app-2", "app"].map(String::from);
        assert!(valid_service_alias("project", &first[0], &first[1]));
        assert!(!valid_service_alias("project", "project-app-01", "app"));
        assert!(!network_aliases_conflict(
            &first,
            Some("project"),
            &second,
            Some("project")
        ));
        assert!(network_aliases_conflict(
            &first,
            None,
            &second,
            Some("project")
        ));
        assert!(network_aliases_conflict(
            &first,
            Some("project"),
            &second,
            Some("other")
        ));
        assert!(network_aliases_conflict(
            &first,
            Some("project"),
            &first,
            Some("project")
        ));
    }
}

use std::collections::BTreeMap;

use anyhow::{ensure, Context};
use conjet_launch_service::handshake::unhex;
use conjet_launch_service::spec::TmpfsMount;
use conjet_launch_service::spec::{
    parse_cpu_set, Account, CpuBandwidth, LaunchSpec, OpenFilesLimit, ResourceLimits,
    CPU_PERIOD_US, WORKLOAD_GID, WORKLOAD_UID,
};
use conjet_launch_service::spec::{DeniedSyscall, SyscallDenial, MAX_SYSCALL_DENIALS};
use serde_json::{json, Map, Value};

use super::Rejected;

pub(super) struct Image {
    pub(super) reference: String,
    pub(super) config_digest: String,
    pub(super) defaults: Value,
    pub(super) diff_ids: Option<Vec<String>>,
}

pub(super) fn digest(value: &str) -> bool {
    value
        .strip_prefix("sha256:")
        .is_some_and(|value| unhex::<32>(value).is_ok())
}

pub(super) fn name(value: &str) -> bool {
    let mut bytes = value.bytes();
    value.len() <= 64
        && bytes
            .next()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
}

pub(super) fn falsey(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::Bool(value) => !value,
        Value::Number(value) => value.as_f64() == Some(0.0),
        Value::String(value) => value.is_empty(),
        Value::Array(values) => values.is_empty(),
        Value::Object(values) => values.is_empty(),
    }
}

pub(super) fn object<'a>(
    value: &'a Value,
    name: &str,
) -> Result<Option<&'a Map<String, Value>>, Rejected> {
    if value.is_null() {
        Ok(None)
    } else {
        value
            .as_object()
            .map(Some)
            .ok_or_else(|| Rejected::bad(format!("invalid {name}")))
    }
}

pub(super) fn options(
    value: &Map<String, Value>,
    allow: &[&str],
    label: &str,
) -> Result<(), Rejected> {
    for (key, value) in value {
        if !allow.contains(&key.as_str()) && !falsey(value) {
            return Err(Rejected::bad(format!(
                "unsupported Docker {label}option {key}"
            )));
        }
    }
    Ok(())
}

fn strings(value: &Value) -> Result<Vec<String>, Rejected> {
    let values = value
        .as_array()
        .ok_or_else(|| Rejected::bad("expected an array of strings"))?;
    if values.len() > 32 {
        return Err(Rejected::bad("array exceeds the supported bound"));
    }
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| Rejected::bad("expected a string"))
        })
        .collect()
}

fn env(value: &Value) -> Result<BTreeMap<String, String>, Rejected> {
    let mut entries = BTreeMap::new();
    for line in strings(value)? {
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| Rejected::bad("environment requires explicit unique keys"))?;
        if entries.insert(key.to_owned(), value.to_owned()).is_some() {
            return Err(Rejected::bad("environment requires explicit unique keys"));
        }
    }
    Ok(entries)
}

fn identity(
    request: &Value,
    image: &Value,
    mapped_ids: bool,
) -> Result<(u32, u32, Option<Account>), Rejected> {
    let value = match request {
        Value::Null => image.as_str().or(image.is_null().then_some("")),
        Value::String(value) if value.is_empty() => {
            image.as_str().or(image.is_null().then_some(""))
        }
        _ => request.as_str(),
    }
    .ok_or_else(|| Rejected::bad("expected a Docker user string"))?;
    if value == "65532:65532" {
        return Ok((WORKLOAD_UID, WORKLOAD_GID, None));
    }
    if !mapped_ids {
        return Err(Rejected::bad("guest requires UID and GID 65532"));
    }
    if value.is_empty() {
        return Ok((0, 0, None));
    }
    let account = Account::parse(value).ok_or_else(|| {
        Rejected::bad("native credentials require mapped IDs or image account names")
    })?;
    if let (Ok(uid), Some(gid)) = (
        account.user.parse::<u32>(),
        account
            .group
            .as_ref()
            .and_then(|group| group.parse::<u32>().ok()),
    ) {
        return Ok((uid, gid, None));
    }
    Ok((0, 0, Some(account)))
}

impl Image {
    pub(super) fn new(reference: String, metadata: Value) -> anyhow::Result<Self> {
        let (name, pinned) = reference
            .rsplit_once('@')
            .context("image reference must be pinned")?;
        ensure!(
            !name.is_empty() && !name.contains('@') && digest(pinned),
            "image reference must be pinned"
        );
        ensure!(
            metadata["manifest_digest"].is_null() || metadata["manifest_digest"] == pinned,
            "image manifest differs from the staging receipt"
        );
        let config_digest = metadata["config_digest"]
            .as_str()
            .filter(|value| digest(value))
            .context("missing OCI config digest")?
            .to_owned();
        let defaults = metadata["process"].clone();
        ensure!(defaults.is_object(), "missing OCI process defaults");
        let diff_ids = serde_json::from_value::<Option<Vec<String>>>(metadata["diff_ids"].clone())
            .context("invalid staged rootfs diff IDs")?;
        ensure!(
            diff_ids.as_ref().is_none_or(|ids| {
                ids.len() <= super::super::oci_stage::LAYERS_LIMIT
                    && ids.iter().all(|id| digest(id))
            }),
            "invalid staged rootfs diff IDs"
        );
        Ok(Self {
            reference,
            config_digest,
            defaults,
            diff_ids,
        })
    }

    pub(super) fn process(&self, data: &Value, mapped_ids: bool) -> Result<Value, Rejected> {
        let config = object(data, "Docker request")?
            .ok_or_else(|| Rejected::bad("expected a Docker request object"))?;
        let host = &data["HostConfig"];
        let host_options = object(host, "Docker HostConfig")?
            .ok_or_else(|| Rejected::bad("expected Docker HostConfig"))?;
        if data["Image"] != self.reference || host["NetworkMode"] != "none" {
            return Err(Rejected::bad(
                "invalid staged image or normalized network mode",
            ));
        }
        options(
            config,
            &[
                "Image",
                "User",
                "Cmd",
                "Entrypoint",
                "Env",
                "WorkingDir",
                "HostConfig",
                "AttachStdout",
                "AttachStderr",
                "AttachStdin",
                "OpenStdin",
                "StdinOnce",
                "Tty",
                "Labels",
                "Healthcheck",
                "NetworkingConfig",
            ],
            "",
        )?;
        options(
            host_options,
            &[
                "NetworkMode",
                "Memory",
                "MemorySwap",
                "MemoryReservation",
                "NanoCpus",
                "CpuPeriod",
                "CpuQuota",
                "CpusetCpus",
                "PidsLimit",
                "Ulimits",
                "AutoRemove",
                "ConsoleSize",
                "RestartPolicy",
                "LogConfig",
                "MemorySwappiness",
                "CapDrop",
                "CapAdd",
                "SecurityOpt",
                "ReadonlyRootfs",
                "Tmpfs",
            ],
            "HostConfig ",
        )?;
        if !host["AutoRemove"].is_null() && !host["AutoRemove"].is_boolean() {
            return Err(Rejected::bad("invalid AutoRemove"));
        }
        if !host["ReadonlyRootfs"].is_null() && !host["ReadonlyRootfs"].is_boolean() {
            return Err(Rejected::bad("invalid ReadonlyRootfs"));
        }
        if !(host["CapDrop"].is_null()
            || host["CapDrop"] == json!([])
            || host["CapDrop"] == json!(["ALL"]))
        {
            return Err(Rejected::bad("only dropping all capabilities is supported"));
        }
        let docker_net_admin = match &host["CapAdd"] {
            value if value.is_null() || value == &json!([]) => false,
            value if value == &json!(["NET_ADMIN"]) || value == &json!(["CAP_NET_ADMIN"]) => true,
            _ => {
                return Err(Rejected::bad(
                    "only NET_ADMIN can be added to native Docker workloads",
                ))
            }
        };
        let syscall_denials = security_options(&host["SecurityOpt"])?;
        if !host["MemorySwappiness"].is_null() && host["MemorySwappiness"].as_i64() != Some(-1) {
            return Err(Rejected::bad("explicit memory swappiness is unsupported"));
        }
        super::restart_policy::Policy::parse(&host["RestartPolicy"])?;
        let log = &host["LogConfig"];
        if object(log, "log configuration")?.is_some()
            && ((!log["Type"].is_null() && log["Type"] != "") || !falsey(&log["Config"]))
        {
            return Err(Rejected::bad("explicit log drivers are unsupported"));
        }
        let network = &data["NetworkingConfig"];
        if let Some(config) = object(network, "networking configuration")? {
            options(config, &["EndpointsConfig"], "networking ")?;
        }
        if let Some(endpoints) = object(&network["EndpointsConfig"], "network endpoints")? {
            if endpoints.iter().any(|(name, value)| {
                name != "none"
                    || !value
                        .as_object()
                        .is_some_and(|fields| fields.values().all(falsey))
            }) {
                return Err(Rejected::bad("only the no-network endpoint is supported"));
            }
        }
        let values = |key| {
            if data[key].is_null() {
                &self.defaults[key]
            } else {
                &data[key]
            }
        };
        let mut argv = strings(values("Entrypoint"))?;
        argv.extend(strings(values("Cmd"))?);
        let mut environment = env(&self.defaults["Env"])?;
        if !data["Env"].is_null() {
            environment.extend(env(&data["Env"])?);
        }
        let working_directory = match data["WorkingDir"].as_str() {
            Some("") | None if data["WorkingDir"].is_null() || data["WorkingDir"] == "" => {
                &self.defaults["WorkingDir"]
            }
            _ => &data["WorkingDir"],
        };
        let cwd = working_directory
            .as_str()
            .ok_or_else(|| Rejected::bad("invalid working directory"))?;
        let (uid, gid, account) = identity(&data["User"], &self.defaults["User"], mapped_ids)?;
        let flags = ["AttachStdin", "OpenStdin", "StdinOnce"];
        if !data["Tty"].is_null() && !data["Tty"].is_boolean() {
            return Err(Rejected::bad("invalid Docker Tty setting"));
        }
        let open_stdin = data["OpenStdin"] == true;
        if flags
            .iter()
            .any(|name| !data[name].is_null() && !data[name].is_boolean())
            || (["AttachStdin", "StdinOnce"]
                .iter()
                .any(|name| data[name] == true)
                && !open_stdin)
        {
            return Err(Rejected::bad("invalid native stdin options"));
        }
        let limits = resource_limits(host)?;
        let spec = LaunchSpec {
            retained_layer: None,
            rootfs_read_only: host["ReadonlyRootfs"] == true,
            image_digest: self.config_digest.clone(),
            argv,
            env: environment
                .into_iter()
                .map(|(key, value)| format!("{key}={value}"))
                .collect(),
            cwd: cwd.into(),
            uid,
            gid,
            account,
            network: "none".into(),
            network_alias: None,
            secondary_network_alias: None,
            network_alias_project: None,
            volume: None,
            bind: None,
            binds: Vec::new(),
            tmpfs: tmpfs_mounts(&host["Tmpfs"])?,
            build_snapshot: None,
            limits,
            docker_resource_defaults: limits.has_unlimited(),
            docker_default_capabilities: host["CapDrop"] != json!(["ALL"]),
            docker_net_admin,
            syscall_denials,
            memory_swap_disabled: false,
            open_files_limit: open_files_limit(&host["Ulimits"])?,
            open_stdin,
            tty: data["Tty"] == true,
            redis_bootstrap: false,
            buildkit_worker: false,
        };
        spec.validate_exec()
            .map_err(|error| Rejected::bad(error.to_string()))?;
        serde_json::to_value(spec)
            .map_err(|_| Rejected::internal("cannot encode native process spec"))
    }
}

fn tmpfs_mounts(value: &Value) -> Result<Vec<TmpfsMount>, Rejected> {
    let Some(mounts) = object(value, "Docker Tmpfs map")? else {
        return Ok(Vec::new());
    };
    if mounts.len() > TmpfsMount::MAX_MOUNTS {
        return Err(Rejected::bad("too many native tmpfs mounts"));
    }
    mounts
        .iter()
        .map(|(target, value)| {
            let value = value
                .as_str()
                .ok_or_else(|| Rejected::bad("invalid Docker tmpfs options"))?;
            let mut mount = TmpfsMount {
                target: target.clone(),
                size_bytes: None,
                mode: 0o1777,
                uid: 0,
                gid: 0,
                read_only: false,
            };
            let mut keys = std::collections::BTreeSet::new();
            for option in value.split(',').filter(|item| !item.is_empty()) {
                let (key, data) = option.split_once('=').unwrap_or((option, ""));
                let kind = match key {
                    "ro" | "rw" => "access",
                    _ => key,
                };
                if !keys.insert(kind) {
                    return Err(Rejected::bad("duplicate Docker tmpfs option"));
                }
                let invalid = || Rejected::bad("invalid Docker tmpfs option value");
                match key {
                    "size" => {
                        let (digits, scale) = match data.as_bytes().last() {
                            Some(b'k' | b'K') => (&data[..data.len() - 1], 1024),
                            Some(b'm' | b'M') => (&data[..data.len() - 1], 1024 * 1024),
                            Some(b'g' | b'G') => (&data[..data.len() - 1], 1024 * 1024 * 1024),
                            _ => (data, 1),
                        };
                        mount.size_bytes = Some(
                            digits
                                .parse::<u64>()
                                .ok()
                                .and_then(|size| size.checked_mul(scale))
                                .ok_or_else(invalid)?,
                        );
                    }
                    "mode" => mount.mode = u32::from_str_radix(data, 8).map_err(|_| invalid())?,
                    "uid" => mount.uid = data.parse().map_err(|_| invalid())?,
                    "gid" => mount.gid = data.parse().map_err(|_| invalid())?,
                    "ro" if data.is_empty() => mount.read_only = true,
                    "rw" | "nosuid" | "nodev" | "noexec" if data.is_empty() => {}
                    _ => return Err(Rejected::bad("unsupported Docker tmpfs option")),
                }
            }
            if !mount.valid() {
                return Err(Rejected::bad(
                    "native Docker tmpfs options are outside their bounds",
                ));
            }
            Ok(mount)
        })
        .collect()
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SeccompProfile {
    default_action: String,
    #[serde(default)]
    architectures: Vec<String>,
    #[serde(default)]
    syscalls: Vec<SeccompRule>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SeccompRule {
    names: Vec<DeniedSyscall>,
    action: String,
    errno_ret: Option<u16>,
}

fn security_options(data: &Value) -> Result<Vec<SyscallDenial>, Rejected> {
    if data.is_null() {
        return Ok(Vec::new());
    }
    let options = strings(data)?;
    if options.len() > 2 {
        return Err(Rejected::bad("too many native Docker security options"));
    }
    let mut no_new_privileges = false;
    let mut seccomp = None;
    for option in &options {
        match option.as_str() {
            "no-new-privileges" | "no-new-privileges=true" | "no-new-privileges:true"
                if !no_new_privileges =>
            {
                no_new_privileges = true
            }
            option if seccomp.is_none() => {
                let json = option
                    .strip_prefix("seccomp=")
                    .or_else(|| option.strip_prefix("seccomp:"))
                    .filter(|value| value.len() <= 8192)
                    .ok_or_else(|| Rejected::bad("unsupported native Docker security option"))?;
                seccomp = Some(
                    serde_json::from_str::<SeccompProfile>(json)
                        .map_err(|_| Rejected::bad("invalid or unsupported seccomp profile"))?,
                );
            }
            _ => {
                return Err(Rejected::bad(
                    "duplicate or unsupported native Docker security option",
                ))
            }
        }
    }
    let Some(profile) = seccomp else {
        return Ok(Vec::new());
    };
    if profile.default_action != "SCMP_ACT_ALLOW"
        || !matches!(profile.architectures.as_slice(), [] | [_])
        || profile
            .architectures
            .iter()
            .any(|arch| arch != "SCMP_ARCH_AARCH64")
    {
        return Err(Rejected::bad(
            "native seccomp profiles must add Linux ARM64 syscall denials",
        ));
    }
    let mut denials = Vec::<SyscallDenial>::new();
    for rule in profile.syscalls {
        let errno = rule.errno_ret.unwrap_or(1);
        if rule.action != "SCMP_ACT_ERRNO" || !(1..=4095).contains(&errno) || rule.names.is_empty()
        {
            return Err(Rejected::bad("invalid or unsupported native seccomp rule"));
        }
        for name in rule.names {
            if denials.len() >= MAX_SYSCALL_DENIALS || denials.iter().any(|rule| rule.name == name)
            {
                return Err(Rejected::bad("duplicate or excessive native seccomp rules"));
            }
            denials.push(SyscallDenial { name, errno });
        }
    }
    Ok(denials)
}

pub(super) fn default_memory_swap(host: &mut Value) {
    if !host["MemorySwap"].is_null() && host["MemorySwap"] != 0 {
        return;
    }
    if let Some(total) = host["Memory"]
        .as_i64()
        .filter(|bytes| *bytes > 0)
        .and_then(|bytes| bytes.checked_mul(2))
    {
        host["MemorySwap"] = json!(total);
    }
}

pub(super) fn resource_limits(host: &Value) -> Result<ResourceLimits, Rejected> {
    let limits = resources(host)?;
    if !limits.valid_docker() {
        return Err(Rejected::bad(
            "native Docker resource limits are outside their bounds",
        ));
    }
    Ok(limits)
}

fn open_files_limit(value: &Value) -> Result<Option<OpenFilesLimit>, Rejected> {
    if value.is_null() {
        return Ok(None);
    }
    let options = value
        .as_array()
        .ok_or_else(|| Rejected::bad("expected a Docker Ulimits array"))?;
    let option = match options.as_slice() {
        [] => return Ok(None),
        [option] if option["Name"] == "nofile" => option,
        _ => return Err(Rejected::bad("only a single nofile ulimit is supported")),
    };
    let limit = OpenFilesLimit {
        soft: option["Soft"]
            .as_u64()
            .ok_or_else(|| Rejected::bad("invalid nofile soft limit"))?,
        hard: option["Hard"]
            .as_u64()
            .ok_or_else(|| Rejected::bad("invalid nofile hard limit"))?,
    };
    if !limit.valid() {
        return Err(Rejected::bad("invalid nofile bounds"));
    }
    Ok(Some(limit))
}

fn resources(host: &Value) -> Result<ResourceLimits, Rejected> {
    let read = |key| match &host[key] {
        Value::Null => Ok(0),
        value => value
            .as_u64()
            .ok_or_else(|| Rejected::bad(format!("invalid native Docker {key}"))),
    };
    let nano_cpus = read("NanoCpus")?;
    if nano_cpus % 1_000_000 != 0 {
        return Err(Rejected::bad("native CPU limits must use whole millicores"));
    }
    let cpu_millicores = u32::try_from(nano_cpus / 1_000_000)
        .map_err(|_| Rejected::bad("native CPU limit exceeds its bound"))?;
    let period = read("CpuPeriod")?;
    let quota = match &host["CpuQuota"] {
        Value::Null => 0,
        value => value
            .as_i64()
            .filter(|quota| *quota >= -1)
            .ok_or_else(|| Rejected::bad("invalid native Docker CpuQuota"))?,
    };
    let cpu_bandwidth = if period != 0 || quota != 0 {
        if nano_cpus != 0 {
            return Err(Rejected::bad("NanoCpus conflicts with CPU period or quota"));
        }
        Some(CpuBandwidth {
            period_us: if period == 0 {
                CPU_PERIOD_US
            } else {
                u32::try_from(period).map_err(|_| Rejected::bad("invalid CPU period"))?
            },
            quota_us: u32::try_from(quota.max(0))
                .map_err(|_| Rejected::bad("invalid CPU quota"))?,
        })
    } else {
        None
    };
    let cpu_affinity = match &host["CpusetCpus"] {
        Value::Null => None,
        Value::String(value) if value.is_empty() => None,
        Value::String(value) => Some(
            parse_cpu_set(value)
                .filter(|mask| mask >> super::super::session::NATIVE_VCPU_COUNT == 0)
                .ok_or_else(|| Rejected::bad("CpusetCpus requests an unavailable guest CPU"))?,
        ),
        _ => return Err(Rejected::bad("invalid native Docker CpusetCpus")),
    };
    let pids = if host["PidsLimit"].as_i64() == Some(-1) {
        0
    } else {
        u32::try_from(read("PidsLimit")?)
            .map_err(|_| Rejected::bad("native PID limit exceeds its bound"))?
    };
    let memory_bytes = read("Memory")?;
    let memory_swap_bytes = match &host["MemorySwap"] {
        Value::Null => None,
        value if value.as_i64() == Some(-1) => None,
        value if value.as_i64() == Some(0) => None,
        value => Some(
            value
                .as_u64()
                .filter(|total| *total <= i64::MAX as u64 && memory_bytes > 0)
                .and_then(|total| total.checked_sub(memory_bytes))
                .ok_or_else(|| {
                    Rejected::bad("MemorySwap requires a valid memory-plus-swap total")
                })?,
        ),
    };
    Ok(ResourceLimits {
        memory_bytes,
        memory_reservation_bytes: read("MemoryReservation")?,
        memory_swap_bytes,
        pids,
        cpu_millicores,
        cpu_bandwidth,
        cpu_affinity,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_explicit_and_omitted_docker_limits_without_clamping() {
        let control = resources(&json!({})).unwrap();
        assert_eq!(
            control,
            ResourceLimits {
                memory_bytes: 0,
                pids: 0,
                cpu_millicores: 0,
                cpu_bandwidth: None,
                cpu_affinity: None,
                memory_reservation_bytes: 0,
                memory_swap_bytes: None,
            }
        );
        let service = resources(&json!({"Memory":134217728, "PidsLimit":64,
            "NanoCpus":500000000}))
        .unwrap();
        assert_eq!(
            service,
            ResourceLimits {
                memory_bytes: 134217728,
                pids: 64,
                cpu_millicores: 500,
                cpu_bandwidth: None,
                cpu_affinity: None,
                memory_reservation_bytes: 0,
                memory_swap_bytes: None,
            }
        );
        assert_eq!(resources(&json!({"PidsLimit":-1})).unwrap().pids, 0);
        assert!(resources(&json!({"NanoCpus":500000001})).is_err());
        assert!(resources(&json!({"PidsLimit":-2})).is_err());
        assert!(resources(&json!({"Memory":-1})).is_err());
    }

    #[test]
    fn docker_default_capabilities_respect_drop_all_and_no_new_privileges() {
        let reference = format!("docker.io/library/alpine@sha256:{}", "a".repeat(64));
        let image = Image::new(
            reference.clone(),
            json!({"config_digest":format!("sha256:{}", "b".repeat(64)),
            "process":{"Cmd":["/bin/true"],"Entrypoint":[],"Env":[],"WorkingDir":"/","User":""}}),
        )
        .unwrap();
        let mut input = json!({"Image":reference, "HostConfig":{"NetworkMode":"none", "SecurityOpt":["no-new-privileges:true"]}});
        let defaults: LaunchSpec =
            serde_json::from_value(image.process(&input, true).unwrap()).unwrap();
        assert!(defaults.docker_default_capabilities);
        input["HostConfig"]["CapDrop"] = json!(["ALL"]);
        let dropped: LaunchSpec =
            serde_json::from_value(image.process(&input, true).unwrap()).unwrap();
        assert!(!dropped.docker_default_capabilities);
        input["HostConfig"]["CapAdd"] = json!(["SYS_ADMIN"]);
        assert!(image.process(&input, true).is_err());
    }

    #[test]
    fn resolves_the_requested_pair_before_the_image_default() {
        assert_eq!(
            identity(&Value::Null, &json!(""), true).unwrap(),
            (0, 0, None)
        );
        assert_eq!(
            identity(&json!(""), &json!("12:34"), true).unwrap(),
            (12, 34, None)
        );
        assert_eq!(
            identity(&json!("0:1"), &json!("12:34"), true).unwrap(),
            (0, 1, None)
        );
        assert_eq!(
            identity(&json!("65532:65532"), &json!(""), false).unwrap(),
            (65532, 65532, None)
        );
    }

    #[test]
    fn rejects_unmapped_ambiguous_and_unnegotiated_identities() {
        for value in ["65536:0", "0:65536", "1:", "+1:2", "1:2:3"] {
            assert!(identity(&json!(value), &Value::Null, true).is_err());
        }
        assert!(identity(&Value::Null, &json!(""), false).is_err());
        assert!(identity(&json!(123), &json!(""), true).is_err());
        assert_eq!(
            identity(&json!(""), &json!("node:node"), true).unwrap().2,
            Account::parse("node:node")
        );
    }
}

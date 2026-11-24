use std::collections::BTreeMap;

use anyhow::{ensure, Context};
use conjet_launch_service::handshake::unhex;
use conjet_launch_service::spec::{
    Account, LaunchSpec, ResourceLimits, WORKLOAD_GID, WORKLOAD_UID,
};
use serde_json::{json, Map, Value};

use super::Rejected;

pub(super) struct Image {
    pub(super) reference: String,
    pub(super) config_digest: String,
    pub(super) defaults: Value,
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
        Ok(Self {
            reference,
            config_digest,
            defaults,
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
                "NanoCpus",
                "PidsLimit",
                "AutoRemove",
                "ConsoleSize",
                "RestartPolicy",
                "LogConfig",
                "MemorySwappiness",
                "CapDrop",
                "SecurityOpt",
            ],
            "HostConfig ",
        )?;
        if !host["AutoRemove"].is_null() && !host["AutoRemove"].is_boolean() {
            return Err(Rejected::bad("invalid AutoRemove"));
        }
        if !(host["CapDrop"].is_null()
            || host["CapDrop"] == json!([])
            || host["CapDrop"] == json!(["ALL"]))
        {
            return Err(Rejected::bad("only dropping all capabilities is supported"));
        }
        let security = &host["SecurityOpt"];
        if !(security.is_null()
            || security == &json!([])
            || security == &json!(["no-new-privileges"])
            || security == &json!(["no-new-privileges=true"]))
        {
            return Err(Rejected::bad("only no-new-privileges is supported"));
        }
        if !host["MemorySwappiness"].is_null() && host["MemorySwappiness"].as_i64() != Some(-1) {
            return Err(Rejected::bad("explicit memory swappiness is unsupported"));
        }
        let restart = &host["RestartPolicy"];
        if let Some(restart_opts) = object(restart, "restart policy")? {
            options(restart_opts, &["Name"], "restart policy ")?;
            if !restart["Name"].is_null() && !matches!(restart["Name"].as_str(), Some("" | "no")) {
                return Err(Rejected::bad("restart policies are unsupported"));
            }
        }
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
        let limits = resources(host)?;
        let memory_swap_disabled = match &host["MemorySwap"] {
            Value::Null => false,
            value if value.as_u64() == Some(0) => false,
            value if value.as_u64() == Some(limits.memory_bytes) => true,
            _ => {
                return Err(Rejected::bad(
                    "native MemorySwap must equal the requested memory limit",
                ))
            }
        };
        let spec = LaunchSpec {
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
            volume: None,
            bind: None,
            build_snapshot: None,
            limits,
            docker_resource_defaults: limits.has_unlimited(),
            memory_swap_disabled,
            open_stdin,
        };
        spec.validate_exec()
            .map_err(|error| Rejected::bad(error.to_string()))?;
        serde_json::to_value(spec)
            .map_err(|_| Rejected::internal("cannot encode native process spec"))
    }
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
    let pids = if host["PidsLimit"].as_i64() == Some(-1) {
        0
    } else {
        u32::try_from(read("PidsLimit")?)
            .map_err(|_| Rejected::bad("native PID limit exceeds its bound"))?
    };
    Ok(ResourceLimits {
        memory_bytes: read("Memory")?,
        pids,
        cpu_millicores,
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
                cpu_millicores: 0
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
                cpu_millicores: 500
            }
        );
        assert_eq!(resources(&json!({"PidsLimit":-1})).unwrap().pids, 0);
        assert!(resources(&json!({"NanoCpus":500000001})).is_err());
        assert!(resources(&json!({"PidsLimit":-2})).is_err());
        assert!(resources(&json!({"Memory":-1})).is_err());
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

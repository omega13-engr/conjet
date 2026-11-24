use std::collections::BTreeMap;

use anyhow::{ensure, Context};
use conjet_launch_service::handshake::unhex;
use conjet_launch_service::spec::{LaunchSpec, NATIVE_LIMITS, WORKLOAD_GID, WORKLOAD_UID};
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

    pub(super) fn process(&self, data: &Value) -> Result<Value, Rejected> {
        let config = object(data, "Docker request")?
            .ok_or_else(|| Rejected::bad("expected a Docker request object"))?;
        let host = &data["HostConfig"];
        let host_options = object(host, "Docker HostConfig")?
            .ok_or_else(|| Rejected::bad("expected Docker HostConfig"))?;
        if data["Image"] != self.reference
            || data["User"] != "65532:65532"
            || host["NetworkMode"] != "none"
            || host["Memory"].as_u64() != Some(NATIVE_LIMITS.memory_bytes)
            || host["NanoCpus"].as_u64()
                != Some(u64::from(NATIVE_LIMITS.cpu_millicores) * 1_000_000)
            || host["PidsLimit"].as_u64() != Some(u64::from(NATIVE_LIMITS.pids))
        {
            return Err(Rejected::bad(
                "require the staged image, --network none, fixed UID/GID and 16 MiB/4 PIDs/0.5 CPU",
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
                "Labels",
                "NetworkingConfig",
            ],
            "",
        )?;
        options(
            host_options,
            &[
                "NetworkMode",
                "Memory",
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
        let spec = LaunchSpec {
            image_digest: self.config_digest.clone(),
            argv,
            env: environment
                .into_iter()
                .map(|(key, value)| format!("{key}={value}"))
                .collect(),
            cwd: cwd.into(),
            uid: WORKLOAD_UID,
            gid: WORKLOAD_GID,
            network: "none".into(),
            network_alias: None,
            secondary_network_alias: None,
            volume: None,
            limits: NATIVE_LIMITS,
        };
        spec.validate()
            .map_err(|error| Rejected::bad(error.to_string()))?;
        serde_json::to_value(spec)
            .map_err(|_| Rejected::internal("cannot encode native process spec"))
    }
}

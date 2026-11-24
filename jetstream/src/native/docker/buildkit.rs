use std::fs::File;
use std::io::Read;

use serde_json::Value;

use super::{request, volume, Rejected};

pub(super) const IMAGE: &str =
    "docker.io/moby/buildkit@sha256:771795ae105f698c5a354aecb1a1be2cf1f1c17c97b348c8b19f7cded83fb97c";

pub(super) fn requested(
    name: &str,
    config: &Value,
    mount: Option<&volume::Mount<'_>>,
) -> Result<bool, Rejected> {
    let host = &config["HostConfig"];
    if host["Privileged"] != true || config["Image"] != IMAGE {
        return Ok(false);
    }
    let options = request::object(host, "BuildKit worker HostConfig")?
        .ok_or_else(|| Rejected::bad("missing BuildKit worker HostConfig"))?;
    request::options(
        options,
        &[
            "Privileged",
            "Init",
            "RestartPolicy",
            "Mounts",
            "NetworkMode",
            "CgroupParent",
            "UsernsMode",
            "ConsoleSize",
            "LogConfig",
        ],
        "native BuildKit worker ",
    )?;
    let restart = &host["RestartPolicy"];
    let restart_fields = request::object(restart, "BuildKit restart policy")?;
    if let Some(fields) = restart_fields {
        request::options(
            fields,
            &["Name", "MaximumRetryCount"],
            "BuildKit restart policy ",
        )?;
    }
    let cache = format!("{name}_state");
    let valid_flags = request::falsey(&config["Cmd"])
        || config["Cmd"] == serde_json::json!(["--allow-insecure-entitlement=network.host"]);
    if !name.starts_with("buildx_buildkit_")
        || host["Init"] != true
        || !(host["ConsoleSize"].is_null() || host["ConsoleSize"] == serde_json::json!([0, 0]))
        || !request::falsey(&host["CgroupParent"])
        || !request::falsey(&host["UsernsMode"])
        || !matches!(
            host["NetworkMode"].as_str(),
            None | Some("" | "bridge" | "default")
        )
        || !matches!(
            restart["Name"].as_str(),
            None | Some("" | "no" | "unless-stopped")
        )
        || (!restart["MaximumRetryCount"].is_null() && restart["MaximumRetryCount"] != 0)
        || !valid_flags
        || [
            "User",
            "Entrypoint",
            "Env",
            "WorkingDir",
            "Healthcheck",
            "NetworkingConfig",
            "AttachStdin",
            "OpenStdin",
            "StdinOnce",
        ]
        .iter()
        .any(|key| !request::falsey(&config[*key]))
        || !mount.is_some_and(|mount| {
            mount.name == cache && mount.target == "/var/lib/buildkit" && !mount.read_only
        })
    {
        return Err(Rejected::bad(
            "unsupported pinned BuildKit worker configuration",
        ));
    }
    Ok(true)
}

pub(super) fn accept_empty_config(path: &str, archive: &File) -> Result<(), Rejected> {
    if !matches!(path, "/etc" | "/etc/") {
        return Err(Rejected::bad(
            "BuildKit config copy requires the worker's /etc",
        ));
    }
    let mut bytes = Vec::new();
    archive
        .take(1025)
        .read_to_end(&mut bytes)
        .map_err(|error| Rejected::bad(format!("cannot read BuildKit config archive: {error}")))?;
    if bytes.len() != 1024 || bytes.iter().any(|&byte| byte != 0) {
        return Err(Rejected::bad(
            "pinned BuildKit bootstrap accepts only an empty config archive",
        ));
    }
    Ok(())
}

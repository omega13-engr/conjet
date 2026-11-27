use std::fs::File;
use std::io::Read;

use serde_json::Value;

use super::{request, volume, Rejected};

pub(super) const IMAGE: &str =
    "docker.io/moby/buildkit@sha256:771795ae105f698c5a354aecb1a1be2cf1f1c17c97b348c8b19f7cded83fb97c";

const DEFAULT_MANIFEST: &str =
    "sha256:dcd3c9ec3a20b8a38ef81bd2cc09e7e89d47d48b6dc29145755e18cc2c9cca26";

fn approved_config(manifest: &str) -> Option<&'static str> {
    use conjet_launch_service::spec::{BUILDKIT_CONFIG, BUILDKIT_DEFAULT_CONFIG};
    if manifest == IMAGE.rsplit_once('@').expect("pinned worker digest").1 {
        Some(BUILDKIT_CONFIG)
    } else if manifest == DEFAULT_MANIFEST {
        Some(BUILDKIT_DEFAULT_CONFIG)
    } else {
        None
    }
}

pub(super) fn approved_manifest(manifest: &str) -> bool {
    approved_config(manifest).is_some()
}

pub(super) fn requested(
    name: &str,
    config: &Value,
    reference: &str,
    mount: Option<&volume::Mount<'_>>,
) -> Result<Option<&'static str>, Rejected> {
    let host = &config["HostConfig"];
    if host["Privileged"] != true {
        return Ok(None);
    }
    let (_, manifest) = reference
        .rsplit_once('@')
        .filter(|(repo, _)| super::public_registry::hub_repository(repo) == "moby/buildkit")
        .ok_or_else(|| Rejected::bad("privileged containers require a verified BuildKit worker"))?;
    let expected = approved_config(manifest)
        .ok_or_else(|| Rejected::bad("privileged containers require a verified BuildKit worker"))?;
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
    Ok(Some(expected))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_admission_binds_the_resolved_manifest_and_cache_policy() {
        let config = serde_json::json!({
            "Image":"moby/buildkit:buildx-stable-1",
            "HostConfig":{"Privileged":true,"Init":true}
        });
        let name = "buildx_buildkit_fresh0";
        let cache = volume::Mount {
            name: "buildx_buildkit_fresh0_state",
            target: "/var/lib/buildkit",
            read_only: false,
        };
        let resolved = format!("index.docker.io/moby/buildkit@{DEFAULT_MANIFEST}");
        assert_eq!(
            requested(name, &config, &resolved, Some(&cache)).unwrap(),
            Some(conjet_launch_service::spec::BUILDKIT_DEFAULT_CONFIG)
        );
        for reference in [
            config["Image"].as_str().unwrap(),
            "docker.io/moby/buildkit@sha256:0000",
            &format!("docker.io/library/alpine@{DEFAULT_MANIFEST}"),
        ] {
            assert!(requested(name, &config, reference, Some(&cache)).is_err());
        }
        assert!(requested(name, &config, &resolved, None).is_err());
        let mut with_bypass = config;
        with_bypass["HostConfig"]["PidMode"] = "host".into();
        assert!(requested(name, &with_bypass, &resolved, Some(&cache)).is_err());
    }
}

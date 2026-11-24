//! Intake profile for the pinned BuildKit 0.23.2 Linux ARM64 OCI worker.

use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::{Snapshot, valid_id};
use crate::handshake::hex;
use crate::spec::{LaunchSpec, NATIVE_LIMITS, WORKLOAD_GID, WORKLOAD_UID};

pub(super) const EXECUTOR: &str = "/run/conjet/buildkit/worker/runc-native/executor";
pub(crate) const MAX_CONFIG_BYTES: u64 = 64 * 1024;

// Canonical policy shared by three independently generated pinned bundles.
// Dynamic process fields and validated worker-owned paths are excluded.
const POLICY: &str = "65a0504290aa0fed601cf5f19b860b77d1ba682595b92c69b8909bfc4cfd4224";

#[derive(Serialize)]
pub(crate) struct BundleWitness {
    snapshot: Snapshot,
    policy_sha256: &'static str,
    mount_count: usize,
}

pub(crate) struct WorkerBundle {
    pub(crate) witness: BundleWitness,
    pub(crate) spec: LaunchSpec,
    pub(crate) hosts_file: String,
}

pub(crate) fn parse(
    bytes: &[u8],
    snapshot: Snapshot,
    image_digest: &str,
) -> Result<WorkerBundle, &'static str> {
    if bytes.len() as u64 > MAX_CONFIG_BYTES || !valid_id(&snapshot.id) {
        return Err("invalid build bundle bounds");
    }
    let mut bundle: Value =
        serde_json::from_slice(bytes).map_err(|_| "invalid build bundle JSON")?;
    let root = format!("{EXECUTOR}/{}/rootfs", snapshot.id);
    if bundle["root"]["path"].as_str() != Some(root.as_str())
        || bundle["linux"]["cgroupsPath"].as_str() != Some(&format!("/buildkit/{}", snapshot.id))
    {
        return Err("build bundle paths do not match the snapshot");
    }
    bundle["root"]["path"] = "".into();
    bundle["linux"]["cgroupsPath"] = "".into();

    let mounts = bundle["mounts"]
        .as_array_mut()
        .ok_or("missing build mounts")?;
    let mut hosts_file = None;
    for mount in mounts.iter_mut() {
        if mount["destination"] == "/etc/hosts" {
            let suffix = mount["source"]
                .as_str()
                .and_then(|source| source.strip_prefix(EXECUTOR))
                .and_then(|name| name.strip_prefix("/hosts."))
                .filter(|suffix| valid_id(suffix));
            if suffix.is_none() {
                return Err("hosts file is outside the pinned worker");
            }
            hosts_file = mount["source"].as_str().map(str::to_owned);
            mount["source"] = "".into();
        }
    }
    let mount_count = mounts.len();
    let process = bundle["process"]
        .as_object_mut()
        .ok_or("missing build process")?;
    let mut field = |name| process.remove(name).ok_or("missing build process field");
    let mut selected = snapshot.clone();
    selected.bundle_policy = true;
    let spec = LaunchSpec {
        docker_resource_defaults: false,
        memory_swap_disabled: false,
        open_stdin: false,
        redis_bootstrap: false,
        buildkit_worker: false,
        image_digest: image_digest.to_owned(),
        argv: serde_json::from_value(field("args")?).map_err(|_| "invalid build argv")?,
        env: serde_json::from_value(field("env")?).map_err(|_| "invalid build environment")?,
        cwd: serde_json::from_value(field("cwd")?)
            .map_err(|_| "invalid build working directory")?,
        uid: WORKLOAD_UID,
        gid: WORKLOAD_GID,
        account: None,
        network: "none".into(),
        network_alias: None,
        secondary_network_alias: None,
        network_alias_project: None,
        volume: None,
        bind: None,
        build_snapshot: Some(selected),
        limits: NATIVE_LIMITS,
    };
    spec.validate()
        .map_err(|_| "build process violates native launch limits")?;

    // The pinned preset includes user credentials, namespaces, device rules,
    // seccomp, capabilities, and the complete ordered mount contract.
    bundle.sort_all_objects();
    let policy = serde_json::to_vec(&bundle).map_err(|_| "invalid build policy")?;
    if hex(&Sha256::digest(policy)) != POLICY {
        return Err("unsupported BuildKit OCI preset");
    }
    Ok(WorkerBundle {
        witness: BundleWitness {
            snapshot,
            policy_sha256: POLICY,
            mount_count,
        },
        spec,
        hosts_file: hosts_file.ok_or("missing worker hosts file")?,
    })
}

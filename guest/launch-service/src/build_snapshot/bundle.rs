//! Intake profile for the pinned BuildKit 0.23.2 Linux ARM64 OCI worker.

use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::{Snapshot, Snapshotter, valid_id};
use crate::handshake::hex;
use crate::spec::{LaunchSpec, NATIVE_LIMITS, ResourceLimits, WORKLOAD_GID, WORKLOAD_UID};

pub(super) const EXECUTOR: &str = "/run/conjet/buildkit/worker/runc-native/executor";
pub(crate) const LIVE_GROUPS: &[u32] = &[0, 1, 2, 3, 4, 6, 10, 11, 20, 26, 27];
pub(crate) const MAX_CONFIG_BYTES: u64 = 64 * 1024;

// Canonical policy shared by three independently generated pinned bundles.
// Dynamic process fields and validated worker-owned paths are excluded.
const POLICY: &str = "65a0504290aa0fed601cf5f19b860b77d1ba682595b92c69b8909bfc4cfd4224";
const LIVE_POLICY: &str = "90e0f262862d2b34e3cf86f74011abeec843b7f2ed2552d77ef2ac4d16913dd6";

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
    let mut selected = snapshot.clone();
    selected.bundle_policy = true;
    let spec = process_spec(
        &mut bundle,
        selected,
        image_digest,
        (WORKLOAD_UID, WORKLOAD_GID),
    )?;

    // The pinned preset includes user credentials, namespaces, device rules,
    // seccomp, capabilities, and the complete ordered mount contract.
    if policy_sha256(&mut bundle)? != POLICY {
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

pub(crate) fn parse_live(
    bytes: &[u8],
    snapshot: Snapshot,
    image_digest: &str,
    snapshotter: Snapshotter,
) -> Result<(LaunchSpec, String), &'static str> {
    if bytes.len() as u64 > MAX_CONFIG_BYTES || !snapshot.live_worker || !valid_id(&snapshot.id) {
        return Err("invalid live build bundle bounds");
    }
    let mut bundle: Value =
        serde_json::from_slice(bytes).map_err(|_| "invalid live BuildKit bundle JSON")?;
    let executor = snapshotter.executor();
    let root = format!("{executor}/{}/rootfs", snapshot.id);
    if bundle["root"]["path"].as_str() != Some(root.as_str()) {
        return Err("live BuildKit root does not match the snapshot");
    }
    let hosts = bundle["mounts"][6]["source"]
        .as_str()
        .and_then(|source| source.strip_prefix(executor))
        .and_then(|name| name.strip_prefix("/hosts."))
        .filter(|suffix| valid_id(suffix))
        .ok_or("live BuildKit hosts source changed")?;
    let hosts = format!("hosts.{hosts}");
    let fixture = serde_json::json!({
        "uid":WORKLOAD_UID, "gid":WORKLOAD_GID, "additionalGids":[WORKLOAD_GID],
    });
    let process_user = bundle
        .get_mut("process")
        .and_then(|process| process.get_mut("user"));
    let identity = if let Some(process_user) = process_user.filter(|value| **value == fixture) {
        // This pinned numeric identity carries only its own primary group.
        // Compare the remaining OCI fields against the same rootless preset.
        *process_user = serde_json::json!({"uid":0, "gid":0, "additionalGids":LIVE_GROUPS});
        (WORKLOAD_UID, WORKLOAD_GID)
    } else {
        (0, 0)
    };
    let spec = process_spec(&mut bundle, snapshot, image_digest, identity)?;
    let resolver = format!("{executor}/resolv.conf");
    if bundle["mounts"][5]["source"].as_str() != Some(resolver.as_str()) {
        return Err("live BuildKit resolver source changed");
    }
    // Bind the dynamic paths to the verified lease before comparing all
    // remaining requested OCI semantics against the pinned rootless preset.
    bundle["root"]["path"] = "<root>".into();
    bundle["mounts"][6]["source"] = "<hosts>".into();
    bundle["mounts"][5]["source"] =
        format!("{}/resolv.conf", Snapshotter::Native.executor()).into();
    // BuildKit appends the bind flags by iterating a Go map. The accepted
    // flags only add restrictions, so their order does not affect the mount.
    for index in [5, 6, 7] {
        let options = bundle["mounts"]
            .get_mut(index)
            .and_then(|mount| mount.get_mut("options"))
            .and_then(Value::as_array_mut)
            .ok_or("missing live BuildKit bind flags")?;
        options.sort_by(|left, right| left.as_str().cmp(&right.as_str()));
    }
    if policy_sha256(&mut bundle)? != LIVE_POLICY {
        return Err("unsupported live BuildKit OCI preset");
    }
    Ok((spec, hosts))
}

fn policy_sha256(bundle: &mut Value) -> Result<String, &'static str> {
    bundle.sort_all_objects();
    let policy = serde_json::to_vec(bundle).map_err(|_| "invalid build policy")?;
    Ok(hex(&Sha256::digest(policy)))
}

fn process_spec(
    bundle: &mut Value,
    snapshot: Snapshot,
    image_digest: &str,
    (uid, gid): (u32, u32),
) -> Result<LaunchSpec, &'static str> {
    let process = bundle["process"]
        .as_object_mut()
        .ok_or("missing build process")?;
    let mut field = |name| process.remove(name).ok_or("missing build process field");
    let live = snapshot.live_worker;
    let spec = LaunchSpec {
        docker_resource_defaults: live,
        memory_swap_disabled: false,
        open_stdin: false,
        redis_bootstrap: false,
        buildkit_worker: false,
        image_digest: image_digest.to_owned(),
        argv: serde_json::from_value(field("args")?).map_err(|_| "invalid build argv")?,
        env: serde_json::from_value(field("env")?).map_err(|_| "invalid build environment")?,
        cwd: serde_json::from_value(field("cwd")?)
            .map_err(|_| "invalid build working directory")?,
        uid,
        gid,
        account: None,
        network: "none".into(),
        network_alias: None,
        secondary_network_alias: None,
        network_alias_project: None,
        volume: None,
        bind: None,
        build_snapshot: Some(snapshot),
        limits: if live {
            ResourceLimits::UNBOUNDED
        } else {
            NATIVE_LIMITS
        },
    };
    spec.validate()
        .map_err(|_| "build process violates native launch limits")?;

    Ok(spec)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_bundle_rejects_missing_or_malformed_bind_flags() {
        let executor = Snapshotter::Native.executor();
        let snapshot = Snapshot {
            id: "nativeRun".into(),
            device: 1,
            inode: 1,
            bundle_policy: true,
            live_worker: true,
        };
        let mut bundle = serde_json::json!({
            "root": {"path": format!("{executor}/nativeRun/rootfs")},
            "process": {"args": ["/bin/true"], "env": [], "cwd": "/"},
            "mounts": [
                null, null, null, null, null,
                {"source": format!("{executor}/resolv.conf"), "options": ["ro"]},
                {"source": format!("{executor}/hosts.test"), "options": ["ro"]}
            ]
        });
        let error = |bundle: &Value| match parse_live(
            &serde_json::to_vec(bundle).unwrap(),
            snapshot.clone(),
            crate::spec::BUILDKIT_CONFIG,
            Snapshotter::Native,
        ) {
            Ok(_) => panic!("invalid bind flags were accepted"),
            Err(error) => error,
        };
        assert_eq!(error(&bundle), "missing live BuildKit bind flags");
        bundle["mounts"].as_array_mut().unwrap().push(0.into());
        assert_eq!(error(&bundle), "missing live BuildKit bind flags");
    }
}

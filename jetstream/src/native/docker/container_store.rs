//! Container records owned by a managed Docker profile.

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;

use anyhow::{ensure, Context};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use conjet_launch_service::spec::valid_retained_layer_id;

use super::{request, CONTAINERS};

const FILE: &str = "containers.json";
const LIMIT: usize = 2 * 1024 * 1024;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Record {
    pub(super) name: String,
    pub(super) created: u64,
    pub(super) config: Value,
    pub(super) image: String,
    pub(super) generation: u64,
    pub(super) started_at: Option<String>,
    pub(super) exit_code: Option<i64>,
    #[serde(default)]
    pub(super) restart_count: u64,
    #[serde(default)]
    pub(super) manually_stopped: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(super) removing: bool,
}

pub(super) type Records = BTreeMap<String, Record>;

pub(super) fn load(root: &Path) -> anyhow::Result<Records> {
    let path = root.join(FILE);
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Records::new()),
        result => result?,
    };
    let bytes = super::super::oci_stage::read_bounded(root, &path, LIMIT)?;
    let records =
        serde_json::from_slice::<Records>(&bytes).context("invalid container record file")?;
    ensure!(
        records.len() <= CONTAINERS,
        "container record count exceeds capacity"
    );
    let mut names = std::collections::BTreeSet::new();
    for (id, record) in &records {
        ensure!(valid_retained_layer_id(id), "invalid saved container ID");
        ensure!(
            request::name(&record.name) && names.insert(&record.name),
            "invalid or duplicate saved container name"
        );
        ensure!(
            record.config.is_object()
                && record.config["Image"].is_string()
                && !record.image.is_empty()
                && record.image.len() <= 512,
            "invalid saved container configuration"
        );
        ensure!(
            record
                .exit_code
                .is_none_or(|code| (0..=255).contains(&code))
                && record
                    .started_at
                    .as_ref()
                    .is_none_or(|time| time.len() <= 64),
            "invalid saved container lifecycle"
        );
    }
    Ok(records)
}

pub(super) fn save(root: &Path, records: &Records) -> anyhow::Result<()> {
    let bytes = serde_json::to_vec(records)?;
    ensure!(
        records.len() <= CONTAINERS && bytes.len() <= LIMIT,
        "container records exceed capacity"
    );
    let mut file = tempfile::NamedTempFile::new_in(root)?;
    file.write_all(&bytes)?;
    file.as_file().sync_all()?;
    file.persist(root.join(FILE))?;
    File::open(root)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn container_records_retain_identity_configuration_and_exit_state() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        assert!(load(&root).unwrap().is_empty());
        let id = "9".repeat(64);
        let record = Record {
            name: "owned".into(),
            created: 17,
            config: json!({"Image":"tag:local"}),
            image: format!("docker.io/library/alpine@sha256:{}", "a".repeat(64)),
            generation: 2,
            started_at: Some("2026-11-28T00:00:00Z".into()),
            exit_code: Some(143),
            restart_count: 0,
            manually_stopped: false,
            removing: false,
        };
        let mut records = Records::from([(id.clone(), record)]);
        save(&root, &records).unwrap();
        let restored = load(&root).unwrap().remove(&id).unwrap();
        assert_eq!(restored.name, "owned");
        assert_eq!(restored.config["Image"], "tag:local");
        assert_eq!(restored.generation, 2);
        assert_eq!(restored.exit_code, Some(143));

        records.insert("1".repeat(64), restored);
        save(&root, &records).unwrap();
        assert!(load(&root).is_err());
        save(&root, &Records::new()).unwrap();
        assert!(load(&root).unwrap().is_empty());
    }
}

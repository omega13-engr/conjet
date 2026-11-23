use std::collections::BTreeMap;

use anyhow::{ensure, Context};
use base64::Engine;
use conjet_launch_service::handshake::unhex;
use conjet_launch_service::spec::{GID_BASE, ID_MAP_WIDTH, UID_BASE};
use serde::{Deserialize, Serialize};

pub(super) const PACKAGE_LIMIT: u64 = 64 * 1024 * 1024;
pub(super) const MAX_RECORDS: usize = 4096;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Root {
    pub(super) config_digest: String,
    pub(super) records: Vec<Record>,
}

#[derive(Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Kind {
    Directory,
    File,
    Symlink,
    Hardlink,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Record {
    pub(super) path: String,
    pub(super) mode: u32,
    pub(super) uid: u32,
    pub(super) gid: u32,
    pub(super) data: String,
    pub(super) target: String,
    pub(super) kind: Kind,
}

pub(super) fn rooted_symlink(path: &str, target: &str) -> bool {
    if target.is_empty() || target.len() > 1024 || target.contains('\0') {
        return false;
    }
    let mut depth = if target.starts_with('/') {
        0
    } else {
        path.matches('/').count()
    };
    for part in target.split('/') {
        match part {
            "" | "." => {}
            ".." if depth == 0 => return false,
            ".." => depth -= 1,
            _ => depth += 1,
        }
    }
    true
}

pub(super) fn root_path(path: &str) -> bool {
    path.len() <= 1024
        && !path.contains('\0')
        && !path.split('/').any(|part| matches!(part, "" | "." | ".."))
}

impl Root {
    pub(super) fn link_groups(&self) -> BTreeMap<&str, Vec<&str>> {
        let mut groups: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        for record in &self.records {
            if record.kind == Kind::Hardlink {
                groups.entry(&record.target).or_default().push(&record.path);
            }
        }
        groups
    }

    pub(super) fn read(bytes: &[u8]) -> anyhow::Result<Self> {
        let root: Self = serde_json::from_slice(bytes).context("invalid OCI staging package")?;
        let digest = root
            .config_digest
            .strip_prefix("sha256:")
            .context("invalid OCI image config digest")?;
        unhex::<32>(digest)?;
        ensure!(
            !root.records.is_empty() && root.records.len() <= MAX_RECORDS,
            "invalid OCI rootfs entry count"
        );
        let mut types = BTreeMap::new();
        for record in &root.records {
            ensure!(root_path(&record.path), "invalid OCI rootfs path");
            ensure!(
                record.mode & !0o1777 == 0
                    && record.uid < ID_MAP_WIDTH
                    && record.gid < ID_MAP_WIDTH,
                "invalid OCI rootfs mode or ownership"
            );
            ensure!(
                types.insert(record.path.as_str(), record.kind).is_none(),
                "duplicate OCI rootfs entry"
            );
            ensure!(
                (record.kind == Kind::File || record.data.is_empty())
                    && (matches!(record.kind, Kind::Symlink | Kind::Hardlink)
                        || record.target.is_empty()),
                "invalid OCI rootfs entry payload"
            );
            if record.kind == Kind::Symlink {
                ensure!(
                    rooted_symlink(&record.path, &record.target),
                    "invalid OCI rootfs symlink"
                );
            }
        }
        for path in types.keys() {
            if let Some((parent, _)) = path.rsplit_once('/') {
                ensure!(
                    types.get(parent) == Some(&Kind::Directory),
                    "OCI rootfs entry has a missing or non-directory parent"
                );
            }
        }
        for record in &root.records {
            if record.kind == Kind::Hardlink {
                ensure!(
                    types.get(record.target.as_str()) == Some(&Kind::File),
                    "OCI hard link must refer to a regular file"
                );
            }
        }
        Ok(root)
    }

    pub(super) fn append(
        &self,
        mut write: impl FnMut(&str, u32, u32, u32, &[u8], Option<(u32, u32)>) -> std::io::Result<()>,
    ) -> anyhow::Result<()> {
        const PREFIX: &str = "etc/conjet/oci-root";
        write(PREFIX, 0o40755, 0, 0, &[], None)?;
        let mut entries: Vec<_> = self.records.iter().collect();
        // Lexical order puts every validated directory before its children.
        entries.sort_unstable_by_key(|part| &part.path);
        let mut groups = BTreeMap::new();
        for record in &entries {
            if record.kind == Kind::Hardlink {
                *groups.entry(record.target.as_str()).or_insert(1u32) += 1;
            }
        }
        let groups: BTreeMap<_, _> = groups
            .into_iter()
            .enumerate()
            .map(|(index, (path, count))| (path, (0x8000_0000 + index as u32, count)))
            .collect();
        let files: BTreeMap<_, _> = entries
            .iter()
            .filter(|entry| entry.kind == Kind::File)
            .map(|entry| (entry.path.as_str(), *entry))
            .collect();
        let mut remaining = groups.clone();
        for record in entries {
            let name = format!("{PREFIX}/{}", record.path);
            let source = if record.kind == Kind::Hardlink {
                files[record.target.as_str()]
            } else {
                record
            };
            let link = groups.get(source.path.as_str()).copied();
            let emit_data = if let Some((_, left)) = remaining.get_mut(source.path.as_str()) {
                *left -= 1;
                *left == 0
            } else {
                true
            };
            let (type_mode, payload) = match source.kind {
                Kind::Directory => (0o040000, Vec::new()),
                Kind::File if emit_data => (
                    0o100000,
                    base64::engine::general_purpose::STANDARD.decode(&source.data)?,
                ),
                Kind::File => (0o100000, Vec::new()),
                Kind::Symlink => (0o120000, source.target.as_bytes().to_vec()),
                Kind::Hardlink => unreachable!("hard link source was validated"),
            };
            write(
                &name,
                type_mode | source.mode,
                UID_BASE + source.uid,
                GID_BASE + source.gid,
                &payload,
                link,
            )?;
        }
        Ok(())
    }
}

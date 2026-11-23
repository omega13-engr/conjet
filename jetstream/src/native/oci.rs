use std::collections::BTreeMap;

use anyhow::{ensure, Context};
use base64::Engine;
use conjet_launch_service::handshake::unhex;
use serde::Deserialize;

pub(super) const PACKAGE_LIMIT: u64 = 64 * 1024 * 1024;
const MAX_RECORDS: usize = 4096;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Root {
    pub(super) config_digest: String,
    records: Vec<Record>,
}

#[derive(Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Kind {
    Directory,
    File,
    Symlink,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    path: String,
    mode: u32,
    uid: u32,
    gid: u32,
    data: String,
    target: String,
    kind: Kind,
}

impl Root {
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
            ensure!(
                record.path.len() <= 1024
                    && !record.path.contains('\0')
                    && !record
                        .path
                        .split('/')
                        .any(|part| matches!(part, "" | "." | "..")),
                "invalid OCI rootfs path"
            );
            ensure!(
                record.mode & !0o1777 == 0 && record.uid <= 65535 && record.gid <= 65535,
                "invalid OCI rootfs mode or ownership"
            );
            ensure!(
                types.insert(record.path.as_str(), record.kind).is_none(),
                "duplicate OCI rootfs entry"
            );
            ensure!(
                (record.kind == Kind::File || record.data.is_empty())
                    && (record.kind == Kind::Symlink || record.target.is_empty()),
                "invalid OCI rootfs entry payload"
            );
            if record.kind == Kind::Symlink {
                ensure!(
                    !record.target.is_empty()
                        && record.target.len() <= 1024
                        && !record.target.contains('\0'),
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
        Ok(root)
    }

    pub(super) fn append(
        &self,
        mut write: impl FnMut(&str, u32, u32, u32, &[u8]) -> std::io::Result<()>,
    ) -> anyhow::Result<()> {
        const PREFIX: &str = "etc/conjet/oci-root";
        write(PREFIX, 0o40755, 0, 0, &[])?;
        let mut entries: Vec<_> = self.records.iter().collect();
        // Lexical order puts every validated directory before its children.
        entries.sort_unstable_by_key(|part| &part.path);
        for record in entries {
            let name = format!("{PREFIX}/{}", record.path);
            let mode = record.mode;
            let (type_mode, payload) = match record.kind {
                Kind::Directory => (0o040000, Vec::new()),
                Kind::File => (
                    0o100000,
                    base64::engine::general_purpose::STANDARD.decode(&record.data)?,
                ),
                Kind::Symlink => (0o120000, record.target.as_bytes().to_vec()),
            };
            write(&name, type_mode | mode, record.uid, record.gid, &payload)?;
        }
        Ok(())
    }
}

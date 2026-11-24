//! Validated transport representation of one immutable OCI root.
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::handshake::unhex;
use crate::spec::ID_MAP_WIDTH;

pub const MAX_RECORDS: usize = 4096;
pub const PACKAGE_LIMIT: u64 = 64 * 1024 * 1024;
pub const DISK_STORE_MARKER: &str = "/etc/conjet/native-image-store-disk";

macro_rules! ensure {
    ($condition:expr, $message:literal $(,)?) => {
        if !$condition {
            return Err(std::io::Error::other($message));
        }
    };
}

pub mod packed;

#[derive(Clone, Copy, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PackageEncoding {
    #[default]
    Json,
    DiskV2,
}

impl PackageEncoding {
    pub fn byte_limit(self) -> u64 {
        match self {
            Self::Json => PACKAGE_LIMIT,
            Self::DiskV2 => packed::BYTE_LIMIT,
        }
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Root {
    pub config_digest: String,
    pub records: Vec<Record>,
}

#[derive(Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Directory,
    File,
    Symlink,
    Hardlink,
}

pub fn mode_mask(kind: Kind) -> u32 {
    if kind == Kind::Directory {
        0o3777
    } else {
        0o1777
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub path: String,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    pub data: String,
    pub target: String,
    pub kind: Kind,
}

pub fn rooted_symlink(path: &str, target: &str) -> bool {
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

pub fn root_path(path: &str) -> bool {
    path.len() <= 1024
        && !path.contains('\0')
        && !path.split('/').any(|part| matches!(part, "" | "." | ".."))
}

impl Root {
    pub fn link_groups(&self) -> BTreeMap<&str, Vec<&str>> {
        let mut groups: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        for record in &self.records {
            if record.kind == Kind::Hardlink {
                groups.entry(&record.target).or_default().push(&record.path);
            }
        }
        groups
    }

    pub fn read(bytes: &[u8]) -> std::io::Result<Self> {
        ensure!(
            bytes.len() as u64 <= PACKAGE_LIMIT,
            "OCI package exceeds its bound"
        );
        let root: Self = serde_json::from_slice(bytes)?;
        root.validate()
    }

    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    pub(crate) fn read_file(file: std::fs::File) -> std::io::Result<Self> {
        ensure!(
            file.metadata()?.len() <= PACKAGE_LIMIT,
            "OCI package exceeds its bound"
        );
        let root: Self = serde_json::from_reader(std::io::BufReader::new(file))?;
        root.validate()
    }

    fn validate(self) -> std::io::Result<Self> {
        self.validate_with_limit(MAX_RECORDS)
    }

    fn validate_with_limit(self, max_records: usize) -> std::io::Result<Self> {
        let digest = self
            .config_digest
            .strip_prefix("sha256:")
            .ok_or_else(|| std::io::Error::other("invalid OCI image config digest"))?;
        unhex::<32>(digest).map_err(std::io::Error::other)?;
        ensure!(
            !self.records.is_empty() && self.records.len() <= max_records,
            "invalid OCI rootfs entry count"
        );
        let mut types = BTreeMap::new();
        for record in &self.records {
            ensure!(root_path(&record.path), "invalid OCI rootfs path");
            ensure!(
                record.mode & !mode_mask(record.kind) == 0
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
        for record in &self.records {
            if record.kind == Kind::Hardlink {
                ensure!(
                    types.get(record.target.as_str()) == Some(&Kind::File),
                    "OCI hard link must refer to a regular file"
                );
            }
        }
        Ok(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn validate_mode(mode: u32, kind: Kind) -> bool {
        Root {
            config_digest: format!("sha256:{}", "af".repeat(32)),
            records: vec![Record {
                path: "home".into(),
                mode,
                uid: 1000,
                gid: 1000,
                kind,
                data: String::new(),
                target: String::new(),
            }],
        }
        .validate()
        .is_ok()
    }

    #[test]
    fn accepts_group_inheritance_only_on_directories() {
        assert!(validate_mode(0o2755, Kind::Directory));
        assert!(!validate_mode(0o2755, Kind::File));
        assert!(!validate_mode(0o4755, Kind::Directory));
        assert!(!validate_mode(0o4755, Kind::File));
    }
}

use std::collections::BTreeMap;

use base64::Engine;
use conjet_launch_service::spec::{GID_BASE, UID_BASE};

pub(super) use conjet_launch_service::oci::{
    root_path, rooted_symlink, Kind, Record, Root, MAX_RECORDS, PACKAGE_LIMIT,
};

pub(super) fn append(
    root: &Root,
    mut write: impl FnMut(&str, u32, u32, u32, &[u8], Option<(u32, u32)>) -> std::io::Result<()>,
) -> anyhow::Result<()> {
    const PREFIX: &str = "etc/conjet/oci-root";
    write(PREFIX, 0o40755, 0, 0, &[], None)?;
    let mut entries: Vec<_> = root.records.iter().collect();
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

//! Bounded initial copy from an immutable, verified image directory.

use std::collections::BTreeMap;
use std::fs::{self, File, Metadata};
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt, chown, lchown, symlink};
use std::path::{Path, PathBuf};

use crate::spec::{GID_BASE, UID_BASE, valid_volume_target};

const MAX_ENTRIES: usize = 8192;
const MAX_COPY_BYTES: u64 = 128 * 1024 * 1024;
const MAX_DEPTH: usize = 64;

pub(crate) fn image_directory(digest: &str, target: &str) -> io::Result<Option<PathBuf>> {
    if !valid_volume_target(target) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let (mut path, _) = crate::sandbox_fixture::image_lower(digest)?;
    for segment in target.trim_start_matches('/').split('/') {
        path.push(segment);
        match path.symlink_metadata() {
            Ok(info) if info.is_dir() => {}
            Ok(_) => return Err(io::Error::other("image volume path is not a directory")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        }
    }
    Ok(Some(path))
}

pub(crate) fn copy_directory(from: &Path, to: &Path) -> io::Result<()> {
    let mut copy = CopyTree {
        entries: MAX_ENTRIES,
        bytes: MAX_COPY_BYTES,
        hardlinks: BTreeMap::new(),
    };
    copy.directory(from, to, &from.symlink_metadata()?, 0)
}

struct CopyTree {
    entries: usize,
    bytes: u64,
    hardlinks: BTreeMap<(u64, u64), PathBuf>,
}

impl CopyTree {
    fn directory(
        &mut self,
        from: &Path,
        to: &Path,
        metadata: &Metadata,
        depth: usize,
    ) -> io::Result<()> {
        if depth > MAX_DEPTH || !metadata.is_dir() {
            return Err(io::Error::other("image volume directory exceeds its scope"));
        }
        let directory_owner = owner(metadata)?;
        for entry in fs::read_dir(from)? {
            let entry = entry?;
            self.entries = self
                .entries
                .checked_sub(1)
                .ok_or_else(|| io::Error::other("image volume exceeds its entry bound"))?;
            let source = entry.path();
            let destination = to.join(entry.file_name());
            let info = source.symlink_metadata()?;
            if info.is_dir() {
                fs::create_dir(&destination)?;
                self.directory(&source, &destination, &info, depth + 1)?;
            } else if info.is_file() {
                self.file(&source, &destination, &info)?;
            } else if info.is_symlink() {
                let (uid, gid) = owner(&info)?;
                symlink(fs::read_link(&source)?, &destination)?;
                lchown(&destination, Some(uid), Some(gid))?;
            } else {
                return Err(io::Error::other(
                    "unsupported entry in image volume directory",
                ));
            }
        }
        set_attributes(to, metadata, directory_owner)?;
        File::open(to)?.sync_all()
    }

    fn file(&mut self, from: &Path, to: &Path, metadata: &Metadata) -> io::Result<()> {
        let id = (metadata.dev(), metadata.ino());
        if let Some(original) = self.hardlinks.get(&id) {
            return fs::hard_link(original, to);
        }
        let owner = owner(metadata)?;
        self.bytes = self
            .bytes
            .checked_sub(metadata.len())
            .ok_or_else(|| io::Error::other("image volume exceeds its byte bound"))?;
        if fs::copy(from, to)? != metadata.len() {
            return Err(io::Error::other("image volume file length changed"));
        }
        set_attributes(to, metadata, owner)?;
        File::open(to)?.sync_all()?;
        if metadata.nlink() > 1 {
            self.hardlinks.insert(id, to.to_owned());
        }
        Ok(())
    }
}

fn owner(metadata: &Metadata) -> io::Result<(u32, u32)> {
    crate::volume_disk::mapped_volume_owner(metadata.uid(), metadata.gid(), (UID_BASE, GID_BASE))
        .map(|(uid, gid)| (UID_BASE + uid, GID_BASE + gid))
        .ok_or_else(|| io::Error::other("image volume owner is outside the mapped IDs"))
}

fn set_attributes(path: &Path, metadata: &Metadata, owner: (u32, u32)) -> io::Result<()> {
    chown(path, Some(owner.0), Some(owner.1))?;
    fs::set_permissions(path, fs::Permissions::from_mode(metadata.mode() & 0o7777))
}

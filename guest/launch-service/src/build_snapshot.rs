//! Identity of a private BuildKit worker's mounted root filesystem.

use serde::{Deserialize, Serialize};

pub const MARKER: &str = "/etc/conjet/native-build-snapshot";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub id: String,
    pub device: u64,
    pub inode: u64,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod guest {
    use std::ffi::CString;
    use std::fs::{File, OpenOptions};
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::path::Path;

    use super::{MARKER, Snapshot, valid_id};

    pub(crate) const ROOT: &std::ffi::CStr = c"/run/conjet/buildkit";
    const OPEN_TREE: libc::c_int =
        libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_DIRECTORY;

    fn open_directory(parent: &File, name: &str) -> io::Result<File> {
        let name = CString::new(name)?;
        let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), OPEN_TREE) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // openat returned a new descriptor with CLOEXEC.
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    fn open(id: &str) -> io::Result<(File, Snapshot)> {
        if !valid_id(id) || !Path::new(MARKER).try_exists()? {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid native build snapshot scope",
            ));
        }
        let store = OpenOptions::new()
            .read(true)
            .custom_flags(OPEN_TREE)
            .open(ROOT.to_str().expect("static build root"))?;
        let executor = open_directory(&store, "executor")?;
        let bundle = open_directory(&executor, id)?;
        let rootfs = open_directory(&bundle, "rootfs")?;
        let info = rootfs.metadata()?;
        if info.dev() != store.metadata()?.dev() {
            return Err(io::Error::other(
                "build root does not belong to the leased disk",
            ));
        }
        let snapshot = Snapshot {
            id: id.into(),
            device: info.dev(),
            inode: info.ino(),
        };
        Ok((rootfs, snapshot))
    }

    pub(crate) fn inspect(id: &str) -> io::Result<Snapshot> {
        open(id).map(|(_, identity)| identity)
    }

    pub(crate) fn source(snapshot: &Snapshot) -> io::Result<File> {
        let (file, identity) = open(&snapshot.id)?;
        if *snapshot != identity {
            return Err(io::Error::other("stale native build snapshot identity"));
        }
        Ok(file)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_names_are_single_components() {
        assert!(valid_id("86febcd2c6"));
        for name in ["", ".", "a/b", "a\\b", "../private", "a\0b"] {
            assert!(!valid_id(name));
        }
    }
}

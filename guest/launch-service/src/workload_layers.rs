//! Writable Docker container layers on the owned native volume disk.

use std::ffi::CString;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::security::checked;
use crate::spec::{GID_BASE, UID_BASE, valid_retained_layer_id};

const ROOT: &str = "/run/conjet/volume-disk/workload-layers";

pub(crate) fn initialize() -> io::Result<()> {
    match DirBuilder::new().mode(0o711).create(ROOT) {
        Ok(()) => fs::set_permissions(ROOT, fs::Permissions::from_mode(0o711))?,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let metadata = fs::symlink_metadata(ROOT)?;
    if !metadata.is_dir() || metadata.uid() != 0 || metadata.mode() & 0o777 != 0o711 {
        return Err(io::Error::other("invalid native workload layer root"));
    }
    Ok(())
}

fn path(id: &str) -> io::Result<PathBuf> {
    if !valid_retained_layer_id(id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid native workload layer identifier",
        ));
    }
    Ok(Path::new(ROOT).join(id))
}

fn lock(directory: &Path) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY)
        .open(directory)?;
    checked(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) })?;
    let actual = file.metadata()?;
    let named = fs::symlink_metadata(directory)?;
    if actual.uid() != 0
        || actual.mode() & 0o777 != 0o711
        || actual.dev() != named.dev()
        || actual.ino() != named.ino()
    {
        return Err(io::Error::other(
            "invalid or replaced native workload layer",
        ));
    }
    Ok(file)
}

pub(crate) struct Layer {
    base: PathBuf,
    lock: File,
    initialized: bool,
}

impl Layer {
    pub(crate) fn open(id: &str, digest: &str) -> io::Result<Self> {
        let base = path(id)?;
        match DirBuilder::new().mode(0o711).create(&base) {
            Ok(()) => fs::set_permissions(&base, fs::Permissions::from_mode(0o711))?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        let lock = lock(&base)?;
        let marker = base.join("image");
        let initialized = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(marker)
        {
            Ok(file) => {
                let metadata = file.metadata()?;
                let mut saved = String::new();
                if !metadata.is_file()
                    || metadata.uid() != 0
                    || metadata.len() != digest.len() as u64
                {
                    return Err(io::Error::other("invalid native workload layer marker"));
                }
                file.take(128).read_to_string(&mut saved)?;
                if saved != digest {
                    return Err(io::Error::other("native workload layer image changed"));
                }
                true
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => false,
            Err(error) => return Err(error),
        };
        for (name, mode) in [("upper", 0o755), ("work", 0o700)] {
            let directory = base.join(name);
            if initialized {
                if !fs::symlink_metadata(&directory)?.is_dir() {
                    return Err(io::Error::other(
                        "native workload layer path is not a directory",
                    ));
                }
                continue;
            }
            match fs::remove_dir_all(&directory) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
            DirBuilder::new().mode(mode).create(&directory)?;
            let raw = CString::new(directory.as_os_str().as_bytes())?;
            checked(unsafe { libc::chown(raw.as_ptr(), UID_BASE, GID_BASE) })?;
        }
        Ok(Self {
            base,
            lock,
            initialized,
        })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.base
    }

    pub(crate) fn initialized(&self) -> bool {
        self.initialized
    }

    pub(crate) fn finish_setup(&self, digest: &str) -> io::Result<()> {
        let temporary = self.base.join(".image.pending");
        let mut marker = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?;
        marker.write_all(digest.as_bytes())?;
        marker.sync_all()?;
        fs::rename(temporary, self.base.join("image"))?;
        self.lock.sync_all()?;
        File::open(ROOT)?.sync_all()
    }
}

pub(crate) fn remove(id: &str) -> io::Result<()> {
    let base = path(id)?;
    let _lock = match lock(&base) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    fs::remove_dir_all(base)?;
    File::open(ROOT)?.sync_all()
}

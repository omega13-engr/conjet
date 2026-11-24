use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{ensure, Context, Result};
use conjet_launch_service::volume_disk::{filesystem_uuid, VolumeIdentity};

pub(super) struct VolumeDisk {
    pub path: PathBuf,
    pub file: Arc<File>,
    pub identity: VolumeIdentity,
}

impl VolumeDisk {
    pub fn lease(
        path: PathBuf,
        scratch: &Path,
        disk_image_store: bool,
        build_workspace: bool,
    ) -> Result<Self> {
        ensure!(
            scratch == Path::new("/Volumes/ExternalSSD/dev_workspace/tmp")
                && path.starts_with(scratch)
                && path.canonicalize()? == path,
            "volume disk must be a canonical ExternalSSD scratch path"
        );
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&path)?;
        let info = file.metadata()?;
        let max_bytes = if disk_image_store && build_workspace {
            16 * 1024 * 1024 * 1024
        } else if disk_image_store {
            4 * 1024 * 1024 * 1024
        } else {
            512 * 1024 * 1024
        };
        ensure!(
            info.is_file()
                && info.nlink() == 1
                && info.uid() == unsafe { libc::geteuid() }
                && info.mode() & 0o077 == 0
                && info.dev() == scratch.metadata()?.dev()
                && (32 * 1024 * 1024..=max_bytes).contains(&info.len()),
            "invalid owner, permissions, size or backing device for native volume disk"
        );
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(std::io::Error::last_os_error())
                .context("native volume disk is already owned");
        }
        let identity = VolumeIdentity {
            uuid: filesystem_uuid(&file)?,
            epoch_seconds: SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
        };
        Ok(Self {
            path,
            file: Arc::new(file),
            identity,
        })
    }
}

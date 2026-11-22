use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use crate::handshake::hex;
use crate::spec::ResourceLimits;

const CPU_PERIOD_US: u64 = 100_000;
pub(crate) const CGROUP2_SUPER_MAGIC: u64 = 0x6367_7270;

pub struct WorkloadCgroup {
    directory: File,
    path: PathBuf,
}

impl WorkloadCgroup {
    pub fn create(
        parent: &Path,
        workload_id: [u8; 16],
        limits: ResourceLimits,
    ) -> io::Result<Self> {
        let parent_descriptor = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(parent)?;
        let mut filesystem = std::mem::MaybeUninit::<libc::statfs>::uninit();
        // The kernel initializes statfs on success. Fail before mkdir on another filesystem.
        if unsafe { libc::fstatfs(parent_descriptor.as_raw_fd(), filesystem.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { filesystem.assume_init() }.f_type as u64 != CGROUP2_SUPER_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "cgroup v2 required",
            ));
        }
        let path = parent.join(hex(&workload_id));
        std::fs::create_dir(&path)?;
        let result = (|| {
            let directory = File::open(&path)?;
            write_control(&path, "memory.max", &limits.memory_bytes.to_string())?;
            write_control(&path, "pids.max", &limits.pids.to_string())?;
            let quota = u64::from(limits.cpu_millicores) * CPU_PERIOD_US / 1_000;
            write_control(&path, "cpu.max", &format!("{quota} {CPU_PERIOD_US}"))?;
            Ok(directory)
        })();
        match result {
            Ok(directory) => Ok(Self { directory, path }),
            Err(setup) => match std::fs::remove_dir(&path) {
                Ok(()) => Err(setup),
                Err(cleanup) => Err(io::Error::other(format!(
                    "cgroup setup failed: {setup}; could not remove empty cgroup: {cleanup}"
                ))),
            },
        }
    }

    pub fn directory(&self) -> &File {
        &self.directory
    }

    pub fn kill(&self) -> io::Result<()> {
        write_control(&self.path, "cgroup.kill", "1")
    }

    pub fn populated(&self) -> io::Result<bool> {
        let events = std::fs::read_to_string(self.path.join("cgroup.events"))?;
        match events
            .lines()
            .find_map(|line| line.strip_prefix("populated "))
        {
            Some("0") => Ok(false),
            Some("1") => Ok(true),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid cgroup population state",
            )),
        }
    }

    pub fn remove_empty(&self) -> io::Result<()> {
        if self.populated()? {
            return Err(io::Error::other(
                "refusing to remove a populated workload cgroup",
            ));
        }
        // The kernel rechecks membership atomically with rmdir.
        std::fs::remove_dir(&self.path)
    }
}

pub(crate) fn write_control(path: &Path, file: &str, value: &str) -> io::Result<()> {
    OpenOptions::new()
        .write(true)
        .open(path.join(file))?
        .write_all(value.as_bytes())
}

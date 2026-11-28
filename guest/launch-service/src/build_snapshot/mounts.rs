//! Fixed mount recipe admitted by the pinned BuildKit bundle policy.

use std::ffi::{CStr, CString};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use crate::security::checked;

const SAFE: libc::c_ulong = libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC;
const FSOPEN_CLOEXEC: libc::c_uint = 1;
const FSCONFIG_CMD_CREATE: libc::c_uint = 6;
const FSMOUNT_CLOEXEC: libc::c_uint = 1;
const MOVE_MOUNT_F_EMPTY_PATH: libc::c_uint = 4;
pub(crate) const LIVE_FDS: &str = "CONJET_NATIVE_BUILD_MOUNTS";
const MASKED: &[&str] = &[
    "proc/acpi",
    "proc/asound",
    "proc/kcore",
    "proc/keys",
    "proc/latency_stats",
    "proc/timer_list",
    "proc/timer_stats",
    "proc/sched_debug",
    "sys/firmware",
    "sys/devices/virtual/powercap",
    "proc/scsi",
];
const READ_ONLY: &[&str] = &[
    "proc/bus",
    "proc/fs",
    "proc/irq",
    "proc/sys",
    "proc/sysrq-trigger",
];

pub(crate) fn detached_sysfs(pidfd: &OwnedFd) -> io::Result<OwnedFd> {
    let original = File::open("/proc/self/ns/net")?;
    let target = crate::exec_fixture::target_network(pidfd)?;
    checked(unsafe { libc::setns(target.as_raw_fd(), libc::CLONE_NEWNET) })?;
    let mount = (|| {
        let context = unsafe { libc::syscall(libc::SYS_fsopen, c"sysfs".as_ptr(), FSOPEN_CLOEXEC) };
        if context < 0 {
            return Err(io::Error::last_os_error());
        }
        let context = unsafe { OwnedFd::from_raw_fd(context as i32) };
        checked(unsafe {
            libc::syscall(
                libc::SYS_fsconfig,
                context.as_raw_fd(),
                FSCONFIG_CMD_CREATE,
                std::ptr::null::<libc::c_char>(),
                std::ptr::null::<libc::c_void>(),
                0,
            ) as i32
        })?;
        let flags = libc::MOUNT_ATTR_RDONLY
            | libc::MOUNT_ATTR_NOSUID
            | libc::MOUNT_ATTR_NODEV
            | libc::MOUNT_ATTR_NOEXEC;
        let descriptor = unsafe {
            libc::syscall(
                libc::SYS_fsmount,
                context.as_raw_fd(),
                FSMOUNT_CLOEXEC,
                flags as u32,
            )
        };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { OwnedFd::from_raw_fd(descriptor as i32) })
    })();
    // The launch helper is single-threaded. Restore its original network
    // namespace before it releases the workload's startup barrier.
    checked(unsafe { libc::setns(original.as_raw_fd(), libc::CLONE_NEWNET) })?;
    mount
}

pub(crate) struct Sources {
    hosts: WorkerFile,
    resolver: WorkerFile,
    tracing: WorkerFile,
    metadata: Option<WorkerFile>,
    null: File,
    devices: [File; 5],
}

enum WorkerFile {
    Bind(File),
    Detached(OwnedFd),
}

impl WorkerFile {
    fn mount(&self, target: &Path) -> io::Result<()> {
        match self {
            Self::Bind(file) => bind(file, target, false),
            Self::Detached(tree) => {
                let path = CString::new(target.as_os_str().as_bytes())?;
                checked(unsafe {
                    libc::syscall(
                        libc::SYS_move_mount,
                        tree.as_raw_fd(),
                        c"".as_ptr(),
                        libc::AT_FDCWD,
                        path.as_ptr(),
                        MOVE_MOUNT_F_EMPTY_PATH,
                    ) as i32
                })
            }
        }
    }
}

pub(crate) struct LiveMounts {
    pub(crate) root: OwnedFd,
    hosts: OwnedFd,
    resolver: OwnedFd,
    tracing: OwnedFd,
    network: OwnedFd,
    metadata: Option<OwnedFd>,
}

impl LiveMounts {
    pub(crate) fn inherits_network(&self) -> bool {
        self.metadata.is_none()
    }

    pub(crate) fn enter_network(&self) -> io::Result<bool> {
        if self.metadata.is_some() {
            return Ok(false);
        }
        // An OCI RUN without a network namespace inherits its verified worker's
        // network, never the supervisor's or host's network.
        checked(unsafe { libc::setns(self.network.as_raw_fd(), libc::CLONE_NEWNET) })?;
        Ok(true)
    }

    pub(crate) fn capture(
        root: OwnedFd,
        executor: &File,
        cache: &File,
        hosts: &str,
        worker_root: &File,
        worker_pidfd: &OwnedFd,
        metadata: Option<&str>,
    ) -> io::Result<Self> {
        Ok(Self {
            root,
            hosts: live_source(executor, &CString::new(hosts)?, false)?,
            resolver: live_source(executor, c"resolv.conf", false)?,
            tracing: live_source(cache, c"otel-grpc.sock", true)?,
            network: crate::exec_fixture::target_network(worker_pidfd)?.into(),
            metadata: metadata
                .map(|name| metadata_source(worker_root, worker_pidfd, name))
                .transpose()?,
        })
    }

    pub(crate) fn descriptors(&self) -> Vec<i32> {
        let mut fds = vec![
            self.root.as_raw_fd(),
            self.hosts.as_raw_fd(),
            self.resolver.as_raw_fd(),
            self.tracing.as_raw_fd(),
            self.network.as_raw_fd(),
        ];
        if let Some(metadata) = &self.metadata {
            fds.push(metadata.as_raw_fd());
        }
        fds
    }

    pub(crate) fn inherited(required: bool) -> io::Result<Option<Self>> {
        let configured = std::env::var_os(LIVE_FDS);
        if configured.is_some() != required {
            return Err(io::Error::other("missing or unexpected live build mounts"));
        }
        let Some(configured) = configured else {
            return Ok(None);
        };
        let fds = configured
            .to_str()
            .ok_or_else(|| io::Error::other("invalid live build mount descriptor list"))?
            .split(',')
            .map(str::parse::<i32>)
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?;
        if !(5..=6).contains(&fds.len()) {
            return Err(io::Error::other(
                "wrong number of live build mount descriptors",
            ));
        }
        let (root, hosts, resolver, tracing) = (fds[0], fds[1], fds[2], fds[3]);
        let network = fds[4];
        let metadata = fds.get(5).copied();
        let mut distinct = fds;
        distinct.sort_unstable();
        if distinct[0] <= 2 || distinct.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(io::Error::other(
                "duplicate or invalid live build descriptors",
            ));
        }
        for fd in distinct {
            checked(unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) })?;
        }
        // The trusted supervisor transferred sole inherited ownership across exec.
        Ok(Some(unsafe {
            Self {
                root: OwnedFd::from_raw_fd(root),
                hosts: OwnedFd::from_raw_fd(hosts),
                resolver: OwnedFd::from_raw_fd(resolver),
                tracing: OwnedFd::from_raw_fd(tracing),
                network: OwnedFd::from_raw_fd(network),
                metadata: metadata.map(|fd| OwnedFd::from_raw_fd(fd)),
            }
        }))
    }

    pub(crate) fn sources(&self) -> io::Result<Sources> {
        Ok(Sources {
            hosts: WorkerFile::Detached(self.hosts.try_clone()?),
            resolver: WorkerFile::Detached(self.resolver.try_clone()?),
            tracing: WorkerFile::Detached(self.tracing.try_clone()?),
            metadata: self
                .metadata
                .as_ref()
                .map(|fd| fd.try_clone().map(WorkerFile::Detached))
                .transpose()?,
            null: File::open("/dev/null")?,
            devices: crate::sandbox_fixture::standard_devices()?,
        })
    }
}

fn metadata_source(root: &File, pidfd: &OwnedFd, name: &str) -> io::Result<OwnedFd> {
    let suffix = name.strip_prefix("buildkit-metadata").unwrap_or("");
    if suffix.is_empty() || suffix.len() > 32 || !suffix.bytes().all(|b| b.is_ascii_digit()) {
        return Err(io::Error::other("invalid owned metadata directory"));
    }
    let open = |parent: &File, name: &CStr| -> io::Result<File> {
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    };
    let tmp = open(root, c"tmp")?;
    let source = open(&tmp, &CString::new(name)?)?;
    let info = source.metadata()?;
    if info.uid() != crate::spec::UID_BASE || info.dev() != tmp.metadata()?.dev() {
        return Err(io::Error::other("frontend metadata ownership changed"));
    }
    let namespace = crate::exec_fixture::target_mount_namespace(pidfd)?;
    let tree = super::guest::clone_worker_overlay(&namespace, &source)?;
    super::guest::set_mount_attributes(
        &tree,
        &libc::mount_attr {
            attr_set: libc::MOUNT_ATTR_RDONLY
                | libc::MOUNT_ATTR_NOSUID
                | libc::MOUNT_ATTR_NODEV
                | libc::MOUNT_ATTR_NOEXEC,
            attr_clr: 0,
            propagation: 0,
            userns_fd: 0,
        },
    )?;
    Ok(tree)
}

fn live_source(directory: &File, name: &CStr, socket: bool) -> io::Result<OwnedFd> {
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata()?;
    let valid_type = if socket {
        metadata.file_type().is_socket()
    } else {
        metadata.is_file() && metadata.len() <= 65_536
    };
    if !valid_type
        || metadata.uid() != crate::spec::UID_BASE
        || metadata.dev() != directory.metadata()?.dev()
        || metadata.nlink() != 1
    {
        return Err(io::Error::other("unexpected live worker source identity"));
    }
    let tree = super::guest::clone_tree(&file)?;
    super::guest::set_mount_attributes(
        &tree,
        &libc::mount_attr {
            attr_set: libc::MOUNT_ATTR_RDONLY
                | libc::MOUNT_ATTR_NOSUID
                | libc::MOUNT_ATTR_NODEV
                | libc::MOUNT_ATTR_NOEXEC,
            attr_clr: 0,
            propagation: 0,
            userns_fd: 0,
        },
    )?;
    Ok(tree)
}

pub(crate) struct MountPlan {
    hosts: Source,
    resolver: Source,
    tracing: Source,
}

struct Source {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl Source {
    fn open(path: &Path) -> io::Result<File> {
        let path = CString::new(path.as_os_str().as_bytes())?;
        // Use a path descriptor, including for a Unix socket. In particular
        // this must not become a regular read-open of the socket inode.
        let fd = unsafe {
            libc::openat(
                libc::AT_FDCWD,
                path.as_ptr(),
                libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    fn verify(path: PathBuf, socket: bool) -> io::Result<Self> {
        let metadata = Self::open(&path)
            .and_then(|source| source.metadata())
            .map_err(|error| {
                io::Error::other(format!("verify worker source {}: {error}", path.display()))
            })?;
        let valid = if socket {
            metadata.file_type().is_socket()
        } else {
            metadata.is_file() && metadata.mode() & 0o022 == 0
        };
        if !valid || metadata.uid() != 0 {
            return Err(io::Error::other("invalid worker mount source"));
        }
        Ok(Self {
            path,
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }

    fn reopen(&self) -> io::Result<File> {
        // Use the child's mount namespace and compare the verified identity.
        // stat reports IDs through the new user namespace here.
        let file = Self::open(&self.path)?;
        let metadata = file.metadata()?;
        if (metadata.dev(), metadata.ino()) != (self.device, self.inode) {
            return Err(io::Error::other("worker mount source changed"));
        }
        Ok(file)
    }
}

impl MountPlan {
    pub(crate) fn verify(hosts: &str) -> io::Result<Self> {
        Ok(Self {
            hosts: Source::verify(PathBuf::from(hosts), false)?,
            resolver: Source::verify(
                Path::new(super::bundle::EXECUTOR).join("resolv.conf"),
                false,
            )?,
            tracing: Source::verify(PathBuf::from("/run/buildkit/otel-grpc.sock"), true)?,
        })
    }

    pub(crate) fn open(&self) -> io::Result<Sources> {
        Ok(Sources {
            hosts: WorkerFile::Bind(self.hosts.reopen()?),
            resolver: WorkerFile::Bind(self.resolver.reopen()?),
            tracing: WorkerFile::Bind(self.tracing.reopen()?),
            metadata: None,
            null: File::open("/dev/null")?,
            devices: crate::sandbox_fixture::standard_devices()?,
        })
    }
}

impl Sources {
    pub(crate) fn mount(self, root: &Path, sysfs: Option<OwnedFd>) -> io::Result<()> {
        checked(unsafe {
            libc::sethostname(
                c"buildkitsandbox".as_ptr(),
                c"buildkitsandbox".to_bytes().len(),
            )
        })?;
        checked(unsafe { libc::unshare(libc::CLONE_NEWCGROUP) })?;
        for (target, fs_type, flags, options) in [
            ("proc", c"proc", SAFE, c""),
            (
                "dev",
                c"tmpfs",
                libc::MS_NOSUID | libc::MS_STRICTATIME,
                c"mode=755,size=65536k",
            ),
            (
                "dev/pts",
                c"devpts",
                libc::MS_NOSUID | libc::MS_NOEXEC,
                c"newinstance,ptmxmode=0666,mode=0620,gid=5",
            ),
            ("dev/shm", c"tmpfs", SAFE, c"mode=1777,size=65536k"),
            ("dev/mqueue", c"mqueue", SAFE, c""),
        ] {
            let path = directory(root, target)?;
            attach(Some(fs_type), &path, Some(fs_type), flags, Some(options))?;
        }
        if let Some(sysfs) = sysfs {
            let sys = CString::new(directory(root, "sys")?.as_os_str().as_bytes())?;
            checked(unsafe {
                libc::syscall(
                    libc::SYS_move_mount,
                    sysfs.as_raw_fd(),
                    c"".as_ptr(),
                    libc::AT_FDCWD,
                    sys.as_ptr(),
                    MOVE_MOUNT_F_EMPTY_PATH,
                ) as i32
            })?;
            let cgroup = directory(root, "sys/fs/cgroup")?;
            attach(
                Some(c"cgroup2"),
                &cgroup,
                Some(c"cgroup2"),
                SAFE | libc::MS_RDONLY,
                None,
            )?;
        }

        for (path, file) in [
            ("etc/hosts", &self.hosts),
            ("etc/resolv.conf", &self.resolver),
            ("dev/otel-grpc.sock", &self.tracing),
        ] {
            let target = mount_file_target(root, path)?;
            file.mount(&target)
                .map_err(|error| io::Error::other(format!("worker mount {path}: {error}")))?;
        }
        if let Some(metadata) = self.metadata {
            metadata.mount(&directory(root, "run/config/buildkit/metadata")?)?;
        }
        let root_path = CString::new(root.as_os_str().as_bytes())?;
        crate::sandbox_fixture::mount_standard_devices(&root_path, self.devices)?;
        for (name, target) in [
            ("fd", "/proc/self/fd"),
            ("stdin", "/proc/self/fd/0"),
            ("stdout", "/proc/self/fd/1"),
            ("stderr", "/proc/self/fd/2"),
            ("ptmx", "pts/ptmx"),
        ] {
            std::os::unix::fs::symlink(target, root.join("dev").join(name))?;
        }
        for path in MASKED {
            let target = root.join(path);
            if let Some(info) = optional_metadata(&target)? {
                if info.is_dir() {
                    attach(
                        Some(c"tmpfs"),
                        &target,
                        Some(c"tmpfs"),
                        SAFE | libc::MS_RDONLY,
                        Some(c"size=4096"),
                    )?;
                } else {
                    bind(&self.null, &target, false)?;
                }
            }
        }
        for path in READ_ONLY {
            let target = root.join(path);
            if optional_metadata(&target)?.is_some() {
                let source = CString::new(target.as_os_str().as_bytes())?;
                attach(Some(&source), &target, None, libc::MS_BIND, None)?;
                attach(
                    None,
                    &target,
                    None,
                    libc::MS_BIND | libc::MS_REMOUNT | libc::MS_RDONLY | SAFE,
                    None,
                )?;
            }
        }
        Ok(())
    }
}

fn mount_file_target(root: &Path, path: &str) -> io::Result<PathBuf> {
    let (parent, name) = path.rsplit_once('/').expect("fixed worker mount");
    let target = directory(root, parent)?.join(name);
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .open(&target)
    {
        Ok(_) => {}
        Err(error)
            if error.kind() == io::ErrorKind::AlreadyExists
                && target.symlink_metadata()?.is_file() => {}
        Err(error) => return Err(error),
    }
    Ok(target)
}

fn optional_metadata(path: &Path) -> io::Result<Option<fs::Metadata>> {
    match path.symlink_metadata() {
        Ok(info) if !info.file_type().is_symlink() => Ok(Some(info)),
        Ok(_) => Err(io::Error::other("symbolic link at a worker mount target")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn directory(root: &Path, relative: &str) -> io::Result<PathBuf> {
    let mut path = root.to_owned();
    for part in relative.split('/') {
        path.push(part);
        match optional_metadata(&path)? {
            Some(info) if info.is_dir() => {}
            Some(_) => return Err(io::Error::other("invalid worker mount directory")),
            None => fs::create_dir(&path)?,
        }
    }
    Ok(path)
}

fn bind(source: &File, target: &Path, device: bool) -> io::Result<()> {
    let source = CString::new(format!("/proc/self/fd/{}", source.as_raw_fd()))?;
    attach(Some(&source), target, None, libc::MS_BIND, None)?;
    let flags = if device {
        libc::MS_NOSUID | libc::MS_NOEXEC
    } else {
        SAFE | libc::MS_RDONLY
    };
    attach(
        None,
        target,
        None,
        libc::MS_BIND | libc::MS_REMOUNT | flags,
        None,
    )
}

fn attach(
    source: Option<&CStr>,
    target: &Path,
    fs_type: Option<&CStr>,
    flags: libc::c_ulong,
    options: Option<&CStr>,
) -> io::Result<()> {
    let target = CString::new(target.as_os_str().as_bytes())?;
    let pointer = |value: Option<&CStr>| value.map_or(std::ptr::null(), CStr::as_ptr);
    checked(unsafe {
        libc::mount(
            pointer(source),
            target.as_ptr(),
            pointer(fs_type),
            flags,
            pointer(options).cast(),
        )
    })
    .map_err(|error| io::Error::other(format!("mount {}: {error}", target.to_string_lossy())))
}

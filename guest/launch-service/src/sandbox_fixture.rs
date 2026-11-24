use std::collections::{BTreeMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::security::{self, WorkloadFilter};
use crate::spec::{
    GID_BASE, ID_MAP_WIDTH, LaunchSpec, UID_BASE, VOLUME_TARGET, VolumeMount, WORKLOAD_GID,
    WORKLOAD_UID,
};

const BASE: &str = "/run/conjet/workload-probe";
pub(crate) const BENCHMARK_EXECUTABLE: &str = "/etc/conjet/benchmark-executable";
pub(crate) const OCI_ROOT: &str = "/etc/conjet/oci-root";
pub(crate) const OCI_MARKER: &str = "/etc/conjet/native-oci-image";
const OCI_LINKS: &str = "/etc/conjet/native-oci-hardlinks.json";
pub(crate) const NATIVE_EXECUTABLE: &str = "/etc/conjet/native-executable";
const MOVE_MOUNT_F_EMPTY_PATH: libc::c_uint = 0x04; // Linux mount UAPI.

pub(crate) struct Sandbox {
    base: PathBuf,
    new_root: CString,
    root: RootMode,
    cwd: CString,
    filter: WorkloadFilter,
    resolver: Option<std::net::Ipv4Addr>,
    standard_devices: bool,
    stdin: File,
    volume: Option<VolumeBinding>,
    worker_mounts: Option<crate::build_snapshot::mounts::MountPlan>,
    uid: u32,
    gid: u32,
}

enum RootMode {
    Overlay(CString),
    BuildSnapshot(crate::build_snapshot::Snapshot),
}

fn standard_device(name: &str, minor: u32) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_NOFOLLOW)
        .open(Path::new("/dev").join(name))?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_char_device()
        || libc::major(metadata.rdev()) != 1
        || libc::minor(metadata.rdev()) != minor
    {
        return Err(io::Error::other("invalid native standard device identity"));
    }
    Ok(file)
}

fn mount_standard_devices(root: &CStr, devices: [File; 2]) -> io::Result<()> {
    let directory = Path::new(std::ffi::OsStr::from_bytes(root.to_bytes())).join("dev");
    match directory.symlink_metadata() {
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid native device directory")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(&directory)?,
        Err(error) => return Err(error),
    }
    for (name, file) in ["null", "zero"].into_iter().zip(devices) {
        let target_path = directory.join(name);
        match File::create_new(&target_path) {
            Ok(_) => {}
            Err(error)
                if error.kind() == io::ErrorKind::AlreadyExists
                    && target_path.symlink_metadata()?.is_file() => {}
            Err(error) => return Err(error),
        }
        let source = CString::new(format!("/proc/self/fd/{}", file.as_raw_fd()))?;
        let target = CString::new(target_path.as_os_str().as_bytes())?;
        security::checked(unsafe {
            libc::mount(
                source.as_ptr(),
                target.as_ptr(),
                std::ptr::null(),
                libc::MS_BIND,
                std::ptr::null(),
            )
        })?;
        security::checked(unsafe {
            libc::mount(
                std::ptr::null(),
                target.as_ptr(),
                std::ptr::null(),
                libc::MS_BIND | libc::MS_REMOUNT | libc::MS_NOSUID | libc::MS_NOEXEC,
                std::ptr::null(),
            )
        })?;
    }
    Ok(())
}

struct VolumeBinding {
    spec: VolumeMount,
    target_path: PathBuf,
    target: CString,
}

impl VolumeBinding {
    fn prepare(name: &VolumeMount, root: &Path) -> io::Result<Self> {
        let target_path = root.join(VOLUME_TARGET.trim_start_matches('/'));
        Ok(Self {
            spec: name.clone(),
            target: CString::new(target_path.as_os_str().as_bytes())?,
            target_path,
        })
    }

    fn mount(&self, source: File) -> io::Result<()> {
        let source_path = CString::new(format!("/proc/self/fd/{}", source.as_raw_fd()))?;
        match fs::create_dir(&self.target_path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                if !self.target_path.symlink_metadata()?.is_dir()
                    || fs::read_dir(&self.target_path)?.next().is_some()
                {
                    return Err(io::Error::other(
                        "native volume target must be an empty directory",
                    ));
                }
            }
            Err(error) => return Err(error),
        }
        security::checked(unsafe {
            libc::mount(
                source_path.as_ptr(),
                self.target.as_ptr(),
                std::ptr::null(),
                libc::MS_BIND,
                std::ptr::null(),
            )
        })?;
        if self.spec.read_only {
            security::checked(unsafe {
                libc::mount(
                    std::ptr::null(),
                    self.target.as_ptr(),
                    std::ptr::null(),
                    libc::MS_BIND
                        | libc::MS_REMOUNT
                        | libc::MS_RDONLY
                        | libc::MS_NODEV
                        | libc::MS_NOEXEC
                        | libc::MS_NOSUID,
                    std::ptr::null(),
                )
            })?;
        }
        Ok(())
    }
}

impl Sandbox {
    pub(crate) fn prepare(
        bridge: bool,
        executable: &str,
        oci: Option<&LaunchSpec>,
        id: [u8; 16],
        stdin: Option<File>,
    ) -> io::Result<Self> {
        let base = owned_path(id, oci.is_some());
        std::fs::create_dir(&base)?;
        let setup = (|| {
            for entry in ["lower", "lower/bin", "lower/work", "upper", "work", "root"] {
                std::fs::create_dir(base.join(entry))?;
            }
            let snapshot = oci.and_then(|spec| spec.build_snapshot.as_ref());
            let worker_mounts = match (oci, snapshot) {
                (Some(spec), Some(snapshot)) if snapshot.bundle_policy => {
                    let bundle =
                        crate::build_snapshot::guest::load_bundle(&snapshot.id, &spec.image_digest)
                            .map_err(io::Error::other)?;
                    if serde_json::to_vec(&bundle.spec)? != serde_json::to_vec(spec)? {
                        return Err(io::Error::other("build bundle changed before setup"));
                    }
                    Some(crate::build_snapshot::mounts::MountPlan::verify(
                        &bundle.hosts_file,
                    )?)
                }
                _ => None,
            };
            let lower = if snapshot.is_some() {
                base.join("lower")
            } else if let Some(spec) = oci {
                let (lower, links) = if fs::read_to_string(OCI_MARKER)? == spec.image_digest {
                    (
                        Path::new(OCI_ROOT).to_path_buf(),
                        Path::new(OCI_LINKS).to_path_buf(),
                    )
                } else {
                    let imported = crate::image_store::imported_root(&spec.image_digest)
                        .ok_or_else(|| io::Error::other("invalid OCI image digest"))?;
                    let lower = imported.join("root");
                    if !lower.symlink_metadata()?.is_dir() {
                        return Err(io::Error::other("OCI lower root is unavailable"));
                    }
                    (lower, imported.join("hardlinks.json"))
                };
                prepare_oci_hardlinks(&lower, &links, &base.join("upper"))?;
                lower
            } else {
                std::fs::copy(executable, base.join("lower/bin/probe"))?;
                std::fs::set_permissions(
                    base.join("lower/bin/probe"),
                    std::fs::Permissions::from_mode(0o555),
                )?;
                base.join("lower")
            };
            std::fs::write(base.join("lower/work/immutable"), b"verified fixture\n")?;
            if bridge && oci.is_none() {
                std::fs::create_dir(base.join("lower/etc"))?;
                std::fs::write(
                    base.join("lower/etc/resolv.conf"),
                    crate::bridge_fixture::RESOLVER_CONFIG,
                )?;
            }
            for directory in ["upper", "work", "root"] {
                let path = CString::new(base.join(directory).as_os_str().as_bytes())?;
                security::checked(unsafe { libc::chown(path.as_ptr(), UID_BASE, GID_BASE) })?;
                std::fs::set_permissions(
                    base.join(directory),
                    std::fs::Permissions::from_mode(if directory != "work" {
                        0o755
                    } else {
                        0o700
                    }),
                )?;
            }
            let workspace = CString::new(base.join("lower/work").as_os_str().as_bytes())?;
            security::checked(unsafe {
                libc::chown(
                    workspace.as_ptr(),
                    UID_BASE + WORKLOAD_UID,
                    GID_BASE + WORKLOAD_GID,
                )
            })?;
            std::fs::write(
                base.join("outside-canary"),
                b"must stay outside workload root\n",
            )?;
            Ok(Self {
                base: base.clone(),
                cwd: CString::new(oci.map_or("/work", |spec| spec.cwd.as_str()))?,
                new_root: CString::new(base.join("root").as_os_str().as_bytes())?,
                root: match snapshot {
                    Some(snapshot) => RootMode::BuildSnapshot(snapshot.clone()),
                    None => RootMode::Overlay(CString::new(format!(
                        "lowerdir={},upperdir={}/upper,workdir={}/work,userxattr",
                        lower.display(),
                        base.display(),
                        base.display()
                    ))?),
                },
                filter: WorkloadFilter::new(
                    bridge,
                    oci.is_some_and(|spec| spec.build_snapshot.is_none()),
                ),
                resolver: oci
                    .and_then(|spec| spec.bridge_scope())
                    .map(|scope| scope.gateway()),
                standard_devices: oci.is_some_and(|spec| spec.build_snapshot.is_none()),
                stdin: match stdin {
                    Some(stdin) => stdin,
                    None => File::open("/dev/null")?,
                },
                volume: oci
                    .and_then(|spec| spec.volume.as_ref())
                    .map(|volume| VolumeBinding::prepare(volume, &base.join("root")))
                    .transpose()?,
                worker_mounts,
                uid: oci.map_or(WORKLOAD_UID, |spec| spec.uid),
                gid: oci.map_or(WORKLOAD_GID, |spec| spec.gid),
            })
        })();
        if setup.is_err() {
            let _ = std::fs::remove_dir_all(&base);
        }
        setup
    }

    pub(crate) fn mappings(&self, pid: libc::pid_t) -> io::Result<()> {
        let process = Path::new("/proc").join(pid.to_string());
        std::fs::write(process.join("setgroups"), "deny")?;
        std::fs::write(
            process.join("uid_map"),
            format!("0 {UID_BASE} {ID_MAP_WIDTH}\n"),
        )?;
        std::fs::write(
            process.join("gid_map"),
            format!("0 {GID_BASE} {ID_MAP_WIDTH}\n"),
        )
    }

    pub(crate) fn snapshot_mount(&self, pid: libc::pid_t) -> io::Result<Option<OwnedFd>> {
        let RootMode::BuildSnapshot(snapshot) = &self.root else {
            return Ok(None);
        };
        // The helper owns this child PID and has yet to open its startup gate.
        let user = File::open(format!("/proc/{pid}/ns/user"))?;
        crate::build_snapshot::guest::mapped_mount(snapshot, &user)
            .map(Some)
            .map_err(|error| io::Error::other(format!("map build snapshot IDs: {error}")))
    }

    pub(crate) fn enter(
        &self,
        snapshot_mount: Option<OwnedFd>,
        sysfs: Option<OwnedFd>,
        before_filter: impl FnOnce() -> io::Result<()>,
    ) -> io::Result<()> {
        fn step(name: &str, result: io::Result<()>) -> io::Result<()> {
            result.map_err(|error| io::Error::other(format!("{name}: {error}")))
        }
        // Open the trusted inode in the child's mount namespace. A descriptor
        // opened before clone refers to the parent's mount and cannot be used
        // for a bind here. The child still owns its inherited guest UID when
        // opening the registry; only stdio survives into the workload.
        let volume_source = self
            .volume
            .as_ref()
            .map(|volume| {
                crate::volume_disk::guest::mount_source(&volume.spec)
                    .map_err(|error| io::Error::other(format!("open named volume: {error}")))
            })
            .transpose()?;
        let worker = self
            .worker_mounts
            .as_ref()
            .map(crate::build_snapshot::mounts::MountPlan::open)
            .transpose()?;
        let devices = if self.standard_devices {
            Some([standard_device("null", 3)?, standard_device("zero", 5)?])
        } else {
            None
        };
        // The child inherited the helper's outer guest IDs. Enter the mapped
        // namespace-root identity before accessing the owned upper/work dirs.
        step(
            "mapped setup gid",
            security::checked(unsafe { libc::setresgid(0, 0, 0) }),
        )?;
        step(
            "mapped setup uid",
            security::checked(unsafe { libc::setresuid(0, 0, 0) }),
        )?;
        step(
            "private mount propagation",
            security::checked(unsafe {
                libc::mount(
                    std::ptr::null(),
                    c"/".as_ptr(),
                    std::ptr::null(),
                    libc::MS_PRIVATE | libc::MS_REC,
                    std::ptr::null(),
                )
            }),
        )?;
        match &self.root {
            RootMode::Overlay(options) => step(
                "private overlay",
                security::checked(unsafe {
                    libc::mount(
                        c"overlay".as_ptr(),
                        self.new_root.as_ptr(),
                        c"overlay".as_ptr(),
                        libc::MS_NODEV | libc::MS_NOSUID,
                        options.as_ptr().cast(),
                    )
                }),
            )?,
            RootMode::BuildSnapshot(_) => {
                let source = snapshot_mount
                    .ok_or_else(|| io::Error::other("missing mapped build snapshot"))?;
                step(
                    "private build snapshot",
                    security::checked(unsafe {
                        libc::syscall(
                            libc::SYS_move_mount,
                            source.as_raw_fd(),
                            c"".as_ptr(),
                            libc::AT_FDCWD,
                            self.new_root.as_ptr(),
                            MOVE_MOUNT_F_EMPTY_PATH,
                        ) as i32
                    }),
                )?;
            }
        }
        if let Some((volume, source)) = self.volume.as_ref().zip(volume_source) {
            step("private named volume", volume.mount(source))?;
        }
        if let Some(devices) = devices {
            step(
                "native standard devices",
                mount_standard_devices(&self.new_root, devices),
            )?;
        }
        if let Some(worker) = worker {
            let sysfs = sysfs.ok_or_else(|| io::Error::other("missing worker sysfs mount"))?;
            let root = Path::new(std::ffi::OsStr::from_bytes(self.new_root.as_bytes()));
            worker.mount(root, sysfs)?;
        }
        if unsafe { libc::dup2(self.stdin.as_raw_fd(), libc::STDIN_FILENO) } < 0 {
            return Err(io::Error::other(format!(
                "closed stdin: {}",
                io::Error::last_os_error()
            )));
        }
        step(
            "chroot",
            security::checked(unsafe { libc::chroot(self.new_root.as_ptr()) }),
        )?;
        step(
            "working directory",
            security::checked(unsafe { libc::chdir(self.cwd.as_ptr()) }),
        )?;
        if let Some(gateway) = self.resolver {
            match fs::symlink_metadata("/etc") {
                Ok(metadata) if metadata.is_dir() => {}
                Ok(_) => return Err(io::Error::other("invalid networked image /etc directory")),
                Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir("/etc")?,
                Err(error) => return Err(error),
            }
            match std::fs::remove_file("/etc/resolv.conf") {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
            use std::io::Write;
            writeln!(
                File::create_new("/etc/resolv.conf")?,
                "nameserver {gateway}"
            )?;
        }
        // Only stdio may survive. The fixture's syscall code needs no inherited directory handle.
        if unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } != 0 {
            return Err(io::Error::other(format!(
                "close inherited descriptors: {}",
                io::Error::last_os_error()
            )));
        }
        step("resource limits", security::set_process_limits())?;
        step(
            "credentials and capabilities",
            security::drop_workload_identity(self.uid, self.gid, self.worker_mounts.is_some()),
        )?;
        before_filter()?;
        step("seccomp", self.filter.install())
    }

    pub(crate) fn cleanup(self, verify_write: bool) -> io::Result<()> {
        if std::fs::read(self.base.join("lower/work/immutable"))? != b"verified fixture\n" {
            return Err(io::Error::other(
                "fixture modified its immutable lower root",
            ));
        }
        if verify_write
            && (std::fs::read(self.base.join("upper/work/new-proof"))? != b"private write\n"
                || self.base.join("lower/work/new-proof").exists())
        {
            return Err(io::Error::other(
                "fixture write did not stay in its private upper root",
            ));
        }
        std::fs::remove_dir_all(self.base)
    }
}

pub(crate) fn owned_path(id: [u8; 16], oci: bool) -> PathBuf {
    if oci {
        PathBuf::from(format!("{BASE}-{}", crate::handshake::hex(&id)))
    } else {
        PathBuf::from(BASE)
    }
}

pub(crate) fn recover(id: [u8; 16], oci: bool) -> io::Result<()> {
    let base = owned_path(id, oci);
    for (relative, expected) in [
        ("lower/work/immutable", &b"verified fixture\n"[..]),
        ("outside-canary", &b"must stay outside workload root\n"[..]),
    ] {
        match std::fs::read(base.join(relative)) {
            Ok(bytes) if bytes == expected => {}
            Ok(_) => return Err(io::Error::other("fixture recovery found a modified canary")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    if base.try_exists()? {
        std::fs::remove_dir_all(&base)?;
    }
    check_absent(&base)
}

pub(crate) fn assert_absent() -> io::Result<()> {
    check_absent(Path::new(BASE))
}

pub(crate) fn assert_owned_absent(id: [u8; 16]) -> io::Result<()> {
    check_absent(&owned_path(id, true))
}

fn check_absent(path: &Path) -> io::Result<()> {
    if path.try_exists()? {
        return Err(io::Error::other("unclaimed fixture sandbox"));
    }
    Ok(())
}

pub fn verify_after_exec() -> io::Result<()> {
    if unsafe { libc::geteuid() } != WORKLOAD_UID || unsafe { libc::getegid() } != WORKLOAD_GID {
        return Err(io::Error::other(
            "unexpected effective application credentials",
        ));
    }
    if unsafe { libc::getgroups(0, std::ptr::null_mut()) } != 0 {
        return Err(io::Error::other("application has supplementary groups"));
    }
    security::verify_empty_capabilities()?;
    let socket = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if socket >= 0 {
        unsafe { libc::close(socket) };
        return Err(io::Error::other(
            "no-network seccomp policy allowed a socket",
        ));
    }
    if io::Error::last_os_error().raw_os_error() != Some(libc::EPERM) {
        return Err(io::Error::other("unexpected seccomp test result"));
    }
    if std::fs::read("/work/immutable")? != b"verified fixture\n"
        || std::fs::read("/run/conjet/workload-probe/outside-canary").is_ok()
    {
        return Err(io::Error::other("unexpected root filesystem visibility"));
    }
    std::fs::write("/work/new-proof", b"private write\n")?;
    println!(
        "conjet-launchd application verified private root, credentials, and seccomp after exec"
    );
    Ok(())
}

// On the tested overlay filesystem, copying up one lower hard link breaks
// its aliases even with index=on. Seed complete groups in the private upper
// before mounting it so both link identity and lower immutability survive.
fn prepare_oci_hardlinks(lower: &Path, manifest: &Path, upper: &Path) -> io::Result<()> {
    const MAX_LINKS: usize = 4096;
    const MAX_METADATA: u64 = 5 * 1024 * 1024;
    const MAX_CONTENT: u64 = 40 * 1024 * 1024;

    let file = match File::open(manifest) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.mode() & 0o022 != 0
        || metadata.len() > MAX_METADATA
    {
        return Err(io::Error::other("invalid native OCI hard-link manifest"));
    }
    let groups: BTreeMap<String, Vec<String>> = serde_json::from_reader(file.take(MAX_METADATA))?;
    let mut seen = HashSet::new();
    let mut copied = 0;
    for (source, aliases) in &groups {
        if aliases.is_empty() {
            return Err(io::Error::other("OCI hard-link group is empty"));
        }
        for path in std::iter::once(source).chain(aliases) {
            if path.len() > 1024
                || path.contains('\0')
                || path.split('/').any(|part| matches!(part, "" | "." | ".."))
                || seen.len() == MAX_LINKS
                || !seen.insert(path)
            {
                return Err(io::Error::other("invalid OCI hard-link path"));
            }
            for (index, _) in path.match_indices('/') {
                let directory = &path[..index];
                let origin = lower.join(directory).symlink_metadata()?;
                if !origin.is_dir() {
                    return Err(io::Error::other("OCI hard link traverses a non-directory"));
                }
                let target = upper.join(directory);
                match fs::create_dir(&target) {
                    Ok(()) => copy_owner_mode(&target, &origin)?,
                    Err(error)
                        if error.kind() == io::ErrorKind::AlreadyExists
                            && target.symlink_metadata()?.is_dir() => {}
                    Err(error) => return Err(error),
                }
            }
        }
        let origin = lower.join(source).symlink_metadata()?;
        copied = origin
            .len()
            .checked_add(copied)
            .ok_or_else(|| io::Error::other("OCI hard-link content overflow"))?;
        if !origin.is_file() || copied > MAX_CONTENT {
            return Err(io::Error::other("invalid OCI hard-link source"));
        }
        for alias in aliases {
            let metadata = lower.join(alias).symlink_metadata()?;
            if !metadata.is_file()
                || origin.ino() != metadata.ino()
                || origin.dev() != metadata.dev()
            {
                return Err(io::Error::other("OCI hard-link identity changed"));
            }
        }
        let target = upper.join(source);
        fs::copy(lower.join(source), &target)?;
        copy_owner_mode(&target, &origin)?;
        for alias in aliases {
            fs::hard_link(&target, upper.join(alias))?;
        }
    }
    Ok(())
}

fn copy_owner_mode(path: &Path, metadata: &Metadata) -> io::Result<()> {
    let c_path = CString::new(path.as_os_str().as_bytes())?;
    // Origin is a verified inode under the boot-staged OCI lower root.
    security::checked(unsafe { libc::chown(c_path.as_ptr(), metadata.uid(), metadata.gid()) })?;
    let kind = if metadata.is_dir() {
        crate::oci::Kind::Directory
    } else {
        crate::oci::Kind::File
    };
    fs::set_permissions(
        path,
        fs::Permissions::from_mode(metadata.mode() & crate::oci::mode_mask(kind)),
    )
}

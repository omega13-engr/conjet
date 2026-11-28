use std::collections::{BTreeMap, HashSet};
use std::ffi::{CStr, CString, OsStr};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::security::{self, WorkloadFilter, WorkloadPolicy};
use crate::spec::{
    GID_BASE, ID_MAP_WIDTH, LaunchSpec, UID_BASE, VolumeMount, WORKLOAD_GID, WORKLOAD_UID,
    valid_volume_target,
};

const BASE: &str = "/run/conjet/workload-probe";
pub(crate) const BENCHMARK_EXECUTABLE: &str = "/etc/conjet/benchmark-executable";
pub(crate) const OCI_ROOT: &str = "/etc/conjet/oci-root";
pub(crate) const OCI_MARKER: &str = "/etc/conjet/native-oci-image";
const OCI_LINKS: &str = "/etc/conjet/native-oci-hardlinks.json";
pub(crate) const NATIVE_EXECUTABLE: &str = "/etc/conjet/native-executable";
const MOVE_MOUNT_F_EMPTY_PATH: libc::c_uint = 0x04; // Linux mount UAPI.

pub(crate) fn image_lower(digest: &str) -> io::Result<(PathBuf, PathBuf)> {
    if fs::read_to_string(OCI_MARKER)? == digest {
        return Ok((PathBuf::from(OCI_ROOT), PathBuf::from(OCI_LINKS)));
    }
    let imported = crate::image_store::imported_root(digest)
        .ok_or_else(|| io::Error::other("invalid OCI image digest"))?;
    let lower = imported.join("root");
    if !lower.symlink_metadata()?.is_dir() {
        return Err(io::Error::other("OCI lower root is unavailable"));
    }
    Ok((lower, imported.join("hardlinks.json")))
}

pub(crate) struct Sandbox {
    base: PathBuf,
    new_root: CString,
    root: RootMode,
    rootfs_read_only: bool,
    open_files_limit: Option<crate::spec::OpenFilesLimit>,
    _retained_layer: Option<crate::workload_layers::Layer>,
    cwd: CString,
    filter: WorkloadFilter,
    resolver: Option<std::net::Ipv4Addr>,
    standard_devices: bool,
    stdin: File,
    tty: bool,
    volume: Vec<FileBinding>,
    tmpfs: Vec<crate::spec::TmpfsMount>,
    worker_mounts: Option<crate::build_snapshot::mounts::MountPlan>,
    build_sysfs_view: bool,
    live_mounts: Option<crate::build_snapshot::mounts::LiveMounts>,
    groups: Vec<u32>,
    uid: u32,
    gid: u32,
    redis_bootstrap: bool,
    buildkit_image: bool,
    buildkit_registry: bool,
    policy: WorkloadPolicy,
    docker_net_admin: bool,
    syscall_denials: Vec<crate::spec::SyscallDenial>,
}

enum RootMode {
    Overlay(CString),
    BuildSnapshot(crate::build_snapshot::Snapshot),
}

fn standard_device(name: &str, minor: u32) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_NOFOLLOW)
        .open(Path::new("/dev").join(name))
        .map_err(|error| io::Error::other(format!("open standard device /dev/{name}: {error}")))?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_char_device()
        || libc::major(metadata.rdev()) != 1
        || libc::minor(metadata.rdev()) != minor
    {
        return Err(io::Error::other("invalid native standard device identity"));
    }
    Ok(file)
}

pub(crate) fn standard_devices() -> io::Result<[File; 5]> {
    Ok([
        standard_device("null", 3)?,
        standard_device("zero", 5)?,
        standard_device("full", 7)?,
        standard_device("random", 8)?,
        standard_device("urandom", 9)?,
    ])
}

pub(crate) fn mount_standard_devices(root: &CStr, devices: [File; 5]) -> io::Result<()> {
    let directory = Path::new(std::ffi::OsStr::from_bytes(root.to_bytes())).join("dev");
    match directory.symlink_metadata() {
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid native device directory")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(&directory)?,
        Err(error) => return Err(error),
    }
    for (name, file) in ["null", "zero", "full", "random", "urandom"]
        .into_iter()
        .zip(devices)
    {
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

fn prepare_container_devices(root: &CStr, devices: [File; 5]) -> io::Result<()> {
    mount_standard_devices(root, devices)?;
    let directory = Path::new(std::ffi::OsStr::from_bytes(root.to_bytes())).join("dev");
    for (name, target) in [
        ("fd", "/proc/self/fd"),
        ("stdin", "/proc/self/fd/0"),
        ("stdout", "/proc/self/fd/1"),
        ("stderr", "/proc/self/fd/2"),
    ] {
        let path = directory.join(name);
        match std::os::unix::fs::symlink(target, &path) {
            Ok(()) => {}
            Err(error)
                if error.kind() == io::ErrorKind::AlreadyExists
                    && fs::read_link(&path).is_ok_and(|actual| actual == Path::new(target)) => {}
            Err(error) => return Err(error),
        }
    }
    let shm = directory.join("shm");
    match fs::create_dir(&shm) {
        Ok(()) => {}
        Err(error)
            if error.kind() == io::ErrorKind::AlreadyExists && shm.symlink_metadata()?.is_dir() => {
        }
        Err(error) => return Err(error),
    }
    let target = CString::new(shm.as_os_str().as_bytes())?;
    security::checked(unsafe {
        libc::mount(
            c"tmpfs".as_ptr(),
            target.as_ptr(),
            c"tmpfs".as_ptr(),
            libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC,
            c"mode=1777,size=65536k".as_ptr().cast(),
        )
    })
}

enum BindingSource {
    Volume(VolumeMount),
    BuildKitCache(VolumeMount),
    Bind(crate::spec::BindMount),
}

fn mount_cgroup(root: &CStr, source: File) -> io::Result<()> {
    let mut target = PathBuf::from(OsStr::from_bytes(root.to_bytes()));
    for component in ["sys", "fs", "cgroup"] {
        target.push(component);
        match fs::create_dir(&target) {
            Ok(()) => {}
            Err(error)
                if error.kind() == io::ErrorKind::AlreadyExists
                    && target.symlink_metadata()?.is_dir() => {}
            Err(error) => return Err(error),
        }
    }
    if fs::read_dir(&target)?.next().is_some() {
        return Err(io::Error::other("native cgroup mount target must be empty"));
    }
    let target = CString::new(target.as_os_str().as_bytes())?;
    let source_path = CString::new(format!("/proc/self/fd/{}", source.as_raw_fd()))?;
    security::checked(unsafe {
        libc::mount(
            source_path.as_ptr(),
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
            libc::MS_BIND
                | libc::MS_REMOUNT
                | libc::MS_RDONLY
                | libc::MS_NODEV
                | libc::MS_NOSUID
                | libc::MS_NOEXEC,
            std::ptr::null(),
        )
    })
}

fn mount_workload_proc(root: &CStr, pid_only: bool) -> io::Result<()> {
    let target = Path::new(std::ffi::OsStr::from_bytes(root.to_bytes())).join("proc");
    match fs::symlink_metadata(&target) {
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid workload /proc directory")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(&target)?,
        Err(error) => return Err(error),
    }
    let target = CString::new(target.as_os_str().as_bytes())?;
    security::checked(unsafe {
        libc::mount(
            c"proc".as_ptr(),
            target.as_ptr(),
            c"proc".as_ptr(),
            libc::MS_RDONLY | libc::MS_NODEV | libc::MS_NOSUID | libc::MS_NOEXEC,
            if pid_only {
                c"subset=pid".as_ptr().cast()
            } else {
                std::ptr::null()
            },
        )
    })
}

fn prepare_buildkit_worker(root: &CStr, registry: bool) -> io::Result<()> {
    let root = Path::new(std::ffi::OsStr::from_bytes(root.to_bytes()));
    for relative in ["usr", "usr/bin", "run", "run/conjet", "run/conjet/buildkit"] {
        let path = root.join(relative);
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_dir() => {}
            Ok(_) => return Err(io::Error::other("invalid BuildKit worker directory")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(path)?,
            Err(error) => return Err(error),
        }
    }
    let mut runtime = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o555)
        .open(root.join("usr/bin/conjet-buildkit-runtime"))?;
    io::copy(&mut File::open("/init")?, &mut runtime)?;
    if registry {
        use std::io::Write;
        let address = crate::spec::BridgeScope::BuiltIn.gateway();
        let port = crate::spec::BUILDKIT_REGISTRY_PORT;
        let mut config = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o444)
            .open(root.join("run/conjet/buildkit-registry.toml"))?;
        writeln!(
            config,
            "[registry.\"docker.io\"]\nmirrors = [\"{address}:{port}\"]"
        )?;
        writeln!(config, "[registry.\"{address}:{port}\"]\nhttp = true")?;
    }
    std::os::unix::fs::symlink("/var/lib/buildkit", root.join("run/conjet/buildkit/worker"))?;
    crate::build_snapshot::worker_control::mount(root)
}

fn expose_cpu_information(root: &CStr) -> io::Result<()> {
    use std::io::{Read, Write};

    let directory = Path::new(std::ffi::OsStr::from_bytes(root.to_bytes())).join("proc");
    match fs::symlink_metadata(&directory) {
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid BuildKit proc directory")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(&directory)?,
        Err(error) => return Err(error),
    }
    let mut data = Vec::new();
    File::open("/proc/cpuinfo")?
        .take(65_537)
        .read_to_end(&mut data)?;
    if data.is_empty() || data.len() > 65_536 {
        return Err(io::Error::other("invalid guest CPU information length"));
    }
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o444)
        .open(directory.join("cpuinfo"))?
        .write_all(&data)
}

struct FileBinding {
    source: BindingSource,
    destination: String,
    read_only: bool,
    root: PathBuf,
    target: CString,
}

fn prepare_mount_target(root: &Path, destination: &str) -> io::Result<PathBuf> {
    // The overlay has no running workload during setup. Inspect image ancestors
    // before following them and keep all mounts beneath the private root.
    let mut target = root.to_path_buf();
    for segment in destination.trim_start_matches('/').split('/') {
        target.push(segment);
        match fs::create_dir(&target) {
            Ok(()) => {}
            Err(error)
                if error.kind() == io::ErrorKind::AlreadyExists
                    && target.symlink_metadata()?.is_dir() => {}
            Err(error) => return Err(error),
        }
    }
    Ok(target)
}

fn mount_tmpfs(root: &CStr, mount: &crate::spec::TmpfsMount) -> io::Result<()> {
    let root = Path::new(OsStr::from_bytes(root.to_bytes()));
    let target = prepare_mount_target(root, &mount.target)?;
    let target = CString::new(target.as_os_str().as_bytes())?;
    let mut options = format!("uid={},gid={},mode={:o}", mount.uid, mount.gid, mount.mode);
    if let Some(bytes) = mount.size_bytes {
        use std::fmt::Write;
        write!(options, ",size={bytes}").expect("write string");
    }
    let options = CString::new(options)?;
    let mut flags = libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC;
    if mount.read_only {
        flags |= libc::MS_RDONLY;
    }
    security::checked(unsafe {
        libc::mount(
            c"tmpfs".as_ptr(),
            target.as_ptr(),
            c"tmpfs".as_ptr(),
            flags,
            options.as_ptr().cast(),
        )
    })
}

impl FileBinding {
    fn prepare(spec: &LaunchSpec, root: &Path) -> io::Result<Vec<Self>> {
        let mut sources = Vec::new();
        if let Some(volume) = &spec.volume {
            if !valid_volume_target(&volume.target) {
                return Err(io::Error::other("unsupported native named volume target"));
            }
            let source = if spec.buildkit_worker {
                BindingSource::BuildKitCache(volume.clone())
            } else {
                BindingSource::Volume(volume.clone())
            };
            sources.push((source, volume.target.clone(), volume.read_only));
        }
        for bind in spec.host_binds() {
            if !crate::spec::valid_bind_target(&bind.target) {
                return Err(io::Error::other("invalid native bind target"));
            }
            sources.push((
                BindingSource::Bind(bind.clone()),
                bind.target.clone(),
                bind.read_only,
            ));
        }
        sources
            .into_iter()
            .map(|(source, destination, read_only)| {
                let path = root.join(destination.trim_start_matches('/'));
                Ok(Self {
                    source,
                    destination,
                    read_only,
                    target: CString::new(path.as_os_str().as_bytes())?,
                    root: root.to_owned(),
                })
            })
            .collect()
    }

    fn open(&self) -> io::Result<File> {
        match &self.source {
            BindingSource::Volume(volume) => crate::volume_disk::guest::mount_source(volume),
            BindingSource::BuildKitCache(volume) => {
                crate::volume_disk::guest::worker_cache_mount_source(volume)
            }
            BindingSource::Bind(bind) => crate::bind_mount::source(&bind.lease),
        }
    }

    fn mount(&self, source: File) -> io::Result<()> {
        let source_path = CString::new(format!("/proc/self/fd/{}", source.as_raw_fd()))?;
        let target = prepare_mount_target(&self.root, &self.destination)?;
        if fs::read_dir(&target)?.next().is_some() {
            return Err(io::Error::other("native volume target must be empty"));
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
        if self.read_only {
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
        live_mounts: Option<crate::build_snapshot::mounts::LiveMounts>,
    ) -> io::Result<Self> {
        let base = owned_path(id, oci.is_some());
        std::fs::create_dir(&base)?;
        let setup = (|| {
            for entry in ["lower", "lower/bin", "lower/work", "upper", "work", "root"] {
                std::fs::create_dir(base.join(entry))?;
            }
            let snapshot = oci.and_then(|spec| spec.build_snapshot.as_ref());
            let retained = oci
                .and_then(|spec| {
                    spec.retained_layer
                        .as_deref()
                        .map(|id| (id, &spec.image_digest))
                })
                .map(|(id, digest)| crate::workload_layers::Layer::open(id, digest))
                .transpose()?;
            let writable = retained
                .as_ref()
                .map_or(base.as_path(), crate::workload_layers::Layer::path);
            let worker_mounts = match (oci, snapshot) {
                (Some(spec), Some(snapshot)) if snapshot.bundle_policy && !snapshot.live_worker => {
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
            if snapshot.is_some_and(|snapshot| snapshot.live_worker) != live_mounts.is_some() {
                return Err(io::Error::other("unexpected live snapshot mount lease"));
            }
            let groups =
                if let Some(groups) = snapshot.and_then(|s| s.supplementary_groups.as_ref()) {
                    groups.clone()
                } else if live_mounts.is_some() && oci.is_some_and(|spec| spec.uid == 0) {
                    crate::build_snapshot::bundle::LIVE_GROUPS.to_vec()
                } else if worker_mounts.is_some() || live_mounts.is_some() {
                    vec![WORKLOAD_GID]
                } else {
                    Vec::new()
                };
            let lower = if snapshot.is_some() {
                base.join("lower")
            } else if let Some(spec) = oci {
                let (lower, links) = image_lower(&spec.image_digest)?;
                if retained.as_ref().is_none_or(|layer| !layer.initialized()) {
                    prepare_oci_hardlinks(&lower, &links, &writable.join("upper"))?;
                    if let Some(layer) = &retained {
                        layer.finish_setup(&spec.image_digest)?;
                    }
                }
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
            let policy = if oci.is_some_and(|spec| spec.buildkit_worker) {
                WorkloadPolicy::BuildKitWorker
            } else if live_mounts.is_some() {
                WorkloadPolicy::BuildKitRun
            } else if oci.is_some_and(|spec| spec.redis_bootstrap) {
                WorkloadPolicy::RedisBootstrap
            } else if oci.is_some_and(|spec| spec.docker_default_capabilities) {
                WorkloadPolicy::DockerDefault
            } else if oci.is_some_and(|spec| spec.build_snapshot.is_none()) {
                WorkloadPolicy::DockerRestricted
            } else {
                WorkloadPolicy::Standard
            };
            Ok(Self {
                base: base.clone(),
                cwd: CString::new(oci.map_or("/work", |spec| spec.cwd.as_str()))?,
                new_root: CString::new(base.join("root").as_os_str().as_bytes())?,
                root: match snapshot {
                    Some(snapshot) => RootMode::BuildSnapshot(snapshot.clone()),
                    None => RootMode::Overlay(CString::new(format!(
                        "lowerdir={},upperdir={}/upper,workdir={}/work,userxattr",
                        lower.display(),
                        writable.display(),
                        writable.display()
                    ))?),
                },
                rootfs_read_only: oci.is_some_and(|spec| spec.rootfs_read_only),
                open_files_limit: oci.and_then(|spec| spec.open_files_limit),
                _retained_layer: retained,
                filter: WorkloadFilter::new(
                    bridge,
                    oci.is_some_and(|spec| spec.build_snapshot.is_none()) || live_mounts.is_some(),
                    policy,
                ),
                resolver: oci
                    .and_then(|spec| spec.bridge_scope())
                    .map(|scope| scope.gateway()),
                standard_devices: oci.is_some_and(|spec| spec.build_snapshot.is_none()),
                tty: oci.is_some_and(|spec| spec.tty),
                stdin: match stdin {
                    Some(stdin) => stdin,
                    None => File::open("/dev/null")?,
                },
                volume: oci
                    .map(|spec| FileBinding::prepare(spec, &base.join("root")))
                    .transpose()?
                    .unwrap_or_default(),
                tmpfs: oci.map_or_else(Vec::new, |spec| spec.tmpfs.clone()),
                worker_mounts,
                build_sysfs_view: oci.is_some_and(LaunchSpec::build_sysfs_view),
                live_mounts,
                groups,
                uid: oci.map_or(WORKLOAD_UID, |spec| spec.uid),
                gid: oci.map_or(WORKLOAD_GID, |spec| spec.gid),
                redis_bootstrap: oci.is_some_and(|spec| spec.redis_bootstrap),
                buildkit_image: oci
                    .is_some_and(|spec| crate::spec::approved_buildkit_config(&spec.image_digest)),
                buildkit_registry: oci.is_some_and(LaunchSpec::buildkit_registry),
                policy,
                docker_net_admin: oci.is_some_and(|spec| spec.docker_net_admin),
                syscall_denials: oci.map_or_else(Vec::new, |spec| spec.syscall_denials.clone()),
            })
        })();
        if setup.is_err() {
            let _ = std::fs::remove_dir_all(&base);
        }
        setup
    }

    pub(crate) fn mappings(&self, pid: libc::pid_t) -> io::Result<()> {
        let process = Path::new("/proc").join(pid.to_string());
        if !self.redis_bootstrap
            && !matches!(
                self.policy,
                WorkloadPolicy::BuildKitRun | WorkloadPolicy::DockerDefault
            )
        {
            std::fs::write(process.join("setgroups"), "deny")?;
        }
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
        if let Some(mounts) = &self.live_mounts {
            return mounts.root.try_clone().map(Some);
        }
        // The helper owns this child PID and has yet to open its startup gate.
        let user = File::open(format!("/proc/{pid}/ns/user"))?;
        crate::build_snapshot::guest::mapped_mount(snapshot, &user)
            .map(Some)
            .map_err(|error| io::Error::other(format!("map build snapshot IDs: {error}")))
    }

    pub(crate) fn inherits_worker_network(&self) -> bool {
        self.live_mounts
            .as_ref()
            .is_some_and(|mounts| mounts.inherits_network())
    }

    pub(crate) fn groups(&self) -> &[u32] {
        &self.groups
    }

    pub(crate) fn enter(
        &self,
        snapshot_mount: Option<OwnedFd>,
        sysfs: Option<OwnedFd>,
        cgroup_path: Option<&Path>,
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
            .iter()
            .map(FileBinding::open)
            .collect::<io::Result<Vec<_>>>()?;
        let cgroup = cgroup_path
            .map(|path| {
                OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW)
                    .open(path)
            })
            .transpose()?;
        let worker = if let Some(mounts) = &self.live_mounts {
            Some(mounts.sources()?)
        } else {
            self.worker_mounts
                .as_ref()
                .map(crate::build_snapshot::mounts::MountPlan::open)
                .transpose()?
        };
        let devices = if self.standard_devices {
            Some(standard_devices()?)
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
        for (volume, source) in self.volume.iter().zip(volume_source) {
            step("private workload mount", volume.mount(source))?;
        }
        for mount in &self.tmpfs {
            step("private tmpfs mount", mount_tmpfs(&self.new_root, mount))?;
        }
        if let Some(cgroup) = cgroup {
            step("workload cgroup view", mount_cgroup(&self.new_root, cgroup))?;
        }
        if self.redis_bootstrap {
            step(
                "workload PID view",
                mount_workload_proc(&self.new_root, true),
            )?;
        }
        match self.policy {
            WorkloadPolicy::DockerDefault | WorkloadPolicy::DockerRestricted => {
                step(
                    "container proc view",
                    mount_workload_proc(&self.new_root, false),
                )?;
            }
            WorkloadPolicy::BuildKitWorker => {
                step(
                    "BuildKit worker proc view",
                    mount_workload_proc(&self.new_root, false),
                )?;
                step(
                    "BuildKit native runtime",
                    prepare_buildkit_worker(&self.new_root, self.buildkit_registry),
                )?;
            }
            _ if self.buildkit_image => {
                step(
                    "pinned BuildKit CPU information",
                    expose_cpu_information(&self.new_root),
                )?;
            }
            _ => {}
        }
        if let Some(devices) = devices {
            step(
                "native standard devices",
                prepare_container_devices(&self.new_root, devices),
            )?;
        }
        if let Some(worker) = worker {
            if sysfs.is_some() != self.build_sysfs_view {
                return Err(io::Error::other("unexpected worker sysfs mount"));
            }
            let root = Path::new(std::ffi::OsStr::from_bytes(self.new_root.as_bytes()));
            worker.mount(root, sysfs)?;
        }
        if self.tty {
            if unsafe { libc::setsid() } < 0 {
                return Err(io::Error::last_os_error());
            }
            step(
                "workload controlling terminal",
                security::checked(unsafe {
                    libc::ioctl(self.stdin.as_raw_fd(), libc::TIOCSCTTY, 0)
                }),
            )?;
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
        if self.rootfs_read_only {
            // The outer root can be made read-only without changing the
            // independently mounted named volumes or standard devices.
            step(
                "read-only workload root",
                security::checked(unsafe {
                    libc::mount(
                        std::ptr::null(),
                        c"/".as_ptr(),
                        std::ptr::null(),
                        libc::MS_BIND
                            | libc::MS_REMOUNT
                            | libc::MS_RDONLY
                            | libc::MS_NODEV
                            | libc::MS_NOSUID,
                        std::ptr::null(),
                    )
                }),
            )?;
        }
        // Only stdio may survive. The fixture's syscall code needs no inherited directory handle.
        if unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } != 0 {
            return Err(io::Error::other(format!(
                "close inherited descriptors: {}",
                io::Error::last_os_error()
            )));
        }
        let (open_files, file_size) = match self.policy {
            WorkloadPolicy::BuildKitWorker
            | WorkloadPolicy::BuildKitRun
            | WorkloadPolicy::DockerDefault
            | WorkloadPolicy::DockerRestricted => {
                (security::BUILDKIT_OPEN_FILES, security::BUILDKIT_FILE_SIZE)
            }
            WorkloadPolicy::RedisBootstrap => {
                (security::REDIS_OPEN_FILES, security::DEFAULT_FILE_SIZE)
            }
            _ => (security::DEFAULT_OPEN_FILES, security::DEFAULT_FILE_SIZE),
        };
        step(
            "resource limits",
            security::set_process_limits(open_files, file_size, self.open_files_limit),
        )?;
        step(
            "credentials and capabilities",
            security::drop_workload_identity(
                self.uid,
                self.gid,
                &self.groups,
                self.policy,
                self.docker_net_admin,
            ),
        )?;
        before_filter()?;
        step("exec signals", security::prepare_exec_signals())?;
        step(
            "seccomp syscall denials",
            security::install_syscall_denials(&self.syscall_denials),
        )?;
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

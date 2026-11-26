//! Identity of a private BuildKit worker's mounted root filesystem.

use serde::{Deserialize, Serialize};

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod bundle;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod mounts;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod worker_control;

pub const MARKER: &str = "/etc/conjet/native-build-snapshot";
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub const CONTROL_ADDRESS: &[u8] = b"conjet-build-snapshot-v1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Snapshotter {
    Native,
    Overlay,
}

impl Snapshotter {
    pub const fn worker_arg(self) -> &'static str {
        match self {
            Self::Native => "--oci-worker-snapshotter=native",
            Self::Overlay => "--oci-worker-snapshotter=overlayfs",
        }
    }

    #[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
    const fn worker_directory(self) -> &'static str {
        match self {
            Self::Native => "runc-native",
            Self::Overlay => "runc-overlayfs",
        }
    }

    #[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
    pub(crate) const fn executor(self) -> &'static str {
        match self {
            Self::Native => "/var/lib/buildkit/runc-native/executor",
            Self::Overlay => "/var/lib/buildkit/runc-overlayfs/executor",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub id: String,
    pub device: u64,
    pub inode: u64,
    #[serde(default, skip_serializing_if = "is_false")]
    pub bundle_policy: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub live_worker: bool,
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl Snapshot {
    pub fn same_mount(&self, other: &Self) -> bool {
        self.id == other.id
            && self.device == other.device
            && self.inode == other.inode
            && self.live_worker == other.live_worker
    }
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
struct SnapshotMount<'a> {
    parent: u64,
    root: &'a str,
    filesystem: &'a str,
    options: &'a str,
}

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
fn mount_entry<'a>(
    mountinfo: &'a str,
    mount_id: u64,
    snapshotter: Snapshotter,
    id: &str,
) -> Option<SnapshotMount<'a>> {
    let mountpoint = format!("{}/{id}/rootfs", snapshotter.executor());
    mountinfo.lines().find_map(|line| {
        let (location, filesystem) = line.split_once(" - ")?;
        let mut fields = location.split_ascii_whitespace();
        (fields.next()?.parse::<u64>().ok()? == mount_id).then_some(())?;
        let parent = fields.next()?.parse().ok()?;
        let root = fields.nth(1)?;
        (fields.next()? == mountpoint).then_some(())?;
        let mut fields = filesystem.split_ascii_whitespace();
        let kind = fields.next()?;
        fields.next()?;
        Some(SnapshotMount {
            parent,
            root,
            filesystem: kind,
            options: fields.next()?,
        })
    })
}

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
fn numeric_leaf(value: &str) -> Option<&str> {
    (value.parse::<u64>().is_ok() && value.bytes().all(|byte| byte.is_ascii_digit()))
        .then_some(value)
}

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
fn snapshot_leaf<'a>(root: &'a str, volume: &str, snapshotter: Snapshotter) -> Option<&'a str> {
    let prefix = format!(
        "/volumes/{volume}/{}/snapshots/snapshots/",
        snapshotter.worker_directory()
    );
    let leaf = root.strip_prefix(&prefix)?;
    numeric_leaf(match snapshotter {
        Snapshotter::Native => leaf,
        Snapshotter::Overlay => leaf.strip_suffix("/fs")?,
    })
}

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
struct OverlayLayers<'a> {
    upper: &'a str,
    lowers: Vec<&'a str>,
}

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
fn overlay_layers(options: &str) -> Option<OverlayLayers<'_>> {
    // Linux OverlayFS caps the stack at OVL_MAX_STACK. The complete
    // kernel mount table is already bounded by target_mountinfo.
    const MAX_LOWER_LAYERS: usize = 500;
    fn layer<'a>(path: &'a str, kind: &str) -> Option<&'a str> {
        let relative = path.strip_prefix("/run/conjet/buildkit/worker/")?;
        let leaf = relative.strip_prefix("runc-overlayfs/snapshots/snapshots/")?;
        numeric_leaf(leaf.strip_suffix(kind)?)
    }
    let mut upper = None;
    let mut work = None;
    let mut lower = None;
    let mut userxattr = false;
    let mut writable = false;
    for option in options.split(',') {
        match option {
            "rw" if !writable => writable = true,
            "userxattr" if !userxattr => userxattr = true,
            "uuid=on" => {}
            _ if option.starts_with("upperdir=") && upper.is_none() => {
                upper = Some(layer(&option["upperdir=".len()..], "/fs")?);
            }
            _ if option.starts_with("workdir=") && work.is_none() => {
                work = Some(layer(&option["workdir=".len()..], "/work")?);
            }
            _ if option.starts_with("lowerdir=") && lower.is_none() => {
                lower = Some(&option["lowerdir=".len()..]);
            }
            _ => return None,
        }
    }
    let upper = upper?;
    if !writable || !userxattr || work? != upper {
        return None;
    }
    let mut lowers = Vec::new();
    for path in lower?.split(':') {
        let id = layer(path, "/fs")?;
        if lowers.len() >= MAX_LOWER_LAYERS || id == upper || lowers.contains(&id) {
            return None;
        }
        lowers.push(id);
    }
    Some(OverlayLayers { upper, lowers })
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod guest {
    use std::ffi::CString;
    use std::fs::{File, OpenOptions};
    use std::io::{self, Read};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::path::Path;

    use super::{
        MARKER, Snapshot, Snapshotter, mount_entry, overlay_layers, snapshot_leaf, valid_id,
    };
    use crate::spec::{GID_BASE, UID_BASE, VolumeMount};

    pub(crate) const ROOT: &std::ffi::CStr = c"/run/conjet/buildkit";
    const OPEN_TREE: libc::c_int =
        libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_DIRECTORY;

    pub(super) fn open_directory(parent: &File, name: &str) -> io::Result<File> {
        let name = CString::new(name)?;
        let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), OPEN_TREE) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // openat returned a new descriptor with CLOEXEC.
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    struct OpenSnapshot {
        root: File,
        identity: Snapshot,
        bundle: File,
        private_worker: bool,
    }

    fn open(id: &str) -> io::Result<OpenSnapshot> {
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
        let worker = open_directory(&store, "worker")?;
        let native = open_directory(&worker, "runc-native")?;
        let native_info = native.metadata()?;
        let executor = open_directory(&native, "executor")?;
        let bundle = open_directory(&executor, id)?;
        let rootfs = open_directory(&bundle, "rootfs")?;
        let info = rootfs.metadata()?;
        if info.dev() != store.metadata()?.dev() {
            return Err(io::Error::other(
                "build root does not belong to the leased disk",
            ));
        }
        let mut flags = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        // The root descriptor is live and fstatvfs writes the whole record on success.
        if unsafe { libc::fstatvfs(rootfs.as_raw_fd(), flags.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let flags = unsafe { flags.assume_init() }.f_flag;
        let required = libc::ST_NOSUID | libc::ST_NODEV;
        let rejected = libc::ST_RDONLY | libc::ST_NOEXEC;
        if flags & required != required || flags & rejected != 0 {
            return Err(io::Error::other("invalid build snapshot mount flags"));
        }
        let snapshot = Snapshot {
            id: id.into(),
            device: info.dev(),
            inode: info.ino(),
            bundle_policy: false,
            live_worker: false,
        };
        Ok(OpenSnapshot {
            root: rootfs,
            identity: snapshot,
            bundle,
            private_worker: native_info.uid() == 0 && native_info.mode() & 0o077 == 0,
        })
    }

    pub(crate) fn inspect(id: &str) -> io::Result<Snapshot> {
        open(id).map(|open| open.identity)
    }

    pub(crate) struct LiveBundle {
        pub(crate) config: Vec<u8>,
        pub(crate) cache: File,
        pub(crate) executor: File,
        root: File,
        worker_overlay: bool,
        // Keep the reviewed layer directories pinned until the detached
        // root is handed off. The resulting kernel mount retains its layer
        // references, and the child holds the original worker cache lease.
        _layer_descriptors: Vec<File>,
    }

    impl LiveBundle {
        pub(crate) fn default_home(&self, uid: u32) -> io::Result<String> {
            crate::image_account::home(&self.root, uid)
        }

        pub(crate) fn identity(&self, id: String) -> io::Result<Snapshot> {
            let info = self.root.metadata()?;
            Ok(Snapshot {
                id,
                device: info.dev(),
                inode: info.ino(),
                bundle_policy: true,
                live_worker: true,
            })
        }

        pub(crate) fn clone_root(&self, pidfd: &OwnedFd) -> io::Result<OwnedFd> {
            let tree = if self.worker_overlay {
                let namespace = crate::exec_fixture::target_mount_namespace(pidfd)?;
                clone_worker_overlay(&namespace, &self.root)
            } else {
                clone_tree(&self.root)
            }
            .map_err(|error| io::Error::other(format!("clone owned snapshot: {error}")))?;
            let attributes = libc::mount_attr {
                attr_set: libc::MOUNT_ATTR_NOSUID | libc::MOUNT_ATTR_NODEV,
                attr_clr: libc::MOUNT_ATTR_NOEXEC,
                propagation: 0,
                userns_fd: 0,
            };
            set_mount_attributes(&tree, &attributes).map_err(|error| {
                io::Error::other(format!("configure detached snapshot: {error}"))
            })?;
            Ok(tree)
        }
    }

    fn clone_worker_overlay(namespace: &File, root: &File) -> io::Result<OwnedFd> {
        use crate::security::checked;
        // open_tree can only clone an attached mount from its owning mount
        // namespace. Join it on a short-lived thread with private fs state.
        // Only the detached descriptor returns to the launch supervisor.
        std::thread::scope(|scope| {
            std::thread::Builder::new()
                .name("buildkit-overlay-mount".into())
                .spawn_scoped(scope, || {
                    checked(unsafe { libc::unshare(libc::CLONE_FS) })?;
                    checked(unsafe { libc::setns(namespace.as_raw_fd(), libc::CLONE_NEWNS) })?;
                    clone_tree(root)
                })?
                .join()
                .map_err(|_| io::Error::other("worker overlay clone thread failed"))?
        })
    }

    pub(crate) fn read_worker_config(
        root: &File,
        mountinfo: &str,
        volume: &VolumeMount,
        id: &str,
        snapshotter: Snapshotter,
    ) -> io::Result<LiveBundle> {
        if !valid_id(id) || volume.target != "/var/lib/buildkit" || volume.read_only {
            return Err(io::Error::other("invalid live BuildKit bundle scope"));
        }
        let var = open_directory(root, "var")?;
        let lib = open_directory(&var, "lib")?;
        let cache = open_directory(&lib, "buildkit")?;
        let leased_cache = crate::volume_disk::guest::build_cache_source(volume)?;
        let expected = leased_cache.metadata()?;
        let actual = cache.metadata()?;
        if (expected.dev(), expected.ino()) != (actual.dev(), actual.ino())
            || (actual.uid(), actual.gid()) != (UID_BASE, GID_BASE)
        {
            return Err(io::Error::other("BuildKit worker cache identity changed"));
        }
        let cache_mount = mount_id(&cache)?;
        let worker = open_directory(&cache, snapshotter.worker_directory())?;
        let executor = open_directory(&worker, "executor")?;
        let bundle = open_directory(&executor, id)?;
        if mount_id(&worker)? != cache_mount
            || mount_id(&executor)? != cache_mount
            || mount_id(&bundle)? != cache_mount
        {
            return Err(io::Error::other("BuildKit bundle crossed the cache mount"));
        }
        let rootfs = open_directory(&bundle, "rootfs")?;
        let mounted = rootfs.metadata()?;
        let bind_id = mount_id(&rootfs)?;
        if bind_id == cache_mount {
            return Err(io::Error::other("BuildKit rootfs is not mounted"));
        }
        let entry = mount_entry(mountinfo, bind_id, snapshotter, id)
            .ok_or_else(|| io::Error::other("missing BuildKit rootfs mount identity"))?;
        if entry.parent != cache_mount {
            return Err(io::Error::other(
                "BuildKit rootfs is outside the cache mount",
            ));
        }
        let leased_worker = open_directory(&leased_cache, snapshotter.worker_directory())?;
        let leased_executor = open_directory(&leased_worker, "executor")?;
        let snapshots = open_directory(&leased_worker, "snapshots")?;
        let snapshots = open_directory(&snapshots, "snapshots")?;
        let worker_overlay = entry.filesystem == "overlay" && snapshotter == Snapshotter::Overlay;
        let (source, layer_descriptors) = if worker_overlay {
            if entry.root != "/" || !is_overlay(&rootfs)? {
                return Err(io::Error::other(
                    "BuildKit overlay is not mounted at its root",
                ));
            }
            let run = open_directory(root, "run")?;
            let conjet = open_directory(&run, "conjet")?;
            let alias = open_directory(&conjet, "buildkit")?;
            let link = std::fs::read_link(format!("/proc/self/fd/{}/worker", alias.as_raw_fd()))?;
            if link != Path::new(&volume.target) {
                return Err(io::Error::other("BuildKit snapshot cache alias changed"));
            }
            let layers = overlay_layers(entry.options)
                .ok_or_else(|| io::Error::other("invalid BuildKit overlay layer layout"))?;
            (
                rootfs,
                overlay_descriptors(&leased_cache, &snapshots, layers)?,
            )
        } else {
            if entry.filesystem != "ext4" {
                return Err(io::Error::other("unexpected BuildKit bind filesystem"));
            }
            let leaf = snapshot_leaf(entry.root, &volume.name, snapshotter).ok_or_else(|| {
                io::Error::other("worker rootfs bind is outside its pinned snapshots")
            })?;
            let mut source = open_directory(&snapshots, leaf)?;
            if snapshotter == Snapshotter::Overlay {
                source = open_directory(&source, "fs")?;
            }
            let info = source.metadata()?;
            if mounted.dev() != actual.dev()
                || (info.dev(), info.ino()) != (mounted.dev(), mounted.ino())
            {
                return Err(io::Error::other(
                    "leased snapshot did not match the active rootfs",
                ));
            }
            (source, Vec::new())
        };
        let worker_executor = executor.metadata()?;
        let original_executor = leased_executor.metadata()?;
        if (worker_executor.dev(), worker_executor.ino())
            != (original_executor.dev(), original_executor.ino())
        {
            return Err(io::Error::other(
                "worker executor directory did not match its lease",
            ));
        }
        let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;
        let fd = unsafe { libc::openat(bundle.as_raw_fd(), c"config.json".as_ptr(), flags) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let info = file.metadata()?;
        if !info.is_file()
            || info.dev() != actual.dev()
            || (info.uid(), info.gid()) != (UID_BASE, GID_BASE)
            || info.nlink() != 1
            || info.len() > super::bundle::MAX_CONFIG_BYTES
        {
            return Err(io::Error::other("invalid live BuildKit config identity"));
        }
        let mut bytes = Vec::new();
        file.take(super::bundle::MAX_CONFIG_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > super::bundle::MAX_CONFIG_BYTES {
            return Err(io::Error::other("live BuildKit config exceeds its bound"));
        }
        Ok(LiveBundle {
            config: bytes,
            cache: leased_cache,
            executor: leased_executor,
            root: source,
            worker_overlay,
            _layer_descriptors: layer_descriptors,
        })
    }

    fn overlay_descriptors(
        lease: &File,
        snapshots: &File,
        layers: super::OverlayLayers<'_>,
    ) -> io::Result<Vec<File>> {
        let mount = mount_id(lease)?;
        let device = lease.metadata()?.dev();
        let checked_dir = |parent: &File, name| {
            let directory = open_directory(parent, name)?;
            let info = directory.metadata()?;
            if info.dev() != device
                || mount_id(&directory)? != mount
                || (info.uid(), info.gid()) != (UID_BASE, GID_BASE)
            {
                return Err(io::Error::other(
                    "BuildKit overlay layer is outside the cache lease",
                ));
            }
            Ok(directory)
        };
        let upper = checked_dir(snapshots, layers.upper)?;
        let mut descriptors = Vec::with_capacity(2 + layers.lowers.len());
        descriptors.push(checked_dir(&upper, "fs")?);
        descriptors.push(checked_dir(&upper, "work")?);
        for lower in layers.lowers {
            let snapshot = checked_dir(snapshots, lower)?;
            descriptors.push(checked_dir(&snapshot, "fs")?);
        }
        Ok(descriptors)
    }

    fn mount_id(file: &File) -> io::Result<u64> {
        let info = std::fs::read_to_string(format!("/proc/self/fdinfo/{}", file.as_raw_fd()))?;
        info.lines()
            .find_map(|line| line.strip_prefix("mnt_id:")?.trim().parse().ok())
            .ok_or_else(|| io::Error::other("could not verify BuildKit snapshot mount ID"))
    }

    fn is_overlay(file: &File) -> io::Result<bool> {
        let mut info = std::mem::MaybeUninit::<libc::statfs>::uninit();
        if unsafe { libc::fstatfs(file.as_raw_fd(), info.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(u32::try_from(unsafe { info.assume_init() }.f_type)
            == Ok(libc::OVERLAYFS_SUPER_MAGIC as u32))
    }

    pub(crate) fn inspect_bundle(
        id: &str,
        image_digest: &str,
    ) -> Result<super::bundle::BundleWitness, &'static str> {
        load_bundle(id, image_digest).map(|bundle| bundle.witness)
    }

    pub(crate) fn load_bundle(
        id: &str,
        image_digest: &str,
    ) -> Result<super::bundle::WorkerBundle, &'static str> {
        read_bundle(id, image_digest, false)
    }

    pub(crate) fn seal_worker_bundle(
        id: &str,
        image_digest: &str,
    ) -> Result<super::bundle::WorkerBundle, &'static str> {
        read_bundle(id, image_digest, true)
    }

    fn read_bundle(
        id: &str,
        image_digest: &str,
        seal: bool,
    ) -> Result<super::bundle::WorkerBundle, &'static str> {
        let open = open(id).map_err(|_| "native build snapshot is unavailable")?;
        let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;
        // The bundle descriptor pins the verified worker directory.
        let fd = unsafe { libc::openat(open.bundle.as_raw_fd(), c"config.json".as_ptr(), flags) };
        if fd < 0 {
            return Err("native build config is unavailable");
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let metadata = file
            .metadata()
            .map_err(|_| "unreadable native build config")?;
        if !metadata.is_file()
            || metadata.uid() != 0
            || metadata.dev() != open.identity.device
            || metadata.len() > super::bundle::MAX_CONFIG_BYTES
        {
            return Err("native build config has invalid ownership, location, or size");
        }
        if metadata.mode() & 0o022 != 0 {
            // The pinned worker creates config.json with mode 0666 in
            // its root-only worker directory. Seal that descriptor before
            // the runtime reads it. Read-only inspection still fails closed.
            if !seal
                || !open.private_worker
                || metadata.mode() & 0o777 != 0o666
                || metadata.nlink() != 1
            {
                return Err("native build config has invalid ownership, location, or size");
            }
            crate::security::checked(unsafe { libc::fchmod(file.as_raw_fd(), 0o600) })
                .map_err(|_| "could not secure the pinned worker config")?;
        }
        let mut bytes = Vec::new();
        file.take(super::bundle::MAX_CONFIG_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "unreadable native build config")?;
        super::bundle::parse(&bytes, open.identity, image_digest)
    }

    pub(crate) fn mapped_mount(snapshot: &Snapshot, user: &File) -> io::Result<OwnedFd> {
        let open = open(&snapshot.id)?;
        if !snapshot.same_mount(&open.identity) {
            return Err(io::Error::other("stale native build snapshot identity"));
        }
        let tree = clone_tree(&open.root)?;
        let attributes = libc::mount_attr {
            attr_set: libc::MOUNT_ATTR_IDMAP,
            attr_clr: 0,
            propagation: 0,
            userns_fd: user.as_raw_fd() as u64,
        };
        set_mount_attributes(&tree, &attributes)?;
        Ok(tree)
    }

    pub(super) fn clone_tree(root: &File) -> io::Result<OwnedFd> {
        // Clone a detached mount of only the verified root, without child mounts.
        let fd = unsafe {
            libc::syscall(
                libc::SYS_open_tree,
                root.as_raw_fd(),
                c"".as_ptr(),
                libc::AT_EMPTY_PATH | libc::OPEN_TREE_CLONE as i32 | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { OwnedFd::from_raw_fd(fd as i32) })
    }

    pub(super) fn set_mount_attributes(
        tree: &OwnedFd,
        attributes: &libc::mount_attr,
    ) -> io::Result<()> {
        // Both descriptors remain open until the kernel copies the attributes.
        crate::security::checked(unsafe {
            libc::syscall(
                libc::SYS_mount_setattr,
                tree.as_raw_fd(),
                c"".as_ptr(),
                libc::AT_EMPTY_PATH,
                attributes,
                size_of::<libc::mount_attr>(),
            ) as i32
        })
    }

    pub(crate) fn listen(
        server: std::sync::Arc<crate::server::Server>,
    ) -> io::Result<std::thread::JoinHandle<io::Result<()>>> {
        use std::os::linux::net::SocketAddrExt;
        use std::os::unix::net::{SocketAddr, UnixListener};
        use std::sync::Arc;

        let address = SocketAddr::from_abstract_name(super::CONTROL_ADDRESS)?;
        let listener = UnixListener::bind_addr(&address)?;
        listener.set_nonblocking(true)?;
        let shutdown = server.shutdown();
        std::thread::Builder::new()
            .name("build-snapshot-control".into())
            .spawn(move || {
                while !shutdown.requested() {
                    match crate::socket::wait(
                        listener.as_raw_fd(),
                        libc::POLLIN,
                        Some(&shutdown),
                        None,
                    ) {
                        Err(_) if shutdown.requested() => return Ok(()),
                        Err(error) => return Err(error),
                        Ok(()) => {}
                    }
                    let (socket, _) = match listener.accept() {
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
                        result => result?,
                    };
                    if !root_peer(socket.as_raw_fd())? {
                        continue;
                    }
                    let stream = crate::socket::Stream::unix(socket, Some(Arc::clone(&shutdown)))?;
                    if let Err(error) = server.serve_build_snapshot(stream)
                        && !shutdown.requested()
                    {
                        eprintln!("build snapshot client closed: {error}");
                    }
                }
                Ok(())
            })
    }

    fn root_peer(fd: libc::c_int) -> io::Result<bool> {
        let mut credentials = std::mem::MaybeUninit::<libc::ucred>::uninit();
        let mut length = size_of::<libc::ucred>() as libc::socklen_t;
        // The socket is owned by the listener and the bounded output is writable.
        crate::security::checked(unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                credentials.as_mut_ptr().cast(),
                &mut length,
            )
        })?;
        if length as usize != size_of::<libc::ucred>() {
            return Err(io::Error::other("invalid build snapshot peer credentials"));
        }
        Ok(unsafe { credentials.assume_init() }.uid == 0)
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

    #[test]
    fn worker_snapshot_paths_bind_the_exact_volume_bundle_and_mount() {
        let example = "50 21 8:0 /volumes/cache/runc-native/snapshots/snapshots/72 \
            /var/lib/buildkit/runc-native/executor/run1/rootfs rw - ext4 /dev/vda rw";
        let native = Snapshotter::Native;
        let entry = mount_entry(example, 50, native, "run1").unwrap();
        assert_eq!(entry.parent, 21);
        assert_eq!(entry.filesystem, "ext4");
        assert_eq!(entry.options, "rw");
        let root = entry.root;
        assert_eq!(snapshot_leaf(root, "cache", native), Some("72"));
        assert!(mount_entry(example, 49, native, "run1").is_none());
        assert_eq!(snapshot_leaf(root, "other", native), None);
        assert!(mount_entry(example, 50, native, "run2").is_none());
        assert_eq!(
            snapshot_leaf(&format!("{root}/extra"), "cache", native),
            None,
        );
    }

    #[test]
    fn overlay_snapshot_layers_require_an_owned_ordered_writable_mount() {
        let base = "/run/conjet/buildkit/worker/runc-overlayfs/snapshots/snapshots";
        let options = format!(
            "rw,lowerdir={base}/4/fs:{base}/3/fs,upperdir={base}/7/fs,workdir={base}/7/work,uuid=on,userxattr"
        );
        let layers = overlay_layers(&options).unwrap();
        assert_eq!(layers.upper, "7");
        assert_eq!(layers.lowers, ["4", "3"]);
        for bad in [
            options.replace("/7/work", "/3/work"),
            options.replace("/4/fs", "/4/../3/fs"),
            options.replace("/4/fs", "/7/fs"),
            options.replace("/4/fs", "/3/fs"),
            options.replace(&format!("{base}/4/fs"), "4/fs"),
            options.replace("/run/conjet/buildkit/worker/", "/private/"),
            options.replace("userxattr", "metacopy=on"),
            options.replace("rw,", "ro,"),
        ] {
            assert!(overlay_layers(&bad).is_none(), "{bad}");
        }
    }
}

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
fn snapshot_leaf<'a>(mountinfo: &'a str, bind_id: u64, volume: &str, id: &str) -> Option<&'a str> {
    let mountpoint = format!("/var/lib/buildkit/runc-native/executor/{id}/rootfs");
    let prefix = format!("/volumes/{volume}/runc-native/snapshots/snapshots/");
    mountinfo.lines().find_map(|line| {
        let mut fields = line.split_ascii_whitespace();
        if fields.next()?.parse::<u64>().ok()? != bind_id {
            return None;
        }
        let root = fields.nth(2)?;
        if fields.next()? != mountpoint {
            return None;
        }
        let leaf = root.strip_prefix(&prefix)?;
        (leaf.parse::<u64>().is_ok() && leaf.bytes().all(|byte| byte.is_ascii_digit()))
            .then_some(leaf)
    })
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod guest {
    use std::ffi::CString;
    use std::fs::{File, OpenOptions};
    use std::io::{self, Read};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::path::Path;

    use super::{MARKER, Snapshot, snapshot_leaf, valid_id};
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
    }

    impl LiveBundle {
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

        pub(crate) fn clone_root(&self) -> io::Result<OwnedFd> {
            let tree = clone_tree(&self.root)
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

    pub(crate) fn read_worker_config(
        root: &File,
        mountinfo: &str,
        volume: &VolumeMount,
        id: &str,
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
        let native = open_directory(&cache, "runc-native")?;
        let executor = open_directory(&native, "executor")?;
        let bundle = open_directory(&executor, id)?;
        let rootfs = open_directory(&bundle, "rootfs")?;
        let mounted = rootfs.metadata()?;
        let bind_id = mount_id(&rootfs)?;
        if mounted.dev() != actual.dev() || bind_id == mount_id(&bundle)? {
            return Err(io::Error::other(
                "BuildKit rootfs is not mounted from its cache disk",
            ));
        }
        let leaf = snapshot_leaf(mountinfo, bind_id, &volume.name, id).ok_or_else(|| {
            io::Error::other("worker rootfs bind is outside its native snapshots")
        })?;
        let native = open_directory(&leased_cache, "runc-native")?;
        let leased_executor = open_directory(&native, "executor")?;
        let snapshots = open_directory(&native, "snapshots")?;
        let snapshots = open_directory(&snapshots, "snapshots")?;
        let source = open_directory(&snapshots, leaf)?;
        let info = source.metadata()?;
        let worker_executor = executor.metadata()?;
        let original_executor = leased_executor.metadata()?;
        if (info.dev(), info.ino()) != (mounted.dev(), mounted.ino()) {
            return Err(io::Error::other(
                "leased snapshot did not match the active rootfs",
            ));
        }
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
        })
    }

    fn mount_id(file: &File) -> io::Result<u64> {
        let info = std::fs::read_to_string(format!("/proc/self/fdinfo/{}", file.as_raw_fd()))?;
        info.lines()
            .find_map(|line| line.strip_prefix("mnt_id:")?.trim().parse().ok())
            .ok_or_else(|| io::Error::other("could not verify BuildKit snapshot mount ID"))
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
        assert_eq!(snapshot_leaf(example, 50, "cache", "run1"), Some("72"));
        assert_eq!(snapshot_leaf(example, 49, "cache", "run1"), None);
        assert_eq!(snapshot_leaf(example, 50, "other", "run1"), None);
        assert_eq!(snapshot_leaf(example, 50, "cache", "run2"), None);
        assert_eq!(
            snapshot_leaf(&example.replace("/72 ", "/72/extra "), 50, "cache", "run1"),
            None,
        );
    }
}

//! Identity of a private BuildKit worker's mounted root filesystem.

use serde::{Deserialize, Serialize};

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
mod bundle;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod mounts;

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
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl Snapshot {
    pub fn same_mount(&self, other: &Self) -> bool {
        self.id == other.id && self.device == other.device && self.inode == other.inode
    }
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod guest {
    use std::ffi::CString;
    use std::fs::{File, OpenOptions};
    use std::io::{self, Read};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
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
        // Clone a detached mount of only the verified root, without child mounts.
        let tree = unsafe {
            libc::syscall(
                libc::SYS_open_tree,
                open.root.as_raw_fd(),
                c"".as_ptr(),
                libc::AT_EMPTY_PATH | libc::OPEN_TREE_CLONE as i32 | libc::O_CLOEXEC,
            )
        };
        if tree < 0 {
            return Err(io::Error::last_os_error());
        }
        let tree = unsafe { OwnedFd::from_raw_fd(tree as i32) };
        let attributes = libc::mount_attr {
            attr_set: libc::MOUNT_ATTR_IDMAP,
            attr_clr: 0,
            propagation: 0,
            userns_fd: user.as_raw_fd() as u64,
        };
        // Both descriptors remain open until the kernel copies the attributes.
        crate::security::checked(unsafe {
            libc::syscall(
                libc::SYS_mount_setattr,
                tree.as_raw_fd(),
                c"".as_ptr(),
                libc::AT_EMPTY_PATH,
                &attributes,
                size_of::<libc::mount_attr>(),
            ) as i32
        })?;
        Ok(tree)
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
}

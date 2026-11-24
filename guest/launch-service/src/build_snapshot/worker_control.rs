//! Local runtime capability of the pinned BuildKit worker.

use std::ffi::CString;
use std::fs::{self, DirBuilder, File, OpenOptions, Permissions};
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::sync::Arc;
use std::thread;

use crate::handshake;
use crate::security::checked;
use crate::server::Server;
use crate::socket::{Stream, wait};
use crate::spec::{GID_BASE, UID_BASE};

pub(crate) const DIR: &std::ffi::CStr = c"/run/conjet/buildkit-control";
pub(crate) const SOCKET: &str = "/run/conjet/buildkit-control/runtime.sock";
pub(crate) const KEY: &str = "/run/conjet/buildkit-control/key";

pub(crate) fn mount(root: &Path) -> io::Result<()> {
    let target = root.join("run/conjet/buildkit-control");
    fs::create_dir(&target)?;
    let target = CString::new(target.as_os_str().as_bytes())?;
    checked(unsafe {
        libc::mount(
            DIR.as_ptr(),
            target.as_ptr(),
            std::ptr::null(),
            libc::MS_BIND,
            std::ptr::null(),
        )
    })?;
    checked(unsafe {
        libc::mount(
            std::ptr::null(),
            target.as_ptr(),
            std::ptr::null(),
            libc::MS_BIND
                | libc::MS_REMOUNT
                | libc::MS_RDONLY
                | libc::MS_NOSUID
                | libc::MS_NODEV
                | libc::MS_NOEXEC,
            std::ptr::null(),
        )
    })
}

pub(crate) fn listen(server: Arc<Server>) -> io::Result<thread::JoinHandle<io::Result<()>>> {
    let key = handshake::random().map_err(io::Error::other)?;
    let directory = DIR.to_str().expect("static worker control directory");
    DirBuilder::new().mode(0o755).create(directory)?;
    let listener = (|| {
        let listener = UnixListener::bind(SOCKET)?;
        listener.set_nonblocking(true)?;
        fs::set_permissions(SOCKET, Permissions::from_mode(0o622))?;
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o400)
            .open(KEY)?;
        file.write_all(&key)?;
        checked(unsafe { libc::fchown(file.as_raw_fd(), UID_BASE, GID_BASE) })?;
        Ok::<_, io::Error>(listener)
    })();
    let listener = match listener {
        Ok(listener) => listener,
        Err(error) => {
            fs::remove_dir_all(directory)?;
            return Err(error);
        }
    };
    let shutdown = server.shutdown();
    thread::Builder::new()
        .name("buildkit-worker-control".into())
        .spawn(move || {
            let result = (|| {
                loop {
                    match wait(listener.as_raw_fd(), libc::POLLIN, Some(&shutdown), None) {
                        Err(_) if shutdown.requested() => return Ok(()),
                        Err(error) => return Err(error),
                        Ok(()) => {}
                    }
                    let (socket, _) = match listener.accept() {
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
                        result => result?,
                    };
                    let Ok(pidfd) = worker_peer(socket.as_raw_fd()) else {
                        continue;
                    };
                    let stream = Stream::unix(socket, Some(Arc::clone(&shutdown)))?;
                    if let Err(error) = server.serve_build_worker(stream, &key, &pidfd)
                        && !shutdown.requested()
                    {
                        eprintln!("BuildKit runtime channel closed: {error}");
                    }
                }
            })();
            drop(listener);
            fs::remove_dir_all(directory)?;
            result
        })
        .inspect_err(|_| {
            let _ = fs::remove_dir_all(directory);
        })
}

fn worker_peer(socket: i32) -> io::Result<OwnedFd> {
    let mut peer = std::mem::MaybeUninit::<libc::ucred>::uninit();
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    checked(unsafe {
        libc::getsockopt(
            socket,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            peer.as_mut_ptr().cast(),
            &mut len,
        )
    })?;
    let denied = || io::Error::new(io::ErrorKind::PermissionDenied, "invalid BuildKit peer");
    if len as usize != size_of::<libc::ucred>() {
        return Err(denied());
    }
    let peer = unsafe { peer.assume_init() };
    if peer.uid != UID_BASE || peer.gid != GID_BASE || peer.pid <= 1 {
        return Err(denied());
    }
    let mut fd = -1;
    let mut len = size_of::<i32>() as libc::socklen_t;
    checked(unsafe {
        libc::getsockopt(
            socket,
            libc::SOL_SOCKET,
            libc::SO_PEERPIDFD,
            (&mut fd as *mut i32).cast(),
            &mut len,
        )
    })?;
    if fd < 0 {
        return Err(denied());
    }
    let pidfd = unsafe { OwnedFd::from_raw_fd(fd) };
    if len as usize != size_of::<i32>() {
        return Err(denied());
    }
    Ok(pidfd)
}

pub(crate) fn peer_cgroup(pidfd: &OwnedFd) -> io::Result<String> {
    use std::io::Read;

    let file =
        crate::exec_fixture::pinned_target(pidfd, |pid| File::open(format!("/proc/{pid}/cgroup")))?;
    let mut contents = String::new();
    file.take(1024).read_to_string(&mut contents)?;
    contents
        .lines()
        .find_map(|line| line.strip_prefix("0::/"))
        .map(str::to_owned)
        .ok_or_else(|| io::Error::other("missing worker cgroup membership"))
}

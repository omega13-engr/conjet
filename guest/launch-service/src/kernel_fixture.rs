use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::cgroups::{WorkloadCgroup, write_control};
use crate::handshake;
use crate::socket::wait;
use crate::spec::{MIN_MEMORY_BYTES, ResourceLimits};

const CONTROLLERS: &str = "+cpu +memory +pids";

#[repr(C)]
#[derive(Default)]
struct CloneArgs {
    flags: u64,
    pidfd: u64,
    child_tid: u64,
    parent_tid: u64,
    exit_signal: u64,
    stack: u64,
    stack_size: u64,
    tls: u64,
    set_tid: u64,
    set_tid_size: u64,
    cgroup: u64,
}

pub fn check() -> Result<(), Box<dyn std::error::Error>> {
    if std::process::id() != 1 {
        return Err("kernel fixture must be PID 1 in a disposable Linux guest".into());
    }
    let mount = CgroupMount::new(Path::new("/run/conjet/probe-cgroup"))?;
    let root = mount.path.join("conjet-native");
    let workloads = root.join("workloads");
    let active = workloads.join("active");
    write_control(&mount.path, "cgroup.subtree_control", CONTROLLERS)?;
    for directory in [&root, &workloads, &active] {
        std::fs::create_dir(directory)?;
        write_control(directory, "cgroup.subtree_control", CONTROLLERS)?;
    }
    let id = handshake::random()?;
    let cgroup = WorkloadCgroup::create(
        &active,
        id,
        ResourceLimits {
            memory_bytes: MIN_MEMORY_BYTES,
            pids: 4,
            cpu_millicores: 500,
        },
    )?;
    let probe = clone_and_reap(&cgroup);
    cgroup.remove_empty()?;
    drop(cgroup);
    for path in [&active, &workloads, &root] {
        std::fs::remove_dir(path)?;
    }
    mount.unmount()?;
    probe?;
    println!(
        "conjet-launchd fresh-kernel fixture verified clone3, namespaces, pidfd and cgroup limits"
    );
    Ok(())
}

fn clone_and_reap(cgroup: &WorkloadCgroup) -> io::Result<()> {
    let mut descriptor = -1i32;
    let flags = libc::CLONE_PIDFD
        | libc::CLONE_NEWUSER
        | libc::CLONE_NEWNS
        | libc::CLONE_NEWNET
        | libc::CLONE_NEWPID
        | libc::CLONE_NEWIPC
        | libc::CLONE_NEWUTS;
    let placement = CloneArgs {
        flags: flags as u64 | 0x2_0000_0000, // Linux UAPI CLONE_INTO_CGROUP
        pidfd: (&mut descriptor as *mut i32) as u64,
        cgroup: cgroup.directory().as_raw_fd() as u64,
        exit_signal: libc::SIGCHLD as u64,
        ..CloneArgs::default()
    };
    // PID 1 has not created threads. The child uses only _exit in this probe.
    // The kernel writes a new pidfd only to the supplied descriptor location.
    let pid = unsafe {
        libc::syscall(
            libc::SYS_clone3,
            &placement,
            std::mem::size_of::<CloneArgs>(),
        )
    };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        unsafe { libc::_exit(0) }
    }
    let pid = pid as libc::pid_t;
    if descriptor < 0 {
        reap(pid)?;
        return Err(io::Error::other(
            "clone3 did not return the requested pidfd",
        ));
    }
    let pidfd = unsafe { OwnedFd::from_raw_fd(descriptor) };
    let ready = wait(
        pidfd.as_raw_fd(),
        libc::POLLIN,
        None,
        Some(Instant::now() + Duration::from_secs(2)),
    );
    if ready.is_err() {
        // The child was created by this probe and has not been reaped, so this
        // PID still names that child even if it exited before the signal.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    let status = reap(pid)?;
    ready?;
    if status != 0 {
        return Err(io::Error::other("namespace probe child failed"));
    }
    Ok(())
}

fn reap(pid: libc::pid_t) -> io::Result<i32> {
    loop {
        let mut status = 0;
        if unsafe { libc::waitpid(pid, &mut status, 0) } == pid {
            return Ok(status);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

struct CgroupMount {
    path: PathBuf,
    target: CString,
    mounted: bool,
}

impl CgroupMount {
    fn new(path: &Path) -> io::Result<Self> {
        let target = CString::new(path.as_os_str().as_bytes())?;
        std::fs::create_dir(path)?;
        // The fixture owns the new mountpoint inside its disposable guest.
        let result = unsafe {
            libc::mount(
                c"none".as_ptr(),
                target.as_ptr(),
                c"cgroup2".as_ptr(),
                libc::MS_NODEV | libc::MS_NOEXEC | libc::MS_NOSUID,
                std::ptr::null(),
            )
        };
        if result != 0 {
            let error = io::Error::last_os_error();
            let _ = std::fs::remove_dir(path);
            return Err(error);
        }
        Ok(Self {
            path: path.to_owned(),
            target,
            mounted: true,
        })
    }

    fn unmount(mut self) -> io::Result<()> {
        if unsafe { libc::umount(self.target.as_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        self.mounted = false;
        std::fs::remove_dir(&self.path)
    }
}

impl Drop for CgroupMount {
    fn drop(&mut self) {
        if self.mounted && unsafe { libc::umount(self.target.as_ptr()) } == 0 {
            let _ = std::fs::remove_dir(&self.path);
        }
    }
}

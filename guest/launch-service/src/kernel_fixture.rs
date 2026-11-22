use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::cgroups::{WorkloadCgroup, write_control};
use crate::handshake;
use crate::sandbox_fixture::Sandbox;
use crate::security;
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

pub fn check(with_sandbox: bool) -> Result<(), Box<dyn std::error::Error>> {
    if std::process::id() != 1 {
        return Err("kernel fixture must be PID 1 in a disposable Linux guest".into());
    }
    let sandbox = with_sandbox.then(Sandbox::prepare).transpose()?;
    let proc_mount = with_sandbox.then(ProcMount::new).transpose()?;
    security::clear_supplementary_groups()?;
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
    let probe = clone_and_reap(&cgroup, sandbox.as_ref());
    cgroup.remove_empty()?;
    drop(cgroup);
    for path in [&active, &workloads, &root] {
        std::fs::remove_dir(path)?;
    }
    mount.unmount()?;
    if let Some(proc_mount) = proc_mount {
        proc_mount.unmount()?;
    }
    if let Some(sandbox) = sandbox {
        sandbox.cleanup(probe.is_ok())?;
    }
    probe?;
    println!(
        "conjet-launchd fresh-kernel fixture verified clone3, namespaces, pidfd and cgroup limits"
    );
    Ok(())
}

fn clone_and_reap(cgroup: &WorkloadCgroup, sandbox: Option<&Sandbox>) -> io::Result<()> {
    let mut barrier = [-1; 2];
    // pipe2 writes two fresh descriptors which are each taken by one File.
    security::checked(unsafe { libc::pipe2(barrier.as_mut_ptr(), libc::O_CLOEXEC) })?;
    let mut child_ready = unsafe { File::from_raw_fd(barrier[0]) };
    let mut parent_ready = unsafe { File::from_raw_fd(barrier[1]) };
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
    // This fixture is single-threaded. The child waits for the parent mappings
    // and then applies all restrictions before any application code.
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
        drop(parent_ready);
        let mut permitted = [0];
        if child_ready.read_exact(&mut permitted).is_err() || permitted != [1] {
            unsafe { libc::_exit(125) }
        }
        drop(child_ready);
        if let Some(sandbox) = sandbox {
            let traced = unsafe {
                libc::ptrace(
                    libc::PTRACE_TRACEME,
                    0,
                    std::ptr::null_mut::<libc::c_void>(),
                    std::ptr::null_mut::<libc::c_void>(),
                )
            };
            if traced != 0 || unsafe { libc::raise(libc::SIGSTOP) } != 0 {
                unsafe { libc::_exit(124) }
            }
            if let Err(error) = sandbox.enter() {
                eprintln!("workload sandbox setup failed: {error}");
                unsafe { libc::_exit(126) }
            }
            let args = [
                c"/bin/probe".as_ptr(),
                c"--verify-workload-fixture".as_ptr(),
                std::ptr::null(),
            ];
            let env = [std::ptr::null()];
            unsafe { libc::execve(args[0], args.as_ptr(), env.as_ptr()) };
            unsafe { libc::_exit(127) }
        }
        unsafe { libc::_exit(0) }
    }
    let pid = pid as libc::pid_t;
    drop(child_ready);
    if descriptor < 0 {
        drop(parent_ready);
        reap(pid)?;
        return Err(io::Error::other(
            "clone3 did not return the requested pidfd",
        ));
    }
    let pidfd = unsafe { OwnedFd::from_raw_fd(descriptor) };
    let authorization = sandbox
        .map_or(Ok(()), |sandbox| sandbox.mappings(pid))
        .and_then(|()| parent_ready.write_all(&[1]));
    drop(parent_ready);
    if authorization.is_ok() && sandbox.is_some() {
        match confirm_exec(pid) {
            Ok(ExecObservation::Confirmed) => {
                println!("conjet-launchd kernel confirmed workload exec")
            }
            Ok(ExecObservation::Reaped(status)) => {
                return Err(io::Error::other(format!(
                    "workload exited before exec, status {status}"
                )));
            }
            Err(error) => {
                // This child remains ours until waitpid reaps it.
                unsafe { libc::kill(pid, libc::SIGKILL) };
                reap(pid)?;
                return Err(error);
            }
        }
    }
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
    authorization?;
    if status != 0 {
        return Err(io::Error::other(format!(
            "namespace probe child failed with wait status {status}"
        )));
    }
    Ok(())
}

enum ExecObservation {
    Confirmed,
    Reaped(i32),
}

fn confirm_exec(pid: libc::pid_t) -> io::Result<ExecObservation> {
    let mut status = reap(pid)?;
    if !libc::WIFSTOPPED(status) {
        return Ok(ExecObservation::Reaped(status));
    }
    if libc::WSTOPSIG(status) != libc::SIGSTOP {
        return Err(io::Error::other("unexpected initial workload trace stop"));
    }
    let none = std::ptr::null_mut::<libc::c_void>();
    let options = (libc::PTRACE_O_TRACEEXEC | libc::PTRACE_O_EXITKILL) as usize;
    if unsafe {
        libc::ptrace(
            libc::PTRACE_SETOPTIONS,
            pid,
            none,
            options as *mut libc::c_void,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let mut signal = 0;
    loop {
        if unsafe {
            libc::ptrace(
                libc::PTRACE_CONT,
                pid,
                none,
                signal as usize as *mut libc::c_void,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        status = reap(pid)?;
        if !libc::WIFSTOPPED(status) {
            return Ok(ExecObservation::Reaped(status));
        }
        if status >> 16 == libc::PTRACE_EVENT_EXEC {
            if unsafe { libc::ptrace(libc::PTRACE_DETACH, pid, none, none) } != 0 {
                return Err(io::Error::last_os_error());
            }
            return Ok(ExecObservation::Confirmed);
        }
        signal = libc::WSTOPSIG(status);
    }
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

struct ProcMount(bool);

impl ProcMount {
    fn new() -> io::Result<Self> {
        security::checked(unsafe {
            libc::mount(
                c"none".as_ptr(),
                c"/proc".as_ptr(),
                c"proc".as_ptr(),
                libc::MS_NODEV | libc::MS_NOEXEC | libc::MS_NOSUID,
                std::ptr::null(),
            )
        })?;
        Ok(Self(true))
    }

    fn unmount(mut self) -> io::Result<()> {
        security::checked(unsafe { libc::umount(c"/proc".as_ptr()) })?;
        self.0 = false;
        Ok(())
    }
}

impl Drop for ProcMount {
    fn drop(&mut self) {
        if self.0 {
            unsafe { libc::umount(c"/proc".as_ptr()) };
        }
    }
}

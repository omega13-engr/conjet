use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::cgroups::{CGROUP2_SUPER_MAGIC, WorkloadCgroup, write_control};
use crate::handshake;
use crate::sandbox_fixture::Sandbox;
use crate::security;
use crate::socket::wait;
use crate::spec::{MIN_MEMORY_BYTES, ResourceLimits};

const CONTROLLERS: &str = "+cpu +memory +pids";
const CGROUP_MOUNT: &str = "/run/conjet/probe-cgroup";

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
    run(
        with_sandbox,
        handshake::random()?,
        ResourceLimits {
            memory_bytes: MIN_MEMORY_BYTES,
            pids: 4,
            cpu_millicores: 500,
        },
        false,
        None,
    )
}

pub fn run_helper(
    mut args: impl Iterator<Item = std::ffi::OsString>,
) -> Result<(), Box<dyn std::error::Error>> {
    fn number<T: std::str::FromStr>(
        args: &mut impl Iterator<Item = std::ffi::OsString>,
    ) -> Result<T, Box<dyn std::error::Error>>
    where
        T::Err: std::error::Error + 'static,
    {
        Ok(args
            .next()
            .and_then(|value| value.into_string().ok())
            .ok_or("fixture helper bounds required")?
            .parse()?)
    }
    let owner: libc::pid_t = number(&mut args)?;
    if owner <= 1 || unsafe { libc::getppid() } != owner {
        return Err("fresh helper requires its guest supervisor".into());
    }
    let id = args.next().ok_or("fresh workload ID required")?;
    let id = handshake::unhex(id.to_str().ok_or("invalid workload ID")?)?;
    let intent = crate::intent::Intent::open(Path::new(crate::intent::DIRECTORY));
    if intent.read()? != Some(id) {
        return Err("fresh helper does not own the recorded workload".into());
    }
    let limits = ResourceLimits {
        memory_bytes: number(&mut args)?,
        pids: number(&mut args)?,
        cpu_millicores: number(&mut args)?,
    };
    let workload_option = match args.next().as_deref().and_then(std::ffi::OsStr::to_str) {
        Some("hold") => Some(c"--hold"),
        Some("fail") => Some(c"--fail"),
        Some("once") => None,
        _ => return Err("fixture helper mode required".into()),
    };
    if args.next().is_some() {
        return Err("unexpected fixture helper arguments".into());
    }
    run(true, id, limits, true, workload_option)
}

fn run(
    with_sandbox: bool,
    id: [u8; 16],
    limits: ResourceLimits,
    controlled: bool,
    workload_option: Option<&'static std::ffi::CStr>,
) -> Result<(), Box<dyn std::error::Error>> {
    let sandbox = with_sandbox.then(Sandbox::prepare).transpose()?;
    let proc_mount = (with_sandbox && !controlled)
        .then(ProcMount::new)
        .transpose()?;
    security::clear_supplementary_groups()?;
    let mount = CgroupMount::new(Path::new(CGROUP_MOUNT))?;
    let root = mount.path.join("conjet-native");
    let workloads = root.join("workloads");
    let active = workloads.join("active");
    write_control(&mount.path, "cgroup.subtree_control", CONTROLLERS)?;
    for directory in [&root, &workloads, &active] {
        std::fs::create_dir(directory)?;
        write_control(directory, "cgroup.subtree_control", CONTROLLERS)?;
    }
    let cgroup = WorkloadCgroup::create(&active, id, limits)?;
    let probe = clone_and_reap(&cgroup, sandbox.as_ref(), controlled, workload_option);
    let exit_report = match &probe {
        Ok(wait_status) if controlled => notify_control(b'X', &wait_status.to_le_bytes()),
        _ => Ok(()),
    };
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
        sandbox.cleanup(matches!(probe, Ok(0)))?;
    }
    let wait_status = probe?;
    exit_report?;
    if controlled {
        notify_control(b'R', &[])?;
    } else {
        if wait_status != 0 {
            return Err(
                format!("namespace probe child failed with wait status {wait_status}").into(),
            );
        }
        println!(
            "conjet-launchd fresh-kernel fixture verified clone3, namespaces, pidfd and cgroup limits"
        );
    }
    Ok(())
}

fn clone_and_reap(
    cgroup: &WorkloadCgroup,
    sandbox: Option<&Sandbox>,
    controlled: bool,
    workload_option: Option<&'static std::ffi::CStr>,
) -> io::Result<i32> {
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
            if traced != 0 {
                eprintln!(
                    "workload trace authorization failed: {}",
                    io::Error::last_os_error()
                );
                unsafe { libc::_exit(124) }
            }
            // The raw clone does not update libc's cached thread identity.
            // Read the new namespace IDs from the kernel for the trace stop.
            let stopped = unsafe {
                libc::syscall(
                    libc::SYS_tgkill,
                    libc::syscall(libc::SYS_getpid),
                    libc::syscall(libc::SYS_gettid),
                    libc::SIGSTOP,
                )
            };
            if stopped != 0 {
                eprintln!("workload trace stop failed: {}", io::Error::last_os_error());
                unsafe { libc::_exit(124) }
            }
            if let Err(error) = sandbox.enter() {
                eprintln!("workload sandbox setup failed: {error}");
                unsafe { libc::_exit(126) }
            }
            let args = [
                c"/bin/probe".as_ptr(),
                c"--verify-workload-fixture".as_ptr(),
                workload_option.map_or(std::ptr::null(), std::ffi::CStr::as_ptr),
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
        .and_then(|()| {
            if controlled {
                notify_control(b'C', &[])?;
            }
            parent_ready.write_all(&[1])
        });
    drop(parent_ready);
    if authorization.is_ok() && sandbox.is_some() {
        match confirm_exec(pid) {
            Ok(ExecObservation::Confirmed) => {
                if controlled {
                    if let Err(error) = notify_control(b'E', &[]) {
                        unsafe { libc::kill(pid, libc::SIGKILL) };
                        reap(pid)?;
                        return Err(error);
                    }
                } else {
                    println!("conjet-launchd kernel confirmed workload exec");
                }
            }
            Ok(ExecObservation::Reaped(status)) => return Ok(status),
            Err(error) => {
                // This child remains ours until waitpid reaps it.
                unsafe { libc::kill(pid, libc::SIGKILL) };
                reap(pid)?;
                return Err(error);
            }
        }
    }
    let ready = if controlled {
        poll_controlled_child(pidfd.as_raw_fd(), cgroup)
    } else {
        wait(
            pidfd.as_raw_fd(),
            libc::POLLIN,
            None,
            Some(Instant::now() + Duration::from_secs(2)),
        )
    };
    if ready.is_err() {
        // The child was created by this helper and has not been reaped.
        if let Err(error) = cgroup.kill() {
            unsafe { libc::kill(pid, libc::SIGKILL) };
            reap(pid)?;
            return Err(error);
        }
    }
    let status = reap(pid)?;
    ready?;
    authorization?;
    Ok(status)
}

fn notify_control(event: u8, content: &[u8]) -> io::Result<()> {
    let mut data = [0; 5];
    data[0] = event;
    data[1..1 + content.len()].copy_from_slice(content);
    let bytes = &data[..1 + content.len()];
    // FD 0 is the private Unix control socket passed by the guest supervisor.
    let sent = unsafe { libc::send(0, bytes.as_ptr().cast(), bytes.len(), libc::MSG_NOSIGNAL) };
    if sent == bytes.len() as isize {
        Ok(())
    } else if sent < 0 {
        Err(io::Error::last_os_error())
    } else {
        Err(io::ErrorKind::WriteZero.into())
    }
}

fn poll_controlled_child(pidfd: i32, cgroup: &WorkloadCgroup) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut pollfds = [
        libc::pollfd {
            fd: pidfd,
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: 0,
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::ErrorKind::TimedOut.into());
        }
        // Both descriptors belong to this single-threaded helper.
        let ready =
            unsafe { libc::poll(pollfds.as_mut_ptr(), 2, remaining.as_millis() as i32 + 1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if pollfds[0].revents != 0 {
            return Ok(());
        }
        if pollfds[1].revents != 0 {
            let mut cancellation = 0u8;
            // Read the single supervisor cancellation byte before closing.
            // A hung-up control channel also cancels the owned workload.
            unsafe {
                libc::recv(
                    0,
                    (&mut cancellation as *mut u8).cast(),
                    1,
                    libc::MSG_DONTWAIT,
                )
            };
            return cgroup.kill();
        }
    }
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

pub(crate) fn recover_cgroup(id: [u8; 16]) -> io::Result<()> {
    let mount = Path::new(CGROUP_MOUNT);
    match mount.symlink_metadata() {
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid fixture cgroup mountpoint")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    }
    let directory = File::open(mount)?;
    let mut filesystem = std::mem::MaybeUninit::<libc::statfs>::uninit();
    security::checked(unsafe { libc::fstatfs(directory.as_raw_fd(), filesystem.as_mut_ptr()) })?;
    if unsafe { filesystem.assume_init() }.f_type as u64 == CGROUP2_SUPER_MAGIC {
        let root = mount.join("conjet-native");
        let workloads = root.join("workloads");
        let active = workloads.join("active");
        let leaf = active.join(handshake::hex(&id));
        if leaf.try_exists()? {
            write_control(&leaf, "cgroup.kill", "1")?;
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                match std::fs::remove_dir(&leaf) {
                    Ok(()) => break,
                    Err(error)
                        if error.raw_os_error() == Some(libc::EBUSY)
                            && Instant::now() < deadline =>
                    {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => return Err(error),
                }
            }
        }
        for path in [&active, &workloads, &root] {
            if path.try_exists()? {
                std::fs::remove_dir(path)?;
            }
        }
        drop(directory);
        let target = CString::new(mount.as_os_str().as_bytes())?;
        security::checked(unsafe { libc::umount(target.as_ptr()) })?;
    }
    std::fs::remove_dir(mount)
}

pub(crate) fn assert_cgroup_absent() -> io::Result<()> {
    if Path::new(CGROUP_MOUNT).try_exists()? {
        return Err(io::Error::other("unclaimed fixture cgroup mountpoint"));
    }
    Ok(())
}

pub(crate) struct ProcMount(bool);

impl ProcMount {
    pub(crate) fn new() -> io::Result<Self> {
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

use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::bridge_fixture::Bridge;
use crate::cgroups::{CGROUP2_SUPER_MAGIC, WorkloadCgroup, write_control};
use crate::handshake;
use crate::sandbox_fixture::Sandbox;
use crate::security;
use crate::socket::wait;
use crate::spec::{MIN_MEMORY_BYTES, ResourceLimits};

const CONTROLLERS: &str = "+cpu +memory +pids";
const CGROUP_MOUNT: &str = "/run/conjet/probe-cgroup";

pub(crate) fn test_mode(mode: &str) -> bool {
    matches!(
        mode,
        "crash-supervisor"
            | "fault-sandbox"
            | "fault-mount"
            | "fault-cgroup"
            | "fault-child"
            | "fault-exec"
            | "fault-cleanup"
            | "missing-executable"
            | "flood"
            | "exhaust-memory"
            | "pause-prepare"
            | "pause-child"
            | "pause-cleanup"
            | "fault-bridge"
            | "fault-bridge-child"
    )
}

fn inject(mode: &str, at: &str) {
    if mode == at {
        eprintln!("conjet-launchd injecting helper failure at {at}");
        std::process::exit(77);
    }
}

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
        "once",
        false,
        false,
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
    let mode = args.next().ok_or("fixture helper mode required")?;
    let mode = mode.to_str().ok_or("invalid fixture helper mode")?;
    if !matches!(
        mode,
        "once" | "hold" | "fail" | "benchmark" | "memory-canary"
    ) && !test_mode(mode)
    {
        return Err("unknown fixture helper mode".into());
    }
    let network = args.next().ok_or("fixture network mode required")?;
    let prepared = match args.next().as_deref().and_then(std::ffi::OsStr::to_str) {
        Some("prepared")
            if network == "none"
                && matches!(mode, "once" | "memory-canary" | "benchmark")
                && limits.memory_bytes <= crate::prepared::SLOT_MEMORY_LIMIT =>
        {
            true
        }
        Some("fresh") => false,
        _ => return Err("invalid fixture preparation mode".into()),
    };
    if !matches!(network.to_str(), Some("bridge" | "none")) || args.next().is_some() {
        return Err("unexpected fixture helper arguments".into());
    }
    run(true, id, limits, true, mode, network == "bridge", prepared)
}

fn run(
    with_sandbox: bool,
    id: [u8; 16],
    limits: ResourceLimits,
    controlled: bool,
    mode: &str,
    network: bool,
    prepared: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if controlled {
        notify_control(b'P', &[])?;
        pause_for_cancel(mode, "pause-prepare")?;
        if cancellation_ready()? {
            notify_control(b'N', &[])?;
            if network {
                notify_control(b'B', &[])?;
            }
            notify_control(b'R', &[])?;
            return Ok(());
        }
    }
    let benchmark = mode == "benchmark";
    let sandbox = with_sandbox
        .then(|| Sandbox::prepare(network, benchmark))
        .transpose()?;
    inject(mode, "fault-sandbox");
    let proc_mount = (with_sandbox && !controlled)
        .then(ProcMount::new)
        .transpose()?;
    security::clear_supplementary_groups()?;
    let mount = CgroupMount::new(Path::new(CGROUP_MOUNT))?;
    inject(mode, "fault-mount");
    let root = mount.path.join("conjet-native");
    let workloads = root.join("workloads");
    let scope = workloads.join(if prepared { "prepared" } else { "active" });
    write_control(&mount.path, "cgroup.subtree_control", CONTROLLERS)?;
    for directory in [&root, &workloads, &scope] {
        std::fs::create_dir(directory)?;
        write_control(directory, "cgroup.subtree_control", CONTROLLERS)?;
    }
    let cgroup = WorkloadCgroup::create(&scope, id, limits)?;
    inject(mode, "fault-cgroup");
    let mut bridge = network.then(Bridge::create).transpose()?;
    inject(mode, "fault-bridge");
    let probe = clone_and_reap(
        &cgroup,
        sandbox.as_ref(),
        controlled,
        mode,
        bridge.as_mut(),
        prepared,
    );
    if mode == "exhaust-memory" {
        eprintln!("workload memory.events: {}", cgroup.memory_events()?);
    }
    let exit_report = match &probe {
        Ok(Some(wait_status)) if controlled => notify_control(b'X', &wait_status.to_le_bytes()),
        Ok(None) if controlled => notify_control(b'N', &[]),
        _ => Ok(()),
    };
    pause_for_cancel(mode, "pause-cleanup")?;
    if mode == "pause-cleanup" {
        cancellation_ready()?;
    }
    inject(mode, "fault-cleanup");
    if let Some(bridge) = bridge {
        bridge.close()?;
        notify_control(b'B', &[])?;
    }
    cgroup.remove_empty()?;
    drop(cgroup);
    for path in [&scope, &workloads, &root] {
        std::fs::remove_dir(path)?;
    }
    mount.unmount()?;
    if let Some(proc_mount) = proc_mount {
        proc_mount.unmount()?;
    }
    if let Some(sandbox) = sandbox {
        sandbox.cleanup(!benchmark && matches!(probe, Ok(Some(0))))?;
    }
    let wait_status = probe?;
    exit_report?;
    if controlled {
        notify_control(b'R', &[])?;
    } else {
        if wait_status != Some(0) {
            return Err(
                format!("namespace probe child failed with wait status {wait_status:?}").into(),
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
    mode: &str,
    mut bridge: Option<&mut Bridge>,
    prepared: bool,
) -> io::Result<Option<i32>> {
    if controlled && cancellation_ready()? {
        return Ok(None);
    }
    let executable = if mode == "missing-executable" {
        c"/bin/absent"
    } else {
        c"/bin/probe"
    };
    let workload_option = match mode {
        "hold" if bridge.is_some() => Some(c"--bridge-hold"),
        "once" | "pause-cleanup" | "fault-cleanup" if bridge.is_some() => Some(c"--bridge"),
        "hold" | "fault-exec" => Some(c"--hold"),
        "fail" => Some(c"--fail"),
        "flood" => Some(c"--flood"),
        "exhaust-memory" => Some(c"--exhaust-memory"),
        "memory-canary" => Some(c"--memory-canary"),
        _ => None,
    };
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
            if let Err(error) = stop_for_tracer() {
                eprintln!("workload trace stop failed: {error}");
                unsafe { libc::_exit(124) }
            }
            if let Err(error) = sandbox.enter(|| {
                if prepared {
                    stop_for_tracer()?;
                }
                Ok(())
            }) {
                eprintln!("workload sandbox setup failed: {error}");
                unsafe { libc::_exit(126) }
            }
            let args = [
                executable.as_ptr(),
                if mode == "benchmark" {
                    std::ptr::null()
                } else {
                    c"--verify-workload-fixture".as_ptr()
                },
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
    inject(mode, "fault-child");
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
            if let Some(bridge) = &mut bridge {
                bridge.attach(pid)?;
                inject(mode, "fault-bridge-child");
            }
            if controlled {
                notify_control(b'C', &[])?;
                pause_for_cancel(mode, "pause-child")?;
                if cancellation_ready()? {
                    return Ok(false);
                }
            }
            parent_ready.write_all(&[1])?;
            Ok(true)
        });
    drop(parent_ready);
    if matches!(authorization, Ok(true)) && sandbox.is_some() {
        match confirm_exec(pid, prepared) {
            Ok(ExecObservation::Confirmed) => {
                if controlled {
                    if let Err(error) = notify_control(b'E', &[]) {
                        unsafe { libc::kill(pid, libc::SIGKILL) };
                        reap(pid)?;
                        return Err(error);
                    }
                    inject(mode, "fault-exec");
                } else {
                    println!("conjet-launchd kernel confirmed workload exec");
                }
            }
            Ok(ExecObservation::Reaped(status)) => return Ok(Some(status)),
            Err(error) => {
                // This child remains ours until waitpid reaps it.
                unsafe { libc::kill(pid, libc::SIGKILL) };
                reap(pid)?;
                return Err(error);
            }
        }
    }
    let ready = if controlled {
        poll_controlled_child(pidfd.as_raw_fd(), cgroup, bridge.as_deref())
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
    Ok(Some(status))
}

fn stop_for_tracer() -> io::Result<()> {
    // The raw clone does not update libc's cached thread identity.
    let stopped = unsafe {
        libc::syscall(
            libc::SYS_tgkill,
            libc::syscall(libc::SYS_getpid),
            libc::syscall(libc::SYS_gettid),
            libc::SIGSTOP,
        )
    };
    security::checked(stopped as libc::c_int)
}

fn wait_for_claim() -> io::Result<bool> {
    let expires = Instant::now() + crate::prepared::SLOT_TTL;
    notify_control(b'Q', &[])?;
    loop {
        let now = Instant::now();
        if now >= expires {
            notify_control(b'T', &[])?;
            return Ok(false);
        }
        if crate::memory::pressures_reserve(crate::memory::available_bytes()) {
            notify_control(b'M', &[])?;
            return Ok(false);
        }
        // Only an admitted parked child samples pressure. This wait is
        // bounded by its lease and consumes no polling thread while idle.
        let next_check = expires.min(now + Duration::from_millis(250));
        match wait(0, libc::POLLIN, None, Some(next_check)) {
            Ok(()) => break,
            Err(error) if error.kind() == io::ErrorKind::TimedOut => continue,
            Err(error) => return Err(error),
        }
    }
    let mut command = [0];
    let size = unsafe {
        libc::recv(
            0,
            command.as_mut_ptr().cast(),
            command.len(),
            libc::MSG_DONTWAIT,
        )
    };
    match (size, command[0]) {
        (1, crate::prepared::RELEASE) => {
            if Instant::now() >= expires {
                notify_control(b'T', &[])?;
                Ok(false)
            } else if crate::memory::pressures_reserve(crate::memory::available_bytes()) {
                notify_control(b'M', &[])?;
                Ok(false)
            } else {
                Ok(true)
            }
        }
        (0, _) | (1, crate::prepared::CANCEL) => Ok(false),
        (-1, _) => Err(io::Error::last_os_error()),
        _ => Err(io::Error::other("invalid prepared helper command")),
    }
}

fn cancellation_ready() -> io::Result<bool> {
    let mut byte = 0u8;
    // The helper's stdin is its private control socket until workload exec.
    let read = unsafe { libc::recv(0, (&mut byte as *mut u8).cast(), 1, libc::MSG_DONTWAIT) };
    match read {
        0 | 1 => Ok(true),
        _ => {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                Ok(false)
            } else {
                Err(error)
            }
        }
    }
}

fn pause_for_cancel(mode: &str, stage: &str) -> io::Result<()> {
    if mode == stage {
        wait(
            0,
            libc::POLLIN,
            None,
            Some(Instant::now() + Duration::from_secs(5)),
        )?;
    }
    Ok(())
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

fn poll_controlled_child(
    pidfd: i32,
    cgroup: &WorkloadCgroup,
    bridge: Option<&Bridge>,
) -> io::Result<()> {
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
        libc::pollfd {
            fd: -1,
            events: 0,
            revents: 0,
        },
        libc::pollfd {
            fd: -1,
            events: 0,
            revents: 0,
        },
    ];
    if let Some(bridge) = bridge {
        pollfds[2..].copy_from_slice(&bridge.poll_fds());
    }
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::ErrorKind::TimedOut.into());
        }
        // Both descriptors belong to this single-threaded helper.
        let ready = unsafe {
            libc::poll(
                pollfds.as_mut_ptr(),
                pollfds.len() as libc::nfds_t,
                remaining.as_millis() as i32 + 1,
            )
        };
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
        if let Some(bridge) = bridge {
            if pollfds[2].revents != 0 {
                bridge.receive_dns()?;
            }
            if pollfds[3].revents != 0 {
                bridge.receive_tcp()?;
            }
        }
    }
}

enum ExecObservation {
    Confirmed,
    Reaped(i32),
}

fn confirm_exec(pid: libc::pid_t, prepared: bool) -> io::Result<ExecObservation> {
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
    if prepared {
        // The first stop established tracing and EXITKILL. The second
        // stop is after sandbox setup, before seccomp installation and
        // exec. The child can proceed only after consuming its claim.
        resume_trace(pid, 0)?;
        status = reap(pid)?;
        if !libc::WIFSTOPPED(status) {
            return Ok(ExecObservation::Reaped(status));
        }
        if libc::WSTOPSIG(status) != libc::SIGSTOP || status >> 16 != 0 {
            return Err(io::Error::other("unexpected prepared workload trace stop"));
        }
        if !wait_for_claim()? {
            security::checked(unsafe { libc::kill(pid, libc::SIGKILL) })?;
            return reap(pid).map(ExecObservation::Reaped);
        }
    }
    let mut signal = 0;
    loop {
        resume_trace(pid, signal)?;
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

fn resume_trace(pid: libc::pid_t, signal: libc::c_int) -> io::Result<()> {
    let result = unsafe {
        libc::ptrace(
            libc::PTRACE_CONT,
            pid,
            std::ptr::null_mut::<libc::c_void>(),
            signal as usize as *mut libc::c_void,
        )
    };
    security::checked(result as libc::c_int)
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
        for name in ["active", "prepared"] {
            let scope = workloads.join(name);
            let leaf = scope.join(handshake::hex(&id));
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
            if scope.try_exists()? {
                std::fs::remove_dir(scope)?;
            }
        }
        for path in [&workloads, &root] {
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

pub(crate) fn cgroup_observation(id: &str, prepared: bool) -> io::Result<(u64, bool)> {
    let path = Path::new(CGROUP_MOUNT)
        .join("conjet-native/workloads")
        .join(if prepared { "prepared" } else { "active" })
        .join(id);
    crate::cgroups::observation(&path)
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

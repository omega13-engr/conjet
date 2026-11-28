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
const CGROUP_ROOT: &str = "conjet-native";
pub(crate) const CORE_CGROUP_MOUNT: &str = "/sys/fs/cgroup";
pub(crate) const BUILD_CGROUP_OWNER: &str = "CONJET_NATIVE_BUILD_CGROUP_OWNER";

pub(crate) fn cgroup_paths(id: &str, oci: bool) -> (PathBuf, String) {
    if oci {
        (
            PathBuf::from(format!("{CGROUP_MOUNT}-{id}")),
            format!("{CGROUP_ROOT}-{id}"),
        )
    } else {
        (PathBuf::from(CGROUP_MOUNT), CGROUP_ROOT.into())
    }
}

pub(crate) fn build_cgroup_path(owner: &str) -> PathBuf {
    Path::new(CORE_CGROUP_MOUNT)
        .join(format!("{CGROUP_ROOT}-{owner}"))
        .join("workloads/active")
        .join(owner)
}

fn prepare_cgroup_scope(
    root: &Path,
    name: &str,
    scope: &str,
    controllers: &str,
) -> io::Result<PathBuf> {
    let group = root.join(name);
    let workloads = group.join("workloads");
    let scope = workloads.join(scope);
    write_control(root, "cgroup.subtree_control", controllers)?;
    for directory in [&group, &workloads, &scope] {
        std::fs::create_dir(directory)?;
        write_control(directory, "cgroup.subtree_control", controllers)?;
    }
    Ok(scope)
}

pub(crate) struct BuildAggregate(WorkloadCgroup);

impl BuildAggregate {
    pub(crate) fn open(
        id: [u8; 16],
        limits: ResourceLimits,
        disable_swap: bool,
    ) -> io::Result<Self> {
        let owner = handshake::hex(&id);
        let root = Path::new(CORE_CGROUP_MOUNT);
        let controllers = std::fs::read_to_string(root.join("cgroup.controllers"))?;
        let controllers = if controllers
            .split_ascii_whitespace()
            .any(|name| name == "io")
        {
            "+cpu +memory +pids +io"
        } else {
            CONTROLLERS
        };
        let group = format!("{CGROUP_ROOT}-{owner}");
        let result = (|| {
            let scope = prepare_cgroup_scope(root, &group, "active", controllers)?;
            let aggregate = WorkloadCgroup::create(&scope, id, limits, disable_swap)?;
            write_control(aggregate.path(), "cgroup.subtree_control", controllers)?;
            Ok(Self(aggregate))
        })();
        if let Err(error) = &result
            && let Err(cleanup) = recover_build_aggregate(id)
        {
            return Err(io::Error::other(format!(
                "BuildKit cgroup setup failed: {error}; cleanup failed: {cleanup}"
            )));
        }
        result
    }

    pub(crate) fn close(self) -> io::Result<()> {
        self.0.remove_empty()?;
        scope_ancestors(self.0.path().parent().expect("aggregate scope"))
            .into_iter()
            .try_for_each(std::fs::remove_dir)
    }
}

fn scope_ancestors(scope: &Path) -> [&Path; 3] {
    let workloads = scope.parent().expect("cgroup scope parent");
    let root = workloads.parent().expect("cgroup workload parent");
    [scope, workloads, root]
}

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
        handshake::random()?,
        ResourceLimits {
            memory_bytes: MIN_MEMORY_BYTES,
            pids: 4,
            cpu_millicores: 500,
            cpu_bandwidth: None,
        },
        RunProfile {
            with_sandbox,
            controlled: false,
            mode: "once",
            network: false,
            prepared: false,
            process: None,
            stdin: None,
            live_mounts: None,
            build_owner: None,
        },
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
    let limits = args.next().ok_or("fresh workload limits required")?;
    let limits: ResourceLimits =
        serde_json::from_str(limits.to_str().ok_or("invalid fresh workload limits")?)?;
    let mode = args.next().ok_or("fixture helper mode required")?;
    let mode = mode.to_str().ok_or("invalid fixture helper mode")?;
    if !matches!(
        mode,
        "once" | "hold" | "fail" | "benchmark" | "memory-canary" | "native" | "native-oci"
    ) && !test_mode(mode)
    {
        return Err("unknown fixture helper mode".into());
    }
    let intent = crate::intent::Intent::open(Path::new(crate::intent::DIRECTORY));
    let intent = if mode == "native-oci" {
        intent.scoped(id)
    } else {
        intent
    };
    if intent.read()? != Some(id) {
        return Err("fresh helper does not own the recorded workload".into());
    }
    let network = args.next().ok_or("fixture network mode required")?;
    let prepared = match args.next().as_deref().and_then(std::ffi::OsStr::to_str) {
        Some("prepared")
            if network == "none"
                && matches!(mode, "once" | "memory-canary" | "benchmark" | "native")
                && limits.memory_bytes <= crate::prepared::SLOT_MEMORY_LIMIT =>
        {
            true
        }
        Some("fresh") => false,
        _ => return Err("invalid fixture preparation mode".into()),
    };
    let process = if mode == "native-oci" {
        let spec = args.next().ok_or("missing OCI process spec")?;
        let spec: crate::spec::LaunchSpec =
            serde_json::from_str(spec.to_str().ok_or("invalid OCI process spec")?)?;
        let expected_network = if spec.bridge_scope().is_some() {
            "bridge"
        } else {
            "none"
        };
        if network != expected_network || spec.limits != limits || prepared {
            return Err("invalid OCI helper limits or mode".into());
        }
        Some(spec)
    } else {
        None
    };
    if !matches!(network.to_str(), Some("bridge" | "none"))
        || (mode == "native" && network != "none")
        || args.next().is_some()
    {
        return Err("unexpected fixture helper arguments".into());
    }
    let stdin =
        crate::workload_input::inherited(process.as_ref().is_some_and(|spec| spec.open_stdin))?;
    let live_mounts = crate::build_snapshot::mounts::LiveMounts::inherited(
        process
            .as_ref()
            .and_then(|spec| spec.build_snapshot.as_ref())
            .is_some_and(|snapshot| snapshot.live_worker),
    )?;
    let build_owner = std::env::var(BUILD_CGROUP_OWNER).ok();
    let worker = process.as_ref().is_some_and(|spec| spec.buildkit_worker);
    if build_owner.is_some() != (worker || live_mounts.is_some()) {
        return Err("unexpected BuildKit cgroup ownership".into());
    }
    if let Some(owner) = &build_owner
        && (handshake::unhex::<16>(owner)? == id) != worker
    {
        return Err("unexpected BuildKit cgroup generation".into());
    }
    run(
        id,
        limits,
        RunProfile {
            with_sandbox: true,
            controlled: true,
            mode,
            network: network == "bridge",
            prepared,
            process: process.as_ref(),
            stdin,
            live_mounts,
            build_owner: build_owner.as_deref(),
        },
    )
}

struct RunProfile<'a> {
    with_sandbox: bool,
    controlled: bool,
    mode: &'a str,
    network: bool,
    prepared: bool,
    process: Option<&'a crate::spec::LaunchSpec>,
    stdin: Option<std::fs::File>,
    live_mounts: Option<crate::build_snapshot::mounts::LiveMounts>,
    build_owner: Option<&'a str>,
}

fn run(
    id: [u8; 16],
    limits: ResourceLimits,
    profile: RunProfile<'_>,
) -> Result<(), Box<dyn std::error::Error>> {
    let RunProfile {
        with_sandbox,
        controlled,
        mode,
        network,
        prepared,
        process,
        stdin,
        live_mounts,
        build_owner,
    } = profile;
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
    let executable = match mode {
        "native" => crate::sandbox_fixture::NATIVE_EXECUTABLE,
        "benchmark" => crate::sandbox_fixture::BENCHMARK_EXECUTABLE,
        _ => "/init",
    };
    let _ = live_mounts
        .as_ref()
        .map(|mounts| mounts.enter_network())
        .transpose()?
        .unwrap_or(false);
    let sandbox = with_sandbox
        .then(|| Sandbox::prepare(network, executable, process, id, stdin, live_mounts))
        .transpose()?;
    inject(mode, "fault-sandbox");
    let proc_mount = (with_sandbox && !controlled)
        .then(ProcMount::new)
        .transpose()?;
    let groups = sandbox
        .as_ref()
        .map_or(&[][..], Sandbox::groups)
        .iter()
        .map(|gid| crate::spec::GID_BASE + gid)
        .collect::<Vec<_>>();
    security::checked(unsafe { libc::setgroups(groups.len(), groups.as_ptr()) })?;
    let (mount_path, root_name) = cgroup_paths(&handshake::hex(&id), process.is_some());
    let mount = build_owner
        .is_none()
        .then(|| CgroupMount::new(&mount_path))
        .transpose()?;
    inject(mode, "fault-mount");
    let scope = match build_owner {
        Some(owner) => build_cgroup_path(owner),
        None => prepare_cgroup_scope(
            &mount_path,
            &root_name,
            if prepared { "prepared" } else { "active" },
            CONTROLLERS,
        )?,
    };
    let worker = process.is_some_and(|spec| spec.buildkit_worker);
    let cgroup = WorkloadCgroup::create(
        &scope,
        id,
        if worker {
            ResourceLimits::UNBOUNDED
        } else {
            limits
        },
        !worker && process.is_some_and(|spec| spec.memory_swap_disabled),
    )?;
    inject(mode, "fault-cgroup");
    let mut bridge = (network && process.is_none())
        .then(Bridge::create)
        .transpose()?;
    inject(mode, "fault-bridge");
    let probe = clone_and_reap(
        &cgroup,
        sandbox.as_ref(),
        controlled,
        mode,
        bridge.as_mut(),
        prepared,
        process,
    );
    if mode == "exhaust-memory" {
        eprintln!("workload memory.events: {}", cgroup.memory_events()?);
    }
    if controlled && process.is_some() && matches!(probe, Ok(Some(_))) && cgroup.oom_killed()? {
        notify_control(b'O', &[])?;
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
    if process.is_some() {
        cgroup.drain()?;
    } else {
        cgroup.remove_empty()?;
    }
    drop(cgroup);
    if let Some(mount) = mount {
        scope_ancestors(&scope)
            .into_iter()
            .try_for_each(std::fs::remove_dir)?;
        mount.unmount()?;
    }
    if let Some(proc_mount) = proc_mount {
        proc_mount.unmount()?;
    }
    if let Some(sandbox) = sandbox {
        sandbox
            .cleanup(process.is_none() && executable == "/init" && matches!(probe, Ok(Some(0))))?;
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
    process: Option<&crate::spec::LaunchSpec>,
) -> io::Result<Option<i32>> {
    if controlled && cancellation_ready()? {
        return Ok(None);
    }
    if process.is_some_and(|spec| spec.redis_bootstrap) {
        security::prepare_open_files(security::REDIS_OPEN_FILES)?;
    } else if process.is_some() {
        security::prepare_open_files(security::BUILDKIT_OPEN_FILES)?;
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
    let encode = |strings: &[String]| -> io::Result<Vec<std::ffi::CString>> {
        strings
            .iter()
            .map(|value| std::ffi::CString::new(value.as_str()).map_err(Into::into))
            .collect()
    };
    let oci = process
        .map(|spec| {
            Ok::<_, io::Error>((
                encode(&spec.argv)?,
                encode(&spec.env)?,
                crate::exec_fixture::program_paths(spec)?,
            ))
        })
        .transpose()?;
    // Allocate the pointer vectors before clone and keep their strings alive
    // through execve. The pointers reference only the helper's own allocations.
    let oci_pointers = oci.as_ref().map(|(args, env, paths)| {
        let ptrs = |values: &[std::ffi::CString]| {
            values
                .iter()
                .map(|value| value.as_ptr())
                .chain([std::ptr::null()])
                .collect::<Vec<_>>()
        };
        (ptrs(args), ptrs(env), paths)
    });
    let mut barrier = [-1; 2];
    // pipe2 writes two fresh descriptors which are each taken by one File.
    security::checked(unsafe { libc::pipe2(barrier.as_mut_ptr(), libc::O_CLOEXEC) })?;
    let mut child_ready = unsafe { File::from_raw_fd(barrier[0]) };
    let mut parent_ready = unsafe { File::from_raw_fd(barrier[1]) };
    let (child_mount, parent_mount) = if process.is_some_and(|spec| spec.build_snapshot.is_some()) {
        let (child, parent) = std::os::unix::net::UnixStream::pair()?;
        (Some(child), Some(parent))
    } else {
        (None, None)
    };
    let mut descriptor = -1i32;
    let flags = libc::CLONE_PIDFD
        | libc::CLONE_NEWUSER
        | libc::CLONE_NEWNS
        | if sandbox.is_some_and(Sandbox::inherits_worker_network) {
            0
        } else {
            libc::CLONE_NEWNET
        }
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
        drop(parent_mount);
        let mut permitted = [0];
        if child_ready.read_exact(&mut permitted).is_err() || permitted != [1] {
            unsafe { libc::_exit(125) }
        }
        drop(child_ready);
        let (snapshot_mount, sysfs_mount) = if let Some(socket) = child_mount {
            match crate::exec_fixture::receive_event(socket.as_raw_fd()) {
                Ok(Some((b'M', mut descriptors))) => {
                    let root = descriptors.remove(0);
                    (Some(root), descriptors.pop())
                }
                _ => unsafe { libc::_exit(125) },
            }
        } else {
            (None, None)
        };
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
            let cgroup_view = process
                .filter(|spec| spec.build_snapshot.is_none())
                .map(|spec| {
                    if spec.buildkit_worker {
                        cgroup.path().parent().expect("BuildKit aggregate cgroup")
                    } else {
                        cgroup.path()
                    }
                });
            if let Err(error) = sandbox.enter(snapshot_mount, sysfs_mount, cgroup_view, || {
                if prepared {
                    stop_for_tracer()?;
                }
                Ok(())
            }) {
                eprintln!("workload sandbox setup failed: {error}");
                unsafe { libc::_exit(126) }
            }
            if let Some((args, env, paths)) = &oci_pointers {
                for path in *paths {
                    unsafe { libc::execve(path.as_ptr(), args.as_ptr(), env.as_ptr()) };
                }
                unsafe { libc::_exit(127) }
            }
            let args = [
                executable.as_ptr(),
                if matches!(mode, "benchmark" | "native") {
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
    drop(child_mount);
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
            if process.is_some_and(|spec| spec.bridge_scope().is_some()) {
                attach_private_peer(pid)?;
            }
            if controlled {
                notify_control(b'C', &[])?;
                pause_for_cancel(mode, "pause-child")?;
                if cancellation_ready()? {
                    return Ok(false);
                }
            }
            if let Some(socket) = parent_mount {
                let mount = sandbox
                    .ok_or_else(|| io::Error::other("missing build snapshot sandbox"))?
                    .snapshot_mount(pid)?
                    .ok_or_else(|| io::Error::other("missing detached build snapshot"))?;
                let sysfs = process
                    .filter(|spec| spec.build_sysfs_view())
                    .map(|_| crate::build_snapshot::mounts::detached_sysfs(&pidfd))
                    .transpose()?;
                let mut descriptors = vec![mount.as_raw_fd()];
                descriptors.extend(sysfs.as_ref().map(AsRawFd::as_raw_fd));
                crate::exec_fixture::send_descriptors(socket.as_raw_fd(), b'M', &descriptors)?;
            }
            parent_ready.write_all(&[1])?;
            Ok(true)
        });
    drop(parent_ready);
    if matches!(authorization, Ok(true)) && sandbox.is_some() {
        match confirm_exec(pid, prepared) {
            Ok(ExecObservation::Confirmed) => {
                if controlled {
                    let event = if process.is_some() {
                        crate::exec_fixture::send_descriptors(0, b'E', &[pidfd.as_raw_fd()])
                    } else {
                        notify_control(b'E', &[])
                    };
                    if let Err(error) = event {
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
        poll_controlled_child(
            pidfd.as_raw_fd(),
            cgroup,
            bridge.as_deref(),
            process.is_some(),
        )
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

fn attach_private_peer(pid: libc::pid_t) -> io::Result<()> {
    use std::os::unix::net::UnixStream;
    let namespace = File::open(format!("/proc/{pid}/ns/net"))?;
    let (mut result, reply) = UnixStream::pair()?;
    result.set_read_timeout(Some(Duration::from_secs(3)))?;
    crate::exec_fixture::send_descriptors(0, b'V', &[namespace.as_raw_fd(), reply.as_raw_fd()])?;
    drop(reply);
    let mut status = [0];
    result.read_exact(&mut status)?;
    if status == [1] {
        Ok(())
    } else {
        Err(io::Error::other("private network peer rejected"))
    }
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
    native_oci: bool,
) -> io::Result<()> {
    let deadline = (!native_oci).then(|| Instant::now() + Duration::from_secs(30));
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
        let timeout = if let Some(deadline) = deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::ErrorKind::TimedOut.into());
            }
            remaining.as_millis() as i32 + 1
        } else {
            -1
        };
        // Both descriptors belong to this single-threaded helper.
        let ready =
            unsafe { libc::poll(pollfds.as_mut_ptr(), pollfds.len() as libc::nfds_t, timeout) };
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
            let received = unsafe {
                libc::recv(
                    0,
                    (&mut cancellation as *mut u8).cast(),
                    1,
                    libc::MSG_DONTWAIT,
                )
            };
            if received == 1 && cancellation == crate::prepared::TERMINATE {
                let result = unsafe {
                    libc::syscall(
                        libc::SYS_pidfd_send_signal,
                        pidfd,
                        libc::SIGTERM,
                        std::ptr::null::<libc::siginfo_t>(),
                        0,
                    )
                };
                if result < 0 && io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) {
                    return Err(io::Error::last_os_error());
                }
                continue;
            }
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

pub(crate) fn reap(pid: libc::pid_t) -> io::Result<i32> {
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

pub(crate) struct CgroupMount {
    path: PathBuf,
    target: CString,
    mounted: bool,
}

impl CgroupMount {
    pub(crate) fn new(path: &Path) -> io::Result<Self> {
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

pub(crate) fn recover_cgroup(id: [u8; 16], oci: bool) -> io::Result<()> {
    let (mount, root_name) = cgroup_paths(&handshake::hex(&id), oci);
    match mount.symlink_metadata() {
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid fixture cgroup mountpoint")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    }
    let directory = File::open(&mount)?;
    let mut filesystem = std::mem::MaybeUninit::<libc::statfs>::uninit();
    security::checked(unsafe { libc::fstatfs(directory.as_raw_fd(), filesystem.as_mut_ptr()) })?;
    if i128::from(unsafe { filesystem.assume_init() }.f_type) == CGROUP2_SUPER_MAGIC {
        let root = mount.join(root_name);
        let workloads = root.join("workloads");
        for name in ["active", "prepared"] {
            let scope = workloads.join(name);
            let leaf = scope.join(handshake::hex(&id));
            recover_cgroup_leaf(&leaf)?;
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

fn recover_cgroup_leaf(path: &Path) -> io::Result<()> {
    if !path.try_exists()? {
        return Ok(());
    }
    write_control(path, "cgroup.kill", "1")?;
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match std::fs::remove_dir(path) {
            Err(error)
                if error.raw_os_error() == Some(libc::EBUSY) && Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            result => return result,
        }
    }
}

pub(crate) fn recover_build_child(owner: &str, child: &str) -> io::Result<()> {
    recover_cgroup_leaf(&build_cgroup_path(owner).join(child))
}

pub(crate) fn recover_build_aggregate(id: [u8; 16]) -> io::Result<()> {
    let owner = handshake::hex(&id);
    let aggregate = build_cgroup_path(&owner);
    if aggregate.try_exists()? {
        for entry in std::fs::read_dir(&aggregate)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let name = entry.file_name();
            handshake::unhex::<16>(name.to_str().unwrap_or_default()).map_err(io::Error::other)?;
            recover_cgroup_leaf(&entry.path())?;
        }
        recover_cgroup_leaf(&aggregate)?;
    }
    for directory in scope_ancestors(aggregate.parent().expect("aggregate scope")) {
        match std::fs::remove_dir(directory) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

pub(crate) fn cgroup_effective_limits(dir: &Path) -> io::Result<(serde_json::Value, u64)> {
    let read = |file| std::fs::read_to_string(dir.join(file)).map(|value| value.trim().to_owned());
    let limits = serde_json::json!({
        "memory_max":read("memory.max")?,
        "pids_max":read("pids.max")?,
        "cpu_max":read("cpu.max")?,
    });
    let active = read("pids.current")?.parse().map_err(io::Error::other)?;
    Ok((limits, active))
}

pub(crate) fn cgroup_scope(id: &str, prepared: bool, oci: bool) -> PathBuf {
    let (mount, root) = cgroup_paths(id, oci);
    mount
        .join(root)
        .join("workloads")
        .join(if prepared { "prepared" } else { "active" })
        .join(id)
}

pub(crate) fn assert_cgroup_absent() -> io::Result<()> {
    if Path::new(CGROUP_MOUNT).try_exists()? {
        return Err(io::Error::other("unclaimed fixture cgroup mountpoint"));
    }
    Ok(())
}

pub(crate) fn assert_owned_cgroup_absent(id: [u8; 16]) -> io::Result<()> {
    let (mount, _) = cgroup_paths(&handshake::hex(&id), true);
    if mount.try_exists()? {
        return Err(io::Error::other("owned OCI cgroup mountpoint remains"));
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

use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use crate::handshake::{hex, unhex};
use crate::output::{Capture, drain};
use crate::security::{self, checked};
use crate::socket::Stream;
use crate::spec::LaunchSpec;

const TARGET_PIDFD: libc::c_int = 3;
const TARGET_ROOT: libc::c_int = 4;
const RESULT_PIPE: libc::c_int = 5;
pub(crate) struct ExecResult {
    pub(crate) code: i32,
    pub(crate) streams: [Capture; 2],
}

pub(crate) fn send_descriptors(socket: i32, mut event: u8, descriptors: &[i32]) -> io::Result<()> {
    let mut vector = libc::iovec {
        iov_base: (&mut event as *mut u8).cast(),
        iov_len: 1,
    };
    let mut control = [0usize; 8];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut vector;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    let length = size_of_val(descriptors) as u32;
    if !(1..=2).contains(&descriptors.len()) {
        return Err(io::Error::other("invalid helper descriptor count"));
    }
    msg.msg_controllen = unsafe { libc::CMSG_SPACE(length) } as _;
    // Transfer the kernel reference itself, so the supervisor never has
    // to look up a reusable numeric PID to identify the target.
    unsafe {
        let header = libc::CMSG_FIRSTHDR(&msg);
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = libc::CMSG_LEN(length) as _;
        let data = libc::CMSG_DATA(header).cast::<i32>();
        for (index, fd) in descriptors.iter().enumerate() {
            data.add(index).write_unaligned(*fd);
        }
        if libc::sendmsg(socket, &msg, libc::MSG_NOSIGNAL) != 1 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

pub(crate) fn receive_event(socket: i32) -> io::Result<Option<(u8, Vec<OwnedFd>)>> {
    let mut event = 0u8;
    let mut vector = libc::iovec {
        iov_base: (&mut event as *mut u8).cast(),
        iov_len: 1,
    };
    let mut control = [0usize; 8];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut vector;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = size_of_val(&control) as _;
    let result = unsafe { libc::recvmsg(socket, &mut msg, libc::MSG_CMSG_CLOEXEC) };
    match result {
        0 => return Ok(None),
        1 => {}
        _ => return Err(io::Error::last_os_error()),
    }
    let mut received = Vec::new();
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(&msg);
        while !header.is_null() {
            let base = libc::CMSG_LEN(0) as usize;
            let len = (*header).cmsg_len as usize;
            if (*header).cmsg_level != libc::SOL_SOCKET
                || (*header).cmsg_type != libc::SCM_RIGHTS
                || len < base
                || len > msg.msg_controllen as usize
            {
                return Err(io::Error::other("invalid helper event descriptor"));
            }
            // The kernel supplied this ancillary data and a CLOEXEC
            // descriptor for each complete element that fitted the buffer.
            let data = libc::CMSG_DATA(header).cast::<i32>();
            for offset in 0..(len - base) / size_of::<i32>() {
                received.push(OwnedFd::from_raw_fd(data.add(offset).read_unaligned()));
            }
            header = libc::CMSG_NXTHDR(&msg, header);
        }
    }
    let valid = match event {
        b'E' => received.len() <= 1,
        b'M' => (1..=2).contains(&received.len()),
        b'V' => received.len() == 2,
        _ => received.is_empty(),
    };
    if msg.msg_flags & libc::MSG_CTRUNC != 0 || !valid {
        return Err(io::Error::other("unexpected helper event descriptors"));
    }
    Ok(Some((event, received)))
}

pub(crate) fn pinned_target(
    pidfd: &OwnedFd,
    open: impl FnOnce(i32) -> io::Result<File>,
) -> io::Result<File> {
    let live = || {
        checked(unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                pidfd.as_raw_fd(),
                0,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            ) as libc::c_int
        })
    };
    live()?;
    let info = fs::read_to_string(format!("/proc/self/fdinfo/{}", pidfd.as_raw_fd()))?;
    let pid = info
        .lines()
        .find_map(|line| {
            line.strip_prefix("Pid:")
                .and_then(|value| value.trim().parse::<i32>().ok())
        })
        .filter(|pid| *pid > 1)
        .ok_or_else(|| io::Error::other("target pidfd has no live PID"))?;
    let file = open(pid)?;
    // A numeric PID can't be reused while its original process is live.
    // Recheck the pinned process before using the directory just opened.
    live()?;
    Ok(file)
}

pub(crate) fn target_root(pidfd: &OwnedFd) -> io::Result<File> {
    pinned_target(pidfd, |pid| {
        OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_PATH | libc::O_DIRECTORY)
            .open(format!("/proc/{pid}/root"))
    })
}

pub(crate) fn target_network(pidfd: &OwnedFd) -> io::Result<File> {
    pinned_target(pidfd, |pid| File::open(format!("/proc/{pid}/ns/net")))
}

pub(crate) fn target_mount_namespace(pidfd: &OwnedFd) -> io::Result<File> {
    pinned_target(pidfd, |pid| File::open(format!("/proc/{pid}/ns/mnt")))
}

pub(crate) fn target_mountinfo(pidfd: &OwnedFd) -> io::Result<String> {
    const LIMIT: u64 = 64 * 1024;
    let info = pinned_target(pidfd, |pid| File::open(format!("/proc/{pid}/mountinfo")))?;
    let mut contents = String::new();
    info.take(LIMIT + 1).read_to_string(&mut contents)?;
    if contents.len() as u64 > LIMIT {
        return Err(io::Error::other("worker mountinfo exceeded its limit"));
    }
    Ok(contents)
}

fn dup_high(fd: i32) -> io::Result<OwnedFd> {
    let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 64) };
    if copy < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(copy) })
    }
}

fn capture(reader: impl Read) -> io::Result<Capture> {
    let mut buffer = Capture::default();
    drain(reader, |bytes| {
        buffer.append_bounded(bytes, crate::wire::EXEC_OUTPUT_LIMIT);
    })?;
    Ok(buffer)
}

pub(crate) fn execute(
    pidfd: OwnedFd,
    id: [u8; 16],
    spec: LaunchSpec,
    tty: bool,
    stdin: Option<Vec<u8>>,
    deadline: Instant,
    publish: impl FnOnce(&crate::pty::Master),
) -> io::Result<ExecResult> {
    let input = if let Some(bytes) = stdin {
        let (reader, mut writer) = crate::workload_input::pipe()?;
        if !crate::workload_input::write(&mut writer, &bytes)? {
            return Err(io::Error::other("could not stage bounded exec stdin"));
        }
        Stdio::from(reader)
    } else {
        Stdio::null()
    };
    let (mut child, result_reader, master) = start(pidfd, id, spec, tty, input, deadline)?;
    type Reader = Box<dyn Read + Send>;
    let (out, err): (Reader, Reader) = if let Some(master) = master {
        publish(&master);
        (Box::new(master), Box::new(io::empty()))
    } else {
        (
            Box::new(child.stdout.take().expect("piped output")),
            Box::new(child.stderr.take().expect("piped error")),
        )
    };
    let stdout = thread::spawn(move || capture(out));
    let stderr = thread::spawn(move || capture(err));
    let status = wait(&mut child, deadline, || false);
    let output = stdout
        .join()
        .map_err(|_| io::Error::other("exec output reader panicked"))??;
    let error = stderr
        .join()
        .map_err(|_| io::Error::other("exec error reader panicked"))??;
    Ok(ExecResult {
        code: result_code(status?, result_reader, deadline)?,
        streams: [output, error],
    })
}

fn start(
    pidfd: OwnedFd,
    id: [u8; 16],
    spec: LaunchSpec,
    tty: bool,
    input: Stdio,
    deadline: Instant,
) -> io::Result<(Child, File, Option<crate::pty::Master>)> {
    let root = target_root(&pidfd)?;
    let pidfd = dup_high(pidfd.as_raw_fd())?;
    let root = dup_high(root.as_raw_fd())?;
    let owner = std::process::id() as libc::pid_t;
    let (result_reader, pipe_writer) = crate::workload_input::pipe()?;
    let writer = dup_high(pipe_writer.as_raw_fd())?;
    drop(pipe_writer);
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(io::ErrorKind::TimedOut.into());
    }
    let mut command = Command::new("/init");
    command.process_group(0);
    command
        .args([
            "--run-oci-exec",
            &owner.to_string(),
            &hex(&id),
            &remaining.as_millis().to_string(),
            &serde_json::to_string(&spec)?,
        ])
        .env_clear()
        .stdin(input);
    let master = if tty {
        let (master, slave) = crate::pty::pair()?;
        command
            .stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave));
        Some(master)
    } else {
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
        None
    };
    unsafe {
        command.pre_exec(move || {
            checked(libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0))?;
            if libc::getppid() != owner {
                return Err(io::Error::from_raw_os_error(libc::ECHILD));
            }
            if libc::dup2(pidfd.as_raw_fd(), TARGET_PIDFD) < 0
                || libc::dup2(root.as_raw_fd(), TARGET_ROOT) < 0
                || libc::dup2(writer.as_raw_fd(), RESULT_PIPE) < 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok((command.spawn()?, result_reader, master))
}

fn child_pidfd(pid: libc::pid_t) -> Option<OwnedFd> {
    // Both callers own the unreaped child, so its PID cannot be reused.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if fd < 0 {
        return None;
    }
    Some(unsafe { OwnedFd::from_raw_fd(fd as i32) })
}

const EXIT_POLL_INTERVAL: Duration = Duration::from_millis(5);

fn wait_for_exit(pidfd: Option<&OwnedFd>, deadline: Instant) {
    if let Some(pidfd) = pidfd {
        match crate::socket::wait(pidfd.as_raw_fd(), libc::POLLIN, None, Some(deadline)) {
            Ok(()) => return,
            Err(error) if error.kind() == io::ErrorKind::TimedOut => return,
            Err(_) => {}
        }
    }
    // Keep checking waitpid if the kernel could not provide process readiness.
    thread::sleep(
        deadline
            .saturating_duration_since(Instant::now())
            .min(EXIT_POLL_INTERVAL),
    );
}

fn wait(
    child: &mut Child,
    deadline: Instant,
    cancelled: impl Fn() -> bool,
) -> io::Result<ExitStatus> {
    let pid = child.id() as libc::pid_t;
    let process_group = -pid;
    let pidfd = child_pidfd(pid);
    let kill_deadline = deadline + Duration::from_millis(500);
    let mut forced = None;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                crate::recovery_fixture::reap_owned_children(process_group)?;
                return Err(error);
            }
        }
        if cancelled() || Instant::now() >= kill_deadline {
            child.kill()?;
            forced = Some(if Instant::now() >= deadline {
                io::ErrorKind::TimedOut
            } else {
                io::ErrorKind::ConnectionAborted
            });
            break child.wait()?;
        }
        wait_for_exit(
            pidfd.as_ref(),
            kill_deadline.min(Instant::now() + EXIT_POLL_INTERVAL),
        );
    };
    if forced.is_some() || status.signal().is_some() {
        // Container removal can kill the exec wrapper and its child
        // together. Reap only this wrapper's adopted descendants so the
        // owning workload can finish cgroup cleanup.
        crate::recovery_fixture::reap_owned_children(process_group)?;
    }
    forced.map_or(Ok(status), |error| Err(error.into()))
}

fn result_code(status: ExitStatus, mut result_reader: File, deadline: Instant) -> io::Result<i32> {
    let mut result = [0];
    let count = result_reader.read(&mut result)?;
    if result == [1] || (Instant::now() >= deadline && status.signal() == Some(libc::SIGKILL)) {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "exec fixture timed out",
        ));
    }
    if count != 1 {
        return Err(io::Error::other(
            "native exec helper lost its result channel",
        ));
    }
    Ok(status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0)))
}

pub(crate) fn execute_stream(
    pidfd: OwnedFd,
    id: [u8; 16],
    spec: LaunchSpec,
    peer: &mut Stream,
    deadline: Instant,
) -> io::Result<i32> {
    let (mut source, stop_input) = peer.cancellable_clone()?;
    source.deadline(Some(deadline));
    let mut target = peer.try_clone()?;
    target.deadline(Some(deadline));
    let (reader, writer) = crate::workload_input::pipe()?;
    let (mut child, result_reader, _) =
        start(pidfd, id, spec, false, Stdio::from(reader), deadline)?;
    let mut stdout = child.stdout.take().expect("piped output");
    let mut stderr = child.stderr.take().expect("piped error");
    let cancelled = AtomicBool::new(false);
    let target = Mutex::new(target);

    thread::scope(|workers| {
        let stopped = &cancelled;
        let input = workers.spawn(move || -> io::Result<()> {
            let mut chunk = [0; crate::wire::EXEC_STREAM_INPUT];
            let mut writer = Some(writer);
            loop {
                let count = match crate::wire::read_exec_input(&mut source, &mut chunk) {
                    Ok(count) => count,
                    Err(_) if stopped.load(Ordering::Acquire) => return Ok(()),
                    Err(error) => {
                        stopped.store(true, Ordering::Release);
                        return Err(error);
                    }
                };
                if count == 0 {
                    writer.take();
                    continue;
                }
                let Some(pipe) = &mut writer else {
                    stopped.store(true, Ordering::Release);
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "exec input continued after EOF",
                    ));
                };
                loop {
                    if stopped.load(Ordering::Acquire) || Instant::now() >= deadline {
                        return Ok(());
                    }
                    match crate::workload_input::write(pipe, &chunk[..count]) {
                        Ok(true) => break,
                        Ok(false) => crate::socket::wait(
                            pipe.as_raw_fd(),
                            libc::POLLOUT,
                            None,
                            Some(deadline),
                        )?,
                        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => return Ok(()),
                        Err(error) => {
                            stopped.store(true, Ordering::Release);
                            return Err(error);
                        }
                    }
                }
            }
        });
        let target = &target;
        let forward = move |stream, reader: &mut dyn Read| -> io::Result<()> {
            let mut chunk = [0; crate::wire::EXEC_STREAM_CHUNK];
            loop {
                let count = reader.read(&mut chunk)?;
                if count == 0 {
                    return Ok(());
                }
                let mut stream_target = target.lock().unwrap();
                stream_target.deadline(Some(deadline.min(Instant::now() + Duration::from_secs(5))));
                crate::wire::write_exec_stream(&mut *stream_target, stream, &chunk[..count])?;
            }
        };
        let forward_output = move |stream, reader: &mut dyn Read| {
            let result = forward(stream, reader);
            if result.is_err() {
                stopped.store(true, Ordering::Release);
            }
            result
        };
        let out = workers.spawn(move || forward_output(1, &mut stdout));
        let err = workers.spawn(move || forward_output(2, &mut stderr));
        let status = wait(&mut child, deadline, || {
            if cancelled.load(Ordering::Acquire) {
                return true;
            }
            let mut descriptor = libc::pollfd {
                fd: peer.as_raw_fd(),
                events: libc::POLLOUT,
                revents: 0,
            };
            unsafe { libc::poll(&mut descriptor, 1, 0) };
            descriptor.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
        });
        cancelled.store(true, Ordering::Release);
        stop_input.request()?;
        input
            .join()
            .map_err(|_| io::Error::other("exec input worker stopped"))??;
        out.join()
            .map_err(|_| io::Error::other("exec output worker stopped"))??;
        err.join()
            .map_err(|_| io::Error::other("exec error worker stopped"))??;
        result_code(status?, result_reader, deadline)
    })
}

pub(crate) fn program_paths(spec: &LaunchSpec) -> io::Result<Vec<CString>> {
    let program = &spec.argv[0];
    if program.starts_with('/') {
        return Ok(vec![CString::new(program.as_bytes())?]);
    }
    spec.env
        .iter()
        .find_map(|entry| entry.strip_prefix("PATH="))
        .unwrap_or("/bin:/usr/bin")
        .split(':')
        .take(32)
        .filter(|directory| {
            directory.starts_with('/')
                && directory.split('/').all(|part| !matches!(part, "." | ".."))
        })
        .map(|directory| {
            CString::new(format!("{}/{program}", directory.trim_end_matches('/')))
                .map_err(Into::into)
        })
        .collect()
}

pub fn run_helper(
    mut args: impl Iterator<Item = std::ffi::OsString>,
) -> Result<(), Box<dyn std::error::Error>> {
    let owner: i32 = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("missing exec owner")?
        .parse()?;
    let workload = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("missing exec workload")?;
    let id = unhex::<16>(&workload)?;
    let budget: u64 = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("missing exec budget")?
        .parse()?;
    if !(1..=crate::wire::BUILDKIT_EXEC_BUDGET_MS).contains(&budget) {
        return Err("invalid exec budget".into());
    }
    let deadline = Instant::now() + Duration::from_millis(budget);
    let specification = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("missing exec specification")?;
    if owner <= 1 || unsafe { libc::getppid() } != owner || args.next().is_some() {
        return Err("exec helper requires its guest supervisor".into());
    }
    let intent =
        crate::intent::Intent::open(std::path::Path::new(crate::intent::DIRECTORY)).scoped(id);
    if intent.read()? != Some(id) {
        return Err("exec helper lacks owned OCI intent".into());
    }
    let spec: LaunchSpec = serde_json::from_str(&specification)?;
    spec.validate_exec()?;
    if budget > crate::wire::EXEC_STREAM_BUDGET_MS
        && !crate::spec::buildkit_control_exec(&spec.image_digest, &spec.argv)
    {
        return Err("long exec budgets require the pinned BuildKit control command".into());
    }

    let args: Vec<_> = spec
        .argv
        .iter()
        .map(|value| CString::new(value.as_bytes()))
        .collect::<Result<_, _>>()?;
    let env: Vec<_> = spec
        .env
        .iter()
        .map(|value| CString::new(value.as_bytes()))
        .collect::<Result<_, _>>()?;
    let argv: Vec<_> = args
        .iter()
        .map(|value| value.as_ptr())
        .chain([std::ptr::null()])
        .collect();
    let envp: Vec<_> = env
        .iter()
        .map(|value| value.as_ptr())
        .chain([std::ptr::null()])
        .collect();
    let cwd = CString::new(spec.cwd.as_bytes())?;
    let executables = program_paths(&spec)?;
    let aggregate = crate::kernel_fixture::build_cgroup_path(&workload);
    let worker = aggregate.join(&workload);
    let cgroup = if worker.is_dir() {
        worker
    } else {
        crate::kernel_fixture::cgroup_scope(&workload, false, true)
    };
    crate::cgroups::write_control(&cgroup, "cgroup.procs", "0")?;
    security::prepare_open_files(security::BUILDKIT_OPEN_FILES)?;
    security::clear_supplementary_groups()?;
    let flags = libc::CLONE_NEWUSER
        | libc::CLONE_NEWNS
        | libc::CLONE_NEWPID
        | libc::CLONE_NEWNET
        | libc::CLONE_NEWIPC
        | libc::CLONE_NEWUTS;
    checked(unsafe { libc::setns(TARGET_PIDFD, flags) })?;
    checked(unsafe { libc::setresgid(0, 0, 0) })?;
    checked(unsafe { libc::setresuid(0, 0, 0) })?;
    checked(unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) })?;
    if unsafe { libc::getppid() } != owner {
        return Err("exec supervisor lost after namespace entry".into());
    }
    checked(unsafe { libc::fchdir(TARGET_ROOT) })?;
    checked(unsafe { libc::chroot(c".".as_ptr()) })?;
    checked(unsafe { libc::chdir(cwd.as_ptr()) })?;
    let filter = security::WorkloadFilter::new(
        spec.bridge_scope().is_some(),
        spec.build_snapshot.is_none(),
        if spec.buildkit_worker {
            security::WorkloadPolicy::BuildKitControl
        } else if spec.docker_default_capabilities {
            security::WorkloadPolicy::DockerDefault
        } else {
            security::WorkloadPolicy::DockerRestricted
        },
    );
    let mut lifeline = [-1; 2];
    checked(unsafe { libc::pipe2(lifeline.as_mut_ptr(), libc::O_CLOEXEC) })?;
    let child = unsafe { libc::fork() };
    if child < 0 {
        return Err(io::Error::last_os_error().into());
    }
    if child == 0 {
        unsafe {
            libc::close(lifeline[1]);
        }
        let setup = (|| -> io::Result<()> {
            security::set_process_limits(
                security::BUILDKIT_OPEN_FILES,
                security::BUILDKIT_FILE_SIZE,
                spec.open_files_limit,
            )?;
            security::drop_workload_identity(
                spec.uid,
                spec.gid,
                &[],
                if spec.docker_default_capabilities {
                    security::WorkloadPolicy::DockerDefault
                } else {
                    security::WorkloadPolicy::Standard
                },
                spec.docker_net_admin,
            )?;
            checked(unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) })?;
            let mut poll = libc::pollfd {
                fd: lifeline[0],
                events: libc::POLLIN,
                revents: 0,
            };
            // The parent holds an empty lifeline pipe. A hangup means it
            // died before the child's parent-death signal was installed.
            if unsafe { libc::poll(&mut poll, 1, 0) } != 0 {
                return Err(io::Error::other("exec helper is no longer live"));
            }
            checked(unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) as i32 })?;
            security::prepare_exec_signals()?;
            security::install_syscall_denials(&spec.syscall_denials)?;
            filter.install()
        })();
        if setup.is_err() {
            unsafe { libc::_exit(126) };
        }
        unsafe {
            for executable in &executables {
                libc::execve(executable.as_ptr(), argv.as_ptr(), envp.as_ptr());
            }
            libc::_exit(127);
        }
    }
    unsafe {
        libc::close(lifeline[0]);
    }
    let pidfd = child_pidfd(child);
    let mut timed_out = false;
    let status = loop {
        let mut status = 0;
        let wait = unsafe { libc::waitpid(child, &mut status, libc::WNOHANG) };
        if wait == child {
            break status;
        }
        if wait < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error.into());
        }
        if Instant::now() >= deadline {
            timed_out = true;
            // This is our unreaped child, so its numeric PID is stable.
            if unsafe { libc::kill(child, libc::SIGKILL) } != 0
                && io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
            {
                return Err(io::Error::last_os_error().into());
            }
            break crate::kernel_fixture::reap(child)?;
        }
        wait_for_exit(pidfd.as_ref(), deadline);
    };
    unsafe {
        libc::close(lifeline[1]);
    }
    let byte = u8::from(timed_out);
    if unsafe { libc::write(RESULT_PIPE, (&byte as *const u8).cast(), 1) } != 1 {
        return Err(io::Error::last_os_error().into());
    }
    if libc::WIFEXITED(status) {
        std::process::exit(libc::WEXITSTATUS(status));
    }
    if libc::WIFSIGNALED(status) {
        std::process::exit(128 + libc::WTERMSIG(status));
    }
    Err("exec child did not report its exit".into())
}

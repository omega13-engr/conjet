use std::io;

const AUDIT_ARCH_AARCH64: u32 = 0xc000_00b7;
const RET_KILL_PROCESS: u32 = 0x8000_0000;
const RET_ERRNO: u32 = 0x0005_0000;
const RET_ALLOW: u32 = 0x7fff_0000;
const BPF_LOAD_WORD: u16 = 0x20;
const BPF_JUMP_EQUAL: u16 = 0x15;
const BPF_RETURN: u16 = 0x06;
const BPF_AND: u16 = 0x54;
const SYS_FADVISE64_AARCH64: u32 = 223;
// Linux capability numbers for CHOWN, DAC_OVERRIDE, SETGID, and SETUID.
const REDIS_CAPABILITIES: u32 = (1 << 0) | (1 << 1) | (1 << 6) | (1 << 7);
// CHOWN, DAC_OVERRIDE, FOWNER and SYS_ADMIN in the worker's mapped user namespace.
const BUILDKIT_CAPABILITIES: u32 = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 21);

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum WorkloadPolicy {
    Standard,
    RedisBootstrap,
    BuildKitWorker,
    BuildKitControl,
}

pub(crate) fn clear_supplementary_groups() -> io::Result<()> {
    checked(unsafe { libc::setgroups(0, std::ptr::null()) })
}

pub(crate) fn drop_workload_identity(
    uid: u32,
    gid: u32,
    supplementary_primary_gid: bool,
    policy: WorkloadPolicy,
) -> io::Result<()> {
    let mut group = 0;
    let count = unsafe { libc::getgroups(1, &mut group) };
    let valid = if supplementary_primary_gid {
        count == 1 && group == gid
    } else {
        count == 0
    };
    if !valid {
        return Err(io::Error::other(
            "unexpected supplementary groups after clone",
        ));
    }
    checked(unsafe {
        libc::prctl(
            libc::PR_CAP_AMBIENT,
            libc::PR_CAP_AMBIENT_CLEAR_ALL,
            0,
            0,
            0,
        )
    })?;
    let allowed = match policy {
        WorkloadPolicy::RedisBootstrap => REDIS_CAPABILITIES,
        WorkloadPolicy::BuildKitWorker => BUILDKIT_CAPABILITIES,
        _ => 0,
    };
    for capability in 0..64 {
        let supported = unsafe { libc::prctl(libc::PR_CAPBSET_READ, capability, 0, 0, 0) };
        if supported < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINVAL) {
                break;
            }
            return Err(error);
        }
        if (u64::from(allowed) & (1 << capability)) == 0 {
            checked(unsafe { libc::prctl(libc::PR_CAPBSET_DROP, capability, 0, 0, 0) })?;
        }
    }
    checked(unsafe { libc::setresgid(gid, gid, gid) })?;
    checked(unsafe { libc::setresuid(uid, uid, uid) })?;

    let header = CapabilityHeader::current();
    let capabilities = [allowed, allowed, 0, 0, 0, 0];
    // The kernel reads exactly the versioned C header and two data entries.
    if unsafe { libc::syscall(libc::SYS_capset, &header, capabilities.as_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    checked(unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) })?;
    // Namespace root must enter exec with the same empty capability state.
    if uid == 0 && allowed == 0 {
        verify_empty_capabilities()?;
    }
    Ok(())
}

#[repr(C)]
struct CapabilityHeader {
    version: u32,
    pid: i32,
}

impl CapabilityHeader {
    fn current() -> Self {
        Self {
            version: 0x2008_0522,
            pid: 0,
        }
    }
}

pub(crate) fn verify_empty_capabilities() -> io::Result<()> {
    let mut header = CapabilityHeader::current();
    let mut masks = [0u32; 6];
    // The kernel writes the bounded versioned capability header and masks.
    if unsafe { libc::syscall(libc::SYS_capget, &mut header, masks.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if masks != [0; 6] {
        return Err(io::Error::other("application retained capabilities"));
    }
    Ok(())
}

pub(crate) const DEFAULT_OPEN_FILES: u64 = 32;
pub(crate) const DEFAULT_FILE_SIZE: u64 = 16 * 1024 * 1024;
pub(crate) const BUILDKIT_OPEN_FILES: u64 = 256;
// The pinned Rust image stores a 299,606,552-byte compiler library.
pub(crate) const BUILDKIT_FILE_SIZE: u64 = 512 * 1024 * 1024;
// The pinned Redis server's default client limit requires this many
// descriptors. Its cgroup still bounds memory, CPU and tasks.
pub(crate) const REDIS_OPEN_FILES: u64 = 10_032;

pub(crate) fn prepare_redis_open_files() -> io::Result<()> {
    let mut bounds = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    checked(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut bounds) })?;
    if bounds.rlim_max < REDIS_OPEN_FILES {
        // Raise the ceiling in the private helper before entering the user
        // namespace, where the child cannot raise an inherited hard limit.
        bounds.rlim_max = REDIS_OPEN_FILES;
        checked(unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &bounds) })?;
    }
    Ok(())
}

pub(crate) fn set_process_limits(open_files: u64, file_size: u64) -> io::Result<()> {
    for (resource, maximum) in [
        (libc::RLIMIT_CORE, 0),
        (libc::RLIMIT_NOFILE, open_files),
        (libc::RLIMIT_FSIZE, file_size),
    ] {
        let bounds = libc::rlimit {
            rlim_cur: maximum,
            rlim_max: maximum,
        };
        checked(unsafe { libc::setrlimit(resource, &bounds) })?;
    }
    Ok(())
}

pub(crate) struct WorkloadFilter {
    program: Vec<libc::sock_filter>,
}

impl WorkloadFilter {
    pub(crate) fn new(bridge: bool, ordinary_oci: bool, policy: WorkloadPolicy) -> Self {
        fn statement(code: u16, k: u32) -> libc::sock_filter {
            libc::sock_filter {
                code,
                k,
                jt: 0,
                jf: 0,
            }
        }
        fn next_or_skip(value: u32) -> libc::sock_filter {
            libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: value,
                jt: 0,
                jf: 1,
            }
        }
        let allowed = [
            libc::SYS_read,
            libc::SYS_write,
            libc::SYS_readv,
            libc::SYS_writev,
            libc::SYS_openat,
            libc::SYS_close,
            libc::SYS_lseek,
            libc::SYS_fstat,
            libc::SYS_newfstatat,
            libc::SYS_statx,
            libc::SYS_readlinkat,
            libc::SYS_getcwd,
            libc::SYS_fcntl,
            libc::SYS_capget,
            libc::SYS_dup,
            libc::SYS_dup3,
            libc::SYS_brk,
            libc::SYS_mmap,
            libc::SYS_munmap,
            libc::SYS_mprotect,
            libc::SYS_madvise,
            libc::SYS_mremap,
            libc::SYS_set_tid_address,
            libc::SYS_set_robust_list,
            libc::SYS_futex,
            libc::SYS_sched_getaffinity,
            libc::SYS_ppoll,
            libc::SYS_rt_sigaction,
            libc::SYS_rt_sigprocmask,
            libc::SYS_rt_sigreturn,
            libc::SYS_sigaltstack,
            libc::SYS_getrandom,
            libc::SYS_clock_gettime,
            libc::SYS_clock_nanosleep,
            libc::SYS_nanosleep,
            libc::SYS_getpid,
            libc::SYS_gettid,
            libc::SYS_getuid,
            libc::SYS_getgid,
            libc::SYS_geteuid,
            libc::SYS_getegid,
            libc::SYS_getgroups,
            libc::SYS_uname,
            libc::SYS_prlimit64,
            libc::SYS_execve,
            libc::SYS_execveat,
            libc::SYS_exit,
            libc::SYS_exit_group,
        ];
        let mut program = vec![
            statement(BPF_LOAD_WORD, 4), // seccomp_data.arch
            libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: AUDIT_ARCH_AARCH64,
                jt: 1,
                jf: 0,
            },
            statement(BPF_RETURN, RET_KILL_PROCESS),
            statement(BPF_LOAD_WORD, 0), // seccomp_data.nr
        ];
        if ordinary_oci {
            let denied = RET_ERRNO | libc::EPERM as u32;
            let sigchld = libc::SIGCHLD as u32;
            let tid_flags = (libc::CLONE_CHILD_CLEARTID
                | libc::CLONE_CHILD_SETTID
                | libc::CLONE_PARENT_SETTID) as u32;
            let thread_required = (libc::CLONE_VM
                | libc::CLONE_FS
                | libc::CLONE_FILES
                | libc::CLONE_SIGHAND
                | libc::CLONE_THREAD) as u32;
            // musl still supplies the ignored legacy CLONE_DETACHED bit.
            let thread_allowed = thread_required
                | tid_flags
                | (libc::CLONE_SETTLS | libc::CLONE_SYSVSEM | libc::CLONE_DETACHED) as u32;
            let skip_if_zero = |count| libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: 0,
                jt: count,
                jf: 0,
            };
            let thread = [
                statement(BPF_LOAD_WORD, 16),
                statement(BPF_AND, !thread_allowed),
                skip_if_zero(1),
                statement(BPF_RETURN, denied),
                statement(BPF_LOAD_WORD, 16),
                statement(BPF_AND, thread_required),
                next_or_skip(thread_required),
                statement(BPF_RETURN, RET_ALLOW),
                statement(BPF_RETURN, denied),
            ];
            let mut clone = vec![
                statement(BPF_LOAD_WORD, 20), // high word of args[0]
                skip_if_zero(1),
                statement(BPF_RETURN, denied),
                statement(BPF_LOAD_WORD, 16), // low word of args[0]
                statement(BPF_AND, libc::CLONE_THREAD as u32),
                skip_if_zero(thread.len() as u8),
            ];
            clone.extend(thread);
            clone.extend([
                statement(BPF_LOAD_WORD, 16),
                statement(BPF_AND, !tid_flags),
                next_or_skip(sigchld),
                statement(BPF_RETURN, RET_ALLOW),
                next_or_skip(sigchld | (libc::CLONE_VM | libc::CLONE_VFORK) as u32),
                statement(BPF_RETURN, RET_ALLOW),
                statement(BPF_RETURN, denied),
            ]);
            program.push(libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: libc::SYS_clone as u32,
                jt: 0,
                jf: clone.len() as u8,
            });
            program.extend(clone);
            let descriptor_control = [
                statement(BPF_LOAD_WORD, 28), // high word of args[1]
                skip_if_zero(1),
                statement(BPF_RETURN, denied),
                statement(BPF_LOAD_WORD, 24), // low word of args[1]
                next_or_skip(libc::FIONBIO as u32),
                statement(BPF_RETURN, RET_ALLOW),
                next_or_skip(libc::TCGETS as u32),
                statement(BPF_RETURN, RET_ALLOW),
                next_or_skip(libc::TIOCGWINSZ as u32),
                statement(BPF_RETURN, RET_ALLOW),
                statement(BPF_RETURN, denied),
            ];
            program.push(libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: libc::SYS_ioctl as u32,
                jt: 0,
                jf: descriptor_control.len() as u8,
            });
            program.extend(descriptor_control);
            // Classic BPF cannot inspect clone3's pointed-to flags. Let
            // libc retry through the checked clone ABI.
            program.push(next_or_skip(libc::SYS_clone3 as u32));
            program.push(statement(BPF_RETURN, RET_ERRNO | libc::ENOSYS as u32));
            // The pinned Alpine musl implements pwrite using pwritev2 with
            // RWF_NOAPPEND. Check the Linux ABI's sixth argument (flags).
            let positional_write = [
                statement(BPF_LOAD_WORD, 16 + 5 * 8),
                next_or_skip(0x20), // RWF_NOAPPEND
                statement(BPF_RETURN, RET_ALLOW),
                statement(BPF_RETURN, RET_ERRNO | libc::EPERM as u32),
            ];
            program.push(libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: libc::SYS_pwritev2 as u32,
                jt: 0,
                jf: positional_write.len() as u8,
            });
            program.extend(positional_write);
            for syscall in [
                libc::SYS_pipe2,
                libc::SYS_wait4,
                libc::SYS_getppid,
                libc::SYS_umask,
                libc::SYS_getdents64,
                libc::SYS_unlinkat,
                libc::SYS_mkdirat,
                libc::SYS_renameat,
                libc::SYS_truncate,
                libc::SYS_ftruncate,
                libc::SYS_pread64,
                libc::SYS_pwrite64,
                libc::SYS_fsync,
                libc::SYS_fdatasync,
                libc::SYS_epoll_create1,
                libc::SYS_epoll_ctl,
                libc::SYS_epoll_pwait,
                libc::SYS_eventfd2,
            ] {
                program.push(next_or_skip(syscall as u32));
                program.push(statement(BPF_RETURN, RET_ALLOW));
            }
            let cache_advice = [
                statement(BPF_LOAD_WORD, 16 + 3 * 8),
                next_or_skip(libc::POSIX_FADV_DONTNEED as u32),
                statement(BPF_RETURN, RET_ALLOW),
                statement(BPF_RETURN, RET_ERRNO | libc::EPERM as u32),
            ];
            program.push(libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: SYS_FADVISE64_AARCH64,
                jt: 0,
                jf: cache_advice.len() as u8,
            });
            program.extend(cache_advice);
        }
        if policy == WorkloadPolicy::RedisBootstrap {
            for syscall in [
                libc::SYS_fchownat,
                libc::SYS_getresuid,
                libc::SYS_getresgid,
                libc::SYS_setgroups,
                libc::SYS_setresuid,
                libc::SYS_setresgid,
                libc::SYS_setuid,
                libc::SYS_setgid,
                libc::SYS_capset,
            ] {
                program.push(next_or_skip(syscall as u32));
                program.push(statement(BPF_RETURN, RET_ALLOW));
            }
            let controls = [
                statement(BPF_LOAD_WORD, 16),
                // util-linux setpriv retains the bounded permitted mask
                // across its UID/GID transition. Exec clears KEEPCAPS.
                libc::sock_filter {
                    code: BPF_JUMP_EQUAL,
                    k: libc::PR_SET_KEEPCAPS as u32,
                    jt: 0,
                    jf: 4,
                },
                statement(BPF_LOAD_WORD, 24),
                next_or_skip(1),
                statement(BPF_RETURN, RET_ALLOW),
                statement(BPF_RETURN, RET_ERRNO | libc::EPERM as u32),
                next_or_skip(libc::PR_GET_NO_NEW_PRIVS as u32),
                statement(BPF_RETURN, RET_ALLOW),
                next_or_skip(libc::PR_SET_NO_NEW_PRIVS as u32),
                statement(BPF_RETURN, RET_ALLOW),
                next_or_skip(libc::PR_GET_SECUREBITS as u32),
                statement(BPF_RETURN, RET_ALLOW),
                next_or_skip(libc::PR_CAPBSET_READ as u32),
                statement(BPF_RETURN, RET_ALLOW),
                statement(BPF_RETURN, RET_ERRNO | libc::EPERM as u32),
            ];
            program.push(libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: libc::SYS_prctl as u32,
                jt: 0,
                jf: controls.len() as u8,
            });
            program.extend(controls);
        }
        let unix = matches!(
            policy,
            WorkloadPolicy::BuildKitWorker | WorkloadPolicy::BuildKitControl
        );
        if policy == WorkloadPolicy::BuildKitWorker {
            for syscall in [
                libc::SYS_flock,
                libc::SYS_fchmod,
                libc::SYS_fchmodat,
                libc::SYS_fchownat,
                libc::SYS_statfs,
                libc::SYS_fstatfs,
                libc::SYS_utimensat,
                libc::SYS_symlinkat,
                libc::SYS_linkat,
                libc::SYS_llistxattr,
                libc::SYS_lgetxattr,
                libc::SYS_waitid,
                libc::SYS_mount,
                libc::SYS_umount2,
            ] {
                program.push(next_or_skip(syscall as u32));
                program.push(statement(BPF_RETURN, RET_ALLOW));
            }
        }
        if bridge || unix {
            let denied = RET_ERRNO | libc::EPERM as u32;
            let mut socket = vec![statement(BPF_LOAD_WORD, 16)];
            if unix {
                let stream = [
                    statement(BPF_LOAD_WORD, 32),
                    libc::sock_filter {
                        code: BPF_JUMP_EQUAL,
                        k: 0,
                        jt: 1,
                        jf: 0,
                    },
                    statement(BPF_RETURN, denied),
                    statement(BPF_LOAD_WORD, 24),
                    statement(
                        BPF_AND,
                        !((libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK) as u32),
                    ),
                    next_or_skip(libc::SOCK_STREAM as u32),
                    statement(BPF_RETURN, RET_ALLOW),
                    statement(BPF_RETURN, denied),
                ];
                socket.push(libc::sock_filter {
                    code: BPF_JUMP_EQUAL,
                    k: libc::AF_UNIX as u32,
                    jt: 0,
                    jf: stream.len() as u8,
                });
                socket.extend(stream);
            }
            if bridge {
                socket.extend([
                    libc::sock_filter {
                        code: BPF_JUMP_EQUAL,
                        k: libc::AF_INET as u32,
                        jt: 3,
                        jf: 0,
                    },
                    next_or_skip(libc::AF_INET6 as u32),
                    statement(BPF_RETURN, RET_ERRNO | libc::EAFNOSUPPORT as u32),
                    statement(BPF_RETURN, denied),
                    statement(BPF_LOAD_WORD, 24), // args[1]: type and socket flags
                    statement(
                        BPF_AND,
                        !((libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK) as u32),
                    ),
                    // libc's getaddrinfo returns the explicit protocol that the
                    // kernel would select for the corresponding socket type.
                    libc::sock_filter {
                        code: BPF_JUMP_EQUAL,
                        k: libc::SOCK_STREAM as u32,
                        jt: 0,
                        jf: 6,
                    },
                    statement(BPF_LOAD_WORD, 32), // args[2]: protocol
                    next_or_skip(0),
                    statement(BPF_RETURN, RET_ALLOW),
                    next_or_skip(libc::IPPROTO_TCP as u32),
                    statement(BPF_RETURN, RET_ALLOW),
                    statement(BPF_RETURN, denied),
                    libc::sock_filter {
                        code: BPF_JUMP_EQUAL,
                        k: libc::SOCK_DGRAM as u32,
                        jt: 0,
                        jf: 5,
                    },
                    statement(BPF_LOAD_WORD, 32),
                    next_or_skip(0),
                    statement(BPF_RETURN, RET_ALLOW),
                    next_or_skip(libc::IPPROTO_UDP as u32),
                    statement(BPF_RETURN, RET_ALLOW),
                    statement(BPF_RETURN, denied),
                ]);
            } else {
                socket.push(statement(BPF_RETURN, denied));
            }
            program.push(libc::sock_filter {
                code: BPF_JUMP_EQUAL,
                k: libc::SYS_socket as u32,
                jt: 0,
                jf: socket.len() as u8,
            });
            program.extend(socket);
            for syscall in [
                libc::SYS_bind,
                libc::SYS_connect,
                libc::SYS_sendto,
                libc::SYS_recvfrom,
                libc::SYS_recvmsg,
                libc::SYS_setsockopt,
                libc::SYS_getsockopt,
                libc::SYS_getsockname,
                libc::SYS_getpeername,
                libc::SYS_listen,
                libc::SYS_accept,
                libc::SYS_accept4,
                libc::SYS_shutdown,
            ] {
                program.push(next_or_skip(syscall as u32));
                program.push(statement(BPF_RETURN, RET_ALLOW));
            }
        }
        for syscall in allowed {
            program.push(next_or_skip(syscall as u32));
            program.push(statement(BPF_RETURN, RET_ALLOW));
        }
        program.push(statement(BPF_RETURN, RET_ERRNO | libc::EPERM as u32));
        Self { program }
    }

    pub(crate) fn install(&self) -> io::Result<()> {
        let filter = libc::sock_fprog {
            len: self.program.len() as u16,
            filter: self.program.as_ptr().cast_mut(),
        };
        // The program stays live until the kernel has copied its bounded instructions.
        checked(unsafe { libc::prctl(libc::PR_SET_SECCOMP, 2, &filter, 0, 0) })
    }
}

pub(crate) fn checked(result: libc::c_int) -> io::Result<()> {
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

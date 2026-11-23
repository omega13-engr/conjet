use std::io;

use crate::spec::{WORKLOAD_GID, WORKLOAD_UID};

const AUDIT_ARCH_AARCH64: u32 = 0xc000_00b7;
const RET_KILL_PROCESS: u32 = 0x8000_0000;
const RET_ERRNO: u32 = 0x0005_0000;
const RET_ALLOW: u32 = 0x7fff_0000;
const BPF_LOAD_WORD: u16 = 0x20;
const BPF_JUMP_EQUAL: u16 = 0x15;
const BPF_RETURN: u16 = 0x06;
const BPF_AND: u16 = 0x54;

pub(crate) fn clear_supplementary_groups() -> io::Result<()> {
    checked(unsafe { libc::setgroups(0, std::ptr::null()) })
}

pub(crate) fn drop_workload_identity() -> io::Result<()> {
    if unsafe { libc::getgroups(0, std::ptr::null_mut()) } != 0 {
        return Err(io::Error::other(
            "supplementary groups were not cleared before clone",
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
    for capability in 0..64 {
        let supported = unsafe { libc::prctl(libc::PR_CAPBSET_READ, capability, 0, 0, 0) };
        if supported < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINVAL) {
                break;
            }
            return Err(error);
        }
        checked(unsafe { libc::prctl(libc::PR_CAPBSET_DROP, capability, 0, 0, 0) })?;
    }
    checked(unsafe { libc::setresgid(WORKLOAD_GID, WORKLOAD_GID, WORKLOAD_GID) })?;
    checked(unsafe { libc::setresuid(WORKLOAD_UID, WORKLOAD_UID, WORKLOAD_UID) })?;

    let header = CapabilityHeader::current();
    let empty = [0u32; 6]; // Two Linux capability data entries, three masks each.
    // The kernel reads exactly the versioned C header and two data entries.
    if unsafe { libc::syscall(libc::SYS_capset, &header, empty.as_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    checked(unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) })
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

pub(crate) fn set_process_limits() -> io::Result<()> {
    for (resource, maximum) in [
        (libc::RLIMIT_CORE, 0),
        (libc::RLIMIT_NOFILE, 32),
        (libc::RLIMIT_FSIZE, 16 * 1024 * 1024),
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
    pub(crate) fn new(bridge: bool) -> Self {
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
        if bridge {
            let denied = RET_ERRNO | libc::EPERM as u32;
            let socket = [
                statement(BPF_LOAD_WORD, 16), // args[0]: domain, little-endian ARM64
                libc::sock_filter {
                    code: BPF_JUMP_EQUAL,
                    k: libc::AF_INET as u32,
                    jt: 1,
                    jf: 0,
                },
                statement(BPF_RETURN, denied),
                statement(BPF_LOAD_WORD, 32), // args[2]: protocol (automatic selection)
                libc::sock_filter {
                    code: BPF_JUMP_EQUAL,
                    k: 0,
                    jt: 1,
                    jf: 0,
                },
                statement(BPF_RETURN, denied),
                statement(BPF_LOAD_WORD, 24), // args[1]: type and socket flags
                statement(
                    BPF_AND,
                    !((libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK) as u32),
                ),
                next_or_skip(libc::SOCK_STREAM as u32),
                statement(BPF_RETURN, RET_ALLOW),
                next_or_skip(libc::SOCK_DGRAM as u32),
                statement(BPF_RETURN, RET_ALLOW),
                statement(BPF_RETURN, denied),
            ];
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

//! AArch64 seccomp for the hash-verified BuildKit RUN policy.
//! Syscall numbers follow Linux asm-generic UAPI (also libc 0.2.186).
//! The source OCI policy is retained in build_snapshot/fixtures/frontend-policy.json.
pub(crate) type Instruction = (u16, u8, u8, u32);
const LOAD: u16 = 0x20;
const EQ: u16 = 0x15;
const AND: u16 = 0x54;
const RET: u16 = 0x06;
const ALLOW: u32 = 0x7fff0000;
const DENY: u32 = 0x00050001;
const ARCH: u32 = 0xc00000b7;
const ALLOWED: &[u32] = &[
    0,   // io_setup
    1,   // io_destroy
    2,   // io_submit
    3,   // io_cancel
    4,   // io_getevents
    5,   // setxattr
    6,   // lsetxattr
    7,   // fsetxattr
    8,   // getxattr
    9,   // lgetxattr
    10,  // fgetxattr
    11,  // listxattr
    12,  // llistxattr
    13,  // flistxattr
    14,  // removexattr
    15,  // lremovexattr
    16,  // fremovexattr
    17,  // getcwd
    19,  // eventfd2
    20,  // epoll_create1
    21,  // epoll_ctl
    22,  // epoll_pwait
    23,  // dup
    24,  // dup3
    25,  // fcntl
    26,  // inotify_init1
    27,  // inotify_add_watch
    28,  // inotify_rm_watch
    29,  // ioctl
    30,  // ioprio_set
    31,  // ioprio_get
    32,  // flock
    33,  // mknodat
    34,  // mkdirat
    35,  // unlinkat
    36,  // symlinkat
    37,  // linkat
    38,  // renameat
    43,  // statfs
    44,  // fstatfs
    45,  // truncate
    46,  // ftruncate
    47,  // fallocate
    48,  // faccessat
    49,  // chdir
    50,  // fchdir
    51,  // chroot
    52,  // fchmod
    53,  // fchmodat
    54,  // fchownat
    55,  // fchown
    56,  // openat
    57,  // close
    59,  // pipe2
    61,  // getdents64
    62,  // lseek
    63,  // read
    64,  // write
    65,  // readv
    66,  // writev
    67,  // pread64
    68,  // pwrite64
    69,  // preadv
    70,  // pwritev
    72,  // pselect6
    73,  // ppoll
    74,  // signalfd4
    75,  // vmsplice
    76,  // splice
    77,  // tee
    78,  // readlinkat
    79,  // newfstatat
    80,  // fstat
    81,  // sync
    82,  // fsync
    83,  // fdatasync
    84,  // sync_file_range
    85,  // timerfd_create
    86,  // timerfd_settime
    87,  // timerfd_gettime
    88,  // utimensat
    90,  // capget
    91,  // capset
    93,  // exit
    94,  // exit_group
    95,  // waitid
    96,  // set_tid_address
    98,  // futex
    99,  // set_robust_list
    100, // get_robust_list
    101, // nanosleep
    102, // getitimer
    103, // setitimer
    107, // timer_create
    108, // timer_gettime
    109, // timer_getoverrun
    110, // timer_settime
    111, // timer_delete
    113, // clock_gettime
    114, // clock_getres
    115, // clock_nanosleep
    117, // ptrace
    118, // sched_setparam
    119, // sched_setscheduler
    120, // sched_getscheduler
    121, // sched_getparam
    122, // sched_setaffinity
    123, // sched_getaffinity
    124, // sched_yield
    125, // sched_get_priority_max
    126, // sched_get_priority_min
    127, // sched_rr_get_interval
    128, // restart_syscall
    129, // kill
    130, // tkill
    131, // tgkill
    132, // sigaltstack
    133, // rt_sigsuspend
    134, // rt_sigaction
    135, // rt_sigprocmask
    136, // rt_sigpending
    137, // rt_sigtimedwait
    138, // rt_sigqueueinfo
    139, // rt_sigreturn
    140, // setpriority
    141, // getpriority
    143, // setregid
    144, // setgid
    145, // setreuid
    146, // setuid
    147, // setresuid
    148, // getresuid
    149, // setresgid
    150, // getresgid
    151, // setfsuid
    152, // setfsgid
    153, // times
    154, // setpgid
    155, // getpgid
    156, // getsid
    157, // setsid
    158, // getgroups
    159, // setgroups
    160, // uname
    163, // getrlimit
    164, // setrlimit
    165, // getrusage
    166, // umask
    167, // prctl
    168, // getcpu
    169, // gettimeofday
    171, // adjtimex
    172, // getpid
    173, // getppid
    174, // getuid
    175, // geteuid
    176, // getgid
    177, // getegid
    178, // gettid
    179, // sysinfo
    180, // mq_open
    181, // mq_unlink
    182, // mq_timedsend
    183, // mq_timedreceive
    184, // mq_notify
    185, // mq_getsetattr
    186, // msgget
    187, // msgctl
    188, // msgrcv
    189, // msgsnd
    190, // semget
    191, // semctl
    192, // semtimedop
    193, // semop
    194, // shmget
    195, // shmctl
    196, // shmat
    197, // shmdt
    199, // socketpair
    200, // bind
    201, // listen
    202, // accept
    203, // connect
    204, // getsockname
    205, // getpeername
    206, // sendto
    207, // recvfrom
    208, // setsockopt
    209, // getsockopt
    210, // shutdown
    211, // sendmsg
    212, // recvmsg
    213, // readahead
    214, // brk
    215, // munmap
    216, // mremap
    221, // execve
    222, // mmap
    226, // mprotect
    227, // msync
    228, // mlock
    229, // munlock
    230, // mlockall
    231, // munlockall
    232, // mincore
    233, // madvise
    234, // remap_file_pages
    240, // rt_tgsigqueueinfo
    242, // accept4
    243, // recvmmsg
    260, // wait4
    261, // prlimit64
    263, // fanotify_mark
    264, // name_to_handle_at
    266, // clock_adjtime
    267, // syncfs
    269, // sendmmsg
    270, // process_vm_readv
    271, // process_vm_writev
    274, // sched_setattr
    275, // sched_getattr
    276, // renameat2
    277, // seccomp
    278, // getrandom
    279, // memfd_create
    281, // execveat
    283, // membarrier
    284, // mlock2
    285, // copy_file_range
    286, // preadv2
    287, // pwritev2
    288, // pkey_mprotect
    289, // pkey_alloc
    290, // pkey_free
    291, // statx
    292, // io_pgetevents
    293, // rseq
    424, // pidfd_send_signal
    434, // pidfd_open
    436, // close_range
    437, // openat2
    439, // faccessat2
    441, // epoll_pwait2
    444, // landlock_create_ruleset
    445, // landlock_add_rule
    446, // landlock_restrict_self
    447, // memfd_secret
    448, // process_mrelease
    449, // futex_waitv
    462, // mseal
];

pub(crate) fn program() -> Vec<Instruction> {
    let mut code = vec![
        (LOAD, 0, 0, 4),
        (EQ, 1, 0, ARCH),
        (RET, 0, 0, 0x80000000),
        (LOAD, 0, 0, 0),
    ];
    for &nr in ALLOWED {
        code.extend([(EQ, 0, 1, nr), (RET, 0, 0, ALLOW)]);
    }
    code.extend([(EQ, 0, 1, 435), (RET, 0, 0, 0x00050026)]); // clone3: ENOSYS
    let mut conditional = |nr: u32, body: Vec<Instruction>| {
        assert!(body.len() <= u8::MAX as usize);
        code.push((EQ, 0, body.len() as u8, nr));
        code.extend(body);
    };
    // Full-width arguments: reject high-word aliasing.
    let prefix = || {
        vec![
            (LOAD, 0, 0, 20),
            (EQ, 1, 0, 0),
            (RET, 0, 0, DENY),
            (LOAD, 0, 0, 16),
        ]
    };
    let mut socket = prefix();
    for family in [
        0, 1, 2, 7, 8, 9, 10, 13, 14, 15, 16, 17, 18, 21, 22, 24, 26, 27, 28, 29, 30, 31, 32, 33,
        35, 36, 39, 41, 42, 43, 44, 45,
    ] {
        socket.extend([(EQ, 0, 1, family), (RET, 0, 0, ALLOW)]);
    }
    socket.push((RET, 0, 0, DENY)); // Includes AF_VSOCK (40).
    conditional(198, socket);
    let mut personality = prefix();
    for value in [0, 8, 131072, 131080, u32::MAX] {
        personality.extend([(EQ, 0, 1, value), (RET, 0, 0, ALLOW)]);
    }
    personality.push((RET, 0, 0, DENY));
    conditional(92, personality);
    let mut clone = prefix();
    clone.extend([
        (AND, 0, 0, 2114060288),
        (EQ, 0, 1, 0),
        (RET, 0, 0, ALLOW),
        (RET, 0, 0, DENY),
    ]);
    conditional(220, clone);
    code.push((RET, 0, 0, DENY));
    code
}

#[cfg(test)]
mod tests {
    use super::*;
    fn evaluate(arch: u32, nr: u32, argument: u64) -> u32 {
        let code = program();
        let mut pc = 0;
        let mut accumulator = 0;
        loop {
            let (op, yes, no, value) = code[pc];
            pc += 1;
            match op {
                LOAD => {
                    accumulator = match value {
                        0 => nr,
                        4 => arch,
                        16 => argument as u32,
                        20 => (argument >> 32) as u32,
                        _ => panic!("unexpected load"),
                    }
                }
                EQ => pc += if accumulator == value { yes } else { no } as usize,
                AND => accumulator &= value,
                RET => return value,
                _ => panic!("unsupported instruction"),
            }
        }
    }
    #[test]
    fn package_management_and_threads_preserve_namespace_boundary() {
        for nr in [54, 55, 146, 147, 159, 198, 199, 220] {
            assert_eq!(evaluate(ARCH, nr, 0), ALLOW, "syscall {nr}");
        }
        for nr in [40, 39, 97, 272, 280, 282, 425, 426, 427] {
            assert_eq!(evaluate(ARCH, nr, 0), DENY, "syscall {nr}");
        }
        assert_eq!(evaluate(ARCH, 198, 40), DENY);
        assert_eq!(evaluate(ARCH, 198, (1u64 << 32) | 2), DENY);
        for flag in [0x10000000, 0x40000000, 0x20000000, 0x00020000] {
            assert_eq!(evaluate(ARCH, 220, flag), DENY);
        }
        assert_eq!(evaluate(ARCH, 435, 0), 0x00050026);
        assert_eq!(evaluate(0x40000028, 63, 0), 0x80000000);
    }
}

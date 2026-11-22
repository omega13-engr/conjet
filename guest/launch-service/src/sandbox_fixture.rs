use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use crate::security::{self, WorkloadFilter};
use crate::spec::{WORKLOAD_GID, WORKLOAD_UID};

const BASE: &str = "/run/conjet/workload-probe";
pub(crate) const BENCHMARK_EXECUTABLE: &str = "/etc/conjet/benchmark-executable";
const UID_BASE: u32 = 100_000;
const GID_BASE: u32 = 100_000;
const UID_WIDTH: u32 = 65_536;

pub(crate) struct Sandbox {
    new_root: CString,
    overlay: CString,
    filter: WorkloadFilter,
    stdin: File,
}

impl Sandbox {
    pub(crate) fn prepare(bridge: bool, benchmark: bool) -> io::Result<Self> {
        let base = Path::new(BASE);
        std::fs::create_dir(base)?;
        let setup = (|| {
            for entry in ["lower", "lower/bin", "lower/work", "upper", "work", "root"] {
                std::fs::create_dir(base.join(entry))?;
            }
            let executable = if benchmark {
                BENCHMARK_EXECUTABLE
            } else {
                "/init"
            };
            std::fs::copy(executable, base.join("lower/bin/probe"))?;
            std::fs::set_permissions(
                base.join("lower/bin/probe"),
                std::fs::Permissions::from_mode(0o555),
            )?;
            std::fs::write(base.join("lower/work/immutable"), b"verified fixture\n")?;
            if bridge {
                std::fs::create_dir(base.join("lower/etc"))?;
                std::fs::write(
                    base.join("lower/etc/resolv.conf"),
                    crate::bridge_fixture::RESOLVER_CONFIG,
                )?;
            }
            for directory in ["upper", "work", "root"] {
                let path = CString::new(base.join(directory).as_os_str().as_bytes())?;
                security::checked(unsafe { libc::chown(path.as_ptr(), UID_BASE, GID_BASE) })?;
                std::fs::set_permissions(
                    Path::new(BASE).join(directory),
                    std::fs::Permissions::from_mode(if directory != "work" {
                        0o755
                    } else {
                        0o700
                    }),
                )?;
            }
            let workspace = CString::new(base.join("lower/work").as_os_str().as_bytes())?;
            security::checked(unsafe {
                libc::chown(
                    workspace.as_ptr(),
                    UID_BASE + WORKLOAD_UID,
                    GID_BASE + WORKLOAD_GID,
                )
            })?;
            std::fs::write(
                base.join("outside-canary"),
                b"must stay outside workload root\n",
            )?;
            Ok(Self {
                new_root: CString::new(base.join("root").as_os_str().as_bytes())?,
                overlay: CString::new(format!(
                    "lowerdir={BASE}/lower,upperdir={BASE}/upper,workdir={BASE}/work,userxattr"
                ))?,
                filter: WorkloadFilter::new(bridge),
                stdin: File::open("/dev/null")?,
            })
        })();
        if setup.is_err() {
            let _ = std::fs::remove_dir_all(base);
        }
        setup
    }

    pub(crate) fn mappings(&self, pid: libc::pid_t) -> io::Result<()> {
        let process = Path::new("/proc").join(pid.to_string());
        std::fs::write(process.join("setgroups"), "deny")?;
        std::fs::write(
            process.join("uid_map"),
            format!("0 {UID_BASE} {UID_WIDTH}\n"),
        )?;
        std::fs::write(
            process.join("gid_map"),
            format!("0 {GID_BASE} {UID_WIDTH}\n"),
        )
    }

    pub(crate) fn enter(&self) -> io::Result<()> {
        fn step(name: &str, result: io::Result<()>) -> io::Result<()> {
            result.map_err(|error| io::Error::other(format!("{name}: {error}")))
        }
        // The child inherited the helper's outer guest IDs. Enter the mapped
        // namespace-root identity before accessing the owned upper/work dirs.
        step(
            "mapped setup gid",
            security::checked(unsafe { libc::setresgid(0, 0, 0) }),
        )?;
        step(
            "mapped setup uid",
            security::checked(unsafe { libc::setresuid(0, 0, 0) }),
        )?;
        step(
            "private mount propagation",
            security::checked(unsafe {
                libc::mount(
                    std::ptr::null(),
                    c"/".as_ptr(),
                    std::ptr::null(),
                    libc::MS_PRIVATE | libc::MS_REC,
                    std::ptr::null(),
                )
            }),
        )?;
        step(
            "private overlay",
            security::checked(unsafe {
                libc::mount(
                    c"overlay".as_ptr(),
                    self.new_root.as_ptr(),
                    c"overlay".as_ptr(),
                    libc::MS_NODEV | libc::MS_NOSUID,
                    self.overlay.as_ptr().cast(),
                )
            }),
        )?;
        if unsafe { libc::dup2(self.stdin.as_raw_fd(), libc::STDIN_FILENO) } < 0 {
            return Err(io::Error::other(format!(
                "closed stdin: {}",
                io::Error::last_os_error()
            )));
        }
        step(
            "chroot",
            security::checked(unsafe { libc::chroot(self.new_root.as_ptr()) }),
        )?;
        step(
            "working directory",
            security::checked(unsafe { libc::chdir(c"/work".as_ptr()) }),
        )?;
        // Only stdio may survive. The fixture's syscall code needs no inherited directory handle.
        if unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } != 0 {
            return Err(io::Error::other(format!(
                "close inherited descriptors: {}",
                io::Error::last_os_error()
            )));
        }
        step("resource limits", security::set_process_limits())?;
        step(
            "credentials and capabilities",
            security::drop_workload_identity(),
        )?;
        step("seccomp", self.filter.install())
    }

    pub(crate) fn cleanup(self, verify_write: bool) -> io::Result<()> {
        if std::fs::read(Path::new(BASE).join("lower/work/immutable"))? != b"verified fixture\n" {
            return Err(io::Error::other(
                "fixture modified its immutable lower root",
            ));
        }
        if verify_write
            && (std::fs::read(Path::new(BASE).join("upper/work/new-proof"))? != b"private write\n"
                || Path::new(BASE).join("lower/work/new-proof").exists())
        {
            return Err(io::Error::other(
                "fixture write did not stay in its private upper root",
            ));
        }
        std::fs::remove_dir_all(BASE)
    }
}

pub(crate) fn recover() -> io::Result<()> {
    let base = Path::new(BASE);
    for (relative, expected) in [
        ("lower/work/immutable", &b"verified fixture\n"[..]),
        ("outside-canary", &b"must stay outside workload root\n"[..]),
    ] {
        match std::fs::read(base.join(relative)) {
            Ok(bytes) if bytes == expected => {}
            Ok(_) => return Err(io::Error::other("fixture recovery found a modified canary")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    if base.try_exists()? {
        std::fs::remove_dir_all(base)?;
    }
    assert_absent()
}

pub(crate) fn assert_absent() -> io::Result<()> {
    if Path::new(BASE).try_exists()? {
        return Err(io::Error::other("unclaimed fixture sandbox"));
    }
    Ok(())
}

pub fn verify_after_exec() -> io::Result<()> {
    if unsafe { libc::geteuid() } != WORKLOAD_UID || unsafe { libc::getegid() } != WORKLOAD_GID {
        return Err(io::Error::other(
            "unexpected effective application credentials",
        ));
    }
    if unsafe { libc::getgroups(0, std::ptr::null_mut()) } != 0 {
        return Err(io::Error::other("application has supplementary groups"));
    }
    security::verify_empty_capabilities()?;
    let socket = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if socket >= 0 {
        unsafe { libc::close(socket) };
        return Err(io::Error::other(
            "no-network seccomp policy allowed a socket",
        ));
    }
    if io::Error::last_os_error().raw_os_error() != Some(libc::EPERM) {
        return Err(io::Error::other("unexpected seccomp test result"));
    }
    if std::fs::read("/work/immutable")? != b"verified fixture\n"
        || std::fs::read("/run/conjet/workload-probe/outside-canary").is_ok()
    {
        return Err(io::Error::other("unexpected root filesystem visibility"));
    }
    std::fs::write("/work/new-proof", b"private write\n")?;
    println!(
        "conjet-launchd application verified private root, credentials, and seccomp after exec"
    );
    Ok(())
}

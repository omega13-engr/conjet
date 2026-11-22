use std::io;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use crate::handshake::hex;
use crate::intent::{DIRECTORY, Intent};
use crate::kernel_fixture;
use crate::sandbox_fixture;
use crate::security::checked;

pub fn serve(allow_crash: bool) -> Result<(), Box<dyn std::error::Error>> {
    if std::process::id() != 1 {
        return Err("recovery fixture requires a disposable guest init".into());
    }
    let _proc = kernel_fixture::ProcMount::new()?;
    let intent = Intent::open(Path::new(DIRECTORY));
    for attempt in 0..2 {
        let mut service = Command::new("/init")
            .arg(if allow_crash {
                "--serve-recovery-child"
            } else {
                "--serve-fresh-child"
            })
            .process_group(0)
            .spawn()?;
        let pgid = service.id() as libc::pid_t;
        kill_owned_group(pgid)?;
        let status = service.wait()?;
        reap_remaining(pgid)?;
        if status.success() {
            if intent.read()?.is_some() {
                return Err("fresh supervisor stopped with an outstanding workload".into());
            }
            kernel_fixture::assert_cgroup_absent()?;
            sandbox_fixture::assert_absent()?;
            return Ok(());
        }
        if let Some(id) = intent.read()? {
            kernel_fixture::recover_cgroup(id)?;
            sandbox_fixture::recover()?;
            kernel_fixture::assert_cgroup_absent()?;
            intent.complete(id)?;
            println!("conjet-launchd reconciled workload {}", hex(&id));
        } else {
            kernel_fixture::assert_cgroup_absent()?;
            sandbox_fixture::assert_absent()?;
        }
        println!("conjet-launchd supervisor attempt {attempt} exited {status}");
    }
    Err("fresh supervisor restart budget exhausted".into())
}

fn kill_owned_group(pgid: libc::pid_t) -> io::Result<()> {
    loop {
        // Observe service exit while keeping the leader PID reserved. The
        // group cannot be rebound to a different leader before this signal.
        let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::uninit();
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pgid as libc::id_t,
                status.as_mut_ptr(),
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        if result == 0 {
            break;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
    match checked(unsafe { libc::kill(-pgid, libc::SIGKILL) }) {
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Ok(()),
        result => result,
    }
}

fn reap_remaining(pgid: libc::pid_t) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        // PID 1 adopts the service's descendants. The group is separate from
        // init and any other guest process, and admission is still closed.
        let reaped = unsafe { libc::waitpid(-pgid, std::ptr::null_mut(), libc::WNOHANG) };
        if reaped > 0 {
            continue;
        }
        if reaped < 0 {
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::ECHILD) => return Ok(()),
                Some(libc::EINTR) => continue,
                _ => return Err(error),
            }
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "owned process group did not exit",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

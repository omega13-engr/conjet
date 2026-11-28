//! PID 1 for owned workloads that opt in to child reaping.

use std::ffi::OsString;
use std::io;
use std::os::unix::process::CommandExt;
use std::process::Command;

use crate::security::{checked, prepare_exec_signals};

pub fn run(mut args: impl Iterator<Item = OsString>) -> io::Result<i32> {
    if unsafe { libc::getpid() } != 1 {
        return Err(io::Error::other(
            "workload init requires its own PID namespace",
        ));
    }
    let program = args
        .next()
        .ok_or_else(|| io::Error::other("missing workload init command"))?;
    let mut command = Command::new(program);
    command.args(args);
    let mut signals: libc::sigset_t = unsafe { std::mem::zeroed() };
    checked(unsafe { libc::sigfillset(&mut signals) })?;
    checked(unsafe { libc::sigprocmask(libc::SIG_SETMASK, &signals, std::ptr::null_mut()) })?;
    let child = unsafe { libc::fork() };
    if child == 0 {
        let error = match prepare_exec_signals() {
            Ok(()) => command.exec(),
            Err(error) => error,
        };
        eprintln!("workload init exec: {error}");
        unsafe { libc::_exit(127) };
    }
    if child < 0 {
        return Err(io::Error::last_os_error());
    }
    loop {
        let mut status = 0;
        loop {
            let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
            if pid == child {
                if libc::WIFEXITED(status) {
                    return Ok(libc::WEXITSTATUS(status));
                }
                if libc::WIFSIGNALED(status) {
                    return Ok(128 + libc::WTERMSIG(status));
                }
            }
            if pid == 0 {
                break;
            }
            if pid < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }
        let signal = unsafe { libc::sigwaitinfo(&signals, std::ptr::null_mut()) };
        if signal < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if signal != libc::SIGCHLD {
            let result = unsafe { libc::kill(child, signal) };
            if result < 0 && io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) {
                return Err(io::Error::last_os_error());
            }
        }
    }
}

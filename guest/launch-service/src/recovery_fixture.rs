use std::io;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use crate::cgroups::write_control;
use crate::handshake::hex;
use crate::intent::{DIRECTORY, Intent};
use crate::kernel_fixture;
use crate::sandbox_fixture;
use crate::security::checked;

const MEMD: &str = "/etc/conjet/conjet-memd";
const RECLAIMD: &str = "/etc/conjet/conjet-reclaimd";

fn core_cgroups() -> io::Result<kernel_fixture::CgroupMount> {
    std::fs::create_dir("/sys/fs")?;
    let root = Path::new("/sys/fs/cgroup");
    let mount = kernel_fixture::CgroupMount::new(root)?;
    let conjet = root.join("conjet.slice");
    write_control(root, "cgroup.subtree_control", "+memory")?;
    std::fs::create_dir(&conjet)?;
    write_control(&conjet, "cgroup.subtree_control", "+memory")?;
    for name in ["conjet-daemons.slice", "conjet-services.slice"] {
        std::fs::create_dir(conjet.join(name))?;
    }
    Ok(mount)
}

pub(crate) fn start_memory_service() -> io::Result<()> {
    const READY: &str = "/run/conjet/memory-vsock-ready";
    if !Path::new(MEMD).try_exists()? {
        return Ok(());
    }
    match std::fs::remove_file(READY) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
        _ => {}
    }
    let daemon = Path::new("/sys/fs/cgroup/conjet.slice/conjet-daemons.slice");
    write_control(daemon, "cgroup.procs", &std::process::id().to_string())?;
    // Both helpers inherit the service group. PID 1 drains that group on
    // clean shutdown and before restarting this supervisor.
    let mut service = Command::new(MEMD)
        .env("CONJET_RECLAIMD_PATH", RECLAIMD)
        .env("CONJET_NATIVE_WORKLOAD_CGROUPS", "1")
        .spawn()?;
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(status) = service.try_wait()? {
            return Err(io::Error::other(format!(
                "Core memory service exited {status}"
            )));
        }
        if std::fs::read_to_string(READY).is_ok_and(|port| port == "2376\n") {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Core memory service",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

pub fn serve(profile: crate::guest::Profile) -> Result<(), Box<dyn std::error::Error>> {
    if std::process::id() != 1 {
        return Err("recovery fixture requires a disposable guest init".into());
    }
    let _proc = kernel_fixture::ProcMount::new()?;
    let intent = Intent::open(Path::new(DIRECTORY));
    let oci = matches!(profile, crate::guest::Profile::Native)
        && Path::new(sandbox_fixture::OCI_MARKER).try_exists()?;
    let _core_cgroups = (oci && Path::new(MEMD).try_exists()?)
        .then(core_cgroups)
        .transpose()?;
    let mut pty = oci.then(crate::pty::Mount::open).transpose()?;
    let volume = if oci {
        crate::volume_disk::guest::Store::open()?
    } else {
        None
    };
    let disk_images = oci && crate::image_store::disk_store_enabled();
    if disk_images {
        if volume.is_none() || Path::new(crate::build_snapshot::MARKER).try_exists()? {
            return Err("disk image store requires the native volume filesystem".into());
        }
        crate::image_store::reset_generation()?;
    }
    for attempt in 0..2 {
        let mut service = Command::new("/init")
            .arg(match profile {
                crate::guest::Profile::Native => "--serve-native-child",
                crate::guest::Profile::Fixture { allow_crash: true } => "--serve-recovery-child",
                _ => "--serve-fresh-child",
            })
            .process_group(0)
            .spawn()?;
        let pgid = service.id() as libc::pid_t;
        kill_owned_group(pgid)?;
        let status = service.wait()?;
        reap_owned_children(-pgid)?;
        if status.success() {
            if intent.read()?.is_some() || (oci && !intent.scoped_inventory()?.is_empty()) {
                return Err("fresh supervisor stopped with an outstanding workload".into());
            }
            kernel_fixture::assert_cgroup_absent()?;
            sandbox_fixture::assert_absent()?;
            if disk_images {
                crate::image_store::reset_generation()?;
            }
            if let Some(volume) = volume {
                volume.close()?;
            }
            if let Some(pty) = &mut pty {
                pty.close()?;
            }
            return Ok(());
        }
        if oci {
            // An older single-OCI boot could have used the legacy intent
            // filename while allocating identity-scoped resource paths.
            let legacy = intent.read()?;
            for (id, record) in intent.scoped_inventory()? {
                recover_oci(id)?;
                record.complete(id)?;
            }
            if let Some(id) = legacy {
                recover_oci(id)?;
                intent.complete(id)?;
            }
            // Native helpers are in their own process groups. The parent's
            // death signal stopped the helpers and scoped cgroup recovery
            // stopped their descendants before PID 1 reaps adopted children.
            reap_owned_children(-1)?;
            crate::image_store::reset_generation()?;
        } else if let Some(id) = intent.read()? {
            kernel_fixture::recover_cgroup(id, false)?;
            sandbox_fixture::recover(id, false)?;
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

fn recover_oci(id: [u8; 16]) -> io::Result<()> {
    kernel_fixture::recover_cgroup(id, true)?;
    sandbox_fixture::recover(id, true)?;
    kernel_fixture::assert_owned_cgroup_absent(id)?;
    sandbox_fixture::assert_owned_absent(id)?;
    println!("conjet-launchd reconciled OCI workload {}", hex(&id));
    Ok(())
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

pub(crate) fn reap_owned_children(selector: libc::pid_t) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        // PID 1 selects its service group, or all adopted children after
        // every owned cgroup was drained. The live OCI subreaper selects
        // only the failing helper's group.
        let reaped = unsafe { libc::waitpid(selector, std::ptr::null_mut(), libc::WNOHANG) };
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

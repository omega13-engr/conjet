#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("The native launch guest service requires Linux with AF_VSOCK.");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::path::Path;
    let mut args = std::env::args_os().skip(1);
    match args.next() {
        None => {
            conjet_launch_service::guest::serve(Path::new("/etc/conjet/launch.key"))?;
            report_resources()?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--check-fresh-kernel" && args.next().is_none() => {
            conjet_launch_service::kernel_fixture::check(false)?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--check-fresh-sandbox" && args.next().is_none() => {
            conjet_launch_service::kernel_fixture::check(true)?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--verify-workload-fixture" && args.next().is_none() => {
            conjet_launch_service::sandbox_fixture::verify_after_exec()?;
            return Ok(());
        }
        _ => return Err("unexpected launchd argument".into()),
    }
    // The isolated transport fixture can run as the guest init. A service
    // invoked by a regular guest supervisor only returns to that supervisor.
    if std::process::id() == 1 {
        unsafe { libc::sync() };
        // This process is PID 1 inside the task-owned Linux fixture VM.
        if unsafe { libc::reboot(libc::RB_POWER_OFF) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn report_resources() -> std::io::Result<()> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    // The kernel initializes the complete structure on success.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let usage = unsafe { usage.assume_init() };
    let microseconds =
        |time: libc::timeval| i128::from(time.tv_sec) * 1_000_000 + i128::from(time.tv_usec);
    println!(
        "conjet-launchd resources {}",
        serde_json::json!({
            "user_cpu_us": microseconds(usage.ru_utime),
            "system_cpu_us": microseconds(usage.ru_stime),
            "peak_rss_kib": usage.ru_maxrss,
        })
    );
    Ok(())
}

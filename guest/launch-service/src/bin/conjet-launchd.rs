#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("The native launch guest service requires Linux with AF_VSOCK.");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use conjet_launch_service::guest::Profile;
    use std::path::Path;
    let mut args = std::env::args_os().skip(1);
    match args.next() {
        None => {
            conjet_launch_service::guest::serve(
                Path::new("/etc/conjet/launch.key"),
                Profile::Transport,
            )?;
            report_resources()?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--serve-fresh-fixture" && args.next().is_none() => {
            conjet_launch_service::recovery_fixture::serve(Profile::Fixture {
                allow_crash: false,
            })?;
            report_resources()?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--serve-native" && args.next().is_none() => {
            conjet_launch_service::recovery_fixture::serve(Profile::Native)?;
            report_resources()?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--serve-recovery-fixture" && args.next().is_none() => {
            conjet_launch_service::recovery_fixture::serve(Profile::Fixture { allow_crash: true })?;
            report_resources()?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument)
            if matches!(
                argument.to_str(),
                Some("--serve-fresh-child" | "--serve-recovery-child" | "--serve-native-child")
            ) && args.next().is_none() =>
        {
            conjet_launch_service::guest::serve(
                Path::new("/etc/conjet/launch.key"),
                if argument == "--serve-native-child" {
                    Profile::Native
                } else {
                    Profile::Fixture {
                        allow_crash: argument == "--serve-recovery-child",
                    }
                },
            )?;
            report_resources()?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--run-fresh-fixture" => {
            return conjet_launch_service::kernel_fixture::run_helper(args);
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--run-oci-exec" => {
            return conjet_launch_service::exec_fixture::run_helper(args);
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--verify-core-pressure-fixture" && args.next().is_none() => {
            return Ok(conjet_launch_service::pressure_fixture::run()?);
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
        Some(argument) if argument == "--check-fresh-bridge" && args.next().is_none() => {
            conjet_launch_service::bridge_fixture::check()?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--check-shared-bridge" && args.next().is_none() => {
            conjet_launch_service::bridge_fixture::check_shared()?;
            unsafe { libc::reboot(libc::RB_POWER_OFF) };
            return Err(std::io::Error::last_os_error().into());
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--check-bridge-availability" && args.next().is_none() => {
            conjet_launch_service::bridge_fixture::check_available()?;
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument)
            if argument == "--check-bridge-peer"
                || argument == "--check-bridge-scope"
                || argument == "--check-shared-bridge-peer" =>
        {
            let parent = args
                .next()
                .and_then(|value| value.into_string().ok())
                .ok_or("bridge fixture owner required")?
                .parse()?;
            if args.next().is_some() {
                return Err("unexpected bridge fixture arguments".into());
            }
            if argument == "--check-bridge-peer" {
                conjet_launch_service::bridge_fixture::check_peer(parent)?;
            } else if argument == "--check-shared-bridge-peer" {
                conjet_launch_service::bridge_fixture::check_shared_peer(parent)?;
            } else {
                conjet_launch_service::bridge_fixture::check_scope(parent)?;
            }
        }
        #[cfg(target_arch = "aarch64")]
        Some(argument) if argument == "--verify-workload-fixture" => {
            let mode = match args.next() {
                None => "once",
                Some(value) if value == "--hold" && args.next().is_none() => "hold",
                Some(value) if value == "--fail" && args.next().is_none() => "fail",
                Some(value) if value == "--bridge" && args.next().is_none() => "bridge",
                Some(value) if value == "--bridge-hold" && args.next().is_none() => "bridge-hold",
                Some(value) if value == "--flood" && args.next().is_none() => "flood",
                Some(value) if value == "--memory-canary" && args.next().is_none() => {
                    "memory-canary"
                }
                Some(value) if value == "--exhaust-memory" && args.next().is_none() => {
                    "exhaust-memory"
                }
                _ => return Err("invalid workload fixture option".into()),
            };
            conjet_launch_service::sandbox_fixture::verify_after_exec()?;
            if matches!(mode, "bridge" | "bridge-hold") {
                conjet_launch_service::bridge_fixture::verify_workload()?;
            }
            match mode {
                "hold" | "bridge-hold" => std::thread::sleep(std::time::Duration::from_secs(10)),
                "fail" => std::process::exit(23),
                "flood" => {
                    use std::io::Write;
                    let chunk = [b'x'; 8_192];
                    for _ in 0..12 {
                        std::io::stdout().lock().write_all(&chunk)?;
                        std::io::stderr().lock().write_all(&chunk)?;
                    }
                }
                "exhaust-memory" => {
                    let memory = vec![0x5au8; 48 * 1024 * 1024];
                    std::hint::black_box(&memory);
                    return Err("fixture survived unexpected memory pressure".into());
                }
                "memory-canary" => {
                    let mut memory = vec![0x5au8; 8 * 1024 * 1024];
                    std::hint::black_box(&mut memory);
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    if memory.iter().any(|&byte| byte != 0x5a) {
                        return Err("workload memory canary changed".into());
                    }
                    println!("verified live memory canary");
                }
                _ => {}
            }
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

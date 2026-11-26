use std::io;
use std::path::Path;
use std::time::{Duration, Instant};

use crate::cgroups::write_control;
use crate::core_admission::PRESSURE_MARKER;

pub fn run() -> io::Result<()> {
    if !Path::new(PRESSURE_MARKER).try_exists()? {
        return Err(io::Error::other(
            "Core pressure fixture requires a dedicated guest boot",
        ));
    }
    let service = Path::new("/sys/fs/cgroup/conjet.slice/conjet-services.slice");
    write_control(service, "memory.max", "100663296")?;
    write_control(service, "memory.high", "16777216")?;
    write_control(service, "cgroup.procs", &std::process::id().to_string())?;
    let end = Instant::now() + Duration::from_secs(30);
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    let page_size = usize::try_from(page_size)
        .ok()
        .filter(|size| size.is_power_of_two() && *size <= 65536)
        .ok_or_else(|| io::Error::other("invalid guest page size"))?;
    while Instant::now() < end {
        let mut memory = vec![0u8; 32 * 1024 * 1024];
        for byte in memory.iter_mut().step_by(page_size) {
            // Touch each page so the kernel charges this service cgroup.
            unsafe { std::ptr::write_volatile(byte, 0x6d) };
        }
        std::thread::sleep(Duration::from_millis(75));
    }
    Ok(())
}

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::handshake::hex;
use crate::spec::ResourceLimits;
use crate::wire::CgroupUsage;

const CPU_PERIOD_US: u64 = 100_000;
pub(crate) const CGROUP2_SUPER_MAGIC: i128 = 0x6367_7270;

pub struct WorkloadCgroup {
    directory: File,
    path: PathBuf,
}

pub(crate) fn usage(directory: &Path) -> io::Result<CgroupUsage> {
    fn read(path: &Path) -> io::Result<String> {
        let mut value = String::new();
        File::open(path)?.take(16_385).read_to_string(&mut value)?;
        if value.len() > 16_384 {
            return Err(io::Error::other(
                "kernel statistics exceeded their read limit",
            ));
        }
        Ok(value)
    }
    fn number(value: &str) -> io::Result<u64> {
        value.trim().parse().map_err(io::Error::other)
    }
    fn field<'a>(text: &'a str, key: &str) -> io::Result<&'a str> {
        text.lines()
            .find_map(|line| {
                line.split_once(' ')
                    .filter(|(name, _)| *name == key)
                    .map(|(_, value)| value)
            })
            .ok_or_else(|| io::Error::other(format!("missing kernel statistic {key}")))
    }

    let cpu = read(&directory.join("cpu.stat"))?;
    let memory = read(&directory.join("memory.stat"))?;
    let memory_limit = read(&directory.join("memory.max"))?;
    let memory_limit = if memory_limit.trim() == "max" {
        let total = read(Path::new("/proc/meminfo"))?;
        let kb = field(&total, "MemTotal:")?
            .strip_suffix(" kB")
            .ok_or_else(|| io::Error::other("invalid guest memory total"))?;
        number(kb)?.saturating_mul(1024)
    } else {
        number(&memory_limit)?
    };
    let stat = read(Path::new("/proc/stat"))?;
    let cpu_ticks = field(&stat, "cpu")?
        .split_whitespace()
        .take(8)
        .try_fold(0u64, |sum, tick| {
            Ok::<_, io::Error>(sum.saturating_add(number(tick)?))
        })?;
    let tick_rate = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let cpus = unsafe { libc::sysconf(libc::_SC_NPROCESSORS_ONLN) };
    if tick_rate <= 0 || cpus <= 0 {
        return Err(io::Error::other("guest CPU statistics are unavailable"));
    }
    Ok(CgroupUsage {
        cpu_ns: number(field(&cpu, "usage_usec")?)?.saturating_mul(1000),
        system_ns: ((u128::from(cpu_ticks) * 1_000_000_000) / tick_rate as u128)
            .try_into()
            .map_err(io::Error::other)?,
        cpus: cpus as u64,
        memory_bytes: number(&read(&directory.join("memory.current"))?)?,
        memory_limit,
        inactive_file: number(field(&memory, "inactive_file")?)?,
        tasks: number(&read(&directory.join("pids.current"))?)?,
    })
}

impl WorkloadCgroup {
    pub fn create(
        parent: &Path,
        workload_id: [u8; 16],
        limits: ResourceLimits,
        disable_swap: bool,
    ) -> io::Result<Self> {
        let parent_descriptor = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(parent)?;
        let mut filesystem = std::mem::MaybeUninit::<libc::statfs>::uninit();
        // The kernel initializes statfs on success. Fail before mkdir on another filesystem.
        if unsafe { libc::fstatfs(parent_descriptor.as_raw_fd(), filesystem.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if i128::from(unsafe { filesystem.assume_init() }.f_type) != CGROUP2_SUPER_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "cgroup v2 required",
            ));
        }
        let path = parent.join(hex(&workload_id));
        std::fs::create_dir(&path)?;
        let result = (|| {
            let directory = File::open(&path)?;
            let maximum = |value: u64| {
                if value == 0 {
                    "max".to_owned()
                } else {
                    value.to_string()
                }
            };
            write_control(&path, "memory.max", &maximum(limits.memory_bytes))?;
            if disable_swap {
                write_control(&path, "memory.swap.max", "0")?;
            }
            write_control(&path, "pids.max", &maximum(u64::from(limits.pids)))?;
            let quota = u64::from(limits.cpu_millicores) * CPU_PERIOD_US / 1_000;
            write_control(
                &path,
                "cpu.max",
                &format!("{} {CPU_PERIOD_US}", maximum(quota)),
            )?;
            Ok(directory)
        })();
        match result {
            Ok(directory) => Ok(Self { directory, path }),
            Err(setup) => match std::fs::remove_dir(&path) {
                Ok(()) => Err(setup),
                Err(cleanup) => Err(io::Error::other(format!(
                    "cgroup setup failed: {setup}; could not remove empty cgroup: {cleanup}"
                ))),
            },
        }
    }

    pub fn directory(&self) -> &File {
        &self.directory
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub fn kill(&self) -> io::Result<()> {
        write_control(&self.path, "cgroup.kill", "1")
    }

    pub(crate) fn memory_events(&self) -> io::Result<String> {
        std::fs::read_to_string(self.path.join("memory.events"))
    }

    pub(crate) fn oom_killed(&self) -> io::Result<bool> {
        let events = self.memory_events()?;
        events
            .lines()
            .find_map(|line| line.strip_prefix("oom_kill "))
            .and_then(|count| count.parse::<u64>().ok())
            .map(|count| count != 0)
            .ok_or_else(|| io::Error::other("invalid cgroup OOM counter"))
    }

    pub fn populated(&self) -> io::Result<bool> {
        populated(&self.path)
    }

    pub fn remove_empty(&self) -> io::Result<()> {
        if self.populated()? {
            return Err(io::Error::other(
                "refusing to remove a populated workload cgroup",
            ));
        }
        // The kernel rechecks membership atomically with rmdir.
        std::fs::remove_dir(&self.path)
    }

    pub(crate) fn drain(&self) -> io::Result<()> {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if self.populated()? {
                self.kill()?;
            } else {
                match std::fs::remove_dir(&self.path) {
                    Ok(()) => return Ok(()),
                    Err(error) if error.raw_os_error() == Some(libc::EBUSY) => {}
                    Err(error) => return Err(error),
                }
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "owned cgroup did not drain",
                ));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

fn populated(path: &Path) -> io::Result<bool> {
    let events = std::fs::read_to_string(path.join("cgroup.events"))?;
    match events
        .lines()
        .find_map(|line| line.strip_prefix("populated "))
    {
        Some("0") => Ok(false),
        Some("1") => Ok(true),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid cgroup population state",
        )),
    }
}

pub(crate) fn freeze(path: &Path, frozen: bool, expires: Instant) -> io::Result<()> {
    let previous = std::fs::read_to_string(path.join("cgroup.freeze"))?;
    write_control(path, "cgroup.freeze", if frozen { "1" } else { "0" })?;
    let expected = if frozen { "frozen 1" } else { "frozen 0" };
    let confirm = || -> io::Result<()> {
        loop {
            if std::fs::read_to_string(path.join("cgroup.events"))?
                .lines()
                .any(|line| line == expected)
            {
                return Ok(());
            }
            if Instant::now() >= expires {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "cgroup freeze deadline elapsed",
                ));
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    };
    if let Err(error) = confirm() {
        write_control(path, "cgroup.freeze", previous.trim())?;
        return Err(error);
    }
    Ok(())
}

pub(crate) fn update_limits(
    path: &Path,
    limits: ResourceLimits,
    disable_swap: bool,
) -> io::Result<()> {
    let maximum = |n: u64| if n == 0 { "max".into() } else { n.to_string() };
    let quota = u64::from(limits.cpu_millicores) * CPU_PERIOD_US / 1_000;
    let next = [
        ("cpu.max", format!("{} {CPU_PERIOD_US}", maximum(quota))),
        ("pids.max", maximum(u64::from(limits.pids))),
        (
            "memory.swap.max",
            (if disable_swap { "0" } else { "max" }).to_owned(),
        ),
        ("memory.max", maximum(limits.memory_bytes)),
    ];
    let previous = next
        .iter()
        .map(|(name, _)| std::fs::read_to_string(path.join(name)))
        .collect::<io::Result<Vec<_>>>()?;
    for (index, ((name, value), old)) in next.iter().zip(&previous).enumerate() {
        if value == old.trim() {
            continue;
        }
        // The kernel can otherwise block the controller while reclaiming
        // pages from a workload whose limit was lowered.
        let wrote = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(path.join(name))
            .and_then(|mut file| file.write_all(value.as_bytes()));
        if let Err(error) = wrote {
            for ((old_name, applied), original) in next[..index].iter().zip(&previous).rev() {
                if applied != original.trim() {
                    write_control(path, old_name, original.trim())?;
                }
            }
            return Err(error);
        }
    }
    Ok(())
}

pub(crate) fn observation(path: &Path) -> io::Result<(u64, bool)> {
    let current = std::fs::read_to_string(path.join("memory.current"))?
        .trim()
        .parse()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid cgroup memory charge"))?;
    Ok((current, populated(path)?))
}

pub(crate) fn write_control(path: &Path, file: &str, value: &str) -> io::Result<()> {
    OpenOptions::new()
        .write(true)
        .open(path.join(file))?
        .write_all(value.as_bytes())
}

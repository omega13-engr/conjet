use std::os::unix::fs::MetadataExt;
use std::time::Duration;

fn main() -> std::io::Result<()> {
    let owner = std::fs::metadata("/output")?;
    let mounts = std::fs::read_to_string("/proc/self/mountinfo")?;
    let status = std::fs::read_to_string("/proc/self/status")?;
    let mount = |path: &str, kind: Option<&str>| {
        mounts.lines().any(|line| {
            line.split_ascii_whitespace().nth(4) == Some(path)
                && kind.is_none_or(|kind| {
                    line.split_once(" - ")
                        .and_then(|(_, tail)| tail.split_ascii_whitespace().next())
                        == Some(kind)
                })
        })
    };
    if (owner.uid(), owner.gid()) != (65_532, 65_532)
        || !status.contains("Uid:\t65532\t65532\t65532\t65532")
        || !status.contains("Gid:\t65532\t65532\t65532\t65532")
        || !status.contains("CapEff:\t0000000000000000")
    {
        return Err(std::io::Error::other(
            "direct BuildKit RUN identity differs",
        ));
    }
    for (path, kind) in [
        ("/proc", Some("proc")),
        ("/dev/pts", Some("devpts")),
        ("/dev/mqueue", Some("mqueue")),
        ("/sys", Some("sysfs")),
        ("/sys/fs/cgroup", Some("cgroup2")),
        ("/etc/hosts", None),
    ] {
        if !mount(path, kind) {
            return Err(std::io::Error::other(format!(
                "missing direct BuildKit RUN mount {path}"
            )));
        }
    }
    std::fs::write("/output/proof", b"native build snapshot proof\n")?;
    println!("native-direct-stdout");
    eprintln!("native-direct-stderr");
    if std::env::args().nth(1).as_deref() == Some("hold") {
        std::thread::sleep(Duration::from_secs(24));
    }
    Ok(())
}

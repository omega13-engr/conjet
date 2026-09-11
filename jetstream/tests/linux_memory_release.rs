#![cfg(all(target_os = "macos", target_arch = "aarch64"))]

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use jetstream::devices::virtio::VirtioDeviceKind;
use jetstream::hvf::boot::{default_virtio_plan, HvfBootOptions, HvfBootRunner};
use jetstream::vmm::boot::BootPlan;
use jetstream::vmm::config::{BootSource, JetstreamConfig};

fn request(path: &Path, operation: &str) -> std::io::Result<()> {
    let mut stream = UnixStream::connect(path)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    write!(
        stream,
        "GET /{operation} HTTP/1.1\r\nHost: guest\r\nConnection: close\r\n\r\n"
    )?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if !line.starts_with("HTTP/1.1 200 ") {
        return Err(std::io::Error::other("guest response was not successful"));
    }
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            return Err(std::io::Error::other("truncated guest response"));
        }
        if line == "\r\n" {
            break;
        }
    }
    let mut body = [0; 3];
    reader.read_exact(&mut body)?;
    assert_eq!(&body, b"OK\n");
    Ok(())
}

fn resident_bytes() -> u64 {
    let mut info = std::mem::MaybeUninit::<libc::rusage_info_v2>::zeroed();
    let result = unsafe {
        libc::proc_pid_rusage(
            libc::getpid(),
            libc::RUSAGE_INFO_V2,
            info.as_mut_ptr().cast::<libc::rusage_info_t>(),
        )
    };
    assert_eq!(result, 0);
    unsafe { info.assume_init() }.ri_resident_size
}

fn snapshot(path: &Path) -> serde_json::Value {
    let mut stream = UnixStream::connect(path).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    stream.write_all(b"{\"command\":\"metrics\"}\n").unwrap();
    let mut response = String::new();
    BufReader::new(stream).read_line(&mut response).unwrap();
    serde_json::from_str(&response).unwrap()
}

#[test]
#[ignore = "requires entitled executable, CONJET_TEST_KERNEL and CONJET_TEST_INITRD; run serially"]
fn linux_reports_freed_pages_and_reuses_memory_without_corruption() {
    let root = tempfile::tempdir().unwrap();
    let root_disk = root.path().join("root.raw");
    std::fs::File::create(&root_disk)
        .unwrap()
        .set_len(1024 * 1024)
        .unwrap();
    let config = JetstreamConfig {
        memory_mib: 512,
        vcpu_count: 2,
        boot_source: BootSource {
            name: "memory-release-correctness".into(),
            kernel_path: std::env::var_os("CONJET_TEST_KERNEL")
                .expect("kernel path")
                .into(),
            initrd_path: Some(
                std::env::var_os("CONJET_TEST_INITRD")
                    .expect("initrd path")
                    .into(),
            ),
            root_disk_path: root_disk,
            data_disk_path: None,
            swap_disk_path: None,
            serial_log_path: root.path().join("serial.log"),
            docker_socket_path: root.path().join("docker.sock"),
            cmdline: "console=ttyAMA0 rdinit=/init panic=-1".into(),
        },
    };
    let plan = BootPlan::new(&config).unwrap();
    // No networking backend or production socket is needed for this fixture.
    let devices = default_virtio_plan(&config)
        .into_iter()
        .filter(|device| device.kind != VirtioDeviceKind::Net)
        .collect();
    let socket = root.path().join("memory.sock");
    let control_socket = root.path().join("control.sock");
    let observer_control = control_socket.clone();
    let observer = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(30);
        while request(&socket, "ready").is_err() {
            assert!(
                Instant::now() < deadline,
                "guest memory fixture did not become ready"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        // Let boot-time reports finish before attributing a drop to this free.
        std::thread::sleep(Duration::from_secs(1));
        request(&socket, "allocate").unwrap();
        let before_control = snapshot(&observer_control);
        let before = resident_bytes();
        request(&socket, "free").unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let after = loop {
            let current = resident_bytes();
            if before.saturating_sub(current) >= 32 * 1024 * 1024 || Instant::now() >= deadline {
                break current;
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        let after_control = snapshot(&observer_control);
        if let Some(path) = std::env::var_os("CONJET_TEST_REPORT") {
            let evidence = serde_json::json!({"before": before_control, "after": after_control});
            std::fs::write(
                Path::new(&path).with_extension("snapshots.json"),
                serde_json::to_vec_pretty(&evidence).unwrap(),
            )
            .unwrap();
        }
        request(&socket, "verify").unwrap();
        request(&socket, "exit").unwrap();
        (before, after)
    });
    let report = HvfBootRunner::new(
        config,
        plan,
        devices,
        HvfBootOptions {
            max_exits: u64::MAX,
            max_runtime_ms: 40_000,
            host_tick_ms: 25,
            memory_control_socket: Some(control_socket),
            hold_after_ready_forever: true,
            ..HvfBootOptions::default()
        },
    )
    .run();
    if let Some(path) = std::env::var_os("CONJET_TEST_REPORT") {
        std::fs::write(path, serde_json::to_vec_pretty(&report).unwrap()).unwrap();
    }
    assert!(report.ok, "{}\n{}", report.message, report.console_output);
    let (before, after) = observer
        .join()
        .expect("guest allocation/free/reuse checks failed");
    assert!(report.console_output.contains("CONJET_MEMORY_REUSE_OK"));
    eprintln!("Linux page reporting RSS check: before={before}, after={after}");
    assert!(before.saturating_sub(after) >= 32 * 1024 * 1024);
}

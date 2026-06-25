use std::io::{Seek, Write};

use jetstream::arch::aarch64;
use jetstream::vmm::boot::{validate_arm64_linux_image, BootPlan};
use jetstream::vmm::config::{BootSource, JetstreamConfig};
use tempfile::NamedTempFile;

#[test]
fn validates_arm64_linux_image_magic() {
    let mut file = arm64_image_file();
    assert!(validate_arm64_linux_image(file.path()).is_ok());
    file.as_file_mut()
        .seek(std::io::SeekFrom::Start(
            aarch64::ARM64_IMAGE_MAGIC_OFFSET as u64,
        ))
        .unwrap();
    file.write_all(&0u32.to_le_bytes()).unwrap();
    assert!(validate_arm64_linux_image(file.path()).is_err());
}

#[test]
fn builds_direct_kernel_boot_plan() {
    let kernel = arm64_image_file();
    let config = JetstreamConfig {
        memory_mib: 512,
        vcpu_count: 2,
        boot_source: BootSource {
            name: "test".to_string(),
            kernel_path: kernel.path().to_path_buf(),
            initrd_path: None,
            root_disk_path: "/tmp/root.img".into(),
            data_disk_path: None,
            swap_disk_path: None,
            serial_log_path: "/tmp/serial.log".into(),
            docker_socket_path: "/tmp/docker.sock".into(),
            cmdline: aarch64::DEFAULT_CMDLINE.to_string(),
        },
    };

    let plan = BootPlan::new(&config).unwrap();
    assert_eq!(plan.ram_base, aarch64::RAM_BASE);
    assert_eq!(
        plan.kernel_load_address,
        aarch64::RAM_BASE + aarch64::KERNEL_LOAD_OFFSET
    );
    assert_eq!(plan.vcpu_count, 2);
    assert!(plan.contains(plan.fdt_load_address, plan.fdt_maximum_size_bytes));
}

#[test]
fn rejects_profiles_outside_current_conjet_limits() {
    let kernel = arm64_image_file();
    let mut config = test_config(kernel.path().to_path_buf(), 8193, 4);
    let error = BootPlan::new(&config).unwrap_err().to_string();
    assert!(error.contains("must not exceed 8192 MiB"));

    config.memory_mib = 8192;
    config.vcpu_count = 5;
    let error = BootPlan::new(&config).unwrap_err().to_string();
    assert!(error.contains("must not exceed 4"));
}

fn test_config(
    kernel_path: std::path::PathBuf,
    memory_mib: u64,
    vcpu_count: u8,
) -> JetstreamConfig {
    JetstreamConfig {
        memory_mib,
        vcpu_count,
        boot_source: BootSource {
            name: "test".to_string(),
            kernel_path,
            initrd_path: None,
            root_disk_path: "/tmp/root.img".into(),
            data_disk_path: None,
            swap_disk_path: None,
            serial_log_path: "/tmp/serial.log".into(),
            docker_socket_path: "/tmp/docker.sock".into(),
            cmdline: aarch64::DEFAULT_CMDLINE.to_string(),
        },
    }
}

fn arm64_image_file() -> NamedTempFile {
    let mut file = NamedTempFile::new().unwrap();
    file.as_file_mut()
        .set_len((aarch64::ARM64_IMAGE_MAGIC_OFFSET + 4) as u64)
        .unwrap();
    file.as_file_mut()
        .seek(std::io::SeekFrom::Start(
            aarch64::ARM64_IMAGE_MAGIC_OFFSET as u64,
        ))
        .unwrap();
    file.write_all(&aarch64::ARM64_IMAGE_MAGIC.to_le_bytes())
        .unwrap();
    file
}

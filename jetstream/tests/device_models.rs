use jetstream::arch::aarch64;
use jetstream::devices::bus::MmioBus;
use jetstream::devices::pl011::Pl011Uart;
use jetstream::devices::psci::{
    ProcessorState, PsciAction, PsciController, PsciFunction, PsciReturn,
};
use jetstream::devices::virtio::{
    VirtioDeviceKind, VirtioMmioDevice, VirtioMmioDevicePlan, BALLOON_FEATURE_FREE_PAGE_HINT,
    BALLOON_FEATURE_PAGE_POISON, BALLOON_FEATURE_PAGE_REPORTING, MAGIC_VALUE, STATUS_FAILED,
    STATUS_FEATURES_OK,
};
use jetstream::hvf::gic::{GicLayout, GicMmio};
use jetstream::vmm::boot::BootPlan;
use jetstream::vmm::config::{BootSource, JetstreamConfig};
use jetstream::vmm::fdt::build_linux_boot_fdt;
use tempfile::NamedTempFile;

use std::io::{Seek, Write};

#[test]
fn pl011_and_mmio_bus_route_console_bytes() {
    let mut bus = MmioBus::new();
    bus.register(Pl011Uart::default()).unwrap();

    bus.write(aarch64::UART_BASE, u64::from(b'O'), 4).unwrap();
    bus.write(aarch64::UART_BASE, u64::from(b'K'), 4).unwrap();
    let flags = bus
        .read(aarch64::UART_BASE + Pl011Uart::FLAG_REGISTER, 4)
        .unwrap();
    assert_eq!(flags & u64::from(Pl011Uart::TRANSMIT_FIFO_FULL), 0);
    assert_ne!(flags & u64::from(Pl011Uart::TRANSMIT_FIFO_EMPTY), 0);
}

#[test]
fn psci_handles_version_features_and_cpu_on() {
    let mut psci = PsciController::new(2).unwrap();
    assert_eq!(
        psci.handle(PsciFunction::Version as u32, 0, 0, 0)
            .return_value,
        PsciController::VERSION
    );
    assert_eq!(
        psci.handle(
            PsciFunction::Features as u32,
            PsciFunction::CpuOn64 as u64,
            0,
            0
        )
        .return_value,
        PsciReturn::Success.register_value()
    );

    let response = psci.handle(PsciFunction::CpuOn64 as u32, 1, 0x4020_0000, 0x55);
    assert_eq!(
        response.action,
        PsciAction::CpuOn {
            target_cpu: 1,
            entry_point: 0x4020_0000,
            context_id: 0x55
        }
    );
    assert_eq!(psci.state(1), Some(ProcessorState::OnPending));
}

#[test]
fn virtio_mmio_exposes_modern_transport_registers() {
    let plan = VirtioMmioDevicePlan::new(VirtioDeviceKind::Block, 0);
    let mut dev = VirtioMmioDevice::new(plan, vec![0xaa, 0xbb, 0xcc, 0xdd]);

    assert_eq!(
        jetstream::devices::bus::MmioDevice::read(&mut dev, 0x000, 4).unwrap(),
        u64::from(MAGIC_VALUE)
    );
    assert_eq!(
        jetstream::devices::bus::MmioDevice::read(&mut dev, 0x008, 4).unwrap(),
        2
    );
    jetstream::devices::bus::MmioDevice::write(&mut dev, 0x038, 128, 4).unwrap();
    jetstream::devices::bus::MmioDevice::write(&mut dev, 0x044, 1, 4).unwrap();
    jetstream::devices::bus::MmioDevice::write(&mut dev, 0x080, 0x1000, 4).unwrap();
    assert_eq!(dev.queue_state(0).unwrap().size, 128);
    assert!(dev.queue_state(0).unwrap().ready);
    assert_eq!(dev.queue_state(0).unwrap().descriptor_address, 0x1000);
    assert_eq!(
        jetstream::devices::bus::MmioDevice::read(&mut dev, 0x100, 4).unwrap(),
        0xddcc_bbaa
    );
}

#[test]
fn virtio_mmio_rejects_unsupported_features_when_features_ok_is_set() {
    let plan = VirtioMmioDevicePlan::new(VirtioDeviceKind::Block, 0);
    let mut dev = VirtioMmioDevice::new(plan, Vec::new());

    jetstream::devices::bus::MmioDevice::write(&mut dev, 0x020, 1 << 31, 4).unwrap();
    jetstream::devices::bus::MmioDevice::write(&mut dev, 0x070, u64::from(STATUS_FEATURES_OK), 4)
        .unwrap();

    assert_eq!(dev.device_status & STATUS_FEATURES_OK, 0);
    assert_ne!(dev.device_status & STATUS_FAILED, 0);
}

#[test]
fn virtio_balloon_offers_only_page_reporting_for_destructive_reclaim() {
    let plan = VirtioMmioDevicePlan::new(VirtioDeviceKind::Balloon, 0);

    assert_eq!(plan.features & BALLOON_FEATURE_FREE_PAGE_HINT, 0);
    assert_eq!(plan.features & BALLOON_FEATURE_PAGE_POISON, 0);
    assert_ne!(plan.features & BALLOON_FEATURE_PAGE_REPORTING, 0);
}

#[test]
fn gic_mmio_models_linux_discovery_and_waker_registers() {
    let layout = GicLayout::new(4);
    let mut gic = GicMmio::new(layout);
    assert!(gic.contains(aarch64::GIC_BASE));
    assert!(gic.contains(layout.redistributor_base + layout.redistributor_stride + 0x14));

    assert_eq!(gic.read(aarch64::GIC_BASE + 0x8, 4).unwrap(), 0x0102_043b);
    let first_typer = gic.read(layout.redistributor_base + 0x8, 8).unwrap();
    let last_typer = gic
        .read(
            layout.redistributor_base + (layout.redistributor_stride * 3) + 0x8,
            8,
        )
        .unwrap();
    assert_eq!(first_typer & (1 << 4), 0);
    assert_ne!(last_typer & (1 << 4), 0);

    let waker = layout.redistributor_base + layout.redistributor_stride + 0x14;
    gic.write(waker, 0b110, 4).unwrap();
    assert_eq!(gic.read(waker, 4).unwrap() & 0b100, 0);
}

#[test]
fn fdt_advertises_conjet_direct_kernel_machine() {
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
    let virtio = vec![VirtioMmioDevicePlan::new(VirtioDeviceKind::Block, 0)];
    let fdt = build_linux_boot_fdt(&plan, &virtio).unwrap();
    assert_eq!(
        u32::from_be_bytes(fdt[0..4].try_into().unwrap()),
        0xd00d_feed
    );
    assert!(contains_bytes(&fdt, b"virtio_mmio@a000000"));
    assert!(contains_bytes(&fdt, b"virtio,mmio"));
    assert!(contains_bytes(&fdt, b"arm,psci-0.2"));
    assert!(contains_bytes(&fdt, b"cpu@0"));
    assert!(contains_bytes(&fdt, b"cpu@1"));
    assert!(contains_bytes(&fdt, &[0, 0, 0, 2, 0, 0, 0, 0]));
    assert!(contains_bytes(&fdt, &[0, 0, 0, 0, 0, 0, 0, 1]));
    assert!(contains_bytes(&fdt, b"console=ttyAMA0"));
    assert!(contains_bytes(&fdt, b"uartclk"));
    assert!(contains_bytes(&fdt, b"apb-pclk"));
    assert!(contains_bytes(&fdt, b"arm,primecell-periphid"));
    assert!(contains_bytes(&fdt, b"clock-names"));
    assert!(contains_bytes(&fdt, b"current-speed"));
    assert!(contains_bytes(&fdt, &[0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 4]));
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

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

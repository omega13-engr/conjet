pub const RAM_BASE: u64 = 0x4000_0000;
pub const GIC_BASE: u64 = 0x0800_0000;
pub const GIC_DISTRIBUTOR_SIZE: u64 = 0x0001_0000;
pub const GIC_REDISTRIBUTOR_STRIDE: u64 = 0x0002_0000;
pub const UART_BASE: u64 = 0x0900_0000;
pub const UART_SIZE: u64 = 0x0001_0000;
pub const VIRTIO_BASE: u64 = 0x0a00_0000;
pub const VIRTIO_MMIO_STRIDE: u64 = 0x200;
pub const IRQ_BASE: u32 = 32;
pub const KERNEL_LOAD_OFFSET: u64 = 0x0020_0000;
pub const INITRD_LOAD_OFFSET: u64 = 0x1000_0000;
pub const FDT_LOAD_OFFSET: u64 = 0x0f00_0000;
pub const FDT_MAX_SIZE: u64 = 2 * 1024 * 1024;
pub const DEFAULT_CMDLINE: &str =
    "console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1 cgroup_no_v1=all";

pub const ARM64_IMAGE_MAGIC_OFFSET: usize = 0x38;
pub const ARM64_IMAGE_MAGIC: u32 = 0x644d_5241;

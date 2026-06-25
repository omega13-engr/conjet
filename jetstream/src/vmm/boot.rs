use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use serde::Serialize;
use thiserror::Error;

use crate::arch::aarch64;
use crate::devices::virtio::VirtioMmioDevicePlan;
use crate::vmm::config::JetstreamConfig;
use crate::vmm::fdt::{build_linux_boot_fdt, FdtError};
use crate::vmm::memory::{GuestMemory, GuestMemoryError};

#[derive(Debug, Error)]
pub enum BootPlanError {
    #[error("Jetstream requires an uncompressed ARM64 Linux Image")]
    InvalidKernelImage,
    #[error("guest RAM must be at least 512 MiB")]
    MemoryTooSmall,
    #[error("guest RAM must not exceed {0} MiB")]
    MemoryTooLarge(u64),
    #[error("at least one vCPU is required")]
    NoVcpus,
    #[error("vCPU count must not exceed {0}")]
    TooManyVcpus(u8),
    #[error("{0} does not fit in guest RAM")]
    RegionDoesNotFit(&'static str),
    #[error(transparent)]
    Fdt(#[from] FdtError),
    #[error(transparent)]
    Memory(#[from] GuestMemoryError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub const MIN_MEMORY_MIB: u64 = 512;
pub const MAX_MEMORY_MIB: u64 = 8 * 1024;
pub const MAX_VCPU_COUNT: u8 = 4;
const GUEST_BALLOON_PAGE_SIZE: usize = 4096;
const PAGE_REPORTING_ORDER_PARAMETER: &str = "page_reporting.page_reporting_order=";
const LEGACY_PAGE_REPORTING_ORDER_PARAMETER: &str = "page_reporting_order=";

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BootPlan {
    pub ram_base: u64,
    pub ram_size_bytes: u64,
    pub kernel_load_address: u64,
    pub kernel_size_bytes: u64,
    pub initrd_load_address: Option<u64>,
    pub initrd_size_bytes: u64,
    pub fdt_load_address: u64,
    pub fdt_maximum_size_bytes: u64,
    pub uart_base: u64,
    pub gic_base: u64,
    pub vcpu_count: u8,
    pub cmdline: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct VcpuResetState {
    pub pc: u64,
    pub x0: u64,
    pub x1: u64,
    pub x2: u64,
    pub x3: u64,
    pub cpsr: u64,
}

impl VcpuResetState {
    pub fn boot_cpu(plan: &BootPlan) -> Self {
        Self {
            pc: plan.kernel_load_address,
            x0: plan.fdt_load_address,
            x1: 0,
            x2: 0,
            x3: 0,
            cpsr: 0x3c5,
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct GuestMemoryLoadRange {
    pub name: String,
    pub guest_physical_address: u64,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BootArtifacts {
    pub reset_state: VcpuResetState,
    pub loaded_ranges: Vec<GuestMemoryLoadRange>,
    pub fdt_size_bytes: u64,
}

impl BootArtifacts {
    pub fn loaded_bytes(&self) -> u64 {
        self.loaded_ranges
            .iter()
            .map(|range| range.size_bytes)
            .sum()
    }
}

pub fn load_boot_artifacts(
    config: &JetstreamConfig,
    plan: &BootPlan,
    virtio_devices: &[VirtioMmioDevicePlan],
    memory: &GuestMemory,
) -> Result<BootArtifacts, BootPlanError> {
    let kernel = std::fs::read(&config.boot_source.kernel_path)?;
    if kernel.len() as u64 != plan.kernel_size_bytes {
        return Err(BootPlanError::RegionDoesNotFit("kernel"));
    }
    memory.load_at(plan.ram_base, plan.kernel_load_address, &kernel)?;
    let mut loaded_ranges = vec![GuestMemoryLoadRange {
        name: "kernel".to_string(),
        guest_physical_address: plan.kernel_load_address,
        size_bytes: kernel.len() as u64,
    }];

    if let Some(initrd_path) = config.boot_source.initrd_path.as_ref() {
        let initrd = std::fs::read(initrd_path)?;
        let Some(initrd_address) = plan.initrd_load_address else {
            return Err(BootPlanError::RegionDoesNotFit("initrd"));
        };
        if initrd.len() as u64 != plan.initrd_size_bytes {
            return Err(BootPlanError::RegionDoesNotFit("initrd"));
        }
        memory.load_at(plan.ram_base, initrd_address, &initrd)?;
        loaded_ranges.push(GuestMemoryLoadRange {
            name: "initramfs".to_string(),
            guest_physical_address: initrd_address,
            size_bytes: initrd.len() as u64,
        });
    }

    let fdt = build_linux_boot_fdt(plan, virtio_devices)?;
    memory.load_at(plan.ram_base, plan.fdt_load_address, &fdt)?;
    loaded_ranges.push(GuestMemoryLoadRange {
        name: "fdt".to_string(),
        guest_physical_address: plan.fdt_load_address,
        size_bytes: fdt.len() as u64,
    });

    Ok(BootArtifacts {
        reset_state: VcpuResetState::boot_cpu(plan),
        loaded_ranges,
        fdt_size_bytes: fdt.len() as u64,
    })
}

impl BootPlan {
    pub fn new(config: &JetstreamConfig) -> Result<Self, BootPlanError> {
        if config.memory_mib < MIN_MEMORY_MIB {
            return Err(BootPlanError::MemoryTooSmall);
        }
        if config.memory_mib > MAX_MEMORY_MIB {
            return Err(BootPlanError::MemoryTooLarge(MAX_MEMORY_MIB));
        }
        if config.vcpu_count == 0 {
            return Err(BootPlanError::NoVcpus);
        }
        if config.vcpu_count > MAX_VCPU_COUNT {
            return Err(BootPlanError::TooManyVcpus(MAX_VCPU_COUNT));
        }
        validate_arm64_linux_image(&config.boot_source.kernel_path)?;

        let kernel_size_bytes = file_size(&config.boot_source.kernel_path)?;
        let (initrd_load_address, initrd_size_bytes) =
            if let Some(path) = config.boot_source.initrd_path.as_ref() {
                (
                    Some(aarch64::RAM_BASE + aarch64::INITRD_LOAD_OFFSET),
                    file_size(path)?,
                )
            } else {
                (None, 0)
            };

        let plan = Self {
            ram_base: aarch64::RAM_BASE,
            ram_size_bytes: config.memory_mib * 1024 * 1024,
            kernel_load_address: aarch64::RAM_BASE + aarch64::KERNEL_LOAD_OFFSET,
            kernel_size_bytes,
            initrd_load_address,
            initrd_size_bytes,
            fdt_load_address: aarch64::RAM_BASE + aarch64::FDT_LOAD_OFFSET,
            fdt_maximum_size_bytes: aarch64::FDT_MAX_SIZE,
            uart_base: aarch64::UART_BASE,
            gic_base: aarch64::GIC_BASE,
            vcpu_count: config.vcpu_count,
            cmdline: command_line_with_page_reporting_order(&config.boot_source.cmdline),
        };
        plan.validate()?;
        Ok(plan)
    }

    pub fn ram_end(&self) -> u64 {
        self.ram_base + self.ram_size_bytes
    }

    pub fn contains(&self, guest_address: u64, size: u64) -> bool {
        if size == 0 || guest_address < self.ram_base {
            return false;
        }
        guest_address
            .checked_add(size)
            .is_some_and(|end| end >= guest_address && end <= self.ram_end())
    }

    pub fn summary(&self) -> String {
        format!(
            "Jetstream plan: {} MiB RAM, {} vCPU(s), kernel=0x{:x}+{} bytes, initrd={} bytes, fdt=0x{:x}, uart=0x{:x}",
            self.ram_size_bytes / 1024 / 1024,
            self.vcpu_count,
            self.kernel_load_address,
            self.kernel_size_bytes,
            self.initrd_size_bytes,
            self.fdt_load_address,
            self.uart_base
        )
    }

    fn validate(&self) -> Result<(), BootPlanError> {
        if !self.contains(self.kernel_load_address, self.kernel_size_bytes) {
            return Err(BootPlanError::RegionDoesNotFit("kernel"));
        }
        if let Some(initrd) = self.initrd_load_address {
            if !self.contains(initrd, self.initrd_size_bytes) {
                return Err(BootPlanError::RegionDoesNotFit("initrd"));
            }
        }
        if !self.contains(self.fdt_load_address, self.fdt_maximum_size_bytes) {
            return Err(BootPlanError::RegionDoesNotFit("fdt"));
        }
        Ok(())
    }
}

fn command_line_with_page_reporting_order(command_line: &str) -> String {
    let Some(order) = page_reporting_order(GUEST_BALLOON_PAGE_SIZE, host_page_size()) else {
        return command_line.to_string();
    };
    command_line_with_page_reporting_order_value(command_line, order)
}

fn command_line_with_page_reporting_order_value(command_line: &str, order: u32) -> String {
    let mut has_explicit_order = false;
    let mut tokens = Vec::new();
    for token in command_line.split_whitespace() {
        if token.starts_with(PAGE_REPORTING_ORDER_PARAMETER) {
            has_explicit_order = true;
            tokens.push(token.to_string());
        } else if !token.starts_with(LEGACY_PAGE_REPORTING_ORDER_PARAMETER) {
            tokens.push(token.to_string());
        }
    }
    if !has_explicit_order {
        tokens.push(format!("{PAGE_REPORTING_ORDER_PARAMETER}{order}"));
    }
    tokens.join(" ")
}

fn page_reporting_order(guest_page_size: usize, host_page_size: usize) -> Option<u32> {
    if guest_page_size == 0 || host_page_size < guest_page_size {
        return None;
    }
    let ratio = host_page_size / guest_page_size;
    if ratio == 0 || host_page_size % guest_page_size != 0 || !ratio.is_power_of_two() {
        return None;
    }
    Some(ratio.trailing_zeros())
}

fn host_page_size() -> usize {
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if page_size <= 0 {
        GUEST_BALLOON_PAGE_SIZE
    } else {
        page_size as usize
    }
}

pub fn validate_arm64_linux_image(path: &Path) -> Result<(), BootPlanError> {
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(aarch64::ARM64_IMAGE_MAGIC_OFFSET as u64))?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic)?;
    if u32::from_le_bytes(magic) == aarch64::ARM64_IMAGE_MAGIC {
        Ok(())
    } else {
        Err(BootPlanError::InvalidKernelImage)
    }
}

fn file_size(path: &Path) -> Result<u64, BootPlanError> {
    Ok(std::fs::metadata(path)?.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn computes_page_reporting_order_from_host_granule() {
        assert_eq!(page_reporting_order(4096, 4096), Some(0));
        assert_eq!(page_reporting_order(4096, 16384), Some(2));
        assert_eq!(page_reporting_order(4096, 65536), Some(4));
        assert_eq!(page_reporting_order(4096, 12288), None);
        assert_eq!(page_reporting_order(16384, 4096), None);
    }

    #[test]
    fn appends_page_reporting_order_when_missing() {
        assert_eq!(
            command_line_with_page_reporting_order_value("console=ttyAMA0 root=/dev/vda1", 2),
            "console=ttyAMA0 root=/dev/vda1 page_reporting.page_reporting_order=2"
        );
    }

    #[test]
    fn preserves_explicit_page_reporting_order() {
        assert_eq!(
            command_line_with_page_reporting_order_value(
                "console=ttyAMA0 page_reporting.page_reporting_order=5 root=/dev/vda1",
                2
            ),
            "console=ttyAMA0 page_reporting.page_reporting_order=5 root=/dev/vda1"
        );
    }

    #[test]
    fn replaces_legacy_unprefixed_page_reporting_order() {
        assert_eq!(
            command_line_with_page_reporting_order_value(
                "console=ttyAMA0 page_reporting_order=5 root=/dev/vda1",
                2
            ),
            "console=ttyAMA0 root=/dev/vda1 page_reporting.page_reporting_order=2"
        );
    }
}

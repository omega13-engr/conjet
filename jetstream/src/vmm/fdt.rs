use thiserror::Error;

use crate::arch::aarch64;
use crate::devices::virtio::VirtioMmioDevicePlan;
use crate::vmm::boot::BootPlan;

const FDT_MAGIC: u32 = 0xd00d_feed;
const FDT_VERSION: u32 = 17;
const FDT_LAST_COMP_VERSION: u32 = 16;
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_END: u32 = 9;
const GIC_PHANDLE: u32 = 1;
const UART_CLOCK_PHANDLE: u32 = 2;
const APB_CLOCK_PHANDLE: u32 = 3;

#[derive(Debug, Error)]
pub enum FdtError {
    #[error("FDT string table offset does not fit in u32")]
    OffsetOverflow,
    #[error("FDT blob exceeds reserved boot-plan space")]
    ExceedsReservation,
}

#[derive(Default)]
struct StringTable {
    bytes: Vec<u8>,
}

impl StringTable {
    fn offset(&mut self, name: &str) -> Result<u32, FdtError> {
        if let Some(offset) = find_c_string(&self.bytes, name) {
            return u32::try_from(offset).map_err(|_| FdtError::OffsetOverflow);
        }
        let offset = self.bytes.len();
        self.bytes.extend_from_slice(name.as_bytes());
        self.bytes.push(0);
        u32::try_from(offset).map_err(|_| FdtError::OffsetOverflow)
    }
}

#[derive(Default)]
struct Writer {
    structure: Vec<u8>,
    strings: StringTable,
}

impl Writer {
    fn begin_node(&mut self, name: &str) {
        be32(&mut self.structure, FDT_BEGIN_NODE);
        self.structure.extend_from_slice(name.as_bytes());
        self.structure.push(0);
        align4(&mut self.structure);
    }

    fn end_node(&mut self) {
        be32(&mut self.structure, FDT_END_NODE);
    }

    fn prop(&mut self, name: &str, value: &[u8]) -> Result<(), FdtError> {
        be32(&mut self.structure, FDT_PROP);
        be32(&mut self.structure, value.len() as u32);
        let offset = self.strings.offset(name)?;
        be32(&mut self.structure, offset);
        self.structure.extend_from_slice(value);
        align4(&mut self.structure);
        Ok(())
    }

    fn prop_empty(&mut self, name: &str) -> Result<(), FdtError> {
        self.prop(name, &[])
    }

    fn prop_str(&mut self, name: &str, value: &str) -> Result<(), FdtError> {
        let mut bytes = value.as_bytes().to_vec();
        bytes.push(0);
        self.prop(name, &bytes)
    }

    fn prop_str_list(&mut self, name: &str, values: &[&str]) -> Result<(), FdtError> {
        let mut bytes = Vec::new();
        for value in values {
            bytes.extend_from_slice(value.as_bytes());
            bytes.push(0);
        }
        self.prop(name, &bytes)
    }

    fn prop_u32(&mut self, name: &str, value: u32) -> Result<(), FdtError> {
        let mut bytes = Vec::new();
        be32(&mut bytes, value);
        self.prop(name, &bytes)
    }

    fn prop_u64(&mut self, name: &str, value: u64) -> Result<(), FdtError> {
        let mut bytes = Vec::new();
        be64(&mut bytes, value);
        self.prop(name, &bytes)
    }

    fn prop_reg(&mut self, name: &str, pairs: &[(u64, u64)]) -> Result<(), FdtError> {
        let mut bytes = Vec::new();
        for (address, size) in pairs {
            be64(&mut bytes, *address);
            be64(&mut bytes, *size);
        }
        self.prop(name, &bytes)
    }

    fn prop_interrupts(&mut self, spi: u32) -> Result<(), FdtError> {
        let mut bytes = Vec::new();
        be32(&mut bytes, 0);
        be32(&mut bytes, spi);
        be32(&mut bytes, 4);
        self.prop("interrupts", &bytes)
    }

    fn finish(mut self, reserve_size: u64) -> Result<Vec<u8>, FdtError> {
        be32(&mut self.structure, FDT_END);
        let reserve_map_size = 16usize;
        let header_size = 40usize;
        let off_mem_rsvmap = header_size;
        let off_dt_struct = off_mem_rsvmap + reserve_map_size;
        let off_dt_strings = off_dt_struct + self.structure.len();
        let totalsize = off_dt_strings + self.strings.bytes.len();
        if totalsize as u64 > reserve_size {
            return Err(FdtError::ExceedsReservation);
        }

        let mut out = Vec::with_capacity(totalsize);
        be32(&mut out, FDT_MAGIC);
        be32(&mut out, totalsize as u32);
        be32(&mut out, off_dt_struct as u32);
        be32(&mut out, off_dt_strings as u32);
        be32(&mut out, off_mem_rsvmap as u32);
        be32(&mut out, FDT_VERSION);
        be32(&mut out, FDT_LAST_COMP_VERSION);
        be32(&mut out, 0);
        be32(&mut out, self.strings.bytes.len() as u32);
        be32(&mut out, self.structure.len() as u32);
        out.resize(off_dt_struct, 0);
        out.extend_from_slice(&self.structure);
        out.extend_from_slice(&self.strings.bytes);
        Ok(out)
    }
}

pub fn build_linux_boot_fdt(
    plan: &BootPlan,
    virtio_devices: &[VirtioMmioDevicePlan],
) -> Result<Vec<u8>, FdtError> {
    let mut w = Writer::default();
    w.begin_node("");
    w.prop_u32("#address-cells", 2)?;
    w.prop_u32("#size-cells", 2)?;
    w.prop_u32("interrupt-parent", GIC_PHANDLE)?;
    w.prop_str("compatible", "linux,dummy-virt")?;

    w.begin_node("chosen");
    w.prop_str("bootargs", &plan.cmdline)?;
    if let Some(initrd_start) = plan.initrd_load_address {
        w.prop_u64("linux,initrd-start", initrd_start)?;
        w.prop_u64("linux,initrd-end", initrd_start + plan.initrd_size_bytes)?;
    }
    w.end_node();

    w.begin_node("memory@40000000");
    w.prop_str("device_type", "memory")?;
    w.prop_reg("reg", &[(plan.ram_base, plan.ram_size_bytes)])?;
    w.end_node();

    w.begin_node("cpus");
    w.prop_u32("#address-cells", 2)?;
    w.prop_u32("#size-cells", 0)?;
    for cpu in 0..plan.vcpu_count {
        w.begin_node(&format!("cpu@{cpu:x}"));
        w.prop_str("device_type", "cpu")?;
        w.prop_str("compatible", "arm,arm-v8")?;
        w.prop_str("enable-method", "psci")?;
        w.prop_u64("reg", u64::from(cpu))?;
        w.end_node();
    }
    w.end_node();

    w.begin_node("psci");
    w.prop_str("compatible", "arm,psci-0.2")?;
    w.prop_str("method", "hvc")?;
    w.end_node();

    w.begin_node("timer");
    w.prop_str("compatible", "arm,armv8-timer")?;
    let mut interrupts = Vec::new();
    for ppi in [13u32, 14, 11, 10] {
        be32(&mut interrupts, 1);
        be32(&mut interrupts, ppi);
        be32(&mut interrupts, 4);
    }
    w.prop("interrupts", &interrupts)?;
    w.end_node();

    w.begin_node("intc@8000000");
    w.prop_str("compatible", "arm,gic-v3")?;
    w.prop_empty("interrupt-controller")?;
    w.prop_u32("#interrupt-cells", 3)?;
    w.prop_u32("#address-cells", 2)?;
    w.prop_u32("#size-cells", 2)?;
    w.prop_u32("phandle", GIC_PHANDLE)?;
    w.prop_reg(
        "reg",
        &[
            (aarch64::GIC_BASE, aarch64::GIC_DISTRIBUTOR_SIZE),
            (
                aarch64::GIC_BASE + aarch64::GIC_DISTRIBUTOR_SIZE,
                aarch64::GIC_REDISTRIBUTOR_STRIDE * u64::from(plan.vcpu_count.max(1)),
            ),
        ],
    )?;
    w.end_node();

    w.begin_node("uartclk");
    w.prop_str("compatible", "fixed-clock")?;
    w.prop_u32("#clock-cells", 0)?;
    w.prop_u32("clock-frequency", 24_000_000)?;
    w.prop_u32("phandle", UART_CLOCK_PHANDLE)?;
    w.end_node();

    w.begin_node("apb-pclk");
    w.prop_str("compatible", "fixed-clock")?;
    w.prop_u32("#clock-cells", 0)?;
    w.prop_u32("clock-frequency", 24_000_000)?;
    w.prop_u32("phandle", APB_CLOCK_PHANDLE)?;
    w.end_node();

    w.begin_node("pl011@9000000");
    w.prop_str_list("compatible", &["arm,pl011", "arm,primecell"])?;
    w.prop_reg("reg", &[(aarch64::UART_BASE, aarch64::UART_SIZE)])?;
    w.prop_interrupts(8)?;
    w.prop_u32("arm,primecell-periphid", 0x0004_1011)?;
    let mut clocks = Vec::new();
    be32(&mut clocks, UART_CLOCK_PHANDLE);
    be32(&mut clocks, APB_CLOCK_PHANDLE);
    w.prop("clocks", &clocks)?;
    w.prop_str_list("clock-names", &["uartclk", "apb_pclk"])?;
    w.prop_u32("clock-frequency", 24_000_000)?;
    w.prop_u32("current-speed", 115_200)?;
    w.prop_str("status", "okay")?;
    w.end_node();

    for device in virtio_devices {
        w.begin_node(&format!("virtio_mmio@{:x}", device.mmio_base));
        w.prop_str("compatible", "virtio,mmio")?;
        w.prop_reg("reg", &[(device.mmio_base, aarch64::VIRTIO_MMIO_STRIDE)])?;
        w.prop_interrupts(device.irq - aarch64::IRQ_BASE)?;
        w.end_node();
    }

    w.end_node();
    w.finish(plan.fdt_maximum_size_bytes)
}

fn find_c_string(bytes: &[u8], needle: &str) -> Option<usize> {
    let needle = needle.as_bytes();
    bytes
        .split(|byte| *byte == 0)
        .scan(0usize, |offset, item| {
            let current = *offset;
            *offset += item.len() + 1;
            Some((current, item))
        })
        .find_map(|(offset, item)| (item == needle).then_some(offset))
}

fn be32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn be64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn align4(out: &mut Vec<u8>) {
    while out.len() % 4 != 0 {
        out.push(0);
    }
}

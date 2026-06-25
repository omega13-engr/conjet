use std::collections::BTreeMap;

use thiserror::Error;

use crate::arch::aarch64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GicLayout {
    pub distributor_base: u64,
    pub distributor_size: u64,
    pub redistributor_base: u64,
    pub redistributor_size: u64,
    pub redistributor_stride: u64,
}

impl GicLayout {
    pub fn new(vcpu_count: u8) -> Self {
        let redistributor_stride = aarch64::GIC_REDISTRIBUTOR_STRIDE;
        Self {
            distributor_base: aarch64::GIC_BASE,
            distributor_size: aarch64::GIC_DISTRIBUTOR_SIZE,
            redistributor_base: aarch64::GIC_BASE + aarch64::GIC_DISTRIBUTOR_SIZE,
            redistributor_size: redistributor_stride * u64::from(vcpu_count.max(1)),
            redistributor_stride,
        }
    }
}

#[derive(Debug, Error)]
#[error("Hypervisor.framework GIC call {call} failed with hv_return_t=0x{code:08x}")]
pub struct GicError {
    pub call: &'static str,
    pub code: i32,
}

pub type GicResult<T> = Result<T, GicError>;

#[derive(Debug, Clone)]
pub struct GicMmio {
    layout: GicLayout,
    distributor_control: u32,
    redistributor_waker: u32,
    registers: BTreeMap<u64, u64>,
}

impl GicMmio {
    pub fn new(layout: GicLayout) -> Self {
        Self {
            layout,
            distributor_control: 0,
            redistributor_waker: 0,
            registers: BTreeMap::new(),
        }
    }

    pub fn contains(&self, address: u64) -> bool {
        let end = self
            .layout
            .redistributor_base
            .saturating_add(self.layout.redistributor_size);
        address >= self.layout.distributor_base && address < end
    }

    pub fn read(&mut self, address: u64, size: u8) -> Result<u64, String> {
        self.validate_size(size)?;
        let offset = address
            .checked_sub(self.layout.distributor_base)
            .ok_or_else(|| format!("GIC MMIO read underflow at 0x{address:x}"))?;
        if offset < self.layout.distributor_size {
            return Ok(self.read_distributor(offset, size));
        }
        Ok(self.read_redistributor(
            offset - (self.layout.redistributor_base - self.layout.distributor_base),
            size,
        ))
    }

    pub fn write(&mut self, address: u64, value: u64, size: u8) -> Result<(), String> {
        self.validate_size(size)?;
        let offset = address
            .checked_sub(self.layout.distributor_base)
            .ok_or_else(|| format!("GIC MMIO write underflow at 0x{address:x}"))?;
        if offset < self.layout.distributor_size {
            self.write_distributor(offset, value, size);
            return Ok(());
        }
        self.write_redistributor(
            offset - (self.layout.redistributor_base - self.layout.distributor_base),
            value,
            size,
        );
        Ok(())
    }

    fn read_distributor(&self, offset: u64, size: u8) -> u64 {
        match offset {
            0x0000 => u64::from(self.distributor_control),
            0x0004 => u64::from(self.distributor_typer()),
            0x0008 => 0x0102_043b,
            0x0010 => 0,
            0xffe0..=0xffff => peripheral_id(offset),
            _ => self
                .registers
                .get(&aligned_offset(offset, size))
                .copied()
                .unwrap_or(0),
        }
    }

    fn write_distributor(&mut self, offset: u64, value: u64, size: u8) {
        match offset {
            0x0000 => self.distributor_control = value as u32,
            _ => {
                self.registers.insert(aligned_offset(offset, size), value);
            }
        }
    }

    fn read_redistributor(&self, offset: u64, size: u8) -> u64 {
        let stride_offset = offset % self.layout.redistributor_stride;
        match stride_offset {
            0x0000 => 0,
            0x0004 => 0x0102_043b,
            0x0008 => self.redistributor_typer(offset, size),
            0x0010 => 0,
            0x0014 => u64::from(self.redistributor_waker),
            0xffe0..=0xffff => peripheral_id(stride_offset),
            _ => self
                .registers
                .get(&aligned_offset(offset, size))
                .copied()
                .unwrap_or_else(|| default_redistributor_register(stride_offset)),
        }
    }

    fn write_redistributor(&mut self, offset: u64, value: u64, size: u8) {
        let stride_offset = offset % self.layout.redistributor_stride;
        match stride_offset {
            // Linux clears ProcessorSleep and waits for ChildrenAsleep to clear.
            0x0014 => self.redistributor_waker = (value as u32) & !0b100,
            _ => {
                self.registers.insert(aligned_offset(offset, size), value);
            }
        }
    }

    fn distributor_typer(&self) -> u32 {
        let spi_base = aarch64::IRQ_BASE;
        let spi_count = 988u32;
        let last_intid = spi_base + spi_count - 1;
        31.min(last_intid / 32)
    }

    fn redistributor_typer(&self, offset: u64, size: u8) -> u64 {
        let redistributor_index = offset / self.layout.redistributor_stride;
        let redistributor_count =
            (self.layout.redistributor_size / self.layout.redistributor_stride).max(1);
        let value = if redistributor_index + 1 >= redistributor_count {
            1u64 << 4
        } else {
            0
        };
        if size == 4 {
            value & 0xffff_ffff
        } else {
            value
        }
    }

    fn validate_size(&self, size: u8) -> Result<(), String> {
        match size {
            1 | 2 | 4 | 8 => Ok(()),
            _ => Err(format!("unsupported GIC MMIO access size {size}")),
        }
    }
}

fn peripheral_id(offset: u64) -> u64 {
    match offset & 0xfffc {
        0xffe0 => 0x92,
        0xffe4 => 0xb4,
        0xffe8 => 0x30,
        0xffec => 0x00,
        0xfff0 => 0x0d,
        0xfff4 => 0xf0,
        0xfff8 => 0x05,
        0xfffc => 0xb1,
        _ => 0,
    }
}

fn default_redistributor_register(offset: u64) -> u64 {
    match offset {
        0x10080 => 0xffff_ffff,
        _ => 0,
    }
}

fn aligned_offset(offset: u64, size: u8) -> u64 {
    offset & !u64::from(size.max(1) - 1)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
mod imp {
    use super::{GicError, GicLayout, GicResult};

    type CreateConfig = unsafe extern "C" fn() -> *mut libc::c_void;
    type ReleaseConfig = unsafe extern "C" fn(*mut libc::c_void);
    type SetBase = unsafe extern "C" fn(*mut libc::c_void, u64) -> i32;
    type CreateGic = unsafe extern "C" fn(*mut libc::c_void) -> i32;
    type GetIntId = unsafe extern "C" fn(u16, *mut u32) -> i32;
    type SetRedistributorRegister = unsafe extern "C" fn(u64, u32, u64) -> i32;
    type SetSpi = unsafe extern "C" fn(u32, bool) -> i32;

    const HV_VTIMER_INTID: u16 = 27;
    const GICR_ISPENDR0: u32 = 0x10200;

    pub struct Gic {
        api: GicApi,
    }

    unsafe impl Send for Gic {}
    unsafe impl Sync for Gic {}

    impl Gic {
        pub fn create(layout: GicLayout) -> GicResult<Self> {
            let api = GicApi::load()?;
            let config = unsafe { (api.create_config)() };
            if config.is_null() {
                return Err(GicError {
                    call: "hv_gic_config_create",
                    code: -1,
                });
            }
            let release = api.release_config;
            let result = (|| {
                check("hv_gic_config_set_distributor_base", unsafe {
                    (api.set_distributor_base)(config, layout.distributor_base)
                })?;
                check("hv_gic_config_set_redistributor_base", unsafe {
                    (api.set_redistributor_base)(config, layout.redistributor_base)
                })?;
                check("hv_gic_create", unsafe { (api.create_gic)(config) })?;
                Ok(())
            })();
            unsafe {
                release(config);
            }
            result?;
            Ok(Self { api })
        }

        pub fn set_spi(&self, intid: u32, level: bool) -> GicResult<()> {
            check("hv_gic_set_spi", unsafe {
                (self.api.set_spi)(intid, level)
            })
        }

        pub fn set_vtimer_pending(&self, vcpu: u64) -> GicResult<()> {
            let mut intid = 0u32;
            check("hv_gic_get_intid", unsafe {
                (self.api.get_intid)(HV_VTIMER_INTID, &mut intid)
            })?;
            if intid >= 32 {
                return Err(GicError {
                    call: "hv_gic_get_intid",
                    code: -1,
                });
            }
            check("hv_gic_set_redistributor_reg", unsafe {
                (self.api.set_redistributor_reg)(vcpu, GICR_ISPENDR0, 1u64 << intid)
            })
        }
    }

    struct GicApi {
        handle: *mut libc::c_void,
        create_config: CreateConfig,
        release_config: ReleaseConfig,
        set_distributor_base: SetBase,
        set_redistributor_base: SetBase,
        create_gic: CreateGic,
        get_intid: GetIntId,
        set_redistributor_reg: SetRedistributorRegister,
        set_spi: SetSpi,
    }

    unsafe impl Send for GicApi {}
    unsafe impl Sync for GicApi {}

    impl GicApi {
        fn load() -> GicResult<Self> {
            let path = b"/System/Library/Frameworks/Hypervisor.framework/Hypervisor\0";
            let handle = unsafe { libc::dlopen(path.as_ptr() as *const _, libc::RTLD_NOW) };
            if handle.is_null() {
                return Err(missing("dlopen"));
            }
            let api = unsafe {
                Self {
                    handle,
                    create_config: symbol(handle, b"hv_gic_config_create\0")?,
                    release_config: symbol(libc::RTLD_DEFAULT, b"os_release\0")?,
                    set_distributor_base: symbol(handle, b"hv_gic_config_set_distributor_base\0")?,
                    set_redistributor_base: symbol(
                        handle,
                        b"hv_gic_config_set_redistributor_base\0",
                    )?,
                    create_gic: symbol(handle, b"hv_gic_create\0")?,
                    get_intid: symbol(handle, b"hv_gic_get_intid\0")?,
                    set_redistributor_reg: symbol(handle, b"hv_gic_set_redistributor_reg\0")?,
                    set_spi: symbol(handle, b"hv_gic_set_spi\0")?,
                }
            };
            Ok(api)
        }
    }

    impl Drop for GicApi {
        fn drop(&mut self) {
            unsafe {
                libc::dlclose(self.handle);
            }
        }
    }

    unsafe fn symbol<T>(handle: *mut libc::c_void, name: &'static [u8]) -> GicResult<T> {
        let symbol = libc::dlsym(handle, name.as_ptr() as *const _);
        if symbol.is_null() {
            return Err(missing(std::str::from_utf8(name).unwrap_or("dlsym")));
        }
        Ok(std::mem::transmute_copy(&symbol))
    }

    fn check(call: &'static str, code: i32) -> GicResult<()> {
        if code == 0 {
            Ok(())
        } else {
            Err(GicError { call, code })
        }
    }

    fn missing(call: &'static str) -> GicError {
        GicError { call, code: -1 }
    }
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
mod imp {
    use super::{GicError, GicLayout, GicResult};

    pub struct Gic;

    unsafe impl Send for Gic {}
    unsafe impl Sync for Gic {}

    impl Gic {
        pub fn create(_layout: GicLayout) -> GicResult<Self> {
            Err(unsupported("hv_gic_create"))
        }

        pub fn set_spi(&self, _intid: u32, _level: bool) -> GicResult<()> {
            Err(unsupported("hv_gic_set_spi"))
        }

        pub fn set_vtimer_pending(&self, _vcpu: u64) -> GicResult<()> {
            Err(unsupported("hv_gic_set_redistributor_reg"))
        }
    }

    fn unsupported(call: &'static str) -> GicError {
        GicError { call, code: -1 }
    }
}

pub use imp::*;

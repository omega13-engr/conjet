use thiserror::Error;

#[derive(Debug, Error)]
#[error("Hypervisor.framework call {call} failed with hv_return_t=0x{code:08x}")]
pub struct HvfError {
    pub call: &'static str,
    pub code: i32,
}

pub type HvfResult<T> = Result<T, HvfError>;

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
mod imp {
    use super::{HvfError, HvfResult};

    pub type HvVcpu = u64;

    pub const HV_MEMORY_READ: u64 = 1;
    pub const HV_MEMORY_WRITE: u64 = 2;
    pub const HV_MEMORY_EXEC: u64 = 4;

    pub const HV_REG_X0: u32 = 0;
    pub const HV_REG_X1: u32 = 1;
    pub const HV_REG_X2: u32 = 2;
    pub const HV_REG_X3: u32 = 3;
    pub const HV_REG_PC: u32 = 31;
    pub const HV_REG_CPSR: u32 = 34;
    pub const HV_SYS_REG_MPIDR_EL1: u16 = 0xc005;

    #[link(name = "Hypervisor", kind = "framework")]
    extern "C" {
        fn hv_vm_create(config: *const libc::c_void) -> i32;
        fn hv_vm_destroy() -> i32;
        fn hv_vm_map(uva: *mut libc::c_void, gpa: u64, size: libc::size_t, flags: u64) -> i32;
        fn hv_vm_unmap(gpa: u64, size: libc::size_t) -> i32;
        fn hv_vcpu_create(
            vcpu: *mut HvVcpu,
            exit: *mut *mut libc::c_void,
            config: *const libc::c_void,
        ) -> i32;
        fn hv_vcpu_destroy(vcpu: HvVcpu) -> i32;
        fn hv_vcpu_set_reg(vcpu: HvVcpu, reg: u32, value: u64) -> i32;
        fn hv_vcpu_get_reg(vcpu: HvVcpu, reg: u32, value: *mut u64) -> i32;
        fn hv_vcpu_set_sys_reg(vcpu: HvVcpu, reg: u16, value: u64) -> i32;
        fn hv_vcpu_get_sys_reg(vcpu: HvVcpu, reg: u16, value: *mut u64) -> i32;
        fn hv_vcpu_set_pending_interrupt(vcpu: HvVcpu, interrupt_type: u32, pending: bool) -> i32;
        fn hv_vcpu_set_vtimer_mask(vcpu: HvVcpu, masked: bool) -> i32;
        fn hv_vcpu_run(vcpu: HvVcpu) -> i32;
        fn hv_vcpus_exit(vcpus: *mut HvVcpu, vcpu_count: u32) -> i32;
    }

    #[repr(C)]
    #[derive(Debug, Clone, Copy)]
    pub struct HvVcpuExitException {
        pub syndrome: u64,
        pub virtual_address: u64,
        pub physical_address: u64,
    }

    #[repr(C)]
    #[derive(Debug, Clone, Copy)]
    pub struct HvVcpuExit {
        pub reason: u32,
        pub exception: HvVcpuExitException,
    }

    #[derive(Debug)]
    pub struct Vm;

    unsafe impl Send for Vm {}
    unsafe impl Sync for Vm {}

    impl Vm {
        pub fn create() -> HvfResult<Self> {
            check("hv_vm_create", unsafe { hv_vm_create(std::ptr::null()) })?;
            Ok(Self)
        }

        pub fn map_memory(
            &self,
            uva: *mut libc::c_void,
            gpa: u64,
            size: usize,
            flags: u64,
        ) -> HvfResult<()> {
            check("hv_vm_map", unsafe { hv_vm_map(uva, gpa, size, flags) })
        }

        pub fn unmap_memory(&self, gpa: u64, size: usize) -> HvfResult<()> {
            check("hv_vm_unmap", unsafe { hv_vm_unmap(gpa, size) })
        }
    }

    impl Drop for Vm {
        fn drop(&mut self) {
            unsafe {
                hv_vm_destroy();
            }
        }
    }

    pub struct Vcpu {
        id: HvVcpu,
        exit: *mut libc::c_void,
    }

    unsafe impl Send for Vcpu {}

    impl Vcpu {
        pub fn create() -> HvfResult<Self> {
            let mut id = 0;
            let mut exit = std::ptr::null_mut();
            check("hv_vcpu_create", unsafe {
                hv_vcpu_create(&mut id, &mut exit, std::ptr::null())
            })?;
            Ok(Self { id, exit })
        }

        pub fn set_reg(&self, reg: u32, value: u64) -> HvfResult<()> {
            check("hv_vcpu_set_reg", unsafe {
                hv_vcpu_set_reg(self.id, reg, value)
            })
        }

        pub fn get_reg(&self, reg: u32) -> HvfResult<u64> {
            let mut value = 0;
            check("hv_vcpu_get_reg", unsafe {
                hv_vcpu_get_reg(self.id, reg, &mut value)
            })?;
            Ok(value)
        }

        pub fn set_sys_reg(&self, reg: u16, value: u64) -> HvfResult<()> {
            check("hv_vcpu_set_sys_reg", unsafe {
                hv_vcpu_set_sys_reg(self.id, reg, value)
            })
        }

        pub fn get_sys_reg(&self, reg: u16) -> HvfResult<u64> {
            let mut value = 0;
            check("hv_vcpu_get_sys_reg", unsafe {
                hv_vcpu_get_sys_reg(self.id, reg, &mut value)
            })?;
            Ok(value)
        }

        pub fn id(&self) -> HvVcpu {
            self.id
        }

        pub fn set_pending_interrupt(&self, interrupt_type: u32, pending: bool) -> HvfResult<()> {
            check("hv_vcpu_set_pending_interrupt", unsafe {
                hv_vcpu_set_pending_interrupt(self.id, interrupt_type, pending)
            })
        }

        pub fn set_vtimer_mask(&self, masked: bool) -> HvfResult<()> {
            check("hv_vcpu_set_vtimer_mask", unsafe {
                hv_vcpu_set_vtimer_mask(self.id, masked)
            })
        }

        pub fn run(&self) -> HvfResult<()> {
            check("hv_vcpu_run", unsafe { hv_vcpu_run(self.id) })
        }

        pub fn exit_info(&self) -> Option<HvVcpuExit> {
            if self.exit.is_null() {
                None
            } else {
                Some(unsafe { *(self.exit as *const HvVcpuExit) })
            }
        }
    }

    pub fn exit_vcpus(vcpus: &[HvVcpu]) -> HvfResult<()> {
        let mut ids = vcpus.to_vec();
        check("hv_vcpus_exit", unsafe {
            hv_vcpus_exit(ids.as_mut_ptr(), ids.len() as u32)
        })
    }

    impl Drop for Vcpu {
        fn drop(&mut self) {
            unsafe {
                hv_vcpu_destroy(self.id);
            }
        }
    }

    fn check(call: &'static str, code: i32) -> HvfResult<()> {
        if code == 0 {
            Ok(())
        } else {
            Err(HvfError { call, code })
        }
    }
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
mod imp {
    use super::{HvfError, HvfResult};

    pub const HV_MEMORY_READ: u64 = 1;
    pub const HV_MEMORY_WRITE: u64 = 2;
    pub const HV_MEMORY_EXEC: u64 = 4;
    pub const HV_REG_X0: u32 = 0;
    pub const HV_REG_X1: u32 = 1;
    pub const HV_REG_X2: u32 = 2;
    pub const HV_REG_X3: u32 = 3;
    pub const HV_REG_PC: u32 = 31;
    pub const HV_REG_CPSR: u32 = 34;
    pub const HV_SYS_REG_MPIDR_EL1: u16 = 0xc005;

    #[derive(Debug, Clone, Copy)]
    pub struct HvVcpuExitException {
        pub syndrome: u64,
        pub virtual_address: u64,
        pub physical_address: u64,
    }

    #[derive(Debug, Clone, Copy)]
    pub struct HvVcpuExit {
        pub reason: u32,
        pub exception: HvVcpuExitException,
    }

    #[derive(Debug)]
    pub struct Vm;
    pub struct Vcpu;

    unsafe impl Send for Vm {}
    unsafe impl Sync for Vm {}
    unsafe impl Send for Vcpu {}

    impl Vm {
        pub fn create() -> HvfResult<Self> {
            Err(unsupported("hv_vm_create"))
        }
        pub fn map_memory(
            &self,
            _uva: *mut libc::c_void,
            _gpa: u64,
            _size: usize,
            _flags: u64,
        ) -> HvfResult<()> {
            Err(unsupported("hv_vm_map"))
        }
        pub fn unmap_memory(&self, _gpa: u64, _size: usize) -> HvfResult<()> {
            Err(unsupported("hv_vm_unmap"))
        }
    }

    impl Vcpu {
        pub fn create() -> HvfResult<Self> {
            Err(unsupported("hv_vcpu_create"))
        }
        pub fn set_reg(&self, _reg: u32, _value: u64) -> HvfResult<()> {
            Err(unsupported("hv_vcpu_set_reg"))
        }
        pub fn get_reg(&self, _reg: u32) -> HvfResult<u64> {
            Err(unsupported("hv_vcpu_get_reg"))
        }
        pub fn set_sys_reg(&self, _reg: u16, _value: u64) -> HvfResult<()> {
            Err(unsupported("hv_vcpu_set_sys_reg"))
        }
        pub fn get_sys_reg(&self, _reg: u16) -> HvfResult<u64> {
            Err(unsupported("hv_vcpu_get_sys_reg"))
        }
        pub fn id(&self) -> u64 {
            0
        }
        pub fn set_pending_interrupt(&self, _interrupt_type: u32, _pending: bool) -> HvfResult<()> {
            Err(unsupported("hv_vcpu_set_pending_interrupt"))
        }
        pub fn set_vtimer_mask(&self, _masked: bool) -> HvfResult<()> {
            Err(unsupported("hv_vcpu_set_vtimer_mask"))
        }
        pub fn run(&self) -> HvfResult<()> {
            Err(unsupported("hv_vcpu_run"))
        }
        pub fn exit_info(&self) -> Option<HvVcpuExit> {
            None
        }
    }

    pub fn exit_vcpus(_vcpus: &[u64]) -> HvfResult<()> {
        Err(unsupported("hv_vcpus_exit"))
    }

    fn unsupported(call: &'static str) -> HvfError {
        HvfError { call, code: -1 }
    }
}

pub use imp::*;

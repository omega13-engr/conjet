use serde::Serialize;

use crate::hvf::ffi::{
    Vcpu, Vm, HV_MEMORY_EXEC, HV_MEMORY_READ, HV_MEMORY_WRITE, HV_REG_CPSR, HV_REG_PC, HV_REG_X0,
    HV_REG_X1,
};
use crate::vmm::memory::GuestMemory;

#[derive(Debug, Clone, Serialize)]
pub struct HvfSmokeReport {
    pub ok: bool,
    pub stages: Vec<HvfSmokeStage>,
}

impl HvfSmokeReport {
    pub fn summary(&self) -> String {
        if self.ok {
            "HVF smoke passed".to_string()
        } else {
            let failed = self
                .stages
                .iter()
                .find(|stage| !stage.ok)
                .map(|stage| format!("{}: {}", stage.name, stage.detail))
                .unwrap_or_else(|| "unknown failure".to_string());
            format!("HVF smoke failed at {failed}")
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct HvfSmokeStage {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub struct HvfSmokeRunner {
    memory_bytes: usize,
    guest_physical_address: u64,
}

impl Default for HvfSmokeRunner {
    fn default() -> Self {
        Self {
            memory_bytes: 64 * 1024,
            guest_physical_address: 0x4000_0000,
        }
    }
}

impl HvfSmokeRunner {
    pub fn run(&self) -> HvfSmokeReport {
        let mut stages = Vec::new();
        let mut stage = |name, result: Result<String, anyhow::Error>| -> bool {
            match result {
                Ok(detail) => {
                    stages.push(HvfSmokeStage {
                        name,
                        ok: true,
                        detail,
                    });
                    true
                }
                Err(error) => {
                    stages.push(HvfSmokeStage {
                        name,
                        ok: false,
                        detail: error.to_string(),
                    });
                    false
                }
            }
        };

        let memory = match GuestMemory::anonymous(self.memory_bytes) {
            Ok(memory) => {
                stage(
                    "guest-memory",
                    Ok(format!("allocated {} bytes", memory.len())),
                );
                memory
            }
            Err(error) => {
                stage("guest-memory", Err(error.into()));
                return HvfSmokeReport { ok: false, stages };
            }
        };

        let vm = match Vm::create() {
            Ok(vm) => {
                stage("vm-create", Ok("created HVF VM".to_string()));
                vm
            }
            Err(error) => {
                stage("vm-create", Err(error.into()));
                return HvfSmokeReport { ok: false, stages };
            }
        };

        if !stage(
            "memory-map",
            vm.map_memory(
                memory.as_ptr(),
                self.guest_physical_address,
                memory.len(),
                HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC,
            )
            .map(|_| "mapped guest RAM".to_string())
            .map_err(Into::into),
        ) {
            return HvfSmokeReport { ok: false, stages };
        }

        let program = smoke_program();
        memory.write(0, &program);

        let vcpu = match Vcpu::create() {
            Ok(vcpu) => {
                stage("vcpu-create", Ok("created vCPU 0".to_string()));
                vcpu
            }
            Err(error) => {
                stage("vcpu-create", Err(error.into()));
                let _ = vm.unmap_memory(self.guest_physical_address, memory.len());
                return HvfSmokeReport { ok: false, stages };
            }
        };

        let data_gpa = self.guest_physical_address + 0x1000;
        let pc = self.guest_physical_address;
        let regs = vcpu
            .set_reg(HV_REG_X0, data_gpa)
            .and_then(|_| vcpu.set_reg(HV_REG_X1, 0x6865_6c6c))
            .and_then(|_| vcpu.set_reg(HV_REG_PC, pc))
            .and_then(|_| vcpu.set_reg(HV_REG_CPSR, 0x3c5));
        if !stage(
            "vcpu-registers",
            regs.map(|_| "initialized x0/x1/pc/cpsr".to_string())
                .map_err(Into::into),
        ) {
            let _ = vm.unmap_memory(self.guest_physical_address, memory.len());
            return HvfSmokeReport { ok: false, stages };
        }

        let _ = stage(
            "vcpu-run",
            vcpu.run()
                .map(|_| "vCPU exited after HVC".to_string())
                .map_err(Into::into),
        );
        let observed = memory.read_u32(0x1000);
        let ok = observed == 0x6865_6c6c;
        stages.push(HvfSmokeStage {
            name: "guest-write",
            ok,
            detail: format!("observed 0x{observed:08x}"),
        });
        if let Ok(pc_after) = vcpu.get_reg(HV_REG_PC) {
            stages.push(HvfSmokeStage {
                name: "pc-readback",
                ok: pc_after >= pc,
                detail: format!("pc=0x{pc_after:x}"),
            });
        }
        let _ = vm.unmap_memory(self.guest_physical_address, memory.len());

        HvfSmokeReport {
            ok: stages.iter().all(|stage| stage.ok),
            stages,
        }
    }
}

fn smoke_program() -> [u8; 12] {
    let str_w1_x0 = 0xb900_0001u32.to_le_bytes();
    let hvc = 0xd400_0002u32.to_le_bytes();
    let brk = 0xd420_0000u32.to_le_bytes();
    [
        str_w1_x0[0],
        str_w1_x0[1],
        str_w1_x0[2],
        str_w1_x0[3],
        hvc[0],
        hvc[1],
        hvc[2],
        hvc[3],
        brk[0],
        brk[1],
        brk[2],
        brk[3],
    ]
}

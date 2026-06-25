use std::collections::BTreeMap;

use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PsciError {
    #[error("PSCI requires at least one vCPU")]
    NoVcpus,
    #[error("PSCI CPU {0} is out of range")]
    CpuOutOfRange(u64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PsciFunction {
    Version = 0x8400_0000,
    CpuSuspend32 = 0x8400_0001,
    CpuOff = 0x8400_0002,
    CpuOn32 = 0x8400_0003,
    AffinityInfo32 = 0x8400_0004,
    MigrateInfoType = 0x8400_0006,
    SystemOff = 0x8400_0008,
    SystemReset = 0x8400_0009,
    Features = 0x8400_000a,
    CpuSuspend64 = 0xc400_0001,
    CpuOn64 = 0xc400_0003,
    AffinityInfo64 = 0xc400_0004,
}

impl TryFrom<u32> for PsciFunction {
    type Error = ();

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        Ok(match value {
            0x8400_0000 => Self::Version,
            0x8400_0001 => Self::CpuSuspend32,
            0x8400_0002 => Self::CpuOff,
            0x8400_0003 => Self::CpuOn32,
            0x8400_0004 => Self::AffinityInfo32,
            0x8400_0006 => Self::MigrateInfoType,
            0x8400_0008 => Self::SystemOff,
            0x8400_0009 => Self::SystemReset,
            0x8400_000a => Self::Features,
            0xc400_0001 => Self::CpuSuspend64,
            0xc400_0003 => Self::CpuOn64,
            0xc400_0004 => Self::AffinityInfo64,
            _ => return Err(()),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum PsciReturn {
    Success = 0,
    NotSupported = -1,
    InvalidParameters = -2,
    AlreadyOn = -4,
    OnPending = -5,
    NotPresent = -7,
    InvalidAddress = -9,
}

impl PsciReturn {
    pub fn register_value(self) -> u64 {
        self as i64 as u64
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PsciAction {
    None,
    CpuOn {
        target_cpu: u64,
        entry_point: u64,
        context_id: u64,
    },
    CpuOff,
    SystemOff,
    SystemReset,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PsciResponse {
    pub return_value: u64,
    pub action: PsciAction,
}

impl PsciResponse {
    fn status(status: PsciReturn) -> Self {
        Self {
            return_value: status.register_value(),
            action: PsciAction::None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessorState {
    Off,
    OnPending,
    On,
}

#[derive(Debug, Clone)]
pub struct PsciController {
    cpu_states: BTreeMap<u64, ProcessorState>,
}

impl PsciController {
    pub const VERSION: u64 = 0x0000_0002;

    pub fn new(cpu_count: u8) -> Result<Self, PsciError> {
        if cpu_count == 0 {
            return Err(PsciError::NoVcpus);
        }
        let cpu_states = (0..cpu_count)
            .map(|cpu| {
                (
                    u64::from(cpu),
                    if cpu == 0 {
                        ProcessorState::On
                    } else {
                        ProcessorState::Off
                    },
                )
            })
            .collect();
        Ok(Self { cpu_states })
    }

    pub fn state(&self, cpu: u64) -> Option<ProcessorState> {
        self.cpu_states.get(&cpu).copied()
    }

    pub fn mark_cpu_online(&mut self, cpu: u64) -> Result<(), PsciError> {
        let state = self
            .cpu_states
            .get_mut(&cpu)
            .ok_or(PsciError::CpuOutOfRange(cpu))?;
        *state = ProcessorState::On;
        Ok(())
    }

    pub fn handle(&mut self, function_id: u32, x1: u64, x2: u64, x3: u64) -> PsciResponse {
        let Ok(function) = PsciFunction::try_from(function_id) else {
            return PsciResponse::status(PsciReturn::NotSupported);
        };
        match function {
            PsciFunction::Version => PsciResponse {
                return_value: Self::VERSION,
                action: PsciAction::None,
            },
            PsciFunction::Features => {
                if PsciFunction::try_from(x1 as u32).is_ok() {
                    PsciResponse::status(PsciReturn::Success)
                } else {
                    PsciResponse::status(PsciReturn::NotSupported)
                }
            }
            PsciFunction::CpuOn32 | PsciFunction::CpuOn64 => self.cpu_on(x1, x2, x3),
            PsciFunction::AffinityInfo32 | PsciFunction::AffinityInfo64 => self.affinity_info(x1),
            PsciFunction::CpuOff => PsciResponse {
                return_value: PsciReturn::Success.register_value(),
                action: PsciAction::CpuOff,
            },
            PsciFunction::SystemOff => PsciResponse {
                return_value: PsciReturn::Success.register_value(),
                action: PsciAction::SystemOff,
            },
            PsciFunction::SystemReset => PsciResponse {
                return_value: PsciReturn::Success.register_value(),
                action: PsciAction::SystemReset,
            },
            PsciFunction::CpuSuspend32
            | PsciFunction::CpuSuspend64
            | PsciFunction::MigrateInfoType => PsciResponse::status(PsciReturn::NotSupported),
        }
    }

    fn cpu_on(&mut self, target_cpu: u64, entry_point: u64, context_id: u64) -> PsciResponse {
        let Some(logical_cpu) = self.logical_cpu(target_cpu) else {
            return PsciResponse::status(PsciReturn::NotPresent);
        };
        if entry_point == 0 || entry_point % 4 != 0 {
            return PsciResponse::status(PsciReturn::InvalidAddress);
        }
        match self
            .cpu_states
            .get(&logical_cpu)
            .copied()
            .unwrap_or(ProcessorState::Off)
        {
            ProcessorState::On => PsciResponse::status(PsciReturn::AlreadyOn),
            ProcessorState::OnPending => PsciResponse::status(PsciReturn::OnPending),
            ProcessorState::Off => {
                self.cpu_states
                    .insert(logical_cpu, ProcessorState::OnPending);
                PsciResponse {
                    return_value: PsciReturn::Success.register_value(),
                    action: PsciAction::CpuOn {
                        target_cpu: logical_cpu,
                        entry_point,
                        context_id,
                    },
                }
            }
        }
    }

    fn affinity_info(&self, target_cpu: u64) -> PsciResponse {
        let Some(logical_cpu) = self.logical_cpu(target_cpu) else {
            return PsciResponse::status(PsciReturn::NotPresent);
        };
        let value = match self.cpu_states.get(&logical_cpu).copied() {
            Some(ProcessorState::On) => 0,
            Some(ProcessorState::Off) => 1,
            Some(ProcessorState::OnPending) => 2,
            None => return PsciResponse::status(PsciReturn::NotPresent),
        };
        PsciResponse {
            return_value: value,
            action: PsciAction::None,
        }
    }

    fn logical_cpu(&self, target_cpu: u64) -> Option<u64> {
        if self.cpu_states.contains_key(&target_cpu) {
            return Some(target_cpu);
        }
        let affinity0 = target_cpu & 0xff;
        let affinity1 = (target_cpu >> 8) & 0xff;
        let affinity2 = (target_cpu >> 16) & 0xff;
        let affinity3 = (target_cpu >> 32) & 0xff;
        if affinity1 == 0
            && affinity2 == 0
            && affinity3 == 0
            && self.cpu_states.contains_key(&affinity0)
        {
            Some(affinity0)
        } else {
            None
        }
    }
}

use thiserror::Error;

use std::any::Any;

use crate::devices::virtio::VirtioMmioDevice;

pub trait MmioDevice: Send {
    fn as_any_mut(&mut self) -> &mut dyn Any;
    fn base(&self) -> u64;
    fn size(&self) -> u64;
    fn read(&mut self, offset: u64, size: u8) -> Result<u64, MmioError>;
    fn write(&mut self, offset: u64, value: u64, size: u8) -> Result<(), MmioError>;
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum MmioError {
    #[error("MMIO device size must be non-zero")]
    EmptyDevice,
    #[error("MMIO device range overflows at 0x{0:x}")]
    DeviceRangeOverflow(u64),
    #[error("MMIO device at 0x{new_base:x} overlaps existing device at 0x{existing_base:x}")]
    OverlappingDevice { new_base: u64, existing_base: u64 },
    #[error("unhandled MMIO address 0x{0:x}")]
    UnhandledAddress(u64),
    #[error("unsupported MMIO access size {0}")]
    UnsupportedAccessSize(u8),
}

#[derive(Default)]
pub struct MmioBus {
    devices: Vec<Box<dyn MmioDevice>>,
}

impl MmioBus {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, device: impl MmioDevice + Send + 'static) -> Result<(), MmioError> {
        let new_end = end_address(device.base(), device.size())?;
        for existing in &self.devices {
            let existing_end = end_address(existing.base(), existing.size())?;
            if ranges_overlap(device.base(), new_end, existing.base(), existing_end) {
                return Err(MmioError::OverlappingDevice {
                    new_base: device.base(),
                    existing_base: existing.base(),
                });
            }
        }
        self.devices.push(Box::new(device));
        Ok(())
    }

    pub fn read(&mut self, address: u64, size: u8) -> Result<u64, MmioError> {
        let (device, offset) = self.route_mut(address)?;
        device.read(offset, size)
    }

    pub fn write(&mut self, address: u64, value: u64, size: u8) -> Result<(), MmioError> {
        let (device, offset) = self.route_mut(address)?;
        device.write(offset, value, size)
    }

    pub fn virtio_mut_at(&mut self, address: u64) -> Option<&mut VirtioMmioDevice> {
        for device in &mut self.devices {
            let end = end_address(device.base(), device.size()).ok()?;
            if address >= device.base() && address < end {
                return device.as_any_mut().downcast_mut::<VirtioMmioDevice>();
            }
        }
        None
    }

    fn route_mut(&mut self, address: u64) -> Result<(&mut dyn MmioDevice, u64), MmioError> {
        for device in &mut self.devices {
            let end = end_address(device.base(), device.size())?;
            if address >= device.base() && address < end {
                let offset = address - device.base();
                return Ok((device.as_mut(), offset));
            }
        }
        Err(MmioError::UnhandledAddress(address))
    }
}

fn end_address(base: u64, size: u64) -> Result<u64, MmioError> {
    if size == 0 {
        return Err(MmioError::EmptyDevice);
    }
    base.checked_add(size)
        .filter(|end| *end > base)
        .ok_or(MmioError::DeviceRangeOverflow(base))
}

fn ranges_overlap(a_start: u64, a_end: u64, b_start: u64, b_end: u64) -> bool {
    a_start < b_end && b_start < a_end
}

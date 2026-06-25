use serde::Serialize;

use crate::arch::aarch64;
use crate::devices::bus::{MmioDevice, MmioError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum VirtioDeviceKind {
    Block,
    Net,
    Vsock,
    Balloon,
    Rng,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VirtioMmioDevicePlan {
    pub kind: VirtioDeviceKind,
    pub mmio_base: u64,
    pub irq: u32,
    pub queue_count: u16,
    pub features: u64,
}

impl VirtioMmioDevicePlan {
    pub fn new(kind: VirtioDeviceKind, slot: u32) -> Self {
        let queue_count = match kind {
            VirtioDeviceKind::Net => 2,
            VirtioDeviceKind::Vsock => 3,
            VirtioDeviceKind::Balloon => 5,
            VirtioDeviceKind::Block | VirtioDeviceKind::Rng => 1,
        };
        Self {
            kind,
            mmio_base: aarch64::VIRTIO_BASE + aarch64::VIRTIO_MMIO_STRIDE * u64::from(slot),
            irq: aarch64::IRQ_BASE + slot,
            queue_count,
            features: common_features_for(kind),
        }
    }
}

pub const MAGIC_VALUE: u32 = 0x7472_6976;
pub const VERSION: u32 = 2;
pub const VENDOR_ID: u32 = 0x434a_4554;
pub const FEATURE_VERSION_1: u64 = 1 << 32;
pub const FEATURE_INDIRECT_DESC: u64 = 1 << 28;
pub const FEATURE_EVENT_IDX: u64 = 1 << 29;
pub const NET_FEATURE_MAC: u64 = 1 << 5;
pub const NET_FEATURE_MRG_RXBUF: u64 = 1 << 15;
pub const NET_FEATURE_STATUS: u64 = 1 << 16;
pub const BALLOON_FEATURE_FREE_PAGE_HINT: u64 = 1 << 3;
pub const BALLOON_FEATURE_PAGE_POISON: u64 = 1 << 4;
pub const BALLOON_FEATURE_PAGE_REPORTING: u64 = 1 << 5;
pub const STATUS_DRIVER_OK: u32 = 1 << 2;
pub const STATUS_FEATURES_OK: u32 = 1 << 3;
pub const STATUS_FAILED: u32 = 1 << 7;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VirtioDeviceId {
    Net = 1,
    Block = 2,
    Rng = 4,
    Balloon = 5,
    Vsock = 19,
}

impl From<VirtioDeviceKind> for VirtioDeviceId {
    fn from(kind: VirtioDeviceKind) -> Self {
        match kind {
            VirtioDeviceKind::Block => Self::Block,
            VirtioDeviceKind::Net => Self::Net,
            VirtioDeviceKind::Vsock => Self::Vsock,
            VirtioDeviceKind::Balloon => Self::Balloon,
            VirtioDeviceKind::Rng => Self::Rng,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct VirtioQueueState {
    pub size: u32,
    pub ready: bool,
    pub descriptor_address: u64,
    pub driver_address: u64,
    pub device_address: u64,
}

impl VirtioQueueState {
    fn new(size: u32) -> Self {
        Self {
            size,
            ready: false,
            descriptor_address: 0,
            driver_address: 0,
            device_address: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct VirtioMmioDevice {
    pub plan: VirtioMmioDevicePlan,
    pub device_id: u32,
    pub device_status: u32,
    pub interrupt_status: u32,
    pub driver_features: u64,
    pub selected_queue: u32,
    selected_device_features_page: u32,
    selected_driver_features_page: u32,
    configuration: Vec<u8>,
    queues: Vec<VirtioQueueState>,
    notified_queues: Vec<u32>,
}

impl VirtioMmioDevice {
    pub fn new(plan: VirtioMmioDevicePlan, configuration: Vec<u8>) -> Self {
        let kind = plan.kind;
        let queue_count = usize::from(plan.queue_count.max(1));
        Self {
            plan,
            device_id: VirtioDeviceId::from(kind) as u32,
            device_status: 0,
            interrupt_status: 0,
            driver_features: 0,
            selected_queue: 0,
            selected_device_features_page: 0,
            selected_driver_features_page: 0,
            configuration,
            queues: vec![VirtioQueueState::new(256); queue_count],
            notified_queues: Vec::new(),
        }
    }

    pub fn queue_state(&self, index: u32) -> Option<VirtioQueueState> {
        self.queues.get(index as usize).copied()
    }

    pub fn queue_ready(&self, index: u32) -> bool {
        self.queue_state(index).is_some_and(|queue| queue.ready)
    }

    pub fn driver_ok(&self) -> bool {
        self.device_status & STATUS_DRIVER_OK != 0
    }

    pub fn features_ok(&self) -> bool {
        self.device_status & STATUS_FEATURES_OK != 0
    }

    pub fn negotiated(&self, feature: u64) -> bool {
        self.features_ok()
            && self.plan.features & feature != 0
            && self.driver_features & feature != 0
    }

    pub fn unsupported_driver_features(&self) -> u64 {
        self.driver_features & !self.plan.features
    }

    pub fn drain_notifications(&mut self) -> Vec<u32> {
        std::mem::take(&mut self.notified_queues)
    }

    pub fn mark_queue_used(&mut self) {
        self.interrupt_status |= 1;
    }

    pub fn mark_configuration_changed(&mut self) {
        self.interrupt_status |= 2;
    }

    pub fn update_configuration(&mut self, configuration: Vec<u8>, notify_driver: bool) {
        self.configuration = configuration;
        if notify_driver {
            self.mark_configuration_changed();
        }
    }

    pub fn configuration_bytes(&self) -> &[u8] {
        &self.configuration
    }

    fn current_queue(&self) -> Option<&VirtioQueueState> {
        self.queues.get(self.selected_queue as usize)
    }

    fn current_queue_mut(&mut self) -> Option<&mut VirtioQueueState> {
        self.queues.get_mut(self.selected_queue as usize)
    }

    fn reset(&mut self) {
        self.selected_queue = 0;
        self.selected_device_features_page = 0;
        self.selected_driver_features_page = 0;
        self.device_status = 0;
        self.interrupt_status = 0;
        self.driver_features = 0;
        self.notified_queues.clear();
        for queue in &mut self.queues {
            let size = queue.size;
            *queue = VirtioQueueState::new(size);
        }
    }
}

impl MmioDevice for VirtioMmioDevice {
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn base(&self) -> u64 {
        self.plan.mmio_base
    }

    fn size(&self) -> u64 {
        aarch64::VIRTIO_MMIO_STRIDE
    }

    fn read(&mut self, offset: u64, size: u8) -> Result<u64, MmioError> {
        if offset >= 0x100 {
            return read_config(&self.configuration, offset - 0x100, size);
        }
        if size != 4 {
            return Err(MmioError::UnsupportedAccessSize(size));
        }
        let value = match offset {
            0x000 => MAGIC_VALUE,
            0x004 => VERSION,
            0x008 => self.device_id,
            0x00c => VENDOR_ID,
            0x010 => feature_page(self.plan.features, self.selected_device_features_page),
            0x034 => self.current_queue().map_or(0, |queue| queue.size),
            0x038 => self.current_queue().map_or(0, |queue| queue.size),
            0x044 => self.current_queue().is_some_and(|queue| queue.ready) as u32,
            0x060 => self.interrupt_status,
            0x070 => self.device_status,
            0x080 => self
                .current_queue()
                .map_or(0, |queue| queue.descriptor_address as u32),
            0x084 => self
                .current_queue()
                .map_or(0, |queue| (queue.descriptor_address >> 32) as u32),
            0x090 => self
                .current_queue()
                .map_or(0, |queue| queue.driver_address as u32),
            0x094 => self
                .current_queue()
                .map_or(0, |queue| (queue.driver_address >> 32) as u32),
            0x0a0 => self
                .current_queue()
                .map_or(0, |queue| queue.device_address as u32),
            0x0a4 => self
                .current_queue()
                .map_or(0, |queue| (queue.device_address >> 32) as u32),
            0x0fc => 0,
            _ => 0,
        };
        Ok(u64::from(value))
    }

    fn write(&mut self, offset: u64, value: u64, size: u8) -> Result<(), MmioError> {
        if offset >= 0x100 {
            return write_config(&mut self.configuration, offset - 0x100, value, size);
        }
        if size != 4 {
            return Err(MmioError::UnsupportedAccessSize(size));
        }
        let value32 = value as u32;
        match offset {
            0x014 => self.selected_device_features_page = value32,
            0x020 => set_feature_page(
                value32,
                self.selected_driver_features_page,
                &mut self.driver_features,
            ),
            0x024 => self.selected_driver_features_page = value32,
            0x030 => self.selected_queue = value32,
            0x038 => {
                if let Some(queue) = self.current_queue_mut() {
                    queue.size = value32;
                }
            }
            0x044 => {
                if let Some(queue) = self.current_queue_mut() {
                    queue.ready = value32 != 0;
                }
            }
            0x050 => self.notified_queues.push(value32),
            0x064 => self.interrupt_status &= !value32,
            0x070 => {
                if value32 == 0 {
                    self.reset();
                } else if value32 & STATUS_FEATURES_OK != 0
                    && self.unsupported_driver_features() != 0
                {
                    self.device_status = (value32 & !STATUS_FEATURES_OK) | STATUS_FAILED;
                } else {
                    self.device_status = value32;
                }
            }
            0x080 => {
                if let Some(queue) = self.current_queue_mut() {
                    queue.descriptor_address = replace_low(queue.descriptor_address, value32);
                }
            }
            0x084 => {
                if let Some(queue) = self.current_queue_mut() {
                    queue.descriptor_address = replace_high(queue.descriptor_address, value32);
                }
            }
            0x090 => {
                if let Some(queue) = self.current_queue_mut() {
                    queue.driver_address = replace_low(queue.driver_address, value32);
                }
            }
            0x094 => {
                if let Some(queue) = self.current_queue_mut() {
                    queue.driver_address = replace_high(queue.driver_address, value32);
                }
            }
            0x0a0 => {
                if let Some(queue) = self.current_queue_mut() {
                    queue.device_address = replace_low(queue.device_address, value32);
                }
            }
            0x0a4 => {
                if let Some(queue) = self.current_queue_mut() {
                    queue.device_address = replace_high(queue.device_address, value32);
                }
            }
            _ => {}
        }
        Ok(())
    }
}

pub fn default_device_plan(
    include_data: bool,
    include_swap: bool,
    include_balloon: bool,
) -> Vec<VirtioMmioDevicePlan> {
    let mut plans = vec![VirtioMmioDevicePlan::new(VirtioDeviceKind::Block, 0)];
    if include_data {
        plans.push(VirtioMmioDevicePlan::new(VirtioDeviceKind::Block, 1));
    }
    if include_swap {
        plans.push(VirtioMmioDevicePlan::new(VirtioDeviceKind::Block, 2));
    }
    plans.push(VirtioMmioDevicePlan::new(VirtioDeviceKind::Net, 3));
    plans.push(VirtioMmioDevicePlan::new(VirtioDeviceKind::Vsock, 4));
    if include_balloon {
        plans.push(VirtioMmioDevicePlan::new(VirtioDeviceKind::Balloon, 5));
    }
    plans.push(VirtioMmioDevicePlan::new(VirtioDeviceKind::Rng, 6));
    plans
}

fn common_features_for(kind: VirtioDeviceKind) -> u64 {
    match kind {
        VirtioDeviceKind::Block | VirtioDeviceKind::Vsock => FEATURE_VERSION_1,
        VirtioDeviceKind::Net => FEATURE_VERSION_1 | NET_FEATURE_MAC | NET_FEATURE_STATUS,
        VirtioDeviceKind::Balloon => FEATURE_VERSION_1 | BALLOON_FEATURE_PAGE_REPORTING,
        VirtioDeviceKind::Rng => FEATURE_VERSION_1 | FEATURE_INDIRECT_DESC | FEATURE_EVENT_IDX,
    }
}

fn feature_page(features: u64, page: u32) -> u32 {
    if page < 2 {
        (features >> (u64::from(page) * 32)) as u32
    } else {
        0
    }
}

fn set_feature_page(value: u32, page: u32, features: &mut u64) {
    if page >= 2 {
        return;
    }
    let shift = u64::from(page) * 32;
    let mask = u64::from(u32::MAX) << shift;
    *features = (*features & !mask) | (u64::from(value) << shift);
}

fn replace_low(original: u64, low: u32) -> u64 {
    (original & 0xffff_ffff_0000_0000) | u64::from(low)
}

fn replace_high(original: u64, high: u32) -> u64 {
    (original & 0x0000_0000_ffff_ffff) | (u64::from(high) << 32)
}

fn read_config(config: &[u8], offset: u64, size: u8) -> Result<u64, MmioError> {
    if ![1, 2, 4].contains(&size) {
        return Err(MmioError::UnsupportedAccessSize(size));
    }
    let start = offset as usize;
    let mut value = 0u64;
    for byte_offset in 0..usize::from(size) {
        if let Some(byte) = config.get(start + byte_offset) {
            value |= u64::from(*byte) << (byte_offset * 8);
        }
    }
    Ok(value)
}

fn write_config(config: &mut [u8], offset: u64, value: u64, size: u8) -> Result<(), MmioError> {
    if ![1, 2, 4].contains(&size) {
        return Err(MmioError::UnsupportedAccessSize(size));
    }
    let start = offset as usize;
    if start >= config.len() {
        return Ok(());
    }
    for byte_offset in 0..usize::from(size).min(config.len() - start) {
        config[start + byte_offset] = (value >> (byte_offset * 8)) as u8;
    }
    Ok(())
}

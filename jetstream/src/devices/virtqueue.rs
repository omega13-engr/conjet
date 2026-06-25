use thiserror::Error;

use crate::devices::virtio::{VirtioMmioDevice, VirtioQueueState};
use crate::vmm::memory::{GuestMemory, GuestMemoryError};

const DESC_SIZE: usize = 16;
const DESC_F_NEXT: u16 = 1;
const DESC_F_WRITE: u16 = 2;
const DESC_F_INDIRECT: u16 = 4;

#[derive(Debug, Error)]
pub enum QueueError {
    #[error("virtio queue is not ready")]
    NotReady,
    #[error("virtio queue addresses are incomplete")]
    IncompleteAddresses,
    #[error("virtio queue size is invalid")]
    InvalidSize,
    #[error("virtio available ring advanced by {0}, larger than queue size")]
    AvailableIndexJump(u16),
    #[error("virtio descriptor {0} is out of bounds")]
    DescriptorOutOfBounds(u16),
    #[error("virtio descriptor chain loops at {0}")]
    DescriptorLoop(u16),
    #[error("virtio descriptor chain exceeds queue size")]
    ChainTooLong,
    #[error("virtio indirect descriptor is invalid")]
    InvalidIndirectDescriptor,
    #[error(transparent)]
    Memory(#[from] GuestMemoryError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueueDescriptor {
    pub address: u64,
    pub length: u32,
    pub flags: u16,
    pub next: u16,
}

impl QueueDescriptor {
    pub fn is_write_only(&self) -> bool {
        self.flags & DESC_F_WRITE != 0
    }

    fn has_next(&self) -> bool {
        self.flags & DESC_F_NEXT != 0
    }

    fn is_indirect(&self) -> bool {
        self.flags & DESC_F_INDIRECT != 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DescriptorChain {
    pub head_index: u16,
    pub descriptors: Vec<QueueDescriptor>,
}

impl DescriptorChain {
    pub fn readable_descriptors(&self) -> impl Iterator<Item = &QueueDescriptor> {
        self.descriptors
            .iter()
            .filter(|descriptor| !descriptor.is_write_only())
    }

    pub fn writable_descriptors(&self) -> impl Iterator<Item = &QueueDescriptor> {
        self.descriptors
            .iter()
            .filter(|descriptor| descriptor.is_write_only())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UsedElement {
    pub id: u32,
    pub length: u32,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SplitQueueExecutor {
    pub last_available_index: u16,
    pub used_index: u16,
}

impl SplitQueueExecutor {
    pub fn peek_available_chains(
        &self,
        queue: VirtioQueueState,
        memory: &GuestMemory,
        guest_base: u64,
        max_chains: Option<usize>,
    ) -> Result<Vec<DescriptorChain>, QueueError> {
        self.available_chains(queue, memory, guest_base, max_chains)
    }

    pub fn drain_available_chains(
        &mut self,
        queue: VirtioQueueState,
        memory: &GuestMemory,
        guest_base: u64,
        max_chains: Option<usize>,
    ) -> Result<Vec<DescriptorChain>, QueueError> {
        let chains = self.available_chains(queue, memory, guest_base, max_chains)?;
        self.last_available_index = self.last_available_index.wrapping_add(chains.len() as u16);
        Ok(chains)
    }

    pub fn publish_used(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
        used: &[UsedElement],
    ) -> Result<(), QueueError> {
        validate(queue)?;
        let old_used_index = self.used_index;
        for element in used {
            let ring_slot = self.used_index % queue.size as u16;
            let offset = queue.device_address + 4 + u64::from(ring_slot) * 8;
            memory.write_le_u32(guest_base, offset, element.id)?;
            memory.write_le_u32(guest_base, offset + 4, element.length)?;
            self.used_index = self.used_index.wrapping_add(1);
        }
        memory.write_le_u16(guest_base, queue.device_address + 2, self.used_index)?;
        if old_used_index != self.used_index && should_notify_used(queue, memory, guest_base)? {
            transport.mark_queue_used();
        }
        Ok(())
    }

    pub fn drain_and_publish<F>(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
        max_chains: Option<usize>,
        mut complete: F,
    ) -> Result<Vec<UsedElement>, QueueError>
    where
        F: FnMut(&DescriptorChain) -> Result<UsedElement, QueueError>,
    {
        let chains = self.drain_available_chains(queue, memory, guest_base, max_chains)?;
        let mut used = Vec::with_capacity(chains.len());
        for chain in &chains {
            used.push(complete(chain)?);
        }
        self.publish_used(queue, transport, memory, guest_base, &used)?;
        Ok(used)
    }

    fn available_chains(
        &self,
        queue: VirtioQueueState,
        memory: &GuestMemory,
        guest_base: u64,
        max_chains: Option<usize>,
    ) -> Result<Vec<DescriptorChain>, QueueError> {
        validate(queue)?;
        let available_index = memory.read_le_u16(guest_base, queue.driver_address + 2)?;
        let available_count = available_index.wrapping_sub(self.last_available_index);
        if u32::from(available_count) > queue.size {
            return Err(QueueError::AvailableIndexJump(available_count));
        }
        let chains_to_read = usize::from(available_count).min(max_chains.unwrap_or(usize::MAX));
        if chains_to_read == 0 {
            return Ok(Vec::new());
        }
        let table = memory.read_at(
            guest_base,
            queue.descriptor_address,
            queue.size as usize * DESC_SIZE,
        )?;
        let mut chains = Vec::with_capacity(chains_to_read);
        for offset in 0..chains_to_read {
            let ring_slot =
                self.last_available_index.wrapping_add(offset as u16) % queue.size as u16;
            let head_index = memory.read_le_u16(
                guest_base,
                queue.driver_address + 4 + u64::from(ring_slot) * 2,
            )?;
            chains.push(parse_chain(
                head_index, &table, queue.size, memory, guest_base,
            )?);
        }
        Ok(chains)
    }
}

pub fn read_descriptors(
    memory: &GuestMemory,
    guest_base: u64,
    descriptors: impl IntoIterator<Item = QueueDescriptor>,
) -> Result<Vec<u8>, QueueError> {
    let mut out = Vec::new();
    for descriptor in descriptors {
        let mut bytes =
            memory.read_at(guest_base, descriptor.address, descriptor.length as usize)?;
        out.append(&mut bytes);
    }
    Ok(out)
}

pub fn write_descriptors(
    memory: &GuestMemory,
    guest_base: u64,
    descriptors: impl IntoIterator<Item = QueueDescriptor>,
    data: &[u8],
) -> Result<usize, QueueError> {
    let mut offset = 0usize;
    for descriptor in descriptors {
        if offset >= data.len() {
            break;
        }
        let count = (descriptor.length as usize).min(data.len() - offset);
        memory.write_at(
            guest_base,
            descriptor.address,
            &data[offset..offset + count],
        )?;
        offset += count;
    }
    Ok(offset)
}

fn validate(queue: VirtioQueueState) -> Result<(), QueueError> {
    if !queue.ready {
        return Err(QueueError::NotReady);
    }
    if queue.size == 0 || queue.size > u32::from(u16::MAX) {
        return Err(QueueError::InvalidSize);
    }
    if queue.descriptor_address == 0 || queue.driver_address == 0 || queue.device_address == 0 {
        return Err(QueueError::IncompleteAddresses);
    }
    Ok(())
}

fn parse_chain(
    head_index: u16,
    table: &[u8],
    queue_size: u32,
    memory: &GuestMemory,
    guest_base: u64,
) -> Result<DescriptorChain, QueueError> {
    if u32::from(head_index) >= queue_size {
        return Err(QueueError::DescriptorOutOfBounds(head_index));
    }
    let mut descriptors = Vec::new();
    let mut seen = Vec::new();
    let mut index = head_index;
    loop {
        if u32::from(index) >= queue_size {
            return Err(QueueError::DescriptorOutOfBounds(index));
        }
        if seen.contains(&index) {
            return Err(QueueError::DescriptorLoop(index));
        }
        seen.push(index);
        let descriptor = parse_descriptor(table, index)?;
        if descriptor.is_indirect() {
            if !descriptors.is_empty() || descriptor.has_next() {
                return Err(QueueError::InvalidIndirectDescriptor);
            }
            return Ok(DescriptorChain {
                head_index,
                descriptors: parse_indirect(descriptor, queue_size, memory, guest_base)?,
            });
        }
        descriptors.push(descriptor);
        if !descriptor.has_next() {
            return Ok(DescriptorChain {
                head_index,
                descriptors,
            });
        }
        if descriptors.len() >= queue_size as usize {
            return Err(QueueError::ChainTooLong);
        }
        index = descriptor.next;
    }
}

fn parse_indirect(
    descriptor: QueueDescriptor,
    queue_size: u32,
    memory: &GuestMemory,
    guest_base: u64,
) -> Result<Vec<QueueDescriptor>, QueueError> {
    if descriptor.length == 0 || descriptor.length as usize % DESC_SIZE != 0 {
        return Err(QueueError::InvalidIndirectDescriptor);
    }
    let table_count = descriptor.length as usize / DESC_SIZE;
    if table_count == 0 || table_count > queue_size as usize {
        return Err(QueueError::InvalidIndirectDescriptor);
    }
    let table = memory.read_at(guest_base, descriptor.address, descriptor.length as usize)?;
    let mut descriptors = Vec::new();
    let mut seen = Vec::new();
    let mut index = 0u16;
    loop {
        if usize::from(index) >= table_count {
            return Err(QueueError::DescriptorOutOfBounds(index));
        }
        if seen.contains(&index) {
            return Err(QueueError::DescriptorLoop(index));
        }
        seen.push(index);
        let next = parse_descriptor(&table, index)?;
        if next.is_indirect() {
            return Err(QueueError::InvalidIndirectDescriptor);
        }
        descriptors.push(next);
        if !next.has_next() {
            return Ok(descriptors);
        }
        if descriptors.len() >= table_count {
            return Err(QueueError::ChainTooLong);
        }
        index = next.next;
    }
}

fn parse_descriptor(table: &[u8], index: u16) -> Result<QueueDescriptor, QueueError> {
    let offset = usize::from(index) * DESC_SIZE;
    if offset + DESC_SIZE > table.len() {
        return Err(QueueError::DescriptorOutOfBounds(index));
    }
    Ok(QueueDescriptor {
        address: u64::from_le_bytes(table[offset..offset + 8].try_into().unwrap()),
        length: u32::from_le_bytes(table[offset + 8..offset + 12].try_into().unwrap()),
        flags: u16::from_le_bytes(table[offset + 12..offset + 14].try_into().unwrap()),
        next: u16::from_le_bytes(table[offset + 14..offset + 16].try_into().unwrap()),
    })
}

fn should_notify_used(
    queue: VirtioQueueState,
    memory: &GuestMemory,
    guest_base: u64,
) -> Result<bool, QueueError> {
    let available_flags = memory.read_le_u16(guest_base, queue.driver_address)?;
    Ok(available_flags & 0x1 == 0)
}

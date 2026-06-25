use std::fs::{File, OpenOptions};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::devices::virtio::{VirtioMmioDevice, VirtioQueueState};
use crate::devices::virtqueue::{
    read_descriptors, write_descriptors, DescriptorChain, QueueError, SplitQueueExecutor,
    UsedElement,
};
use crate::vmm::memory::GuestMemory;

const SECTOR_SIZE: u64 = 512;

#[derive(Debug, Error)]
pub enum BlockError {
    #[error("block image {path} has invalid capacity {bytes} bytes")]
    InvalidCapacity { path: PathBuf, bytes: u64 },
    #[error("virtio-blk chain is missing request header")]
    MissingHeader,
    #[error("virtio-blk chain is missing status descriptor")]
    MissingStatus,
    #[error("block access exceeds image capacity")]
    OutOfRange,
    #[error(transparent)]
    Queue(#[from] QueueError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
enum RequestType {
    In = 0,
    Out = 1,
    Flush = 4,
    GetId = 8,
}

#[derive(Debug, Clone, Copy)]
struct RequestHeader {
    request_type: u32,
    sector: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
enum Status {
    Ok = 0,
    IoError = 1,
    Unsupported = 2,
}

#[derive(Debug)]
pub struct RawBlockDevice {
    file: File,
    identifier: String,
    read_only: bool,
    capacity_bytes: u64,
}

impl RawBlockDevice {
    pub fn open(
        path: impl AsRef<Path>,
        identifier: impl Into<String>,
        read_only: bool,
    ) -> Result<Self, BlockError> {
        let path = path.as_ref().to_path_buf();
        let file = OpenOptions::new()
            .read(true)
            .write(!read_only)
            .open(&path)?;
        let capacity_bytes = file.metadata()?.len();
        if capacity_bytes < SECTOR_SIZE {
            return Err(BlockError::InvalidCapacity {
                path,
                bytes: capacity_bytes,
            });
        }
        Ok(Self {
            file,
            identifier: identifier.into(),
            read_only,
            capacity_bytes,
        })
    }

    pub fn configuration(&self) -> Vec<u8> {
        (self.capacity_bytes / SECTOR_SIZE).to_le_bytes().to_vec()
    }

    fn perform(&self, header: RequestHeader, payload: &[u8], read_len: usize) -> (Status, Vec<u8>) {
        match header.request_type {
            x if x == RequestType::In as u32 => self.read(header.sector, read_len),
            x if x == RequestType::Out as u32 => self.write(header.sector, payload),
            x if x == RequestType::Flush as u32 => self.flush(),
            x if x == RequestType::GetId as u32 => (
                Status::Ok,
                self.identifier.as_bytes()[..self.identifier.len().min(read_len)].to_vec(),
            ),
            _ => (Status::Unsupported, Vec::new()),
        }
    }

    fn read(&self, sector: u64, len: usize) -> (Status, Vec<u8>) {
        let Ok(offset) = self.byte_offset(sector, len as u64) else {
            return (Status::IoError, Vec::new());
        };
        let mut out = vec![0u8; len];
        match self.file.read_at(&mut out, offset) {
            Ok(count) if count == len => (Status::Ok, out),
            Ok(_) => (Status::IoError, Vec::new()),
            Err(_) => (Status::IoError, Vec::new()),
        }
    }

    fn write(&self, sector: u64, payload: &[u8]) -> (Status, Vec<u8>) {
        if self.read_only {
            return (Status::Unsupported, Vec::new());
        }
        let Ok(offset) = self.byte_offset(sector, payload.len() as u64) else {
            return (Status::IoError, Vec::new());
        };
        match self.file.write_at(payload, offset) {
            Ok(count) if count == payload.len() => (Status::Ok, Vec::new()),
            Ok(_) => (Status::IoError, Vec::new()),
            Err(_) => (Status::IoError, Vec::new()),
        }
    }

    fn flush(&self) -> (Status, Vec<u8>) {
        if self.read_only {
            return (Status::Ok, Vec::new());
        }
        match self.file.sync_data() {
            Ok(()) => (Status::Ok, Vec::new()),
            Err(_) => (Status::IoError, Vec::new()),
        }
    }

    fn byte_offset(&self, sector: u64, len: u64) -> Result<u64, BlockError> {
        let offset = sector
            .checked_mul(SECTOR_SIZE)
            .ok_or(BlockError::OutOfRange)?;
        let end = offset.checked_add(len).ok_or(BlockError::OutOfRange)?;
        if end > self.capacity_bytes {
            return Err(BlockError::OutOfRange);
        }
        Ok(offset)
    }
}

#[derive(Debug)]
pub struct BlockQueueHandler {
    pub executor: SplitQueueExecutor,
    pub device: RawBlockDevice,
}

impl BlockQueueHandler {
    pub fn new(device: RawBlockDevice) -> Self {
        Self {
            executor: SplitQueueExecutor::default(),
            device,
        }
    }

    pub fn handle_available(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, BlockError> {
        let device = &self.device;
        Ok(self.executor.drain_and_publish(
            queue,
            transport,
            memory,
            guest_base,
            None,
            |chain| complete_chain(chain, device, memory, guest_base),
        )?)
    }
}

fn complete_chain(
    chain: &DescriptorChain,
    device: &RawBlockDevice,
    memory: &GuestMemory,
    guest_base: u64,
) -> Result<UsedElement, QueueError> {
    let readable: Vec<_> = chain.readable_descriptors().copied().collect();
    let writable: Vec<_> = chain.writable_descriptors().copied().collect();
    let Some(header_descriptor) = readable.first() else {
        return Err(QueueError::InvalidSize);
    };
    let Some(status_descriptor) = writable.last() else {
        return Err(QueueError::InvalidSize);
    };
    let header_bytes = memory.read_at(
        guest_base,
        header_descriptor.address,
        header_descriptor.length as usize,
    )?;
    let header = parse_header(&header_bytes).map_err(|_| QueueError::InvalidSize)?;
    let payload = read_descriptors(memory, guest_base, readable.into_iter().skip(1))?;
    let writable_payload: Vec<_> = writable[..writable.len().saturating_sub(1)].to_vec();
    let writable_len = writable_payload.iter().map(|d| d.length as usize).sum();
    let (status, response) = device.perform(header, &payload, writable_len);
    let copied = write_descriptors(memory, guest_base, writable_payload, &response)?;
    memory.write_at(guest_base, status_descriptor.address, &[status as u8])?;
    Ok(UsedElement {
        id: u32::from(chain.head_index),
        length: copied as u32 + 1,
    })
}

fn parse_header(bytes: &[u8]) -> Result<RequestHeader, BlockError> {
    if bytes.len() < 16 {
        return Err(BlockError::MissingHeader);
    }
    Ok(RequestHeader {
        request_type: u32::from_le_bytes(bytes[0..4].try_into().unwrap()),
        sector: u64::from_le_bytes(bytes[8..16].try_into().unwrap()),
    })
}

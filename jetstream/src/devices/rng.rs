use thiserror::Error;

use crate::devices::virtio::{VirtioMmioDevice, VirtioQueueState};
use crate::devices::virtqueue::{write_descriptors, QueueError, SplitQueueExecutor, UsedElement};
use crate::vmm::memory::GuestMemory;

// Virtio permits a partial buffer completion. Keep each host entropy request and
// the total work per notification bounded independently of guest buffer lengths.
const MAX_REQUEST_BYTES: usize = 256;
const MAX_QUEUE_SIZE: u32 = 256;

#[derive(Debug, Error)]
pub enum RngError {
    #[error("virtio-rng requires nonempty device-writable buffers")]
    InvalidBuffer,
    #[error(transparent)]
    Queue(#[from] QueueError),
    #[error("host entropy source failed: {0}")]
    Entropy(#[from] std::io::Error),
}

#[derive(Debug, Default)]
pub struct RngQueueHandler {
    executor: SplitQueueExecutor,
}

impl RngQueueHandler {
    pub fn reset(&mut self) {
        self.executor = SplitQueueExecutor::default();
    }

    pub fn handle_available(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, RngError> {
        self.handle_with_entropy(queue, transport, memory, guest_base, host_entropy)
    }

    fn handle_with_entropy(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
        mut fill: impl FnMut(&mut [u8]) -> std::io::Result<()>,
    ) -> Result<Vec<UsedElement>, RngError> {
        if !transport.driver_ok() || !queue.ready {
            return Ok(Vec::new());
        }
        if queue.size > MAX_QUEUE_SIZE || !queue.size.is_power_of_two() {
            return Err(QueueError::InvalidSize.into());
        }
        let chains = self
            .executor
            .peek_available_chains(queue, memory, guest_base, None)?;
        let mut used = Vec::with_capacity(chains.len());
        let mut bytes = [0u8; MAX_REQUEST_BYTES];
        for chain in chains {
            if chain
                .descriptors
                .iter()
                .any(|descriptor| !descriptor.is_write_only())
            {
                return Err(RngError::InvalidBuffer);
            }
            let length = chain.descriptors.iter().fold(0usize, |length, descriptor| {
                length
                    .saturating_add(descriptor.length as usize)
                    .min(MAX_REQUEST_BYTES)
            });
            if length == 0 {
                return Err(RngError::InvalidBuffer);
            }
            fill(&mut bytes[..length])?;
            let written =
                write_descriptors(memory, guest_base, chain.descriptors, &bytes[..length])?;
            used.push(UsedElement {
                id: u32::from(chain.head_index),
                length: written as u32,
            });
        }
        self.executor
            .publish_used(queue, transport, memory, guest_base, &used)?;
        self.executor.last_available_index = self
            .executor
            .last_available_index
            .wrapping_add(used.len() as u16);
        Ok(used)
    }
}

fn host_entropy(bytes: &mut [u8]) -> std::io::Result<()> {
    // getentropy accepts at most 256 bytes and supplies OS cryptographic random
    // data. Never fall back to predictable data or expose a failed request.
    if unsafe { libc::getentropy(bytes.as_mut_ptr().cast(), bytes.len()) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devices::virtio::{VirtioDeviceKind, VirtioMmioDevicePlan, STATUS_DRIVER_OK};

    const BASE: u64 = 0x4000_0000;

    fn fixture(length: u32, flags: u16) -> (GuestMemory, VirtioMmioDevice, VirtioQueueState) {
        let memory = GuestMemory::anonymous(16384).unwrap();
        let mut transport =
            VirtioMmioDevice::new(VirtioMmioDevicePlan::new(VirtioDeviceKind::Rng, 6), vec![]);
        transport.device_status = STATUS_DRIVER_OK;
        let queue = VirtioQueueState {
            size: 8,
            ready: true,
            descriptor_address: BASE + 0x100,
            driver_address: BASE + 0x200,
            device_address: BASE + 0x300,
        };
        memory
            .write_at(
                BASE,
                queue.descriptor_address,
                &(BASE + 0x1000).to_le_bytes(),
            )
            .unwrap();
        memory
            .write_le_u32(BASE, queue.descriptor_address + 8, length)
            .unwrap();
        memory
            .write_le_u16(BASE, queue.descriptor_address + 12, flags)
            .unwrap();
        memory
            .write_le_u16(BASE, queue.driver_address + 2, 1)
            .unwrap();
        (memory, transport, queue)
    }

    #[test]
    fn completes_entropy_requests_and_does_not_repeat_completed_buffers() {
        let (memory, mut transport, queue) = fixture(64, 2);
        let mut handler = RngQueueHandler::default();
        let used = handler
            .handle_with_entropy(queue, &mut transport, &memory, BASE, |bytes| {
                bytes.fill(0x5a);
                Ok(())
            })
            .unwrap();
        assert_eq!(used, [UsedElement { id: 0, length: 64 }]);
        assert_eq!(
            memory.read_at(BASE, BASE + 0x1000, 64).unwrap(),
            vec![0x5a; 64]
        );
        assert_eq!(
            memory.read_le_u16(BASE, queue.device_address + 2).unwrap(),
            1
        );
        assert_eq!(transport.interrupt_status, 1);
        assert!(handler
            .handle_with_entropy(queue, &mut transport, &memory, BASE, |_| panic!(
                "completed buffer reused"
            ))
            .unwrap()
            .is_empty());
        handler.reset();
        assert_eq!(
            handler
                .handle_with_entropy(queue, &mut transport, &memory, BASE, |bytes| {
                    bytes.fill(0xa5);
                    Ok(())
                })
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn caps_large_guest_buffers_and_preserves_the_unused_tail() {
        let (memory, mut transport, queue) = fixture(u32::MAX, 2);
        let mut handler = RngQueueHandler::default();
        let used = handler
            .handle_with_entropy(queue, &mut transport, &memory, BASE, |bytes| {
                assert_eq!(bytes.len(), 256);
                bytes.fill(1);
                Ok(())
            })
            .unwrap();
        assert_eq!(used[0].length, 256);
        assert_eq!(
            memory.read_at(BASE, BASE + 0x1100, 32).unwrap(),
            vec![0; 32]
        );
    }

    #[test]
    fn rejects_readable_empty_and_oversized_queues_without_using_entropy() {
        for (length, flags, size) in [(16, 0, 8), (0, 2, 8), (16, 2, 512)] {
            let (memory, mut transport, mut queue) = fixture(length, flags);
            queue.size = size;
            assert!(RngQueueHandler::default()
                .handle_with_entropy(queue, &mut transport, &memory, BASE, |_| panic!(
                    "invalid request used entropy"
                ))
                .is_err());
            assert_eq!(
                memory.read_le_u16(BASE, queue.device_address + 2).unwrap(),
                0
            );
        }
    }

    #[test]
    fn entropy_failure_is_not_published_as_random_data() {
        let (memory, mut transport, queue) = fixture(64, 2);
        assert!(matches!(
            RngQueueHandler::default().handle_with_entropy(
                queue,
                &mut transport,
                &memory,
                BASE,
                |_| Err(std::io::Error::from_raw_os_error(libc::EIO))
            ),
            Err(RngError::Entropy(_))
        ));
        assert_eq!(
            memory.read_le_u16(BASE, queue.device_address + 2).unwrap(),
            0
        );
        assert_eq!(
            memory.read_at(BASE, BASE + 0x1000, 64).unwrap(),
            vec![0; 64]
        );
    }

    #[test]
    fn waits_for_driver_ready_and_host_entropy_is_available() {
        let (memory, mut transport, queue) = fixture(64, 2);
        assert_eq!(
            transport.plan.features & crate::devices::virtio::FEATURE_EVENT_IDX,
            0
        );
        transport.device_status = 0;
        assert!(RngQueueHandler::default()
            .handle_with_entropy(queue, &mut transport, &memory, BASE, |_| panic!(
                "driver not ready"
            ))
            .unwrap()
            .is_empty());
        host_entropy(&mut [0u8; MAX_REQUEST_BYTES]).unwrap();
    }
}

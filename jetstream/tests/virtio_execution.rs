use std::io::{Read, Seek, SeekFrom};

use jetstream::arch::aarch64;
use jetstream::devices::block::{BlockQueueHandler, RawBlockDevice};
use jetstream::devices::virtio::{VirtioDeviceKind, VirtioMmioDevice, VirtioMmioDevicePlan};
use jetstream::devices::virtqueue::UsedElement;
use jetstream::devices::vsock::{VsockPacket, VsockQueue, VsockQueueHandler};
use jetstream::vmm::memory::GuestMemory;
use tempfile::NamedTempFile;

#[test]
fn block_queue_executes_write_flush_and_readback() {
    let mut image = NamedTempFile::new().unwrap();
    image.as_file_mut().set_len(4096).unwrap();
    let raw = RawBlockDevice::open(image.path(), "testblk", false).unwrap();
    let mut handler = BlockQueueHandler::new(raw);
    let mut transport = VirtioMmioDevice::new(
        VirtioMmioDevicePlan::new(VirtioDeviceKind::Block, 0),
        Vec::new(),
    );
    let memory = GuestMemory::anonymous(1024 * 1024).unwrap();
    let queue = queue_state();
    let payload = b"hello block";
    let header_addr = aarch64::RAM_BASE + 0x4000;
    let payload_addr = aarch64::RAM_BASE + 0x5000;
    let status_addr = aarch64::RAM_BASE + 0x6000;
    memory
        .write_at(aarch64::RAM_BASE, header_addr, &blk_header(1, 1))
        .unwrap();
    memory
        .write_at(aarch64::RAM_BASE, payload_addr, payload)
        .unwrap();
    write_desc_table(
        &memory,
        &[
            desc(header_addr, 16, 1, 1),
            desc(payload_addr, payload.len() as u32, 1, 2),
            desc(status_addr, 1, 2, 0),
        ],
    );
    write_avail(&memory, &[0]);

    let used = handler
        .handle_available(queue, &mut transport, &memory, aarch64::RAM_BASE)
        .unwrap();

    assert_eq!(used, vec![UsedElement { id: 0, length: 1 }]);
    assert_eq!(
        memory
            .read_at(aarch64::RAM_BASE, status_addr, 1)
            .unwrap()
            .as_slice(),
        &[0]
    );
    let mut persisted = vec![0u8; payload.len()];
    image.as_file_mut().seek(SeekFrom::Start(512)).unwrap();
    image.as_file_mut().read_exact(&mut persisted).unwrap();
    assert_eq!(persisted, payload);
}

#[test]
fn vsock_transmit_and_receive_queues_move_packets() {
    let mut handler = VsockQueueHandler::new();
    let mut transport = VirtioMmioDevice::new(
        VirtioMmioDevicePlan::new(VirtioDeviceKind::Vsock, 4),
        Vec::new(),
    );
    let memory = GuestMemory::anonymous(1024 * 1024).unwrap();
    let queue = queue_state();
    let packet = VsockPacket::rw(40_000, 2375, b"GET /_ping\r\n\r\n".to_vec()).encode();
    let packet_addr = aarch64::RAM_BASE + 0x4000;
    memory
        .write_at(aarch64::RAM_BASE, packet_addr, &packet)
        .unwrap();
    write_desc_table(&memory, &[desc(packet_addr, packet.len() as u32, 0, 0)]);
    write_avail(&memory, &[0]);

    let used = handler
        .handle_available(
            queue,
            VsockQueue::Transmit as u32,
            &mut transport,
            &memory,
            aarch64::RAM_BASE,
        )
        .unwrap();
    assert_eq!(used, vec![UsedElement { id: 0, length: 0 }]);

    let host_packet = VsockPacket::rw(40_000, 2375, b"HTTP/1.1 200 OK\r\n\r\nOK".to_vec());
    let host_bytes = host_packet.encode();
    handler.enqueue_host_packet(host_packet);
    let recv_addr = aarch64::RAM_BASE + 0x7000;
    write_desc_table(&memory, &[desc(recv_addr, host_bytes.len() as u32, 2, 0)]);
    write_avail_with_index(&memory, &[0], 2);

    let used = handler
        .handle_available(
            queue,
            VsockQueue::Receive as u32,
            &mut transport,
            &memory,
            aarch64::RAM_BASE,
        )
        .unwrap();

    assert_eq!(
        used,
        vec![UsedElement {
            id: 0,
            length: host_bytes.len() as u32
        }]
    );
    assert_eq!(
        memory
            .read_at(aarch64::RAM_BASE, recv_addr, host_bytes.len())
            .unwrap(),
        host_bytes
    );
}

fn queue_state() -> jetstream::devices::virtio::VirtioQueueState {
    jetstream::devices::virtio::VirtioQueueState {
        size: 8,
        ready: true,
        descriptor_address: aarch64::RAM_BASE + 0x1000,
        driver_address: aarch64::RAM_BASE + 0x2000,
        device_address: aarch64::RAM_BASE + 0x3000,
    }
}

fn blk_header(request_type: u32, sector: u64) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&request_type.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&sector.to_le_bytes());
    out
}

fn desc(address: u64, length: u32, flags: u16, next: u16) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[0..8].copy_from_slice(&address.to_le_bytes());
    out[8..12].copy_from_slice(&length.to_le_bytes());
    out[12..14].copy_from_slice(&flags.to_le_bytes());
    out[14..16].copy_from_slice(&next.to_le_bytes());
    out
}

fn write_desc_table(memory: &GuestMemory, descriptors: &[[u8; 16]]) {
    let mut table = vec![0u8; 8 * 16];
    for (index, descriptor) in descriptors.iter().enumerate() {
        table[index * 16..index * 16 + 16].copy_from_slice(descriptor);
    }
    memory
        .write_at(aarch64::RAM_BASE, aarch64::RAM_BASE + 0x1000, &table)
        .unwrap();
}

fn write_avail(memory: &GuestMemory, heads: &[u16]) {
    write_avail_with_index(memory, heads, 1);
}

fn write_avail_with_index(memory: &GuestMemory, heads: &[u16], index: u16) {
    let mut ring = Vec::new();
    ring.extend_from_slice(&0u16.to_le_bytes());
    ring.extend_from_slice(&index.to_le_bytes());
    for head in heads {
        ring.extend_from_slice(&head.to_le_bytes());
    }
    memory
        .write_at(aarch64::RAM_BASE, aarch64::RAM_BASE + 0x2000, &ring)
        .unwrap();
    memory
        .write_at(aarch64::RAM_BASE, aarch64::RAM_BASE + 0x3000, &[0u8; 128])
        .unwrap();
}

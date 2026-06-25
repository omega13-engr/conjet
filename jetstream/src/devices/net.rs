use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use thiserror::Error;

use crate::devices::virtio::{VirtioMmioDevice, VirtioQueueState};
use crate::devices::virtqueue::{
    read_descriptors, write_descriptors, QueueError, SplitQueueExecutor, UsedElement,
};
use crate::hvf::vmnet::{VmnetError, VmnetSession};
use crate::vmm::memory::GuestMemory;

const VIRTIO_NET_HEADER_LEN: usize = 12;
const RX_BATCH_LIMIT: usize = 64;
const TX_BATCH_LIMIT: usize = 64;
static NET_TRACE_LINES: AtomicUsize = AtomicUsize::new(0);

#[derive(Debug, Error)]
pub enum NetError {
    #[error("virtio-net packet is shorter than header")]
    ShortPacket,
    #[error("virtio-net receive queue has no writable capacity")]
    NoReceiveCapacity,
    #[error(transparent)]
    Queue(#[from] QueueError),
    #[error(transparent)]
    Vmnet(#[from] VmnetError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetQueue {
    Receive = 0,
    Transmit = 1,
}

#[derive(Debug)]
pub struct VmnetPacketBridge {
    session: VmnetSession,
    ingress: VecDeque<Vec<u8>>,
}

impl VmnetPacketBridge {
    pub fn start_default() -> Result<Self, VmnetError> {
        Ok(Self {
            session: VmnetSession::start_shared(
                "conjet-rust-jetstream-net0",
                "02:43:4a:45:54:01",
                "172.31.64.1",
                "172.31.64.254",
                "255.255.255.0",
            )?,
            ingress: VecDeque::new(),
        })
    }

    fn submit(&mut self, packets: &[Vec<u8>]) -> Result<(), VmnetError> {
        let written = self.session.write_packets(packets)?;
        trace_net(format_args!(
            "vmnet_write requested={} written={} bytes={} first={}",
            packets.len(),
            written,
            packets.iter().map(Vec::len).sum::<usize>(),
            packets
                .first()
                .map(|packet| ethernet_summary(packet))
                .unwrap_or_else(|| "none".to_string())
        ));
        Ok(())
    }

    fn poll(&mut self) -> Result<usize, VmnetError> {
        let packets = self
            .session
            .read_packets(RX_BATCH_LIMIT)?
            .into_iter()
            .map(normalize_vmnet_payload)
            .collect::<Vec<_>>();
        let count = packets.len();
        if count > 0 {
            trace_net(format_args!(
                "vmnet_read packets={} bytes={} first={}",
                count,
                packets.iter().map(Vec::len).sum::<usize>(),
                packets
                    .first()
                    .map(|packet| ethernet_summary(packet))
                    .unwrap_or_else(|| "none".to_string())
            ));
        }
        self.ingress.extend(packets);
        Ok(count)
    }

    fn pop(&mut self) -> Option<Vec<u8>> {
        self.ingress.pop_front()
    }

    fn push_front(&mut self, packet: Vec<u8>) {
        self.ingress.push_front(packet);
    }
}

#[derive(Debug, Default)]
pub struct NetQueueHandler {
    receive_executor: SplitQueueExecutor,
    transmit_executor: SplitQueueExecutor,
    bridge: Option<Arc<Mutex<VmnetPacketBridge>>>,
}

impl NetQueueHandler {
    pub fn with_bridge(bridge: Arc<Mutex<VmnetPacketBridge>>) -> Self {
        Self {
            bridge: Some(bridge),
            ..Self::default()
        }
    }

    pub fn handle_available(
        &mut self,
        queue: VirtioQueueState,
        queue_index: u32,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, NetError> {
        match queue_index {
            x if x == NetQueue::Transmit as u32 => {
                self.handle_transmit(queue, transport, memory, guest_base)
            }
            x if x == NetQueue::Receive as u32 => {
                self.handle_receive(queue, transport, memory, guest_base)
            }
            _ => Ok(Vec::new()),
        }
    }

    fn handle_transmit(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, NetError> {
        let chains = self.transmit_executor.drain_available_chains(
            queue,
            memory,
            guest_base,
            Some(TX_BATCH_LIMIT),
        )?;
        if chains.is_empty() {
            return Ok(Vec::new());
        }

        let mut packets = Vec::with_capacity(chains.len());
        let mut used = Vec::with_capacity(chains.len());
        for chain in &chains {
            let descriptors: Vec<_> = chain.readable_descriptors().copied().collect();
            let bytes = read_descriptors(memory, guest_base, descriptors)?;
            let header_len = header_len(transport);
            if bytes.len() < header_len {
                return Err(NetError::ShortPacket);
            }
            packets.push(bytes[header_len..].to_vec());
            used.push(UsedElement {
                id: u32::from(chain.head_index),
                length: bytes.len() as u32,
            });
        }

        if let Some(bridge) = self.bridge.as_ref() {
            bridge
                .lock()
                .expect("vmnet bridge mutex poisoned")
                .submit(&packets)?;
        }
        trace_net(format_args!(
            "virtio_net_tx packets={} bytes={} header_len={} driver_features=0x{:x}",
            packets.len(),
            packets.iter().map(Vec::len).sum::<usize>(),
            header_len(transport),
            transport.driver_features
        ));
        self.transmit_executor
            .publish_used(queue, transport, memory, guest_base, &used)?;
        if !used.is_empty() && transport.interrupt_status == 0 {
            transport.mark_queue_used();
        }
        Ok(used)
    }

    fn handle_receive(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, NetError> {
        if let Some(bridge) = self.bridge.as_ref() {
            bridge.lock().expect("vmnet bridge mutex poisoned").poll()?;
        }
        let chains = self.receive_executor.peek_available_chains(
            queue,
            memory,
            guest_base,
            Some(RX_BATCH_LIMIT),
        )?;
        if chains.is_empty() {
            return Ok(Vec::new());
        }
        let Some(bridge) = self.bridge.as_ref() else {
            return Ok(Vec::new());
        };
        let mut bridge = bridge.lock().expect("vmnet bridge mutex poisoned");
        let mut prepared = Vec::new();
        for chain in chains {
            let Some(payload) = bridge.pop() else {
                break;
            };
            let mut encoded = vec![0u8; header_len(transport)];
            encoded[10..12].copy_from_slice(&1u16.to_le_bytes());
            encoded.extend_from_slice(&payload);
            let capacity = chain
                .writable_descriptors()
                .map(|descriptor| descriptor.length as usize)
                .sum::<usize>();
            if encoded.len() > capacity {
                bridge.push_front(payload);
                break;
            }
            prepared.push((chain, encoded));
        }
        drop(bridge);

        if prepared.is_empty() {
            return Ok(Vec::new());
        }
        let drained = self.receive_executor.drain_available_chains(
            queue,
            memory,
            guest_base,
            Some(prepared.len()),
        )?;
        let mut used = Vec::with_capacity(prepared.len());
        for ((chain, data), drained_chain) in prepared.into_iter().zip(drained.into_iter()) {
            if chain.head_index != drained_chain.head_index {
                return Err(NetError::NoReceiveCapacity);
            }
            let descriptors: Vec<_> = chain.writable_descriptors().copied().collect();
            let copied = write_descriptors(memory, guest_base, descriptors, &data)?;
            used.push(UsedElement {
                id: u32::from(chain.head_index),
                length: copied as u32,
            });
        }
        self.receive_executor
            .publish_used(queue, transport, memory, guest_base, &used)?;
        trace_net(format_args!(
            "virtio_net_rx delivered={} bytes={} header_len={} interrupt_status=0x{:x}",
            used.len(),
            used.iter()
                .map(|element| element.length as usize)
                .sum::<usize>(),
            header_len(transport),
            transport.interrupt_status
        ));
        if !used.is_empty() && transport.interrupt_status == 0 {
            transport.mark_queue_used();
        }
        Ok(used)
    }
}

fn header_len(transport: &VirtioMmioDevice) -> usize {
    let _ = transport;
    VIRTIO_NET_HEADER_LEN
}

fn trace_net(args: std::fmt::Arguments<'_>) {
    if std::env::var_os("JETSTREAM_NET_TRACE").is_none() {
        return;
    }
    if NET_TRACE_LINES.fetch_add(1, Ordering::Relaxed) < 200 {
        eprintln!("jetstream-net: {args}");
    }
}

fn normalize_vmnet_payload(packet: Vec<u8>) -> Vec<u8> {
    if looks_like_ethernet(&packet) {
        return packet;
    }
    if packet.len() > VIRTIO_NET_HEADER_LEN
        && looks_like_virtio_net_header(&packet[..VIRTIO_NET_HEADER_LEN])
        && looks_like_ethernet(&packet[VIRTIO_NET_HEADER_LEN..])
    {
        return packet[VIRTIO_NET_HEADER_LEN..].to_vec();
    }
    packet
}

fn looks_like_ethernet(packet: &[u8]) -> bool {
    if packet.len() < 14 {
        return false;
    }
    if packet[6..12].iter().all(|byte| *byte == 0) {
        return false;
    }
    u16::from_be_bytes([packet[12], packet[13]]) >= 0x0600
}

fn looks_like_virtio_net_header(header: &[u8]) -> bool {
    if header.len() < VIRTIO_NET_HEADER_LEN {
        return false;
    }
    let flags = header[0];
    let gso_type = header[1];
    let header_len = u16::from_le_bytes([header[2], header[3]]);
    let gso_size = u16::from_le_bytes([header[4], header[5]]);
    let checksum_start = u16::from_le_bytes([header[6], header[7]]);
    let checksum_offset = u16::from_le_bytes([header[8], header[9]]);
    let num_buffers = u16::from_le_bytes([header[10], header[11]]);
    let allowed_gso = matches!(gso_type, 0 | 1 | 3 | 4 | 0x80 | 0x81 | 0x83 | 0x84);
    flags & !0x07 == 0
        && allowed_gso
        && num_buffers <= 1024
        && (header_len == 0 || header_len >= 14)
        && (gso_size != 0 || checksum_start == 0 || checksum_offset <= 64)
}

fn ethernet_summary(packet: &[u8]) -> String {
    if packet.len() < 14 {
        return format!("truncated:{}", packet.len());
    }
    format!(
        "dst={:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x} src={:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x} ethertype=0x{:04x} len={}",
        packet[0],
        packet[1],
        packet[2],
        packet[3],
        packet[4],
        packet[5],
        packet[6],
        packet[7],
        packet[8],
        packet[9],
        packet[10],
        packet[11],
        u16::from_be_bytes([packet[12], packet[13]]),
        packet.len()
    )
}

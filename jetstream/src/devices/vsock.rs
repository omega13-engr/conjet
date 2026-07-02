use std::collections::{BTreeMap, VecDeque};
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;

use thiserror::Error;

use crate::devices::virtio::{VirtioMmioDevice, VirtioQueueState};
use crate::devices::virtqueue::{
    read_descriptors, write_descriptors, DescriptorChain, QueueError, SplitQueueExecutor,
    UsedElement,
};
use crate::vmm::memory::GuestMemory;

pub const HOST_CID: u64 = 2;
pub const DEFAULT_GUEST_CID: u64 = 3;
pub const DOCKER_BRIDGE_PORT: u32 = 2375;
pub const MEMORY_BRIDGE_PORT: u32 = 2376;
const STREAM_TYPE: u16 = 1;
const OP_REQUEST: u16 = 1;
const OP_RESPONSE: u16 = 2;
const OP_RESET: u16 = 3;
const OP_SHUTDOWN: u16 = 4;
const OP_RW: u16 = 5;
const OP_CREDIT_UPDATE: u16 = 6;
const HEADER_LEN: usize = 44;
const DEFAULT_BUF_ALLOC: u32 = 4 * 1024 * 1024;
const DEFAULT_GUEST_BUF_ALLOC: u64 = 256 * 1024;
const MAX_HOST_PAYLOAD: usize = 32 * 1024;
const SHUTDOWN_SEND: u32 = 2;
const CONJET_BINARY_FRAME_MAGIC: [u8; 4] = [0x43, 0x4a, 0x4e, 0x54];

#[derive(Debug, Error)]
pub enum VsockError {
    #[error("virtio-vsock packet is shorter than header")]
    ShortPacket,
    #[error("virtio-vsock packet length mismatch")]
    LengthMismatch,
    #[error("virtio-vsock receive queue has no writable capacity")]
    NoReceiveCapacity,
    #[error(transparent)]
    Queue(#[from] QueueError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VsockQueue {
    Receive = 0,
    Transmit = 1,
    Event = 2,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VsockPacket {
    pub src_cid: u64,
    pub dst_cid: u64,
    pub src_port: u32,
    pub dst_port: u32,
    pub op: u16,
    pub flags: u32,
    pub buf_alloc: u32,
    pub fwd_cnt: u32,
    pub payload: Vec<u8>,
}

impl VsockPacket {
    pub fn connection_request(host_port: u32, guest_port: u32) -> Self {
        Self::control(host_port, guest_port, OP_REQUEST, 0, 0)
    }

    pub fn credit_update(host_port: u32, guest_port: u32, fwd_cnt: u32) -> Self {
        Self::control(host_port, guest_port, OP_CREDIT_UPDATE, 0, fwd_cnt)
    }

    pub fn reset(host_port: u32, guest_port: u32, fwd_cnt: u32) -> Self {
        Self::control(host_port, guest_port, OP_RESET, 0, fwd_cnt)
    }

    fn control(host_port: u32, guest_port: u32, op: u16, flags: u32, fwd_cnt: u32) -> Self {
        Self {
            src_cid: HOST_CID,
            dst_cid: DEFAULT_GUEST_CID,
            src_port: host_port,
            dst_port: guest_port,
            op,
            flags,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt,
            payload: Vec::new(),
        }
    }

    pub fn rw(host_port: u32, guest_port: u32, payload: Vec<u8>) -> Self {
        Self::rw_with_credit(host_port, guest_port, payload, 0)
    }

    pub fn rw_with_credit(host_port: u32, guest_port: u32, payload: Vec<u8>, fwd_cnt: u32) -> Self {
        Self {
            src_cid: HOST_CID,
            dst_cid: DEFAULT_GUEST_CID,
            src_port: host_port,
            dst_port: guest_port,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt,
            payload,
        }
    }

    pub fn shutdown(host_port: u32, guest_port: u32) -> Self {
        Self::shutdown_with_credit(host_port, guest_port, 0)
    }

    pub fn shutdown_with_credit(host_port: u32, guest_port: u32, fwd_cnt: u32) -> Self {
        Self {
            src_cid: HOST_CID,
            dst_cid: DEFAULT_GUEST_CID,
            src_port: host_port,
            dst_port: guest_port,
            op: OP_SHUTDOWN,
            flags: SHUTDOWN_SEND,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt,
            payload: Vec::new(),
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN + self.payload.len());
        out.extend_from_slice(&self.src_cid.to_le_bytes());
        out.extend_from_slice(&self.dst_cid.to_le_bytes());
        out.extend_from_slice(&self.src_port.to_le_bytes());
        out.extend_from_slice(&self.dst_port.to_le_bytes());
        out.extend_from_slice(&(self.payload.len() as u32).to_le_bytes());
        out.extend_from_slice(&STREAM_TYPE.to_le_bytes());
        out.extend_from_slice(&self.op.to_le_bytes());
        out.extend_from_slice(&self.flags.to_le_bytes());
        out.extend_from_slice(&self.buf_alloc.to_le_bytes());
        out.extend_from_slice(&self.fwd_cnt.to_le_bytes());
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, VsockError> {
        if bytes.len() < HEADER_LEN {
            return Err(VsockError::ShortPacket);
        }
        let len = u32::from_le_bytes(bytes[24..28].try_into().unwrap()) as usize;
        if bytes.len() != HEADER_LEN + len {
            return Err(VsockError::LengthMismatch);
        }
        Ok(Self {
            src_cid: u64::from_le_bytes(bytes[0..8].try_into().unwrap()),
            dst_cid: u64::from_le_bytes(bytes[8..16].try_into().unwrap()),
            src_port: u32::from_le_bytes(bytes[16..20].try_into().unwrap()),
            dst_port: u32::from_le_bytes(bytes[20..24].try_into().unwrap()),
            op: u16::from_le_bytes(bytes[30..32].try_into().unwrap()),
            flags: u32::from_le_bytes(bytes[32..36].try_into().unwrap()),
            buf_alloc: u32::from_le_bytes(bytes[36..40].try_into().unwrap()),
            fwd_cnt: u32::from_le_bytes(bytes[40..44].try_into().unwrap()),
            payload: bytes[HEADER_LEN..].to_vec(),
        })
    }
}

#[derive(Debug, Default)]
pub struct VsockQueueHandler {
    receive_executor: SplitQueueExecutor,
    transmit_executor: SplitQueueExecutor,
    pending_host_packets: VecDeque<VsockPacket>,
    bridges: Vec<Arc<Mutex<HostUnixVsockBridgeState>>>,
}

impl VsockQueueHandler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_bridge(bridge: Arc<Mutex<HostUnixVsockBridgeState>>) -> Self {
        Self::with_bridges(vec![bridge])
    }

    pub fn with_bridges(bridges: Vec<Arc<Mutex<HostUnixVsockBridgeState>>>) -> Self {
        Self {
            bridges,
            ..Self::default()
        }
    }

    pub fn enqueue_host_packet(&mut self, packet: VsockPacket) {
        self.pending_host_packets.push_back(packet);
    }

    pub fn handle_available(
        &mut self,
        queue: VirtioQueueState,
        queue_index: u32,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, VsockError> {
        self.import_bridge_packets();
        match queue_index {
            x if x == VsockQueue::Transmit as u32 => {
                let packets = self.transmit_executor.drain_and_publish(
                    queue,
                    transport,
                    memory,
                    guest_base,
                    Some(64),
                    |chain| receive_guest_packet(chain, memory, guest_base, &self.bridges),
                )?;
                Ok(packets)
            }
            x if x == VsockQueue::Receive as u32 => {
                self.deliver_host_packets(queue, transport, memory, guest_base)
            }
            _ => Ok(Vec::new()),
        }
    }

    fn import_bridge_packets(&mut self) {
        for bridge in &self.bridges {
            let mut bridge = bridge.lock().expect("vsock bridge mutex poisoned");
            bridge.poll_host_streams();
            while let Some(packet) = bridge.pending_guest_packets.pop_front() {
                self.pending_host_packets.push_back(packet);
            }
        }
    }

    fn deliver_host_packets(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, VsockError> {
        let chains =
            self.receive_executor
                .peek_available_chains(queue, memory, guest_base, Some(64))?;
        if chains.is_empty() || self.pending_host_packets.is_empty() {
            return Ok(Vec::new());
        }
        let mut prepared = Vec::new();
        for chain in chains {
            let Some(packet) = self.pending_host_packets.pop_front() else {
                break;
            };
            let capacity = chain
                .writable_descriptors()
                .map(|descriptor| descriptor.length as usize)
                .sum::<usize>();
            if capacity < HEADER_LEN {
                self.pending_host_packets.push_front(packet);
                break;
            }
            let encoded = packet.encode();
            if encoded.len() > capacity {
                let max_payload = capacity - HEADER_LEN;
                let first_payload =
                    packet.payload[..max_payload.min(packet.payload.len())].to_vec();
                let rest_payload = packet.payload[first_payload.len()..].to_vec();
                let mut first = packet.clone();
                first.payload = first_payload;
                if !rest_payload.is_empty() {
                    let mut rest = packet;
                    rest.payload = rest_payload;
                    self.pending_host_packets.push_front(rest);
                }
                prepared.push((chain, first.encode()));
            } else {
                prepared.push((chain, encoded));
            }
        }
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
                return Err(VsockError::NoReceiveCapacity);
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
        if !used.is_empty() && transport.interrupt_status == 0 {
            transport.mark_queue_used();
        }
        Ok(used)
    }
}

fn receive_guest_packet(
    chain: &DescriptorChain,
    memory: &GuestMemory,
    guest_base: u64,
    bridges: &[Arc<Mutex<HostUnixVsockBridgeState>>],
) -> Result<UsedElement, QueueError> {
    let descriptors: Vec<_> = chain.readable_descriptors().copied().collect();
    let bytes = read_descriptors(memory, guest_base, descriptors)?;
    if let Ok(packet) = VsockPacket::decode(&bytes) {
        for bridge in bridges {
            if bridge
                .lock()
                .expect("vsock bridge mutex poisoned")
                .handle_guest_packet(packet.clone())
            {
                break;
            }
        }
    }
    Ok(UsedElement {
        id: u32::from(chain.head_index),
        length: 0,
    })
}

#[derive(Debug)]
pub struct HostUnixVsockBridge {
    pub state: Arc<Mutex<HostUnixVsockBridgeState>>,
    socket_path: PathBuf,
}

impl HostUnixVsockBridge {
    pub fn bind(socket_path: impl AsRef<Path>) -> Result<Self, VsockError> {
        Self::bind_with_guest_port(socket_path, DOCKER_BRIDGE_PORT, 40_000)
    }

    pub fn bind_with_guest_port(
        socket_path: impl AsRef<Path>,
        guest_port: u32,
        first_host_port: u32,
    ) -> Result<Self, VsockError> {
        let socket_path = socket_path.as_ref().to_path_buf();
        if socket_path.exists() {
            std::fs::remove_file(&socket_path)?;
        }
        if let Some(parent) = socket_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let listener = UnixListener::bind(&socket_path)?;
        listener.set_nonblocking(true)?;
        let state = Arc::new(Mutex::new(HostUnixVsockBridgeState::new(
            guest_port,
            first_host_port,
            guest_port == DOCKER_BRIDGE_PORT,
        )));
        let worker_state = state.clone();
        thread::Builder::new()
            .name("jetstream-docker-vsock-bridge".to_string())
            .spawn(move || accept_loop(listener, worker_state))
            .map_err(VsockError::Io)?;
        Ok(Self { state, socket_path })
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }
}

#[derive(Debug)]
pub struct HostUnixVsockBridgeState {
    guest_port: u32,
    next_port: u32,
    detect_docker_phases: bool,
    docker_phase_request_events: u64,
    docker_phase_response_events: u64,
    docker_completed_stream_events: u64,
    docker_completed_workload_stream_events: u64,
    docker_request_bytes: u64,
    docker_response_bytes: u64,
    streams: BTreeMap<u32, HostUnixVsockStream>,
    pub pending_guest_packets: VecDeque<VsockPacket>,
}

impl Default for HostUnixVsockBridgeState {
    fn default() -> Self {
        Self::new(DOCKER_BRIDGE_PORT, 40_000, true)
    }
}

impl HostUnixVsockBridgeState {
    pub fn new(guest_port: u32, first_host_port: u32, detect_docker_phases: bool) -> Self {
        Self {
            guest_port,
            next_port: first_host_port,
            detect_docker_phases,
            docker_phase_request_events: 0,
            docker_phase_response_events: 0,
            docker_completed_stream_events: 0,
            docker_completed_workload_stream_events: 0,
            docker_request_bytes: 0,
            docker_response_bytes: 0,
            streams: BTreeMap::new(),
            pending_guest_packets: VecDeque::new(),
        }
    }

    pub fn docker_phase_events(&self) -> u64 {
        self.docker_phase_request_events
            .saturating_add(self.docker_phase_response_events)
    }

    pub fn docker_phase_request_events(&self) -> u64 {
        self.docker_phase_request_events
    }

    pub fn docker_phase_response_events(&self) -> u64 {
        self.docker_phase_response_events
    }

    pub fn docker_completed_stream_events(&self) -> u64 {
        self.docker_completed_stream_events
    }

    pub fn docker_completed_workload_stream_events(&self) -> u64 {
        self.docker_completed_workload_stream_events
    }

    pub fn docker_request_bytes(&self) -> u64 {
        self.docker_request_bytes
    }

    pub fn docker_response_bytes(&self) -> u64 {
        self.docker_response_bytes
    }

    fn accept_stream(&mut self, stream: UnixStream) {
        let port = self.next_port;
        self.next_port = self.next_port.saturating_add(1);
        let _ = stream.set_nonblocking(true);
        let stream = HostUnixVsockStream::new(stream);
        self.pending_guest_packets
            .push_back(VsockPacket::connection_request(port, self.guest_port));
        self.streams.insert(port, stream);
        self.poll_host_stream(port);
    }

    fn poll_host_streams(&mut self) {
        let ports: Vec<u32> = self.streams.keys().copied().collect();
        for host_port in ports {
            self.poll_host_stream(host_port);
        }
        let mut completed = 0u64;
        let mut completed_workloads = 0u64;
        self.streams.retain(|_, stream| {
            let finished = stream.finished();
            if finished {
                completed = completed.saturating_add(1);
                if stream.docker_workload_detected || stream.docker_response_phase_detected {
                    completed_workloads = completed_workloads.saturating_add(1);
                }
            }
            !finished
        });
        if self.detect_docker_phases {
            self.docker_completed_stream_events = self
                .docker_completed_stream_events
                .saturating_add(completed);
            self.docker_completed_workload_stream_events = self
                .docker_completed_workload_stream_events
                .saturating_add(completed_workloads);
        }
    }

    fn poll_host_stream(&mut self, host_port: u32) {
        let Some(stream) = self.streams.get_mut(&host_port) else {
            return;
        };
        if stream.flush_host_output().is_err() {
            stream.reset = true;
            let fwd_cnt = stream.forward_count();
            self.pending_guest_packets.push_back(VsockPacket::reset(
                host_port,
                self.guest_port,
                fwd_cnt,
            ));
            return;
        }
        loop {
            let Some(reservation) = stream.reserve_guest_credit(MAX_HOST_PAYLOAD) else {
                break;
            };
            let mut buf = vec![0u8; reservation];
            match stream.socket.read(&mut buf) {
                Ok(0) => {
                    if !stream.host_shutdown_sent {
                        stream.host_shutdown_sent = true;
                        let fwd_cnt = stream.forward_count();
                        self.pending_guest_packets
                            .push_back(VsockPacket::shutdown_with_credit(
                                host_port,
                                self.guest_port,
                                fwd_cnt,
                            ));
                    }
                    break;
                }
                Ok(count) => {
                    buf.truncate(count);
                    stream.observe_host_protocol(&buf);
                    if !stream.binary_frame_stream {
                        self.docker_request_bytes =
                            self.docker_request_bytes.saturating_add(count as u64);
                    }
                    if self.detect_docker_phases && !stream.binary_frame_stream {
                        stream.detect_docker_workload_request(&buf);
                    }
                    let request_complete =
                        !stream.binary_frame_stream && stream.observe_host_request_bytes(&buf);
                    stream.bytes_sent_to_guest =
                        stream.bytes_sent_to_guest.wrapping_add(count as u64);
                    let fwd_cnt = stream.forward_count();
                    self.pending_guest_packets
                        .push_back(VsockPacket::rw_with_credit(
                            host_port,
                            self.guest_port,
                            buf,
                            fwd_cnt,
                        ));
                    if request_complete && !stream.host_shutdown_sent {
                        stream.host_shutdown_sent = true;
                        let fwd_cnt = stream.forward_count();
                        self.pending_guest_packets
                            .push_back(VsockPacket::shutdown_with_credit(
                                host_port,
                                self.guest_port,
                                fwd_cnt,
                            ));
                        break;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    stream.reset = true;
                    let fwd_cnt = stream.forward_count();
                    self.pending_guest_packets.push_back(VsockPacket::reset(
                        host_port,
                        self.guest_port,
                        fwd_cnt,
                    ));
                    break;
                }
            }
        }
    }

    fn handle_guest_packet(&mut self, packet: VsockPacket) -> bool {
        let host_port = packet.dst_port;
        match packet.op {
            OP_RESPONSE | OP_CREDIT_UPDATE => {
                if let Some(stream) = self.streams.get_mut(&host_port) {
                    stream.update_guest_credit(&packet);
                    if packet.op == OP_RESPONSE {
                        let fwd_cnt = stream.forward_count();
                        self.pending_guest_packets
                            .push_back(VsockPacket::credit_update(
                                host_port,
                                packet.src_port,
                                fwd_cnt,
                            ));
                    }
                    true
                } else {
                    false
                }
            }
            OP_RW => {
                if let Some(stream) = self.streams.get_mut(&host_port) {
                    stream.update_guest_credit(&packet);
                    if !stream.binary_frame_stream {
                        self.docker_response_bytes = self
                            .docker_response_bytes
                            .saturating_add(packet.payload.len() as u64);
                    }
                    if self.detect_docker_phases && !stream.binary_frame_stream {
                        let phases = stream.detect_docker_response_phase_events(&packet.payload);
                        if phases > 0 {
                            stream.docker_response_phase_detected = true;
                        }
                        self.docker_phase_response_events =
                            self.docker_phase_response_events.saturating_add(phases);
                    }
                    stream.enqueue_host_output(&packet.payload);
                    stream.bytes_received_from_guest = stream
                        .bytes_received_from_guest
                        .wrapping_add(packet.payload.len() as u64);
                    if stream.flush_host_output().is_err() {
                        stream.reset = true;
                        self.pending_guest_packets.push_back(VsockPacket::reset(
                            host_port,
                            packet.src_port,
                            stream.forward_count(),
                        ));
                        return true;
                    }
                    stream.finish_terminal_build_response();
                    self.pending_guest_packets
                        .push_back(VsockPacket::credit_update(
                            host_port,
                            packet.src_port,
                            stream.forward_count(),
                        ));
                    self.poll_host_stream(host_port);
                    true
                } else {
                    false
                }
            }
            OP_SHUTDOWN => {
                if let Some(stream) = self.streams.get_mut(&host_port) {
                    stream.update_guest_credit(&packet);
                    // Do not half-close the host socket until every response
                    // byte already accepted from the guest has been written.
                    // Closing here can truncate a Content-Length response and
                    // is surfaced by Go's HTTP client as `unexpected EOF`.
                    stream.guest_shutdown_pending = true;
                    if stream.flush_host_output().is_err() {
                        stream.reset = true;
                        self.pending_guest_packets.push_back(VsockPacket::reset(
                            host_port,
                            packet.src_port,
                            stream.forward_count(),
                        ));
                        return true;
                    }
                    self.poll_host_stream(host_port);
                    true
                } else {
                    false
                }
            }
            OP_RESET => self.streams.remove(&host_port).is_some(),
            _ => false,
        }
    }
}

#[derive(Debug)]
struct HostUnixVsockStream {
    socket: UnixStream,
    bytes_received_from_guest: u64,
    bytes_sent_to_guest: u64,
    guest_forward_count: u64,
    guest_buffer_allocation: u64,
    host_output: VecDeque<u8>,
    guest_shutdown: bool,
    guest_shutdown_pending: bool,
    host_shutdown_sent: bool,
    reset: bool,
    docker_workload_detected: bool,
    docker_response_phase_detected: bool,
    docker_exporting_to_image_seen: bool,
    docker_terminal_response_seen: bool,
    docker_response_phase_line_buffer: Vec<u8>,
    host_request_observed: Vec<u8>,
    host_request_complete: bool,
    host_protocol_prefix: Vec<u8>,
    host_protocol_known: bool,
    binary_frame_stream: bool,
}

impl HostUnixVsockStream {
    fn new(socket: UnixStream) -> Self {
        Self {
            socket,
            bytes_received_from_guest: 0,
            bytes_sent_to_guest: 0,
            guest_forward_count: 0,
            guest_buffer_allocation: DEFAULT_GUEST_BUF_ALLOC,
            host_output: VecDeque::new(),
            guest_shutdown: false,
            guest_shutdown_pending: false,
            host_shutdown_sent: false,
            reset: false,
            docker_workload_detected: false,
            docker_response_phase_detected: false,
            docker_exporting_to_image_seen: false,
            docker_terminal_response_seen: false,
            docker_response_phase_line_buffer: Vec::new(),
            host_request_observed: Vec::new(),
            host_request_complete: false,
            host_protocol_prefix: Vec::new(),
            host_protocol_known: false,
            binary_frame_stream: false,
        }
    }

    fn observe_host_protocol(&mut self, payload: &[u8]) {
        if self.host_protocol_known {
            return;
        }
        let needed = CONJET_BINARY_FRAME_MAGIC
            .len()
            .saturating_sub(self.host_protocol_prefix.len());
        self.host_protocol_prefix
            .extend_from_slice(&payload[..payload.len().min(needed)]);
        if self.host_protocol_prefix.len() >= CONJET_BINARY_FRAME_MAGIC.len() {
            self.binary_frame_stream = self.host_protocol_prefix == CONJET_BINARY_FRAME_MAGIC;
            self.host_protocol_known = true;
        }
    }

    fn observe_host_request_bytes(&mut self, payload: &[u8]) -> bool {
        if self.host_request_complete {
            return true;
        }
        const MAX_OBSERVED_REQUEST: usize = 1024 * 1024;
        if self.host_request_observed.len() < MAX_OBSERVED_REQUEST {
            let remaining = MAX_OBSERVED_REQUEST - self.host_request_observed.len();
            self.host_request_observed
                .extend_from_slice(&payload[..payload.len().min(remaining)]);
        }
        if let Some(required) =
            http_request_bytes_required_for_guest_shutdown(&self.host_request_observed)
        {
            self.host_request_complete = self.host_request_observed.len() >= required;
        }
        self.host_request_complete
    }

    fn detect_docker_workload_request(&mut self, payload: &[u8]) {
        if self.docker_workload_detected {
            return;
        }
        if docker_workload_request_detected(payload) {
            self.docker_workload_detected = true;
        }
    }

    fn detect_docker_response_phase_events(&mut self, payload: &[u8]) -> u64 {
        let mut phases = 0u64;
        if !payload.iter().any(|byte| *byte == b'\n' || *byte == b'\r') {
            phases = phases.saturating_add(self.inspect_docker_response_line(payload));
        }
        let mut completed_lines = Vec::new();
        for byte in payload {
            self.docker_response_phase_line_buffer.push(*byte);
            if *byte == b'\n' || *byte == b'\r' {
                completed_lines.push(std::mem::take(&mut self.docker_response_phase_line_buffer));
            } else if self.docker_response_phase_line_buffer.len() > 4096 {
                self.docker_response_phase_line_buffer.clear();
            }
        }
        for line in completed_lines {
            phases = phases.saturating_add(self.inspect_docker_response_line(&line));
        }
        phases
    }

    fn inspect_docker_response_line(&mut self, line: &[u8]) -> u64 {
        let text = String::from_utf8_lossy(line);
        if text.contains("exporting to image") {
            self.docker_exporting_to_image_seen = true;
        }
        if self.docker_exporting_to_image_seen
            && (text.contains(" DONE ") || text.contains(" DONE\\n"))
        {
            self.docker_terminal_response_seen = true;
        }
        docker_phase_marker_count(line)
    }

    fn finish_terminal_build_response(&mut self) {
        if self.host_shutdown_sent
            && self.docker_terminal_response_seen
            && self.host_output.is_empty()
            && !self.guest_shutdown
        {
            let _ = self.socket.shutdown(Shutdown::Write);
            self.guest_shutdown = true;
        }
    }

    fn forward_count(&self) -> u32 {
        self.bytes_received_from_guest as u32
    }

    fn update_guest_credit(&mut self, packet: &VsockPacket) {
        self.guest_forward_count = u64::from(packet.fwd_cnt);
        if packet.buf_alloc > 0 {
            self.guest_buffer_allocation = u64::from(packet.buf_alloc);
        }
    }

    fn reserve_guest_credit(&self, requested: usize) -> Option<usize> {
        if self.host_shutdown_sent || self.reset {
            return None;
        }
        let in_flight = self
            .bytes_sent_to_guest
            .saturating_sub(self.guest_forward_count);
        if in_flight >= self.guest_buffer_allocation {
            return None;
        }
        let available = (self.guest_buffer_allocation - in_flight) as usize;
        Some(requested.min(available))
    }

    fn enqueue_host_output(&mut self, payload: &[u8]) {
        self.host_output.extend(payload.iter().copied());
    }

    fn flush_host_output(&mut self) -> std::io::Result<()> {
        while !self.host_output.is_empty() {
            let contiguous = self.host_output.make_contiguous();
            match self.socket.write(contiguous) {
                Ok(0) => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::WriteZero,
                        "docker bridge wrote zero bytes",
                    ));
                }
                Ok(count) => {
                    self.host_output.drain(..count);
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        self.finish_guest_shutdown_if_drained();
        Ok(())
    }

    fn finish_guest_shutdown_if_drained(&mut self) {
        if self.guest_shutdown_pending && self.host_output.is_empty() && !self.guest_shutdown {
            let _ = self.socket.shutdown(Shutdown::Write);
            self.guest_shutdown = true;
            self.guest_shutdown_pending = false;
        }
    }

    fn finished(&self) -> bool {
        self.reset
            || (self.guest_shutdown && self.host_shutdown_sent && self.host_output.is_empty())
    }
}

fn http_request_bytes_required_for_guest_shutdown(buffer: &[u8]) -> Option<usize> {
    let header_end = buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| index + 4)?;
    let headers = String::from_utf8_lossy(&buffer[..header_end]).to_ascii_lowercase();
    if headers.contains(" /grpc ")
        || headers.contains("connection: upgrade")
        || headers.contains("upgrade: h2c")
    {
        return None;
    }
    if headers.contains("transfer-encoding: chunked") {
        return chunked_http_request_bytes_required(buffer, header_end);
    }
    for line in headers.lines() {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.trim() == "content-length" {
            let length = value.trim().parse::<usize>().ok()?;
            return header_end.checked_add(length);
        }
    }
    Some(header_end)
}

fn chunked_http_request_bytes_required(buffer: &[u8], mut offset: usize) -> Option<usize> {
    loop {
        let line_end = find_crlf(buffer, offset)?;
        let line = &buffer[offset..line_end];
        let size_text = std::str::from_utf8(line)
            .ok()?
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        let chunk_size = usize::from_str_radix(size_text, 16).ok()?;
        offset = line_end.checked_add(2)?;
        if chunk_size == 0 {
            if buffer.len() >= offset.checked_add(2)? && &buffer[offset..offset + 2] == b"\r\n" {
                return offset.checked_add(2);
            }
            let trailer_end = buffer[offset..]
                .windows(4)
                .position(|window| window == b"\r\n\r\n")?;
            return offset.checked_add(trailer_end)?.checked_add(4);
        }
        offset = offset.checked_add(chunk_size)?;
        if buffer.len() < offset.checked_add(2)? {
            return None;
        }
        if &buffer[offset..offset + 2] != b"\r\n" {
            return None;
        }
        offset = offset.checked_add(2)?;
    }
}

fn find_crlf(buffer: &[u8], offset: usize) -> Option<usize> {
    buffer
        .get(offset..)?
        .windows(2)
        .position(|window| window == b"\r\n")
        .map(|index| offset + index)
}

fn docker_phase_marker_count(line: &[u8]) -> u64 {
    let text = String::from_utf8_lossy(line);
    let mut count = 0u64;
    let plain_markers = [
        " DONE ",
        " DONE\\n",
        " CACHED",
        "\"stream\":\"Successfully built",
        "\"aux\":{\"ID\":\"sha256:",
        "\"status\":\"Pull complete\"",
        "\"status\":\"Download complete\"",
        "\"status\":\"Already exists\"",
    ];
    if plain_markers.iter().any(|marker| text.contains(marker)) {
        count = count.saturating_add(1);
    }
    for marker in ["exporting layers", "exporting to image"] {
        count = count.saturating_add(text.matches(marker).count() as u64);
    }
    count
}

fn docker_workload_request_detected(payload: &[u8]) -> bool {
    let text = String::from_utf8_lossy(payload);
    text.contains(" /build")
        || text.contains("/build?")
        || text.contains(" /images/create")
        || text.contains("/images/create?")
}

fn accept_loop(listener: UnixListener, state: Arc<Mutex<HostUnixVsockBridgeState>>) {
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                state
                    .lock()
                    .expect("vsock bridge mutex poisoned")
                    .accept_stream(stream);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(_) => break,
        }
    }
}

pub fn configuration(guest_cid: u64) -> Vec<u8> {
    guest_cid.to_le_bytes().to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conjet_binary_frame(frame_type: u8, stream_id: u32, payload: &[u8]) -> Vec<u8> {
        let mut frame = Vec::with_capacity(20 + payload.len());
        frame.extend_from_slice(&CONJET_BINARY_FRAME_MAGIC);
        frame.push(1);
        frame.push(frame_type);
        frame.extend_from_slice(&0u16.to_be_bytes());
        frame.extend_from_slice(&stream_id.to_be_bytes());
        frame.extend_from_slice(&0u32.to_be_bytes());
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(payload);
        frame
    }

    #[test]
    fn host_half_close_is_forwarded_without_dropping_stream() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client.write_all(b"GET /build HTTP/1.1\r\n\r\n").unwrap();
        client.shutdown(Shutdown::Write).unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        let packets: Vec<_> = bridge.pending_guest_packets.drain(..).collect();
        assert_eq!(packets[0].op, OP_REQUEST);
        assert_eq!(packets[1].op, OP_RW);
        assert_eq!(packets[1].payload, b"GET /build HTTP/1.1\r\n\r\n");
        assert!(packets
            .iter()
            .any(|packet| { packet.op == OP_SHUTDOWN && packet.flags == SHUTDOWN_SEND }));
        assert!(bridge.streams.contains_key(&49_152));

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_SHUTDOWN,
            flags: SHUTDOWN_SEND,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: Vec::new(),
        }));
        bridge.poll_host_streams();
        assert!(!bridge.streams.contains_key(&49_152));
    }

    #[test]
    fn binary_frame_payload_http_get_does_not_trigger_docker_auto_shutdown() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let mut payload = Vec::new();
        payload.extend_from_slice(b"GET / HTTP/1.1\r\n");
        payload.extend_from_slice(b"Host: 172.17.0.2\r\n");
        payload.extend_from_slice(b"Connection: close\r\n\r\n");
        client
            .write_all(&conjet_binary_frame(15, 1, &payload))
            .unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert_eq!(bridge.pending_guest_packets.len(), 2);
        assert_eq!(bridge.pending_guest_packets[0].op, OP_REQUEST);
        assert_eq!(bridge.pending_guest_packets[1].op, OP_RW);
        assert!(!bridge
            .pending_guest_packets
            .iter()
            .any(|packet| packet.op == OP_SHUTDOWN));
        assert_eq!(bridge.docker_request_bytes(), 0);
    }

    #[test]
    fn guest_payload_writes_to_host_and_advances_forward_count() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.pending_guest_packets.clear();

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: b"HTTP/1.1 200 OK\r\n\r\nOK".to_vec(),
        }));

        let mut received = [0u8; 32];
        let count = client.read(&mut received).unwrap();
        assert_eq!(&received[..count], b"HTTP/1.1 200 OK\r\n\r\nOK");

        let credit = bridge.pending_guest_packets.pop_front().unwrap();
        assert_eq!(credit.op, OP_CREDIT_UPDATE);
        assert_eq!(credit.fwd_cnt, count as u32);
    }

    #[test]
    fn docker_phase_markers_from_host_request_do_not_trigger_reclaim_phase() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.pending_guest_packets.clear();

        client.write_all(b"#1 DONE 0.1s\n#2 CACHED\n").unwrap();
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_phase_events(), 0);
        assert_eq!(bridge.docker_phase_request_events(), 0);
        assert_eq!(bridge.docker_phase_response_events(), 0);
        assert_eq!(bridge.docker_request_bytes(), 23);
        assert_eq!(bridge.docker_response_bytes(), 0);
    }

    #[test]
    fn finished_docker_streams_increment_completion_counter() {
        let (client, server) = UnixStream::pair().unwrap();
        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        drop(client);

        bridge.poll_host_streams();
        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_SHUTDOWN,
            flags: SHUTDOWN_SEND,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: Vec::new(),
        }));
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_completed_stream_events(), 1);
    }

    #[test]
    fn docker_ping_completion_is_not_a_workload_completion() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"GET /_ping HTTP/1.1\r\nHost: docker\r\n\r\n")
            .unwrap();
        client.shutdown(Shutdown::Write).unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_SHUTDOWN,
            flags: SHUTDOWN_SEND,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: Vec::new(),
        }));
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_completed_stream_events(), 1);
        assert_eq!(bridge.docker_completed_workload_stream_events(), 0);
    }

    #[test]
    fn docker_get_without_client_half_close_sends_guest_shutdown() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"GET /info HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")
            .unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert_eq!(bridge.pending_guest_packets.len(), 3);
        assert_eq!(bridge.pending_guest_packets[0].op, OP_REQUEST);
        assert_eq!(bridge.pending_guest_packets[1].op, OP_RW);
        assert_eq!(bridge.pending_guest_packets[2].op, OP_SHUTDOWN);
    }

    #[test]
    fn docker_grpc_upgrade_does_not_auto_shutdown_guest() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(
                b"POST /grpc HTTP/1.1\r\nHost: \r\nContent-Length: 0\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
            )
            .unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert_eq!(bridge.pending_guest_packets.len(), 2);
        assert_eq!(bridge.pending_guest_packets[0].op, OP_REQUEST);
        assert_eq!(bridge.pending_guest_packets[1].op, OP_RW);

        client
            .write_all(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
            .unwrap();
        bridge.poll_host_streams();

        assert_eq!(bridge.pending_guest_packets.len(), 3);
        assert_eq!(bridge.pending_guest_packets[2].op, OP_RW);
    }

    #[test]
    fn docker_post_waits_for_declared_request_body_before_guest_shutdown() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST /v1.52/containers/create HTTP/1.1\r\nHost: docker\r\nContent-Length: 4\r\n\r\nab")
            .unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert_eq!(bridge.pending_guest_packets.len(), 2);
        assert_eq!(bridge.pending_guest_packets[0].op, OP_REQUEST);
        assert_eq!(bridge.pending_guest_packets[1].op, OP_RW);

        client.write_all(b"cd").unwrap();
        bridge.poll_host_streams();
        assert_eq!(bridge.pending_guest_packets.len(), 4);
        assert_eq!(bridge.pending_guest_packets[2].op, OP_RW);
        assert_eq!(bridge.pending_guest_packets[3].op, OP_SHUTDOWN);
    }

    #[test]
    fn docker_chunked_post_waits_for_terminal_chunk_before_guest_shutdown() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST /v1.52/build HTTP/1.1\r\nHost: docker\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nab")
            .unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert_eq!(bridge.pending_guest_packets.len(), 2);
        assert_eq!(bridge.pending_guest_packets[0].op, OP_REQUEST);
        assert_eq!(bridge.pending_guest_packets[1].op, OP_RW);

        client.write_all(b"cd\r\n0\r\n\r\n").unwrap();
        for _ in 0..4 {
            bridge.poll_host_streams();
            if bridge.pending_guest_packets.len() >= 4 {
                break;
            }
            std::thread::yield_now();
        }
        assert_eq!(bridge.pending_guest_packets.len(), 4);
        assert_eq!(bridge.pending_guest_packets[2].op, OP_RW);
        assert_eq!(bridge.pending_guest_packets[3].op, OP_SHUTDOWN);
    }

    #[test]
    fn docker_build_completion_is_a_workload_completion() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST /v1.52/build?t=demo HTTP/1.1\r\nHost: docker\r\n\r\n")
            .unwrap();
        client.shutdown(Shutdown::Write).unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_SHUTDOWN,
            flags: SHUTDOWN_SEND,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: Vec::new(),
        }));
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_completed_stream_events(), 1);
        assert_eq!(bridge.docker_completed_workload_stream_events(), 1);
    }

    #[test]
    fn docker_buildkit_session_completion_is_not_workload_completion() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST /v1.52/session HTTP/1.1\r\nHost: docker\r\n\r\n")
            .unwrap();
        client.shutdown(Shutdown::Write).unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_SHUTDOWN,
            flags: SHUTDOWN_SEND,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: Vec::new(),
        }));
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_completed_stream_events(), 1);
        assert_eq!(bridge.docker_completed_workload_stream_events(), 0);
    }

    #[test]
    fn docker_response_phase_stream_completion_is_workload_completion() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.pending_guest_packets.clear();

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: b"#1 DONE 0.1s\n".to_vec(),
        }));

        let mut received = [0u8; 64];
        let _ = client.read(&mut received).unwrap();

        drop(client);
        bridge.poll_host_streams();
        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_SHUTDOWN,
            flags: SHUTDOWN_SEND,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: Vec::new(),
        }));
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_phase_response_events(), 1);
        assert_eq!(bridge.docker_completed_stream_events(), 1);
        assert_eq!(bridge.docker_completed_workload_stream_events(), 1);
    }

    #[test]
    fn terminal_build_response_half_closes_host_client() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST /v1.52/build?t=demo HTTP/1.1\r\nHost: docker\r\n\r\n")
            .unwrap();
        client.shutdown(Shutdown::Write).unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();
        bridge.pending_guest_packets.clear();

        let payload = b"#8 exporting to image\n#8 DONE 6.3s\n".to_vec();
        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: payload.clone(),
        }));

        let mut received = vec![0u8; payload.len()];
        client.read_exact(&mut received).unwrap();
        assert_eq!(received, payload);
        let mut eof = [0u8; 1];
        assert_eq!(client.read(&mut eof).unwrap(), 0);

        bridge.poll_host_streams();
        assert_eq!(bridge.docker_completed_stream_events(), 1);
        assert_eq!(bridge.docker_completed_workload_stream_events(), 1);
    }

    #[test]
    fn docker_phase_markers_from_guest_response_increment_phase_counter() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.pending_guest_packets.clear();

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: b"#1 DONE 0.1s\n#2 CACHED\n".to_vec(),
        }));

        let mut received = [0u8; 64];
        let _ = client.read(&mut received).unwrap();
        assert_eq!(bridge.docker_phase_events(), 2);
        assert_eq!(bridge.docker_phase_request_events(), 0);
        assert_eq!(bridge.docker_phase_response_events(), 2);
        assert_eq!(bridge.docker_request_bytes(), 0);
        assert_eq!(bridge.docker_response_bytes(), 23);
    }

    #[test]
    fn buildkit_markers_from_guest_response_increment_phase_counter() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.pending_guest_packets.clear();

        let payload = b"\x00\x01llb.customname\x00[2/4] RUN echo phase-one\x00exporting layers\x00";
        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: payload.to_vec(),
        }));

        let mut received = [0u8; 128];
        let _ = client.read(&mut received).unwrap();
        assert_eq!(bridge.docker_phase_events(), 1);
        assert_eq!(bridge.docker_phase_response_events(), 1);
        assert_eq!(bridge.docker_response_bytes(), payload.len() as u64);
    }
}

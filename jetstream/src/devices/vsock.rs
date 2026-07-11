use std::collections::{BTreeMap, VecDeque};
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::{Map, Value};
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
const TRANSMIT_DRAIN_BATCH_LIMIT: usize = 64;
const SHUTDOWN_SEND: u32 = 2;
const MAX_HTTP_RESPONSE_HEADER_BYTES: usize = 64 * 1024;
const MAX_HTTP_CHUNK_LINE_BYTES: usize = 8 * 1024;
const CONJET_BINARY_FRAME_MAGIC: [u8; 4] = [0x43, 0x4a, 0x4e, 0x54];
const CONJET_BINARY_FRAME_VERSION: u8 = 1;
const CONJET_BINARY_FRAME_HEADER_LEN: usize = 20;
const CONJET_BINARY_FRAME_TCP_DATA: u8 = 15;
const MAX_CONJET_BINARY_FRAME_PAYLOAD: usize = 1024 * 1024;
const MAX_DOCKER_WORKLOAD_REQUEST_PREFIX_BYTES: usize = 16 * 1024;

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
                self.drain_transmit_queue(queue, transport, memory, guest_base)
            }
            x if x == VsockQueue::Receive as u32 => {
                self.deliver_host_packets(queue, transport, memory, guest_base)
            }
            _ => Ok(Vec::new()),
        }
    }

    fn drain_transmit_queue(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, VsockError> {
        let mut used = Vec::new();
        loop {
            // A Linux virtio-vsock sender can fill its entire ring before it
            // waits for used descriptors. Drain every available batch for one
            // notification; otherwise a bounded one-shot drain can strand a
            // large Docker archive behind the initial batch indefinitely.
            let batch = self.transmit_executor.drain_and_publish(
                queue,
                transport,
                memory,
                guest_base,
                Some(TRANSMIT_DRAIN_BATCH_LIMIT),
                |chain| receive_guest_packet(chain, memory, guest_base, &self.bridges),
            )?;
            let batch_len = batch.len();
            used.extend(batch);
            if batch_len < TRANSMIT_DRAIN_BATCH_LIMIT {
                break;
            }
        }
        // A shutdown control packet can be queued independently from a
        // producer's data work.  Let every bridge observe the completed
        // transport drain before using a close-delimited response fallback;
        // framed HTTP responses use their wire terminator instead.
        for bridge in &self.bridges {
            bridge
                .lock()
                .expect("vsock bridge mutex poisoned")
                .finish_pending_guest_shutdowns_after_transport_drain();
        }
        Ok(used)
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
        // The listener is a host-side capability boundary. Do not inherit a
        // permissive umask and accidentally expose the Docker/memory bridge to
        // another local account.
        std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))?;
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
    docker_workload_started_events: u64,
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
            docker_workload_started_events: 0,
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

    pub fn docker_workload_started_events(&self) -> u64 {
        self.docker_workload_started_events
    }

    pub fn docker_completed_stream_events(&self) -> u64 {
        self.docker_completed_stream_events
    }

    pub fn docker_completed_workload_stream_events(&self) -> u64 {
        self.docker_completed_workload_stream_events
    }

    pub fn active_docker_workload_streams(&self) -> u64 {
        self.streams
            .values()
            .filter(|stream| stream.is_docker_workload())
            .count() as u64
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
                if stream.is_docker_workload() {
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
                    let Some(buf) = stream.take_host_payload_after_protocol_detection(buf) else {
                        continue;
                    };
                    if !stream.binary_frame_stream {
                        self.docker_request_bytes =
                            self.docker_request_bytes.saturating_add(buf.len() as u64);
                    }
                    if self.detect_docker_phases {
                        let workload_was_detected = stream.is_docker_workload();
                        if stream.binary_frame_stream {
                            stream.inspect_binary_frame_payloads(&buf);
                        } else {
                            stream.detect_docker_workload_request(&buf);
                        }
                        if !workload_was_detected && stream.is_docker_workload() {
                            self.docker_workload_started_events =
                                self.docker_workload_started_events.saturating_add(1);
                        }
                    }
                    let host_payload = stream.prepare_host_payload_for_guest(buf);
                    let Some((buf, request_complete)) = host_payload.into_forwarded() else {
                        continue;
                    };
                    stream.bytes_sent_to_guest =
                        stream.bytes_sent_to_guest.wrapping_add(buf.len() as u64);
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
        self.enqueue_guest_credit_update(host_port);
    }

    fn handle_guest_packet(&mut self, packet: VsockPacket) -> bool {
        // The guest controls every field in a virtio-vsock frame. Bind a frame
        // to this bridge before using its port as a host-side stream key.
        if packet.src_cid != DEFAULT_GUEST_CID
            || packet.dst_cid != HOST_CID
            || packet.src_port != self.guest_port
        {
            return false;
        }
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
                    let workload_was_detected = stream.is_docker_workload();
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
                        if !workload_was_detected && stream.is_docker_workload() {
                            self.docker_workload_started_events =
                                self.docker_workload_started_events.saturating_add(1);
                        }
                    }
                    stream.observe_guest_response(&packet.payload);
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

    fn finish_pending_guest_shutdowns_after_transport_drain(&mut self) {
        let mut resets = Vec::new();
        let mut credit_updates = Vec::new();
        for (host_port, stream) in &mut self.streams {
            stream.note_transport_drain_after_guest_shutdown();
            if stream.flush_host_output().is_err() {
                stream.reset = true;
                resets.push((*host_port, stream.forward_count()));
            } else if let Some(fwd_cnt) = stream.take_guest_credit_update() {
                credit_updates.push((*host_port, fwd_cnt));
            }
        }
        for (host_port, fwd_cnt) in resets {
            self.pending_guest_packets.push_back(VsockPacket::reset(
                host_port,
                self.guest_port,
                fwd_cnt,
            ));
        }
        for (host_port, fwd_cnt) in credit_updates {
            self.pending_guest_packets
                .push_back(VsockPacket::credit_update(
                    host_port,
                    self.guest_port,
                    fwd_cnt,
                ));
        }
    }

    fn enqueue_guest_credit_update(&mut self, host_port: u32) {
        let fwd_cnt = self
            .streams
            .get_mut(&host_port)
            .and_then(HostUnixVsockStream::take_guest_credit_update);
        if let Some(fwd_cnt) = fwd_cnt {
            self.pending_guest_packets
                .push_back(VsockPacket::credit_update(
                    host_port,
                    self.guest_port,
                    fwd_cnt,
                ));
        }
    }
}

#[derive(Debug)]
struct HostUnixVsockStream {
    socket: UnixStream,
    bytes_received_from_guest: u64,
    bytes_forwarded_to_host: u64,
    last_advertised_guest_forward_count: u32,
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
    docker_response_phase_line_buffer: Vec<u8>,
    response_framing: HostResponseFraming,
    guest_shutdown_transport_drained: bool,
    docker_workload_request_prefix: Vec<u8>,
    host_request_observed: Vec<u8>,
    host_request_complete: bool,
    host_request_forwarding_started: bool,
    host_request_streaming_upgrade: bool,
    host_protocol_buffer: Vec<u8>,
    host_protocol_known: bool,
    binary_frame_stream: bool,
    binary_frame_inspection_header: Vec<u8>,
    binary_frame_inspection_payload_remaining: usize,
    binary_frame_inspection_tcp_data: bool,
    binary_frame_inspection_disabled: bool,
}

impl HostUnixVsockStream {
    fn new(socket: UnixStream) -> Self {
        Self {
            socket,
            bytes_received_from_guest: 0,
            bytes_forwarded_to_host: 0,
            last_advertised_guest_forward_count: 0,
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
            docker_response_phase_line_buffer: Vec::new(),
            response_framing: HostResponseFraming::default(),
            guest_shutdown_transport_drained: false,
            docker_workload_request_prefix: Vec::new(),
            host_request_observed: Vec::new(),
            host_request_complete: false,
            host_request_forwarding_started: false,
            host_request_streaming_upgrade: false,
            host_protocol_buffer: Vec::new(),
            host_protocol_known: false,
            binary_frame_stream: false,
            binary_frame_inspection_header: Vec::new(),
            binary_frame_inspection_payload_remaining: 0,
            binary_frame_inspection_tcp_data: false,
            binary_frame_inspection_disabled: false,
        }
    }

    fn observe_host_protocol(&mut self, payload: &[u8]) {
        if self.host_protocol_known {
            return;
        }
        self.host_protocol_buffer.extend_from_slice(payload);
        if self.host_protocol_buffer.len() >= CONJET_BINARY_FRAME_MAGIC.len() {
            self.binary_frame_stream = self.host_protocol_buffer[..CONJET_BINARY_FRAME_MAGIC.len()]
                == CONJET_BINARY_FRAME_MAGIC;
            self.host_protocol_known = true;
        }
    }

    fn take_host_payload_after_protocol_detection(&mut self, payload: Vec<u8>) -> Option<Vec<u8>> {
        if !self.host_protocol_known {
            return None;
        }
        if self.host_protocol_buffer.is_empty() {
            Some(payload)
        } else {
            Some(std::mem::take(&mut self.host_protocol_buffer))
        }
    }

    fn inspect_binary_frame_payloads(&mut self, mut payload: &[u8]) {
        if self.binary_frame_inspection_disabled {
            return;
        }

        while !payload.is_empty() {
            if self.binary_frame_inspection_payload_remaining > 0 {
                let count = payload
                    .len()
                    .min(self.binary_frame_inspection_payload_remaining);
                if self.binary_frame_inspection_tcp_data {
                    self.detect_docker_workload_request(&payload[..count]);
                }
                self.binary_frame_inspection_payload_remaining -= count;
                payload = &payload[count..];
                if self.binary_frame_inspection_payload_remaining == 0 {
                    self.binary_frame_inspection_tcp_data = false;
                }
                continue;
            }

            let needed = CONJET_BINARY_FRAME_HEADER_LEN
                .saturating_sub(self.binary_frame_inspection_header.len());
            let count = payload.len().min(needed);
            self.binary_frame_inspection_header
                .extend_from_slice(&payload[..count]);
            payload = &payload[count..];
            if self.binary_frame_inspection_header.len() < CONJET_BINARY_FRAME_HEADER_LEN {
                break;
            }

            let header = &self.binary_frame_inspection_header;
            let payload_len =
                u32::from_be_bytes([header[16], header[17], header[18], header[19]]) as usize;
            if header[..CONJET_BINARY_FRAME_MAGIC.len()] != CONJET_BINARY_FRAME_MAGIC
                || header[4] != CONJET_BINARY_FRAME_VERSION
                || payload_len > MAX_CONJET_BINARY_FRAME_PAYLOAD
            {
                self.binary_frame_inspection_header.clear();
                self.binary_frame_inspection_disabled = true;
                return;
            }
            self.binary_frame_inspection_tcp_data = header[5] == CONJET_BINARY_FRAME_TCP_DATA;
            self.binary_frame_inspection_payload_remaining = payload_len;
            self.binary_frame_inspection_header.clear();
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

    fn prepare_host_payload_for_guest(&mut self, payload: Vec<u8>) -> HostRequestPayload {
        if self.binary_frame_stream {
            return HostRequestPayload::Forward {
                payload,
                request_complete: false,
            };
        }

        if self.host_request_forwarding_started {
            if self.host_request_streaming_upgrade {
                return HostRequestPayload::Forward {
                    payload,
                    request_complete: false,
                };
            }
            let request_complete = self.observe_host_request_bytes(&payload);
            return HostRequestPayload::Forward {
                payload,
                request_complete,
            };
        }

        const MAX_OBSERVED_REQUEST: usize = 1024 * 1024;
        if self.host_request_observed.len() < MAX_OBSERVED_REQUEST {
            let remaining = MAX_OBSERVED_REQUEST - self.host_request_observed.len();
            self.host_request_observed
                .extend_from_slice(&payload[..payload.len().min(remaining)]);
        }

        let Some(header_end) = http_header_end(&self.host_request_observed) else {
            if self.host_request_observed.len() >= MAX_OBSERVED_REQUEST {
                self.host_request_forwarding_started = true;
                let buffered = std::mem::take(&mut self.host_request_observed);
                return HostRequestPayload::Forward {
                    payload: buffered,
                    request_complete: false,
                };
            }
            return HostRequestPayload::Pending;
        };

        let is_container_create = http_request_path(&self.host_request_observed[..header_end])
            .is_some_and(docker_path_is_container_create);
        let required = http_request_bytes_required_for_guest_shutdown(&self.host_request_observed);
        let streaming_upgrade =
            http_request_is_streaming_upgrade(&self.host_request_observed[..header_end]);

        if is_container_create
            && !required.is_some_and(|bytes| self.host_request_observed.len() >= bytes)
        {
            return HostRequestPayload::Pending;
        }

        self.host_request_forwarding_started = true;
        if streaming_upgrade {
            self.host_request_streaming_upgrade = true;
        }
        let request_complete =
            required.is_some_and(|bytes| self.host_request_observed.len() >= bytes);
        if request_complete {
            self.host_request_complete = true;
        }
        let buffered = if is_container_create || request_complete || streaming_upgrade {
            std::mem::take(&mut self.host_request_observed)
        } else {
            self.host_request_observed.clone()
        };
        let payload = if is_container_create {
            rewrite_docker_create_service_cgroup_parent(&buffered).unwrap_or(buffered)
        } else {
            buffered
        };
        HostRequestPayload::Forward {
            payload,
            request_complete,
        }
    }

    fn detect_docker_workload_request(&mut self, payload: &[u8]) {
        if self.docker_workload_detected {
            return;
        }
        let remaining = MAX_DOCKER_WORKLOAD_REQUEST_PREFIX_BYTES
            .saturating_sub(self.docker_workload_request_prefix.len());
        if remaining > 0 {
            self.docker_workload_request_prefix
                .extend_from_slice(&payload[..payload.len().min(remaining)]);
        }
        if docker_workload_request_detected(&self.docker_workload_request_prefix) {
            self.docker_workload_detected = true;
            self.docker_workload_request_prefix.clear();
        } else if self.docker_workload_request_prefix.len()
            >= MAX_DOCKER_WORKLOAD_REQUEST_PREFIX_BYTES
            || http_header_end(&self.docker_workload_request_prefix).is_some()
        {
            self.docker_workload_request_prefix.clear();
        }
    }

    fn is_docker_workload(&self) -> bool {
        self.docker_workload_detected || self.docker_response_phase_detected
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
        docker_phase_marker_count(line)
    }

    fn observe_guest_response(&mut self, payload: &[u8]) {
        if !self.binary_frame_stream {
            self.response_framing.observe(payload);
        }
        if self.guest_shutdown_pending && !self.response_framing.is_complete() {
            self.guest_shutdown_transport_drained = false;
        }
    }

    fn forward_count(&self) -> u32 {
        // `fwd_cnt` is a receive acknowledgement to the guest.  Advancing it
        // when bytes merely enter `host_output` lets a fast guest accumulate
        // an unbounded host-side queue; acknowledge only completed socket
        // writes so virtio-vsock credit provides the backpressure.
        self.bytes_forwarded_to_host as u32
    }

    fn take_guest_credit_update(&mut self) -> Option<u32> {
        let fwd_cnt = self.forward_count();
        if fwd_cnt == self.last_advertised_guest_forward_count {
            return None;
        }
        self.last_advertised_guest_forward_count = fwd_cnt;
        Some(fwd_cnt)
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
                    self.bytes_forwarded_to_host =
                        self.bytes_forwarded_to_host.wrapping_add(count as u64);
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
        if self.guest_shutdown_pending
            && self.host_output.is_empty()
            && self.response_framing.permits_guest_shutdown(
                self.guest_shutdown_transport_drained,
                self.binary_frame_stream,
            )
            && !self.guest_shutdown
        {
            let _ = self.socket.shutdown(Shutdown::Write);
            self.guest_shutdown = true;
            self.guest_shutdown_pending = false;
        }
    }

    fn note_transport_drain_after_guest_shutdown(&mut self) {
        if self.guest_shutdown_pending && self.response_framing.is_close_delimited() {
            self.guest_shutdown_transport_drained = true;
            self.finish_guest_shutdown_if_drained();
        }
    }

    fn finished(&self) -> bool {
        self.reset
            || (self.guest_shutdown && self.host_shutdown_sent && self.host_output.is_empty())
    }
}

/// Tracks the response framing without retaining response bodies.  A guest
/// vsock shutdown only tells us that a peer wants to close; it is not a proof
/// that all data work has already reached the virtqueue.  HTTP framing gives a
/// precise, allocation-bounded completion boundary for Docker API streams.
#[derive(Debug)]
enum HostResponseFraming {
    DetectingHeaders(Vec<u8>),
    ContentLength { remaining: u64 },
    Chunked(HttpChunkedResponseDecoder),
    CloseDelimited,
    Complete,
}

impl Default for HostResponseFraming {
    fn default() -> Self {
        Self::DetectingHeaders(Vec::new())
    }
}

impl HostResponseFraming {
    fn observe(&mut self, payload: &[u8]) {
        match self {
            Self::DetectingHeaders(headers) => {
                let available = MAX_HTTP_RESPONSE_HEADER_BYTES.saturating_sub(headers.len());
                headers.extend_from_slice(&payload[..payload.len().min(available)]);
                let Some(header_end) = http_header_end(headers) else {
                    if headers.len() >= MAX_HTTP_RESPONSE_HEADER_BYTES {
                        *self = Self::CloseDelimited;
                    }
                    return;
                };
                let trailing = headers[header_end..].to_vec();
                let next = http_response_framing(&headers[..header_end]);
                *self = next;
                if !trailing.is_empty() {
                    self.observe(&trailing);
                }
            }
            Self::ContentLength { remaining } => {
                *remaining = remaining.saturating_sub(payload.len() as u64);
                if *remaining == 0 {
                    *self = Self::Complete;
                }
            }
            Self::Chunked(decoder) => match decoder.observe(payload) {
                Ok(true) => *self = Self::Complete,
                Ok(false) => {}
                Err(()) => *self = Self::CloseDelimited,
            },
            Self::CloseDelimited | Self::Complete => {}
        }
    }

    fn is_complete(&self) -> bool {
        matches!(self, Self::Complete)
    }

    fn is_close_delimited(&self) -> bool {
        matches!(self, Self::CloseDelimited)
    }

    fn has_no_response_bytes(&self) -> bool {
        matches!(self, Self::DetectingHeaders(headers) if headers.is_empty())
    }

    fn permits_guest_shutdown(&self, transport_drained: bool, binary_frame_stream: bool) -> bool {
        self.is_complete()
            || (transport_drained
                && (binary_frame_stream
                    || self.is_close_delimited()
                    || self.has_no_response_bytes()))
    }
}

fn http_response_framing(headers: &[u8]) -> HostResponseFraming {
    let text = String::from_utf8_lossy(headers);
    let Some(status_line) = text.lines().next() else {
        return HostResponseFraming::CloseDelimited;
    };
    let mut status_parts = status_line.split_whitespace();
    let version = status_parts.next().unwrap_or_default();
    let status = status_parts
        .next()
        .and_then(|value| value.parse::<u16>().ok());
    if !version.starts_with("HTTP/") {
        return HostResponseFraming::CloseDelimited;
    }
    if status.is_some_and(|value| (100..200).contains(&value) && value != 101) {
        // Informational responses precede the response that carries the body.
        return HostResponseFraming::default();
    }
    if status.is_some_and(|value| matches!(value, 101 | 204 | 304)) {
        return HostResponseFraming::Complete;
    }

    let lower = text.to_ascii_lowercase();
    if lower.lines().any(|line| {
        let Some((name, value)) = line.split_once(':') else {
            return false;
        };
        name.trim() == "transfer-encoding"
            && value
                .split(',')
                .any(|encoding| encoding.trim() == "chunked")
    }) {
        return HostResponseFraming::Chunked(HttpChunkedResponseDecoder::default());
    }
    if let Some(length) = lower.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        (name.trim() == "content-length")
            .then(|| value.trim().parse::<u64>().ok())
            .flatten()
    }) {
        return if length == 0 {
            HostResponseFraming::Complete
        } else {
            HostResponseFraming::ContentLength { remaining: length }
        };
    }
    HostResponseFraming::CloseDelimited
}

#[derive(Debug, Default)]
struct HttpChunkedResponseDecoder {
    state: HttpChunkedResponseState,
    line: Vec<u8>,
}

#[derive(Debug, Default)]
enum HttpChunkedResponseState {
    #[default]
    ChunkSize,
    ChunkData {
        remaining: u64,
    },
    ChunkTerminator {
        saw_carriage_return: bool,
    },
    Trailers,
}

impl HttpChunkedResponseDecoder {
    /// Returns `Ok(true)` only after the terminal zero-sized chunk and all
    /// trailers have been consumed.  The retained line buffer is capped so a
    /// malformed stream cannot grow the VMM's host memory with its body size.
    fn observe(&mut self, payload: &[u8]) -> Result<bool, ()> {
        let mut offset = 0usize;
        while offset < payload.len() {
            match &mut self.state {
                HttpChunkedResponseState::ChunkSize => {
                    if !append_http_line(&mut self.line, payload, &mut offset)? {
                        return Ok(false);
                    }
                    let size_text = std::str::from_utf8(&self.line[..self.line.len() - 2])
                        .map_err(|_| ())?
                        .split(';')
                        .next()
                        .unwrap_or_default()
                        .trim();
                    let size = u64::from_str_radix(size_text, 16).map_err(|_| ())?;
                    self.line.clear();
                    self.state = if size == 0 {
                        HttpChunkedResponseState::Trailers
                    } else {
                        HttpChunkedResponseState::ChunkData { remaining: size }
                    };
                }
                HttpChunkedResponseState::ChunkData { remaining } => {
                    let remaining_usize = usize::try_from(*remaining).unwrap_or(usize::MAX);
                    let consumed = (payload.len() - offset).min(remaining_usize);
                    offset += consumed;
                    *remaining = remaining.saturating_sub(consumed as u64);
                    if *remaining > 0 {
                        return Ok(false);
                    }
                    self.state = HttpChunkedResponseState::ChunkTerminator {
                        saw_carriage_return: false,
                    };
                }
                HttpChunkedResponseState::ChunkTerminator {
                    saw_carriage_return,
                } => {
                    if !*saw_carriage_return {
                        if payload[offset] != b'\r' {
                            return Err(());
                        }
                        *saw_carriage_return = true;
                        offset += 1;
                        continue;
                    }
                    if payload[offset] != b'\n' {
                        return Err(());
                    }
                    offset += 1;
                    self.state = HttpChunkedResponseState::ChunkSize;
                }
                HttpChunkedResponseState::Trailers => {
                    if !append_http_line(&mut self.line, payload, &mut offset)? {
                        return Ok(false);
                    }
                    if self.line == b"\r\n" {
                        return Ok(true);
                    }
                    self.line.clear();
                }
            }
        }
        Ok(false)
    }
}

fn append_http_line(line: &mut Vec<u8>, payload: &[u8], offset: &mut usize) -> Result<bool, ()> {
    while *offset < payload.len() {
        line.push(payload[*offset]);
        *offset += 1;
        if line.len() > MAX_HTTP_CHUNK_LINE_BYTES {
            return Err(());
        }
        if line.ends_with(b"\r\n") {
            return Ok(true);
        }
    }
    Ok(false)
}

enum HostRequestPayload {
    Pending,
    Forward {
        payload: Vec<u8>,
        request_complete: bool,
    },
}

impl HostRequestPayload {
    fn into_forwarded(self) -> Option<(Vec<u8>, bool)> {
        match self {
            HostRequestPayload::Pending => None,
            HostRequestPayload::Forward {
                payload,
                request_complete,
            } => Some((payload, request_complete)),
        }
    }
}

fn http_request_bytes_required_for_guest_shutdown(buffer: &[u8]) -> Option<usize> {
    let header_end = http_header_end(buffer)?;
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

fn http_header_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| index + 4)
}

fn http_request_path(header: &[u8]) -> Option<&str> {
    let text = std::str::from_utf8(header).ok()?;
    let request_line = text.lines().next()?;
    let mut parts = request_line.split_whitespace();
    let _method = parts.next()?;
    parts.next()
}

fn http_request_is_streaming_upgrade(header: &[u8]) -> bool {
    let headers = String::from_utf8_lossy(header).to_ascii_lowercase();
    headers.contains(" /grpc ")
        || headers.contains("connection: upgrade")
        || headers.contains("upgrade: h2c")
}

fn docker_path_is_container_create(path: &str) -> bool {
    let path_only = path.split_once('?').map_or(path, |(path, _)| path);
    let components = path_only
        .split('/')
        .filter(|component| !component.is_empty())
        .collect::<Vec<_>>();
    if components.len() >= 2 && components[0] == "containers" && components[1] == "create" {
        return true;
    }
    components.len() >= 3
        && components[0].starts_with('v')
        && components[1] == "containers"
        && components[2] == "create"
}

fn rewrite_docker_create_service_cgroup_parent(request: &[u8]) -> Option<Vec<u8>> {
    let header_end = http_header_end(request)?;
    let header = std::str::from_utf8(&request[..header_end]).ok()?;
    let mut lines = header.split("\r\n").filter(|line| !line.is_empty());
    let request_line = lines.next()?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next()?;
    let path = request_parts.next()?;
    let version = request_parts.next().unwrap_or("HTTP/1.1");
    if method != "POST" || !docker_path_is_container_create(path) {
        return None;
    }

    let mut headers = Vec::new();
    let mut saw_host = false;
    let mut transfer_encoding = String::new();
    let mut content_length = None;
    for line in lines {
        let (name, value) = line.split_once(':')?;
        let lower = name.trim().to_ascii_lowercase();
        if lower == "host" {
            saw_host = true;
        }
        if lower == "transfer-encoding" {
            transfer_encoding = value.trim().to_ascii_lowercase();
        }
        if lower == "content-length" {
            content_length = value.trim().parse::<usize>().ok();
        }
        headers.push((name.to_string(), value.trim().to_string()));
    }
    if transfer_encoding
        .split(',')
        .any(|encoding| encoding.trim() == "chunked")
    {
        return None;
    }
    let body_length = content_length?;
    let body_start = header_end;
    let body_end = body_start.checked_add(body_length)?;
    let body = request.get(body_start..body_end)?;
    if docker_create_body_is_build_related(body) {
        return None;
    }

    let mut root = serde_json::from_slice::<Value>(body).ok()?;
    let root_object = root.as_object_mut()?;
    let labels = root_object
        .get("Labels")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let compose_project = labels
        .get("com.docker.compose.project")
        .and_then(Value::as_str);
    let compose_service = labels
        .get("com.docker.compose.service")
        .and_then(Value::as_str);
    let container_name = docker_container_name_from_path(path);
    let service_key =
        service_memory_slice_key(compose_project, compose_service, container_name.as_deref());
    let cgroup_parent = format!("conjet-services-conjet-service-{service_key}.slice");

    let host_config = root_object
        .entry("HostConfig")
        .or_insert_with(|| Value::Object(Map::new()));
    if !host_config.is_object() {
        *host_config = Value::Object(Map::new());
    }
    let host_config = host_config.as_object_mut()?;
    if let Some(existing) = host_config.get("CgroupParent").and_then(Value::as_str) {
        if !existing.trim().is_empty() && !is_conjet_default_service_cgroup_parent(existing) {
            return None;
        }
    }
    host_config.insert("CgroupParent".to_string(), Value::String(cgroup_parent));

    let new_body = serde_json::to_vec(&root).ok()?;
    let mut rewritten = Vec::new();
    rewritten.extend_from_slice(format!("{method} {path} {version}\r\n").as_bytes());
    for (name, value) in headers {
        let lower = name.trim().to_ascii_lowercase();
        if lower == "content-length" || lower == "transfer-encoding" {
            continue;
        }
        rewritten.extend_from_slice(format!("{name}: {value}\r\n").as_bytes());
    }
    if !saw_host {
        rewritten.extend_from_slice(b"Host: docker\r\n");
    }
    rewritten.extend_from_slice(format!("Content-Length: {}\r\n\r\n", new_body.len()).as_bytes());
    rewritten.extend_from_slice(&new_body);
    Some(rewritten)
}

fn docker_create_body_is_build_related(body: &[u8]) -> bool {
    let text = String::from_utf8_lossy(&body[..body.len().min(8192)]);
    text.contains("moby.buildkit")
        || text.contains("moby/buildkit")
        || text.contains("moby\\/buildkit")
        || text.contains("buildx_buildkit")
        || text.contains("buildkitd")
}

fn is_conjet_default_service_cgroup_parent(value: &str) -> bool {
    let normalized = value.trim().trim_matches('/');
    normalized == "conjet-services.slice" || normalized == "conjet.slice/conjet-services.slice"
}

fn docker_container_name_from_path(path: &str) -> Option<String> {
    let query = path.split_once('?')?.1;
    for item in query.split('&') {
        let (name, value) = item.split_once('=')?;
        if name == "name" {
            return Some(percent_decode(value));
        }
    }
    None
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Ok(hex) = std::str::from_utf8(&bytes[index + 1..index + 3]) {
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    output.push(byte);
                    index += 3;
                    continue;
                }
            }
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn service_memory_slice_key(
    compose_project: Option<&str>,
    compose_service: Option<&str>,
    container_name: Option<&str>,
) -> String {
    let raw = match (compose_project, compose_service, container_name) {
        (Some(project), Some(service), _) if !project.is_empty() && !service.is_empty() => {
            format!("{project}_{service}")
        }
        (_, Some(service), _) if !service.is_empty() => service.to_string(),
        (_, _, Some(name)) if !name.is_empty() => name.to_string(),
        _ => "container".to_string(),
    };
    let sanitized = raw
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>();
    let compact = sanitized
        .split('_')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("_")
        .to_ascii_lowercase();
    let key = if compact.is_empty() {
        "container".to_string()
    } else {
        compact
    };
    key.chars().take(80).collect()
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
    let Some(header_end) = http_header_end(payload) else {
        return false;
    };
    let Some(header) = payload.get(..header_end) else {
        return false;
    };
    let Ok(text) = std::str::from_utf8(header) else {
        return false;
    };
    let Some(request_line) = text.lines().next() else {
        return false;
    };
    let mut parts = request_line.split_whitespace();
    matches!(parts.next(), Some("POST")) && parts.next().is_some_and(docker_path_is_workload)
}

fn docker_path_is_workload(path: &str) -> bool {
    let path_only = path.split_once('?').map_or(path, |(path, _)| path);
    let components = path_only
        .split('/')
        .filter(|component| !component.is_empty())
        .collect::<Vec<_>>();
    match components.as_slice() {
        ["build"] | ["images", "create"] => true,
        [version, "build"] | [version, "images", "create"] => version.starts_with('v'),
        _ => false,
    }
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
    fn bridge_rejects_forged_guest_packet_identity() {
        let (_client, server) = UnixStream::pair().unwrap();
        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.pending_guest_packets.clear();

        let mut forged = VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID + 1,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_CREDIT_UPDATE,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: Vec::new(),
        };
        assert!(!bridge.handle_guest_packet(forged.clone()));

        forged.dst_cid = HOST_CID;
        forged.src_port = DOCKER_BRIDGE_PORT + 1;
        assert!(!bridge.handle_guest_packet(forged.clone()));

        forged.src_port = DOCKER_BRIDGE_PORT;
        assert!(bridge.handle_guest_packet(forged));
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
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: b"HTTP/1.1 204 No Content\r\n\r\n".to_vec(),
        }));

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
        bridge.finish_pending_guest_shutdowns_after_transport_drain();
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
        assert_eq!(bridge.docker_workload_started_events(), 0);
    }

    #[test]
    fn fragmented_binary_tcp_build_request_starts_workload_and_forwards_all_bytes() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let mut wire = conjet_binary_frame(14, 7, b"127.0.0.1 2375");
        wire.extend_from_slice(&conjet_binary_frame(
            CONJET_BINARY_FRAME_TCP_DATA,
            7,
            b"POST /v1.52/build?t=idle-cycle HTTP/1.1\r\nHost: docker\r\n\r\n",
        ));
        let first_split = 3;
        let second_split = CONJET_BINARY_FRAME_HEADER_LEN + 3;
        client.write_all(&wire[..first_split]).unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();
        assert_eq!(bridge.pending_guest_packets.len(), 1);
        assert_eq!(bridge.pending_guest_packets[0].op, OP_REQUEST);

        client.write_all(&wire[first_split..second_split]).unwrap();
        bridge.poll_host_streams();
        client.write_all(&wire[second_split..]).unwrap();
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_workload_started_events(), 1);
        assert_eq!(bridge.active_docker_workload_streams(), 1);
        assert_eq!(bridge.docker_request_bytes(), 0);
        let forwarded = bridge
            .pending_guest_packets
            .iter()
            .filter(|packet| packet.op == OP_RW)
            .flat_map(|packet| packet.payload.iter().copied())
            .collect::<Vec<_>>();
        assert_eq!(forwarded, wire);
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
    fn guest_credit_advances_only_after_host_output_is_written() {
        let (mut client, server) = UnixStream::pair().unwrap();
        server.set_nonblocking(true).unwrap();
        let mut stream = HostUnixVsockStream::new(server);
        let payload = vec![b'x'; 1024];

        stream.enqueue_host_output(&payload);
        stream.bytes_received_from_guest = payload.len() as u64;
        assert_eq!(stream.forward_count(), 0);
        assert_eq!(stream.take_guest_credit_update(), None);

        stream.flush_host_output().unwrap();
        let mut received = vec![0u8; payload.len()];
        client.read_exact(&mut received).unwrap();
        assert_eq!(received, payload);
        assert_eq!(stream.forward_count(), payload.len() as u32);
        assert_eq!(
            stream.take_guest_credit_update(),
            Some(payload.len() as u32)
        );
    }

    #[test]
    fn transmit_notification_drains_every_pending_batch() {
        let guest_base = 0x4000_0000;
        let queue_size = (TRANSMIT_DRAIN_BATCH_LIMIT + 1) as u32;
        let memory = GuestMemory::anonymous(0x20_000).unwrap();
        let queue = VirtioQueueState {
            size: queue_size,
            ready: true,
            descriptor_address: guest_base + 0x1000,
            driver_address: guest_base + 0x3000,
            device_address: guest_base + 0x4000,
        };
        let plan = crate::devices::virtio::VirtioMmioDevicePlan::new(
            crate::devices::virtio::VirtioDeviceKind::Vsock,
            0,
        );
        let mut transport = VirtioMmioDevice::new(plan, configuration(DEFAULT_GUEST_CID));
        let packet = VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_CREDIT_UPDATE,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: Vec::new(),
        }
        .encode();

        for index in 0..queue_size as usize {
            let payload_address = guest_base + 0x8000 + (index as u64 * 0x100);
            memory
                .write_at(guest_base, payload_address, &packet)
                .unwrap();
            let mut descriptor = [0u8; 16];
            descriptor[..8].copy_from_slice(&payload_address.to_le_bytes());
            descriptor[8..12].copy_from_slice(&(packet.len() as u32).to_le_bytes());
            memory
                .write_at(
                    guest_base,
                    queue.descriptor_address + (index as u64 * 16),
                    &descriptor,
                )
                .unwrap();
            memory
                .write_le_u16(
                    guest_base,
                    queue.driver_address + 4 + (index as u64 * 2),
                    index as u16,
                )
                .unwrap();
        }
        memory
            .write_le_u16(guest_base, queue.driver_address + 2, queue_size as u16)
            .unwrap();

        let mut handler = VsockQueueHandler::new();
        let used = handler
            .handle_available(
                queue,
                VsockQueue::Transmit as u32,
                &mut transport,
                &memory,
                guest_base,
            )
            .unwrap();

        assert_eq!(used.len(), queue_size as usize);
        assert_eq!(
            handler.transmit_executor.last_available_index,
            queue_size as u16
        );
        assert_eq!(
            memory
                .read_le_u16(guest_base, queue.device_address + 2)
                .unwrap(),
            queue_size as u16
        );
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
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: b"HTTP/1.1 204 No Content\r\n\r\n".to_vec(),
        }));
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
        bridge.finish_pending_guest_shutdowns_after_transport_drain();
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
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".to_vec(),
        }));

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
        bridge.finish_pending_guest_shutdowns_after_transport_drain();
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

        assert_eq!(bridge.pending_guest_packets.len(), 1);
        assert_eq!(bridge.pending_guest_packets[0].op, OP_REQUEST);

        client.write_all(b"cd").unwrap();
        bridge.poll_host_streams();
        assert_eq!(bridge.pending_guest_packets.len(), 3);
        assert_eq!(bridge.pending_guest_packets[1].op, OP_RW);
        assert_eq!(bridge.pending_guest_packets[2].op, OP_SHUTDOWN);
    }

    #[test]
    fn docker_container_create_rewrites_broad_conjet_cgroup_parent() {
        let body = br#"{"Image":"postgres:16","Labels":{"com.docker.compose.project":"chum-mem","com.docker.compose.service":"postgres"},"HostConfig":{"CgroupParent":"conjet-services.slice"}}"#;
        let request = format!(
            "POST /v1.52/containers/create?name=chum-mem-postgres-1 HTTP/1.1\r\nHost: docker\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            String::from_utf8_lossy(body)
        );
        let rewritten = rewrite_docker_create_service_cgroup_parent(request.as_bytes()).unwrap();
        let rewritten_text = String::from_utf8(rewritten).unwrap();

        assert!(rewritten_text.contains(
            r#""CgroupParent":"conjet-services-conjet-service-chum_mem_postgres.slice""#
        ));
        assert!(!rewritten_text.contains(r#""CgroupParent":"conjet-services.slice""#));
    }

    #[test]
    fn docker_container_create_stream_rewrites_before_guest_payload() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let body =
            br#"{"Image":"alpine:3.20","HostConfig":{"CgroupParent":"conjet-services.slice"}}"#;
        let request = format!(
            "POST /v1.52/containers/create?name=conjet-slice-probe HTTP/1.1\r\nHost: docker\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            String::from_utf8_lossy(body)
        );
        client.write_all(request.as_bytes()).unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert_eq!(bridge.pending_guest_packets.len(), 3);
        assert_eq!(bridge.pending_guest_packets[0].op, OP_REQUEST);
        assert_eq!(bridge.pending_guest_packets[1].op, OP_RW);
        assert_eq!(bridge.pending_guest_packets[2].op, OP_SHUTDOWN);
        let payload = String::from_utf8_lossy(&bridge.pending_guest_packets[1].payload);
        assert!(payload.contains(
            r#""CgroupParent":"conjet-services-conjet-service-conjet_slice_probe.slice""#
        ));
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
        assert_eq!(bridge.active_docker_workload_streams(), 1);
        assert_eq!(bridge.docker_workload_started_events(), 1);

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".to_vec(),
        }));

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
        bridge.finish_pending_guest_shutdowns_after_transport_drain();
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_completed_stream_events(), 1);
        assert_eq!(bridge.docker_completed_workload_stream_events(), 1);
        assert_eq!(bridge.active_docker_workload_streams(), 0);
        assert_eq!(bridge.docker_workload_started_events(), 1);
    }

    #[test]
    fn versioned_docker_build_without_query_starts_workload() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST /v1.52/build HTTP/1.1\r\nHost: docker\r\nContent-Length: 0\r\n\r\n")
            .unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();

        assert_eq!(bridge.active_docker_workload_streams(), 1);
        assert_eq!(bridge.docker_workload_started_events(), 1);
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
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".to_vec(),
        }));

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
        bridge.finish_pending_guest_shutdowns_after_transport_drain();
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

        let body = b"#1 DONE 0.1s\n";
        let payload = [
            b"HTTP/1.1 200 OK\r\nContent-Length: ".as_slice(),
            body.len().to_string().as_bytes(),
            b"\r\n\r\n",
            body,
        ]
        .concat();

        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload,
        }));

        let mut received = [0u8; 64];
        let _ = client.read(&mut received).unwrap();
        assert_eq!(bridge.docker_workload_started_events(), 1);
        assert_eq!(bridge.active_docker_workload_streams(), 1);

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
        bridge.finish_pending_guest_shutdowns_after_transport_drain();
        bridge.poll_host_streams();

        assert_eq!(bridge.docker_phase_response_events(), 1);
        assert_eq!(bridge.docker_completed_stream_events(), 1);
        assert_eq!(bridge.docker_completed_workload_stream_events(), 1);
        assert_eq!(bridge.docker_workload_started_events(), 1);
    }

    #[test]
    fn chunked_response_waits_for_terminal_chunk_before_half_closing_host_client() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST /v1.52/build?t=demo HTTP/1.1\r\nHost: docker\r\n\r\n")
            .unwrap();
        client.shutdown(Shutdown::Write).unwrap();

        let mut bridge = HostUnixVsockBridgeState::new(DOCKER_BRIDGE_PORT, 49_152, true);
        bridge.accept_stream(server);
        bridge.poll_host_streams();
        bridge.pending_guest_packets.clear();

        let body = vec![b'x'; 1024];
        let mut payload =
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".to_vec();
        payload.extend_from_slice(format!("{:x}\r\n", body.len()).as_bytes());
        payload.extend_from_slice(&body);
        payload.extend_from_slice(b"\r\n");
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
        assert!(bridge.streams.contains_key(&49_152));
        assert!(!bridge.streams[&49_152].guest_shutdown);

        let terminal = b"0\r\n\r\n".to_vec();
        assert!(bridge.handle_guest_packet(VsockPacket {
            src_cid: DEFAULT_GUEST_CID,
            dst_cid: HOST_CID,
            src_port: DOCKER_BRIDGE_PORT,
            dst_port: 49_152,
            op: OP_RW,
            flags: 0,
            buf_alloc: DEFAULT_BUF_ALLOC,
            fwd_cnt: 0,
            payload: terminal.clone(),
        }));
        assert!(bridge.streams[&49_152].guest_shutdown);

        let mut received = vec![0u8; payload.len() + terminal.len()];
        client.read_exact(&mut received).unwrap();
        assert_eq!(&received[..payload.len()], payload);
        assert_eq!(&received[payload.len()..], terminal);
        let mut eof = [0u8; 1];
        assert_eq!(client.read(&mut eof).unwrap(), 0);

        bridge.poll_host_streams();
        assert_eq!(bridge.docker_completed_stream_events(), 1);
        assert_eq!(bridge.docker_completed_workload_stream_events(), 1);
    }

    #[test]
    fn chunked_response_decoder_tracks_large_body_without_retaining_it() {
        let body = vec![b'x'; 2 * 1024 * 1024];
        let mut decoder = HttpChunkedResponseDecoder::default();
        assert!(!decoder
            .observe(format!("{:x}\r\n", body.len()).as_bytes())
            .unwrap());
        assert!(!decoder.observe(&body).unwrap());
        assert_eq!(decoder.line.len(), 0);
        assert!(!decoder.observe(b"\r\n0\r\n").unwrap());
        assert!(decoder.observe(b"\r\n").unwrap());
        assert_eq!(decoder.line.len(), 2);
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

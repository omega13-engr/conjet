//! Nonblocking Ethernet transport to the VPN-compatible host network helper.

use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

pub const MAX_FRAME: usize = 1514;
pub const MAX_PENDING: usize = 256;
const READY: &[u8; 7] = b"CJNET1\n";

#[derive(Debug)]
pub struct HostNetworkSession {
    io: FrameStream,
    child: Child,
}

impl HostNetworkSession {
    pub fn start() -> io::Result<Self> {
        let executable = match std::env::var_os("CONJET_NETWORK_HELPER_PATH") {
            Some(path) => PathBuf::from(path),
            None => std::env::current_exe()?.with_file_name("conjet-network"),
        };
        let (mut stream, child_stream) = UnixStream::pair()?;
        let mut child = Command::new(&executable)
            .stdin(Stdio::from(std::os::fd::OwnedFd::from(child_stream)))
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            // Use macOS system resolution, including VPN-scoped DNS.
            .env("GODEBUG", "netdns=cgo")
            .spawn()
            .map_err(|error| io::Error::new(error.kind(), format!(
                "cannot start network helper {}: {error}; build/bundle conjet-network or explicitly select CONJET_NETWORK_EGRESS=vmnet",
                executable.display()
            )))?;
        let mut initialize = || -> io::Result<()> {
            stream.set_read_timeout(Some(Duration::from_secs(10)))?;
            let mut ready = [0u8; READY.len()];
            stream.read_exact(&mut ready)?;
            if &ready != READY {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "network helper protocol mismatch",
                ));
            }
            stream.set_read_timeout(None)?;
            stream.set_nonblocking(true)
        };
        if let Err(error) = initialize() {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
        Ok(Self {
            io: FrameStream::new(stream),
            child,
        })
    }

    pub fn transmit_capacity(&mut self) -> io::Result<usize> {
        self.io.flush()?;
        Ok(MAX_PENDING - self.io.outbound.len())
    }

    pub fn write_packets(&mut self, packets: &[Vec<u8>]) -> io::Result<usize> {
        let count = self.io.enqueue(packets)?;
        self.io.flush()?;
        Ok(count)
    }

    pub fn read_packets(&mut self, max_packets: usize) -> io::Result<Vec<Vec<u8>>> {
        self.io.flush()?;
        self.io.receive(max_packets)
    }
}

impl Drop for HostNetworkSession {
    fn drop(&mut self) {
        let _ = self.io.stream.shutdown(std::net::Shutdown::Both);
        // Reap exactly our child; do not leave a networking process behind
        // when the VM exits, including initialization/runtime errors.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Debug)]
struct FrameStream {
    stream: UnixStream,
    outbound: VecDeque<Vec<u8>>,
    written: usize,
    header: [u8; 4],
    header_read: usize,
    payload: Vec<u8>,
    payload_read: usize,
}

impl FrameStream {
    fn new(stream: UnixStream) -> Self {
        Self {
            stream,
            outbound: VecDeque::new(),
            written: 0,
            header: [0; 4],
            header_read: 0,
            payload: Vec::new(),
            payload_read: 0,
        }
    }

    fn enqueue(&mut self, packets: &[Vec<u8>]) -> io::Result<usize> {
        // Validate the entire batch before accepting any descriptor.
        if packets
            .iter()
            .any(|packet| !(14..=MAX_FRAME).contains(&packet.len()))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid Ethernet frame size",
            ));
        }
        let count = packets.len().min(MAX_PENDING - self.outbound.len());
        for packet in packets.iter().take(count) {
            let mut frame = Vec::with_capacity(packet.len() + 4);
            frame.extend_from_slice(&(packet.len() as u32).to_be_bytes());
            frame.extend_from_slice(packet);
            self.outbound.push_back(frame);
        }
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        // Bound host work per VM dispatch. Preserve partial writes and let
        // socket backpressure hold descriptors instead of dropping packets.
        for _ in 0..64 {
            let Some(frame) = self.outbound.front() else {
                break;
            };
            match self.stream.write(&frame[self.written..]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "network helper closed",
                    ))
                }
                Ok(count) => {
                    self.written += count;
                    if self.written == frame.len() {
                        self.outbound.pop_front();
                        self.written = 0;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }

    fn receive(&mut self, max_packets: usize) -> io::Result<Vec<Vec<u8>>> {
        let mut packets = Vec::new();
        while packets.len() < max_packets {
            if self.header_read < 4 {
                match self.stream.read(&mut self.header[self.header_read..]) {
                    Ok(0) => {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            "network helper closed during frame header",
                        ))
                    }
                    Ok(count) => self.header_read += count,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error),
                }
                if self.header_read != 4 {
                    continue;
                }
                let len = u32::from_be_bytes(self.header) as usize;
                if !(14..=MAX_FRAME).contains(&len) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "network helper frame exceeds MTU or is truncated",
                    ));
                }
                self.payload.resize(len, 0);
            }
            match self.stream.read(&mut self.payload[self.payload_read..]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "network helper closed during frame payload",
                    ))
                }
                Ok(count) => self.payload_read += count,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
            if self.payload_read == self.payload.len() {
                packets.push(std::mem::take(&mut self.payload));
                self.header_read = 0;
                self.payload_read = 0;
            }
        }
        Ok(packets)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (FrameStream, UnixStream) {
        let (local, remote) = UnixStream::pair().unwrap();
        local.set_nonblocking(true).unwrap();
        (FrameStream::new(local), remote)
    }

    #[test]
    fn fragmented_header_and_payload_survive_would_block() {
        let (mut framed, mut peer) = pair();
        peer.write_all(&[0, 0]).unwrap();
        assert!(framed.receive(1).unwrap().is_empty());
        peer.write_all(&[0, 14, 1, 2]).unwrap();
        assert!(framed.receive(1).unwrap().is_empty());
        peer.write_all(&[3; 12]).unwrap();
        assert_eq!(
            framed.receive(1).unwrap(),
            vec![[vec![1, 2], vec![3; 12]].concat()]
        );
    }

    #[test]
    fn invalid_length_is_rejected_before_allocating_payload() {
        for len in [0u32, 13, 1515, u32::MAX] {
            let (mut framed, mut peer) = pair();
            peer.write_all(&len.to_be_bytes()).unwrap();
            assert_eq!(
                framed.receive(1).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
            assert_eq!(framed.payload.capacity(), 0);
        }
    }

    #[test]
    fn queue_is_bounded_and_preserves_stream_order() {
        let (mut framed, mut peer) = pair();
        let packets: Vec<_> = (0..MAX_PENDING).map(|i| vec![i as u8; 14]).collect();
        assert_eq!(framed.enqueue(&packets).unwrap(), MAX_PENDING);
        assert_eq!(framed.enqueue(&[vec![0; 14]]).unwrap(), 0);
        for _ in 0..4 {
            framed.flush().unwrap();
        }
        let mut actual = vec![0; MAX_PENDING * 18];
        peer.read_exact(&mut actual).unwrap();
        for (i, frame) in actual.chunks_exact(18).enumerate() {
            assert_eq!(&frame[..4], &14u32.to_be_bytes());
            assert!(frame[4..].iter().all(|byte| *byte == i as u8));
        }
        assert!(framed.outbound.is_empty());
    }

    #[test]
    fn peer_disconnect_is_reported() {
        let (mut framed, peer) = pair();
        drop(peer);
        assert_eq!(
            framed.receive(1).unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    }

    #[test]
    fn socket_backpressure_preserves_every_frame() {
        use std::os::fd::AsRawFd;
        let (mut framed, mut peer) = pair();
        let small_buffer: libc::c_int = 1024;
        assert_eq!(
            unsafe {
                libc::setsockopt(
                    framed.stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_SNDBUF,
                    &small_buffer as *const _ as *const libc::c_void,
                    std::mem::size_of_val(&small_buffer) as libc::socklen_t,
                )
            },
            0
        );
        peer.set_nonblocking(true).unwrap();
        let packets: Vec<_> = (0..MAX_PENDING).map(|i| vec![i as u8; MAX_FRAME]).collect();
        framed.enqueue(&packets).unwrap();
        framed.flush().unwrap();
        assert!(
            !framed.outbound.is_empty(),
            "test must encounter backpressure"
        );
        let expected: Vec<_> = packets
            .iter()
            .flat_map(|p| [(p.len() as u32).to_be_bytes().to_vec(), p.clone()].concat())
            .collect();
        let mut actual = Vec::new();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while actual.len() < expected.len() {
            assert!(std::time::Instant::now() < deadline, "transport stalled");
            framed.flush().unwrap();
            let mut chunk = [0u8; 333];
            match peer.read(&mut chunk) {
                Ok(0) => panic!("unexpected EOF"),
                Ok(n) => actual.extend_from_slice(&chunk[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => std::thread::yield_now(),
                Err(e) => panic!("{e}"),
            }
        }
        assert_eq!(actual, expected);
        assert!(framed.outbound.is_empty());
        assert_eq!(framed.written, 0);
    }
}

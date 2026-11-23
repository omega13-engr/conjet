use std::io;
use std::os::fd::{AsRawFd, RawFd};
use std::time::{Duration, Instant};

const BUFFER_BYTES: usize = 8192;
const CHECK_INTERVAL: Duration = Duration::from_millis(50);

struct Direction {
    bytes: [u8; BUFFER_BYTES],
    start: usize,
    end: usize,
    eof: bool,
    half_closed: bool,
}

impl Direction {
    fn new() -> Self {
        Self {
            bytes: [0; BUFFER_BYTES],
            start: 0,
            end: 0,
            eof: false,
            half_closed: false,
        }
    }

    fn buffered(&self) -> bool {
        self.start < self.end
    }

    fn read(&mut self, source: RawFd) -> io::Result<bool> {
        let count = unsafe {
            libc::recv(
                source,
                self.bytes.as_mut_ptr().cast(),
                self.bytes.len(),
                libc::MSG_DONTWAIT,
            )
        };
        match count {
            0 => {
                self.eof = true;
                Ok(true)
            }
            1.. => {
                self.start = 0;
                self.end = count as usize;
                Ok(true)
            }
            _ => retryable(),
        }
    }

    fn write(&mut self, destination: RawFd) -> io::Result<bool> {
        let bytes = &self.bytes[self.start..self.end];
        let count = unsafe {
            libc::send(
                destination,
                bytes.as_ptr().cast(),
                bytes.len(),
                libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT,
            )
        };
        match count {
            0 => Err(io::ErrorKind::WriteZero.into()),
            1.. => {
                self.start += count as usize;
                Ok(true)
            }
            _ => retryable(),
        }
    }

    fn finish(&mut self, destination: RawFd) -> io::Result<()> {
        if self.eof && !self.buffered() && !self.half_closed {
            if unsafe { libc::shutdown(destination, libc::SHUT_WR) } != 0 {
                return Err(io::Error::last_os_error());
            }
            self.half_closed = true;
        }
        Ok(())
    }
}

fn retryable() -> io::Result<bool> {
    let error = io::Error::last_os_error();
    if matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
    ) {
        Ok(false)
    } else {
        Err(error)
    }
}

/// Move bytes between two connected sockets with one bounded buffer per
/// direction. A read EOF is propagated after its pending bytes drain.
pub fn pump(
    left: &impl AsRawFd,
    right: &impl AsRawFd,
    idle_limit: Duration,
    cancelled: impl Fn() -> bool,
) -> io::Result<()> {
    let fds = [left.as_raw_fd(), right.as_raw_fd()];
    let mut direction = [Direction::new(), Direction::new()];
    let mut last_activity = Instant::now();
    loop {
        if cancelled() {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        for source in 0..2 {
            direction[source].finish(fds[1 - source])?;
        }
        if direction.iter().all(|flow| flow.half_closed) {
            return Ok(());
        }
        let remaining = idle_limit.saturating_sub(last_activity.elapsed());
        if remaining.is_zero() {
            return Err(io::ErrorKind::TimedOut.into());
        }
        let timeout = remaining.min(CHECK_INTERVAL).as_millis().max(1) as i32;
        let mut items = [0, 1].map(|side| {
            let mut events = 0;
            if !direction[side].eof && !direction[side].buffered() {
                events |= libc::POLLIN;
            }
            if direction[1 - side].buffered() {
                events |= libc::POLLOUT;
            }
            libc::pollfd {
                fd: if events != 0 { fds[side] } else { -1 },
                events,
                revents: 0,
            }
        });
        if unsafe { libc::poll(items.as_mut_ptr(), items.len() as _, timeout) } < 0 {
            retryable()?;
            continue;
        }
        for source in 0..2 {
            let flow = &mut direction[source];
            let read_ready = items[source].revents
                & (libc::POLLIN | libc::POLLHUP | libc::POLLERR | libc::POLLNVAL)
                != 0;
            let write_ready = items[1 - source].revents
                & (libc::POLLOUT | libc::POLLHUP | libc::POLLERR | libc::POLLNVAL)
                != 0;
            let activity = if flow.buffered() && write_ready {
                flow.write(fds[1 - source])?
            } else if !flow.buffered() && !flow.eof && read_ready {
                flow.read(fds[source])?
            } else {
                false
            };
            if activity {
                last_activity = Instant::now();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::Shutdown;
    use std::os::unix::net::UnixStream;
    use std::thread;

    #[test]
    fn flushes_large_stream_and_propagates_half_close_in_both_directions() {
        let (mut client, left) = UnixStream::pair().unwrap();
        let (right, mut server) = UnixStream::pair().unwrap();
        let request = vec![37; 1024 * 1024];
        thread::scope(|scope| {
            let relay = scope.spawn(|| pump(&left, &right, Duration::from_secs(3), || false));
            let remote = scope.spawn(|| {
                let mut payload = Vec::new();
                server.read_to_end(&mut payload).unwrap();
                assert_eq!(payload, request);
                server.write_all(b"after request EOF").unwrap();
                server.shutdown(Shutdown::Write).unwrap();
            });
            client.write_all(&request).unwrap();
            client.shutdown(Shutdown::Write).unwrap();
            let mut reply = String::new();
            client.read_to_string(&mut reply).unwrap();
            assert_eq!(reply, "after request EOF");
            remote.join().unwrap();
            relay.join().unwrap().unwrap();
        });
    }

    #[test]
    fn stops_on_cancellation_and_idle_limit() {
        let (_client, left) = UnixStream::pair().unwrap();
        let (right, _server) = UnixStream::pair().unwrap();
        assert_eq!(
            pump(&left, &right, Duration::from_secs(1), || true)
                .unwrap_err()
                .kind(),
            io::ErrorKind::ConnectionAborted
        );
        assert_eq!(
            pump(&left, &right, Duration::from_millis(20), || false)
                .unwrap_err()
                .kind(),
            io::ErrorKind::TimedOut
        );
    }
}

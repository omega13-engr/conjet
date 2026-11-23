use std::fs::OpenOptions;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use crate::handshake::Key;

pub fn read_key(path: &Path) -> io::Result<Key> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.mode() & 0o077 != 0
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.len() != 32
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "launch key must be a private 32-byte file owned by this user",
        ));
    }
    let mut key = [0; 32];
    file.read_exact(&mut key)?;
    Ok(key)
}

pub struct Shutdown {
    signalled: AtomicBool,
    receiver: UnixStream,
    sender: UnixStream,
}

impl Shutdown {
    pub fn new() -> io::Result<Arc<Self>> {
        let (receiver, sender) = UnixStream::pair()?;
        Ok(Arc::new(Self {
            signalled: AtomicBool::new(false),
            receiver,
            sender,
        }))
    }

    pub fn request(&self) -> io::Result<()> {
        if !self.signalled.swap(true, Ordering::AcqRel) {
            (&self.sender).write_all(&[1])?;
        }
        Ok(())
    }

    pub fn requested(&self) -> bool {
        self.signalled.load(Ordering::Acquire)
    }
}

pub(crate) fn wait(
    fd: RawFd,
    events: i16,
    shutdown: Option<&Shutdown>,
    deadline: Option<Instant>,
) -> io::Result<()> {
    let mut items = [
        libc::pollfd {
            fd,
            events,
            revents: 0,
        },
        libc::pollfd {
            fd: shutdown.map_or(-1, |token| token.receiver.as_raw_fd()),
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    loop {
        if shutdown.is_some_and(Shutdown::requested) {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        let timeout = if let Some(end) = deadline {
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(io::ErrorKind::TimedOut.into());
            }
            left.as_millis().saturating_add(1).min(i32::MAX as u128) as i32
        } else {
            -1
        };
        // Both descriptor owners outlive poll and the array stays valid until it returns.
        let result = unsafe { libc::poll(items.as_mut_ptr(), items.len() as _, timeout) };
        if result > 0 {
            if shutdown.is_some_and(Shutdown::requested) {
                return Err(io::ErrorKind::ConnectionAborted.into());
            }
            return Ok(());
        }
        if result == 0 {
            return Err(io::ErrorKind::TimedOut.into());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

pub struct Stream {
    descriptor: OwnedFd,
    shutdown: Option<Arc<Shutdown>>,
    deadline: Option<Instant>,
}

impl AsRawFd for Stream {
    fn as_raw_fd(&self) -> RawFd {
        self.descriptor.as_raw_fd()
    }
}

impl Stream {
    pub fn unix(stream: UnixStream, shutdown: Option<Arc<Shutdown>>) -> io::Result<Self> {
        stream.set_nonblocking(true)?;
        Ok(Self::nonblocking(stream.into(), shutdown))
    }

    pub(crate) fn nonblocking(descriptor: OwnedFd, shutdown: Option<Arc<Shutdown>>) -> Self {
        Self {
            descriptor,
            shutdown,
            deadline: None,
        }
    }

    pub fn deadline(&mut self, deadline: Option<Instant>) {
        self.deadline = deadline;
    }

    pub fn readable(&self, deadline: Option<Instant>) -> io::Result<()> {
        wait(
            self.descriptor.as_raw_fd(),
            libc::POLLIN,
            self.shutdown.as_deref(),
            deadline,
        )
    }
}

impl Read for Stream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        loop {
            self.readable(self.deadline)?;
            // The owned descriptor and writable slice are valid for the duration of recv.
            let size = unsafe {
                libc::recv(
                    self.descriptor.as_raw_fd(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                    0,
                )
            };
            if size >= 0 {
                return Ok(size as usize);
            }
            let error = io::Error::last_os_error();
            if !matches!(
                error.kind(),
                io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
            ) {
                return Err(error);
            }
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        loop {
            wait(
                self.descriptor.as_raw_fd(),
                libc::POLLOUT,
                self.shutdown.as_deref(),
                self.deadline,
            )?;
            // The owned descriptor and readable slice are valid for the duration of send.
            let size = unsafe {
                libc::send(
                    self.descriptor.as_raw_fd(),
                    buffer.as_ptr().cast(),
                    buffer.len(),
                    libc::MSG_NOSIGNAL,
                )
            };
            if size >= 0 {
                return Ok(size as usize);
            }
            let error = io::Error::last_os_error();
            if !matches!(
                error.kind(),
                io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
            ) {
                return Err(error);
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

use std::ffi::CString;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::socket::{Shutdown, Stream};

const DIRECTORY: &str = "/run/conjet/native-bind";
const LIMIT: usize = 68 * 1024;
const FUSE_MAGIC: u64 = 0x65735546;
const EXCHANGE_BUDGET: Duration = Duration::from_secs(5);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Request {
    pub(crate) boot_id: String,
    pub(crate) lease: String,
    pub(crate) read_only: bool,
}

fn stop_signal(header: &[u8]) -> bool {
    header[..4] == 16u32.to_le_bytes() && header[4..] == [0; 12]
}

pub(crate) fn path(lease: &str) -> io::Result<PathBuf> {
    crate::handshake::unhex::<16>(lease)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid native bind lease"))?;
    Ok(Path::new(DIRECTORY).join(lease))
}

pub(crate) fn source(lease: &str) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path(lease)?)?;
    let mut filesystem = std::mem::MaybeUninit::<libc::statfs>::uninit();
    crate::security::checked(unsafe { libc::fstatfs(file.as_raw_fd(), filesystem.as_mut_ptr()) })?;
    if unsafe { filesystem.assume_init() }.f_type != FUSE_MAGIC {
        return Err(io::Error::other("native bind lease is not mounted"));
    }
    Ok(file)
}

pub(crate) struct Mount {
    endpoint: File,
    path: PathBuf,
    target: CString,
    mounted: bool,
}

impl Mount {
    pub(crate) fn open(request: &Request) -> io::Result<Self> {
        let path = path(&request.lease)?;
        let endpoint = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open("/dev/fuse")?;
        let metadata = endpoint.metadata()?;
        if !metadata.file_type().is_char_device()
            || libc::major(metadata.rdev()) != 10
            || libc::minor(metadata.rdev()) != 229
        {
            return Err(io::Error::other("invalid native FUSE device identity"));
        }
        match DirBuilder::new().mode(0o700).create(DIRECTORY) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let info = fs::symlink_metadata(DIRECTORY)?;
                if !info.is_dir() || info.uid() != 0 || info.mode() & 0o777 != 0o700 {
                    return Err(io::Error::other("invalid native bind directory"));
                }
            }
            Err(error) => return Err(error),
        }
        let target = CString::new(path.as_os_str().as_encoded_bytes())?;
        let options = CString::new(format!(
            "fd={},rootmode=40000,user_id=0,group_id=0,allow_other,default_permissions",
            endpoint.as_raw_fd(),
        ))?;
        DirBuilder::new().mode(0o700).create(&path)?;
        let mut mount = Self {
            endpoint,
            path,
            target,
            mounted: false,
        };
        let flags = libc::MS_NODEV
            | libc::MS_NOSUID
            | libc::MS_NOEXEC
            | if request.read_only {
                libc::MS_RDONLY
            } else {
                0
            };
        crate::security::checked(unsafe {
            libc::mount(
                c"conjet-bind".as_ptr(),
                mount.target.as_ptr(),
                c"fuse".as_ptr(),
                flags,
                options.as_ptr().cast(),
            )
        })?;
        mount.mounted = true;
        Ok(mount)
    }

    fn forward(&mut self, stream: &mut Stream, shutdown: &Shutdown) -> io::Result<()> {
        let mut request = vec![0; LIMIT];
        let mut response = vec![0; LIMIT];
        let mut poll = [
            libc::pollfd {
                fd: stream.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: self.endpoint.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        while !shutdown.requested() {
            let ready = unsafe { libc::poll(poll.as_mut_ptr(), poll.len() as libc::nfds_t, 200) };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
            if poll[0].revents != 0 {
                stream.deadline(Some(Instant::now() + EXCHANGE_BUDGET));
                stream.read_exact(&mut response[..16])?;
                return if stop_signal(&response[..16]) {
                    Ok(())
                } else {
                    Err(io::ErrorKind::InvalidData.into())
                };
            }
            if poll[1].revents == 0 {
                continue;
            }
            let count = match self.endpoint.read(&mut request) {
                Ok(count) if count >= 40 => count,
                Ok(_) => return Err(io::ErrorKind::InvalidData.into()),
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) =>
                {
                    continue;
                }
                Err(error) => return Err(error),
            };
            let opcode = u32::from_le_bytes(request[4..8].try_into().expect("FUSE opcode"));
            stream.deadline(Some(Instant::now() + EXCHANGE_BUDGET));
            stream.write_all(&request[..count])?;
            if matches!(opcode, 2 | 42) {
                continue;
            }
            stream.read_exact(&mut response[..16])?;
            if stop_signal(&response[..16]) {
                return Ok(());
            }
            let length = u32::from_le_bytes(response[..4].try_into().expect("FUSE size")) as usize;
            if !(16..=LIMIT).contains(&length) || response[8..16] != request[8..16] {
                return Err(io::ErrorKind::InvalidData.into());
            }
            stream.read_exact(&mut response[16..length])?;
            if self.endpoint.write(&response[..length])? != length {
                return Err(io::ErrorKind::WriteZero.into());
            }
        }
        Err(io::ErrorKind::Interrupted.into())
    }

    fn close(&mut self) -> io::Result<()> {
        crate::security::checked(unsafe { libc::umount2(self.target.as_ptr(), 0) })?;
        self.mounted = false;
        fs::remove_dir(&self.path)
    }

    pub(crate) fn relay(mut self, stream: &mut Stream, shutdown: &Shutdown) -> io::Result<()> {
        self.forward(stream, shutdown)?;
        self.close()?;
        // A distinguished, request-shaped record confirms mount teardown to
        // the host stream reader. Kernel FUSE opcodes are nonzero.
        let mut acknowledgement = [0; 40];
        acknowledgement[..4].copy_from_slice(&40u32.to_le_bytes());
        stream.deadline(Some(Instant::now() + EXCHANGE_BUDGET));
        stream.write_all(&acknowledgement)
    }
}

impl Drop for Mount {
    fn drop(&mut self) {
        if self.mounted {
            let _ = unsafe { libc::umount2(self.target.as_ptr(), libc::MNT_DETACH) };
        }
        let _ = fs::remove_dir(&self.path);
    }
}

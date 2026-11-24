use std::ffi::CString;
use std::fs::{File, Metadata};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{FileExt, MetadataExt};

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::wire::COPY_LIMIT;

const CHUNK: usize = 8192;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Operation {
    Stat {
        path: String,
    },
    Read {
        path: String,
        identity: Identity,
        offset: u64,
    },
}

#[derive(Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Identity {
    device: u64,
    inode: u64,
    bytes: u64,
    changed: (i64, i64),
    modified: (i64, i64),
}

impl From<&Metadata> for Identity {
    fn from(info: &Metadata) -> Self {
        Self {
            device: info.dev(),
            inode: info.ino(),
            bytes: info.len(),
            changed: (info.ctime(), info.ctime_nsec()),
            modified: (info.mtime(), info.mtime_nsec()),
        }
    }
}

fn valid_path(path: &str) -> bool {
    path.len() <= 1024
        && (path == "/"
            || path
                .strip_prefix('/')
                .is_some_and(|path| path.split('/').all(|part| !matches!(part, "" | "." | ".."))))
        && !path.contains('\0')
}

pub(crate) fn open_path(root: &File, path: &str, flags: i32) -> io::Result<File> {
    if !valid_path(path) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid workload archive path",
        ));
    }
    #[repr(C)]
    struct OpenHow {
        flags: u64,
        mode: u64,
        resolve: u64,
    }
    let path = CString::new(path)?;
    let how = OpenHow {
        flags: (flags | libc::O_CLOEXEC | libc::O_NOFOLLOW) as u64,
        mode: 0,
        resolve: 0x10 | 0x04, // RESOLVE_IN_ROOT | RESOLVE_NO_SYMLINKS
    };
    let descriptor = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            root.as_raw_fd(),
            path.as_ptr(),
            &how,
            std::mem::size_of::<OpenHow>(),
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(descriptor as i32) })
}

pub(crate) fn operate(root: &File, operation: Operation) -> io::Result<Value> {
    match operation {
        Operation::Stat { path } => {
            let info = open_path(root, &path, libc::O_PATH)?.metadata()?;
            if !(info.is_dir() || info.is_file()) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "unsupported workload archive entry",
                ));
            }
            Ok(json!({
                "name":if path=="/" { "/" } else { path.rsplit('/').next().expect("validated path") },
                "directory":info.is_dir(),
                "mode":info.mode() & 0o777,
                "identity":Identity::from(&info),
            }))
        }
        Operation::Read {
            path,
            identity,
            offset,
        } => {
            let file = open_path(root, &path, libc::O_RDONLY | libc::O_NONBLOCK)?;
            let info = file.metadata()?;
            if !info.is_file()
                || identity != Identity::from(&info)
                || identity.bytes > COPY_LIMIT
                || offset >= identity.bytes
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "workload archive file changed or exceeds its bound",
                ));
            }
            let count = (identity.bytes - offset).min(CHUNK as u64) as usize;
            let mut chunk = [0; CHUNK];
            file.read_exact_at(&mut chunk[..count], offset)?;
            if identity != Identity::from(&file.metadata()?) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "workload archive file changed during read",
                ));
            }
            let next = offset + count as u64;
            Ok(json!({
                "offset":offset,"next_offset":next,"eof":next==identity.bytes,
                "data":base64::engine::general_purpose::STANDARD.encode(&chunk[..count]),
            }))
        }
    }
}

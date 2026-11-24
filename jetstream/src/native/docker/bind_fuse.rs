use std::collections::BTreeMap;
use std::ffi::{CStr, CString, OsStr};
use std::fs::{File, Metadata};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, MetadataExt};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use conjet_launch_service::socket::Stream;
use conjet_launch_service::spec::{GID_BASE, UID_BASE};

use super::bind::{component, open_at};

const ROOT: u64 = 1;
const REQUEST_HEADER: usize = 40;
const TRANSFER: usize = 64 * 1024;
const REQUEST_LIMIT: usize = TRANSFER + 4096;
const FILE_LIMIT: u64 = 32 * 1024 * 1024;
const NODE_LIMIT: usize = 512;
const HANDLE_LIMIT: usize = 32;
const HOST_FLAGS: libc::c_int = libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;

fn word(bytes: &[u8], offset: usize) -> io::Result<u32> {
    Ok(u32::from_le_bytes(
        bytes
            .get(offset..offset + 4)
            .ok_or(io::ErrorKind::InvalidData)?
            .try_into()
            .expect("four-byte FUSE field"),
    ))
}

fn wide(bytes: &[u8], offset: usize) -> io::Result<u64> {
    Ok(u64::from_le_bytes(
        bytes
            .get(offset..offset + 8)
            .ok_or(io::ErrorKind::InvalidData)?
            .try_into()
            .expect("eight-byte FUSE field"),
    ))
}

fn put_word(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

fn put_wide(bytes: &mut [u8], offset: usize, value: u64) {
    bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
}

fn name(bytes: &[u8]) -> io::Result<CString> {
    let name = CStr::from_bytes_with_nul(bytes).map_err(|_| io::ErrorKind::InvalidInput)?;
    component(OsStr::from_bytes(name.to_bytes()))
}

fn linux_errno(error: &io::Error) -> i32 {
    match error.raw_os_error() {
        Some(libc::EFBIG) => 27,
        Some(libc::ENOTDIR) => 20,
        Some(libc::EISDIR) => 21,
        Some(libc::EROFS) => 30,
        Some(libc::ESTALE) => 116,
        Some(libc::ENOSYS) => 38,
        Some(libc::ENOSPC) => 28,
        Some(libc::EMFILE) => 24,
        _ => match error.kind() {
            io::ErrorKind::NotFound => 2,
            io::ErrorKind::PermissionDenied => 13,
            io::ErrorKind::AlreadyExists => 17,
            io::ErrorKind::InvalidInput | io::ErrorKind::InvalidData => 22,
            io::ErrorKind::Unsupported => 38,
            _ => 5,
        },
    }
}

struct Node {
    inode: u64,
    name: CString,
}

struct OpenFile {
    file: File,
    node: u64,
    write: bool,
}

struct Files {
    root: File,
    device: u64,
    writable: bool,
    nodes: BTreeMap<u64, Node>,
    handles: BTreeMap<u64, OpenFile>,
    next: u64,
}

impl Files {
    fn new(root: File, writable: bool) -> io::Result<Self> {
        let device = root.metadata()?.dev();
        Ok(Self {
            root,
            device,
            writable,
            nodes: BTreeMap::new(),
            handles: BTreeMap::new(),
            next: ROOT + 1,
        })
    }

    fn id(&mut self) -> u64 {
        let id = self.next;
        self.next += 1;
        id
    }

    fn regular(&self, file: &File) -> io::Result<Metadata> {
        let info = file.metadata()?;
        if !info.is_file()
            || info.dev() != self.device
            || info.nlink() != 1
            || info.uid() != unsafe { libc::geteuid() }
        {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        Ok(info)
    }

    fn entry(&mut self, name: CString, info: &Metadata) -> io::Result<(u64, Vec<u8>)> {
        let existing = self
            .nodes
            .iter()
            .find_map(|(&id, node)| (node.inode == info.ino() && node.name == name).then_some(id));
        let id = if let Some(id) = existing {
            id
        } else {
            if self.nodes.len() >= NODE_LIMIT {
                return Err(io::Error::from_raw_os_error(libc::ENOSPC));
            }
            let id = self.id();
            self.nodes.insert(
                id,
                Node {
                    inode: info.ino(),
                    name,
                },
            );
            id
        };
        let mut out = vec![0; 128];
        put_wide(&mut out, 0, id);
        put_wide(&mut out, 8, id);
        attr(&mut out[40..], id, info);
        Ok((id, out))
    }

    fn reopen(&self, node: u64, flags: libc::c_int) -> io::Result<File> {
        let node = self.nodes.get(&node).ok_or(io::ErrorKind::NotFound)?;
        // Open without truncation until the inode check is complete.
        let file = open_at(
            &self.root,
            &node.name,
            HOST_FLAGS | (flags & !libc::O_TRUNC),
            0,
        )?;
        if self.regular(&file)?.ino() != node.inode {
            return Err(io::Error::from_raw_os_error(libc::ESTALE));
        }
        if flags & libc::O_TRUNC != 0 {
            file.set_len(0)?;
        }
        Ok(file)
    }

    fn require_write(&self) -> io::Result<()> {
        if self.writable {
            Ok(())
        } else {
            Err(io::Error::from_raw_os_error(libc::EROFS))
        }
    }

    fn flags(&self, flags: u32) -> io::Result<(libc::c_int, bool)> {
        let access = match flags & 3 {
            0 => libc::O_RDONLY,
            1 => libc::O_WRONLY,
            2 => libc::O_RDWR,
            _ => return Err(io::ErrorKind::InvalidInput.into()),
        };
        let write = access != libc::O_RDONLY;
        let truncate = flags & 0o1000 != 0;
        if write || truncate {
            self.require_write()?;
        }
        if truncate && !write {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let native = access | if truncate { libc::O_TRUNC } else { 0 };
        Ok((native, write))
    }

    fn handle(&mut self, file: File, node: u64, write: bool) -> io::Result<Vec<u8>> {
        if self.handles.len() >= HANDLE_LIMIT {
            return Err(io::Error::from_raw_os_error(libc::EMFILE));
        }
        let id = self.id();
        self.handles.insert(id, OpenFile { file, node, write });
        let mut out = vec![0; 16];
        put_wide(&mut out, 0, id);
        Ok(out)
    }

    fn opened(&self, node: u64, body: &[u8]) -> io::Result<&OpenFile> {
        self.handles
            .get(&wide(body, 0)?)
            .filter(|handle| handle.node == node)
            .ok_or_else(|| io::ErrorKind::NotFound.into())
    }

    fn dispatch(&mut self, opcode: u32, node: u64, body: &[u8]) -> io::Result<Vec<u8>> {
        match opcode {
            1 if node == ROOT => {
                // FUSE_LOOKUP
                let name = name(body)?;
                let file = open_at(&self.root, &name, HOST_FLAGS | libc::O_RDONLY, 0)?;
                let info = self.regular(&file)?;
                self.entry(name, &info).map(|(_, entry)| entry)
            }
            3 => {
                // FUSE_GETATTR
                let info = if node == ROOT {
                    self.root.metadata()?
                } else {
                    self.reopen(node, libc::O_RDONLY)?.metadata()?
                };
                let mut out = vec![0; 104];
                attr(&mut out[16..], node, &info);
                Ok(out)
            }
            14 => {
                // FUSE_OPEN
                let (flags, write) = self.flags(word(body, 0)?)?;
                let file = self.reopen(node, flags)?;
                self.handle(file, node, write)
            }
            15 => {
                // FUSE_READ
                let file = self.opened(node, body)?;
                let mut out = vec![0; (word(body, 16)? as usize).min(TRANSFER)];
                let count = file.file.read_at(&mut out, wide(body, 8)?)?;
                out.truncate(count);
                Ok(out)
            }
            16 => {
                // FUSE_WRITE
                let file = self.opened(node, body)?;
                if !file.write {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                let offset = wide(body, 8)?;
                let size = word(body, 16)? as usize;
                if size > TRANSFER || offset.saturating_add(size as u64) > FILE_LIMIT {
                    return Err(io::Error::from_raw_os_error(libc::EFBIG));
                }
                let data = body.get(40..40 + size).ok_or(io::ErrorKind::InvalidData)?;
                let count = file.file.write_at(data, offset)?;
                let mut out = vec![0; 8];
                put_word(&mut out, 0, count as u32);
                Ok(out)
            }
            17 => {
                // FUSE_STATFS
                let mut out = vec![0; 80];
                let mut raw = std::mem::MaybeUninit::<libc::statfs>::uninit();
                if unsafe { libc::fstatfs(self.root.as_raw_fd(), raw.as_mut_ptr()) } != 0 {
                    return Err(io::Error::last_os_error());
                }
                let raw = unsafe { raw.assume_init() };
                put_wide(&mut out, 0, raw.f_blocks);
                put_wide(&mut out, 8, raw.f_bfree);
                put_wide(&mut out, 16, raw.f_bavail);
                put_wide(&mut out, 24, raw.f_files);
                put_wide(&mut out, 32, raw.f_ffree);
                put_word(&mut out, 40, raw.f_bsize);
                put_word(&mut out, 44, 255);
                put_word(&mut out, 48, raw.f_bsize);
                Ok(out)
            }
            18 => {
                // FUSE_RELEASE
                self.opened(node, body)?;
                self.handles.remove(&wide(body, 0)?);
                Ok(Vec::new())
            }
            20 => {
                // FUSE_FSYNC
                self.opened(node, body)?.file.sync_all()?;
                Ok(Vec::new())
            }
            25 => {
                // FUSE_FLUSH
                self.opened(node, body)?;
                Ok(Vec::new())
            }
            26 => init(body),
            34 => Ok(Vec::new()), // FUSE_ACCESS, checked by the kernel using our attributes.
            35 if node == ROOT => {
                // FUSE_CREATE
                self.require_write()?;
                if self.handles.len() >= HANDLE_LIMIT || self.nodes.len() >= NODE_LIMIT {
                    return Err(io::Error::from_raw_os_error(libc::ENOSPC));
                }
                let (flags, write) = self.flags(word(body, 0)?)?;
                let mode = (word(body, 4)? & 0o777) as libc::mode_t;
                let name = name(body.get(16..).ok_or(io::ErrorKind::InvalidData)?)?;
                let file = open_at(
                    &self.root,
                    &name,
                    HOST_FLAGS | flags | libc::O_CREAT | libc::O_EXCL,
                    mode,
                )?;
                let info = self.regular(&file)?;
                let (node, mut entry) = self.entry(name, &info)?;
                entry.extend(self.handle(file, node, write)?);
                Ok(entry)
            }
            38 => Ok(Vec::new()), // FUSE_DESTROY
            _ => Err(io::Error::from_raw_os_error(libc::ENOSYS)),
        }
    }
}

fn attr(out: &mut [u8], id: u64, info: &Metadata) {
    put_wide(out, 0, id);
    put_wide(out, 8, info.size());
    put_wide(out, 16, info.blocks());
    put_wide(out, 24, info.atime().max(0) as u64);
    put_wide(out, 32, info.mtime().max(0) as u64);
    put_wide(out, 40, info.ctime().max(0) as u64);
    put_word(out, 48, info.atime_nsec() as u32);
    put_word(out, 52, info.mtime_nsec() as u32);
    put_word(out, 56, info.ctime_nsec() as u32);
    put_word(out, 60, info.mode() & 0o170777);
    put_word(out, 64, info.nlink().min(u32::MAX as u64) as u32);
    put_word(out, 68, UID_BASE);
    put_word(out, 72, GID_BASE);
    put_word(out, 80, 4096);
}

fn init(body: &[u8]) -> io::Result<Vec<u8>> {
    if word(body, 0)? != 7 || word(body, 4)? < 31 {
        return Err(io::ErrorKind::Unsupported.into());
    }
    let flags = word(body, 12)?;
    let mut out = vec![0; 64];
    put_word(&mut out, 0, 7);
    put_word(&mut out, 4, 31);
    put_word(&mut out, 12, flags & (1 << 5 | 1 << 22)); // BIG_WRITES | MAX_PAGES
    put_word(&mut out, 20, TRANSFER as u32);
    put_word(&mut out, 24, 1);
    out[28..30].copy_from_slice(&16u16.to_le_bytes());
    Ok(out)
}

pub(super) fn serve(
    mut stream: Stream,
    writer: &Mutex<Stream>,
    source: File,
    writable: bool,
) -> io::Result<()> {
    let mut files = Files::new(source, writable)?;
    let mut buffer = vec![0; REQUEST_LIMIT];
    loop {
        stream.read_exact(&mut buffer[..REQUEST_HEADER])?;
        let length = word(&buffer, 0)? as usize;
        if !(REQUEST_HEADER..=REQUEST_LIMIT).contains(&length) {
            return Err(io::ErrorKind::InvalidData.into());
        }
        stream.read_exact(&mut buffer[REQUEST_HEADER..length])?;
        let opcode = word(&buffer, 4)?;
        if opcode == 0 {
            return if length == REQUEST_HEADER && buffer[4..REQUEST_HEADER] == [0; 36] {
                Ok(())
            } else {
                Err(io::ErrorKind::InvalidData.into())
            };
        }
        if matches!(opcode, 2 | 42) {
            continue;
        } // FORGET, BATCH_FORGET
        let unique = wide(&buffer, 8)?;
        let node = wide(&buffer, 16)?;
        let result = files.dispatch(opcode, node, &buffer[REQUEST_HEADER..length]);
        let (payload, error) = match result {
            Ok(payload) => (payload, 0),
            Err(error) => (Vec::new(), -linux_errno(&error)),
        };
        let mut header = [0; 16];
        put_word(&mut header, 0, (16 + payload.len()) as u32);
        put_word(&mut header, 4, error as u32);
        put_wide(&mut header, 8, unique);
        let mut writer = writer.lock().unwrap();
        writer.deadline(Some(Instant::now() + Duration::from_secs(5)));
        writer.write_all(&header)?;
        writer.write_all(&payload)?;
    }
}

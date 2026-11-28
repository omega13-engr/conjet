use std::ffi::CString;
use std::fs::{self, File, Metadata};
use std::io::{self, Read, Seek, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{FileExt, MetadataExt};
use std::time::{Duration, Instant};

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::image_store::ConnectionId;
use crate::wire::COPY_LIMIT;

mod tree;

const CHUNK: usize = 8192;
const STREAM_CHUNK: usize = 64 * 1024;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Operation {
    Stat {
        path: String,
    },
    List {
        path: String,
        identity: Identity,
    },
    Read {
        path: String,
        identity: Identity,
        offset: u64,
    },
    Begin(UploadSpec),
    Write {
        offset: u64,
        data: String,
    },
    Commit,
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

pub(crate) struct DownloadRequest {
    pub(crate) path: String,
    pub(crate) identity: Identity,
}

impl DownloadRequest {
    pub(crate) fn open(&self, root: &File) -> io::Result<File> {
        let file = open_path(root, &self.path, libc::O_RDONLY | libc::O_NONBLOCK)?;
        self.verify(&file)?;
        Ok(file)
    }

    pub(crate) fn size(&self) -> u64 {
        self.identity.bytes
    }

    pub(crate) fn verify(&self, file: &File) -> io::Result<()> {
        let info = file.metadata()?;
        if !info.is_file() || self.identity != Identity::from(&info) || self.size() > COPY_LIMIT {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "workload archive file changed or exceeds its bound",
            ));
        }
        Ok(())
    }

    pub(crate) fn transfer(
        &self,
        file: &mut File,
        mut send: impl FnMut(&[u8]) -> io::Result<()>,
    ) -> io::Result<()> {
        let mut left = self.size();
        let mut chunk = [0; STREAM_CHUNK];
        while left != 0 {
            let count = left.min(chunk.len() as u64) as usize;
            file.read_exact(&mut chunk[..count])?;
            send(&chunk[..count])?;
            left -= count as u64;
        }
        self.verify(file)
    }

    pub(crate) fn verify_path(&self, root: &File) -> io::Result<()> {
        self.verify(&open_path(root, &self.path, libc::O_PATH)?)
    }
}

fn visible_owner(id: u32, base: u32) -> u32 {
    id.checked_sub(base)
        .filter(|id| *id < crate::spec::ID_MAP_WIDTH)
        .unwrap_or(65534)
}

fn link_target(entry: &File) -> io::Result<String> {
    let mut target = [0; 1025];
    let size = unsafe {
        libc::readlinkat(
            entry.as_raw_fd(),
            c"".as_ptr(),
            target.as_mut_ptr().cast(),
            target.len(),
        )
    };
    match usize::try_from(size) {
        Ok(size) if (1..target.len()).contains(&size) => {
            String::from_utf8(target[..size].to_vec()).map_err(|_| rejected())
        }
        Ok(_) => Err(rejected()),
        Err(_) => Err(io::Error::last_os_error()),
    }
}

fn list_directory(root: &File, path: &str, identity: &Identity) -> io::Result<Value> {
    let directory = open_path(root, path, libc::O_RDONLY | libc::O_DIRECTORY)?;
    if Identity::from(&directory.metadata()?) != *identity {
        return Err(rejected());
    }
    let mut names = Vec::new();
    let mut bytes = 0;
    for entry in fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))? {
        let name = entry?.file_name().into_string().map_err(|_| rejected())?;
        bytes += name.len();
        if names.len() == 256 || bytes > 8192 || name.chars().any(char::is_control) {
            return Err(rejected());
        }
        names.push(name);
    }
    if Identity::from(&directory.metadata()?) != *identity {
        return Err(rejected());
    }
    names.sort_unstable();
    Ok(json!({"entries": names}))
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
    open_beneath(root, path, flags, false)
}

fn open_beneath(root: &File, path: &str, flags: i32, same_mount: bool) -> io::Result<File> {
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
        // RESOLVE_IN_ROOT | RESOLVE_NO_SYMLINKS, optionally RESOLVE_NO_XDEV.
        resolve: 0x10 | 0x04 | u64::from(same_mount),
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

#[derive(Default)]
pub(crate) struct Store {
    pending: Option<Upload>,
    stream_active: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct UploadSpec {
    path: String,
    name: String,
    size: u64,
    mode: u32,
    digest: [u8; 32],
    #[serde(default)]
    tree: bool,
}

pub(crate) struct Upload {
    owner: ConnectionId,
    workload: String,
    expires: Instant,
    parent: File,
    path: String,
    name: CString,
    file: File,
    size: u64,
    mode: u32,
    digest: [u8; 32],
    tree: bool,
    offset: u64,
    hash: Sha256,
    staging: Staging,
}

fn rejected() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "invalid workload archive upload",
    )
}

#[derive(Debug)]
pub(crate) struct PublishError(pub(crate) &'static str, io::Error);

impl std::fmt::Display for PublishError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.0, self.1)
    }
}

impl std::error::Error for PublishError {}

fn publishing<T>(operation: &'static str, result: io::Result<T>) -> io::Result<T> {
    result.map_err(|error| io::Error::other(PublishError(operation, error)))
}

fn with_filesystem_owner<T>(uid: u32, operation: impl FnOnce() -> io::Result<T>) -> io::Result<T> {
    use crate::spec::GID_BASE;
    // Linux filesystem credentials are thread-local. Keep the server's
    // real and effective IDs so the original filesystem IDs can be restored.
    let previous_gid = unsafe { libc::setfsgid(GID_BASE) };
    let previous_uid = unsafe { libc::setfsuid(uid) };
    let result = if unsafe { libc::setfsuid(u32::MAX) } == uid as i32
        && unsafe { libc::setfsgid(u32::MAX) } == GID_BASE as i32
    {
        operation()
    } else {
        Err(io::Error::other(
            "mapped workload filesystem credentials unavailable",
        ))
    };
    unsafe {
        libc::setfsuid(previous_uid as u32);
        libc::setfsgid(previous_gid as u32);
    }
    result
}

fn destination(parent: &File, name: &CString) -> io::Result<bool> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } == 0
    {
        let kind = unsafe { stat.assume_init() }.st_mode & libc::S_IFMT;
        return if kind == libc::S_IFREG {
            Ok(true)
        } else {
            Err(rejected())
        };
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::NotFound {
        Ok(false)
    } else {
        Err(error)
    }
}

impl Upload {
    fn open(
        root: &File,
        spec: UploadSpec,
        owner: ConnectionId,
        workload: &str,
        workload_uid: u32,
    ) -> io::Result<Self> {
        if spec.size > COPY_LIMIT
            || spec.mode & !0o777 != 0
            || spec.name.len() > 255
            || spec.name.contains('/')
            || matches!(spec.name.as_str(), "" | "." | "..")
        {
            return Err(rejected());
        }
        let name = CString::new(spec.name)?;
        let parent = open_beneath(root, &spec.path, libc::O_PATH | libc::O_DIRECTORY, true)?;
        if !spec.tree {
            destination(&parent, &name)?;
        }
        let (staging, file) = Staging::create(&parent, owner, workload_uid)?;
        Ok(Self {
            owner,
            workload: workload.into(),
            expires: Instant::now() + Duration::from_secs(30),
            parent,
            path: spec.path,
            name,
            file,
            size: spec.size,
            mode: spec.mode,
            digest: spec.digest,
            tree: spec.tree,
            offset: 0,
            hash: Sha256::new(),
            staging,
        })
    }

    fn write_bytes(&mut self, bytes: &[u8]) -> io::Result<()> {
        let next = self.offset + bytes.len() as u64;
        if bytes.is_empty() || next > self.size {
            return Err(rejected());
        }
        self.file.write_all(bytes)?;
        self.hash.update(bytes);
        self.offset = next;
        Ok(())
    }

    fn write(&mut self, offset: u64, data: &str) -> io::Result<Value> {
        if offset != self.offset || data.is_empty() || data.len() > CHUNK.div_ceil(3) * 4 {
            return Err(rejected());
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|_| rejected())?;
        if bytes.len() > CHUNK {
            return Err(rejected());
        }
        self.write_bytes(&bytes)?;
        Ok(json!({"offset":self.offset}))
    }

    pub(crate) fn receive(
        &mut self,
        mut read: impl FnMut(&mut [u8]) -> io::Result<()>,
    ) -> io::Result<()> {
        let mut chunk = [0; STREAM_CHUNK];
        while self.offset < self.size {
            let count = (self.size - self.offset).min(chunk.len() as u64) as usize;
            read(&mut chunk[..count])?;
            self.write_bytes(&chunk[..count])?;
        }
        Ok(())
    }

    pub(crate) fn commit(mut self, root: &File) -> io::Result<Value> {
        if self.offset != self.size || <[u8; 32]>::from(self.hash.finalize_reset()) != self.digest {
            return Err(rejected());
        }
        let current =
            open_beneath(root, &self.path, libc::O_PATH | libc::O_DIRECTORY, true)?.metadata()?;
        let original = self.parent.metadata()?;
        if (current.dev(), current.ino()) != (original.dev(), original.ino()) {
            return Err(rejected());
        }
        if self.tree {
            publishing("archive_tree_rewind", self.file.rewind())?;
            tree::publish(&self.parent, &self.staging, &mut self.file)?;
            publishing("archive_stage_cleanup", self.staging.remove(true))?;
            return Ok(json!({"offset":self.size}));
        }
        let replace = destination(&self.parent, &self.name)?;
        let file = self.file.as_raw_fd();
        publishing(
            "archive_ownership",
            crate::security::checked(unsafe {
                libc::fchown(file, crate::spec::UID_BASE, crate::spec::GID_BASE)
            }),
        )?;
        publishing(
            "archive_permissions",
            with_filesystem_owner(crate::spec::UID_BASE, || {
                crate::security::checked(unsafe { libc::fchmod(file, self.mode) })
            }),
        )?;
        publishing("archive_sync", self.file.sync_all())?;
        let rename = |flags: libc::c_uint| {
            crate::security::checked(unsafe {
                libc::syscall(
                    libc::SYS_renameat2,
                    self.staging.directory.as_raw_fd(),
                    c"payload".as_ptr(),
                    self.parent.as_raw_fd(),
                    self.name.as_ptr(),
                    flags,
                ) as i32
            })
        };
        if replace {
            publishing("archive_replace", rename(0))?;
        } else {
            publishing(
                "archive_create",
                with_filesystem_owner(self.staging.uid, || rename(libc::RENAME_NOREPLACE)),
            )?;
        }
        publishing("archive_stage_cleanup", self.staging.remove(false))?;
        Ok(json!({"offset":self.size}))
    }
}

struct Staging {
    parent: File,
    directory: File,
    name: CString,
    uid: u32,
    publisher: u32,
}

impl Staging {
    fn remove(&self, remove_payload: bool) -> io::Result<()> {
        if remove_payload {
            unsafe { libc::unlinkat(self.directory.as_raw_fd(), c"payload".as_ptr(), 0) };
            let root = format!("/proc/self/fd/{}/tree", self.directory.as_raw_fd());
            match fs::remove_dir_all(root) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        let current = unsafe {
            libc::openat(
                self.parent.as_raw_fd(),
                self.name.as_ptr(),
                libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if current < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::NotFound {
                Ok(())
            } else {
                Err(error)
            };
        }
        let current = unsafe { File::from_raw_fd(current) }.metadata()?;
        let expected = self.directory.metadata()?;
        if (current.dev(), current.ino()) != (expected.dev(), expected.ino()) {
            return Err(rejected());
        }
        crate::security::checked(unsafe {
            libc::unlinkat(
                self.parent.as_raw_fd(),
                self.name.as_ptr(),
                libc::AT_REMOVEDIR,
            )
        })
    }

    fn create(parent: &File, owner: ConnectionId, workload_uid: u32) -> io::Result<(Self, File)> {
        use std::fmt::Write as _;

        let mut uid = crate::spec::ID_MAP_WIDTH - 1;
        if uid == workload_uid {
            uid -= 1;
        }
        let uid = crate::spec::UID_BASE + uid;
        let creator = parent.metadata()?.uid();
        let creator = if (crate::spec::UID_BASE..crate::spec::UID_BASE + crate::spec::ID_MAP_WIDTH)
            .contains(&creator)
        {
            creator
        } else {
            uid
        };
        let mut name = String::from(".conjet-upload-");
        for byte in owner {
            write!(name, "{byte:02x}").expect("format connection ID");
        }
        let name = CString::new(name)?;
        let parent = parent.try_clone()?;
        let dir = parent.as_raw_fd();
        publishing(
            "archive_stage_create",
            with_filesystem_owner(creator, || {
                crate::security::checked(unsafe { libc::mkdirat(dir, name.as_ptr(), 0o700) })
            }),
        )?;
        let fd = unsafe {
            libc::openat(
                dir,
                name.as_ptr(),
                libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            let error = io::Error::last_os_error();
            unsafe { libc::unlinkat(dir, name.as_ptr(), libc::AT_REMOVEDIR) };
            return publishing("archive_stage_open", Err(error));
        }
        let staging = Self {
            parent,
            directory: unsafe { File::from_raw_fd(fd) },
            name,
            uid,
            publisher: creator,
        };
        let metadata = staging.directory.metadata()?;
        if metadata.uid() != creator || metadata.mode() & 0o777 != 0o700 {
            return publishing("archive_stage_owner", Err(rejected()));
        }
        if creator != uid {
            publishing(
                "archive_stage_owner",
                crate::security::checked(unsafe {
                    libc::fchownat(
                        staging.directory.as_raw_fd(),
                        c"".as_ptr(),
                        uid,
                        crate::spec::GID_BASE,
                        libc::AT_EMPTY_PATH,
                    )
                }),
            )?;
        }
        let file = publishing(
            "archive_stage_file",
            with_filesystem_owner(uid, || {
                let fd = unsafe {
                    libc::openat(
                        staging.directory.as_raw_fd(),
                        c"payload".as_ptr(),
                        libc::O_CREAT
                            | libc::O_EXCL
                            | libc::O_NOFOLLOW
                            | libc::O_RDWR
                            | libc::O_CLOEXEC,
                        0o600,
                    )
                };
                if fd < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(unsafe { File::from_raw_fd(fd) })
            }),
        )?;
        Ok((staging, file))
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        let _ = self.remove(true);
    }
}

impl Store {
    pub(crate) fn disconnect(&mut self, owner: ConnectionId) {
        if self
            .pending
            .as_ref()
            .is_some_and(|upload| upload.owner == owner)
        {
            self.pending = None;
        }
    }

    fn expire(&mut self) {
        if self
            .pending
            .as_ref()
            .is_some_and(|upload| Instant::now() >= upload.expires)
        {
            self.pending = None;
        }
    }

    fn open(
        &self,
        root: &File,
        spec: UploadSpec,
        owner: ConnectionId,
        workload: &str,
        workload_uid: u32,
    ) -> io::Result<Upload> {
        if self.pending.is_some() || self.stream_active {
            return Err(rejected());
        }
        Upload::open(root, spec, owner, workload, workload_uid)
    }

    pub(crate) fn begin_stream(
        &mut self,
        root: &File,
        spec: UploadSpec,
        owner: ConnectionId,
        workload: &str,
        uid: u32,
    ) -> io::Result<Upload> {
        self.expire();
        let upload = self.open(root, spec, owner, workload, uid)?;
        self.stream_active = true;
        Ok(upload)
    }

    pub(crate) fn finish_stream(&mut self) {
        self.stream_active = false;
    }

    pub(crate) fn stream_active(&self) -> bool {
        self.stream_active
    }

    pub(crate) fn operate(
        &mut self,
        root: &File,
        operation: Operation,
        owner: ConnectionId,
        workload: &str,
        workload_uid: u32,
    ) -> io::Result<Value> {
        self.expire();
        match operation {
            Operation::Stat { path } => {
                let entry = open_path(root, &path, libc::O_PATH)?;
                let info = entry.metadata()?;
                let link = if info.is_symlink() {
                    Some(link_target(&entry)?)
                } else if info.is_dir() || info.is_file() {
                    None
                } else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "unsupported workload archive entry",
                    ));
                };
                let uid = visible_owner(info.uid(), crate::spec::UID_BASE);
                let gid = visible_owner(info.gid(), crate::spec::GID_BASE);
                Ok(json!({
                    "name":if path=="/" { "/" } else { path.rsplit('/').next().expect("validated path") },
                    "directory":info.is_dir(),
                    "mode":info.mode() & 0o7777,
                    "identity":Identity::from(&info),
                    "uid":uid, "gid":gid, "link":link,
                }))
            }
            Operation::List { path, identity } => list_directory(root, &path, &identity),
            Operation::Read {
                path,
                identity,
                offset,
            } => {
                let request = DownloadRequest { path, identity };
                let file = request.open(root)?;
                if offset >= request.size() {
                    return Err(rejected());
                }
                let count = (request.size() - offset).min(CHUNK as u64) as usize;
                let mut chunk = [0; CHUNK];
                file.read_exact_at(&mut chunk[..count], offset)?;
                request.verify(&file)?;
                let next = offset + count as u64;
                Ok(json!({
                    "offset":offset,"next_offset":next,"eof":next==request.size(),
                    "data":base64::engine::general_purpose::STANDARD.encode(&chunk[..count]),
                }))
            }
            Operation::Begin(spec) => {
                self.pending = Some(self.open(root, spec, owner, workload, workload_uid)?);
                Ok(json!({"offset":0}))
            }
            Operation::Write { offset, data } => {
                let upload = self
                    .pending
                    .as_mut()
                    .filter(|upload| upload.owner == owner && upload.workload == workload)
                    .ok_or_else(rejected)?;
                let result = upload.write(offset, &data);
                if result.is_err() {
                    self.pending = None;
                }
                result
            }
            Operation::Commit => {
                if self
                    .pending
                    .as_ref()
                    .is_none_or(|upload| upload.owner != owner || upload.workload != workload)
                {
                    return Err(rejected());
                }
                self.pending
                    .take()
                    .expect("verified workload archive upload")
                    .commit(root)
            }
        }
    }
}

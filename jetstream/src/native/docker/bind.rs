use std::ffi::{CStr, CString, OsStr};
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use conjet_launch_service::handshake::{hex, random};
use conjet_launch_service::socket::Stream;
use conjet_launch_service::spec::BindMount;
use serde_json::{json, Value};

use super::{private_directory, Owner, Rejected};

const DIRECTORY: libc::c_int = libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW;

pub(super) struct Root {
    path: PathBuf,
    directory: File,
}

impl Root {
    pub(super) fn open(path: PathBuf, root: &Path) -> anyhow::Result<Self> {
        private_directory(&path, root)?;
        let relative = path.strip_prefix(root)?;
        anyhow::ensure!(
            !relative.as_os_str().is_empty(),
            "bind root requires an owned scratch subdirectory"
        );
        let anchor = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(DIRECTORY)
            .open(root)?;
        let directory = descend(&anchor, relative)?;
        let metadata = directory.metadata()?;
        anyhow::ensure!(
            metadata.is_dir()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.mode() & 0o077 == 0,
            "invalid host bind root identity"
        );
        Ok(Self { path, directory })
    }

    pub(super) fn source(&self, source: &Path) -> Result<File, Rejected> {
        let path = source
            .strip_prefix(&self.path)
            .map_err(|_| Rejected::bad("host bind source lies outside the configured root"))?;
        if path.as_os_str().is_empty() || path.as_os_str().len() > 1024 {
            return Err(Rejected::bad("host bind requires an owned subdirectory"));
        }
        let directory = descend(&self.directory, path)
            .map_err(|_| Rejected::bad("host bind requires an existing directory without symlinks on the configured filesystem"))?;
        if directory
            .metadata()
            .ok()
            .is_none_or(|info| info.uid() != unsafe { libc::geteuid() })
        {
            return Err(Rejected::bad(
                "host bind source is not owned by the endpoint user",
            ));
        }
        Ok(directory)
    }
}

fn descend(anchor: &File, relative: &Path) -> io::Result<File> {
    let device = anchor.metadata()?.dev();
    let mut directory = anchor.try_clone()?;
    for segment in relative.components() {
        let Component::Normal(segment) = segment else {
            return Err(io::ErrorKind::InvalidInput.into());
        };
        directory = open_at(&directory, &component(segment)?, DIRECTORY, 0)?;
        if directory.metadata()?.dev() != device {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
    }
    Ok(directory)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn binds_only_descriptor_relative_directories_on_the_configured_tree() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("owned")).unwrap();
        symlink(outside.path(), root.path().join("link")).unwrap();
        let anchor = File::open(root.path()).unwrap();
        assert!(descend(&anchor, Path::new("owned"))
            .unwrap()
            .metadata()
            .unwrap()
            .is_dir());
        assert!(descend(&anchor, Path::new("link")).is_err());
        assert!(descend(&anchor, Path::new("owned/../owned")).is_err());
        assert!(descend(&anchor, outside.path()).is_err());
    }
}

pub(super) struct Binding {
    path: String,
    source: File,
    read_only: bool,
}

impl Binding {
    pub(super) fn requested(data: &Value, root: Option<&Root>) -> Result<Option<Self>, Rejected> {
        let host = &data["HostConfig"];
        let Some(mounts) = host["Mounts"].as_array() else {
            return Ok(None);
        };
        if !mounts.iter().any(|mount| mount["Type"] == "bind") {
            return Ok(None);
        }
        let [mount] = mounts.as_slice() else {
            return Err(Rejected::bad("only one isolated host bind is supported"));
        };
        if !super::request::falsey(&host["Binds"]) || mount["Target"] != "/dataset" {
            return Err(Rejected::bad(
                "isolated host bind requires the /dataset target",
            ));
        }
        if let Some(options) = mount.as_object() {
            super::request::options(options, &["Type", "Source", "Target", "ReadOnly"], "bind ")?;
        }
        let root =
            root.ok_or_else(|| Rejected(501, "native host bind root is not configured".into()))?;
        let path = mount["Source"]
            .as_str()
            .ok_or_else(|| Rejected::bad("native bind requires a host path"))?;
        let read_only = if mount["ReadOnly"].is_null() {
            false
        } else {
            mount["ReadOnly"]
                .as_bool()
                .ok_or_else(|| Rejected::bad("invalid bind ReadOnly flag"))?
        };
        Ok(Some(Self {
            path: path.to_owned(),
            source: root.source(Path::new(path))?,
            read_only,
        }))
    }

    pub(super) fn metadata(&self) -> Value {
        json!({"Type":"bind","Source":self.path,"Destination":"/dataset",
            "RW":!self.read_only,"Mode":if self.read_only {"ro"} else {"rw"},"Propagation":"rprivate"})
    }

    pub(super) fn start(&self, owner: &Owner) -> anyhow::Result<Session> {
        use super::bind_fuse;
        let lease = hex(&random::<16>()?);
        let source = self.source.try_clone()?;
        let stream = owner
            .scoped_peer()
            .map_err(|error| anyhow!(error.1))?
            .bind(&lease, self.read_only)?;
        let writer = unsafe { libc::fcntl(stream.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if writer < 0 {
            return Err(io::Error::last_os_error().into());
        }
        let writer = UnixStream::from(unsafe { OwnedFd::from_raw_fd(writer) });
        let writer = Arc::new(Mutex::new(Stream::unix(writer, None)?));
        let remote = Arc::clone(&writer);
        let writable = !self.read_only;
        let worker = thread::Builder::new()
            .name("native-host-bind".into())
            .spawn(move || bind_fuse::serve(stream, &remote, source, writable))?;
        Ok(Session {
            binding: BindMount {
                lease,
                read_only: self.read_only,
            },
            writer,
            worker: Some(worker),
        })
    }
}

pub(super) struct Session {
    pub binding: BindMount,
    writer: Arc<Mutex<Stream>>,
    worker: Option<JoinHandle<io::Result<()>>>,
}

impl Session {
    pub(super) fn finish(mut self) -> anyhow::Result<()> {
        let mut signal = [0; 16];
        signal[..4].copy_from_slice(&16u32.to_le_bytes());
        {
            let mut writer = self.writer.lock().unwrap();
            writer.deadline(Some(Instant::now() + Duration::from_secs(5)));
            writer
                .write_all(&signal)
                .context("request native bind teardown")?;
        }
        let deadline = Instant::now() + Duration::from_secs(6);
        while !self
            .worker
            .as_ref()
            .expect("native bind worker")
            .is_finished()
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(2));
        }
        let worker = self.worker.take().expect("native bind worker");
        if !worker.is_finished() {
            self.disconnect();
        }
        worker
            .join()
            .map_err(|_| anyhow!("native bind worker failed"))?
            .context("verify native bind teardown")
    }

    fn disconnect(&self) {
        let fd = self.writer.lock().unwrap().as_raw_fd();
        unsafe {
            libc::shutdown(fd, libc::SHUT_RDWR);
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(worker) = self.worker.take() {
            self.disconnect();
            let _ = worker.join();
        }
    }
}

pub(super) fn component(name: &OsStr) -> io::Result<CString> {
    let bytes = name.as_bytes();
    if bytes.len() > 255 || bytes.contains(&b'/') || matches!(bytes, b"" | b"." | b"..") {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    Ok(CString::new(bytes)?)
}

pub(super) fn open_at(
    directory: &File,
    name: &CStr,
    flags: libc::c_int,
    mode: libc::mode_t,
) -> io::Result<File> {
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags,
            libc::c_uint::from(mode),
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

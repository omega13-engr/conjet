use std::collections::BTreeMap;
use std::fs::File;
use std::io;
use std::os::unix::fs::FileExt;

const LABEL: &[u8; 16] = b"CJ_NATIVE_VOL\0\0\0";
pub const MARKER: &str = "/etc/conjet/native-volume";
pub type VolumeLabels = BTreeMap<String, String>;
const LABELS_LIMIT: usize = 1024;

pub fn encode_labels(labels: &VolumeLabels) -> io::Result<Vec<u8>> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid native volume labels");
    if labels.len() > 16
        || labels.iter().any(|(name, value)| {
            name.is_empty()
                || name.len() > 128
                || value.len() > 256
                || name.contains(['=', '\0'])
                || value.contains('\0')
        })
    {
        return Err(invalid());
    }
    let encoded = serde_json::to_vec(labels)?;
    if encoded.len() > LABELS_LIMIT {
        return Err(invalid());
    }
    Ok(encoded)
}

pub struct VolumeIdentity {
    pub uuid: [u8; 16],
    pub epoch_seconds: u64,
}

impl VolumeIdentity {
    pub fn encode(&self) -> [u8; 24] {
        let mut wire = [0; 24];
        wire[..16].copy_from_slice(&self.uuid);
        wire[16..].copy_from_slice(&self.epoch_seconds.to_le_bytes());
        wire
    }

    pub fn decode(bytes: &[u8]) -> io::Result<Self> {
        let wire: [u8; 24] = bytes
            .try_into()
            .map_err(|_| io::Error::other("invalid native volume boot record"))?;
        let uuid = wire[..16].try_into().expect("fixed filesystem UUID");
        let epoch_seconds = u64::from_le_bytes(wire[16..].try_into().expect("fixed timestamp"));
        if uuid == [0; 16] || !(946_684_800..=4_102_444_800).contains(&epoch_seconds) {
            return Err(io::Error::other(
                "invalid volume identity or host timestamp",
            ));
        }
        Ok(Self {
            uuid,
            epoch_seconds,
        })
    }
}

pub fn filesystem_uuid(file: &File) -> io::Result<[u8; 16]> {
    let mut superblock = [0u8; 136];
    file.read_exact_at(&mut superblock, 1024)?;
    let uuid = superblock[104..120].try_into().expect("ext4 UUID");
    if superblock[56..58] != [0x53, 0xef] || &superblock[120..136] != LABEL || uuid == [0; 16] {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid native ext4 volume disk",
        ));
    }
    Ok(uuid)
}

pub fn valid_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    name.len() <= 64
        && bytes
            .next()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) mod guest {
    use std::ffi::CStr;
    use std::fs::{self, DirBuilder, File, Metadata, OpenOptions};
    use std::io;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
    use std::path::Path;
    use std::time::{Duration, Instant};

    use serde::Serialize;

    use super::{
        LABELS_LIMIT, MARKER, VolumeIdentity, VolumeLabels, encode_labels, filesystem_uuid,
        valid_name,
    };
    use crate::security::checked;
    use crate::spec::{GID_BASE, UID_BASE, VolumeMount, WORKLOAD_GID, WORKLOAD_UID};

    const DEVICES: &CStr = c"/run/conjet/volume-devices";
    const ROOT: &CStr = c"/run/conjet/volume-disk";
    const VOLUMES: &str = "/run/conjet/volume-disk/volumes";
    const PENDING: &str = "/run/conjet/volume-disk/volumes/.pending";
    const LIMIT: usize = 8;
    const METADATA: &CStr = c"trusted.conjet.volume-labels";

    fn path(value: &CStr) -> &Path {
        Path::new(value.to_str().expect("static mount path"))
    }

    struct Mount(Option<&'static CStr>);

    impl Mount {
        fn open(
            source: &CStr,
            target: &'static CStr,
            fs_type: &CStr,
            flags: libc::c_ulong,
        ) -> io::Result<Self> {
            DirBuilder::new().mode(0o700).create(path(target))?;
            if let Err(error) = checked(unsafe {
                libc::mount(
                    source.as_ptr(),
                    target.as_ptr(),
                    fs_type.as_ptr(),
                    flags,
                    std::ptr::null(),
                )
            }) {
                let _ = fs::remove_dir(path(target));
                return Err(error);
            }
            Ok(Self(Some(target)))
        }

        fn close(&mut self) -> io::Result<()> {
            if let Some(target) = self.0 {
                checked(unsafe { libc::umount(target.as_ptr()) })?;
                self.0 = None;
                fs::remove_dir(path(target))?;
            }
            Ok(())
        }
    }

    impl Drop for Mount {
        fn drop(&mut self) {
            let _ = self.close();
        }
    }

    pub(crate) struct Store {
        disk: Mount,
        devices: Mount,
    }

    impl Store {
        pub(crate) fn open() -> io::Result<Option<Self>> {
            let config = match fs::read(MARKER) {
                Ok(bytes) => VolumeIdentity::decode(&bytes)?,
                Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
                Err(error) => return Err(error),
            };
            // The disposable initramfs has no RTC. ext4 uses realtime when
            // recording inode deletion, so initialize it before mounting.
            let time = libc::timespec {
                tv_sec: config
                    .epoch_seconds
                    .try_into()
                    .map_err(|_| io::Error::other("host timestamp is outside guest time_t"))?,
                tv_nsec: 0,
            };
            checked(unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &time) })?;
            let base_flags = libc::MS_NOSUID | libc::MS_NOEXEC;
            let devices = Mount::open(c"devtmpfs", DEVICES, c"devtmpfs", base_flags)?;
            let deadline = Instant::now() + Duration::from_secs(3);
            let candidates = [
                c"/run/conjet/volume-devices/vda",
                c"/run/conjet/volume-devices/vdb",
            ];
            let source = loop {
                let mut matching = candidates.iter().filter(|device| {
                    File::open(path(device))
                        .and_then(|file| filesystem_uuid(&file))
                        .ok()
                        == Some(config.uuid)
                });
                if let Some(source) = matching.next() {
                    if matching.next().is_some() {
                        return Err(io::Error::other(
                            "multiple devices match the native volume UUID",
                        ));
                    }
                    break *source;
                }
                if Instant::now() >= deadline {
                    return Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        "leased volume disk did not appear",
                    ));
                }
                std::thread::sleep(Duration::from_millis(10));
            };
            let build_root = Path::new(crate::build_snapshot::MARKER).try_exists()?;
            let (target, flags) = if build_root {
                (
                    crate::build_snapshot::guest::ROOT,
                    libc::MS_NOSUID | libc::MS_NODEV,
                )
            } else {
                (ROOT, base_flags | libc::MS_NODEV)
            };
            let disk = Mount::open(source, target, c"ext4", flags)?;
            if build_root {
                let info = fs::symlink_metadata(path(target))?;
                if !info.is_dir() || info.uid() != 0 || info.mode() & 0o022 != 0 {
                    return Err(io::Error::other("invalid native build workspace ownership"));
                }
                return Ok(Some(Self { disk, devices }));
            }
            match DirBuilder::new().mode(0o700).create(VOLUMES) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
            let info = fs::symlink_metadata(VOLUMES)?;
            if !info.is_dir() || info.uid() != 0 || info.mode() & 0o777 != 0o700 {
                return Err(io::Error::other("invalid native volume registry directory"));
            }
            remove_pending()?;
            names()?;
            Ok(Some(Self { disk, devices }))
        }

        pub(crate) fn close(mut self) -> io::Result<()> {
            self.disk.close()?;
            self.devices.close()
        }
    }

    fn remove_pending() -> io::Result<()> {
        match fs::remove_dir(PENDING) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    pub(crate) fn available() -> bool {
        Path::new(VOLUMES).is_dir()
    }

    pub(crate) fn names() -> io::Result<Vec<String>> {
        let mut names = Vec::new();
        for entry in fs::read_dir(VOLUMES)? {
            let name = entry?
                .file_name()
                .into_string()
                .map_err(|_| io::Error::other("invalid native volume name on disk"))?;
            if names.len() >= LIMIT || !valid_name(&name) {
                return Err(io::Error::other("invalid native volume registry contents"));
            }
            inspect(&name)?;
            names.push(name);
        }
        names.sort_unstable();
        Ok(names)
    }

    pub(crate) fn create(name: &str, labels: &VolumeLabels) -> io::Result<VolumeInfo> {
        if !valid_name(name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid native volume name",
            ));
        }
        let encoded = encode_labels(labels)?;
        let entries = names()?;
        if entries.iter().any(|entry| entry == name) {
            return inspect(name);
        }
        if entries.len() >= LIMIT {
            return Err(io::ErrorKind::StorageFull.into());
        }
        let path = Path::new(VOLUMES).join(name);
        DirBuilder::new().mode(0o700).create(PENDING)?;
        let result = (|| {
            std::os::unix::fs::chown(
                PENDING,
                Some(UID_BASE + WORKLOAD_UID),
                Some(GID_BASE + WORKLOAD_GID),
            )?;
            let pending = File::open(PENDING)?;
            if !labels.is_empty() {
                checked(unsafe {
                    libc::fsetxattr(
                        pending.as_raw_fd(),
                        METADATA.as_ptr(),
                        encoded.as_ptr().cast(),
                        encoded.len(),
                        libc::XATTR_CREATE,
                    )
                })?;
            }
            pending.sync_all()?;
            fs::rename(PENDING, path)?;
            File::open(VOLUMES)?.sync_all()?;
            inspect(name)
        })();
        if result.is_err() {
            remove_pending()?;
        }
        result
    }

    pub(crate) fn remove(name: &str) -> io::Result<()> {
        inspect(name)?;
        fs::remove_dir_all(Path::new(VOLUMES).join(name))?;
        File::open(VOLUMES)?.sync_all()
    }

    #[derive(Serialize)]
    pub(crate) struct VolumeInfo {
        name: String,
        guest_uid: u32,
        guest_gid: u32,
        mode: u32,
        pub(crate) inode: u64,
        labels: VolumeLabels,
    }

    pub(crate) fn inspect(name: &str) -> io::Result<VolumeInfo> {
        if !valid_name(name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid native volume name",
            ));
        }
        let source = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY)
            .open(Path::new(VOLUMES).join(name))?;
        let mut info = checked_info(
            name,
            &source.metadata()?,
            (UID_BASE + WORKLOAD_UID, GID_BASE + WORKLOAD_GID),
        )?;
        let mut payload = [0u8; LABELS_LIMIT];
        let length = unsafe {
            libc::fgetxattr(
                source.as_raw_fd(),
                METADATA.as_ptr(),
                payload.as_mut_ptr().cast(),
                payload.len(),
            )
        };
        if length < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ENODATA) {
                return Err(error);
            }
        } else {
            info.labels = serde_json::from_slice(&payload[..length as usize])?;
            encode_labels(&info.labels)?;
        }
        Ok(info)
    }

    pub(crate) fn mount_source(request: &VolumeMount) -> io::Result<File> {
        if !valid_name(&request.name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid native volume name",
            ));
        }
        let source = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_DIRECTORY)
            .open(Path::new(VOLUMES).join(&request.name))?;
        let info = checked_info(
            &request.name,
            &source.metadata()?,
            (WORKLOAD_UID, WORKLOAD_GID),
        )?;
        if info.inode != request.inode {
            return Err(io::Error::other("stale native volume identity"));
        }
        Ok(source)
    }

    fn checked_info(name: &str, info: &Metadata, owner: (u32, u32)) -> io::Result<VolumeInfo> {
        if !info.is_dir() || (info.uid(), info.gid()) != owner || info.mode() & 0o777 != 0o700 {
            return Err(io::Error::other(
                "unexpected native volume directory identity",
            ));
        }
        Ok(VolumeInfo {
            name: name.into(),
            guest_uid: WORKLOAD_UID,
            guest_gid: WORKLOAD_GID,
            mode: info.mode() & 0o777,
            inode: info.ino(),
            labels: VolumeLabels::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boot_record_requires_disk_identity_and_valid_epoch() {
        let good = VolumeIdentity {
            uuid: [42; 16],
            epoch_seconds: 1_800_000_000,
        };
        assert_eq!(
            VolumeIdentity::decode(&good.encode()).unwrap().uuid,
            good.uuid
        );
        let mut invalid = good.encode();
        invalid[16..].fill(0);
        assert!(VolumeIdentity::decode(&invalid).is_err());
        assert!(VolumeIdentity::decode(&good.encode()[..16]).is_err());
    }

    #[test]
    fn registry_names_cannot_escape_the_owned_root() {
        assert!(valid_name("named-volume_1.raw"));
        for name in ["", "..", "../ext", "some/path", ".pending", "a\0"] {
            assert!(!valid_name(name));
        }
    }
}

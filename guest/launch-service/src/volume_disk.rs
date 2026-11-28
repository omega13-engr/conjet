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
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use serde::Serialize;

    use super::{
        LABELS_LIMIT, MARKER, VolumeIdentity, VolumeLabels, encode_labels, filesystem_uuid,
        valid_name,
    };
    use crate::security::checked;
    use crate::spec::{GID_BASE, UID_BASE, VolumeMount, WORKLOAD_GID, WORKLOAD_UID};

    const DEVICES: &CStr = c"/run/conjet/volume-devices";
    const ROOT: &CStr = c"/run/conjet/volume-disk";
    const BUILD_WORKSPACE: &CStr = c"/run/conjet/volume-disk/buildkit";
    const VOLUMES: &str = "/run/conjet/volume-disk/volumes";
    const BUILD_VOLUMES: &CStr = c"/run/conjet/buildkit-volumes";
    const PENDING: &str = "/run/conjet/volume-disk/volumes/.pending";
    const LIMIT: usize = 8;
    const METADATA: &CStr = c"trusted.conjet.volume-labels";
    const CREATED_AT: &CStr = c"trusted.conjet.volume-created-at";
    const UNCLAIMED: &CStr = c"trusted.conjet.volume-unclaimed";

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

        fn build_bind(source: &CStr, target: &'static CStr) -> io::Result<Self> {
            let mount = Self::open(source, target, c"", libc::MS_BIND)?;
            checked(unsafe {
                libc::mount(
                    std::ptr::null(),
                    target.as_ptr(),
                    std::ptr::null(),
                    libc::MS_BIND | libc::MS_REMOUNT | libc::MS_NOSUID | libc::MS_NODEV,
                    std::ptr::null(),
                )
            })?;
            Ok(mount)
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
        build_volumes: Option<Mount>,
        workspace: Option<Mount>,
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
            let combined = build_root && Path::new(crate::oci::DISK_STORE_MARKER).try_exists()?;
            let (target, flags) = if build_root && !combined {
                (
                    crate::build_snapshot::guest::ROOT,
                    libc::MS_NOSUID | libc::MS_NODEV,
                )
            } else {
                (ROOT, base_flags | libc::MS_NODEV)
            };
            let disk = Mount::open(source, target, c"ext4", flags)?;
            if build_root && !combined {
                let info = fs::symlink_metadata(path(target))?;
                if !info.is_dir() || info.uid() != 0 || info.mode() & 0o022 != 0 {
                    return Err(io::Error::other("invalid native build workspace ownership"));
                }
                return Ok(Some(Self {
                    build_volumes: None,
                    workspace: None,
                    disk,
                    devices,
                }));
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
            crate::workload_layers::initialize()?;
            let workspace = if combined {
                match DirBuilder::new().mode(0o700).create(path(BUILD_WORKSPACE)) {
                    Ok(()) => {}
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                    Err(error) => return Err(error),
                }
                let info = fs::symlink_metadata(path(BUILD_WORKSPACE))?;
                if !info.is_dir() || info.uid() != 0 || info.mode() & 0o777 != 0o700 {
                    return Err(io::Error::other("invalid native build workspace ownership"));
                }
                Some(Mount::build_bind(
                    BUILD_WORKSPACE,
                    crate::build_snapshot::guest::ROOT,
                )?)
            } else {
                None
            };
            // BuildKit's exporter remounts snapshot binds read-only. Its pinned
            // mount library cannot preserve an inherited, locked noexec flag.
            // Only the authorized worker selects its cache from this alias.
            let build_volumes = combined
                .then(|| Mount::build_bind(c"/run/conjet/volume-disk/volumes", BUILD_VOLUMES))
                .transpose()?;
            Ok(Some(Self {
                build_volumes,
                workspace,
                disk,
                devices,
            }))
        }

        pub(crate) fn close(mut self) -> io::Result<()> {
            if let Some(build_volumes) = &mut self.build_volumes {
                build_volumes.close()?;
            }
            if let Some(workspace) = &mut self.workspace {
                workspace.close()?;
            }
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
            checked(unsafe {
                libc::fsetxattr(
                    pending.as_raw_fd(),
                    UNCLAIMED.as_ptr(),
                    std::ptr::null(),
                    0,
                    libc::XATTR_CREATE,
                )
            })?;
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
            let created = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(io::Error::other)?
                .as_secs()
                .to_le_bytes();
            checked(unsafe {
                libc::fsetxattr(
                    pending.as_raw_fd(),
                    CREATED_AT.as_ptr(),
                    created.as_ptr().cast(),
                    created.len(),
                    libc::XATTR_CREATE,
                )
            })?;
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
        #[serde(skip_serializing_if = "Option::is_none")]
        created_unix_seconds: Option<u64>,
    }

    pub(crate) fn inspect(name: &str) -> io::Result<VolumeInfo> {
        if !valid_name(name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid native volume name",
            ));
        }
        let source = open_volume(name, 0)?;
        let mut info = checked_info(name, &source.metadata()?, (UID_BASE, GID_BASE))?;
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
        let mut created = [0; 8];
        let length = unsafe {
            libc::fgetxattr(
                source.as_raw_fd(),
                CREATED_AT.as_ptr(),
                created.as_mut_ptr().cast(),
                created.len(),
            )
        };
        if length < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ENODATA) {
                return Err(error);
            }
        } else if length as usize == created.len() {
            info.created_unix_seconds = Some(u64::from_le_bytes(created));
        } else {
            return Err(io::Error::other("invalid native volume creation time"));
        }
        Ok(info)
    }

    pub(crate) fn mount_source(request: &VolumeMount) -> io::Result<File> {
        checked_source(request, (0, 0))
    }

    pub(crate) fn build_cache_source(request: &VolumeMount) -> io::Result<File> {
        checked_source(request, (UID_BASE, GID_BASE))
    }

    pub(crate) fn worker_cache_mount_source(request: &VolumeMount) -> io::Result<File> {
        if request.target != "/var/lib/buildkit" || request.read_only {
            return Err(io::Error::other("invalid BuildKit worker cache mount"));
        }
        // The launch child is already in the mapped user namespace when it
        // reopens the source. Its cache ownership is reported in that mapping.
        let registered = mount_source(request)?.metadata()?;
        let source = open_volume_at(path(BUILD_VOLUMES), &request.name, libc::O_PATH)?;
        let mounted = source.metadata()?;
        if (mounted.dev(), mounted.ino()) != (registered.dev(), registered.ino()) {
            return Err(io::Error::other("BuildKit worker cache alias changed"));
        }
        Ok(source)
    }

    fn checked_source(request: &VolumeMount, uid_gid_base: (u32, u32)) -> io::Result<File> {
        let source = open_volume(&request.name, libc::O_PATH)?;
        let info = checked_info(&request.name, &source.metadata()?, uid_gid_base)?;
        if info.inode != request.inode {
            return Err(io::Error::other("stale native volume identity"));
        }
        Ok(source)
    }

    /// Called by the supervisor while it owns the volume admission lock.
    /// Persist the marker before modifying an unclaimed volume so a VM restart
    /// can roll back a partial copy before exposing it to any workload.
    pub(crate) fn initialize_mount(
        request: &VolumeMount,
        image_digest: &str,
        namespace_root: bool,
    ) -> io::Result<()> {
        let source = open_volume(&request.name, 0)?;
        let info = checked_info(&request.name, &source.metadata()?, (UID_BASE, GID_BASE))?;
        if info.inode != request.inode {
            return Err(io::Error::other("stale native volume identity"));
        }
        let fd = source.as_raw_fd();
        let directory = std::path::PathBuf::from(format!("/proc/self/fd/{fd}"));
        let mut pending = [0u8; 1];
        let marker =
            unsafe { libc::fgetxattr(fd, UNCLAIMED.as_ptr(), pending.as_mut_ptr().cast(), 1) };
        match marker {
            -1 => {
                let error = io::Error::last_os_error();
                return if error.raw_os_error() == Some(libc::ENODATA) {
                    Ok(())
                } else {
                    Err(error)
                };
            }
            0 => {}
            1 if pending[0] == 1 => {
                restore_unclaimed(&source, &directory)?;
            }
            _ => {
                return Err(io::Error::other(
                    "invalid native volume initialization marker",
                ));
            }
        }
        if let Some(true) = request.docker_copy_up {
            let from = crate::volume_copy::image_directory(image_digest, &request.target)?;
            if let Some(from) = from {
                if fs::read_dir(&directory)?.next().is_some() {
                    return Err(io::Error::other("unclaimed native volume contains data"));
                }
                mark_unclaimed(fd, &[1])?;
                source.sync_all()?;
                if let Err(error) = crate::volume_copy::copy_directory(&from, &directory) {
                    restore_unclaimed(&source, &directory)?;
                    mark_unclaimed(fd, &[])?;
                    source.sync_all()?;
                    return Err(error);
                }
                source.sync_all()?;
                checked(unsafe { libc::fremovexattr(fd, UNCLAIMED.as_ptr()) })?;
                return source.sync_all();
            }
        }
        if namespace_root && source.metadata()?.uid() != UID_BASE {
            if fs::read_dir(&directory)?.next().is_some() {
                return Err(io::Error::other("unclaimed native volume contains data"));
            }
            checked(unsafe { libc::fchown(fd, UID_BASE, GID_BASE) })?;
        }
        if request.docker_copy_up.is_some() && namespace_root {
            checked(unsafe { libc::fchmod(fd, 0o755) })?;
        }
        source.sync_all()?;
        checked(unsafe { libc::fremovexattr(fd, UNCLAIMED.as_ptr()) })?;
        source.sync_all()
    }

    fn mark_unclaimed(fd: libc::c_int, pending: &[u8]) -> io::Result<()> {
        checked(unsafe {
            libc::fsetxattr(
                fd,
                UNCLAIMED.as_ptr(),
                pending.as_ptr().cast(),
                pending.len(),
                libc::XATTR_REPLACE,
            )
        })
    }

    fn restore_unclaimed(volume: &File, directory: &Path) -> io::Result<()> {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                fs::remove_dir_all(entry.path())?;
            } else {
                fs::remove_file(entry.path())?;
            }
        }
        let fd = volume.as_raw_fd();
        checked(unsafe { libc::fchown(fd, UID_BASE + WORKLOAD_UID, GID_BASE + WORKLOAD_GID) })?;
        checked(unsafe { libc::fchmod(fd, 0o700) })?;
        volume.sync_all()
    }

    fn open_volume(name: &str, flags: libc::c_int) -> io::Result<File> {
        open_volume_at(Path::new(VOLUMES), name, flags)
    }

    fn open_volume_at(root: &Path, name: &str, flags: libc::c_int) -> io::Result<File> {
        if !valid_name(name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid native volume name",
            ));
        }
        OpenOptions::new()
            .read(true)
            .custom_flags(flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_DIRECTORY)
            .open(root.join(name))
    }

    fn checked_info(name: &str, info: &Metadata, base: (u32, u32)) -> io::Result<VolumeInfo> {
        // Container entrypoints may chown/chmod their volume. Ownership must
        // remain inside the mapped guest range; the private registry parent
        // and descriptor-relative open retain the access boundary.
        let owner = super::mapped_volume_owner(info.uid(), info.gid(), base);
        if !info.is_dir() || owner.is_none() {
            return Err(io::Error::other(
                "unexpected native volume directory identity",
            ));
        }
        Ok(VolumeInfo {
            name: name.into(),
            guest_uid: owner.expect("validated volume owner").0,
            guest_gid: owner.expect("validated volume owner").1,
            mode: info.mode() & 0o777,
            inode: info.ino(),
            labels: VolumeLabels::new(),
            created_unix_seconds: None,
        })
    }
}

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
pub(crate) fn mapped_volume_owner(uid: u32, gid: u32, base: (u32, u32)) -> Option<(u32, u32)> {
    let owner = (uid.checked_sub(base.0)?, gid.checked_sub(base.1)?);
    (owner.0 < crate::spec::ID_MAP_WIDTH && owner.1 < crate::spec::ID_MAP_WIDTH).then_some(owner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volume_owners_accept_mapped_application_accounts_only() {
        for id in [0, 70, 999, crate::spec::ID_MAP_WIDTH - 1] {
            assert_eq!(
                mapped_volume_owner(100_000 + id, 100_000 + id, (100_000, 100_000)),
                Some((id, id))
            );
        }
        assert_eq!(
            mapped_volume_owner(99_999, 100_000, (100_000, 100_000)),
            None
        );
        assert_eq!(
            mapped_volume_owner(100_000, 165_536, (100_000, 100_000)),
            None
        );
        assert_eq!(
            mapped_volume_owner(u32::MAX, 100_000, (100_000, 100_000)),
            None
        );
    }

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

//! Staged extraction of data-only workload tar trees.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt, chown, lchown, symlink};
use std::path::{Component, Path, PathBuf};

use crate::security::checked;
use crate::spec::{GID_BASE, ID_MAP_WIDTH, UID_BASE};

use super::{Staging, publishing, rejected, with_filesystem_owner};

const MAX_ENTRIES: usize = 512;

#[derive(Clone, Copy)]
struct Attributes {
    uid: u32,
    gid: u32,
    mode: u32,
}

impl Attributes {
    fn from(header: &tar::Header) -> io::Result<Self> {
        let mapped = |value: u64| {
            u32::try_from(value)
                .ok()
                .filter(|id| *id < ID_MAP_WIDTH)
                .ok_or_else(rejected)
        };
        let mode = header.mode()?;
        if mode & !0o777 != 0 {
            return Err(rejected());
        }
        Ok(Self {
            uid: UID_BASE + mapped(header.uid()?)?,
            gid: GID_BASE + mapped(header.gid()?)?,
            mode,
        })
    }

    fn apply(self, path: &Path) -> io::Result<()> {
        chown(path, Some(self.uid), Some(self.gid))?;
        fs::set_permissions(path, fs::Permissions::from_mode(self.mode))
    }

    fn apply_directory(self, directory: &File) -> io::Result<()> {
        let fd = directory.as_raw_fd();
        checked(unsafe { libc::fchown(fd, self.uid, self.gid) })?;
        checked(unsafe { libc::fchmod(fd, self.mode) })?;
        directory.sync_all()
    }
}

fn member(path: &Path) -> io::Result<PathBuf> {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir if normalized.as_os_str().is_empty() => {}
            Component::Normal(part)
                if part.to_str().is_some_and(|part| {
                    part.len() <= 255 && !part.chars().any(char::is_control)
                }) =>
            {
                normalized.push(part);
            }
            _ => return Err(rejected()),
        }
    }
    if normalized.as_os_str().is_empty()
        || normalized.as_os_str().len() > 1024
        || normalized.components().count() > 32
    {
        return Err(rejected());
    }
    Ok(normalized)
}

fn verify_end(source: &mut File, end: u64) -> io::Result<()> {
    if source.metadata()?.len() < end + 1024 {
        return Err(rejected());
    }
    source.seek(SeekFrom::Start(end))?;
    let mut buffer = [0; 8192];
    loop {
        let count = source.read(&mut buffer)?;
        if count == 0 {
            return Ok(());
        }
        if buffer[..count].iter().any(|byte| *byte != 0) {
            return Err(rejected());
        }
    }
}

fn unpack(
    source: &mut File,
    tree: &Path,
    uid: u32,
) -> io::Result<BTreeMap<String, Option<Attributes>>> {
    let mut directories = BTreeMap::<PathBuf, Attributes>::new();
    let mut regular = BTreeSet::new();
    let mut files = BTreeMap::new();
    let mut entries = BTreeSet::new();
    let mut roots = BTreeMap::new();
    let mut end = 0;
    {
        let mut tar = tar::Archive::new(&mut *source);
        for entry in tar.entries()? {
            let mut entry = entry?;
            let name = member(&entry.path()?)?;
            let parent = name.parent().expect("relative member");
            if entries.len() == MAX_ENTRIES
                || (!parent.as_os_str().is_empty() && !directories.contains_key(parent))
                || !entries.insert(name.clone())
            {
                return Err(rejected());
            }
            end = entry.raw_file_position() + entry.size().div_ceil(512) * 512;
            let kind = entry.header().entry_type();
            let attributes = Attributes::from(entry.header())?;
            if parent.as_os_str().is_empty() {
                roots.insert(
                    name.to_str().expect("UTF-8 member").to_owned(),
                    kind.is_dir().then_some(attributes),
                );
            }
            let target = tree.join(&name);
            match kind {
                tar::EntryType::Directory if entry.size() == 0 => {
                    publishing(
                        "archive_tree_mkdir",
                        with_filesystem_owner(uid, || fs::create_dir(&target)),
                    )?;
                    directories.insert(name, attributes);
                }
                tar::EntryType::Regular => {
                    let mut file = publishing(
                        "archive_tree_file",
                        with_filesystem_owner(uid, || {
                            OpenOptions::new()
                                .write(true)
                                .create_new(true)
                                .mode(0o600)
                                .open(&target)
                        }),
                    )?;
                    if io::copy(&mut entry, &mut file)? != entry.size() {
                        return Err(rejected());
                    }
                    files.insert(name.clone(), attributes);
                    regular.insert(name);
                }
                tar::EntryType::Link if entry.size() == 0 => {
                    let link = member(&entry.link_name()?.ok_or_else(rejected)?)?;
                    if !regular.contains(&link) {
                        return Err(rejected());
                    }
                    publishing(
                        "archive_tree_hardlink",
                        with_filesystem_owner(uid, || fs::hard_link(tree.join(link), target)),
                    )?;
                    regular.insert(name);
                }
                tar::EntryType::Symlink if entry.size() == 0 => {
                    let link = entry.link_name()?.ok_or_else(rejected)?;
                    let name = name.to_str().expect("UTF-8 member");
                    if !link
                        .to_str()
                        .is_some_and(|link| crate::oci::rooted_symlink(name, link))
                    {
                        return Err(rejected());
                    }
                    publishing(
                        "archive_tree_symlink",
                        with_filesystem_owner(uid, || symlink(link, &target)),
                    )?;
                    publishing(
                        "archive_tree_link_owner",
                        lchown(&target, Some(attributes.uid), Some(attributes.gid)),
                    )?;
                }
                _ => return Err(rejected()),
            }
        }
    }
    if roots.is_empty() {
        return Err(rejected());
    }
    publishing("archive_tree_terminator", verify_end(source, end))?;
    // Set ownership after all links are created. Until then every regular
    // inode is owned by the private staging identity.
    for (path, attributes) in files {
        let target = tree.join(path);
        let file = File::open(&target)?;
        publishing("archive_tree_attributes", attributes.apply(&target))?;
        publishing("archive_tree_sync", file.sync_all())?;
    }
    for (path, attributes) in directories.into_iter().rev() {
        if path
            .parent()
            .is_some_and(|parent| parent.as_os_str().is_empty())
        {
            continue;
        }
        let directory = tree.join(path);
        publishing(
            "archive_tree_directory_attributes",
            attributes.apply(&directory),
        )?;
        publishing(
            "archive_tree_directory_sync",
            File::open(directory)?.sync_all(),
        )?;
    }
    Ok(roots)
}

pub(super) fn publish(parent: &File, staging: &Staging, source: &mut File) -> io::Result<()> {
    let stage = staging.directory.as_raw_fd();
    publishing(
        "archive_tree_stage",
        with_filesystem_owner(staging.uid, || {
            checked(unsafe { libc::mkdirat(stage, c"tree".as_ptr(), 0o700) })
        }),
    )?;
    let descriptor = unsafe {
        libc::openat(
            stage,
            c"tree".as_ptr(),
            libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_RDONLY,
        )
    };
    if descriptor < 0 {
        return publishing("archive_tree_open", Err(io::Error::last_os_error()));
    }
    let tree = unsafe { File::from_raw_fd(descriptor) };
    let metadata = tree.metadata()?;
    if metadata.uid() != staging.uid || metadata.mode() & 0o777 != 0o700 {
        return publishing("archive_tree_owner", Err(rejected()));
    }
    let path = PathBuf::from(format!("/proc/self/fd/{}", tree.as_raw_fd()));
    let roots = unpack(source, &path, staging.uid)?;
    let names = roots
        .into_iter()
        .map(|(name, attributes)| Ok((CString::new(name)?, attributes)))
        .collect::<io::Result<Vec<_>>>()?;
    for (name, _) in &names {
        let mut info = std::mem::MaybeUninit::<libc::stat>::uninit();
        let found = unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                name.as_ptr(),
                info.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if found == 0 || io::Error::last_os_error().kind() != io::ErrorKind::NotFound {
            return Err(rejected());
        }
    }
    if staging.publisher != staging.uid {
        // The temporary tree remains behind the private staging directory.
        // The mapped destination owner can now rename through the held FDs.
        publishing(
            "archive_tree_publish_owner",
            checked(unsafe { libc::fchown(tree.as_raw_fd(), staging.publisher, GID_BASE) }),
        )?;
    }
    for (name, attributes) in names {
        // Linux requires write permission on a directory to update its ".."
        // entry during a cross-directory rename. Set the final owner and mode
        // through the held FD only after the mapped publisher has moved it.
        let directory = if let Some(attributes) = attributes {
            let descriptor = unsafe {
                libc::openat(
                    tree.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_RDONLY,
                )
            };
            if descriptor < 0 {
                return publishing("archive_tree_publish_open", Err(io::Error::last_os_error()));
            }
            let directory = unsafe { File::from_raw_fd(descriptor) };
            let provisional = Attributes {
                uid: staging.publisher,
                gid: GID_BASE,
                mode: 0o700,
            };
            publishing(
                "archive_tree_publish_stage",
                provisional.apply_directory(&directory),
            )?;
            Some((directory, attributes))
        } else {
            None
        };
        let result = with_filesystem_owner(staging.publisher, || {
            checked(unsafe {
                libc::syscall(
                    libc::SYS_renameat2,
                    tree.as_raw_fd(),
                    name.as_ptr(),
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::RENAME_NOREPLACE,
                ) as i32
            })
        });
        if let Err(error) = result {
            let code = match error.raw_os_error() {
                Some(libc::EACCES) => "archive_tree_publish_access",
                Some(libc::EPERM) => "archive_tree_publish_permission",
                Some(libc::EXDEV) => "archive_tree_publish_cross_device",
                Some(libc::EINVAL) => "archive_tree_publish_invalid",
                Some(libc::ENOENT) => "archive_tree_publish_missing",
                Some(libc::EEXIST) => "archive_tree_publish_exists",
                _ => "archive_tree_publish",
            };
            return publishing(code, Err(error));
        }
        if let Some((directory, attributes)) = directory {
            publishing(
                "archive_tree_publish_attributes",
                attributes.apply_directory(&directory),
            )?;
        }
    }
    Ok(())
}

use std::fs::OpenOptions;
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use crate::spec::{Account, ID_MAP_WIDTH};

const ACCOUNT_FILE_LIMIT: u64 = 64 * 1024;

fn mapped(value: &str) -> io::Result<u32> {
    value
        .parse::<u32>()
        .ok()
        .filter(|id| *id < ID_MAP_WIDTH)
        .ok_or_else(|| io::Error::other("image account requires a mapped ID"))
}

fn numeric(value: &str) -> bool {
    value.bytes().all(|byte| byte.is_ascii_digit())
}

fn read(root: &std::fs::File, path: &str) -> io::Result<String> {
    let file = match crate::workload_copy::open_path(root, path, libc::O_RDONLY | libc::O_NONBLOCK)
    {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(String::new()),
        Err(error) => return Err(error),
    };
    let info = file.metadata()?;
    if !info.is_file() || info.len() > ACCOUNT_FILE_LIMIT {
        return Err(io::Error::other("invalid image account file"));
    }
    let mut data = String::new();
    file.take(ACCOUNT_FILE_LIMIT + 1)
        .read_to_string(&mut data)?;
    if data.len() as u64 > ACCOUNT_FILE_LIMIT || data.contains('\0') {
        return Err(io::Error::other("invalid image account data"));
    }
    Ok(data)
}

pub(crate) fn resolve_image(digest: &str, account: &Account) -> io::Result<(u32, u32)> {
    if !account.valid() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let (root, _) = crate::sandbox_fixture::image_lower(digest)?;
    resolve(&root, account)
}

fn resolve(root: &Path, account: &Account) -> io::Result<(u32, u32)> {
    let root = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(root)?;
    let user = &account.user;
    let provided_uid = numeric(user).then(|| mapped(user)).transpose()?;
    let passwd = read(&root, "/etc/passwd")?;
    let mut candidates = passwd.lines().filter_map(|row| {
        let mut fields = row.split(':');
        let name = fields.next()?;
        let uid = fields.nth(1)?;
        let gid = fields.next()?;
        let matches = provided_uid.map_or(name == user, |value| uid.parse::<u32>() == Ok(value));
        matches.then_some((uid, gid))
    });
    let (uid, mut gid) = if let Some((uid, gid)) = candidates.next() {
        if candidates.next().is_some() {
            return Err(io::Error::other("ambiguous image user"));
        }
        (
            mapped(uid)?,
            if account.group.is_some() {
                0
            } else {
                mapped(gid)?
            },
        )
    } else {
        (
            provided_uid.ok_or_else(|| io::Error::other("image user was not found"))?,
            0,
        )
    };
    if let Some(group) = &account.group {
        gid = if numeric(group) {
            mapped(group)?
        } else {
            let groups = read(&root, "/etc/group")?;
            let mut candidates = groups.lines().filter_map(|row| {
                let mut fields = row.split(':');
                let name = fields.next()?;
                let gid = fields.nth(1)?;
                (name == group).then_some(gid)
            });
            let first = candidates
                .next()
                .ok_or_else(|| io::Error::other("image group was not found"))?;
            if candidates.next().is_some() {
                return Err(io::Error::other("ambiguous image group"));
            }
            mapped(first)?
        };
    }
    Ok((uid, gid))
}

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use crate::handshake::{hex, unhex};

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) const DIRECTORY: &str = "/run/conjet/fresh-intent";

// The fixture admits one workload. Its intent survives a helper or service
// process losing memory, but disappears with the disposable guest.
pub(crate) struct Intent {
    directory: PathBuf,
    name: String,
}

impl Intent {
    pub(crate) fn open(directory: &Path) -> Self {
        Self {
            directory: directory.into(),
            name: "active".into(),
        }
    }

    pub(crate) fn scoped(&self, id: [u8; 16]) -> Self {
        Self {
            directory: self.directory.clone(),
            name: format!("oci-{}", hex(&id)),
        }
    }

    pub(crate) fn scoped_inventory(&self) -> io::Result<Vec<([u8; 16], Self)>> {
        let mut intents = Vec::new();
        let entries = match self.directory.read_dir() {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(intents),
            Err(error) => return Err(error),
        };
        for entry in entries {
            let entry = entry?;
            let raw = entry.file_name();
            let Some(name) = raw.to_str().and_then(|name| name.strip_prefix("oci-")) else {
                continue;
            };
            let id = unhex::<16>(name).map_err(io::Error::other)?;
            let intent = self.scoped(id);
            if intent.read()? != Some(id) || intents.len() >= 8 {
                return Err(io::Error::other(
                    "invalid or excessive OCI workload intents",
                ));
            }
            intents.push((id, intent));
        }
        intents.sort_unstable_by_key(|(id, _)| *id);
        Ok(intents)
    }

    pub(crate) fn record(&self, id: [u8; 16]) -> io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(self.directory.join(&self.name))?;
        // A truncated record after interruption is retained and fails closed.
        // Exclusive creation also prevents a second owner overwriting it.
        file.write_all(hex(&id).as_bytes())?;
        file.sync_all()?;
        File::open(&self.directory)?.sync_all()
    }

    pub(crate) fn read(&self) -> io::Result<Option<[u8; 16]>> {
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(self.directory.join(&self.name))
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        if !file.metadata()?.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid intent file",
            ));
        }
        let mut encoded = String::new();
        file.take(33).read_to_string(&mut encoded)?;
        unhex(&encoded)
            .map(Some)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid workload intent"))
    }

    pub(crate) fn complete(&self, id: [u8; 16]) -> io::Result<()> {
        if self.read()? != Some(id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "workload intent changed during cleanup",
            ));
        }
        fs::remove_file(self.directory.join(&self.name))?;
        File::open(&self.directory)?.sync_all()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_one_owner_and_keeps_unresolved_or_corrupt_intent() {
        let suffix: [u8; 16] = crate::handshake::random().unwrap();
        let private = std::env::temp_dir().join(format!("conjet-intent-{}", hex(&suffix)));
        fs::create_dir(&private).unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(private.clone());
        let intent = Intent::open(&private);
        assert_eq!(intent.read().unwrap(), None);
        intent.record([7; 16]).unwrap();
        let reopened = Intent::open(&private);
        assert_eq!(reopened.read().unwrap(), Some([7; 16]));
        assert_eq!(
            reopened.record([9; 16]).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        assert!(reopened.complete([9; 16]).is_err());
        reopened.complete([7; 16]).unwrap();
        assert_eq!(reopened.read().unwrap(), None);
        fs::write(private.join("active"), b"truncated").unwrap();
        assert!(reopened.complete([7; 16]).is_err());
        assert!(private.join("active").is_file());
    }

    #[test]
    fn scans_scoped_intents_and_only_releases_the_named_owner() {
        let suffix: [u8; 16] = crate::handshake::random().unwrap();
        let directory = std::env::temp_dir().join(format!("conjet-scoped-intent-{}", hex(&suffix)));
        fs::create_dir(&directory).unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(directory.clone());
        let base = Intent::open(&directory);
        let first = [1; 16];
        let second = [2; 16];
        base.scoped(first).record(first).unwrap();
        base.scoped(second).record(second).unwrap();
        assert_eq!(
            base.scoped_inventory()
                .unwrap()
                .iter()
                .map(|(id, _)| *id)
                .collect::<Vec<_>>(),
            [first, second]
        );
        assert!(base.scoped(first).complete(second).is_err());
        base.scoped(first).complete(first).unwrap();
        assert_eq!(base.scoped_inventory().unwrap()[0].0, second);
        fs::write(
            directory.join(format!("oci-{}", hex(&second))),
            "mismatched",
        )
        .unwrap();
        assert!(base.scoped_inventory().is_err());
    }
}

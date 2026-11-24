//! Disk image packages use length-prefixed metadata and raw file extents.
use std::collections::BTreeMap;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::ops::Range;

use crate::handshake::hex;

use super::{Kind, Record, Root};

const MAGIC: &[u8; 8] = b"CJOCI\x02\0\0";
const METADATA_LIMIT: usize = 8192;
pub const RECORD_LIMIT: usize = 32_768;
pub const BYTE_LIMIT: u64 = 1200 * 1024 * 1024;

/// The regular-file bytes remain in the verified package.
pub struct Index {
    pub root: Root,
    extents: BTreeMap<String, Range<u64>>,
}

impl Index {
    pub fn read(source: &mut (impl Read + Seek), size: u64) -> io::Result<Self> {
        ensure!(
            size <= BYTE_LIMIT,
            "disk OCI package exceeds its byte limit"
        );
        let mut magic = [0; 8];
        source.read_exact(&mut magic)?;
        ensure!(&magic == MAGIC, "invalid disk OCI package header");
        let mut digest = [0; 32];
        source.read_exact(&mut digest)?;
        let count = read_u32(source)? as usize;
        ensure!(
            (1..=RECORD_LIMIT).contains(&count),
            "invalid disk OCI entry count"
        );
        let mut records = Vec::with_capacity(count);
        let mut extents = BTreeMap::new();
        let mut metadata = Vec::new();
        for _ in 0..count {
            let len = read_u32(source)? as usize;
            ensure!(
                (1..=METADATA_LIMIT).contains(&len),
                "invalid disk OCI entry metadata size"
            );
            metadata.resize(len, 0);
            source.read_exact(&mut metadata)?;
            let record: Record = serde_json::from_slice(&metadata)?;
            ensure!(record.data.is_empty(), "disk OCI entry embeds file bytes");
            let mut bytes = [0; 8];
            source.read_exact(&mut bytes)?;
            let length = u64::from_le_bytes(bytes);
            if record.kind == Kind::File {
                let start = source.stream_position()?;
                let end = start
                    .checked_add(length)
                    .filter(|end| *end <= size)
                    .ok_or_else(|| io::Error::other("truncated disk OCI extent"))?;
                source.seek(SeekFrom::Start(end))?;
                extents.insert(record.path.clone(), start..end);
            } else {
                ensure!(length == 0, "non-file disk OCI entry has an extent");
            }
            records.push(record);
        }
        ensure!(
            source.stream_position()? == size,
            "disk OCI package has trailing or missing bytes"
        );
        let root = Root {
            config_digest: format!("sha256:{}", hex(&digest)),
            records,
        }
        .validate_with_limit(RECORD_LIMIT)?;
        Ok(Self { root, extents })
    }

    pub fn copy_file(
        &self,
        source: &mut (impl Read + Seek),
        path: &str,
        target: &mut impl Write,
    ) -> io::Result<()> {
        let extent = self
            .extents
            .get(path)
            .ok_or_else(|| io::Error::other("missing disk OCI extent"))?;
        source.seek(SeekFrom::Start(extent.start))?;
        let length = extent.end - extent.start;
        ensure!(
            io::copy(&mut source.take(length), target)? == length,
            "disk OCI extent ended during install"
        );
        Ok(())
    }
}

fn read_u32(source: &mut impl Read) -> io::Result<u32> {
    let mut bytes = [0; 4];
    source.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    fn frame(parts: &[(&str, Kind, &str, &[u8])]) -> Vec<u8> {
        let mut bytes = MAGIC.to_vec();
        bytes.extend_from_slice(&[0xab; 32]);
        bytes.extend_from_slice(&(parts.len() as u32).to_le_bytes());
        for (path, kind, target, data) in parts {
            let record = Record {
                path: (*path).into(),
                kind: *kind,
                mode: 0o755,
                uid: 0,
                gid: 0,
                target: (*target).into(),
                data: String::new(),
            };
            let metadata = serde_json::to_vec(&record).unwrap();
            bytes.extend_from_slice(&(metadata.len() as u32).to_le_bytes());
            bytes.extend_from_slice(&metadata);
            bytes.extend_from_slice(&(data.len() as u64).to_le_bytes());
            bytes.extend_from_slice(data);
        }
        bytes
    }

    fn read(bytes: &[u8]) -> io::Result<Index> {
        Index::read(&mut Cursor::new(bytes), bytes.len() as u64)
    }

    #[test]
    fn indexes_extents_without_putting_contents_in_the_root_metadata() {
        let bytes = frame(&[
            ("bin", Kind::Directory, "", b""),
            ("bin/runner", Kind::File, "", b"runner"),
            ("bin/next", Kind::File, "", b"other bytes"),
            ("bin/alias", Kind::Hardlink, "bin/runner", b""),
        ]);
        let packed = read(&bytes).unwrap();
        assert!(
            packed
                .root
                .records
                .iter()
                .all(|record| record.data.is_empty())
        );
        assert_eq!(packed.root.link_groups()["bin/runner"], ["bin/alias"]);
        let mut content = Vec::new();
        packed
            .copy_file(&mut Cursor::new(bytes), "bin/runner", &mut content)
            .unwrap();
        assert_eq!(content, b"runner");
    }

    #[test]
    fn refuses_invalid_paths_links_and_framing() {
        for parts in [
            vec![("../escape", Kind::File, "", b"x".as_slice())],
            vec![("absent/child", Kind::File, "", b"x".as_slice())],
            vec![("alias", Kind::Hardlink, "gone", b"".as_slice())],
            vec![("link", Kind::Symlink, "../escape", b"".as_slice())],
            vec![("dir", Kind::Directory, "", b"payload".as_slice())],
            vec![
                ("same", Kind::File, "", b"1".as_slice()),
                ("same", Kind::File, "", b"2".as_slice()),
            ],
        ] {
            assert!(read(&frame(&parts)).is_err());
        }
        let mut bytes = frame(&[("file", Kind::File, "", b"body")]);
        assert!(read(&bytes[..bytes.len() - 1]).is_err());
        bytes.push(0);
        assert!(read(&bytes).is_err());
        bytes[0] = 0;
        assert!(read(&bytes).is_err());
    }
}

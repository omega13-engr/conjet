use std::io::{self, Read};

const OUTPUT_CAPACITY: usize = 64 * 1024;

#[derive(Default)]
pub(crate) struct Capture {
    pub(crate) bytes: Vec<u8>,
    pub(crate) dropped: u64,
}

impl Capture {
    pub(crate) fn append(&mut self, data: &[u8]) {
        let kept = data.len().min(OUTPUT_CAPACITY - self.bytes.len());
        self.bytes.extend_from_slice(&data[..kept]);
        self.dropped = self.dropped.saturating_add((data.len() - kept) as u64);
    }
}

pub(crate) fn drain(mut reader: impl Read, mut push: impl FnMut(&[u8])) -> io::Result<()> {
    let mut buffer = [0; 8192];
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            return Ok(());
        }
        push(&buffer[..count]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drains_excess_bytes_without_retaining_them() {
        let mut input = vec![b'a'; OUTPUT_CAPACITY];
        input.extend_from_slice(&[b'b'; 16_384]);
        let mut captured = Capture::default();
        drain(input.as_slice(), |bytes| captured.append(bytes)).unwrap();
        assert_eq!(captured.bytes, vec![b'a'; OUTPUT_CAPACITY]);
        assert_eq!(captured.dropped, 16_384);
    }
}

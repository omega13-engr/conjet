use std::io::{self, Read};

#[derive(Default)]
pub(crate) struct Capture {
    pub(crate) bytes: Vec<u8>,
    pub(crate) dropped: u64,
}

impl Capture {
    pub(crate) fn acknowledge(&mut self, base: &mut usize, cursor: usize) -> io::Result<()> {
        let consumed = cursor
            .checked_sub(*base)
            .filter(|count| *count <= self.bytes.len())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid output cursor"))?;
        self.bytes.drain(..consumed);
        *base = cursor;
        Ok(())
    }

    pub(crate) fn append_bounded(&mut self, data: &[u8], capacity: usize) {
        let kept = data.len().min(capacity.saturating_sub(self.bytes.len()));
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
        let capacity = crate::spec::workload_output_limit("");
        let mut input = vec![b'a'; capacity];
        input.extend_from_slice(&[b'b'; 16_384]);
        let mut captured = Capture::default();
        drain(input.as_slice(), |bytes| {
            captured.append_bounded(bytes, capacity)
        })
        .unwrap();
        assert_eq!(captured.bytes, vec![b'a'; capacity]);
        assert_eq!(captured.dropped, 16_384);
    }
    #[test]
    fn acknowledged_stream_reuses_capacity_without_losing_bytes() {
        let mut capture = Capture::default();
        let mut base = 0;
        let mut expected = 0;
        for value in 0..200u8 {
            capture.append_bounded(&[value; 4096], 4096);
            assert_eq!(capture.bytes, vec![value; 4096]);
            expected += 4096;
            capture.acknowledge(&mut base, expected).unwrap();
            assert!(capture.bytes.is_empty());
        }
        assert_eq!(base, 819200);
        assert_eq!(capture.dropped, 0);
    }

    #[test]
    fn stale_or_future_acknowledgements_do_not_discard_output() {
        let mut capture = Capture::default();
        let mut base = 10;
        capture.append_bounded(b"abcdef", 16);
        for cursor in [0, 9, 17, usize::MAX] {
            assert!(capture.acknowledge(&mut base, cursor).is_err());
            assert_eq!(base, 10);
            assert_eq!(capture.bytes, b"abcdef");
        }
        capture.acknowledge(&mut base, 12).unwrap();
        assert_eq!(capture.bytes, b"cdef");
        capture.acknowledge(&mut base, 12).unwrap();
        assert_eq!(capture.bytes, b"cdef");
    }
}

use std::io::{self, Read};

const OUTPUT_CAPACITY: usize = 64 * 1024;

#[derive(Default)]
pub(crate) struct Capture {
    pub(crate) bytes: Vec<u8>,
    pub(crate) dropped: u64,
}

pub(crate) fn capture(mut reader: impl Read) -> io::Result<Capture> {
    let mut output = Capture::default();
    let mut buffer = [0; 8192];
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            return Ok(output);
        }
        let kept = count.min(OUTPUT_CAPACITY - output.bytes.len());
        output.bytes.extend_from_slice(&buffer[..kept]);
        output.dropped = output.dropped.saturating_add((count - kept) as u64);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drains_excess_bytes_without_retaining_them() {
        let mut input = vec![b'a'; OUTPUT_CAPACITY];
        input.extend_from_slice(&[b'b'; 16_384]);
        let captured = capture(input.as_slice()).unwrap();
        assert_eq!(captured.bytes, vec![b'a'; OUTPUT_CAPACITY]);
        assert_eq!(captured.dropped, 16_384);
    }
}

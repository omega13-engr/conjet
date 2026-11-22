#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
use std::io::Read;

pub(crate) const MIN_AVAILABLE_BYTES: u64 = 64 * 1024 * 1024;

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) fn available_bytes() -> Option<u64> {
    let mut info = String::new();
    std::fs::File::open("/proc/meminfo")
        .ok()?
        .take(8192)
        .read_to_string(&mut info)
        .ok()?;
    parse_available(&info)
}

fn parse_available(info: &str) -> Option<u64> {
    let mut fields = info
        .lines()
        .find_map(|line| line.strip_prefix("MemAvailable:"))?
        .split_whitespace();
    let kib: u64 = fields.next()?.parse().ok()?;
    if fields.next()? != "kB" || fields.next().is_some() {
        return None;
    }
    kib.checked_mul(1024)
}

pub(crate) fn pressures_reserve(available_bytes: Option<u64>) -> bool {
    available_bytes.is_none_or(|bytes| bytes < MIN_AVAILABLE_BYTES)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_and_malformed_telemetry_cannot_authorize_preparation() {
        for text in [
            "MemFree: 999999 kB",
            "MemAvailable: unknown kB",
            "MemAvailable: 999999 bytes",
            "MemAvailable: 18446744073709551615 kB",
        ] {
            assert!(pressures_reserve(parse_available(text)));
        }
        assert!(pressures_reserve(parse_available(
            "MemAvailable: 65535 kB\n"
        )));
        assert!(!pressures_reserve(parse_available(
            "MemAvailable: 65536 kB\n"
        )));
    }
}

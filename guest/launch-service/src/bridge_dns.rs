#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
use std::net::Ipv4Addr;
#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
const HEADER: usize = 12;
#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
pub(super) const MAX_MESSAGE: usize = 512;

fn label(bytes: &[u8]) -> bool {
    (1..=63).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes[bytes.len() - 1].is_ascii_alphanumeric()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
}

pub(super) fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 253 && name.as_bytes().split(|byte| *byte == b'.').all(label)
}

/// Answer one uncompressed IN question without forwarding it anywhere.
#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
pub(super) fn answer(
    message: &[u8],
    lookup: impl FnOnce(&str) -> Vec<Ipv4Addr>,
) -> Option<Vec<u8>> {
    let [_, _, flags, resolver_flags, 0, 1, 0, 0, 0, 0, 0, 0, ..] = message else {
        return None;
    };
    // Recognize the resolver's AD/CD request bits. This local registry
    // does no DNSSEC validation and never sets those response bits.
    if *flags & !1 != 0 || *resolver_flags & !0x30 != 0 || message.len() > MAX_MESSAGE {
        return None;
    }
    let mut cursor = HEADER;
    let mut name = String::new();
    loop {
        let length = *message.get(cursor)? as usize;
        cursor += 1;
        if length == 0 {
            break;
        }
        let segment = message.get(cursor..cursor + length)?;
        if !label(segment) {
            return None;
        }
        if !name.is_empty() {
            name.push('.');
        }
        name.extend(
            segment
                .iter()
                .map(|byte| char::from(byte.to_ascii_lowercase())),
        );
        cursor += length;
    }
    if name.is_empty() || name.len() > 253 {
        return None;
    }
    let &[0, kind, 0, 1] = message.get(cursor..)? else {
        return None;
    };
    if !matches!(kind, 1 | 28) {
        return None;
    }
    let addresses = lookup(&name);
    let mut response = message.to_vec();
    response[2] = 0x84 | *flags;
    response[3] = if addresses.is_empty() { 3 } else { 0 };
    // A known service has no IPv6 addresses. The bridge has at most 8 peers.
    if kind == 1 {
        for ip in addresses.into_iter().take(8) {
            response[7] += 1;
            response.extend_from_slice(b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x00\x00\x04");
            response.extend_from_slice(&ip.octets());
        }
    }
    Some(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    const QUERY: &[u8] =
        b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03App\x04Test\0\0\x01\0\x01";
    const IP: Ipv4Addr = Ipv4Addr::new(198, 18, 0, 2);

    #[test]
    fn authoritative_case_insensitive_a_answer() {
        let mut query = QUERY.to_vec();
        query[3] = 0x20;
        let reply = answer(&query, |name| {
            (name == "app.test").then_some(IP).into_iter().collect()
        })
        .unwrap();
        assert_eq!(&reply[..8], &[0x12, 0x34, 0x85, 0, 0, 1, 0, 1]);
        assert_eq!(&reply[reply.len() - 4..], &IP.octets());
    }

    #[test]
    fn shared_service_returns_each_ipv4_answer() {
        let second = Ipv4Addr::new(198, 18, 0, 7);
        let reply = answer(QUERY, |_| vec![IP, second]).unwrap();
        assert_eq!(reply[7], 2);
        assert_eq!(&reply[QUERY.len() + 12..QUERY.len() + 16], &IP.octets());
        assert_eq!(&reply[reply.len() - 4..], &second.octets());
        assert!(reply.len() <= MAX_MESSAGE);
    }

    #[test]
    fn missing_name_and_known_service_without_ipv6_have_distinct_responses() {
        let mut aaaa = QUERY.to_vec();
        aaaa[QUERY.len() - 3] = 28;
        let reply = answer(&aaaa, |_| vec![IP]).unwrap();
        assert_eq!(&reply[2..8], &[0x85, 0, 0, 1, 0, 0]);
        let reply = answer(QUERY, |_| Vec::new()).unwrap();
        assert_eq!(&reply[2..8], &[0x85, 3, 0, 1, 0, 0]);
    }

    #[test]
    fn malformed_and_unbounded_questions_never_reach_lookup() {
        let mut compressed = QUERY.to_vec();
        compressed[12] = 0xc0;
        let mut two_questions = QUERY.to_vec();
        two_questions[5] = 2;
        for invalid in [
            &QUERY[..QUERY.len() - 1],
            &compressed,
            &two_questions,
            &[0; MAX_MESSAGE + 1],
        ] {
            assert!(answer(invalid, |_| panic!("invalid DNS question reached lookup")).is_none());
        }
        for invalid in [
            "",
            "-alias",
            "alias-",
            "dotted..alias",
            "space alias",
            "alias.",
        ] {
            assert!(!valid_name(invalid));
        }
        assert!(valid_name("api-1.example"));
    }
}

use std::net::Ipv4Addr;

const HEADER: usize = 12;
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
pub(super) fn answer(
    message: &[u8],
    lookup: impl FnOnce(&str) -> Option<Ipv4Addr>,
) -> Option<Vec<u8>> {
    let [_, _, flags, 0, 0, 1, 0, 0, 0, 0, 0, 0, ..] = message else {
        return None;
    };
    if *flags & !1 != 0 || message.len() > MAX_MESSAGE {
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
    let address = lookup(&name);
    let endpoint = match kind {
        1 => address,
        28 => None, // A known service has no IPv6 address.
        _ => return None,
    };
    let mut response = message.to_vec();
    response[2] = 0x84 | *flags;
    response[3] = if address.is_some() { 0 } else { 3 };
    if let Some(ip) = endpoint {
        response[7] = 1;
        response.extend_from_slice(b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x00\x00\x04");
        response.extend_from_slice(&ip.octets());
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
        let reply = answer(QUERY, |name| (name == "app.test").then_some(IP)).unwrap();
        assert_eq!(&reply[..8], &[0x12, 0x34, 0x85, 0, 0, 1, 0, 1]);
        assert_eq!(&reply[reply.len() - 4..], &IP.octets());
    }

    #[test]
    fn missing_name_and_known_service_without_ipv6_have_distinct_responses() {
        let mut aaaa = QUERY.to_vec();
        aaaa[QUERY.len() - 3] = 28;
        let reply = answer(&aaaa, |_| Some(IP)).unwrap();
        assert_eq!(&reply[2..8], &[0x85, 0, 0, 1, 0, 0]);
        let reply = answer(QUERY, |_| None).unwrap();
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

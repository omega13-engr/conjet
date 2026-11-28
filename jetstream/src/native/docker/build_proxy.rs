//! Public web egress for the authenticated, private BuildKit worker relay.
use std::io::Write;
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use super::{Owner, STOP};
use anyhow::{ensure, Context};
use conjet_launch_service::socket::Stream;

struct Request<'a> {
    host: &'a str,
    port: u16,
    path: &'a str,
    method: &'a str,
}

fn parse(line: &str) -> anyhow::Result<Request<'_>> {
    let words: Vec<_> = line.split_ascii_whitespace().collect();
    ensure!(
        words.len() == 3 && words[2] == "HTTP/1.1",
        "invalid proxy request"
    );
    let (method, target) = (words[0], words[1]);
    let (authority, path) = if method == "CONNECT" {
        (target, "")
    } else {
        ensure!(
            matches!(method, "GET" | "HEAD"),
            "unsupported web proxy method"
        );
        let target = target
            .strip_prefix("http://")
            .context("expected absolute HTTP URL")?;
        target
            .split_once('/')
            .map_or((target, "/"), |(host, _)| (host, &target[host.len()..]))
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, port.parse::<u16>()?),
        None => (authority, 80),
    };
    ensure!(
        !host.is_empty()
            && host.len() <= 253
            && host.split('.').all(|label| !label.is_empty()
                && label.len() <= 63
                && label.as_bytes()[0].is_ascii_alphanumeric()
                && label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')),
        "invalid proxy hostname"
    );
    ensure!(
        (method == "CONNECT" && port == 443) || (method != "CONNECT" && port == 80),
        "unsupported web proxy port"
    );
    ensure!(!path.contains('#'), "invalid HTTP request path");
    Ok(Request {
        host,
        port,
        path,
        method,
    })
}

fn public(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(ip) => {
            let [a, b, c, _] = ip.octets();
            !(a == 0
                || a == 10
                || a == 127
                || a >= 224
                || (a == 100 && (64..=127).contains(&b))
                || (a == 169 && b == 254)
                || (a == 172 && (16..=31).contains(&b))
                || (a == 192 && (b == 168 || (b == 0 && c == 0) || (b == 0 && c == 2)))
                || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                || (a == 203 && b == 0 && c == 113))
        }
        IpAddr::V6(ip) => {
            let segments = ip.segments();
            segments[0] & 0xe000 == 0x2000
                && segments[0] != 0x2002 // 6to4 embeds an unchecked IPv4 destination.
                && !(segments[0] == 0x2001 && (segments[1] < 0x0200 || segments[1] == 0xdb8))
        }
    }
}

fn headers(header: &str) -> anyhow::Result<Vec<(&str, &str)>> {
    let mut fields = Vec::new();
    for line in header.split("\r\n").skip(1).filter(|s| !s.is_empty()) {
        let (name, value) = line.split_once(':').context("invalid proxy header")?;
        ensure!(
            !name.is_empty()
                && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                && value.bytes().all(|b| b == b'\t' || (b >= 32 && b != 127)),
            "invalid proxy header characters"
        );
        ensure!(
            !name.eq_ignore_ascii_case("transfer-encoding")
                && (!name.eq_ignore_ascii_case("content-length") || value.trim() == "0"),
            "proxy request bodies are unsupported"
        );
        fields.push((name, value));
    }
    // Honor named hop-by-hop fields without forwarding proxy credentials.
    let hops: Vec<_> = fields
        .iter()
        .filter(|(name, _)| name.eq_ignore_ascii_case("connection"))
        .flat_map(|(_, value)| value.split(',').map(str::trim))
        .collect();
    Ok(fields
        .iter()
        .copied()
        .filter(|(name, _)| {
            ![
                "host",
                "connection",
                "proxy-connection",
                "proxy-authorization",
                "keep-alive",
                "upgrade",
                "te",
                "trailer",
                "content-length",
            ]
            .iter()
            .chain(hops.iter())
            .any(|n| name.eq_ignore_ascii_case(n))
        })
        .collect())
}

pub(super) fn serve(owner: &Owner, stream: &mut Stream, header: &str) -> anyhow::Result<()> {
    let mut lines = header.split("\r\n");
    let request = parse(lines.next().context("missing proxy request")?)?;
    let fields = headers(header)?;
    let addresses: Vec<_> = (request.host, request.port)
        .to_socket_addrs()?
        .take(16)
        .collect();
    ensure!(
        !addresses.is_empty() && addresses.iter().all(|a| public(a.ip())),
        "proxy destination is not public"
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut connected = None;
    for address in addresses {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        if let Ok(socket) = TcpStream::connect_timeout(
            &SocketAddr::new(address.ip(), request.port),
            remaining.min(Duration::from_secs(3)),
        ) {
            connected = Some(socket);
            break;
        }
    }
    let mut remote = connected.context("public web connection failed")?;
    remote.set_write_timeout(Some(Duration::from_secs(10)))?;
    if request.method == "CONNECT" {
        stream.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")?;
    } else {
        write!(
            remote,
            "{} {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n",
            request.method, request.path, request.host
        )?;
        for (name, value) in fields {
            write!(remote, "{name}:{value}\r\n")?;
        }
        remote.write_all(b"\r\n")?;
    }
    conjet_launch_service::relay::pump(stream, &remote, Duration::from_secs(30), || {
        STOP.load(Ordering::Acquire) || !owner.has_build_registry_worker()
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accepts_web_downloads_but_rejects_ambiguous_destinations() {
        assert_eq!(
            parse("CONNECT registry.npmjs.org:443 HTTP/1.1")
                .unwrap()
                .port,
            443
        );
        assert_eq!(
            parse("GET http://deb.debian.org/debian/ HTTP/1.1")
                .unwrap()
                .path,
            "/debian/"
        );
        for request in [
            "CONNECT localhost:22 HTTP/1.1",
            "GET http://a@b/ HTTP/1.1",
            "GET http://a:443/ HTTP/1.1",
            "POST http://a/ HTTP/1.1",
            "CONNECT [::1]:443 HTTP/1.1",
            "CONNECT x:443/ HTTP/1.1",
        ] {
            assert!(parse(request).is_err(), "{request}");
        }
    }
    #[test]
    fn validates_headers_before_connecting_and_strips_hop_fields() {
        assert!(headers("GET http://x/ HTTP/1.1\r\nX: a\nb\r\n\r\n").is_err());
        assert!(headers("GET http://x/ HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n").is_err());
        assert!(headers("CONNECT x:443 HTTP/1.1\r\nContent-Length: 2\r\n\r\n").is_err());
        let fields = headers("GET http://x/ HTTP/1.1\r\nConnection: X-Private\r\nX-Private: hidden\r\nProxy-Authorization: hidden\r\nAccept: */*\r\n\r\n").unwrap();
        assert_eq!(fields, vec![("Accept", " */*")]);
    }
    #[test]
    fn cannot_proxy_to_host_private_or_special_networks() {
        for address in [
            "0.0.0.0",
            "10.0.0.1",
            "127.0.0.1",
            "100.64.0.1",
            "169.254.169.254",
            "172.16.0.1",
            "192.168.1.1",
            "198.18.0.1",
            "224.0.0.1",
            "255.255.255.255",
            "::1",
            "::ffff:127.0.0.1",
            "fc00::1",
            "fe80::1",
            "2001:db8::1",
            "2002:7f00:1::1",
            "2001::1",
        ] {
            assert!(!public(address.parse().unwrap()), "{address}");
        }
        assert!(public("1.1.1.1".parse().unwrap()));
        assert!(public("2606:4700::1111".parse().unwrap()));
    }
}

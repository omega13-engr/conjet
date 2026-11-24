use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use super::{Item, Owner, Rejected, BACKEND, PLATFORM};

const MAX_HEADERS: usize = 16384;
const MAX_BODY: usize = 16384;
const READ_TIMEOUT: Duration = Duration::from_secs(3);
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const IDLE_TIMEOUT: Duration = Duration::from_secs(38);
const ARCHIVE_READ_TIMEOUT: Duration = Duration::from_secs(60);

struct Request {
    method: String,
    path: String,
    query: BTreeMap<String, String>,
    body: Vec<u8>,
    archive: Option<File>,
    close: bool,
    tcp_upgrade: bool,
}

type Result<T> = std::result::Result<T, Rejected>;

fn decode(value: &str) -> Result<String> {
    let mut bytes = Vec::with_capacity(value.len());
    let mut rest = value.as_bytes();
    while let Some((byte, tail)) = rest.split_first() {
        rest = tail;
        if *byte == b'%' {
            let hex = rest
                .get(..2)
                .and_then(|hex| std::str::from_utf8(hex).ok())
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
                .ok_or_else(|| Rejected::bad("invalid URL percent escape"))?;
            bytes.push(hex);
            rest = &rest[2..];
        } else {
            bytes.push(*byte);
        }
    }
    String::from_utf8(bytes).map_err(|_| Rejected::bad("invalid URL encoding"))
}

fn image_reference(path: &str, suffix: &str) -> Result<String> {
    let name = path
        .strip_prefix("/images/")
        .and_then(|path| path.strip_suffix(suffix))
        .filter(|name| !name.is_empty())
        .ok_or_else(|| Rejected::bad("missing Docker image reference"))?;
    decode(name)
}

fn line(
    reader: &mut BufReader<UnixStream>,
    left: &mut usize,
    deadline: Instant,
) -> Result<Option<String>> {
    let mut bytes = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Rejected(408, "Docker request deadline elapsed".into()));
        }
        reader
            .get_ref()
            .set_read_timeout(Some(remaining))
            .map_err(|_| Rejected::internal("cannot set read deadline"))?;
        let available = reader
            .fill_buf()
            .map_err(|_| Rejected(408, "Docker request was interrupted".into()))?;
        if available.is_empty() && bytes.is_empty() {
            return Ok(None);
        }
        let consumed = available.iter().position(|byte| *byte == b'\n');
        let count = consumed.map_or(available.len(), |index| index + 1);
        if count == 0 || count > *left {
            return Err(Rejected::bad("incomplete or oversized request header"));
        }
        bytes.extend_from_slice(&available[..count]);
        reader.consume(count);
        *left -= count;
        if consumed.is_some() {
            let bytes = bytes
                .strip_suffix(b"\r\n")
                .ok_or_else(|| Rejected::bad("malformed HTTP line"))?;
            return String::from_utf8(bytes.to_vec())
                .map(Some)
                .map_err(|_| Rejected::bad("invalid HTTP header encoding"));
        }
    }
}

fn copy_body(
    reader: &mut BufReader<UnixStream>,
    writer: &mut impl Write,
    mut count: usize,
    deadline: Instant,
) -> Result<()> {
    if count == 0 {
        return Ok(());
    }
    let mut buffer = [0; 32768];
    while count != 0 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Rejected(408, "Docker request deadline elapsed".into()));
        }
        reader
            .get_ref()
            .set_read_timeout(Some(remaining))
            .map_err(|_| Rejected::internal("cannot set read deadline"))?;
        let next = count.min(buffer.len());
        let read = reader.read(&mut buffer[..next]).map_err(|error| {
            if matches!(
                error.kind(),
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
            ) {
                Rejected(408, "Docker request deadline elapsed".into())
            } else {
                Rejected::bad("incomplete Docker request body")
            }
        })?;
        if read == 0 {
            return Err(Rejected::bad("incomplete Docker request body"));
        }
        writer
            .write_all(&buffer[..read])
            .map_err(|_| Rejected::internal("cannot write Docker request body"))?;
        count -= read;
    }
    Ok(())
}

fn read_exec_stdin(reader: &mut BufReader<UnixStream>) -> io::Result<Vec<u8>> {
    use conjet_launch_service::wire::EXEC_STDIN_LIMIT;
    let deadline = Instant::now() + READ_TIMEOUT;
    let mut buffer = [0; EXEC_STDIN_LIMIT + 1];
    let mut consumed = 0;
    while consumed <= EXEC_STDIN_LIMIT {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::other("native exec stdin deadline elapsed"));
        }
        reader.get_ref().set_read_timeout(Some(remaining))?;
        let count = reader.read(&mut buffer[consumed..])?;
        if count == 0 {
            return Ok(buffer[..consumed].to_vec());
        }
        consumed += count;
    }
    Err(io::Error::other("native exec stdin exceeds 4096 bytes"))
}

#[cfg(test)]
mod framing_tests {
    use super::*;

    #[test]
    fn tail_counts_retained_lines_and_preserves_a_partial_last_line() {
        let streams = [&b"one\ntwo\n"[..], &b"warning\nlast"[..]];
        assert_eq!(tail_offsets(streams, [true, true], 0), [8, 12]);
        assert_eq!(tail_offsets(streams, [true, true], 1), [8, 8]);
        assert_eq!(tail_offsets(streams, [true, true], 3), [4, 0]);
        assert_eq!(tail_offsets(streams, [true, false], 1), [4, 0]);
        assert_eq!(
            tail_offsets([&b"one\n\n"[..], &[]], [true, true], 1),
            [4, 0]
        );
    }

    #[test]
    fn disconnected_stream_releases_darwin_slot_but_half_close_preserves_output() {
        let (client, server) = UnixStream::pair().unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        assert!(!client_disconnected(&server));
        drop(client);
        assert!(client_disconnected(&server));
    }

    fn request(bytes: &[u8]) -> (BufReader<UnixStream>, UnixStream) {
        let (mut client, server) = UnixStream::pair().unwrap();
        client.write_all(bytes).unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        (BufReader::new(server), client)
    }

    #[test]
    fn archive_chunked_body_leaves_next_request_intact() {
        let scratch = tempfile::tempdir().unwrap();
        let (mut reader, _client) = request(b"POST /v1.44/images/load HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n1\r\nd\r\n0\r\n\r\nGET /_ping HTTP/1.1\r\n\r\n");
        let loaded = parse(&mut reader, Some(scratch.path())).unwrap().unwrap();
        let mut body = String::new();
        loaded.archive.unwrap().read_to_string(&mut body).unwrap();
        assert_eq!(body, "abcd");
        assert_eq!(parse(&mut reader, None).unwrap().unwrap().path, "/_ping");
    }

    #[test]
    fn archive_framing_rejects_ambiguity_truncation_and_unbounded_chunks() {
        let scratch = tempfile::tempdir().unwrap();
        for (headers_and_body, status) in [
            (
                &b"Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"[..],
                400,
            ),
            (&b"Transfer-Encoding: chunked\r\n\r\n4\r\nab"[..], 400),
            (&b"Transfer-Encoding: chunked\r\n\r\n4000001\r\n"[..], 413),
            (
                &b"Transfer-Encoding: chunked\r\n\r\n0\r\nExtra: value\r\n\r\n"[..],
                400,
            ),
        ] {
            let mut bytes = b"POST /images/load HTTP/1.1\r\n".to_vec();
            bytes.extend(headers_and_body);
            let (mut reader, _client) = request(&bytes);
            assert!(
                matches!(parse(&mut reader, Some(scratch.path())), Err(Rejected(code, _)) if code == status)
            );
        }
        let (mut reader, _client) = request(b"POST /v1.44/containers/create HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n");
        assert!(matches!(
            parse(&mut reader, Some(scratch.path())),
            Err(Rejected(400, _))
        ));
    }
}

fn copy_chunks(
    reader: &mut BufReader<UnixStream>,
    writer: &mut File,
    deadline: Instant,
    mut budget: usize,
) -> Result<()> {
    // Bound framing overhead independently of the decoded archive.
    let mut framing = 1024 * 1024;
    loop {
        let size = line(reader, &mut framing, deadline)?
            .ok_or_else(|| Rejected::bad("missing Docker archive chunk"))?;
        if size.is_empty() || size.len() > 16 || !size.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Rejected::bad("invalid Docker archive chunk size"));
        }
        let count = usize::from_str_radix(&size, 16)
            .map_err(|_| Rejected::bad("invalid Docker archive chunk size"))?;
        if count > budget {
            return Err(Rejected(413, "Docker archive exceeds its bound".into()));
        }
        if count != 0 {
            copy_body(reader, writer, count, deadline)?;
            budget -= count;
        }
        if line(reader, &mut framing, deadline)?.as_deref() != Some("") {
            return Err(Rejected::bad("invalid Docker archive chunk terminator"));
        }
        if count == 0 {
            return Ok(());
        }
    }
}

fn parse(
    reader: &mut BufReader<UnixStream>,
    archive_root: Option<&Path>,
) -> Result<Option<Request>> {
    let mut left = MAX_HEADERS;
    let deadline = Instant::now() + READ_TIMEOUT;
    let Some(first) = line(reader, &mut left, deadline)? else {
        return Ok(None);
    };
    let mut fields = first.split(' ');
    let (Some(method), Some(target), Some("HTTP/1.1"), None) =
        (fields.next(), fields.next(), fields.next(), fields.next())
    else {
        return Err(Rejected::bad("expected an HTTP/1.1 request"));
    };
    if !target.starts_with('/')
        || target.contains('#')
        || !target.bytes().all(|byte| byte.is_ascii_graphic())
    {
        return Err(Rejected::bad("expected an origin-form request target"));
    }
    let (path, raw_query) = target.split_once('?').unwrap_or((target, ""));
    let load = method == "POST" && matches!(path, "/v1.44/images/load" | "/images/load");
    let copy = method == "PUT"
        && path
            .strip_prefix("/v1.44")
            .unwrap_or(path)
            .strip_prefix("/containers/")
            .and_then(|route| route.strip_suffix("/archive"))
            .is_some_and(super::request::name);
    let spooled = load || copy;
    let body_limit = if load {
        super::archive::LIMIT
    } else if copy {
        super::workload_copy::UPLOAD_LIMIT
    } else {
        MAX_BODY
    };
    let mut size = None;
    let mut chunked = false;
    let mut expect = false;
    let mut close = false;
    let mut connection_upgrade = false;
    let mut tcp_upgrade = false;
    loop {
        let header = line(reader, &mut left, deadline)?
            .ok_or_else(|| Rejected::bad("incomplete HTTP headers"))?;
        if header.is_empty() {
            break;
        }
        let (key, value) = header
            .split_once(':')
            .ok_or_else(|| Rejected::bad("malformed HTTP header"))?;
        if key.is_empty()
            || !key
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^`_|~".contains(&byte))
            || !value
                .bytes()
                .all(|byte| byte == b'\t' || (b' '..=b'~').contains(&byte))
        {
            return Err(Rejected::bad("malformed HTTP header"));
        }
        let value = value.trim();
        if key.eq_ignore_ascii_case("transfer-encoding") {
            if !spooled || chunked || !value.eq_ignore_ascii_case("chunked") {
                return Err(Rejected::bad("unsupported Docker request body framing"));
            }
            chunked = true;
        }
        if key.eq_ignore_ascii_case("expect") {
            if !spooled || expect || !value.eq_ignore_ascii_case("100-continue") {
                return Err(Rejected::bad("unsupported Docker request expectation"));
            }
            expect = true;
        }
        if key.eq_ignore_ascii_case("content-length") {
            if size.is_some()
                || value.is_empty()
                || !value.bytes().all(|byte| byte.is_ascii_digit())
            {
                return Err(Rejected::bad("invalid content length"));
            }
            size = value
                .parse::<usize>()
                .ok()
                .filter(|bytes| *bytes <= body_limit);
            if size.is_none() {
                return Err(Rejected(
                    413,
                    "Docker request body exceeds its bound".into(),
                ));
            }
        }
        if key.eq_ignore_ascii_case("connection") {
            close |= value
                .split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("close"));
            connection_upgrade |= value
                .split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("upgrade"));
        }
        if key.eq_ignore_ascii_case("upgrade") {
            tcp_upgrade |= value.eq_ignore_ascii_case("tcp");
        }
    }
    let mut query = BTreeMap::new();
    for pair in raw_query.split('&').filter(|pair| !pair.is_empty()) {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        if query
            .insert(decode(key)?, decode(&value.replace('+', " "))?)
            .is_some()
        {
            return Err(Rejected::bad("duplicate query option"));
        }
    }
    let mut body = Vec::new();
    let archive = if spooled {
        use std::io::Seek;
        if (chunked && size.is_some()) || (!chunked && size.unwrap_or(0) == 0) {
            return Err(Rejected::bad("invalid Docker archive framing"));
        }
        let root = archive_root
            .ok_or_else(|| Rejected(501, "native archive scratch is not configured".into()))?;
        let mut spool = tempfile::tempfile_in(root)
            .map_err(|_| Rejected::internal("cannot spool Docker archive"))?;
        if expect {
            reader
                .get_ref()
                .write_all(b"HTTP/1.1 100 Continue\r\n\r\n")
                .map_err(|_| Rejected::bad("Docker archive client disconnected"))?;
        }
        let deadline = Instant::now() + ARCHIVE_READ_TIMEOUT;
        if chunked {
            copy_chunks(reader, &mut spool, deadline, body_limit)?;
        } else {
            copy_body(reader, &mut spool, size.unwrap_or(0), deadline)?;
        }
        spool
            .rewind()
            .map_err(|_| Rejected::internal("cannot rewind Docker archive"))?;
        Some(spool)
    } else {
        let count = size.unwrap_or(0);
        body.reserve_exact(count);
        copy_body(reader, &mut body, count, deadline)?;
        None
    };
    Ok(Some(Request {
        method: method.into(),
        path: path.into(),
        query,
        body,
        archive,
        close,
        tcp_upgrade: connection_upgrade && tcp_upgrade,
    }))
}

fn header(writer: &mut UnixStream, status: u16, lines: &str) -> io::Result<()> {
    let reason = match status {
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        304 => "Not Modified",
        400 => "Bad Request",
        404 => "Not Found",
        408 => "Request Timeout",
        409 => "Conflict",
        413 => "Content Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        _ => "Error",
    };
    write!(
        writer,
        "HTTP/1.1 {status} {reason}\r\nAPI-Version: 1.44\r\nOstype: linux\r\n{lines}\r\n"
    )
}

struct Reply {
    status: u16,
    content_type: &'static str,
    data: Vec<u8>,
    attributed: bool,
}

impl Reply {
    fn empty(status: u16) -> Self {
        Self {
            status,
            content_type: "",
            data: Vec::new(),
            attributed: false,
        }
    }

    fn json(status: u16, data: Value) -> Self {
        Self {
            status,
            content_type: "application/json",
            data: data.to_string().into_bytes(),
            attributed: false,
        }
    }

    fn send(self, writer: &mut UnixStream, head: bool, close: bool) -> io::Result<()> {
        let mut lines = format!("Content-Length: {}\r\n", self.data.len());
        if close {
            lines.push_str("Connection: close\r\n");
        }
        if !self.content_type.is_empty() {
            lines.push_str(&format!("Content-Type: {}\r\n", self.content_type));
        }
        if self.attributed {
            lines.push_str(&format!("X-Conjet-Backend: {BACKEND}\r\n"));
        }
        header(writer, self.status, &lines)?;
        if !head {
            writer.write_all(&self.data)?;
        }
        Ok(())
    }
}

enum Action {
    Reply(Reply),
    Archive(File),
    WorkloadArchive(String, Option<File>),
    Wait(Arc<Item>, String, u64),
    Attach(Arc<Item>, [bool; 2], u64, bool),
    Logs(Arc<Item>, [bool; 2], u64, bool, Option<usize>),
    Exec(Arc<super::exec::Entry>, Value),
    Events(super::events::Subscription),
}

fn stop_grace(query: &BTreeMap<String, String>) -> Result<u64> {
    query.get("t").map_or(Ok(10), |value| {
        value
            .parse::<u64>()
            .ok()
            .filter(|seconds| *seconds <= 30)
            .ok_or_else(|| Rejected::bad("stop timeout must be between 0 and 30 seconds"))
    })
}

fn disabled(value: Option<&String>) -> bool {
    value.map_or(true, |value| matches!(value.as_str(), "0" | "false"))
}

fn dispatch(owner: &Arc<Owner>, request: &Request) -> Result<Action> {
    let method = request.method.as_str();
    let query = &request.query;
    let mut path = request.path.as_str();
    if let Some((version, rest)) = path[1..].split_once('/') {
        if version.starts_with('v')
            && version[1..]
                .bytes()
                .all(|byte| byte == b'.' || byte.is_ascii_digit())
        {
            if version != "v1.44" {
                return Err(Rejected::bad(
                    "this native endpoint supports Docker API 1.44",
                ));
            }
            path = &path[path.len() - rest.len() - 1..];
        }
    }
    let reply = match (method, path) {
        ("HEAD" | "GET", "/_ping") => {
            let mut reply = Reply::empty(200);
            if method == "GET" {
                reply.data.extend_from_slice(b"OK");
            }
            reply
        }
        ("GET", "/version") => Reply::json(
            200,
            json!({
                "Version":"0.1.0","ApiVersion":"1.44","MinAPIVersion":"1.44",
                "Os":"linux","Arch":"arm64","Platform":{"Name":PLATFORM},
                "ConjetContainerCapacity":super::CONTAINERS,
            }),
        ),
        ("GET", "/info") if query.is_empty() => Reply::json(
            200,
            json!({
                "SystemTime":super::events::daemon_time()?,
                "OSType":"linux","Architecture":"aarch64","NCPU":2,"MemTotal":2147483648u64,
            }),
        ),
        ("POST", "/containers/create") => {
            if query
                .keys()
                .any(|key| !matches!(key.as_str(), "name" | "platform"))
                || query
                    .get("platform")
                    .is_some_and(|value| value != "linux/arm64")
            {
                return Err(Rejected::bad(
                    "only the Linux ARM64 create query is supported",
                ));
            }
            let config = serde_json::from_slice(&request.body)
                .map_err(|_| Rejected::bad("invalid Docker request object"))?;
            let item = owner.create(query.get("name").map(String::as_str), config)?;
            Reply::json(201, json!({"Id":item.container.id,"Warnings":[]}))
        }
        ("GET", "/containers/json")
            if query
                .keys()
                .all(|key| matches!(key.as_str(), "filters" | "all")) =>
        {
            let all = match query.get("all").map(String::as_str) {
                None | Some("false" | "0") => false,
                Some("true" | "1") => true,
                _ => return Err(Rejected::bad("invalid Docker container discovery scope")),
            };
            let filters = super::discovery::Filters::parse(query.get("filters"))?;
            Reply::json(200, owner.list_containers(&filters, all))
        }
        ("GET", "/events") if query.is_empty() => {
            let ledger = owner.ledger.lock().unwrap();
            let mut reply = Reply::empty(200);
            reply.content_type = "application/json";
            for event in &ledger.events {
                reply.data.extend_from_slice(event.to_string().as_bytes());
                reply.data.push(b'\n');
            }
            reply
        }
        ("GET", "/events") => {
            return Ok(Action::Events(super::events::Subscription::parse(query)?))
        }
        ("GET", "/networks") if query.keys().all(|key| key == "filters") => {
            let filters = super::discovery::Filters::parse(query.get("filters"))?;
            Reply::json(200, owner.list_networks(&filters))
        }
        ("POST", "/networks/create") if query.is_empty() => {
            let body = serde_json::from_slice(&request.body)
                .map_err(|_| Rejected::bad("invalid Docker network request"))?;
            Reply::json(201, owner.create_network(body)?)
        }
        ("GET", "/volumes") if query.keys().all(|key| key == "filters") => {
            let filters = super::discovery::Filters::parse(query.get("filters"))?;
            Reply::json(200, super::volume::list(owner, &filters)?)
        }
        ("POST", "/volumes/create") if query.is_empty() => {
            let body = serde_json::from_slice(&request.body)
                .map_err(|_| Rejected::bad("invalid Docker volume request"))?;
            Reply::json(201, super::volume::create(owner, &body)?)
        }
        (_, _) if path.starts_with("/volumes/") => {
            let name = decode(&path["/volumes/".len()..])?;
            match method {
                "GET" if query.is_empty() => {
                    Reply::json(200, super::volume::inspect(owner, &name)?)
                }
                "DELETE" if query.keys().all(|key| key == "force") => {
                    let force = match query.get("force").map(String::as_str) {
                        Some("true" | "1") => true,
                        Some("false" | "0") | None => false,
                        _ => return Err(Rejected::bad("invalid volume removal force option")),
                    };
                    match owner.remove_volume(&name) {
                        Ok(()) => {}
                        Err(Rejected(404, _)) if force => {}
                        Err(error) => return Err(error),
                    }
                    Reply::empty(204)
                }
                _ => return Err(Rejected::bad("unsupported Docker volume operation")),
            }
        }
        (_, _) if path.starts_with("/networks/") => {
            let route = &path["/networks/".len()..];
            let (reference, operation) = route.split_once('/').unwrap_or((route, ""));
            let reference = decode(reference)?;
            if !super::request::name(&reference) {
                return Err(Rejected::bad("invalid Docker network identifier"));
            }
            match (method, operation) {
                ("GET", "")
                    if query.iter().all(|(name, value)| {
                        (name == "verbose" && disabled(Some(value)))
                            || (name == "scope" && value.is_empty())
                    }) =>
                {
                    Reply::json(200, owner.inspect_network(&reference)?)
                }
                ("DELETE", "") if query.is_empty() => {
                    owner.remove_network(&reference)?;
                    Reply::empty(204)
                }
                ("POST", "connect" | "disconnect") if query.is_empty() => {
                    let body = serde_json::from_slice(&request.body)
                        .map_err(|_| Rejected::bad("invalid Docker network change body"))?;
                    super::network::change(owner, &reference, &body, operation == "connect")?;
                    Reply::empty(200)
                }
                _ => return Err(Rejected::bad("unsupported Docker network request")),
            }
        }
        ("POST", "/images/load") => {
            if query.keys().any(|key| key != "quiet")
                || query
                    .get("quiet")
                    .is_some_and(|value| !matches!(value.as_str(), "0" | "1" | "true" | "false"))
            {
                return Err(Rejected::bad("unsupported image load option"));
            }
            let archive = request
                .archive
                .as_ref()
                .ok_or_else(|| Rejected::bad("missing Docker archive upload"))?;
            Reply {
                status: 200,
                content_type: "application/json",
                data: owner.load_archive(archive)?,
                attributed: false,
            }
        }
        ("GET", "/images/get") => {
            if query.len() != 1 || !request.body.is_empty() {
                return Err(Rejected::bad("image save requires one image"));
            }
            let name = query
                .get("names")
                .or_else(|| query.get("names[]"))
                .filter(|name| !name.is_empty())
                .ok_or_else(|| Rejected::bad("missing Docker image name"))?;
            return Ok(Action::Archive(owner.save_archive(name)?));
        }
        ("GET", _) if path.starts_with("/images/") && path.ends_with("/get") => {
            if !query.is_empty() || !request.body.is_empty() {
                return Err(Rejected::bad("unsupported image save option"));
            }
            return Ok(Action::Archive(
                owner.save_archive(&image_reference(path, "/get")?)?,
            ));
        }
        ("GET", "/images/json") => {
            if query
                .keys()
                .any(|key| !matches!(key.as_str(), "filters" | "all" | "digests"))
            {
                return Err(Rejected::bad("unsupported image list option"));
            }
            let filters = super::discovery::parse_filters(query.get("filters"))?;
            if filters.is_empty() {
                return Ok(Action::Reply(Reply::json(200, owner.list_images()?)));
            }
            let reference = filters
                .get("reference")
                .filter(|names| filters.len() == 1 && names.len() == 1)
                .map(|names| names[0].as_str())
                .filter(|name| !name.contains(['*', '?', '[', ']', '\\']))
                .ok_or_else(|| Rejected::bad("image listing requires one exact reference"))?;
            let images = match owner.inspect_image(reference) {
                Ok(mut image) => {
                    let tag = super::image::Tags::key(reference);
                    image["RepoTags"]
                        .as_array_mut()
                        .expect("image tag inventory")
                        .retain(|name| name.as_str() == Some(tag.as_ref()));
                    image["RepoDigests"]
                        .as_array_mut()
                        .expect("image digest inventory")
                        .retain(|name| name.as_str() == Some(reference));
                    vec![image]
                }
                Err(Rejected(404, _)) => Vec::new(),
                Err(error) => return Err(error),
            };
            Reply::json(200, json!(images))
        }
        ("GET", _) if path.starts_with("/images/") && path.ends_with("/json") => {
            let reference = image_reference(path, "/json")?;
            Reply::json(200, owner.inspect_image(&reference)?)
        }
        ("POST", _) if path.starts_with("/images/") && path.ends_with("/tag") => {
            let reference = image_reference(path, "/tag")?;
            if query
                .keys()
                .any(|key| !matches!(key.as_str(), "repo" | "tag"))
                || !request.body.is_empty()
            {
                return Err(Rejected::bad("invalid Docker tag request"));
            }
            let repository = query
                .get("repo")
                .ok_or_else(|| Rejected::bad("missing Docker tag repository"))?;
            owner.tag_image(
                &reference,
                repository,
                query.get("tag").map_or("", String::as_str),
            )?;
            Reply::empty(201)
        }
        ("POST", "/images/create") => {
            if query
                .keys()
                .any(|key| !matches!(key.as_str(), "fromImage" | "tag" | "platform"))
                || query
                    .get("platform")
                    .is_some_and(|value| value != "linux/arm64")
                || !request.body.is_empty()
            {
                return Err(Rejected::bad(
                    "only pinned Linux ARM64 registry pulls are supported",
                ));
            }
            let from = query
                .get("fromImage")
                .ok_or_else(|| Rejected::bad("missing registry image reference"))?;
            let reference = query
                .get("tag")
                .filter(|value| !value.is_empty())
                .map_or_else(|| from.to_owned(), |tag| format!("{from}@{tag}"));
            let mut reply = Reply::json(200, owner.pull_image(&reference)?);
            reply.data.push(b'\n');
            reply
        }
        ("DELETE", _) if path.starts_with("/images/") => {
            if query
                .keys()
                .any(|key| !matches!(key.as_str(), "force" | "noprune"))
                || !disabled(query.get("force"))
            {
                return Err(Rejected::bad("forced image removal is unsupported"));
            }
            Reply::json(
                200,
                owner.remove_image(&decode(&path["/images/".len()..])?)?,
            )
        }
        (_, _) if path.starts_with("/exec/") => {
            let (id, operation) = path["/exec/".len()..]
                .split_once('/')
                .ok_or_else(|| Rejected::bad("invalid native exec route"))?;
            if !super::request::name(id) || !query.is_empty() {
                return Err(Rejected::bad("invalid native exec identifier or query"));
            }
            let entry = owner.lookup_exec(id)?;
            match (method, operation) {
                ("POST", "start") => {
                    if entry.stdin() && !request.tcp_upgrade {
                        return Err(Rejected::bad("exec stdin requires a TCP upgrade"));
                    }
                    let handle = entry.reserve(&request.body)?;
                    return Ok(Action::Exec(entry, handle));
                }
                ("GET", "json") => Reply::json(200, entry.inspect()),
                _ => return Err(Rejected(501, "unsupported native exec operation".into())),
            }
        }
        _ => return container(owner, path, request),
    };
    Ok(Action::Reply(reply))
}

fn container(owner: &Arc<Owner>, path: &str, request: &Request) -> Result<Action> {
    let method = request.method.as_str();
    let query = &request.query;
    let body = request.body.as_slice();
    let route = path
        .strip_prefix("/containers/")
        .ok_or_else(|| Rejected(501, "unsupported Docker API operation".into()))?;
    let (id, action) = route.split_once('/').unwrap_or((route, ""));
    if !super::request::name(id) {
        return Err(Rejected::bad("invalid Docker container identifier"));
    }
    let item = owner.lookup(id)?;
    let allowed_query: &[&str] = match (method, action) {
        ("HEAD" | "GET", "archive") => &["path"],
        ("PUT", "archive") => &["path", "noOverwriteDirNonDir", "copyUIDGID"],
        ("POST", "attach") => &["stdin", "stdout", "stderr", "logs", "stream"],
        ("GET", "logs") => &[
            "stdout",
            "stderr",
            "follow",
            "tail",
            "since",
            "until",
            "timestamps",
            "details",
        ],
        ("POST", "wait") => &["condition"],
        ("POST", "stop" | "restart") => &["t", "signal"],
        ("POST", "kill") => &["signal"],
        ("POST", "rename") => &["name"],
        ("GET", "stats") => &["stream", "one-shot"],
        ("DELETE", "") => &["force", "v", "link"],
        _ => &[],
    };
    if query
        .keys()
        .any(|key| !allowed_query.contains(&key.as_str()))
    {
        return Err(Rejected::bad("unsupported Docker container query"));
    }
    let mut reply = match (method, action) {
        ("HEAD" | "GET", "archive") => {
            if !body.is_empty() {
                return Err(Rejected::bad("unexpected Docker archive request body"));
            }
            let path = query
                .get("path")
                .ok_or_else(|| Rejected::bad("missing workload archive path"))?;
            let (stat, archive) = owner.workload_archive(&item, path, method == "HEAD")?;
            return Ok(Action::WorkloadArchive(stat, archive));
        }
        ("PUT", "archive") => {
            if query
                .get("copyUIDGID")
                .is_some_and(|value| !matches!(value.as_str(), "0" | "false"))
                || query
                    .get("noOverwriteDirNonDir")
                    .is_some_and(|value| !matches!(value.as_str(), "0" | "false" | "1" | "true"))
            {
                return Err(Rejected::bad(
                    "unsupported workload archive ownership or overwrite option",
                ));
            }
            let path = query
                .get("path")
                .ok_or_else(|| Rejected::bad("missing workload archive path"))?;
            let archive = request
                .archive
                .as_ref()
                .ok_or_else(|| Rejected::bad("missing workload archive body"))?;
            owner.workload_upload(&item, path, archive)?;
            Reply::empty(200)
        }
        ("POST", "exec") => {
            let data = serde_json::from_slice(body)
                .map_err(|_| Rejected::bad("invalid Docker exec body"))?;
            Reply::json(201, owner.create_exec(item, data)?)
        }
        ("POST", "start") => {
            owner.start(&item)?;
            let mut reply = Reply::empty(204);
            reply.attributed = true;
            reply
        }
        ("POST", "rename") => {
            let name = query
                .get("name")
                .filter(|name| super::request::name(name))
                .ok_or_else(|| Rejected::bad("invalid Docker container name"))?;
            owner.rename(&item, name)?;
            Reply::empty(204)
        }
        ("GET", "stats") => {
            if query.get("stream").is_none() || !disabled(query.get("stream")) {
                return Err(Rejected::bad("native stats require stream=false"));
            }
            Reply::json(200, owner.stats(&item, !disabled(query.get("one-shot")))?)
        }
        ("POST", "stop" | "restart") => {
            if query
                .get("signal")
                .is_some_and(|value| !matches!(value.as_str(), "SIGTERM" | "TERM" | "15"))
            {
                return Err(Rejected::bad("stop and restart support SIGTERM"));
            }
            let grace = stop_grace(query)?;
            if action == "restart" {
                owner.restart(&item, grace)?;
                Reply::empty(204)
            } else {
                Reply::empty(if owner.stop(&item, super::TERM, grace)? {
                    204
                } else {
                    304
                })
            }
        }
        ("POST", "kill") => {
            if query
                .get("signal")
                .is_some_and(|value| !matches!(value.as_str(), "SIGKILL" | "KILL" | "9"))
            {
                return Err(Rejected::bad("kill supports SIGKILL"));
            }
            if !owner.stop(&item, super::KILL, 0)? {
                return Err(Rejected(409, "container is not running".into()));
            }
            Reply::empty(204)
        }
        ("POST", "wait") => {
            let condition = query.get("condition").map_or("not-running", String::as_str);
            if !matches!(condition, "next-exit" | "not-running" | "removed") {
                return Err(Rejected::bad("unsupported wait condition"));
            }
            let generation = item.state().generation;
            return Ok(Action::Wait(item, condition.to_owned(), generation));
        }
        ("POST", "attach") => {
            let stdin = !disabled(query.get("stdin"));
            if !disabled(query.get("logs")) {
                return Err(Rejected::bad("attachment replay is unsupported"));
            }
            if stdin && (item.container.config["OpenStdin"] != true || !request.tcp_upgrade) {
                return Err(Rejected::bad(
                    "attached stdin requires an open workload input and TCP upgrade",
                ));
            }
            let streams = ["stdout", "stderr"]
                .map(|name| query.get(name).is_none() || !disabled(query.get(name)));
            let generation = item.state().generation;
            return Ok(Action::Attach(item, streams, generation, stdin));
        }
        ("GET", "logs") => {
            if !disabled(query.get("timestamps"))
                || !disabled(query.get("details"))
                || ["since", "until"]
                    .iter()
                    .any(|key| query.get(*key).is_some_and(|value| value != "0"))
            {
                return Err(Rejected::bad(
                    "log time, duration and formatting filters are unsupported",
                ));
            }
            let tail = query
                .get("tail")
                .filter(|value| value.as_str() != "all")
                .map(|value| {
                    value
                        .parse::<usize>()
                        .map_err(|_| Rejected::bad("invalid log tail count"))
                })
                .transpose()?;
            let enabled = ["stdout", "stderr"]
                .map(|name| query.get(name).is_none() || !disabled(query.get(name)));
            let follow = !disabled(query.get("follow"));
            let generation = item.state().generation;
            return Ok(Action::Logs(item, enabled, generation, follow, tail));
        }
        ("GET", "json") => {
            let state = item.state();
            if state.removed {
                return Err(Rejected(404, "container was removed".into()));
            }
            let status = state.status();
            let code = state.terminal.as_ref().map_or_else(
                || if state.error.is_some() { 125 } else { 0 },
                |terminal| terminal.code,
            );
            let container = &item.container;
            let mut config = container.config.clone();
            let mut host = container.config["HostConfig"].clone();
            config["Tty"] = json!(false);
            let networks = state.network.as_ref().map_or_else(|| json!({}), |attachment| {
                json!({(attachment.network.name.as_str()):attachment.inspect(state.network_address.as_deref())})
            });
            host["NetworkMode"] = json!(state
                .network
                .as_ref()
                .map_or("none", |attachment| attachment.network.name.as_str()));
            let specs = container.spec["argv"].as_array().expect("validated args");
            let mut lifecycle = json!({
                "Status":status,"Running":status=="running","ExitCode":code,
                "OOMKilled":state.terminal.as_ref().is_some_and(|terminal|
                    terminal.witness["exit"]["oom_killed"] == true),
                "Error":state.error.as_deref().unwrap_or("")
            });
            if let Some(health) = &state.health {
                lifecycle["Health"] = health.inspect();
            }
            let mut reply = Reply::json(
                200,
                json!({
                    "Id":container.id,"Name":format!("/{}",container.name().as_str()),"Image":container.spec["image_digest"],
                    "Driver":BACKEND,"Platform":"linux","Path":specs[0],"Args":specs[1..],
                    "Mounts":container.mounts(),
                    "RestartCount":state.generation,
                    "State":lifecycle,
                    "Config":config,"HostConfig":host,"NetworkSettings":{
                        "Networks":networks, "Ports":item.port_metadata(state.network_address.is_some())
                    },
                }),
            );
            reply.attributed = true;
            reply
        }
        ("DELETE", "") => {
            if !disabled(query.get("link"))
                || query
                    .get("v")
                    .is_some_and(|value| !matches!(value.as_str(), "0" | "1" | "false" | "true"))
            {
                return Err(Rejected::bad("unsupported container removal options"));
            }
            // Docker's v flag removes anonymous volumes. Native mounts are
            // explicitly named and released through their own endpoint.
            owner.remove(
                &item,
                query
                    .get("force")
                    .is_some_and(|value| matches!(value.as_str(), "1" | "true")),
            )?;
            Reply::empty(204)
        }
        _ => return Err(Rejected(501, "unsupported container operation".into())),
    };
    if method == "HEAD" {
        reply.data.clear();
    }
    Ok(Action::Reply(reply))
}

fn wait(item: &Item, condition: &str, generation: u64, writer: &mut UnixStream) -> io::Result<()> {
    header(
        writer,
        200,
        "Content-Type: application/json\r\nConnection: close\r\n",
    )?;
    let outcome = item
        .wait_for(
            |state| {
                state.error.is_some()
                    || match condition {
                        "removed" => state.removed,
                        "not-running" if !state.started => true,
                        _ => state.generation != generation || state.terminal.is_some(),
                    }
            },
            35,
        )
        .and_then(|state| {
            let selected = if condition == "removed" {
                state.generation
            } else {
                generation
            };
            if let Some(error) = state
                .error
                .as_ref()
                .filter(|_| selected == state.generation)
            {
                return Err(Rejected::internal(error));
            }
            match state.terminal_for(selected) {
                Some(terminal) if terminal.delivery_error.is_some() => Err(Rejected::internal(
                    terminal.delivery_error.as_ref().unwrap(),
                )),
                Some(terminal) => Ok(terminal.code),
                None if selected != state.generation => {
                    Err(Rejected::internal("container execution history expired"))
                }
                None => Ok(0),
            }
        });
    let reply = match outcome {
        Ok(code) => json!({"StatusCode":code,"Error":null}),
        Err(Rejected(_, message)) => json!({"StatusCode":125,"Error":{"Message":message}}),
    };
    writer.write_all(reply.to_string().as_bytes())
}

fn attach(
    item: &Item,
    enabled: [bool; 2],
    generation: u64,
    writer: &mut UnixStream,
) -> io::Result<()> {
    header(writer, 101, "Connection: Upgrade\r\nUpgrade: tcp\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\n")?;
    send_output(item, enabled, generation, true, None, writer)
}

fn tail_offsets(streams: [&[u8]; 2], enabled: [bool; 2], mut lines: usize) -> [usize; 2] {
    let mut offsets = [0; 2];
    for index in (0..2).rev().filter(|index| enabled[*index]) {
        let data = streams[index];
        if lines == 0 || data.is_empty() {
            offsets[index] = data.len();
            continue;
        }
        // Ignore only the terminating delimiter. Empty lines still count.
        let content = data.strip_suffix(b"\n").unwrap_or(data);
        let mut starts = content
            .iter()
            .enumerate()
            .rev()
            .filter_map(|(position, &byte)| (byte == b'\n').then_some(position + 1));
        offsets[index] = loop {
            lines -= 1;
            match starts.next() {
                Some(offset) if lines == 0 => break offset,
                Some(_) => {}
                None => break 0,
            }
        };
    }
    offsets
}

fn send_output(
    item: &Item,
    enabled: [bool; 2],
    generation: u64,
    follow: bool,
    mut tail: Option<usize>,
    writer: &mut UnixStream,
) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(35);
    let mut cursors = [0; 2];
    loop {
        let mut state = item.state();
        let (frames, finished, failure) = loop {
            let terminal = state.terminal_for(generation);
            let same_generation = state.generation == generation;
            let streams = match terminal {
                Some(terminal) => [&terminal.stdout[..], &terminal.stderr[..]],
                _ if same_generation => [&state.live[0][..], &state.live[1][..]],
                _ => [&[][..], &[][..]],
            };
            if let Some(lines) = tail.take() {
                cursors = tail_offsets(streams, enabled, lines);
            }
            let complete =
                !same_generation || terminal.is_some() || state.removed || state.error.is_some();
            let chunks: [Vec<u8>; 2] = std::array::from_fn(|index| {
                if !enabled[index] {
                    return Vec::new();
                }
                let begin = cursors[index].min(streams[index].len());
                let end = if follow {
                    (begin + super::CHUNK).min(streams[index].len())
                } else {
                    streams[index].len()
                };
                streams[index][begin..end].to_vec()
            });
            if chunks.iter().any(|chunk| !chunk.is_empty()) || complete || !follow {
                let failure = terminal
                    .and_then(|terminal| terminal.delivery_error.clone())
                    .or_else(|| same_generation.then(|| state.error.clone()).flatten());
                break (chunks, complete, failure);
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() || client_disconnected(writer) {
                return Ok(());
            }
            let (next, _) = item
                .changed
                .wait_timeout(state, remaining.min(Duration::from_millis(200)))
                .unwrap();
            state = next;
        };
        drop(state);
        let empty = frames.iter().all(Vec::is_empty);
        for (index, chunk) in frames.into_iter().enumerate() {
            if chunk.is_empty() {
                continue;
            }
            send_frame(writer, index as u8 + 1, &chunk)?;
            cursors[index] += chunk.len();
        }
        if !follow || (empty && finished) {
            if let Some(error) = failure {
                send_frame(writer, 3, error.as_bytes())?;
            }
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "output subscriber deadline elapsed",
            ));
        }
    }
}

pub(super) fn client_disconnected(stream: &UnixStream) -> bool {
    // Darwin does not return a hangup if no events were requested. A
    // read poll also sees a peer's write half-close as a hangup, which
    // is valid for a client that is still receiving streamed output.
    let mut socket = libc::pollfd {
        fd: stream.as_raw_fd(),
        events: libc::POLLOUT,
        revents: 0,
    };
    let ready = unsafe { libc::poll(&mut socket, 1, 0) };
    ready > 0 && socket.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
}

fn send_frame(writer: &mut UnixStream, kind: u8, data: &[u8]) -> io::Result<()> {
    let mut frame = [0; 8];
    frame[0] = kind;
    frame[4..].copy_from_slice(&(data.len() as u32).to_be_bytes());
    writer.write_all(&frame)?;
    writer.write_all(data)
}

fn await_request(reader: &BufReader<UnixStream>) -> io::Result<bool> {
    if !reader.buffer().is_empty() {
        return Ok(true);
    }
    let began = Instant::now();
    let mut poll = libc::pollfd {
        fd: reader.get_ref().as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    while began.elapsed() < IDLE_TIMEOUT && !super::STOP.load(std::sync::atomic::Ordering::Acquire)
    {
        match unsafe { libc::poll(&mut poll, 1, 200) } {
            0 => {}
            result if result > 0 => return Ok(true),
            _ => {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }
    }
    Ok(false)
}

pub(super) fn serve(
    mut stream: UnixStream,
    owner: &Arc<Owner>,
    trace_requests: bool,
) -> io::Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    while await_request(&reader)? {
        let request = match parse(&mut reader, owner.archive_root.as_deref()) {
            Ok(Some(request)) => request,
            Ok(None) => break,
            Err(Rejected(status, message)) => {
                Reply::json(status, json!({"message":message})).send(&mut stream, false, true)?;
                break;
            }
        };
        let close = request.close || super::STOP.load(std::sync::atomic::Ordering::Acquire);
        if trace_requests {
            eprintln!(
                "{}",
                json!({
                    "method": request.method, "path": request.path,
                    "query_keys": request.query.keys().collect::<Vec<_>>(),
                })
            );
        }
        match dispatch(owner, &request) {
            Ok(Action::Reply(reply)) => reply.send(&mut stream, request.method == "HEAD", close)?,
            Ok(Action::Archive(mut spool)) => {
                header(&mut stream, 200, &format!(
                    "Content-Type: application/x-tar\r\nContent-Length: {}\r\nConnection: close\r\n",
                    spool.metadata()?.len()
                ))?;
                io::copy(&mut spool, &mut stream)?;
                break;
            }
            Ok(Action::WorkloadArchive(stat, mut spool)) => {
                let bytes = spool
                    .as_ref()
                    .map(File::metadata)
                    .transpose()?
                    .map_or(0, |info| info.len());
                header(&mut stream, 200, &format!(
                    "Content-Type: application/x-tar\r\nContent-Length: {bytes}\r\nX-Docker-Container-Path-Stat: {stat}\r\nConnection: close\r\n"
                ))?;
                if let Some(spool) = &mut spool {
                    io::copy(spool, &mut stream)?;
                }
                break;
            }
            Err(Rejected(status, message)) => Reply::json(status, json!({"message":message}))
                .send(&mut stream, request.method == "HEAD", close)?,
            Ok(Action::Wait(item, condition, generation)) => {
                wait(&item, &condition, generation, &mut stream)?;
                break;
            }
            Ok(Action::Attach(item, streams, generation, stdin)) => {
                if stdin {
                    let Ok(_input) = item.input_attachment.try_lock() else {
                        Reply::json(
                            409,
                            json!({"message":"native workload input already has an attachment"}),
                        )
                        .send(&mut stream, false, true)?;
                        break;
                    };
                    std::thread::scope(|tasks| -> io::Result<()> {
                        let input = tasks.spawn(|| {
                            super::workload_input::relay(owner, &item, generation, reader)
                        });
                        let output = attach(&item, streams, generation, &mut stream);
                        let _ = stream.shutdown(Shutdown::Read);
                        let sent = input
                            .join()
                            .map_err(|_| io::Error::other("native input worker stopped"))?;
                        output?;
                        if let Err(error) = sent {
                            send_frame(&mut stream, 3, error.to_string().as_bytes())?;
                        }
                        Ok(())
                    })?;
                } else {
                    attach(&item, streams, generation, &mut stream)?;
                }
                break;
            }
            Ok(Action::Logs(item, streams, generation, follow, tail)) => {
                header(&mut stream, 200, "Connection: close\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\n")?;
                send_output(&item, streams, generation, follow, tail, &mut stream)?;
                break;
            }
            Ok(Action::Events(subscription)) => {
                header(
                    &mut stream,
                    200,
                    "Connection: close\r\nContent-Type: application/json\r\n",
                )?;
                subscription.stream(owner, &mut stream)?;
                break;
            }
            Ok(Action::Exec(entry, handle)) => {
                if entry.streaming() {
                    let sent = header(&mut stream, 101, "Connection: Upgrade\r\nUpgrade: tcp\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\n");
                    if let Err(error) = sent {
                        entry.fail("native exec client disconnected before start".into());
                        return Err(error);
                    }
                    if let Err(error) = entry.run_stream(owner, &handle, &mut reader, &mut stream) {
                        send_frame(&mut stream, 3, error.to_string().as_bytes())?;
                    }
                    break;
                }
                let completed = (!entry.stdin()).then(|| entry.run(owner, handle.clone(), None));
                let (status, connection) = if request.tcp_upgrade {
                    (101, "Connection: Upgrade\r\nUpgrade: tcp\r\n")
                } else {
                    (200, "Connection: close\r\n")
                };
                let stream_type = if entry.tty() { "raw" } else { "multiplexed" };
                let sent = header(
                    &mut stream,
                    status,
                    &format!(
                        "{connection}Content-Type: application/vnd.docker.{stream_type}-stream\r\n"
                    ),
                );
                if let Err(error) = sent {
                    if completed.is_none() {
                        entry.fail("native exec client disconnected before start".into());
                    }
                    return Err(error);
                }
                let result = completed.unwrap_or_else(|| match read_exec_stdin(&mut reader) {
                    Ok(input) => entry.run(owner, handle, Some(&input)),
                    Err(error) => entry.fail(error.to_string()),
                });
                if entry.tty() {
                    stream.write_all(&result.output[0])?;
                    if let Some(error) = result.error {
                        stream.write_all(error.as_bytes())?;
                    }
                } else {
                    for (index, data) in result.output.into_iter().enumerate() {
                        if !data.is_empty() {
                            send_frame(&mut stream, index as u8 + 1, &data)?;
                        }
                    }
                    if let Some(error) = result.error {
                        send_frame(&mut stream, 3, error.as_bytes())?;
                    }
                }
                break;
            }
        }
        if close {
            break;
        }
    }
    stream.shutdown(Shutdown::Write)
}

use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use super::{Item, Owner, Rejected, BACKEND, PLATFORM};

const MAX_HEADERS: usize = 16384;
const MAX_BODY: usize = 16384;
const READ_TIMEOUT: Duration = Duration::from_secs(3);
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const IDLE_TIMEOUT: Duration = Duration::from_secs(38);

struct Request {
    method: String,
    path: String,
    query: BTreeMap<String, String>,
    body: Vec<u8>,
    close: bool,
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

fn parse(reader: &mut BufReader<UnixStream>) -> Result<Option<Request>> {
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
    let mut size = None;
    let mut close = false;
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
        if ["transfer-encoding", "expect"]
            .iter()
            .any(|name| key.eq_ignore_ascii_case(name))
        {
            return Err(Rejected::bad("unsupported Docker request body framing"));
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
                .filter(|bytes| *bytes <= MAX_BODY);
            if size.is_none() {
                return Err(Rejected::bad("Docker request body exceeds its bound"));
            }
        }
        if key.eq_ignore_ascii_case("connection") {
            close |= value
                .split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("close"));
        }
    }
    let mut body = vec![0; size.unwrap_or(0)];
    let mut offset = 0;
    while offset < body.len() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Rejected(408, "Docker request deadline elapsed".into()));
        }
        reader
            .get_ref()
            .set_read_timeout(Some(remaining))
            .map_err(|_| Rejected::internal("cannot set read deadline"))?;
        let count = reader
            .read(&mut body[offset..])
            .map_err(|_| Rejected::bad("incomplete Docker request body"))?;
        if count == 0 {
            return Err(Rejected::bad("incomplete Docker request body"));
        }
        offset += count;
    }
    let (path, raw_query) = target.split_once('?').unwrap_or((target, ""));
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
    Ok(Some(Request {
        method: method.into(),
        path: path.into(),
        query,
        body,
        close,
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
    Wait(Arc<Item>, String, u64),
    Attach(Arc<Item>, [bool; 2], u64),
    Logs(Arc<Item>, [bool; 2], u64, bool),
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
        ("GET", _) if path.starts_with("/images/") && path.ends_with("/json") => {
            let reference = decode(&path["/images/".len()..path.len() - "/json".len()])?;
            Reply::json(200, owner.inspect_image(&reference)?)
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
        _ => return container(owner, method, path, query),
    };
    Ok(Action::Reply(reply))
}

fn container(
    owner: &Arc<Owner>,
    method: &str,
    path: &str,
    query: &BTreeMap<String, String>,
) -> Result<Action> {
    let route = path
        .strip_prefix("/containers/")
        .ok_or_else(|| Rejected(501, "unsupported Docker API operation".into()))?;
    let (id, action) = route.split_once('/').unwrap_or((route, ""));
    if !super::request::name(id) {
        return Err(Rejected::bad("invalid Docker container identifier"));
    }
    let item = owner.lookup(id)?;
    let allowed_query: &[&str] = match (method, action) {
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
        ("POST", "start") => {
            owner.start(&item)?;
            let mut reply = Reply::empty(204);
            reply.attributed = true;
            reply
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
            if !disabled(query.get("stdin")) || !disabled(query.get("logs")) {
                return Err(Rejected::bad("stdin and attachment replay are unsupported"));
            }
            let streams = ["stdout", "stderr"]
                .map(|name| query.get(name).is_none() || !disabled(query.get(name)));
            let generation = item.state().generation;
            return Ok(Action::Attach(item, streams, generation));
        }
        ("GET", "logs") => {
            if !disabled(query.get("timestamps"))
                || !disabled(query.get("details"))
                || query.get("tail").is_some_and(|value| value != "all")
                || ["since", "until"]
                    .iter()
                    .any(|key| query.get(*key).is_some_and(|value| value != "0"))
            {
                return Err(Rejected::bad(
                    "log time, duration, formatting and tail filters are unsupported",
                ));
            }
            let enabled = ["stdout", "stderr"]
                .map(|name| query.get(name).is_none() || !disabled(query.get(name)));
            let follow = !disabled(query.get("follow"));
            let generation = item.state().generation;
            return Ok(Action::Logs(item, enabled, generation, follow));
        }
        ("GET", "json") => {
            let state = item.state();
            if state.removed {
                return Err(Rejected(404, "container was removed".into()));
            }
            let status = if state.terminal.is_some() || state.error.is_some() {
                "exited"
            } else if state.started {
                "running"
            } else {
                "created"
            };
            let code = state.terminal.as_ref().map_or_else(
                || if state.error.is_some() { 125 } else { 0 },
                |terminal| terminal.code,
            );
            let container = &item.container;
            let mut config = container.config.clone();
            config["Tty"] = json!(false);
            let specs = container.spec["argv"].as_array().expect("validated args");
            let mut reply = Reply::json(
                200,
                json!({
                    "Id":container.id,"Name":format!("/{}",container.name),"Image":container.spec["image_digest"],
                    "Driver":BACKEND,"Platform":"linux","Path":specs[0],"Args":specs[1..],
                    "RestartCount":state.generation,
                    "State":{"Status":status,"Running":status=="running","ExitCode":code,
                             "Error":state.error.as_deref().unwrap_or("")},
                    "Config":config,"HostConfig":container.config["HostConfig"],"NetworkSettings":{"Networks":{}},
                }),
            );
            reply.attributed = true;
            reply
        }
        ("DELETE", "") => {
            if !disabled(query.get("v")) || !disabled(query.get("link")) {
                return Err(Rejected::bad("volume and link removal are not supported"));
            }
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
    send_output(item, enabled, generation, true, writer)
}

fn send_output(
    item: &Item,
    enabled: [bool; 2],
    generation: u64,
    follow: bool,
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
            if remaining.is_zero() {
                return Ok(());
            }
            let (next, _) = item.changed.wait_timeout(state, remaining).unwrap();
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

pub(super) fn serve(mut stream: UnixStream, owner: &Arc<Owner>) -> io::Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    while await_request(&reader)? {
        let request = match parse(&mut reader) {
            Ok(Some(request)) => request,
            Ok(None) => break,
            Err(Rejected(status, message)) => {
                Reply::json(status, json!({"message":message})).send(&mut stream, false, true)?;
                break;
            }
        };
        let close = request.close || super::STOP.load(std::sync::atomic::Ordering::Acquire);
        match dispatch(owner, &request) {
            Ok(Action::Reply(reply)) => reply.send(&mut stream, request.method == "HEAD", close)?,
            Err(Rejected(status, message)) => Reply::json(status, json!({"message":message}))
                .send(&mut stream, request.method == "HEAD", close)?,
            Ok(Action::Wait(item, condition, generation)) => {
                wait(&item, &condition, generation, &mut stream)?;
                break;
            }
            Ok(Action::Attach(item, streams, generation)) => {
                attach(&item, streams, generation, &mut stream)?;
                break;
            }
            Ok(Action::Logs(item, streams, generation, follow)) => {
                header(&mut stream, 200, "Connection: close\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\n")?;
                send_output(&item, streams, generation, follow, &mut stream)?;
                break;
            }
        }
        if close {
            break;
        }
    }
    stream.shutdown(Shutdown::Write)
}

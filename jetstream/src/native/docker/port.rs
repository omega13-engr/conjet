use std::io;
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use anyhow::ensure;
use conjet_launch_service::{handshake::Key, relay};
use serde_json::{json, Value};

use super::{client, request, session, Rejected};

const MAX_PEERS: usize = 2;
const IDLE: Duration = Duration::from_secs(15);

struct RequestedMapping {
    guest: u16,
    host: u16,
}

fn port(value: &str) -> Option<u16> {
    value
        .parse::<u16>()
        .ok()
        .filter(|number| number.to_string() == value)
}

impl RequestedMapping {
    pub(super) fn parse(config: &Value) -> Result<Option<Self>, Rejected> {
        let exposed = request::object(&config["ExposedPorts"], "exposed ports")?;
        let bindings = request::object(&config["HostConfig"]["PortBindings"], "port bindings")?;
        let Some(bindings) = bindings.filter(|bindings| !bindings.is_empty()) else {
            if exposed.is_some_and(|exposed| !exposed.is_empty()) {
                return Err(Rejected::bad("exposing ports requires a loopback binding"));
            }
            return Ok(None);
        };
        if bindings.len() != 1 {
            return Err(Rejected::bad(
                "only one native TCP port binding is supported",
            ));
        }
        let (container_port, bindings) = bindings.iter().next().expect("one port binding");
        if exposed.is_some_and(|exposed| {
            exposed.len() != 1
                || !exposed
                    .get(container_port)
                    .is_some_and(|marker| marker.as_object().is_some_and(serde_json::Map::is_empty))
        }) {
            return Err(Rejected::bad(
                "exposed port differs from the published port",
            ));
        }
        let guest = container_port
            .strip_suffix("/tcp")
            .and_then(port)
            .filter(|port| *port != 0)
            .ok_or_else(|| Rejected::bad("native port publication requires TCP"))?;
        let [binding] = bindings.as_array().map(Vec::as_slice).unwrap_or_default() else {
            return Err(Rejected::bad("only one host address and port is supported"));
        };
        let fields = request::object(binding, "native port binding")?
            .ok_or_else(|| Rejected::bad("expected a native port binding"))?;
        request::options(fields, &["HostIp", "HostPort"], "port binding ")?;
        if binding["HostIp"] != "127.0.0.1" {
            return Err(Rejected::bad("native port publication requires 127.0.0.1"));
        }
        let host = match binding["HostPort"].as_str() {
            Some("") => 0,
            Some(value) => port(value).ok_or_else(|| Rejected::bad("invalid loopback port"))?,
            None => return Err(Rejected::bad("missing loopback port")),
        };
        Ok(Some(Self { guest, host }))
    }
}

/// A bounded collection owns every listener, so partial setup rolls back all ports.
pub(super) struct RequestedPort(Vec<RequestedMapping>);

impl RequestedPort {
    pub(super) fn parse(config: &Value) -> Result<Option<Self>, Rejected> {
        let Some(bindings) =
            request::object(&config["HostConfig"]["PortBindings"], "port bindings")?
                .filter(|b| !b.is_empty())
        else {
            return RequestedMapping::parse(config).map(|p| p.map(|p| Self(vec![p])));
        };
        if bindings.len() > 8 {
            return Err(Rejected::bad(
                "native TCP publication supports at most eight ports",
            ));
        }
        if let Some(exposed) = request::object(&config["ExposedPorts"], "exposed ports")? {
            if exposed.keys().any(|key| !bindings.contains_key(key)) {
                return Err(Rejected::bad(
                    "exposed port differs from the published ports",
                ));
            }
        }
        let mut ports = Vec::with_capacity(bindings.len());
        for (key, value) in bindings {
            let mut entry = config.clone();
            entry["HostConfig"]["PortBindings"] = json!({(key):value});
            entry["ExposedPorts"] = match config["ExposedPorts"].get(key) {
                Some(value) => json!({(key):value}),
                None => Value::Null,
            };
            ports.push(RequestedMapping::parse(&entry)?.expect("nonempty binding"));
        }
        Ok(Some(Self(ports)))
    }
}

pub(super) struct PublishedPort(Vec<PublishedMapping>);

impl PublishedPort {
    pub(super) fn bind(request: RequestedPort, endpoint: Endpoint) -> Result<Self, Rejected> {
        request
            .0
            .into_iter()
            .map(|p| PublishedMapping::bind(p, endpoint.clone()))
            .collect::<Result<Vec<_>, _>>()
            .map(Self)
    }
    pub(super) fn live_address(&self, guest: u16) -> Option<std::net::SocketAddr> {
        self.0.iter().find_map(|port| port.live_address(guest))
    }
    pub(super) fn set_target(&self, handle: Option<Value>) {
        for port in &self.0 {
            port.set_target(handle.clone());
        }
    }
    pub(super) fn inspect(&self, active: bool) -> Value {
        let mut result = serde_json::Map::new();
        for port in &self.0 {
            result.extend(port.inspect(active).as_object().unwrap().clone());
        }
        Value::Object(result)
    }
    pub(super) fn summary(&self) -> Vec<Value> {
        self.0.iter().map(PublishedMapping::summary).collect()
    }
}

#[derive(Clone)]
pub(super) struct Endpoint {
    pub directory: PathBuf,
    pub identity: session::Identity,
    pub key: Key,
    pub boot: String,
}

#[derive(Clone)]
struct Target {
    handle: Value,
    cancelled: Arc<AtomicBool>,
}

struct PublishedMapping {
    port: u16,
    guest: u16,
    target: Arc<Mutex<Option<Target>>>,
    stopped: Arc<AtomicBool>,
    task: Option<JoinHandle<()>>,
}

impl PublishedMapping {
    pub(super) fn live_address(&self, guest: u16) -> Option<std::net::SocketAddr> {
        (self.guest == guest && self.target.lock().unwrap().is_some())
            .then(|| (Ipv4Addr::LOCALHOST, self.port).into())
    }

    pub(super) fn bind(request: RequestedMapping, endpoint: Endpoint) -> Result<Self, Rejected> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, request.host)).map_err(|error| {
            if error.kind() == io::ErrorKind::AddrInUse {
                Rejected(409, "requested loopback port is already in use".into())
            } else {
                Rejected::internal(format!("cannot bind loopback port: {error}"))
            }
        })?;
        let port = listener
            .local_addr()
            .map_err(|error| Rejected::internal(error.to_string()))?
            .port();
        listener
            .set_nonblocking(true)
            .map_err(|error| Rejected::internal(error.to_string()))?;
        let stopped = Arc::new(AtomicBool::new(false));
        let target = Arc::new(Mutex::new(None));
        let accept_stop = Arc::clone(&stopped);
        let accept_target = Arc::clone(&target);
        let guest = request.guest;
        let task = thread::Builder::new()
            .name("native-loopback".into())
            .spawn(move || {
                serve(
                    listener,
                    Arc::new(endpoint),
                    guest,
                    &accept_target,
                    &accept_stop,
                );
            })
            .map_err(|error| Rejected::internal(error.to_string()))?;
        Ok(Self {
            port,
            guest,
            target,
            stopped,
            task: Some(task),
        })
    }

    pub(super) fn set_target(&self, handle: Option<Value>) {
        let mut current = self.target.lock().unwrap();
        if current.as_ref().map(|target| &target.handle) == handle.as_ref() {
            return;
        }
        if let Some(old) = current.take() {
            old.cancelled.store(true, Ordering::Release);
        }
        *current = handle.map(|handle| Target {
            handle,
            cancelled: Arc::new(AtomicBool::new(false)),
        });
    }

    pub(super) fn inspect(&self, active: bool) -> Value {
        let endpoint = if active {
            json!([{"HostIp":"127.0.0.1","HostPort":self.port.to_string()}])
        } else {
            Value::Null
        };
        json!({(format!("{}/tcp",self.guest)):endpoint})
    }

    pub(super) fn summary(&self) -> Value {
        json!({"IP":"127.0.0.1","PrivatePort":self.guest,"PublicPort":self.port,"Type":"tcp"})
    }
}

impl Drop for PublishedMapping {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Release);
        self.set_target(None);
        if let Some(task) = self.task.take() {
            let _ = task.join();
        }
    }
}

fn serve(
    listener: TcpListener,
    endpoint: Arc<Endpoint>,
    guest: u16,
    target: &Mutex<Option<Target>>,
    stopped: &AtomicBool,
) {
    let mut workers: Vec<JoinHandle<()>> = Vec::with_capacity(MAX_PEERS);
    while !stopped.load(Ordering::Acquire) {
        for index in (0..workers.len()).rev() {
            if workers[index].is_finished() {
                let _ = workers.swap_remove(index).join();
            }
        }
        match listener.accept() {
            Ok((stream, _)) if workers.len() < MAX_PEERS => {
                let target = target.lock().unwrap().clone();
                if let Some(target) = target {
                    let endpoint = Arc::clone(&endpoint);
                    if let Ok(worker) = thread::Builder::new()
                        .name("native-port-relay".into())
                        .spawn(move || {
                            let _ = connect(&endpoint, stream, guest, &target);
                        })
                    {
                        workers.push(worker);
                    }
                }
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let mut item = libc::pollfd {
                    fd: listener.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                unsafe { libc::poll(&mut item, 1, 25) };
            }
            Err(_) => break,
        }
    }
    drop(listener);
    for worker in workers {
        let _ = worker.join();
    }
}

fn connect(
    endpoint: &Endpoint,
    stream: TcpStream,
    port: u16,
    target: &Target,
) -> anyhow::Result<()> {
    let cancelled = || target.cancelled.load(Ordering::Acquire);
    if cancelled() {
        return Ok(());
    }
    let peer = client::Connection::open(&endpoint.directory, &endpoint.identity, &endpoint.key)?;
    ensure!(
        peer.oci && peer.boot == endpoint.boot,
        "native port relay guest generation changed"
    );
    let guest = peer.dial(&target.handle, port)?;
    relay::pump(&stream, &guest, IDLE, cancelled)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_ephemeral_and_explicit_loopback_ports() {
        for (host, expected) in [("", 0), ("0", 0), ("8190", 8190)] {
            let config = json!({
                "ExposedPorts":{"8080/tcp":{}},
                "HostConfig":{"PortBindings":{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":host}]}}
            });
            let port = RequestedPort::parse(&config).unwrap().unwrap();
            assert_eq!((port.0[0].guest, port.0[0].host), (8080, expected));
        }
    }

    #[test]
    fn failed_second_listener_releases_the_first() {
        let occupied = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let temporary = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let first = temporary.local_addr().unwrap().port();
        drop(temporary);
        let endpoint = Endpoint {
            directory: PathBuf::from("/unused"),
            identity: session::Identity {
                pid: 1,
                image_digest: "test".into(),
                memory_mib: 2048,
            },
            key: [0; 32],
            boot: "test".into(),
        };
        let request = RequestedPort(vec![
            RequestedMapping {
                guest: 8787,
                host: first,
            },
            RequestedMapping {
                guest: 8788,
                host: occupied.local_addr().unwrap().port(),
            },
        ]);
        assert!(PublishedPort::bind(request, endpoint).is_err());
        assert!(TcpListener::bind((Ipv4Addr::LOCALHOST, first)).is_ok());
    }

    #[test]
    fn accepts_multiple_loopback_mappings_and_preserves_each_target() {
        let config = json!({"ExposedPorts":{"8787/tcp":{},"8788/tcp":{}},
            "HostConfig":{"PortBindings":{
                "8787/tcp":[{"HostIp":"127.0.0.1","HostPort":"18787"}],
                "8788/tcp":[{"HostIp":"127.0.0.1","HostPort":"18788"}]}}});
        let parsed = RequestedPort::parse(&config).unwrap().unwrap();
        assert_eq!(
            parsed
                .0
                .iter()
                .map(|p| (p.guest, p.host))
                .collect::<Vec<_>>(),
            [(8787, 18787), (8788, 18788)]
        );
        let mut invalid = config.clone();
        invalid["HostConfig"]["PortBindings"]["8788/tcp"][0]["HostIp"] = json!("0.0.0.0");
        assert!(RequestedPort::parse(&invalid).is_err());
    }

    #[test]
    fn rejects_wildcards_udp_and_contradictory_exposure() {
        for (ip, mapping, exposed) in [
            ("0.0.0.0", "8080/tcp", "8080/tcp"),
            ("127.0.0.1", "8080/udp", "8080/udp"),
            ("127.0.0.1", "8080/tcp", "8081/tcp"),
        ] {
            let config = json!({
                "ExposedPorts":{(exposed):{}},
                "HostConfig":{"PortBindings":{(mapping):[{"HostIp":ip,"HostPort":"0"}]}}
            });
            assert!(RequestedPort::parse(&config).is_err());
        }
    }
}

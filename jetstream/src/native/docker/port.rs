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

pub(super) struct RequestedPort {
    guest: u16,
    host: u16,
}

fn port(value: &str) -> Option<u16> {
    value
        .parse::<u16>()
        .ok()
        .filter(|number| number.to_string() == value)
}

impl RequestedPort {
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

pub(super) struct PublishedPort {
    port: u16,
    guest: u16,
    target: Arc<Mutex<Option<Target>>>,
    stopped: Arc<AtomicBool>,
    task: Option<JoinHandle<()>>,
}

impl PublishedPort {
    pub(super) fn bind(request: RequestedPort, endpoint: Endpoint) -> Result<Self, Rejected> {
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
}

impl Drop for PublishedPort {
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
            assert_eq!((port.guest, port.host), (8080, expected));
        }
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

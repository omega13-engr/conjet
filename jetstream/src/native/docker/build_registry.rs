use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use anyhow::{ensure, Context};
use conjet_launch_service::socket::Stream;

use super::{Owner, STOP};

const HEADER_LIMIT: u64 = 8192;
const WORKERS: usize = conjet_launch_service::handshake::BUILD_RELAY_CONNECTIONS;

pub(super) struct Relay {
    stop: Arc<AtomicBool>,
    workers: Vec<JoinHandle<()>>,
}

impl Relay {
    pub(super) fn start(owner: &Arc<Owner>, trace: bool) -> io::Result<Self> {
        let mut relay = Self {
            stop: Arc::new(AtomicBool::new(false)),
            workers: Vec::with_capacity(WORKERS),
        };
        let acceptance = Arc::new(Mutex::new(()));
        for _ in 0..WORKERS {
            let acceptance = acceptance.clone();
            let owner = owner.clone();
            let stop = relay.stop.clone();
            relay.workers.push(
                thread::Builder::new()
                    .name("native-build-registry".into())
                    .spawn(move || {
                        let stopping =
                            || stop.load(Ordering::Acquire) || STOP.load(Ordering::Acquire);
                        while !stopping() {
                            // Only one idle poller holds a control connection.
                            // Busy transfers release this gate to the next worker.
                            let mut gate = Some(acceptance.lock().unwrap());
                            if stopping() {
                                break;
                            }
                            if !owner.has_build_registry_worker() {
                                thread::sleep(Duration::from_millis(50));
                                continue;
                            }
                            let Ok(mut peer) = owner.scoped_peer() else {
                                thread::sleep(Duration::from_millis(50));
                                continue;
                            };
                            while !stopping() && owner.has_build_registry_worker() {
                                match peer.poll_build_registry() {
                                    Ok(true) => {
                                        drop(gate.take());
                                        if let Err(error) =
                                            serve(&owner, &mut peer.into_build_registry(), trace)
                                        {
                                            eprintln!("native build relay failed: {error:#}");
                                        }
                                        break;
                                    }
                                    Ok(false) => thread::sleep(Duration::from_millis(50)),
                                    Err(_) => break,
                                }
                            }
                        }
                    })?,
            );
        }
        Ok(relay)
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Object<'a> {
    Ping,
    Content {
        repository: &'a str,
        digest: &'a str,
        manifest: bool,
    },
}

fn request(line: &str) -> anyhow::Result<(bool, Object<'_>)> {
    let mut fields = line.split_ascii_whitespace();
    let head = match fields.next() {
        Some("GET") => false,
        Some("HEAD") => true,
        _ => anyhow::bail!("unsupported registry method"),
    };
    let url = fields.next().context("missing registry path")?;
    ensure!(
        fields.next() == Some("HTTP/1.1") && fields.next().is_none(),
        "unsupported registry request layout"
    );
    let (path, query) = url.split_once('?').map_or((url, ""), |pair| pair);
    ensure!(
        matches!(query, "" | "ns=docker.io"),
        "unsupported registry namespace"
    );
    let path = path
        .strip_prefix("/v2/")
        .context("expected a distribution request")?;
    if path.is_empty() {
        return Ok((head, Object::Ping));
    }
    let (path, digest) = path.rsplit_once('/').context("missing registry digest")?;
    let (repository, kind) = path
        .rsplit_once('/')
        .context("missing registry repository")?;
    ensure!(
        super::build_mirror::repository(repository),
        "invalid registry repository"
    );
    let manifest = match kind {
        "manifests" => true,
        "blobs" => false,
        _ => anyhow::bail!("unsupported registry object"),
    };
    ensure!(
        super::request::digest(digest) || (manifest && super::public_registry::valid_tag(digest)),
        "expected a registry digest or a supported image tag"
    );
    Ok((
        head,
        Object::Content {
            repository,
            digest,
            manifest,
        },
    ))
}

fn serve(owner: &Owner, stream: &mut Stream, trace: bool) -> anyhow::Result<()> {
    // Do not prefetch and discard a CONNECT tunnel's first TLS bytes.
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        ensure!(
            header.len() < HEADER_LIMIT as usize,
            "registry header limit exceeded"
        );
        let mut byte = [0];
        stream.read_exact(&mut byte)?;
        header.push(byte[0]);
    }
    let header = std::str::from_utf8(&header)?;
    let line = header
        .split("\r\n")
        .next()
        .context("missing registry request")?;
    if line.starts_with("CONNECT ")
        || line
            .split_whitespace()
            .nth(1)
            .is_some_and(|url| url.starts_with("http://"))
    {
        return super::build_proxy::serve(owner, stream, header);
    }
    let (head, object) = match request(line) {
        Ok(request) => request,
        Err(error) => {
            stream.write_all(
                b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )?;
            return Err(error);
        }
    };
    let Object::Content {
        repository,
        digest,
        manifest,
    } = object
    else {
        stream.write_all(b"HTTP/1.1 200 OK\r\nDocker-Distribution-Api-Version: registry/2.0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")?;
        return Ok(());
    };
    let result = owner
        .store
        .as_ref()
        .context("registry mirror requires a private store")?
        .lock()
        .unwrap()
        .worker_registry_file(repository, digest, manifest);
    match result {
        Ok((mut file, content_type, digest, cached)) => {
            let size = file.metadata()?.len();
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nDocker-Content-Digest: {digest}\r\nConnection: close\r\n\r\n",
                size)?;
            if !head {
                ensure!(
                    io::copy(&mut file, stream)? == size,
                    "registry object size changed during transfer"
                );
            }
            if trace {
                eprintln!(
                    "{}",
                    serde_json::json!({
                        "event":"build_registry", "repository":repository, "digest":digest,
                        "head":head, "manifest":manifest, "bytes":if head {0} else {size},
                        "source":if cached {"verified-cache"} else {"public-https"},
                    })
                );
            }
        }
        Err(error) => {
            eprintln!("native build registry could not serve the pinned object: {error:#}");
            stream.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_accepts_only_distribution_reads_by_digest() {
        let digest = format!("sha256:{}", "a".repeat(64));
        let path = format!("/v2/library/node/manifests/{digest}?ns=docker.io");
        assert_eq!(
            request(&format!("HEAD {path} HTTP/1.1")).unwrap(),
            (
                true,
                Object::Content {
                    repository: "library/node",
                    digest: &digest,
                    manifest: true
                }
            )
        );
        assert!(request("HEAD /v2/docker/dockerfile/manifests/1?ns=docker.io HTTP/1.1").is_ok());
        for line in [
            format!("PUT {path} HTTP/1.1"),
            "GET /v2/library/node/blobs/latest HTTP/1.1".into(),
            format!("GET /v2/library/node/blobs/{digest}?ns=example.com HTTP/1.1"),
            format!("GET http://example.com/v2/library/node/blobs/{digest} HTTP/1.1"),
        ] {
            assert!(request(&line).is_err());
        }
    }
}

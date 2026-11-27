use std::io::{self, BufRead, BufReader, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use anyhow::{ensure, Context};
use conjet_launch_service::socket::Stream;

use super::{Owner, STOP};

const HEADER_LIMIT: u64 = 8192;
const WORKERS: usize = 3;

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
        for _ in 0..WORKERS {
            let owner = owner.clone();
            let stop = relay.stop.clone();
            relay.workers.push(
                thread::Builder::new()
                    .name("native-build-registry".into())
                    .spawn(move || {
                        let stopping =
                            || stop.load(Ordering::Acquire) || STOP.load(Ordering::Acquire);
                        while !stopping() {
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
                                        let _ =
                                            serve(&owner, &mut peer.into_build_registry(), trace);
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
    let manifest = match kind {
        "manifests" => true,
        "blobs" => false,
        _ => anyhow::bail!("unsupported registry object"),
    };
    ensure!(
        super::request::digest(digest)
            || (manifest
                && repository == "library/alpine"
                && super::public_registry::valid_tag(digest)),
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
    let mut line = String::new();
    {
        let mut reader = BufReader::new((&mut *stream).take(HEADER_LIMIT));
        reader.read_line(&mut line)?;
        let mut header = Vec::new();
        loop {
            header.clear();
            ensure!(
                reader.read_until(b'\n', &mut header)? > 0,
                "truncated registry headers"
            );
            if header == b"\r\n" {
                break;
            }
        }
    }
    let (head, object) = request(&line)?;
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
        for line in [
            format!("PUT {path} HTTP/1.1"),
            "GET /v2/library/node/manifests/latest HTTP/1.1".into(),
            format!("GET /v2/library/node/blobs/{digest}?ns=example.com HTTP/1.1"),
            format!("GET http://example.com/v2/library/node/blobs/{digest} HTTP/1.1"),
        ] {
            assert!(request(&line).is_err());
        }
    }
}

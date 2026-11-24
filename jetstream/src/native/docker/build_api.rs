//! Translate a bounded Docker archive build into the private Buildx driver.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::{net::UnixStream, process::CommandExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{atomic::Ordering, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{ensure, Context};
use serde_json::json;

use super::{buildkit, image, private_scratch, Owner, Rejected, STOP};

pub(super) const CONTEXT_LIMIT: usize = 32 * 1024 * 1024;
const CONTEXT_ENTRIES: usize = 4096;
const LOG_LIMIT: u64 = 16 * 1024;
const COMMAND_LIMIT: Duration = Duration::from_secs(180);

pub(super) struct Client {
    docker: PathBuf,
    config: PathBuf,
    host: String,
    building: Mutex<()>,
}

pub(super) struct Options {
    tag: String,
    no_cache: bool,
}

impl Options {
    pub(super) fn parse(query: &BTreeMap<String, String>) -> Result<Self, Rejected> {
        if !query.iter().all(|(key, value)| match key.as_str() {
            "dockerfile" => value == "Dockerfile",
            "networkmode" => value == "none",
            "platform" => value == "linux/arm64",
            "version" => value == "1",
            "rm" | "forcerm" => matches!(value.as_str(), "1" | "true"),
            "nocache" => matches!(value.as_str(), "0" | "1" | "true" | "false"),
            "t" => true,
            _ => false,
        }) {
            return Err(Rejected::bad("unsupported native Docker build option"));
        }
        let tag = query
            .get("t")
            .ok_or_else(|| Rejected::bad("native build requires a local tag"))?;
        let tag = image::Tags::key(tag);
        let (repository, version) = tag
            .rsplit_once(':')
            .filter(|(_, version)| !version.is_empty())
            .ok_or_else(|| Rejected::bad("invalid native Docker build tag"))?;
        image::Tags::default().insert(repository, version, String::new())?;
        Ok(Self {
            tag: tag.into_owned(),
            no_cache: query
                .get("nocache")
                .is_some_and(|value| matches!(value.as_str(), "1" | "true")),
        })
    }
}

impl Client {
    pub(super) fn new(docker: PathBuf, config: PathBuf, socket: &Path) -> anyhow::Result<Self> {
        private_scratch(&config)?;
        ensure!(
            docker.is_absolute() && docker.is_file(),
            "expected a local Docker executable"
        );
        let docker = docker.canonicalize()?;
        let socket = socket.to_str().context("invalid private Docker endpoint")?;
        Ok(Self {
            docker,
            config,
            host: format!("unix://{socket}"),
            building: Mutex::new(()),
        })
    }

    fn invoke(&self, args: &[&str], client: Option<&UnixStream>) -> anyhow::Result<String> {
        let mut process = Command::new(&self.docker)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &self.config)
            .env("TMPDIR", &self.config)
            .env("DOCKER_HOST", &self.host)
            .env("DOCKER_API_VERSION", "1.44")
            .args([
                "--config",
                self.config.to_str().context("invalid Docker config path")?,
                "buildx",
            ])
            .args(args)
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("start the private Buildx client")?;
        let drain = |mut pipe: Box<dyn Read + Send>| {
            thread::spawn(move || -> io::Result<Vec<u8>> {
                let mut log = Vec::new();
                (&mut pipe).take(LOG_LIMIT).read_to_end(&mut log)?;
                io::copy(&mut pipe, &mut io::sink())?;
                Ok(log)
            })
        };
        let stdout = drain(Box::new(
            process.stdout.take().expect("piped Buildx stdout"),
        ));
        let stderr = drain(Box::new(
            process.stderr.take().expect("piped Buildx stderr"),
        ));
        let deadline = Instant::now() + COMMAND_LIMIT;
        let status = loop {
            if let Some(status) = process.try_wait()? {
                break Ok(status);
            }
            if Instant::now() >= deadline
                || (client.is_some_and(disconnected))
                || (client.is_some() && STOP.load(Ordering::Acquire))
            {
                // Docker starts the Buildx plug-in in the same process group.
                let group = -(process.id() as i32);
                unsafe { libc::kill(group, libc::SIGINT) };
                let grace = Instant::now() + Duration::from_secs(3);
                while process.try_wait()?.is_none() && Instant::now() < grace {
                    thread::sleep(Duration::from_millis(25));
                }
                unsafe { libc::kill(group, libc::SIGKILL) };
                process.wait()?;
                break Err(anyhow::anyhow!("private Docker build cancelled or expired"));
            }
            thread::sleep(Duration::from_millis(25));
        };
        let stdout = stdout
            .join()
            .map_err(|_| anyhow::anyhow!("Buildx output reader failed"))??;
        let stderr = stderr
            .join()
            .map_err(|_| anyhow::anyhow!("Buildx error reader failed"))??;
        let stderr = String::from_utf8_lossy(&stderr);
        ensure!(status?.success(), "Buildx failed: {}", stderr.trim());
        Ok(String::from_utf8_lossy(&stdout).into_owned())
    }

    pub(super) fn build(
        &self,
        owner: &Owner,
        context: File,
        options: Options,
        client: &UnixStream,
    ) -> Result<Vec<u8>, Rejected> {
        let _lock = self
            .building
            .try_lock()
            .map_err(|_| Rejected(409, "another native API build is active".into()))?;
        {
            let ledger = owner.ledger.lock().unwrap();
            if ledger.closing || ledger.poisoned || !ledger.active.is_empty() {
                return Err(Rejected(
                    409,
                    "native API builds require an idle guest".into(),
                ));
            }
        }
        let root = owner
            .archive_root
            .as_ref()
            .ok_or_else(|| Rejected::internal("missing private build archive directory"))?;
        let scratch =
            tempfile::tempdir_in(root).map_err(|error| Rejected::internal(error.to_string()))?;
        let input = scratch.path().join("context");
        std::fs::create_dir(&input).map_err(|error| Rejected::internal(error.to_string()))?;
        unpack(context, &input).map_err(|error| Rejected::bad(format!("{error:#}")))?;
        let input = input.to_str().expect("private scratch path is UTF-8");
        let nonce = super::random::<8>().map_err(|error| Rejected::internal(error.to_string()))?;
        let builder = format!("conjet-api-{}", super::hex(&nonce));
        let worker = format!("buildx_buildkit_{builder}0");
        let image = format!("image={}", buildkit::IMAGE);
        let archive = scratch.path().join("result.tar");
        let output = format!("type=docker,dest={}", archive.display());
        let create = self.invoke(
            &[
                "create",
                "--name",
                &builder,
                "--driver",
                "docker-container",
                "--driver-opt",
                &image,
            ],
            Some(client),
        );
        let created = create.is_ok();
        let solve = create.and_then(|_| {
            self.invoke(&["inspect", "--bootstrap", &builder], Some(client))?;
            let mut args = vec![
                "build",
                "--builder",
                &builder,
                "--platform",
                "linux/arm64",
                "--network",
                "none",
                "--progress",
                "plain",
                "--tag",
                &options.tag,
                "--output",
                &output,
            ];
            if options.no_cache {
                args.push("--no-cache");
            }
            args.push(input);
            self.invoke(&args, Some(client))
        });
        let cleanup = self.invoke(&["rm", &builder], None);
        if owner
            .lookup(&worker)
            .is_ok_and(|item| !item.state().removed)
            || !matches!(
                super::volume::inspect(owner, &(worker + "_state")),
                Err(Rejected(404, _))
            )
        {
            return Err(Rejected::internal(
                "native API build left its worker or cache active",
            ));
        }
        if created {
            cleanup.map_err(|error| Rejected::internal(format!("{error:#}")))?;
        }
        if solve.is_ok() {
            let file =
                File::open(&archive).map_err(|error| Rejected::internal(error.to_string()))?;
            if file.metadata().map_or(true, |metadata| {
                metadata.len() > super::archive::LIMIT as u64
            }) {
                return Err(Rejected(
                    413,
                    "native build export exceeds its bound".into(),
                ));
            }
            return owner.load_archive(&file);
        }
        let message = solve.unwrap_err().to_string();
        let mut failed = json!({"error":message,"errorDetail":{"message":message}})
            .to_string()
            .into_bytes();
        failed.push(b'\n');
        Ok(failed)
    }
}

fn unpack(context: File, directory: &Path) -> anyhow::Result<()> {
    let mut context = BufReader::new(context);
    let stream: Box<dyn Read> = if context.fill_buf()?.starts_with(b"\x1f\x8b") {
        Box::new(flate2::read::GzDecoder::new(context))
    } else {
        Box::new(context)
    };
    // Bound compressed inputs by their decoded size as well as their upload size.
    let mut archive = tar::Archive::new(stream.take(CONTEXT_LIMIT as u64 + 1));
    let mut paths = std::collections::BTreeSet::new();
    for (index, entry) in archive.entries()?.enumerate() {
        ensure!(
            index < CONTEXT_ENTRIES,
            "Docker build context has too many entries"
        );
        let mut entry = entry?;
        let kind = entry.header().entry_type();
        let path = entry.path()?;
        let mut clean = PathBuf::new();
        for component in path.components() {
            match component {
                Component::Normal(part) => clean.push(part),
                Component::CurDir => {}
                _ => anyhow::bail!("Docker build context contains a path outside its root"),
            }
        }
        if clean.as_os_str().is_empty() && kind.is_dir() {
            continue;
        }
        ensure!(
            kind.is_file() || kind.is_dir(),
            "Docker build context entry must be a file or directory"
        );
        ensure!(
            paths.insert(clean),
            "Docker build context contains a duplicate path"
        );
        ensure!(
            entry.unpack_in(directory)?,
            "Docker build context entry escaped its root"
        );
    }
    ensure!(
        directory.join("Dockerfile").is_file(),
        "Docker build context is missing Dockerfile"
    );
    Ok(())
}

fn disconnected(client: &UnixStream) -> bool {
    let mut poll = libc::pollfd {
        fd: client.as_raw_fd(),
        events: 0,
        revents: 0,
    };
    if unsafe { libc::poll(&mut poll, 1, 0) } <= 0 {
        return false;
    }
    if poll.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
        let _ = client.shutdown(Shutdown::Both);
        true
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_accepts_local_archive_builds_with_isolated_network() {
        let mut query = BTreeMap::from([
            ("t".into(), "local/fixture".into()),
            ("networkmode".into(), "none".into()),
        ]);
        assert_eq!(Options::parse(&query).unwrap().tag, "local/fixture:latest");
        query.insert("networkmode".into(), "host".into());
        assert!(Options::parse(&query).is_err());
        query.remove("networkmode");
        query.insert("remote".into(), "https://example.org/context.tar".into());
        assert!(Options::parse(&query).is_err());
    }

    #[test]
    fn build_upload_admits_regular_files_and_rejects_a_link() {
        use std::io::Seek;

        let make_archive = |add_link: bool| {
            let file = tempfile::tempfile().unwrap();
            let mut archive = tar::Builder::new(file);
            let contents = b"FROM scratch\n";
            let mut header = tar::Header::new_ustar();
            header.set_size(contents.len() as u64);
            header.set_mode(0o644);
            archive
                .append_data(&mut header, "Dockerfile", &contents[..])
                .unwrap();
            if add_link {
                let mut header = tar::Header::new_ustar();
                header.set_entry_type(tar::EntryType::Symlink);
                header.set_mode(0o777);
                header.set_size(0);
                archive
                    .append_link(&mut header, "link", "Dockerfile")
                    .unwrap();
            }
            let mut file = archive.into_inner().unwrap();
            file.rewind().unwrap();
            file
        };
        let directory = tempfile::tempdir().unwrap();
        unpack(make_archive(false), directory.path()).unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("Dockerfile")).unwrap(),
            b"FROM scratch\n"
        );
        let rejected = tempfile::tempdir().unwrap();
        assert!(unpack(make_archive(true), rejected.path()).is_err());
        assert!(!rejected.path().join("link").exists());
    }
}

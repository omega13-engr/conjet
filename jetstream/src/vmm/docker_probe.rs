use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct DockerProbeReport {
    pub ok: bool,
    pub status_code: Option<u16>,
    pub response_body: String,
    pub attempts: u32,
    pub elapsed_ms: u64,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct DockerSocketReadinessProbe {
    socket_path: PathBuf,
}

impl DockerSocketReadinessProbe {
    pub fn new(socket_path: impl AsRef<Path>) -> Self {
        Self {
            socket_path: socket_path.as_ref().to_path_buf(),
        }
    }

    pub fn wait_ready(
        &self,
        timeout: Duration,
        interval: Duration,
        wake: impl Fn(),
    ) -> DockerProbeReport {
        let started = Instant::now();
        let deadline = started + timeout;
        let mut attempts = 0u32;
        let interval = interval.max(Duration::from_millis(10));

        loop {
            attempts = attempts.saturating_add(1);
            wake();
            let attempt_message = match self.try_ping() {
                Ok((status_code, body)) if status_code == 200 && body.trim() == "OK" => {
                    return DockerProbeReport {
                        ok: true,
                        status_code: Some(status_code),
                        response_body: body,
                        attempts,
                        elapsed_ms: elapsed_ms(started),
                        message: "Docker API responded to /_ping".to_string(),
                    };
                }
                Ok((status_code, body)) => {
                    format!(
                        "Docker API returned HTTP {status_code} with body {:?}",
                        body.trim()
                    )
                }
                Err(error) => error,
            };

            if Instant::now() >= deadline {
                return DockerProbeReport {
                    ok: false,
                    status_code: None,
                    response_body: String::new(),
                    attempts,
                    elapsed_ms: elapsed_ms(started),
                    message: format!(
                        "timed out waiting for Docker API on {}: {attempt_message}",
                        self.socket_path.display()
                    ),
                };
            }
            wake();
            std::thread::sleep(interval.min(deadline.saturating_duration_since(Instant::now())));
        }
    }

    fn try_ping(&self) -> Result<(u16, String), String> {
        let mut stream = UnixStream::connect(&self.socket_path)
            .map_err(|error| format!("connect {} failed: {error}", self.socket_path.display()))?;
        stream
            .set_read_timeout(Some(Duration::from_millis(500)))
            .map_err(|error| format!("set read timeout failed: {error}"))?;
        stream
            .set_write_timeout(Some(Duration::from_millis(500)))
            .map_err(|error| format!("set write timeout failed: {error}"))?;

        stream
            .write_all(b"GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")
            .map_err(|error| format!("write Docker ping failed: {error}"))?;
        stream
            .flush()
            .map_err(|error| format!("flush Docker ping failed: {error}"))?;

        let mut response = Vec::new();
        let mut buf = [0u8; 8192];
        loop {
            match stream.read(&mut buf) {
                Ok(0) => break,
                Ok(count) => response.extend_from_slice(&buf[..count]),
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        || error.kind() == std::io::ErrorKind::TimedOut =>
                {
                    break;
                }
                Err(error) => return Err(format!("read Docker ping failed: {error}")),
            }
            if response.len() >= 128 * 1024 {
                break;
            }
        }
        parse_http_response(&response)
    }
}

fn parse_http_response(response: &[u8]) -> Result<(u16, String), String> {
    let header_end = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| "Docker ping response did not contain HTTP headers".to_string())?;
    let headers = String::from_utf8_lossy(&response[..header_end]);
    let status_code = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| "Docker ping response did not contain a status code".to_string())?;
    let body = String::from_utf8_lossy(&response[header_end + 4..]).into_owned();
    Ok((status_code, body))
}

fn elapsed_ms(started: Instant) -> u64 {
    started.elapsed().as_millis().try_into().unwrap_or(u64::MAX)
}

//! WebSocket framing for the owned Docker attach endpoint.

use std::io::{self, BufReader, Read};
use std::os::unix::net::UnixStream;
use std::sync::Mutex;
use std::time::Duration;

use base64::Engine;
use tungstenite::handshake::derive_accept_key;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::protocol::{CloseFrame, Role, WebSocketConfig};
use tungstenite::{Error, Message, WebSocket};

use super::Rejected;

const MAX_MESSAGE: usize = 64 * 1024;
const MAX_WRITE_BUFFER: usize = 16 * 1024;

pub(super) fn accept(key: &str, version: &str) -> Result<String, Rejected> {
    if version != "13"
        || base64::engine::general_purpose::STANDARD
            .decode(key)
            .map_or(true, |decoded| decoded.len() != 16)
    {
        return Err(Rejected::bad("invalid WebSocket attach handshake"));
    }
    Ok(derive_accept_key(key.as_bytes()))
}

pub(super) struct Socket(Mutex<WebSocket<UnixStream>>);

impl Socket {
    pub(super) fn new(reader: BufReader<UnixStream>) -> io::Result<Self> {
        let prefix = reader.buffer().to_vec();
        let stream = reader.into_inner();
        stream.set_read_timeout(Some(Duration::from_millis(100)))?;
        let config = WebSocketConfig::default()
            .read_buffer_size(8192)
            .write_buffer_size(0)
            .max_write_buffer_size(MAX_WRITE_BUFFER)
            .max_frame_size(Some(MAX_MESSAGE))
            .max_message_size(Some(MAX_MESSAGE));
        Ok(Self(Mutex::new(WebSocket::from_partially_read(
            stream,
            prefix,
            Role::Server,
            Some(config),
        ))))
    }

    pub(super) fn send(&self, bytes: &[u8]) -> io::Result<()> {
        map_wire(
            self.0
                .lock()
                .unwrap()
                .send(Message::Binary(bytes.to_vec().into())),
        )
    }

    pub(super) fn close(&self) -> io::Result<()> {
        let mut socket = self.0.lock().unwrap();
        if socket.can_write() {
            map_wire(socket.close(Some(CloseFrame {
                code: CloseCode::Normal,
                reason: "".into(),
            })))?;
        }
        Ok(())
    }

    pub(super) fn reader(&self) -> Reader<'_> {
        Reader {
            socket: self,
            pending: Vec::new(),
            consumed: 0,
            ended: false,
        }
    }
}

pub(super) struct Reader<'a> {
    socket: &'a Socket,
    pending: Vec<u8>,
    consumed: usize,
    pub(super) ended: bool,
}

impl Read for Reader<'_> {
    fn read(&mut self, target: &mut [u8]) -> io::Result<usize> {
        if target.is_empty() {
            return Ok(0);
        }
        while self.pending.len() == self.consumed {
            let mut socket = self.socket.0.lock().unwrap();
            let message = match socket.read() {
                Ok(message) => message,
                Err(Error::ConnectionClosed | Error::AlreadyClosed) => {
                    self.ended = true;
                    return Ok(0);
                }
                Err(error) => {
                    let error = wire_error(error);
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                    ) {
                        // Unix sockets use a short read timeout so an idle
                        // reader cannot monopolize the shared frame state.
                        drop(socket);
                        std::thread::sleep(Duration::from_millis(2));
                    }
                    return Err(error);
                }
            };
            match message {
                Message::Binary(_) | Message::Text(_) => {
                    self.pending = message.into_data().into();
                    self.consumed = 0;
                }
                Message::Ping(_) => map_wire(socket.flush())?,
                Message::Pong(_) => {}
                Message::Close(_) => {
                    self.ended = true;
                    map_wire(socket.flush())?;
                    return Ok(0);
                }
                Message::Frame(_) => {
                    return Err(io::Error::other("unexpected raw WebSocket frame"))
                }
            }
        }
        let bytes = (self.pending.len() - self.consumed).min(target.len());
        target[..bytes].copy_from_slice(&self.pending[self.consumed..self.consumed + bytes]);
        self.consumed += bytes;
        Ok(bytes)
    }
}

pub(super) fn consume(mut reader: Reader<'_>) -> io::Result<()> {
    let mut bytes = [0; 4096];
    loop {
        match reader.read(&mut bytes) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(error) => return Err(error),
        }
    }
}

fn map_wire(result: Result<(), Error>) -> io::Result<()> {
    match result {
        Ok(()) | Err(Error::ConnectionClosed | Error::AlreadyClosed) => Ok(()),
        Err(error) => Err(wire_error(error)),
    }
}

fn wire_error(error: Error) -> io::Error {
    match error {
        Error::Io(error) => error,
        other => io::Error::other(other),
    }
}

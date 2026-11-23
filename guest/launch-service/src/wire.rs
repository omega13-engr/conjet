use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize, de::DeserializeOwned};
use thiserror::Error;

pub const VERSION: u8 = 1;
pub const MAX_PAYLOAD: usize = 16_384;
const HEADER_SIZE: usize = 28;
const MAGIC: [u8; 4] = *b"CJLS";

pub type RequestId = [u8; 16];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Kind {
    Hello = 1,
    Challenge = 2,
    Authenticate = 3,
    HelloAck = 4,
    Ping = 5,
    Pong = 6,
    Shutdown = 7,
    Launch = 8,
    Status = 9,
    Wait = 10,
    Cancel = 11,
    Output = 12,
    State = 13,
    OutputChunk = 14,
    Error = 15,
    ShutdownAck = 16,
    Prepare = 17,
    Claim = 18,
    Memory = 19,
    Inspect = 20,
    Image = 21,
}

impl TryFrom<u8> for Kind {
    type Error = WireError;

    fn try_from(value: u8) -> Result<Self, WireError> {
        use Kind::*;
        match value {
            1 => Ok(Hello),
            2 => Ok(Challenge),
            3 => Ok(Authenticate),
            4 => Ok(HelloAck),
            5 => Ok(Ping),
            6 => Ok(Pong),
            7 => Ok(Shutdown),
            8 => Ok(Launch),
            9 => Ok(Status),
            10 => Ok(Wait),
            11 => Ok(Cancel),
            12 => Ok(Output),
            13 => Ok(State),
            14 => Ok(OutputChunk),
            15 => Ok(Kind::Error),
            16 => Ok(ShutdownAck),
            17 => Ok(Prepare),
            18 => Ok(Claim),
            19 => Ok(Memory),
            20 => Ok(Inspect),
            21 => Ok(Image),
            _ => Err(WireError::BadHeader),
        }
    }
}

#[derive(Debug, Error)]
pub enum WireError {
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error("invalid frame header")]
    BadHeader,
    #[error("frame payload exceeds {MAX_PAYLOAD} bytes")]
    TooLarge,
    #[error("unexpected message or correlation ID")]
    UnexpectedMessage,
    #[error("invalid message payload")]
    InvalidPayload,
    #[error("no mutually supported protocol version")]
    UnsupportedVersion,
    #[error("authentication failed")]
    Unauthorized,
    #[error("secure randomness unavailable")]
    RandomUnavailable,
    #[error("peer rejected request: {0}")]
    PeerError(String),
}

#[derive(Debug)]
pub struct Frame {
    pub kind: Kind,
    pub id: RequestId,
    payload: Vec<u8>,
}

impl Frame {
    pub fn read(mut reader: impl Read) -> Result<Self, WireError> {
        let mut header = [0; HEADER_SIZE];
        reader.read_exact(&mut header)?;
        if header[..4] != MAGIC
            || header[4] != VERSION
            || header[6..8] != [0, 0]
            || header[12..] == [0; 16]
        {
            return Err(WireError::BadHeader);
        }
        let kind = Kind::try_from(header[5])?;
        let size = u32::from_be_bytes(header[8..12].try_into().unwrap()) as usize;
        if size > MAX_PAYLOAD {
            return Err(WireError::TooLarge);
        }
        let mut payload = vec![0; size];
        reader.read_exact(&mut payload)?;
        Ok(Self {
            kind,
            id: header[12..].try_into().unwrap(),
            payload,
        })
    }

    pub fn write(
        mut writer: impl Write,
        kind: Kind,
        id: RequestId,
        message: &impl Serialize,
    ) -> Result<(), WireError> {
        let payload = serde_json::to_vec(message).map_err(|_| WireError::InvalidPayload)?;
        if payload.len() > MAX_PAYLOAD {
            return Err(WireError::TooLarge);
        }
        if payload.first() != Some(&b'{') {
            return Err(WireError::InvalidPayload);
        }
        if id == [0; 16] {
            return Err(WireError::BadHeader);
        }
        let mut header = [0; HEADER_SIZE];
        header[..4].copy_from_slice(&MAGIC);
        header[4] = VERSION;
        header[5] = kind as u8;
        header[8..12].copy_from_slice(&(payload.len() as u32).to_be_bytes());
        header[12..].copy_from_slice(&id);
        writer.write_all(&header)?;
        writer.write_all(&payload)?;
        Ok(())
    }

    pub fn decode<T: DeserializeOwned>(&self) -> Result<T, WireError> {
        if self.payload.iter().find(|byte| !byte.is_ascii_whitespace()) != Some(&b'{') {
            return Err(WireError::InvalidPayload);
        }
        serde_json::from_slice(&self.payload).map_err(|_| WireError::InvalidPayload)
    }

    pub fn expect<T: DeserializeOwned>(&self, kind: Kind, id: RequestId) -> Result<T, WireError> {
        if self.id != id {
            return Err(WireError::UnexpectedMessage);
        }
        if self.kind == Kind::Error {
            let error: ErrorReply = self.decode()?;
            if error.code.is_empty()
                || error.code.len() > 64
                || !error
                    .code
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte == b'_')
                || error.message.len() > 256
            {
                return Err(WireError::InvalidPayload);
            }
            return Err(WireError::PeerError(error.code));
        }
        if self.kind != kind {
            return Err(WireError::UnexpectedMessage);
        }
        self.decode()
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorReply {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u32>,
}

pub fn write_error(
    writer: impl Write,
    id: RequestId,
    code: &str,
    message: &str,
) -> Result<(), WireError> {
    let mut bounded = String::new();
    for char in message.chars() {
        if bounded.len() + char.len_utf8() > 256 {
            break;
        }
        bounded.push(char);
    }
    Frame::write(
        writer,
        Kind::Error,
        id,
        &ErrorReply {
            code: code.into(),
            message: bounded,
            retry_after_ms: None,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize, Serialize)]
    #[serde(deny_unknown_fields)]
    struct Ping {
        budget_ms: u16,
    }

    #[test]
    fn frame_round_trips_and_correlates() {
        let mut bytes = Vec::new();
        Frame::write(&mut bytes, Kind::Ping, [8; 16], &Ping { budget_ms: 255 }).unwrap();
        let frame = Frame::read(bytes.as_slice()).unwrap();
        assert_eq!(
            frame.expect::<Ping>(Kind::Ping, [8; 16]).unwrap().budget_ms,
            255
        );
        assert!(matches!(
            frame.expect::<Ping>(Kind::Ping, [9; 16]),
            Err(WireError::UnexpectedMessage)
        ));
    }

    #[test]
    fn size_is_validated_before_payload_read() {
        let mut bytes = Vec::new();
        Frame::write(&mut bytes, Kind::Ping, [7; 16], &Ping { budget_ms: 123 }).unwrap();
        bytes[8..12].copy_from_slice(&((MAX_PAYLOAD + 1) as u32).to_be_bytes());
        assert!(matches!(
            Frame::read(&bytes[..HEADER_SIZE]),
            Err(WireError::TooLarge)
        ));
    }

    #[test]
    fn malformed_flags_and_truncated_bodies_are_rejected() {
        let mut bytes = Vec::new();
        Frame::write(&mut bytes, Kind::Ping, [4; 16], &Ping { budget_ms: 123 }).unwrap();
        assert!(matches!(
            Frame::read(&bytes[..HEADER_SIZE]),
            Err(WireError::Io(_))
        ));
        bytes[7] = 1;
        assert!(matches!(
            Frame::read(bytes.as_slice()),
            Err(WireError::BadHeader)
        ));
    }
}

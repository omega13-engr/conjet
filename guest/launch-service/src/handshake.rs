use std::io::{Read, Write};

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::wire::{Frame, Kind, MAX_PAYLOAD, RequestId, VERSION, WireError, write_error};

pub const MAX_CONNECTIONS: usize = 10;
pub const MAX_QUEUED_CONTROL: usize = 8;
pub type Key = [u8; 32];
pub type BootId = [u8; 16];

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Hello {
    versions: Vec<u8>,
    client_nonce: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Challenge {
    version: u8,
    guest_nonce: String,
    boot_id: String,
    proof: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Authenticate {
    proof: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Capabilities {
    pub boot_id: String,
    pub capabilities: Vec<String>,
    pub limits: Limits,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    pub connections: usize,
    pub queued_control: usize,
    pub payload_bytes: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_workloads: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal_records: Option<usize>,
}

pub fn random<const N: usize>() -> Result<[u8; N], WireError> {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).map_err(|_| WireError::RandomUnavailable)?;
    Ok(bytes)
}

pub fn hex(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(ALPHABET[(byte >> 4) as usize] as char);
        encoded.push(ALPHABET[(byte & 15) as usize] as char);
    }
    encoded
}

pub fn unhex<const N: usize>(value: &str) -> Result<[u8; N], WireError> {
    fn digit(value: u8) -> Option<u8> {
        match value {
            b'0'..=b'9' => Some(value - b'0'),
            b'a'..=b'f' => Some(value - b'a' + 10),
            _ => None,
        }
    }
    if value.len() != N * 2 {
        return Err(WireError::InvalidPayload);
    }
    let mut bytes = [0; N];
    for (byte, pair) in bytes.iter_mut().zip(value.as_bytes().chunks_exact(2)) {
        *byte = digit(pair[0]).ok_or(WireError::InvalidPayload)? << 4
            | digit(pair[1]).ok_or(WireError::InvalidPayload)?;
    }
    Ok(bytes)
}

struct Transcript {
    id: RequestId,
    offered: Vec<u8>,
    client_nonce: [u8; 32],
    guest_nonce: [u8; 32],
    boot_id: BootId,
}

impl Transcript {
    fn mac(&self, key: &Key, role: u8) -> Hmac<Sha256> {
        let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("fixed SHA256 key");
        mac.update(b"CJLS1");
        mac.update(&[role, VERSION, self.offered.len() as u8]);
        mac.update(&self.offered);
        mac.update(&self.id);
        mac.update(&self.client_nonce);
        mac.update(&self.guest_nonce);
        mac.update(&self.boot_id);
        mac
    }

    fn proof(&self, key: &Key, role: u8) -> String {
        hex(&self.mac(key, role).finalize().into_bytes())
    }

    fn verify(&self, key: &Key, role: u8, proof: &str) -> Result<(), WireError> {
        let proof = unhex::<32>(proof).map_err(|_| WireError::Unauthorized)?;
        self.mac(key, role)
            .verify_slice(&proof)
            .map_err(|_| WireError::Unauthorized)
    }
}

pub fn guest(
    stream: &mut (impl Read + Write),
    key: &Key,
    boot_id: BootId,
    capabilities: &[&str],
) -> Result<(), WireError> {
    let frame = Frame::read(&mut *stream)?;
    if frame.kind != Kind::Hello {
        write_error(&mut *stream, frame.id, "unauthorized", "handshake required")?;
        return Err(WireError::Unauthorized);
    }
    let hello: Hello = match frame.decode() {
        Ok(hello) => hello,
        Err(error) => {
            write_error(&mut *stream, frame.id, "malformed", "invalid hello payload")?;
            return Err(error);
        }
    };
    if hello.versions.is_empty()
        || hello.versions.len() > 8
        || hello
            .versions
            .iter()
            .enumerate()
            .any(|(index, version)| hello.versions[..index].contains(version))
    {
        write_error(&mut *stream, frame.id, "malformed", "invalid version list")?;
        return Err(WireError::InvalidPayload);
    }
    if !hello.versions.contains(&VERSION) {
        write_error(
            &mut *stream,
            frame.id,
            "unsupported_version",
            "version 1 required",
        )?;
        return Err(WireError::UnsupportedVersion);
    }
    let transcript = Transcript {
        id: frame.id,
        offered: hello.versions,
        client_nonce: match unhex(&hello.client_nonce) {
            Ok(nonce) => nonce,
            Err(error) => {
                write_error(&mut *stream, frame.id, "malformed", "invalid nonce")?;
                return Err(error);
            }
        },
        guest_nonce: random()?,
        boot_id,
    };
    Frame::write(
        &mut *stream,
        Kind::Challenge,
        frame.id,
        &Challenge {
            version: VERSION,
            guest_nonce: hex(&transcript.guest_nonce),
            boot_id: hex(&boot_id),
            proof: transcript.proof(key, b'G'),
        },
    )?;
    let request = Frame::read(&mut *stream)?;
    let auth: Authenticate = match request.expect(Kind::Authenticate, frame.id) {
        Ok(auth) => auth,
        Err(error) => {
            write_error(
                &mut *stream,
                request.id,
                "malformed",
                "invalid authenticate payload",
            )?;
            return Err(error);
        }
    };
    if transcript.verify(key, b'H', &auth.proof).is_err() {
        write_error(&mut *stream, frame.id, "unauthorized", "invalid proof")?;
        return Err(WireError::Unauthorized);
    }
    let has_workload = ["fresh_arm64_fixture", "native_static_arm64_v1"]
        .iter()
        .any(|feature| capabilities.contains(feature));
    Frame::write(
        stream,
        Kind::HelloAck,
        frame.id,
        &Capabilities {
            boot_id: hex(&boot_id),
            capabilities: capabilities
                .iter()
                .map(|capability| (*capability).into())
                .collect(),
            limits: Limits {
                connections: MAX_CONNECTIONS,
                queued_control: MAX_QUEUED_CONTROL,
                payload_bytes: MAX_PAYLOAD,
                active_workloads: has_workload.then_some(1),
                terminal_records: has_workload.then_some(1),
            },
        },
    )
}

pub fn host(stream: &mut (impl Read + Write), key: &Key) -> Result<Capabilities, WireError> {
    let id = random()?;
    let client_nonce = random()?;
    let offered = vec![VERSION];
    Frame::write(
        &mut *stream,
        Kind::Hello,
        id,
        &Hello {
            versions: offered.clone(),
            client_nonce: hex(&client_nonce),
        },
    )?;
    let challenge: Challenge = Frame::read(&mut *stream)?.expect(Kind::Challenge, id)?;
    if challenge.version != VERSION {
        return Err(WireError::UnsupportedVersion);
    }
    let transcript = Transcript {
        id,
        offered,
        client_nonce,
        guest_nonce: unhex(&challenge.guest_nonce)?,
        boot_id: unhex(&challenge.boot_id)?,
    };
    transcript.verify(key, b'G', &challenge.proof)?;
    Frame::write(
        &mut *stream,
        Kind::Authenticate,
        id,
        &Authenticate {
            proof: transcript.proof(key, b'H'),
        },
    )?;
    let reply: Capabilities = Frame::read(stream)?.expect(Kind::HelloAck, id)?;
    if reply.boot_id != challenge.boot_id {
        return Err(WireError::Unauthorized);
    }
    Ok(reply)
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;
    use std::thread;
    use std::time::Duration;

    use super::*;

    #[test]
    fn transcript_matches_v1_wire_vector() {
        let transcript = Transcript {
            id: [6; 16],
            offered: vec![1],
            client_nonce: [5; 32],
            guest_nonce: [4; 32],
            boot_id: [3; 16],
        };
        assert_eq!(
            transcript.proof(&[7; 32], b'G'),
            "572a70b53ebdef8d37ffed7ce6cc5a4c8f7a7637d015a0179de7453b8363f3f9"
        );
    }

    #[test]
    fn verifies_both_peers_over_a_persistent_stream() {
        let (mut server, mut client) = UnixStream::pair().unwrap();
        for io in [&server, &client] {
            io.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        }
        let worker = thread::spawn(move || guest(&mut server, &[7; 32], [3; 16], &["ping"]));
        let advertised = host(&mut client, &[7; 32]).unwrap();
        assert_eq!(advertised.boot_id, hex(&[3; 16]));
        assert_eq!(advertised.capabilities, ["ping"]);
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn host_rejects_untrusted_guest_before_sending_proof() {
        let (mut server, mut client) = UnixStream::pair().unwrap();
        let worker = thread::spawn(move || guest(&mut server, &[7; 32], [3; 16], &["ping"]));
        assert!(matches!(
            host(&mut client, &[8; 32]),
            Err(WireError::Unauthorized)
        ));
        drop(client);
        assert!(matches!(worker.join().unwrap(), Err(WireError::Io(_))));
    }

    #[test]
    fn guest_rejects_replayed_proof_from_another_nonce() {
        let (mut server, mut client) = UnixStream::pair().unwrap();
        let worker = thread::spawn(move || guest(&mut server, &[7; 32], [3; 16], &[]));
        let id = [6; 16];
        Frame::write(
            &mut client,
            Kind::Hello,
            id,
            &Hello {
                versions: vec![1],
                client_nonce: hex(&[5; 32]),
            },
        )
        .unwrap();
        let challenge: Challenge = Frame::read(&mut client)
            .unwrap()
            .expect(Kind::Challenge, id)
            .unwrap();
        let stale = Transcript {
            id,
            offered: vec![VERSION],
            client_nonce: [4; 32],
            guest_nonce: unhex(&challenge.guest_nonce).unwrap(),
            boot_id: [3; 16],
        };
        Frame::write(
            &mut client,
            Kind::Authenticate,
            id,
            &Authenticate {
                proof: stale.proof(&[7; 32], b'H'),
            },
        )
        .unwrap();
        let reply = Frame::read(&mut client).unwrap();
        assert!(matches!(reply.expect::<Capabilities>(Kind::HelloAck, id),
                         Err(WireError::PeerError(code)) if code == "unauthorized"));
        assert!(matches!(
            worker.join().unwrap(),
            Err(WireError::Unauthorized)
        ));
    }
}

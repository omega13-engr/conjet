use std::time::Instant;

use serde::Serialize;

const FRAME_LEN: usize = 60;
const MAX_RECORDS: usize = 16;

pub const PORT: u32 = 1029;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Event {
    ControlReady,
    LegacyProcessStarted,
    ChildCreated,
    ExecConfirmed,
    ApplicationReady,
    ExecFailed,
    ProcessExited,
}

#[derive(Debug, Clone, Serialize)]
pub struct Record {
    pub event: Event,
    pub status: u16,
    pub code: u32,
    pub boot_id_hash: u64,
    pub guest_monotonic_ns: u64,
    pub host_offset_ns: u64,
}

#[derive(Debug)]
pub struct Trace {
    started: Instant,
    records: Vec<Record>,
    frame: [u8; FRAME_LEN],
    received: usize,
}

impl Trace {
    pub fn new(started: Instant) -> Self {
        Self {
            started,
            records: Vec::new(),
            frame: [0; FRAME_LEN],
            received: 0,
        }
    }

    pub fn reset_stream(&mut self) {
        self.received = 0;
    }

    pub fn receive(&mut self, mut data: &[u8]) -> bool {
        while !data.is_empty() {
            if self.records.len() == MAX_RECORDS {
                return false;
            }
            let count = data.len().min(FRAME_LEN - self.received);
            self.frame[self.received..self.received + count].copy_from_slice(&data[..count]);
            self.received += count;
            data = &data[count..];
            if self.received == FRAME_LEN {
                let Some(record) = decode(&self.frame, self.started) else {
                    self.reset_stream();
                    return false;
                };
                self.records.push(record);
                self.reset_stream();
            }
        }
        true
    }

    pub fn take_records(&mut self) -> Vec<Record> {
        std::mem::take(&mut self.records)
    }
}

fn decode(frame: &[u8; FRAME_LEN], started: Instant) -> Option<Record> {
    let short = |offset| u16::from_le_bytes(frame[offset..offset + 2].try_into().unwrap());
    let word = |offset| u32::from_le_bytes(frame[offset..offset + 4].try_into().unwrap());
    let wide = |offset| u64::from_le_bytes(frame[offset..offset + 8].try_into().unwrap());
    if word(0) != 0x4356_534f
        || short(4) != 1
        || short(6) != 8
        || word(8) != 32
        || !matches!(word(12), 3 | u32::MAX)
        || word(16) != PORT
        || word(20) != 2
        || word(24) != PORT
        || word(28) != 0x4352_4459
        || short(32) != 1
        || short(38) != 0
    {
        return None;
    }

    let event = match short(34) {
        1 => Event::ControlReady,
        2 => Event::LegacyProcessStarted,
        3 => Event::ChildCreated,
        4 => Event::ExecConfirmed,
        5 => Event::ApplicationReady,
        6 => Event::ExecFailed,
        7 => Event::ProcessExited,
        _ => return None,
    };
    let status = short(36);
    if status > 1 {
        return None;
    }
    Some(Record {
        event,
        status,
        code: word(56),
        boot_id_hash: wide(40),
        guest_monotonic_ns: wide(48),
        host_offset_ns: started.elapsed().as_nanos().min(u128::from(u64::MAX)) as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(event: u16) -> [u8; FRAME_LEN] {
        let mut bytes = [0; FRAME_LEN];
        for (offset, value) in [
            (0, 0x4356_534fu32),
            (8, 32),
            (12, 3),
            (16, PORT),
            (20, 2),
            (24, PORT),
            (28, 0x4352_4459),
            (56, 13),
        ] {
            bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        for (offset, value) in [(4, 1u16), (6, 8), (32, 1), (34, event), (36, 1)] {
            bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
        }
        bytes[48..56].copy_from_slice(&42u64.to_le_bytes());
        bytes
    }

    #[test]
    fn receives_split_and_coalesced_frames_without_upgrading_the_legacy_event() {
        let mut trace = Trace::new(Instant::now());
        let legacy = frame(2);
        assert!(trace.receive(&legacy[..13]));
        assert!(trace.take_records().is_empty());
        assert!(trace.receive(&[&legacy[13..], &frame(6)].concat()));
        let records = trace.take_records();
        assert_eq!(records[0].event, Event::LegacyProcessStarted);
        assert_eq!(records[1].event, Event::ExecFailed);
        assert_eq!(records[1].code, 13);
        assert_eq!(records[1].guest_monotonic_ns, 42);
        assert!(records[1].host_offset_ns >= records[0].host_offset_ns);
    }

    #[test]
    fn rejects_corrupt_frames_and_limits_retained_records() {
        let mut trace = Trace::new(Instant::now());
        let mut invalid = frame(3);
        invalid[8] = 255;
        assert!(!trace.receive(&invalid));
        for _ in 0..MAX_RECORDS {
            assert!(trace.receive(&frame(3)));
        }
        assert!(!trace.receive(&frame(3)));
        assert_eq!(trace.take_records().len(), MAX_RECORDS);
    }
}

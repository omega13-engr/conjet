use std::time::{Duration, Instant};

pub(crate) const SLOT_TTL: Duration = Duration::from_secs(5);
pub(crate) const SLOT_MEMORY_LIMIT: u64 = 32 * 1024 * 1024;
pub(crate) const CANCEL: u8 = 1;
pub(crate) const TERMINATE: u8 = 3;
pub(crate) const RELEASE: u8 = 2;

#[derive(PartialEq, Eq)]
enum State {
    Preparing,
    Ready { expires: Instant },
    Claimed,
    Discarded,
}

pub(crate) struct Slot {
    digest: [u8; 32],
    state: State,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ClaimError {
    Unavailable,
    Mismatch,
}

impl Slot {
    pub(crate) fn new(digest: [u8; 32]) -> Self {
        Self {
            digest,
            state: State::Preparing,
        }
    }

    pub(crate) fn ready(&mut self, expires: Instant) {
        if self.state == State::Preparing {
            self.state = State::Ready { expires };
        }
    }

    pub(crate) fn claim(&mut self, digest: [u8; 32], now: Instant) -> Result<(), ClaimError> {
        let State::Ready { expires } = self.state else {
            return Err(ClaimError::Unavailable);
        };
        if now >= expires {
            self.discard();
            return Err(ClaimError::Unavailable);
        }
        if self.digest != digest {
            return Err(ClaimError::Mismatch);
        }
        self.state = State::Claimed;
        Ok(())
    }

    pub(crate) fn discard(&mut self) {
        if self.state != State::Claimed {
            self.state = State::Discarded;
        }
    }

    pub(crate) fn claimed(&self) -> bool {
        self.state == State::Claimed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Barrier, Mutex};

    #[test]
    fn only_one_concurrent_claim_consumes_a_ready_slot() {
        let now = Instant::now();
        let mut slot = Slot::new([7; 32]);
        slot.ready(now + SLOT_TTL);
        let slot = Mutex::new(slot);
        let barrier = Barrier::new(8);
        let count = std::thread::scope(|scope| {
            let mut claims = Vec::new();
            for _ in 0..8 {
                claims.push(scope.spawn(|| {
                    barrier.wait();
                    slot.lock().unwrap().claim([7; 32], now).is_ok()
                }));
            }
            claims
                .into_iter()
                .map(|claim| usize::from(claim.join().unwrap()))
                .sum::<usize>()
        });
        assert_eq!(count, 1);
        assert!(slot.lock().unwrap().claimed());
    }

    #[test]
    fn slot_requires_matching_spec_readiness_and_live_lifetime() {
        let now = Instant::now();
        let mut slot = Slot::new([7; 32]);
        assert_eq!(slot.claim([7; 32], now), Err(ClaimError::Unavailable));
        slot.ready(now + SLOT_TTL);
        assert_eq!(slot.claim([8; 32], now), Err(ClaimError::Mismatch));
        assert_eq!(
            slot.claim([7; 32], now + SLOT_TTL),
            Err(ClaimError::Unavailable)
        );
        slot.ready(now + SLOT_TTL * 2);
        assert_eq!(slot.claim([7; 32], now), Err(ClaimError::Unavailable));
        let mut slot = Slot::new([7; 32]);
        slot.discard();
        slot.ready(now + SLOT_TTL);
        assert_eq!(slot.claim([7; 32], now), Err(ClaimError::Unavailable));
        assert_eq!(SLOT_MEMORY_LIMIT, 32 * 1024 * 1024);
        assert_ne!(CANCEL, RELEASE);
    }
}

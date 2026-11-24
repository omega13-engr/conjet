use std::sync::Mutex;
use std::time::{Duration, Instant};

use conjet_launch_service::core_admission::{Admission, Observation, CAPACITY};
use conjet_launch_service::handshake::unhex;

const MAX_AGE: Duration = Duration::from_millis(250);

#[derive(Debug)]
struct Sample {
    seen: Instant,
    owned: usize,
    pending: Vec<Admission>,
    allowed: bool,
}

/// Connects a boot-scoped authenticated guest poller to the VMM's Core policy.
#[derive(Debug, Default)]
pub struct NativeMemoryAdmission(Mutex<Option<Sample>>);

impl NativeMemoryAdmission {
    pub fn publish(&self, report: Observation, now: Instant) -> bool {
        let valid = report.owned <= CAPACITY
            && report.pending.len() <= report.owned
            && report.pending.iter().enumerate().all(|(index, admission)| {
                admission.sequence > 0
                    && unhex::<16>(&admission.workload_id).is_ok()
                    && !report.pending[..index].iter().any(|earlier| {
                        earlier.sequence == admission.sequence
                            || earlier.workload_id == admission.workload_id
                    })
            });
        let mut sample = self.0.lock().expect("native memory admission");
        if sample.as_ref().is_some_and(|last| now <= last.seen) {
            return false;
        }
        *sample = valid.then_some(Sample {
            seen: now,
            owned: report.owned,
            pending: report.pending,
            allowed: false,
        });
        valid
    }

    pub fn invalidate(&self) {
        *self.0.lock().expect("native memory admission") = None;
    }

    pub(super) fn observe(&self, now: Instant) -> Option<(Instant, usize, bool)> {
        let sample = self.0.lock().expect("native memory admission");
        let sample = sample
            .as_ref()
            .filter(|sample| now.saturating_duration_since(sample.seen) < MAX_AGE)?;
        Some((
            sample.seen,
            sample.owned,
            !sample.pending.is_empty() && !sample.allowed,
        ))
    }

    pub(super) fn allow(&self, seen: Instant) {
        if let Some(current) = &mut *self.0.lock().expect("native memory admission") {
            if current.seen == seen {
                current.allowed = true;
            }
        }
    }

    pub fn take_grants(&self, now: Instant) -> Vec<Admission> {
        let mut sample = self.0.lock().expect("native memory admission");
        sample
            .as_mut()
            .filter(|sample| sample.allowed && now.saturating_duration_since(sample.seen) < MAX_AGE)
            .map(|sample| std::mem::take(&mut sample.pending))
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending(sequence: u64) -> Observation {
        Observation {
            owned: 1,
            pending: vec![Admission {
                workload_id: "01".repeat(16),
                sequence,
            }],
        }
    }

    #[test]
    fn a_grant_requires_the_current_sample_and_expires() {
        let now = Instant::now();
        let later = now + Duration::from_millis(1);
        let gate = NativeMemoryAdmission::default();
        assert!(gate.observe(now).is_none());
        assert!(gate.publish(pending(1), now));
        assert!(gate.take_grants(now).is_empty());
        assert!(gate.publish(pending(2), later));
        assert!(!gate.publish(pending(1), now));
        gate.allow(now);
        assert!(gate.take_grants(later).is_empty());
        gate.allow(later);
        assert_eq!(gate.take_grants(later)[0].sequence, 2);
        assert!(gate.take_grants(later).is_empty());
        assert_eq!(gate.observe(later), Some((later, 1, false)));
        assert!(gate.observe(later + MAX_AGE).is_none());
    }

    #[test]
    fn malformed_and_lost_telemetry_cannot_make_a_grant() {
        let now = Instant::now();
        let gate = NativeMemoryAdmission::default();
        assert!(gate.publish(pending(1), now));
        gate.allow(now);
        let next = now + Duration::from_millis(1);
        let mut invalid = pending(2);
        invalid.owned = 0;
        assert!(!gate.publish(invalid, next));
        assert!(gate.observe(next).is_none());
        assert!(gate.take_grants(next).is_empty());
        assert!(gate.publish(pending(2), next));
        gate.allow(next);
        gate.invalidate();
        assert!(gate.take_grants(next).is_empty());
        assert!(gate.observe(next).is_none());
    }
}

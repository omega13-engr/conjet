use std::fmt;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use conjet_launch_service::core_admission::{Admission, Observation, CAPACITY};
use conjet_launch_service::handshake::unhex;

const MAX_AGE: Duration = Duration::from_millis(250);

#[derive(Debug)]
struct Sample {
    seen: Instant,
    owned: usize,
    pending: Vec<Admission>,
    approved_at: Option<Instant>,
    first_evaluated_at: Option<Instant>,
    capacity_held: bool,
}

pub struct Grant {
    pub admission: Admission,
    pub observed_at: Instant,
    pub approved_at: Instant,
    pub first_evaluated_at: Option<Instant>,
    pub capacity_held: bool,
}

/// Connects a boot-scoped authenticated guest poller to the VMM's Core policy.
#[derive(Debug, Default)]
pub struct NativeMemoryAdmission {
    sample: Mutex<Option<Sample>>,
    approval: Condvar,
    trace: bool,
    wake_on_pending: bool,
    controller_wake: ControllerWake,
}

#[derive(Default)]
struct ControllerWake {
    callback: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
}

impl fmt::Debug for ControllerWake {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ControllerWake")
            .finish_non_exhaustive()
    }
}

pub(super) struct WakeRegistration<'a>(&'a ControllerWake);

impl Drop for WakeRegistration<'_> {
    fn drop(&mut self) {
        // Synchronize with any in-flight callback before the VM releases IDs.
        self.0
            .callback
            .lock()
            .expect("native controller wake")
            .take();
    }
}

impl NativeMemoryAdmission {
    pub fn new(trace: bool, wake_on_pending: bool) -> Self {
        Self {
            trace,
            wake_on_pending,
            ..Self::default()
        }
    }

    pub(super) fn register_controller_wake(
        &self,
        callback: impl Fn() + Send + Sync + 'static,
    ) -> Option<WakeRegistration<'_>> {
        if !self.wake_on_pending {
            return None;
        }
        let mut wake = self
            .controller_wake
            .callback
            .lock()
            .expect("native controller wake");
        assert!(wake.is_none(), "only one VM owns the controller wake");
        *wake = Some(Box::new(callback));
        Some(WakeRegistration(&self.controller_wake))
    }

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
        let mut sample = self.sample.lock().expect("native memory admission");
        if sample.as_ref().is_some_and(|last| now <= last.seen) {
            return false;
        }
        let wake = self.wake_on_pending
            && valid
            && report.pending.iter().any(|request| {
                sample.as_ref().is_none_or(|last| {
                    now.saturating_duration_since(last.seen) >= MAX_AGE
                        || !last.pending.contains(request)
                })
            });
        *sample = valid.then_some(Sample {
            seen: now,
            owned: report.owned,
            pending: report.pending,
            approved_at: None,
            first_evaluated_at: None,
            capacity_held: false,
        });
        drop(sample);
        if wake {
            let callback = self
                .controller_wake
                .callback
                .lock()
                .expect("native controller wake");
            if let Some(callback) = callback.as_ref() {
                callback();
            }
        }
        valid
    }

    pub fn invalidate(&self) {
        *self.sample.lock().expect("native memory admission") = None;
    }

    pub(super) fn observe(&self, now: Instant) -> Option<(Instant, usize, bool)> {
        let mut sample = self.sample.lock().expect("native memory admission");
        let sample = sample
            .as_mut()
            .filter(|sample| now.saturating_duration_since(sample.seen) < MAX_AGE)?;
        let pending = !sample.pending.is_empty() && sample.approved_at.is_none();
        if self.trace && pending {
            sample.first_evaluated_at.get_or_insert_with(Instant::now);
        }
        Some((sample.seen, sample.owned, pending))
    }

    pub(super) fn note_capacity_hold(&self, seen: Instant) {
        if self.trace {
            let mut sample = self.sample.lock().expect("native memory admission");
            if let Some(current) = sample.as_mut().filter(|current| current.seen == seen) {
                current.capacity_held = true;
            }
        }
    }

    pub(super) fn allow(&self, seen: Instant) {
        let mut sample = self.sample.lock().expect("native memory admission");
        let Some(current) = sample.as_mut().filter(|current| current.seen == seen) else {
            return;
        };
        if current.approved_at.is_none() {
            current.approved_at = Some(Instant::now());
            self.approval.notify_one();
        }
    }

    pub fn wait_for_approval(&self, interval: Duration) {
        let sample = self.sample.lock().expect("native memory admission");
        // With an empty sample this remains the normal observation cadence.
        // If a grant is already queued, checking the predicate under the lock
        // prevents losing a notification sent just before this wait.
        let _ = self
            .approval
            .wait_timeout_while(sample, interval, |sample| {
                !sample
                    .as_ref()
                    .is_some_and(|s| s.approved_at.is_some() && !s.pending.is_empty())
            })
            .expect("native memory admission");
    }

    pub fn take_grants(&self, now: Instant) -> Vec<Grant> {
        let mut sample = self.sample.lock().expect("native memory admission");
        sample
            .as_mut()
            .filter(|sample| now.saturating_duration_since(sample.seen) < MAX_AGE)
            .and_then(|sample| {
                let approved_at = sample.approved_at?;
                let observed_at = sample.seen;
                let first_evaluated_at = sample.first_evaluated_at;
                let capacity_held = sample.capacity_held;
                Some(
                    std::mem::take(&mut sample.pending)
                        .into_iter()
                        .map(|admission| Grant {
                            admission,
                            observed_at,
                            approved_at,
                            first_evaluated_at,
                            capacity_held,
                        })
                        .collect(),
                )
            })
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
        assert_eq!(gate.take_grants(later)[0].admission.sequence, 2);
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

    #[test]
    fn traced_grant_distinguishes_first_evaluation_and_capacity_hold() {
        let gate = NativeMemoryAdmission::new(true, false);
        let seen = Instant::now();
        assert!(gate.publish(pending(1), seen));
        assert_eq!(gate.observe(Instant::now()), Some((seen, 1, true)));
        gate.note_capacity_hold(seen);
        gate.allow(seen);
        let grant = gate.take_grants(Instant::now()).pop().unwrap();
        let evaluated = grant.first_evaluated_at.unwrap();
        assert!(seen <= evaluated && evaluated <= grant.approved_at);
        assert!(grant.capacity_held);
    }

    #[test]
    fn wake_only_hints_fresh_pending_generation_and_stops_when_unregistered() {
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        let gate = NativeMemoryAdmission::new(false, true);
        let wakes = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&wakes);
        let registration = gate
            .register_controller_wake(move || {
                count.fetch_add(1, Ordering::Relaxed);
            })
            .unwrap();
        let now = Instant::now();
        let at = |ms| now + Duration::from_millis(ms);
        assert!(gate.publish(
            Observation {
                owned: 0,
                pending: vec![]
            },
            now
        ));
        assert!(gate.publish(pending(1), at(1)));
        assert!(gate.publish(pending(1), at(2)));
        assert!(!gate.publish(pending(2), at(1)));
        assert!(gate.take_grants(at(2)).is_empty());
        assert_eq!(wakes.load(Ordering::Relaxed), 1);
        let mut malformed = pending(2);
        malformed.owned = 0;
        assert!(!gate.publish(malformed, at(3)));
        assert!(gate.publish(pending(2), at(4)));
        assert_eq!(wakes.load(Ordering::Relaxed), 2);
        drop(registration);
        assert!(gate.publish(pending(3), at(5)));
        assert_eq!(wakes.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn approval_wakes_the_consumer_without_waiting_for_the_poll_interval() {
        let now = Instant::now();
        let gate = NativeMemoryAdmission::default();
        assert!(gate.publish(pending(1), now));
        let (ready, wait) = std::sync::mpsc::channel();
        let (delivered, result) = std::sync::mpsc::channel();
        std::thread::scope(|threads| {
            let gate = &gate;
            threads.spawn(move || {
                ready.send(()).unwrap();
                gate.wait_for_approval(Duration::from_secs(3));
                delivered.send(gate.take_grants(now).len()).unwrap();
            });
            wait.recv().unwrap();
            gate.allow(now);
            assert_eq!(result.recv_timeout(Duration::from_secs(1)).unwrap(), 1);
        });
    }
}

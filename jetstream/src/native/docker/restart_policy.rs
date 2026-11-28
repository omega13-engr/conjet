use std::time::Duration;

use serde_json::Value;

use super::{request, Rejected};

#[derive(Clone, Copy, Default, Eq, PartialEq)]
pub(super) enum Policy {
    #[default]
    No,
    Always,
    UnlessStopped,
    OnFailure(u32),
}

impl Policy {
    pub(super) fn parse(configured: &Value) -> Result<Self, Rejected> {
        if let Some(fields) = request::object(configured, "restart policy")? {
            request::options(fields, &["Name", "MaximumRetryCount"], "restart policy ")?;
        }
        let retry = match &configured["MaximumRetryCount"] {
            Value::Null => 0,
            value => value
                .as_u64()
                .and_then(|count| i32::try_from(count).ok())
                .ok_or_else(|| Rejected::bad("invalid maximum restart retry count"))?
                as u32,
        };
        match &configured["Name"] {
            Value::Null if retry == 0 => Ok(Self::No),
            Value::String(name) => match (name.as_str(), retry) {
                ("" | "no", 0) => Ok(Self::No),
                ("always", 0) => Ok(Self::Always),
                ("unless-stopped", 0) => Ok(Self::UnlessStopped),
                ("on-failure", count) => Ok(Self::OnFailure(count)),
                _ => Err(Rejected::bad("invalid Docker restart policy")),
            },
            _ => Err(Rejected::bad("invalid Docker restart policy")),
        }
    }

    pub(super) fn after_exit(self, code: i64, retries: u64) -> bool {
        match self {
            Self::No => false,
            Self::Always | Self::UnlessStopped => true,
            Self::OnFailure(limit) => code != 0 && (limit == 0 || retries < u64::from(limit)),
        }
    }

    pub(super) fn after_daemon_restart(self, started: bool, manually_stopped: bool) -> bool {
        started && (self == Self::Always || (self == Self::UnlessStopped && !manually_stopped))
    }
}

pub(super) fn backoff(previous: Duration, runtime: Duration) -> Duration {
    if previous.is_zero() || runtime >= Duration::from_secs(10) {
        Duration::from_millis(100)
    } else {
        previous.saturating_mul(2).min(Duration::from_secs(60))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn policies_distinguish_exit_manual_stop_and_daemon_restart() {
        let always = Policy::Always;
        let unless = Policy::UnlessStopped;
        let failure = Policy::parse(&json!({"Name":"on-failure", "MaximumRetryCount":1})).unwrap();
        assert!(always.after_exit(0, 10) && always.after_daemon_restart(true, true));
        assert!(unless.after_exit(0, 10) && unless.after_daemon_restart(true, false));
        assert!(!unless.after_daemon_restart(true, true));
        assert!(!always.after_daemon_restart(false, false));
        assert!(failure.after_exit(4, 0));
        assert!(!failure.after_exit(4, 1));
        assert!(!failure.after_exit(0, 0));
        assert!(!failure.after_daemon_restart(true, false));
        assert!(Policy::parse(&json!({"Name":"always", "MaximumRetryCount":1})).is_err());
        assert!(Policy::parse(&json!({"Name":"on-failure", "MaximumRetryCount":-1})).is_err());
    }

    #[test]
    fn rapid_failure_backoff_is_bounded_and_resets_after_a_stable_run() {
        assert_eq!(
            backoff(Duration::ZERO, Duration::ZERO),
            Duration::from_millis(100)
        );
        assert_eq!(
            backoff(Duration::from_millis(100), Duration::ZERO),
            Duration::from_millis(200)
        );
        assert_eq!(
            backoff(Duration::from_secs(59), Duration::ZERO),
            Duration::from_secs(60)
        );
        assert_eq!(
            backoff(Duration::from_secs(1), Duration::from_secs(10)),
            Duration::from_millis(100)
        );
    }
}

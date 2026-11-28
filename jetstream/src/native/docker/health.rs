use std::time::{Duration, Instant};

use conjet_launch_service::spec::LaunchSpec;
use serde_json::{json, Value};

use super::{exec, request, Item, Owner, Rejected};

pub(super) struct Config {
    pub argv: Vec<String>,
    pub budget_ms: u64,
    interval: Duration,
    retries: u64,
}

impl Config {
    pub(super) fn parse(raw: &Value, process: &Value) -> Result<Option<Self>, Rejected> {
        let Some(fields) = request::object(raw, "Docker healthcheck")? else {
            return Ok(None);
        };
        if fields.is_empty() {
            return Ok(None);
        }
        request::options(
            fields,
            &["Test", "Interval", "Timeout", "Retries"],
            "healthcheck ",
        )?;
        let test = raw["Test"]
            .as_array()
            .ok_or_else(|| Rejected::bad("invalid Docker healthcheck Test"))?;
        let Some((head, argv)) = test.split_first() else {
            return Err(Rejected::bad(
                "Docker healthcheck requires an explicit command",
            ));
        };
        if head == "NONE" && argv.is_empty() {
            return Ok(None);
        }
        if !matches!(head.as_str(), Some("CMD" | "CMD-SHELL")) || argv.is_empty() {
            return Err(Rejected::bad("invalid Docker healthcheck command"));
        }
        if head == "CMD-SHELL" && (argv.len() != 1 || !argv[0].is_string()) {
            return Err(Rejected::bad(
                "CMD-SHELL healthcheck requires one command string",
            ));
        }
        let mut spec: LaunchSpec = serde_json::from_value(process.clone())
            .map_err(|_| Rejected::internal("cannot read native healthcheck process defaults"))?;
        spec.redis_bootstrap = false;
        spec.argv = argv
            .iter()
            .map(|part| {
                part.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| Rejected::bad("invalid Docker healthcheck argument"))
            })
            .collect::<Result<_, _>>()?;
        if head == "CMD-SHELL" {
            spec.argv.splice(..0, ["/bin/sh".into(), "-c".into()]);
        }
        spec.validate_exec()
            .map_err(|error| Rejected::bad(error.to_string()))?;
        let duration = |key: &str, fallback: u64, max: u64| {
            if raw[key].is_null() || raw[key] == 0 {
                return Ok(Duration::from_nanos(fallback));
            }
            raw[key]
                .as_u64()
                .filter(|value| (100_000_000..=max).contains(value))
                .map(Duration::from_nanos)
                .ok_or_else(|| {
                    Rejected::bad(format!(
                        "native healthcheck {key} exceeds its supported window"
                    ))
                })
        };
        let interval = duration("Interval", 30_000_000_000, 30_000_000_000)?;
        let timeout = duration("Timeout", 30_000_000_000, 30_000_000_000)?;
        let retries = match &raw["Retries"] {
            Value::Null => 3,
            value if value == &json!(0) => 3,
            value => value
                .as_u64()
                .filter(|value| (1..=12).contains(value))
                .ok_or_else(|| Rejected::bad("invalid native healthcheck retry count"))?,
        };
        Ok(Some(Self {
            argv: spec.argv,
            budget_ms: timeout.as_millis() as u64,
            interval,
            retries,
        }))
    }
}

pub(super) struct State {
    next: Instant,
    failures: u64,
    status: &'static str,
}

impl State {
    pub(super) fn starting(now: Instant) -> Self {
        Self {
            next: now,
            failures: 0,
            status: "starting",
        }
    }

    pub(super) fn due(&self, now: Instant) -> bool {
        now >= self.next
    }

    pub(super) fn record(&mut self, now: Instant, config: &Config, healthy: bool) {
        self.next = now + config.interval;
        if healthy {
            self.failures = 0;
            self.status = "healthy";
        } else {
            self.failures = self.failures.saturating_add(1);
            if self.failures >= config.retries {
                self.status = "unhealthy";
            }
        }
    }

    pub(super) fn inspect(&self) -> Value {
        json!({"Status":self.status,"FailingStreak":self.failures,"Log":[]})
    }
}

pub(super) fn probe(owner: &Owner, item: &Item, generation: u64, handle: &Value) {
    let Some(config) = item.container.healthcheck.as_ref() else {
        return;
    };
    {
        let state = item.state();
        if state.generation != generation
            || !state
                .health
                .as_ref()
                .is_some_and(|health| health.due(Instant::now()))
        {
            return;
        }
    }
    let healthy = exec::execute(
        owner,
        handle.clone(),
        &config.argv,
        [false, false],
        None,
        None,
        config.budget_ms,
    )
    .is_ok_and(|(code, result)| code == 0 && result.error.is_none());
    let mut state = item.state();
    if state.generation == generation {
        if let Some(health) = &mut state.health {
            health.record(Instant::now(), config, healthy);
            item.changed.notify_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compose_shell_healthcheck_preserves_command_and_timeout() {
        let process = json!({"image_digest":format!("sha256:{}", "a".repeat(64)),
            "argv":["/bin/true"], "env":[], "cwd":"/", "uid":0,"gid":0,
            "network":"none", "limits":{"memory_bytes":16777216,"pids":4,"cpu_millicores":500}});
        let config = Config::parse(
            &json!({"Test":["CMD-SHELL", "pg_isready -U artex -d artex"],
            "Interval":5_000_000_000u64,"Timeout":3_000_000_000u64,"Retries":10}),
            &process,
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            config.argv,
            ["/bin/sh", "-c", "pg_isready -U artex -d artex"]
        );
        assert_eq!(config.budget_ms, 3000);
        assert!(Config::parse(&json!({"Test":["NONE"]}), &process)
            .unwrap()
            .is_none());
        assert!(Config::parse(&json!({"Test":["CMD-SHELL", "true", "extra"]}), &process).is_err());
        assert!(Config::parse(
            &json!({"Test":["CMD", "true"],"Timeout":30_000_000_001u64}),
            &process
        )
        .is_err());
    }

    #[test]
    fn health_generation_starts_fresh_and_requires_the_retry_threshold() {
        let now = Instant::now();
        let config = Config {
            argv: vec!["/bin/true".into()],
            budget_ms: 1,
            interval: Duration::from_millis(100),
            retries: 2,
        };
        let mut state = State::starting(now);
        assert!(state.due(now));
        state.record(now, &config, false);
        assert_eq!(state.inspect()["Status"], "starting");
        assert!(!state.due(now));
        state.record(now, &config, false);
        assert_eq!(state.inspect()["Status"], "unhealthy");
        state.record(now, &config, true);
        assert_eq!(state.inspect()["Status"], "healthy");
        assert_eq!(State::starting(now).inspect()["FailingStreak"], 0);
    }
}

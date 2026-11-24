use std::collections::BTreeMap;
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;

use super::{discovery, Owner, Rejected};

pub(super) fn daemon_time() -> Result<String, Rejected> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Rejected::internal("host clock is before the Unix epoch"))?;
    let seconds = now
        .as_secs()
        .try_into()
        .map_err(|_| Rejected::internal("host clock is out of range"))?;
    let mut time = std::mem::MaybeUninit::<libc::tm>::uninit();
    if unsafe { libc::gmtime_r(&seconds, time.as_mut_ptr()) }.is_null() {
        return Err(Rejected::internal("could not read UTC daemon time"));
    }
    let time = unsafe { time.assume_init() };
    Ok(format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:09}Z",
        time.tm_year + 1900,
        time.tm_mon + 1,
        time.tm_mday,
        time.tm_hour,
        time.tm_min,
        time.tm_sec,
        now.subsec_nanos()
    ))
}

fn epoch_ns(value: &str) -> Option<u128> {
    let (seconds, fractional) = value.split_once('.').unwrap_or((value, ""));
    let seconds = seconds.parse::<u64>().ok()?;
    if fractional.len() > 9 || !fractional.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let nanos = fractional.parse::<u32>().unwrap_or(0) * 10u32.pow(9 - fractional.len() as u32);
    Some(u128::from(seconds) * 1_000_000_000 + u128::from(nanos))
}

pub(super) struct Subscription {
    filters: BTreeMap<String, Vec<String>>,
    since: Option<u128>,
    until: Option<u128>,
}

impl Subscription {
    pub(super) fn parse(query: &BTreeMap<String, String>) -> Result<Self, Rejected> {
        if query
            .keys()
            .any(|key| !matches!(key.as_str(), "filters" | "since" | "until"))
        {
            return Err(Rejected::bad("unsupported Docker event query"));
        }
        let filters = discovery::parse_filters(query.get("filters"))?;
        for key in filters.keys() {
            if !matches!(key.as_str(), "type" | "event" | "container" | "label") {
                return Err(Rejected::bad(format!(
                    "unsupported Docker event filter {key}"
                )));
            }
        }
        let time = |field| {
            query
                .get(field)
                .map(|value| {
                    epoch_ns(value).ok_or_else(|| {
                        Rejected::bad(format!("invalid Docker event {field} timestamp"))
                    })
                })
                .transpose()
        };
        Ok(Self {
            filters,
            since: time("since")?,
            until: time("until")?,
        })
    }

    fn matches(&self, event: &Value) -> bool {
        let attribute = &event["Actor"]["Attributes"];
        self.filters.iter().all(|(key, terms)| {
            terms.is_empty()
                || match key.as_str() {
                    "type" => terms.iter().any(|value| event["Type"] == value.as_str()),
                    "event" => terms.iter().any(|value| event["Action"] == value.as_str()),
                    "container" => terms.iter().any(|value| {
                        attribute["name"] == value.as_str()
                            || event["Actor"]["ID"]
                                .as_str()
                                .is_some_and(|id| id.starts_with(value))
                    }),
                    "label" => discovery::labels_match(terms, attribute),
                    _ => false,
                }
        })
    }

    pub(super) fn stream(self, owner: &Owner, writer: &mut UnixStream) -> io::Result<()> {
        let mut ledger = owner.ledger.lock().unwrap();
        let mut cursor = ledger.discarded_events
            + if self.since.is_some() {
                0
            } else {
                ledger.events.len()
            };
        let mut client = libc::pollfd {
            fd: writer.as_raw_fd(),
            events: 0,
            revents: 0,
        };
        while !ledger.closing {
            if self.until.is_some_and(|until| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .is_ok_and(|now| now.as_nanos() >= until)
            }) {
                break;
            }
            if unsafe { libc::poll(&mut client, 1, 0) } > 0
                && client.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
            {
                break;
            }
            let index = cursor.checked_sub(ledger.discarded_events).ok_or_else(|| {
                io::Error::other("Docker event subscriber fell behind bounded history")
            })?;
            let mut batch = Vec::new();
            for event in ledger.events.iter().skip(index) {
                cursor += 1;
                let timestamp = u128::from(event["timeNano"].as_u64().unwrap_or(0));
                if !self.since.is_some_and(|since| timestamp < since) && self.matches(event) {
                    batch.extend_from_slice(event.to_string().as_bytes());
                    batch.push(b'\n');
                }
            }
            if batch.is_empty() {
                ledger = owner
                    .event_changed
                    .wait_timeout(ledger, Duration::from_millis(200))
                    .unwrap()
                    .0;
            } else {
                drop(ledger);
                writer.write_all(&batch)?;
                ledger = owner.ledger.lock().unwrap();
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn event_filters_select_only_owned_container_labels_and_actions() {
        let query = BTreeMap::from([(
            "filters".into(),
            json!({"type":["container"],
            "label":["com.docker.compose.project=owned"],"event":["start"]})
            .to_string(),
        )]);
        let filter = Subscription::parse(&query).unwrap();
        let mut event = json!({"Type":"container","Action":"start",
            "Actor":{"ID":"private","Attributes":{"com.docker.compose.project":"owned"}}});
        assert!(filter.matches(&event));
        event["Actor"]["Attributes"]["com.docker.compose.project"] = json!("other");
        assert!(!filter.matches(&event));
        assert_eq!(epoch_ns("123.25"), Some(123_250_000_000));
        assert_eq!(epoch_ns("123.1234567890"), None);
    }
}

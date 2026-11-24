//! Capacity grants name the accepted workload within its authenticated boot.

use serde::{Deserialize, Serialize};

pub const MARKER: &str = "/etc/conjet/native-core-admission";
pub const PRESSURE_MARKER: &str = "/etc/conjet/native-core-pressure-fixture";
pub const TRACE_MARKER: &str = "/etc/conjet/native-core-latency-trace";
pub const CAPACITY: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Admission {
    pub workload_id: String,
    pub sequence: u64,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Observation {
    pub owned: usize,
    pub pending: Vec<Admission>,
}

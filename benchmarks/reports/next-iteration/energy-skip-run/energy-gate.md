# Conjet Energy Gate

- Verdict: skipped
- Samples: 1
- Contexts: conjet, orbstack
- Workloads: idle

Energy claim status: Not proven.

Reason: powermetrics requires sudo/noninteractive privileges

# Conjet Energy Results

Generated results: 2

## Machine

- macOS: 26.4.1 (25E253)
- Architecture: arm64
- CPU: Apple M1 Pro
- Memory: 16384 MiB
- Power source: battery
- Thermal state: nominal

## Summary

| Workload | Runtime | Samples | Failures | P50 (s) | P75 (s) | P95 (s) | P99 (s) | Mean (s) | StdDev (s) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| idle | conjet | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| idle | orbstack | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

## Results

| Trace ID | Workload | Runtime | Duration (s) | Exit | Key Metrics |
| --- | --- | ---: | ---: | ---: | --- |
| bench-idle-conjet-1780196163904-fb392d71 | idle | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-idle-orbstack-1780196163904-c7f68fe4 | idle | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |

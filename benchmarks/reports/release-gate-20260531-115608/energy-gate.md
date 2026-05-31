# Conjet Energy Gate

- Verdict: skipped
- Samples: 10
- Contexts: conjet, orbstack
- Workloads: idle, container-start-loop, hot-reload-loop, compose-loop, npm-install, pnpm-install, cargo-

Energy claim status: Not proven.

Reason: powermetrics requires sudo/noninteractive privileges

# Conjet Energy Results

Generated results: 14

## Machine

- macOS: 26.4.1 (25E253)
- Architecture: arm64
- CPU: Apple M1 Pro
- Memory: 16384 MiB
- Power source: ac-power
- Thermal state: nominal

## Summary

| Workload | Runtime | Samples | Failures | P50 (s) | P75 (s) | P95 (s) | P99 (s) | Mean (s) | StdDev (s) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cargo- | conjet | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| cargo- | orbstack | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| compose-loop | conjet | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| compose-loop | orbstack | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| container-start-loop | conjet | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| container-start-loop | orbstack | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| hot-reload-loop | conjet | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| hot-reload-loop | orbstack | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| idle | conjet | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| idle | orbstack | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| npm-install | conjet | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| npm-install | orbstack | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| pnpm-install | conjet | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| pnpm-install | orbstack | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

## Results

| Trace ID | Workload | Runtime | Duration (s) | Exit | Key Metrics |
| --- | --- | ---: | ---: | ---: | --- |
| bench-idle-conjet-1780199768481-73975ac6 | idle | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-container-start-loop-conjet-1780199768481-a58148b3 | container-start-loop | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-hot-reload-loop-conjet-1780199768481-a4c2c802 | hot-reload-loop | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-compose-loop-conjet-1780199768481-878ff320 | compose-loop | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-npm-install-conjet-1780199768481-428d8c02 | npm-install | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-pnpm-install-conjet-1780199768481-69c5ab33 | pnpm-install | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-cargo-conjet-1780199768481-6854b3e4 | cargo- | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-idle-orbstack-1780199768481-164e79de | idle | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-container-start-loop-orbstack-1780199768481-fee78f9e | container-start-loop | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-hot-reload-loop-orbstack-1780199768481-f7c81840 | hot-reload-loop | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-compose-loop-orbstack-1780199768481-75172dd8 | compose-loop | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-npm-install-orbstack-1780199768481-5f12675d | npm-install | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-pnpm-install-orbstack-1780199768481-aab83126 | pnpm-install | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-cargo-orbstack-1780199768481-33ea332c | cargo- | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=ac-power, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |

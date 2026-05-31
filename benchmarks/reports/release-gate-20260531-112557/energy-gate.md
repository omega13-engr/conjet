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
- Power source: battery
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
| bench-idle-conjet-1780197957555-3045fde5 | idle | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-container-start-loop-conjet-1780197957555-a7ee7ba7 | container-start-loop | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-hot-reload-loop-conjet-1780197957555-c3c44053 | hot-reload-loop | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-compose-loop-conjet-1780197957555-59673d79 | compose-loop | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-npm-install-conjet-1780197957555-4ad965fd | npm-install | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-pnpm-install-conjet-1780197957555-e3bb26b1 | pnpm-install | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-cargo-conjet-1780197957555-57df9e12 | cargo- | conjet | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-idle-orbstack-1780197957555-0dc57afc | idle | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-container-start-loop-orbstack-1780197957555-5e681920 | container-start-loop | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-hot-reload-loop-orbstack-1780197957555-edaca299 | hot-reload-loop | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-compose-loop-orbstack-1780197957555-c8b815a8 | compose-loop | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-npm-install-orbstack-1780197957555-4c984f18 | npm-install | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-pnpm-install-orbstack-1780197957555-22c5b8c0 | pnpm-install | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |
| bench-cargo-orbstack-1780197957555-96595976 | cargo- | orbstack | 0 | 0 | average_power_watts=null, cpu_power_watts=null, energy_skip_reason=powermetrics requires sudo/noninteractive privileges, energy_to_solution_joules=null, energy_verdict=skipped, low_power_mode=false, package_power_watts=null, power_source=battery, thermal_state_after=nominal, thermal_state_before=nominal, wakeups_per_second=null |

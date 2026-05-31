# Conjet Energy Gate

- Verdict: measured
- Samples: 10
- Contexts: conjet, orbstack
- Workloads: idle, container-start-loop, hot-reload-loop, compose-loop, npm-install, pnpm-install, cargo-build

# Conjet Energy Results

Generated results: 140

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
| cargo-build | conjet | 10 | 10 | 15.054 | 15.062 | 15.073 | 15.073 | 15.051 | 0.014 |
| cargo-build | orbstack | 10 | 10 | 15.059 | 15.061 | 15.065 | 15.065 | 15.054 | 0.011 |
| compose-loop | conjet | 10 | 0 | 15.061 | 15.066 | 15.255 | 15.255 | 15.077 | 0.060 |
| compose-loop | orbstack | 10 | 0 | 15.264 | 15.569 | 15.884 | 15.884 | 15.374 | 0.251 |
| container-start-loop | conjet | 10 | 0 | 15.051 | 15.075 | 15.196 | 15.196 | 15.071 | 0.050 |
| container-start-loop | orbstack | 10 | 0 | 15.170 | 15.718 | 16.317 | 16.317 | 15.455 | 0.423 |
| hot-reload-loop | conjet | 10 | 0 | 15.057 | 15.068 | 15.071 | 15.071 | 15.052 | 0.016 |
| hot-reload-loop | orbstack | 10 | 0 | 15.654 | 16.276 | 16.591 | 16.591 | 15.806 | 0.524 |
| idle-power-sample | conjet | 10 | 0 | 32.182 | 32.348 | 32.529 | 32.529 | 32.233 | 0.150 |
| idle-power-sample | orbstack | 10 | 0 | 32.199 | 32.242 | 32.300 | 32.300 | 32.211 | 0.047 |
| npm-install | conjet | 10 | 0 | 15.409 | 15.880 | 16.044 | 16.044 | 15.515 | 0.359 |
| npm-install | orbstack | 10 | 0 | 15.593 | 16.467 | 18.275 | 18.275 | 16.099 | 0.964 |
| pnpm-install | conjet | 10 | 0 | 16.457 | 17.883 | 19.685 | 19.685 | 16.827 | 1.464 |
| pnpm-install | orbstack | 10 | 0 | 17.181 | 17.668 | 18.757 | 18.757 | 17.051 | 1.129 |

## Results

| Trace ID | Workload | Runtime | Duration (s) | Exit | Key Metrics |
| --- | --- | ---: | ---: | ---: | --- |
| bench-idle-power-sample-conjet-1780203707889-c7c3000d | idle-power-sample | conjet | 32.529 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.497, combined_power_mw_max=1352, combined_power_mw_mean=497.333, combined_power_mw_p50=372, combined_power_mw_p75=727, combined_power_mw_p95=1121, combined_power_mw_p99=1352, combined_power_mw_stddev=314.960, cpu_power_mw_max=1292, cpu_power_mw_mean=438.700, cpu_power_mw_p50=312, cpu_power_mw_p75=670, cpu_power_mw_p95=1057, cpu_power_mw_p99=1292, cpu_power_mw_stddev=314.021, cpu_power_watts=0.439, energy_verdict=measured, gpu_power_mw_max=73, gpu_power_mw_mean=58.450, gpu_power_mw_p50=58, gpu_power_mw_p75=60, gpu_power_mw_p95=66, gpu_power_mw_p99=73, gpu_power_mw_stddev=3.905, idle_power_watts=0.497, iteration=1, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780203740549-899cebde | container-start-loop | conjet | 15.062 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.827, combined_power_mw_max=5495, combined_power_mw_mean=4826.769, combined_power_mw_p50=4667, combined_power_mw_p75=4996, combined_power_mw_p95=5495, combined_power_mw_p99=5495, combined_power_mw_stddev=291.692, cpu_energy_to_solution_joules_estimate=68.008, cpu_power_mw_max=5429, cpu_power_mw_mean=4764.462, cpu_power_mw_p50=4604, cpu_power_mw_p75=4934, cpu_power_mw_p95=5429, cpu_power_mw_p99=5429, cpu_power_mw_stddev=290.729, cpu_power_watts=4.764, energy_to_solution_joules=68.898, energy_to_solution_joules_estimate=68.898, energy_verdict=measured, gpu_power_mw_max=66, gpu_power_mw_mean=62.038, gpu_power_mw_p50=63, gpu_power_mw_p75=64, gpu_power_mw_p95=66, gpu_power_mw_p99=66, gpu_power_mw_stddev=2.609, iteration=1, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.014, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.274, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780203755672-7e926f34 | hot-reload-loop | conjet | 15.071 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.318, combined_power_mw_max=5937, combined_power_mw_mean=5317.846, combined_power_mw_p50=5300, combined_power_mw_p75=5574, combined_power_mw_p95=5937, combined_power_mw_p99=5937, combined_power_mw_stddev=397.011, cpu_energy_to_solution_joules_estimate=74.594, cpu_power_mw_max=5867, cpu_power_mw_mean=5249.692, cpu_power_mw_p50=5235, cpu_power_mw_p75=5506, cpu_power_mw_p95=5867, cpu_power_mw_p99=5867, cpu_power_mw_stddev=396.928, cpu_power_watts=5.250, energy_to_solution_joules=75.562, energy_to_solution_joules_estimate=75.562, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=68.192, gpu_power_mw_p50=69, gpu_power_mw_p75=70, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.386, iteration=1, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.023, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.209, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780203770809-74c96ab2 | compose-loop | conjet | 15.255 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.660, combined_power_mw_max=5058, combined_power_mw_mean=4659.692, combined_power_mw_p50=4670, combined_power_mw_p75=4846, combined_power_mw_p95=5058, combined_power_mw_p99=5058, combined_power_mw_stddev=220.063, cpu_energy_to_solution_joules_estimate=68.759, cpu_power_mw_max=4989, cpu_power_mw_mean=4592.231, cpu_power_mw_p50=4605, cpu_power_mw_p75=4776, cpu_power_mw_p95=4989, cpu_power_mw_p99=4989, cpu_power_mw_stddev=219.400, cpu_power_watts=4.592, energy_to_solution_joules=69.769, energy_to_solution_joules_estimate=69.769, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=67.385, gpu_power_mw_p50=67, gpu_power_mw_p75=68, gpu_power_mw_p95=70, gpu_power_mw_p99=70, gpu_power_mw_stddev=1.361, iteration=1, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.231, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.973, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780203786115-c80cac5c | npm-install | conjet | 15.905 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.102, combined_power_mw_max=4230, combined_power_mw_mean=3101.500, combined_power_mw_p50=3108, combined_power_mw_p75=3239, combined_power_mw_p95=4230, combined_power_mw_p99=4230, combined_power_mw_stddev=542.184, cpu_energy_to_solution_joules_estimate=47.405, cpu_power_mw_max=4163, cpu_power_mw_mean=3034.571, cpu_power_mw_p50=3033, cpu_power_mw_p75=3171, cpu_power_mw_p95=4163, cpu_power_mw_p99=4163, cpu_power_mw_stddev=541.525, cpu_power_watts=3.035, energy_to_solution_joules=48.451, energy_to_solution_joules_estimate=48.451, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=67, gpu_power_mw_p50=67, gpu_power_mw_p75=68, gpu_power_mw_p95=75, gpu_power_mw_p99=75, gpu_power_mw_stddev=3.546, iteration=1, low_power_mode=false, matched_process_lines=15, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.879, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.622, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780203802073-01dbb18c | pnpm-install | conjet | 15.072 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.441, combined_power_mw_max=3718, combined_power_mw_mean=2441.462, combined_power_mw_p50=2469, combined_power_mw_p75=3266, combined_power_mw_p95=3718, combined_power_mw_p99=3718, combined_power_mw_stddev=966.598, cpu_energy_to_solution_joules_estimate=35.181, cpu_power_mw_max=3651, cpu_power_mw_mean=2378.231, cpu_power_mw_p50=2408, cpu_power_mw_p75=3204, cpu_power_mw_p95=3651, cpu_power_mw_p99=3651, cpu_power_mw_stddev=966.255, cpu_power_watts=2.378, energy_to_solution_joules=36.116, energy_to_solution_joules_estimate=36.116, energy_verdict=measured, gpu_power_mw_max=67, gpu_power_mw_mean=63.269, gpu_power_mw_p50=63, gpu_power_mw_p75=65, gpu_power_mw_p95=66, gpu_power_mw_p99=67, gpu_power_mw_stddev=1.830, iteration=1, low_power_mode=false, matched_process_lines=3, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.051, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.793, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780203817197-c293dc84 | cargo-build | conjet | 15.062 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.538, combined_power_mw_max=1793, combined_power_mw_mean=538.462, combined_power_mw_p50=338, combined_power_mw_p75=758, combined_power_mw_p95=1793, combined_power_mw_p99=1793, combined_power_mw_stddev=425.490, cpu_energy_to_solution_joules_estimate=0.104, cpu_power_mw_max=1728, cpu_power_mw_mean=476.538, cpu_power_mw_p50=277, cpu_power_mw_p75=696, cpu_power_mw_p95=1728, cpu_power_mw_p99=1728, cpu_power_mw_stddev=424.889, cpu_power_watts=0.477, energy_to_solution_joules=0.118, energy_to_solution_joules_estimate=0.118, energy_verdict=measured, gpu_power_mw_max=66, gpu_power_mw_mean=62.077, gpu_power_mw_p50=62, gpu_power_mw_p75=64, gpu_power_mw_p95=66, gpu_power_mw_p99=66, gpu_power_mw_stddev=2.055, iteration=1, low_power_mode=false, matched_process_lines=1, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.024, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.218, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780203832324-d5254cba | idle-power-sample | orbstack | 32.242 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.556, combined_power_mw_max=2310, combined_power_mw_mean=555.867, combined_power_mw_p50=412, combined_power_mw_p75=595, combined_power_mw_p95=1181, combined_power_mw_p99=2310, combined_power_mw_stddev=412.670, cpu_power_mw_max=2171, cpu_power_mw_mean=491.567, cpu_power_mw_p50=354, cpu_power_mw_p75=531, cpu_power_mw_p95=1099, cpu_power_mw_p99=2171, cpu_power_mw_stddev=399.541, cpu_power_watts=0.492, energy_verdict=measured, gpu_power_mw_max=140, gpu_power_mw_mean=64.417, gpu_power_mw_p50=60, gpu_power_mw_p75=62, gpu_power_mw_p95=96, gpu_power_mw_p99=140, gpu_power_mw_stddev=16.350, idle_power_watts=0.556, iteration=1, low_power_mode=false, matched_process_lines=45, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780203864682-2e751064 | container-start-loop | orbstack | 15.156 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.820, combined_power_mw_max=2485, combined_power_mw_mean=1819.846, combined_power_mw_p50=1760, combined_power_mw_p75=1977, combined_power_mw_p95=2485, combined_power_mw_p99=2485, combined_power_mw_stddev=382.304, cpu_energy_to_solution_joules_estimate=26.145, cpu_power_mw_max=2425, cpu_power_mw_mean=1759.385, cpu_power_mw_p50=1700, cpu_power_mw_p75=1920, cpu_power_mw_p95=2425, cpu_power_mw_p99=2425, cpu_power_mw_stddev=381.440, cpu_power_watts=1.759, energy_to_solution_joules=27.044, energy_to_solution_joules_estimate=27.044, energy_verdict=measured, gpu_power_mw_max=68, gpu_power_mw_mean=60.385, gpu_power_mw_p50=61, gpu_power_mw_p75=62, gpu_power_mw_p95=66, gpu_power_mw_p99=68, gpu_power_mw_stddev=2.910, iteration=1, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.124, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.861, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780203879897-87029242 | hot-reload-loop | orbstack | 15.654 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.825, combined_power_mw_max=2299, combined_power_mw_mean=1825.500, combined_power_mw_p50=1821, combined_power_mw_p75=2070, combined_power_mw_p95=2299, combined_power_mw_p99=2299, combined_power_mw_stddev=316.878, cpu_energy_to_solution_joules_estimate=27.103, cpu_power_mw_max=2237, cpu_power_mw_mean=1764.357, cpu_power_mw_p50=1760, cpu_power_mw_p75=2011, cpu_power_mw_p95=2237, cpu_power_mw_p99=2237, cpu_power_mw_stddev=316.191, cpu_power_watts=1.764, energy_to_solution_joules=28.043, energy_to_solution_joules_estimate=28.043, energy_verdict=measured, gpu_power_mw_max=64, gpu_power_mw_mean=61.214, gpu_power_mw_p50=62, gpu_power_mw_p75=63, gpu_power_mw_p95=64, gpu_power_mw_p99=64, gpu_power_mw_stddev=1.878, iteration=1, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.620, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.362, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780203895607-e048767f | compose-loop | orbstack | 15.255 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.907, combined_power_mw_max=2659, combined_power_mw_mean=1907.462, combined_power_mw_p50=1843, combined_power_mw_p75=2108, combined_power_mw_p95=2659, combined_power_mw_p99=2659, combined_power_mw_stddev=345.648, cpu_energy_to_solution_joules_estimate=27.603, cpu_power_mw_max=2595, cpu_power_mw_mean=1844.692, cpu_power_mw_p50=1782, cpu_power_mw_p75=2047, cpu_power_mw_p95=2595, cpu_power_mw_p99=2595, cpu_power_mw_stddev=344.619, cpu_power_watts=1.845, energy_to_solution_joules=28.542, energy_to_solution_joules_estimate=28.542, energy_verdict=measured, gpu_power_mw_max=67, gpu_power_mw_mean=62.769, gpu_power_mw_p50=63, gpu_power_mw_p75=64, gpu_power_mw_p95=67, gpu_power_mw_p99=67, gpu_power_mw_stddev=2.172, iteration=1, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.222, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.963, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780203910919-46bb7854 | npm-install | orbstack | 15.330 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.091, combined_power_mw_max=4567, combined_power_mw_mean=2091.308, combined_power_mw_p50=1677, combined_power_mw_p75=2633, combined_power_mw_p95=4567, combined_power_mw_p99=4567, combined_power_mw_stddev=1036.754, cpu_energy_to_solution_joules_estimate=30.515, cpu_power_mw_max=4500, cpu_power_mw_mean=2030.077, cpu_power_mw_p50=1618, cpu_power_mw_p75=2571, cpu_power_mw_p95=4500, cpu_power_mw_p99=4500, cpu_power_mw_stddev=1036.025, cpu_power_watts=2.030, energy_to_solution_joules=31.435, energy_to_solution_joules_estimate=31.435, energy_verdict=measured, gpu_power_mw_max=68, gpu_power_mw_mean=61.423, gpu_power_mw_p50=61, gpu_power_mw_p75=63, gpu_power_mw_p95=67, gpu_power_mw_p99=68, gpu_power_mw_stddev=2.483, iteration=1, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.295, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.031, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780203926308-b42cc061 | pnpm-install | orbstack | 16.450 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.446, combined_power_mw_max=3168, combined_power_mw_mean=2445.929, combined_power_mw_p50=2679, combined_power_mw_p75=2988, combined_power_mw_p95=3168, combined_power_mw_p99=3168, combined_power_mw_stddev=670.577, cpu_energy_to_solution_joules_estimate=38.525, cpu_power_mw_max=3106, cpu_power_mw_mean=2383.857, cpu_power_mw_p50=2619, cpu_power_mw_p75=2927, cpu_power_mw_p95=3106, cpu_power_mw_p99=3106, cpu_power_mw_stddev=671.041, cpu_power_watts=2.384, energy_to_solution_joules=39.528, energy_to_solution_joules_estimate=39.528, energy_verdict=measured, gpu_power_mw_max=65, gpu_power_mw_mean=61.929, gpu_power_mw_p50=62, gpu_power_mw_p75=63, gpu_power_mw_p95=65, gpu_power_mw_p99=65, gpu_power_mw_stddev=1.981, iteration=1, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.420, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.161, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780203942816-4d920a4c | cargo-build | orbstack | 15.057 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.594, combined_power_mw_max=2945, combined_power_mw_mean=593.615, combined_power_mw_p50=298, combined_power_mw_p75=549, combined_power_mw_p95=2945, combined_power_mw_p99=2945, combined_power_mw_stddev=701.304, cpu_energy_to_solution_joules_estimate=0.916, cpu_power_mw_max=2877, cpu_power_mw_mean=533.692, cpu_power_mw_p50=231, cpu_power_mw_p75=485, cpu_power_mw_p95=2877, cpu_power_mw_p99=2877, cpu_power_mw_stddev=698.958, cpu_power_watts=0.534, energy_to_solution_joules=1.018, energy_to_solution_joules_estimate=1.018, energy_verdict=measured, gpu_power_mw_max=68, gpu_power_mw_mean=59.885, gpu_power_mw_p50=60, gpu_power_mw_p75=61, gpu_power_mw_p95=68, gpu_power_mw_p99=68, gpu_power_mw_stddev=4.135, iteration=1, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.017, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.716, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780203957944-8aa935d9 | idle-power-sample | conjet | 32.298 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.466, combined_power_mw_max=1570, combined_power_mw_mean=466.300, combined_power_mw_p50=336, combined_power_mw_p75=403, combined_power_mw_p95=1037, combined_power_mw_p99=1570, combined_power_mw_stddev=353.785, cpu_power_mw_max=1510, cpu_power_mw_mean=408.067, cpu_power_mw_p50=278, cpu_power_mw_p75=349, cpu_power_mw_p95=975, cpu_power_mw_p99=1510, cpu_power_mw_stddev=353.139, cpu_power_watts=0.408, energy_verdict=measured, gpu_power_mw_max=63, gpu_power_mw_mean=58.233, gpu_power_mw_p50=58, gpu_power_mw_p75=59, gpu_power_mw_p95=63, gpu_power_mw_p99=63, gpu_power_mw_stddev=2.044, idle_power_watts=0.466, iteration=2, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780203990356-29daecab | container-start-loop | conjet | 15.069 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.694, combined_power_mw_max=5236, combined_power_mw_mean=4693.923, combined_power_mw_p50=4611, combined_power_mw_p75=4805, combined_power_mw_p95=5236, combined_power_mw_p99=5236, combined_power_mw_stddev=294.455, cpu_energy_to_solution_joules_estimate=66.715, cpu_power_mw_max=5175, cpu_power_mw_mean=4631.615, cpu_power_mw_p50=4549, cpu_power_mw_p75=4739, cpu_power_mw_p95=5175, cpu_power_mw_p99=5175, cpu_power_mw_stddev=294.399, cpu_power_watts=4.632, energy_to_solution_joules=67.613, energy_to_solution_joules_estimate=67.613, energy_verdict=measured, gpu_power_mw_max=67, gpu_power_mw_mean=62.115, gpu_power_mw_p50=62, gpu_power_mw_p75=64, gpu_power_mw_p95=67, gpu_power_mw_p99=67, gpu_power_mw_stddev=2.694, iteration=2, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.022, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.404, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780204005489-74ea7d9f | hot-reload-loop | conjet | 15.068 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.741, combined_power_mw_max=5326, combined_power_mw_mean=4741, combined_power_mw_p50=4636, combined_power_mw_p75=5136, combined_power_mw_p95=5326, combined_power_mw_p99=5326, combined_power_mw_stddev=367.398, cpu_energy_to_solution_joules_estimate=67.037, cpu_power_mw_max=5260, cpu_power_mw_mean=4674.846, cpu_power_mw_p50=4571, cpu_power_mw_p75=5069, cpu_power_mw_p95=5260, cpu_power_mw_p99=5260, cpu_power_mw_stddev=367.058, cpu_power_watts=4.675, energy_to_solution_joules=67.986, energy_to_solution_joules_estimate=67.986, energy_verdict=measured, gpu_power_mw_max=69, gpu_power_mw_mean=65.846, gpu_power_mw_p50=65, gpu_power_mw_p75=67, gpu_power_mw_p95=68, gpu_power_mw_p99=69, gpu_power_mw_stddev=1.321, iteration=2, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.019, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.340, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780204020618-850e5e6b | compose-loop | conjet | 15.061 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.772, combined_power_mw_max=5445, combined_power_mw_mean=4772, combined_power_mw_p50=4697, combined_power_mw_p75=4980, combined_power_mw_p95=5445, combined_power_mw_p99=5445, combined_power_mw_stddev=295.138, cpu_energy_to_solution_joules_estimate=67.315, cpu_power_mw_max=5374, cpu_power_mw_mean=4703.538, cpu_power_mw_p50=4630, cpu_power_mw_p75=4912, cpu_power_mw_p95=5374, cpu_power_mw_p99=5374, cpu_power_mw_stddev=294.861, cpu_power_watts=4.704, energy_to_solution_joules=68.295, energy_to_solution_joules_estimate=68.295, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=68.385, gpu_power_mw_p50=68, gpu_power_mw_p75=69, gpu_power_mw_p95=70, gpu_power_mw_p99=71, gpu_power_mw_stddev=0.964, iteration=2, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.015, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.312, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780204035740-f0447ec9 | npm-install | conjet | 15.438 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.111, combined_power_mw_max=3736, combined_power_mw_mean=3110.643, combined_power_mw_p50=3142, combined_power_mw_p75=3552, combined_power_mw_p95=3736, combined_power_mw_p99=3736, combined_power_mw_stddev=479.104, cpu_energy_to_solution_joules_estimate=46.127, cpu_power_mw_max=3669, cpu_power_mw_mean=3043.357, cpu_power_mw_p50=3076, cpu_power_mw_p75=3481, cpu_power_mw_p95=3669, cpu_power_mw_p99=3669, cpu_power_mw_stddev=478.501, cpu_power_watts=3.043, energy_to_solution_joules=47.147, energy_to_solution_joules_estimate=47.147, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=67.357, gpu_power_mw_p50=68, gpu_power_mw_p75=68, gpu_power_mw_p95=71, gpu_power_mw_p99=71, gpu_power_mw_stddev=2.108, iteration=2, low_power_mode=false, matched_process_lines=15, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.414, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.157, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780204051229-004fc118 | pnpm-install | conjet | 18.577 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.981, combined_power_mw_max=4840, combined_power_mw_mean=2981.235, combined_power_mw_p50=3137, combined_power_mw_p75=3594, combined_power_mw_p95=4840, combined_power_mw_p99=4840, combined_power_mw_stddev=1026.027, cpu_energy_to_solution_joules_estimate=53.330, cpu_power_mw_max=4774, cpu_power_mw_mean=2914.824, cpu_power_mw_p50=3073, cpu_power_mw_p75=3526, cpu_power_mw_p95=4774, cpu_power_mw_p99=4774, cpu_power_mw_stddev=1024.932, cpu_power_watts=2.915, energy_to_solution_joules=54.545, energy_to_solution_joules_estimate=54.545, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=66.441, gpu_power_mw_p50=67, gpu_power_mw_p75=68, gpu_power_mw_p95=70, gpu_power_mw_p99=70, gpu_power_mw_stddev=2.117, iteration=2, low_power_mode=false, matched_process_lines=7, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=18.549, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=17, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=18.296, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780204069858-93203be7 | cargo-build | conjet | 15.028 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.469, combined_power_mw_max=1132, combined_power_mw_mean=468.846, combined_power_mw_p50=360, combined_power_mw_p75=569, combined_power_mw_p95=1132, combined_power_mw_p99=1132, combined_power_mw_stddev=262.292, cpu_energy_to_solution_joules_estimate=0.090, cpu_power_mw_max=1062, cpu_power_mw_mean=406.077, cpu_power_mw_p50=301, cpu_power_mw_p75=503, cpu_power_mw_p95=1062, cpu_power_mw_p99=1062, cpu_power_mw_stddev=260.748, cpu_power_watts=0.406, energy_to_solution_joules=0.104, energy_to_solution_joules_estimate=0.104, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=63, gpu_power_mw_p50=62, gpu_power_mw_p75=67, gpu_power_mw_p95=69, gpu_power_mw_p99=70, gpu_power_mw_stddev=3.606, iteration=2, low_power_mode=false, matched_process_lines=4, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.006, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.223, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780204084943-59c0d902 | idle-power-sample | orbstack | 32.199 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.406, combined_power_mw_max=978, combined_power_mw_mean=406.500, combined_power_mw_p50=313, combined_power_mw_p75=492, combined_power_mw_p95=931, combined_power_mw_p99=978, combined_power_mw_stddev=226.843, cpu_power_mw_max=921, cpu_power_mw_mean=347.733, cpu_power_mw_p50=257, cpu_power_mw_p75=432, cpu_power_mw_p95=867, cpu_power_mw_p99=921, cpu_power_mw_stddev=226.847, cpu_power_watts=0.348, energy_verdict=measured, gpu_power_mw_max=64, gpu_power_mw_mean=58.767, gpu_power_mw_p50=59, gpu_power_mw_p75=60, gpu_power_mw_p95=64, gpu_power_mw_p99=64, gpu_power_mw_stddev=2.383, idle_power_watts=0.406, iteration=2, low_power_mode=false, matched_process_lines=41, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780204117259-5bf753f4 | container-start-loop | orbstack | 15.718 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.876, combined_power_mw_max=2528, combined_power_mw_mean=1875.714, combined_power_mw_p50=1974, combined_power_mw_p75=2135, combined_power_mw_p95=2528, combined_power_mw_p99=2528, combined_power_mw_stddev=391.311, cpu_energy_to_solution_joules_estimate=27.962, cpu_power_mw_max=2464, cpu_power_mw_mean=1813.429, cpu_power_mw_p50=1910, cpu_power_mw_p75=2067, cpu_power_mw_p95=2464, cpu_power_mw_p99=2464, cpu_power_mw_stddev=390.308, cpu_power_watts=1.813, energy_to_solution_joules=28.923, energy_to_solution_joules_estimate=28.923, energy_verdict=measured, gpu_power_mw_max=69, gpu_power_mw_mean=62.464, gpu_power_mw_p50=62, gpu_power_mw_p75=64, gpu_power_mw_p95=69, gpu_power_mw_p99=69, gpu_power_mw_stddev=2.500, iteration=2, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.683, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.420, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780204133043-3754fdea | hot-reload-loop | orbstack | 15.037 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.668, combined_power_mw_max=2346, combined_power_mw_mean=1668.385, combined_power_mw_p50=1688, combined_power_mw_p75=1928, combined_power_mw_p95=2346, combined_power_mw_p99=2346, combined_power_mw_stddev=398.330, cpu_energy_to_solution_joules_estimate=23.641, cpu_power_mw_max=2286, cpu_power_mw_mean=1607.077, cpu_power_mw_p50=1626, cpu_power_mw_p75=1863, cpu_power_mw_p95=2286, cpu_power_mw_p99=2286, cpu_power_mw_stddev=397.843, cpu_power_watts=1.607, energy_to_solution_joules=24.543, energy_to_solution_joules_estimate=24.543, energy_verdict=measured, gpu_power_mw_max=66, gpu_power_mw_mean=61.462, gpu_power_mw_p50=62, gpu_power_mw_p75=64, gpu_power_mw_p95=66, gpu_power_mw_p99=66, gpu_power_mw_stddev=2.804, iteration=2, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.007, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.711, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780204148139-587b8ad4 | compose-loop | orbstack | 15.679 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.381, combined_power_mw_max=4892, combined_power_mw_mean=2381, combined_power_mw_p50=2112, combined_power_mw_p75=2991, combined_power_mw_p95=4892, combined_power_mw_p99=4892, combined_power_mw_stddev=997.590, cpu_energy_to_solution_joules_estimate=35.637, cpu_power_mw_max=4827, cpu_power_mw_mean=2316.643, cpu_power_mw_p50=2049, cpu_power_mw_p75=2925, cpu_power_mw_p95=4827, cpu_power_mw_p99=4827, cpu_power_mw_stddev=997.152, cpu_power_watts=2.317, energy_to_solution_joules=36.627, energy_to_solution_joules_estimate=36.627, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=64.357, gpu_power_mw_p50=65, gpu_power_mw_p75=67, gpu_power_mw_p95=68, gpu_power_mw_p99=71, gpu_power_mw_stddev=2.967, iteration=2, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.643, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.383, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780204163876-f019656a | npm-install | orbstack | 18.275 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.280, combined_power_mw_max=3217, combined_power_mw_mean=2279.750, combined_power_mw_p50=2357, combined_power_mw_p75=2874, combined_power_mw_p95=3217, combined_power_mw_p99=3217, combined_power_mw_stddev=653.817, cpu_energy_to_solution_joules_estimate=39.820, cpu_power_mw_max=3153, cpu_power_mw_mean=2216, cpu_power_mw_p50=2297, cpu_power_mw_p75=2812, cpu_power_mw_p95=3153, cpu_power_mw_p99=3153, cpu_power_mw_stddev=653.926, cpu_power_watts=2.216, energy_to_solution_joules=40.966, energy_to_solution_joules_estimate=40.966, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=63.812, gpu_power_mw_p50=63, gpu_power_mw_p75=67, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=3.644, iteration=2, low_power_mode=false, matched_process_lines=34, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=18.236, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=16, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=17.969, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780204182209-ba2a5c91 | pnpm-install | orbstack | 17.208 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.287, combined_power_mw_max=3690, combined_power_mw_mean=2287.133, combined_power_mw_p50=2289, combined_power_mw_p75=2836, combined_power_mw_p95=3690, combined_power_mw_p99=3690, combined_power_mw_stddev=685.112, cpu_energy_to_solution_joules_estimate=37.605, cpu_power_mw_max=3625, cpu_power_mw_mean=2223.533, cpu_power_mw_p50=2227, cpu_power_mw_p75=2773, cpu_power_mw_p95=3625, cpu_power_mw_p99=3625, cpu_power_mw_stddev=684.816, cpu_power_watts=2.224, energy_to_solution_joules=38.681, energy_to_solution_joules_estimate=38.681, energy_verdict=measured, gpu_power_mw_max=67, gpu_power_mw_mean=63.733, gpu_power_mw_p50=64, gpu_power_mw_p75=65, gpu_power_mw_p95=67, gpu_power_mw_p99=67, gpu_power_mw_stddev=1.931, iteration=2, low_power_mode=false, matched_process_lines=32, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=17.176, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=15, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.912, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780204199481-1172f6a8 | cargo-build | orbstack | 15.061 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.567, combined_power_mw_max=1742, combined_power_mw_mean=566.538, combined_power_mw_p50=461, combined_power_mw_p75=740, combined_power_mw_p95=1742, combined_power_mw_p99=1742, combined_power_mw_stddev=403.514, cpu_energy_to_solution_joules_estimate=0.998, cpu_power_mw_max=1675, cpu_power_mw_mean=503.154, cpu_power_mw_p50=397, cpu_power_mw_p75=676, cpu_power_mw_p95=1675, cpu_power_mw_p99=1675, cpu_power_mw_stddev=403.047, cpu_power_watts=0.503, energy_to_solution_joules=1.124, energy_to_solution_joules_estimate=1.124, energy_verdict=measured, gpu_power_mw_max=68, gpu_power_mw_mean=63.231, gpu_power_mw_p50=63, gpu_power_mw_p75=64, gpu_power_mw_p95=67, gpu_power_mw_p99=68, gpu_power_mw_stddev=2.375, iteration=2, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.015, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.984, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780204214624-cdded1ce | idle-power-sample | conjet | 32.381 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.403, combined_power_mw_max=1007, combined_power_mw_mean=403.167, combined_power_mw_p50=300, combined_power_mw_p75=436, combined_power_mw_p95=954, combined_power_mw_p99=1007, combined_power_mw_stddev=231.145, cpu_power_mw_max=951, cpu_power_mw_mean=345.867, cpu_power_mw_p50=246, cpu_power_mw_p75=379, cpu_power_mw_p95=898, cpu_power_mw_p99=951, cpu_power_mw_stddev=231.183, cpu_power_watts=0.346, energy_verdict=measured, gpu_power_mw_max=62, gpu_power_mw_mean=57.350, gpu_power_mw_p50=57, gpu_power_mw_p75=59, gpu_power_mw_p95=61, gpu_power_mw_p99=62, gpu_power_mw_stddev=2.294, idle_power_watts=0.403, iteration=3, low_power_mode=false, matched_process_lines=4, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780204247120-5cc5a3f7 | container-start-loop | conjet | 15.125 | 0 | ane_power_mw_max=1, ane_power_mw_mean=0.077, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=1, ane_power_mw_p99=1, ane_power_mw_stddev=0.266, average_power_watts=4.694, combined_power_mw_max=5275, combined_power_mw_mean=4694.385, combined_power_mw_p50=4693, combined_power_mw_p75=4805, combined_power_mw_p95=5275, combined_power_mw_p99=5275, combined_power_mw_stddev=311.022, cpu_energy_to_solution_joules_estimate=68.726, cpu_power_mw_max=5208, cpu_power_mw_mean=4631.385, cpu_power_mw_p50=4634, cpu_power_mw_p75=4748, cpu_power_mw_p95=5208, cpu_power_mw_p99=5208, cpu_power_mw_stddev=310.495, cpu_power_watts=4.631, energy_to_solution_joules=69.661, energy_to_solution_joules_estimate=69.661, energy_verdict=measured, gpu_power_mw_max=67, gpu_power_mw_mean=62.769, gpu_power_mw_p50=63, gpu_power_mw_p75=65, gpu_power_mw_p95=67, gpu_power_mw_p99=67, gpu_power_mw_stddev=2.978, iteration=3, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.102, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.839, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780204262295-bcda4ea4 | hot-reload-loop | conjet | 15.027 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.857, combined_power_mw_max=5183, combined_power_mw_mean=4856.615, combined_power_mw_p50=4899, combined_power_mw_p75=5112, combined_power_mw_p95=5183, combined_power_mw_p99=5183, combined_power_mw_stddev=299.762, cpu_energy_to_solution_joules_estimate=69.736, cpu_power_mw_max=5107, cpu_power_mw_mean=4789.154, cpu_power_mw_p50=4832, cpu_power_mw_p75=5048, cpu_power_mw_p95=5107, cpu_power_mw_p99=5107, cpu_power_mw_stddev=298.535, cpu_power_watts=4.789, energy_to_solution_joules=70.718, energy_to_solution_joules_estimate=70.718, energy_verdict=measured, gpu_power_mw_max=76, gpu_power_mw_mean=67.462, gpu_power_mw_p50=67, gpu_power_mw_p75=68, gpu_power_mw_p95=76, gpu_power_mw_p99=76, gpu_power_mw_stddev=3.319, iteration=3, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.004, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.561, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780204277376-d9d7c643 | compose-loop | conjet | 15.074 | 0 | ane_power_mw_max=1, ane_power_mw_mean=0.077, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=1, ane_power_mw_p99=1, ane_power_mw_stddev=0.266, average_power_watts=4.678, combined_power_mw_max=5435, combined_power_mw_mean=4678, combined_power_mw_p50=4591, combined_power_mw_p75=4855, combined_power_mw_p95=5435, combined_power_mw_p99=5435, combined_power_mw_stddev=373.228, cpu_energy_to_solution_joules_estimate=66.860, cpu_power_mw_max=5364, cpu_power_mw_mean=4608.846, cpu_power_mw_p50=4521, cpu_power_mw_p75=4786, cpu_power_mw_p95=5364, cpu_power_mw_p99=5364, cpu_power_mw_stddev=372.678, cpu_power_watts=4.609, energy_to_solution_joules=67.863, energy_to_solution_joules_estimate=67.863, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=68.962, gpu_power_mw_p50=69, gpu_power_mw_p75=69, gpu_power_mw_p95=74, gpu_power_mw_p99=74, gpu_power_mw_stddev=2.047, iteration=3, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.027, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.507, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780204292516-ee4e3821 | npm-install | conjet | 15.409 | 0 | ane_power_mw_max=1, ane_power_mw_mean=0.077, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=1, ane_power_mw_p99=1, ane_power_mw_stddev=0.266, average_power_watts=2.819, combined_power_mw_max=3962, combined_power_mw_mean=2819.462, combined_power_mw_p50=3094, combined_power_mw_p75=3177, combined_power_mw_p95=3962, combined_power_mw_p99=3962, combined_power_mw_stddev=832.845, cpu_energy_to_solution_joules_estimate=41.641, cpu_power_mw_max=3895, cpu_power_mw_mean=2753.154, cpu_power_mw_p50=3022, cpu_power_mw_p75=3111, cpu_power_mw_p95=3895, cpu_power_mw_p99=3895, cpu_power_mw_stddev=833.001, cpu_power_watts=2.753, energy_to_solution_joules=42.644, energy_to_solution_joules_estimate=42.644, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=66.192, gpu_power_mw_p50=66, gpu_power_mw_p75=67, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.287, iteration=3, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.387, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.125, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780204307980-15632502 | pnpm-install | conjet | 19.685 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.234, combined_power_mw_max=4168, combined_power_mw_mean=2234.111, combined_power_mw_p50=2408, combined_power_mw_p75=2993, combined_power_mw_p95=4168, combined_power_mw_p99=4168, combined_power_mw_stddev=974.767, cpu_energy_to_solution_joules_estimate=42.074, cpu_power_mw_max=4102, cpu_power_mw_mean=2169.444, cpu_power_mw_p50=2344, cpu_power_mw_p75=2928, cpu_power_mw_p95=4102, cpu_power_mw_p99=4102, cpu_power_mw_stddev=974.827, cpu_power_watts=2.169, energy_to_solution_joules=43.329, energy_to_solution_joules_estimate=43.329, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=64.500, gpu_power_mw_p50=65, gpu_power_mw_p75=66, gpu_power_mw_p95=70, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.375, iteration=3, low_power_mode=false, matched_process_lines=5, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=19.656, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=18, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=19.394, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780204327719-0429c908 | cargo-build | conjet | 15.073 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.521, combined_power_mw_max=1194, combined_power_mw_mean=521.077, combined_power_mw_p50=333, combined_power_mw_p75=589, combined_power_mw_p95=1194, combined_power_mw_p99=1194, combined_power_mw_stddev=330.882, cpu_energy_to_solution_joules_estimate=0.112, cpu_power_mw_max=1134, cpu_power_mw_mean=459.231, cpu_power_mw_p50=269, cpu_power_mw_p75=525, cpu_power_mw_p95=1134, cpu_power_mw_p99=1134, cpu_power_mw_stddev=330.596, cpu_power_watts=0.459, energy_to_solution_joules=0.127, energy_to_solution_joules_estimate=0.127, energy_verdict=measured, gpu_power_mw_max=67, gpu_power_mw_mean=61.885, gpu_power_mw_p50=62, gpu_power_mw_p75=65, gpu_power_mw_p95=67, gpu_power_mw_p99=67, gpu_power_mw_stddev=2.873, iteration=3, low_power_mode=false, matched_process_lines=3, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.030, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.243, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780204342854-d5c25267 | idle-power-sample | orbstack | 32.185 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.534, combined_power_mw_max=1462, combined_power_mw_mean=533.833, combined_power_mw_p50=459, combined_power_mw_p75=638, combined_power_mw_p95=1230, combined_power_mw_p99=1462, combined_power_mw_stddev=300.302, cpu_power_mw_max=1400, cpu_power_mw_mean=473.467, cpu_power_mw_p50=396, cpu_power_mw_p75=572, cpu_power_mw_p95=1172, cpu_power_mw_p99=1400, cpu_power_mw_stddev=300.514, cpu_power_watts=0.473, energy_verdict=measured, gpu_power_mw_max=66, gpu_power_mw_mean=60.183, gpu_power_mw_p50=60, gpu_power_mw_p75=62, gpu_power_mw_p95=64, gpu_power_mw_p99=66, gpu_power_mw_stddev=2.520, idle_power_watts=0.534, iteration=3, low_power_mode=false, matched_process_lines=39, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780204375161-b15f0ce3 | container-start-loop | orbstack | 16.317 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.466, combined_power_mw_max=2654, combined_power_mw_mean=1465.571, combined_power_mw_p50=1467, combined_power_mw_p75=1622, combined_power_mw_p95=2654, combined_power_mw_p99=2654, combined_power_mw_stddev=446.178, cpu_energy_to_solution_joules_estimate=22.481, cpu_power_mw_max=2592, cpu_power_mw_mean=1403.643, cpu_power_mw_p50=1409, cpu_power_mw_p75=1556, cpu_power_mw_p95=2592, cpu_power_mw_p99=2592, cpu_power_mw_stddev=445.666, cpu_power_watts=1.404, energy_to_solution_joules=23.473, energy_to_solution_joules_estimate=23.473, energy_verdict=measured, gpu_power_mw_max=66, gpu_power_mw_mean=62.214, gpu_power_mw_p50=62, gpu_power_mw_p75=64, gpu_power_mw_p95=66, gpu_power_mw_p99=66, gpu_power_mw_stddev=2.411, iteration=3, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.285, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.016, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780204391544-c0a5e5f6 | hot-reload-loop | orbstack | 15.396 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.574, combined_power_mw_max=2125, combined_power_mw_mean=1573.923, combined_power_mw_p50=1542, combined_power_mw_p75=1928, combined_power_mw_p95=2125, combined_power_mw_p99=2125, combined_power_mw_stddev=372.720, cpu_energy_to_solution_joules_estimate=22.803, cpu_power_mw_max=2057, cpu_power_mw_mean=1509.923, cpu_power_mw_p50=1480, cpu_power_mw_p75=1859, cpu_power_mw_p95=2057, cpu_power_mw_p99=2057, cpu_power_mw_stddev=372.199, cpu_power_watts=1.510, energy_to_solution_joules=23.770, energy_to_solution_joules_estimate=23.770, energy_verdict=measured, gpu_power_mw_max=69, gpu_power_mw_mean=63.962, gpu_power_mw_p50=63, gpu_power_mw_p75=65, gpu_power_mw_p95=69, gpu_power_mw_p99=69, gpu_power_mw_stddev=2.361, iteration=3, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.366, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.102, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780204407008-953aca92 | compose-loop | orbstack | 15.264 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.711, combined_power_mw_max=3435, combined_power_mw_mean=1711.231, combined_power_mw_p50=1590, combined_power_mw_p75=1853, combined_power_mw_p95=3435, combined_power_mw_p99=3435, combined_power_mw_stddev=599.874, cpu_energy_to_solution_joules_estimate=24.692, cpu_power_mw_max=3375, cpu_power_mw_mean=1649.462, cpu_power_mw_p50=1532, cpu_power_mw_p75=1791, cpu_power_mw_p95=3375, cpu_power_mw_p99=3375, cpu_power_mw_stddev=600.361, cpu_power_watts=1.649, energy_to_solution_joules=25.617, energy_to_solution_joules_estimate=25.617, energy_verdict=measured, gpu_power_mw_max=68, gpu_power_mw_mean=61.769, gpu_power_mw_p50=62, gpu_power_mw_p75=62, gpu_power_mw_p95=67, gpu_power_mw_p99=68, gpu_power_mw_stddev=2.665, iteration=3, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.233, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.970, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780204422327-09660b99 | npm-install | orbstack | 15.851 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.089, combined_power_mw_max=3173, combined_power_mw_mean=2088.857, combined_power_mw_p50=2007, combined_power_mw_p75=2478, combined_power_mw_p95=3173, combined_power_mw_p99=3173, combined_power_mw_stddev=637.584, cpu_energy_to_solution_joules_estimate=31.489, cpu_power_mw_max=3106, cpu_power_mw_mean=2025.071, cpu_power_mw_p50=1943, cpu_power_mw_p75=2415, cpu_power_mw_p95=3106, cpu_power_mw_p99=3106, cpu_power_mw_stddev=636.960, cpu_power_watts=2.025, energy_to_solution_joules=32.481, energy_to_solution_joules_estimate=32.481, energy_verdict=measured, gpu_power_mw_max=69, gpu_power_mw_mean=63.857, gpu_power_mw_p50=64, gpu_power_mw_p75=66, gpu_power_mw_p95=68, gpu_power_mw_p99=69, gpu_power_mw_stddev=2.460, iteration=3, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.818, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.550, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780204438236-0f0091ad | pnpm-install | orbstack | 17.414 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.437, combined_power_mw_max=3703, combined_power_mw_mean=2437.467, combined_power_mw_p50=2739, combined_power_mw_p75=3058, combined_power_mw_p95=3703, combined_power_mw_p99=3703, combined_power_mw_stddev=827.201, cpu_energy_to_solution_joules_estimate=40.641, cpu_power_mw_max=3641, cpu_power_mw_mean=2374.200, cpu_power_mw_p50=2679, cpu_power_mw_p75=2991, cpu_power_mw_p95=3641, cpu_power_mw_p99=3641, cpu_power_mw_stddev=826.218, cpu_power_watts=2.374, energy_to_solution_joules=41.724, energy_to_solution_joules_estimate=41.724, energy_verdict=measured, gpu_power_mw_max=67, gpu_power_mw_mean=63.267, gpu_power_mw_p50=63, gpu_power_mw_p75=65, gpu_power_mw_p95=67, gpu_power_mw_p99=67, gpu_power_mw_stddev=2.265, iteration=3, low_power_mode=false, matched_process_lines=32, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=17.382, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=15, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=17.118, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780204455712-5143d9c9 | cargo-build | orbstack | 15.064 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.654, combined_power_mw_max=2160, combined_power_mw_mean=654.154, combined_power_mw_p50=329, combined_power_mw_p75=927, combined_power_mw_p95=2160, combined_power_mw_p99=2160, combined_power_mw_stddev=526.809, cpu_energy_to_solution_joules_estimate=1.050, cpu_power_mw_max=2093, cpu_power_mw_mean=592.077, cpu_power_mw_p50=263, cpu_power_mw_p75=865, cpu_power_mw_p95=2093, cpu_power_mw_p99=2093, cpu_power_mw_stddev=526.239, cpu_power_watts=0.592, energy_to_solution_joules=1.160, energy_to_solution_joules_estimate=1.160, energy_verdict=measured, gpu_power_mw_max=69, gpu_power_mw_mean=62, gpu_power_mw_p50=61, gpu_power_mw_p75=65, gpu_power_mw_p95=69, gpu_power_mw_p99=69, gpu_power_mw_stddev=3.669, iteration=3, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.023, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.774, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780204470842-f978f0ed | idle-power-sample | conjet | 32.182 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.413, combined_power_mw_max=876, combined_power_mw_mean=413.133, combined_power_mw_p50=340, combined_power_mw_p75=487, combined_power_mw_p95=865, combined_power_mw_p99=876, combined_power_mw_stddev=191.868, cpu_power_mw_max=823, cpu_power_mw_mean=354.733, cpu_power_mw_p50=276, cpu_power_mw_p75=426, cpu_power_mw_p95=809, cpu_power_mw_p99=823, cpu_power_mw_stddev=191.784, cpu_power_watts=0.355, energy_verdict=measured, gpu_power_mw_max=64, gpu_power_mw_mean=58.633, gpu_power_mw_p50=58, gpu_power_mw_p75=61, gpu_power_mw_p95=63, gpu_power_mw_p99=64, gpu_power_mw_stddev=2.757, idle_power_watts=0.413, iteration=4, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780204503145-24e67d1d | container-start-loop | conjet | 15.038 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.798, combined_power_mw_max=5445, combined_power_mw_mean=4797.615, combined_power_mw_p50=4784, combined_power_mw_p75=4985, combined_power_mw_p95=5445, combined_power_mw_p99=5445, combined_power_mw_stddev=321.062, cpu_energy_to_solution_joules_estimate=69.586, cpu_power_mw_max=5376, cpu_power_mw_mean=4732.538, cpu_power_mw_p50=4717, cpu_power_mw_p75=4914, cpu_power_mw_p95=5376, cpu_power_mw_p99=5376, cpu_power_mw_stddev=321.597, cpu_power_watts=4.733, energy_to_solution_joules=70.543, energy_to_solution_joules_estimate=70.543, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=65.038, gpu_power_mw_p50=66, gpu_power_mw_p75=68, gpu_power_mw_p95=71, gpu_power_mw_p99=71, gpu_power_mw_stddev=4.155, iteration=4, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.013, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.704, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780204518236-fa4864ab | hot-reload-loop | conjet | 15.058 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.642, combined_power_mw_max=5389, combined_power_mw_mean=4642, combined_power_mw_p50=4456, combined_power_mw_p75=5054, combined_power_mw_p95=5389, combined_power_mw_p99=5389, combined_power_mw_stddev=425.231, cpu_energy_to_solution_joules_estimate=66.723, cpu_power_mw_max=5321, cpu_power_mw_mean=4572.769, cpu_power_mw_p50=4388, cpu_power_mw_p75=4986, cpu_power_mw_p95=5321, cpu_power_mw_p99=5321, cpu_power_mw_stddev=424.784, cpu_power_watts=4.573, energy_to_solution_joules=67.733, energy_to_solution_joules_estimate=67.733, energy_verdict=measured, gpu_power_mw_max=76, gpu_power_mw_mean=69.115, gpu_power_mw_p50=68, gpu_power_mw_p75=71, gpu_power_mw_p95=75, gpu_power_mw_p99=76, gpu_power_mw_stddev=2.577, iteration=4, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.016, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.591, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780204533351-ee31921a | compose-loop | conjet | 15.061 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.704, combined_power_mw_max=5415, combined_power_mw_mean=4703.692, combined_power_mw_p50=4600, combined_power_mw_p75=4791, combined_power_mw_p95=5415, combined_power_mw_p99=5415, combined_power_mw_stddev=289.587, cpu_energy_to_solution_joules_estimate=67.590, cpu_power_mw_max=5345, cpu_power_mw_mean=4633.615, cpu_power_mw_p50=4529, cpu_power_mw_p75=4720, cpu_power_mw_p95=5345, cpu_power_mw_p99=5345, cpu_power_mw_stddev=289.273, cpu_power_watts=4.634, energy_to_solution_joules=68.612, energy_to_solution_joules_estimate=68.612, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=70.038, gpu_power_mw_p50=70, gpu_power_mw_p75=72, gpu_power_mw_p95=73, gpu_power_mw_p99=74, gpu_power_mw_stddev=2.121, iteration=4, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.016, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.587, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780204548470-c4ecdaac | npm-install | conjet | 15.315 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.926, combined_power_mw_max=3871, combined_power_mw_mean=2925.615, combined_power_mw_p50=2846, combined_power_mw_p75=3382, combined_power_mw_p95=3871, combined_power_mw_p99=3871, combined_power_mw_stddev=584.013, cpu_energy_to_solution_joules_estimate=42.948, cpu_power_mw_max=3801, cpu_power_mw_mean=2857.308, cpu_power_mw_p50=2781, cpu_power_mw_p75=3313, cpu_power_mw_p95=3801, cpu_power_mw_p99=3801, cpu_power_mw_stddev=583.553, cpu_power_watts=2.857, energy_to_solution_joules=43.975, energy_to_solution_joules_estimate=43.975, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=68.192, gpu_power_mw_p50=68, gpu_power_mw_p75=69, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=1.732, iteration=4, low_power_mode=false, matched_process_lines=13, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.292, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.031, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780204563836-c43ec4e4 | pnpm-install | conjet | 16.583 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.165, combined_power_mw_max=4711, combined_power_mw_mean=3164.933, combined_power_mw_p50=3214, combined_power_mw_p75=3646, combined_power_mw_p95=4711, combined_power_mw_p99=4711, combined_power_mw_stddev=729.519, cpu_energy_to_solution_joules_estimate=50.471, cpu_power_mw_max=4643, cpu_power_mw_mean=3097.067, cpu_power_mw_p50=3151, cpu_power_mw_p75=3577, cpu_power_mw_p95=4643, cpu_power_mw_p99=4643, cpu_power_mw_stddev=730.105, cpu_power_watts=3.097, energy_to_solution_joules=51.577, energy_to_solution_joules_estimate=51.577, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=67.967, gpu_power_mw_p50=68, gpu_power_mw_p75=69, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.152, iteration=4, low_power_mode=false, matched_process_lines=6, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.559, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=15, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.296, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780204580470-839aaf10 | cargo-build | conjet | 15.055 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.472, combined_power_mw_max=937, combined_power_mw_mean=471.538, combined_power_mw_p50=390, combined_power_mw_p75=440, combined_power_mw_p95=937, combined_power_mw_p99=937, combined_power_mw_stddev=228.194, cpu_energy_to_solution_joules_estimate=0.085, cpu_power_mw_max=872, cpu_power_mw_mean=405, cpu_power_mw_p50=323, cpu_power_mw_p75=374, cpu_power_mw_p95=872, cpu_power_mw_p99=872, cpu_power_mw_stddev=228.344, cpu_power_watts=0.405, energy_to_solution_joules=0.099, energy_to_solution_joules_estimate=0.099, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=66.231, gpu_power_mw_p50=66, gpu_power_mw_p75=69, gpu_power_mw_p95=71, gpu_power_mw_p99=71, gpu_power_mw_stddev=2.886, iteration=4, low_power_mode=false, matched_process_lines=2, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.026, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.210, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780204595601-9930bcfe | idle-power-sample | orbstack | 32.300 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.377, combined_power_mw_max=777, combined_power_mw_mean=376.633, combined_power_mw_p50=319, combined_power_mw_p75=354, combined_power_mw_p95=774, combined_power_mw_p99=777, combined_power_mw_stddev=197.096, cpu_power_mw_max=713, cpu_power_mw_mean=316.867, cpu_power_mw_p50=259, cpu_power_mw_p75=294, cpu_power_mw_p95=712, cpu_power_mw_p99=713, cpu_power_mw_stddev=197.356, cpu_power_watts=0.317, energy_verdict=measured, gpu_power_mw_max=66, gpu_power_mw_mean=59.800, gpu_power_mw_p50=60, gpu_power_mw_p75=61, gpu_power_mw_p95=65, gpu_power_mw_p99=66, gpu_power_mw_stddev=2.682, idle_power_watts=0.377, iteration=4, low_power_mode=false, matched_process_lines=41, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780204628016-5c0d30ba | container-start-loop | orbstack | 15.991 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.563, combined_power_mw_max=2425, combined_power_mw_mean=1562.786, combined_power_mw_p50=1492, combined_power_mw_p75=1828, combined_power_mw_p95=2425, combined_power_mw_p99=2425, combined_power_mw_stddev=434.464, cpu_energy_to_solution_joules_estimate=23.567, cpu_power_mw_max=2366, cpu_power_mw_mean=1501.714, cpu_power_mw_p50=1428, cpu_power_mw_p75=1762, cpu_power_mw_p95=2366, cpu_power_mw_p99=2366, cpu_power_mw_stddev=435.169, cpu_power_watts=1.502, energy_to_solution_joules=24.526, energy_to_solution_joules_estimate=24.526, energy_verdict=measured, gpu_power_mw_max=66, gpu_power_mw_mean=61.214, gpu_power_mw_p50=61, gpu_power_mw_p75=62, gpu_power_mw_p95=66, gpu_power_mw_p99=66, gpu_power_mw_stddev=2.320, iteration=4, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.957, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.693, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780204644066-87638f3d | hot-reload-loop | orbstack | 16.450 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.614, combined_power_mw_max=1933, combined_power_mw_mean=1614, combined_power_mw_p50=1670, combined_power_mw_p75=1786, combined_power_mw_p95=1933, combined_power_mw_p99=1933, combined_power_mw_stddev=203.610, cpu_energy_to_solution_joules_estimate=25.077, cpu_power_mw_max=1871, cpu_power_mw_mean=1551.929, cpu_power_mw_p50=1608, cpu_power_mw_p75=1726, cpu_power_mw_p95=1871, cpu_power_mw_p99=1871, cpu_power_mw_stddev=202.337, cpu_power_watts=1.552, energy_to_solution_joules=26.080, energy_to_solution_joules_estimate=26.080, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=61.857, gpu_power_mw_p50=61, gpu_power_mw_p75=62, gpu_power_mw_p95=70, gpu_power_mw_p99=70, gpu_power_mw_stddev=2.973, iteration=4, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.418, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.158, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780204660573-8168da81 | compose-loop | orbstack | 15.884 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.069, combined_power_mw_max=4114, combined_power_mw_mean=2068.571, combined_power_mw_p50=1844, combined_power_mw_p75=2649, combined_power_mw_p95=4114, combined_power_mw_p99=4114, combined_power_mw_stddev=826.525, cpu_energy_to_solution_joules_estimate=31.222, cpu_power_mw_max=4051, cpu_power_mw_mean=2003.214, cpu_power_mw_p50=1773, cpu_power_mw_p75=2574, cpu_power_mw_p95=4051, cpu_power_mw_p99=4051, cpu_power_mw_stddev=826.241, cpu_power_watts=2.003, energy_to_solution_joules=32.240, energy_to_solution_joules_estimate=32.240, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=65.500, gpu_power_mw_p50=65, gpu_power_mw_p75=69, gpu_power_mw_p95=75, gpu_power_mw_p99=75, gpu_power_mw_stddev=4.136, iteration=4, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.852, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.586, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780204676519-042d3686 | npm-install | orbstack | 15.060 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.258, combined_power_mw_max=2991, combined_power_mw_mean=2258.231, combined_power_mw_p50=2225, combined_power_mw_p75=2850, combined_power_mw_p95=2991, combined_power_mw_p99=2991, combined_power_mw_stddev=580.557, cpu_energy_to_solution_joules_estimate=31.988, cpu_power_mw_max=2920, cpu_power_mw_mean=2193.308, cpu_power_mw_p50=2161, cpu_power_mw_p75=2784, cpu_power_mw_p95=2920, cpu_power_mw_p99=2920, cpu_power_mw_stddev=578.523, cpu_power_watts=2.193, energy_to_solution_joules=32.935, energy_to_solution_joules_estimate=32.935, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=65.038, gpu_power_mw_p50=65, gpu_power_mw_p75=66, gpu_power_mw_p95=71, gpu_power_mw_p99=71, gpu_power_mw_stddev=3.228, iteration=4, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.008, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.584, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780204691640-cb94dd89 | pnpm-install | orbstack | 17.181 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.354, combined_power_mw_max=3936, combined_power_mw_mean=2354, combined_power_mw_p50=2278, combined_power_mw_p75=2846, combined_power_mw_p95=3936, combined_power_mw_p99=3936, combined_power_mw_stddev=889.058, cpu_energy_to_solution_joules_estimate=38.658, cpu_power_mw_max=3873, cpu_power_mw_mean=2290.133, cpu_power_mw_p50=2214, cpu_power_mw_p75=2783, cpu_power_mw_p95=3873, cpu_power_mw_p99=3873, cpu_power_mw_stddev=888.815, cpu_power_watts=2.290, energy_to_solution_joules=39.736, energy_to_solution_joules_estimate=39.736, energy_verdict=measured, gpu_power_mw_max=68, gpu_power_mw_mean=63.833, gpu_power_mw_p50=63, gpu_power_mw_p75=66, gpu_power_mw_p95=68, gpu_power_mw_p99=68, gpu_power_mw_stddev=2.222, iteration=4, low_power_mode=false, matched_process_lines=32, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=17.146, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=15, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.880, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780204708888-aa82aaf2 | cargo-build | orbstack | 15.059 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.504, combined_power_mw_max=1941, combined_power_mw_mean=504.385, combined_power_mw_p50=329, combined_power_mw_p75=454, combined_power_mw_p95=1941, combined_power_mw_p99=1941, combined_power_mw_stddev=459.185, cpu_energy_to_solution_joules_estimate=0.746, cpu_power_mw_max=1875, cpu_power_mw_mean=443.615, cpu_power_mw_p50=264, cpu_power_mw_p75=395, cpu_power_mw_p95=1875, cpu_power_mw_p99=1875, cpu_power_mw_stddev=458.214, cpu_power_watts=0.444, energy_to_solution_joules=0.848, energy_to_solution_joules_estimate=0.848, energy_verdict=measured, gpu_power_mw_max=68, gpu_power_mw_mean=60.962, gpu_power_mw_p50=61, gpu_power_mw_p75=63, gpu_power_mw_p95=67, gpu_power_mw_p99=68, gpu_power_mw_stddev=3.458, iteration=4, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.023, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.682, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780204724016-b6147cce | idle-power-sample | conjet | 32.348 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.462, combined_power_mw_max=2512, combined_power_mw_mean=461.500, combined_power_mw_p50=275, combined_power_mw_p75=354, combined_power_mw_p95=1090, combined_power_mw_p99=2512, combined_power_mw_stddev=477.414, cpu_power_mw_max=2447, cpu_power_mw_mean=403.933, cpu_power_mw_p50=213, cpu_power_mw_p75=297, cpu_power_mw_p95=1034, cpu_power_mw_p99=2447, cpu_power_mw_stddev=476.472, cpu_power_watts=0.404, energy_verdict=measured, gpu_power_mw_max=65, gpu_power_mw_mean=57.633, gpu_power_mw_p50=58, gpu_power_mw_p75=59, gpu_power_mw_p95=62, gpu_power_mw_p99=65, gpu_power_mw_stddev=2.449, idle_power_watts=0.462, iteration=5, low_power_mode=false, matched_process_lines=2, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780204756494-fe72e668 | container-start-loop | conjet | 15.028 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.731, combined_power_mw_max=5567, combined_power_mw_mean=4731, combined_power_mw_p50=4601, combined_power_mw_p75=4821, combined_power_mw_p95=5567, combined_power_mw_p99=5567, combined_power_mw_stddev=425.812, cpu_energy_to_solution_joules_estimate=67.347, cpu_power_mw_max=5502, cpu_power_mw_mean=4668.308, cpu_power_mw_p50=4541, cpu_power_mw_p75=4759, cpu_power_mw_p95=5502, cpu_power_mw_p99=5502, cpu_power_mw_stddev=424.161, cpu_power_watts=4.668, energy_to_solution_joules=68.251, energy_to_solution_joules_estimate=68.251, energy_verdict=measured, gpu_power_mw_max=66, gpu_power_mw_mean=62.500, gpu_power_mw_p50=63, gpu_power_mw_p75=65, gpu_power_mw_p95=66, gpu_power_mw_p99=66, gpu_power_mw_stddev=2.735, iteration=5, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.005, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.426, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780204771575-ae2d8253 | hot-reload-loop | conjet | 15.070 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.639, combined_power_mw_max=5354, combined_power_mw_mean=4638.846, combined_power_mw_p50=4573, combined_power_mw_p75=4804, combined_power_mw_p95=5354, combined_power_mw_p99=5354, combined_power_mw_stddev=324.638, cpu_energy_to_solution_joules_estimate=65.608, cpu_power_mw_max=5285, cpu_power_mw_mean=4571.385, cpu_power_mw_p50=4508, cpu_power_mw_p75=4735, cpu_power_mw_p95=5285, cpu_power_mw_p99=5285, cpu_power_mw_stddev=323.752, cpu_power_watts=4.571, energy_to_solution_joules=66.576, energy_to_solution_joules_estimate=66.576, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=67.231, gpu_power_mw_p50=67, gpu_power_mw_p75=69, gpu_power_mw_p95=69, gpu_power_mw_p99=70, gpu_power_mw_stddev=1.527, iteration=5, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.018, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.352, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780204786717-66bc5385 | compose-loop | conjet | 15.061 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.646, combined_power_mw_max=5746, combined_power_mw_mean=4646.077, combined_power_mw_p50=4537, combined_power_mw_p75=4649, combined_power_mw_p95=5746, combined_power_mw_p99=5746, combined_power_mw_stddev=398.066, cpu_energy_to_solution_joules_estimate=64.813, cpu_power_mw_max=5680, cpu_power_mw_mean=4576.615, cpu_power_mw_p50=4463, cpu_power_mw_p75=4580, cpu_power_mw_p95=5680, cpu_power_mw_p99=5680, cpu_power_mw_stddev=398.538, cpu_power_watts=4.577, energy_to_solution_joules=65.797, energy_to_solution_joules_estimate=65.797, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=69.308, gpu_power_mw_p50=69, gpu_power_mw_p75=70, gpu_power_mw_p95=74, gpu_power_mw_p99=74, gpu_power_mw_stddev=2.034, iteration=5, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.027, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.162, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780204801847-e4deaa44 | npm-install | conjet | 16.044 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.022, combined_power_mw_max=3708, combined_power_mw_mean=3022.500, combined_power_mw_p50=3099, combined_power_mw_p75=3219, combined_power_mw_p95=3708, combined_power_mw_p99=3708, combined_power_mw_stddev=508.543, cpu_energy_to_solution_joules_estimate=46.570, cpu_power_mw_max=3642, cpu_power_mw_mean=2955.571, cpu_power_mw_p50=3029, cpu_power_mw_p75=3152, cpu_power_mw_p95=3642, cpu_power_mw_p99=3642, cpu_power_mw_stddev=508.113, cpu_power_watts=2.956, energy_to_solution_joules=47.625, energy_to_solution_joules_estimate=47.625, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=66.893, gpu_power_mw_p50=67, gpu_power_mw_p75=69, gpu_power_mw_p95=70, gpu_power_mw_p99=70, gpu_power_mw_stddev=1.896, iteration=5, low_power_mode=false, matched_process_lines=15, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.020, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.757, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780204817951-d38f4dde | pnpm-install | conjet | 15.971 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.655, combined_power_mw_max=3968, combined_power_mw_mean=2655, combined_power_mw_p50=2567, combined_power_mw_p75=3482, combined_power_mw_p95=3968, combined_power_mw_p99=3968, combined_power_mw_stddev=958.274, cpu_energy_to_solution_joules_estimate=40.611, cpu_power_mw_max=3899, cpu_power_mw_mean=2589.143, cpu_power_mw_p50=2500, cpu_power_mw_p75=3415, cpu_power_mw_p95=3899, cpu_power_mw_p99=3899, cpu_power_mw_stddev=957.848, cpu_power_watts=2.589, energy_to_solution_joules=41.644, energy_to_solution_joules_estimate=41.644, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=65.750, gpu_power_mw_p50=65, gpu_power_mw_p75=67, gpu_power_mw_p95=69, gpu_power_mw_p99=70, gpu_power_mw_stddev=1.765, iteration=5, low_power_mode=false, matched_process_lines=5, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.948, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.685, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780204833974-4c160eea | cargo-build | conjet | 15.036 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.387, combined_power_mw_max=700, combined_power_mw_mean=386.615, combined_power_mw_p50=319, combined_power_mw_p75=442, combined_power_mw_p95=700, combined_power_mw_p99=700, combined_power_mw_stddev=160.223, cpu_energy_to_solution_joules_estimate=0.072, cpu_power_mw_max=638, cpu_power_mw_mean=323.538, cpu_power_mw_p50=257, cpu_power_mw_p75=381, cpu_power_mw_p95=638, cpu_power_mw_p99=638, cpu_power_mw_stddev=160.208, cpu_power_watts=0.324, energy_to_solution_joules=0.086, energy_to_solution_joules_estimate=0.086, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=63, gpu_power_mw_p50=62, gpu_power_mw_p75=64, gpu_power_mw_p95=70, gpu_power_mw_p99=70, gpu_power_mw_stddev=3.051, iteration=5, low_power_mode=false, matched_process_lines=3, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.007, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.222, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780204849068-a8a3e8d6 | idle-power-sample | orbstack | 32.253 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.506, combined_power_mw_max=1187, combined_power_mw_mean=506.333, combined_power_mw_p50=445, combined_power_mw_p75=576, combined_power_mw_p95=1122, combined_power_mw_p99=1187, combined_power_mw_stddev=222.076, cpu_power_mw_max=1126, cpu_power_mw_mean=447.133, cpu_power_mw_p50=385, cpu_power_mw_p75=516, cpu_power_mw_p95=1066, cpu_power_mw_p99=1126, cpu_power_mw_stddev=222.061, cpu_power_watts=0.447, energy_verdict=measured, gpu_power_mw_max=63, gpu_power_mw_mean=59.317, gpu_power_mw_p50=60, gpu_power_mw_p75=60, gpu_power_mw_p95=63, gpu_power_mw_p99=63, gpu_power_mw_stddev=1.962, idle_power_watts=0.506, iteration=5, low_power_mode=false, matched_process_lines=40, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780204881436-b8ebcdf4 | container-start-loop | orbstack | 15.237 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.905, combined_power_mw_max=2674, combined_power_mw_mean=1905.308, combined_power_mw_p50=1731, combined_power_mw_p75=2324, combined_power_mw_p95=2674, combined_power_mw_p99=2674, combined_power_mw_stddev=459.031, cpu_energy_to_solution_joules_estimate=27.564, cpu_power_mw_max=2624, cpu_power_mw_mean=1845.231, cpu_power_mw_p50=1667, cpu_power_mw_p75=2212, cpu_power_mw_p95=2624, cpu_power_mw_p99=2624, cpu_power_mw_stddev=455.990, cpu_power_watts=1.845, energy_to_solution_joules=28.461, energy_to_solution_joules_estimate=28.461, energy_verdict=measured, gpu_power_mw_max=112, gpu_power_mw_mean=59.885, gpu_power_mw_p50=58, gpu_power_mw_p75=66, gpu_power_mw_p95=112, gpu_power_mw_p99=112, gpu_power_mw_stddev=21.228, iteration=5, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.201, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.938, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780204896731-be2eef32 | hot-reload-loop | orbstack | 15.611 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.922, combined_power_mw_max=3781, combined_power_mw_mean=1921.857, combined_power_mw_p50=1673, combined_power_mw_p75=2244, combined_power_mw_p95=3781, combined_power_mw_p99=3781, combined_power_mw_stddev=604.920, cpu_energy_to_solution_joules_estimate=28.838, cpu_power_mw_max=3710, cpu_power_mw_mean=1882.286, cpu_power_mw_p50=1644, cpu_power_mw_p75=2212, cpu_power_mw_p95=3710, cpu_power_mw_p99=3710, cpu_power_mw_stddev=593.716, cpu_power_watts=1.882, energy_to_solution_joules=29.444, energy_to_solution_joules_estimate=29.444, energy_verdict=measured, gpu_power_mw_max=82, gpu_power_mw_mean=39.286, gpu_power_mw_p50=32, gpu_power_mw_p75=46, gpu_power_mw_p95=81, gpu_power_mw_p99=82, gpu_power_mw_stddev=16.771, iteration=5, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.579, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.321, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780204912400-9cf81417 | compose-loop | orbstack | 15.569 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.010, combined_power_mw_max=5149, combined_power_mw_mean=2010.286, combined_power_mw_p50=1825, combined_power_mw_p75=1953, combined_power_mw_p95=5149, combined_power_mw_p99=5149, combined_power_mw_stddev=931.702, cpu_energy_to_solution_joules_estimate=29.876, cpu_power_mw_max=5012, cpu_power_mw_mean=1956.500, cpu_power_mw_p50=1762, cpu_power_mw_p75=1850, cpu_power_mw_p95=5012, cpu_power_mw_p99=5012, cpu_power_mw_stddev=908.004, cpu_power_watts=1.956, energy_to_solution_joules=30.697, energy_to_solution_joules_estimate=30.697, energy_verdict=measured, gpu_power_mw_max=137, gpu_power_mw_mean=53.714, gpu_power_mw_p50=43, gpu_power_mw_p75=66, gpu_power_mw_p95=136, gpu_power_mw_p99=137, gpu_power_mw_stddev=31.295, iteration=5, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.529, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.270, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780204928024-4161656d | npm-install | orbstack | 16.467 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.592, combined_power_mw_max=5614, combined_power_mw_mean=3592, combined_power_mw_p50=3392, combined_power_mw_p75=4710, combined_power_mw_p95=5614, combined_power_mw_p99=5614, combined_power_mw_stddev=1137.315, cpu_energy_to_solution_joules_estimate=50.744, cpu_power_mw_max=4724, cpu_power_mw_mean=3139.786, cpu_power_mw_p50=3256, cpu_power_mw_p75=3906, cpu_power_mw_p95=4724, cpu_power_mw_p99=4724, cpu_power_mw_stddev=933.616, cpu_power_watts=3.140, energy_to_solution_joules=58.052, energy_to_solution_joules_estimate=58.052, energy_verdict=measured, gpu_power_mw_max=1190, gpu_power_mw_mean=452.107, gpu_power_mw_p50=523, gpu_power_mw_p75=724, gpu_power_mw_p95=1176, gpu_power_mw_p99=1190, gpu_power_mw_stddev=417.094, iteration=5, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.428, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.161, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780204944562-ba977a5c | pnpm-install | orbstack | 15.040 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.914, combined_power_mw_max=4643, combined_power_mw_mean=2913.846, combined_power_mw_p50=3070, combined_power_mw_p75=3526, combined_power_mw_p95=4643, combined_power_mw_p99=4643, combined_power_mw_stddev=898.382, cpu_energy_to_solution_joules_estimate=37.309, cpu_power_mw_max=3696, cpu_power_mw_mean=2558.231, cpu_power_mw_p50=2731, cpu_power_mw_p75=3096, cpu_power_mw_p95=3696, cpu_power_mw_p99=3696, cpu_power_mw_stddev=824.179, cpu_power_watts=2.558, energy_to_solution_joules=42.495, energy_to_solution_joules_estimate=42.495, energy_verdict=measured, gpu_power_mw_max=1406, gpu_power_mw_mean=355.077, gpu_power_mw_p50=82, gpu_power_mw_p75=638, gpu_power_mw_p95=1396, gpu_power_mw_p99=1406, gpu_power_mw_stddev=408.095, iteration=5, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.006, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.584, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780204959652-622569b9 | cargo-build | orbstack | 15.060 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.001, combined_power_mw_max=2079, combined_power_mw_mean=1001.462, combined_power_mw_p50=784, combined_power_mw_p75=1237, combined_power_mw_p95=2079, combined_power_mw_p99=2079, combined_power_mw_stddev=422.697, cpu_energy_to_solution_joules_estimate=1.768, cpu_power_mw_max=2007, cpu_power_mw_mean=949.538, cpu_power_mw_p50=755, cpu_power_mw_p75=1172, cpu_power_mw_p95=2007, cpu_power_mw_p99=2007, cpu_power_mw_stddev=418.815, cpu_power_watts=0.950, energy_to_solution_joules=1.865, energy_to_solution_joules_estimate=1.865, energy_verdict=measured, gpu_power_mw_max=79, gpu_power_mw_mean=51.731, gpu_power_mw_p50=65, gpu_power_mw_p75=70, gpu_power_mw_p95=79, gpu_power_mw_p99=79, gpu_power_mw_stddev=20.433, iteration=5, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.015, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.862, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780204974768-78ac7697 | idle-power-sample | conjet | 32.262 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.594, combined_power_mw_max=990, combined_power_mw_mean=594.133, combined_power_mw_p50=563, combined_power_mw_p75=648, combined_power_mw_p95=988, combined_power_mw_p99=990, combined_power_mw_stddev=203.563, cpu_power_mw_max=922, cpu_power_mw_mean=528.633, cpu_power_mw_p50=497, cpu_power_mw_p75=583, cpu_power_mw_p95=919, cpu_power_mw_p99=922, cpu_power_mw_stddev=202.968, cpu_power_watts=0.529, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=65.617, gpu_power_mw_p50=65, gpu_power_mw_p75=67, gpu_power_mw_p95=71, gpu_power_mw_p99=74, gpu_power_mw_stddev=2.763, idle_power_watts=0.594, iteration=6, low_power_mode=false, matched_process_lines=4, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780205007140-8310b7bf | container-start-loop | conjet | 15.027 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.979, combined_power_mw_max=5816, combined_power_mw_mean=4979.154, combined_power_mw_p50=4840, combined_power_mw_p75=5089, combined_power_mw_p95=5816, combined_power_mw_p99=5816, combined_power_mw_stddev=407.026, cpu_energy_to_solution_joules_estimate=72.359, cpu_power_mw_max=5749, cpu_power_mw_mean=4907, cpu_power_mw_p50=4767, cpu_power_mw_p75=5018, cpu_power_mw_p95=5749, cpu_power_mw_p99=5749, cpu_power_mw_stddev=407.232, cpu_power_watts=4.907, energy_to_solution_joules=73.423, energy_to_solution_joules_estimate=73.423, energy_verdict=measured, gpu_power_mw_max=78, gpu_power_mw_mean=72.269, gpu_power_mw_p50=72, gpu_power_mw_p75=75, gpu_power_mw_p95=78, gpu_power_mw_p99=78, gpu_power_mw_stddev=3.169, iteration=6, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.004, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.746, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780205022221-ca0775de | hot-reload-loop | conjet | 15.035 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.975, combined_power_mw_max=5732, combined_power_mw_mean=4975.385, combined_power_mw_p50=4948, combined_power_mw_p75=5123, combined_power_mw_p95=5732, combined_power_mw_p99=5732, combined_power_mw_stddev=438.371, cpu_energy_to_solution_joules_estimate=71.933, cpu_power_mw_max=5656, cpu_power_mw_mean=4900.308, cpu_power_mw_p50=4872, cpu_power_mw_p75=5046, cpu_power_mw_p95=5656, cpu_power_mw_p99=5656, cpu_power_mw_stddev=437.231, cpu_power_watts=4.900, energy_to_solution_joules=73.035, energy_to_solution_joules_estimate=73.035, energy_verdict=measured, gpu_power_mw_max=79, gpu_power_mw_mean=75.077, gpu_power_mw_p50=75, gpu_power_mw_p75=76, gpu_power_mw_p95=79, gpu_power_mw_p99=79, gpu_power_mw_stddev=1.730, iteration=6, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.008, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.679, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780205037309-99899688 | compose-loop | conjet | 15.038 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.820, combined_power_mw_max=5355, combined_power_mw_mean=4820.308, combined_power_mw_p50=4806, combined_power_mw_p75=4874, combined_power_mw_p95=5355, combined_power_mw_p99=5355, combined_power_mw_stddev=230.959, cpu_energy_to_solution_joules_estimate=69.485, cpu_power_mw_max=5282, cpu_power_mw_mean=4743.923, cpu_power_mw_p50=4731, cpu_power_mw_p75=4794, cpu_power_mw_p95=5282, cpu_power_mw_p99=5282, cpu_power_mw_stddev=231.625, cpu_power_watts=4.744, energy_to_solution_joules=70.603, energy_to_solution_joules_estimate=70.603, energy_verdict=measured, gpu_power_mw_max=80, gpu_power_mw_mean=76.385, gpu_power_mw_p50=77, gpu_power_mw_p75=77, gpu_power_mw_p95=80, gpu_power_mw_p99=80, gpu_power_mw_stddev=1.883, iteration=6, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.006, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.647, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780205052401-e062c3b4 | npm-install | conjet | 15.869 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.421, combined_power_mw_max=4709, combined_power_mw_mean=3420.714, combined_power_mw_p50=3403, combined_power_mw_p75=3601, combined_power_mw_p95=4709, combined_power_mw_p99=4709, combined_power_mw_stddev=635.146, cpu_energy_to_solution_joules_estimate=52.139, cpu_power_mw_max=4630, cpu_power_mw_mean=3345.143, cpu_power_mw_p50=3323, cpu_power_mw_p75=3527, cpu_power_mw_p95=4630, cpu_power_mw_p99=4630, cpu_power_mw_stddev=634.740, cpu_power_watts=3.345, energy_to_solution_joules=53.316, energy_to_solution_joules_estimate=53.316, energy_verdict=measured, gpu_power_mw_max=81, gpu_power_mw_mean=75.393, gpu_power_mw_p50=76, gpu_power_mw_p75=78, gpu_power_mw_p95=81, gpu_power_mw_p99=81, gpu_power_mw_stddev=3.331, iteration=6, low_power_mode=false, matched_process_lines=13, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.844, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.586, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780205068327-4c909a01 | pnpm-install | conjet | 16.457 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.373, combined_power_mw_max=4130, combined_power_mw_mean=3372.800, combined_power_mw_p50=3360, combined_power_mw_p75=3926, combined_power_mw_p95=4130, combined_power_mw_p99=4130, combined_power_mw_stddev=512.361, cpu_energy_to_solution_joules_estimate=53.349, cpu_power_mw_max=4054, cpu_power_mw_mean=3298.333, cpu_power_mw_p50=3283, cpu_power_mw_p75=3850, cpu_power_mw_p95=4054, cpu_power_mw_p99=4054, cpu_power_mw_stddev=512.386, cpu_power_watts=3.298, energy_to_solution_joules=54.553, energy_to_solution_joules_estimate=54.553, energy_verdict=measured, gpu_power_mw_max=79, gpu_power_mw_mean=74.533, gpu_power_mw_p50=75, gpu_power_mw_p75=76, gpu_power_mw_p95=78, gpu_power_mw_p99=79, gpu_power_mw_stddev=2.432, iteration=6, low_power_mode=false, matched_process_lines=8, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.432, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=15, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.174, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780205084836-dbf52cc5 | cargo-build | conjet | 15.036 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.588, combined_power_mw_max=971, combined_power_mw_mean=587.615, combined_power_mw_p50=494, combined_power_mw_p75=703, combined_power_mw_p95=971, combined_power_mw_p99=971, combined_power_mw_stddev=221.826, cpu_energy_to_solution_joules_estimate=0.121, cpu_power_mw_max=902, cpu_power_mw_mean=517.615, cpu_power_mw_p50=421, cpu_power_mw_p75=629, cpu_power_mw_p95=902, cpu_power_mw_p99=902, cpu_power_mw_stddev=222.255, cpu_power_watts=0.518, energy_to_solution_joules=0.137, energy_to_solution_joules_estimate=0.137, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=69.962, gpu_power_mw_p50=70, gpu_power_mw_p75=72, gpu_power_mw_p95=74, gpu_power_mw_p99=74, gpu_power_mw_stddev=2.653, iteration=6, low_power_mode=false, matched_process_lines=3, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.007, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.233, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780205099926-0b4844ed | idle-power-sample | orbstack | 32.239 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.595, combined_power_mw_max=1143, combined_power_mw_mean=595.467, combined_power_mw_p50=485, combined_power_mw_p75=614, combined_power_mw_p95=1062, combined_power_mw_p99=1143, combined_power_mw_stddev=222.094, cpu_power_mw_max=1074, cpu_power_mw_mean=529.567, cpu_power_mw_p50=419, cpu_power_mw_p75=546, cpu_power_mw_p95=996, cpu_power_mw_p99=1074, cpu_power_mw_stddev=221.424, cpu_power_watts=0.530, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=65.967, gpu_power_mw_p50=66, gpu_power_mw_p75=68, gpu_power_mw_p95=71, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.904, idle_power_watts=0.595, iteration=6, low_power_mode=false, matched_process_lines=41, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780205132282-223bfe61 | container-start-loop | orbstack | 15.170 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.836, combined_power_mw_max=3001, combined_power_mw_mean=1836, combined_power_mw_p50=1667, combined_power_mw_p75=2031, combined_power_mw_p95=3001, combined_power_mw_p99=3001, combined_power_mw_stddev=510.130, cpu_energy_to_solution_joules_estimate=26.285, cpu_power_mw_max=2931, cpu_power_mw_mean=1767, cpu_power_mw_p50=1598, cpu_power_mw_p75=1961, cpu_power_mw_p95=2931, cpu_power_mw_p99=2931, cpu_power_mw_stddev=510.112, cpu_power_watts=1.767, energy_to_solution_joules=27.312, energy_to_solution_joules_estimate=27.312, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=69, gpu_power_mw_p50=69, gpu_power_mw_p75=70, gpu_power_mw_p95=74, gpu_power_mw_p99=75, gpu_power_mw_stddev=2.703, iteration=6, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.140, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.876, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780205147512-d4bc1883 | hot-reload-loop | orbstack | 16.163 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.953, combined_power_mw_max=3305, combined_power_mw_mean=1952.786, combined_power_mw_p50=1854, combined_power_mw_p75=2270, combined_power_mw_p95=3305, combined_power_mw_p99=3305, combined_power_mw_stddev=519.562, cpu_energy_to_solution_joules_estimate=29.864, cpu_power_mw_max=3215, cpu_power_mw_mean=1881.786, cpu_power_mw_p50=1791, cpu_power_mw_p75=2201, cpu_power_mw_p95=3215, cpu_power_mw_p99=3215, cpu_power_mw_stddev=515.413, cpu_power_watts=1.882, energy_to_solution_joules=30.990, energy_to_solution_joules_estimate=30.990, energy_verdict=measured, gpu_power_mw_max=91, gpu_power_mw_mean=71, gpu_power_mw_p50=69, gpu_power_mw_p75=72, gpu_power_mw_p95=90, gpu_power_mw_p99=91, gpu_power_mw_stddev=6.268, iteration=6, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.129, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.870, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780205163732-c5e3e974 | compose-loop | orbstack | 15.075 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.827, combined_power_mw_max=2197, combined_power_mw_mean=1826.538, combined_power_mw_p50=1910, combined_power_mw_p75=2012, combined_power_mw_p95=2197, combined_power_mw_p99=2197, combined_power_mw_stddev=254.707, cpu_energy_to_solution_joules_estimate=24.732, cpu_power_mw_max=2128, cpu_power_mw_mean=1757.231, cpu_power_mw_p50=1838, cpu_power_mw_p75=1940, cpu_power_mw_p95=2128, cpu_power_mw_p99=2128, cpu_power_mw_stddev=252.767, cpu_power_watts=1.757, energy_to_solution_joules=25.707, energy_to_solution_joules_estimate=25.707, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=69.192, gpu_power_mw_p50=69, gpu_power_mw_p75=72, gpu_power_mw_p95=73, gpu_power_mw_p99=74, gpu_power_mw_stddev=3.026, iteration=6, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.019, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.074, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780205178868-f2ea453f | npm-install | orbstack | 15.998 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.355, combined_power_mw_max=3075, combined_power_mw_mean=2355.357, combined_power_mw_p50=2439, combined_power_mw_p75=3042, combined_power_mw_p95=3075, combined_power_mw_p99=3075, combined_power_mw_stddev=686.499, cpu_energy_to_solution_joules_estimate=35.879, cpu_power_mw_max=3002, cpu_power_mw_mean=2285.214, cpu_power_mw_p50=2369, cpu_power_mw_p75=2971, cpu_power_mw_p95=3002, cpu_power_mw_p99=3002, cpu_power_mw_stddev=685.854, cpu_power_watts=2.285, energy_to_solution_joules=36.980, energy_to_solution_joules_estimate=36.980, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=70.357, gpu_power_mw_p50=71, gpu_power_mw_p75=72, gpu_power_mw_p95=74, gpu_power_mw_p99=75, gpu_power_mw_stddev=2.239, iteration=6, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.964, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.701, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780205194925-f75dee67 | pnpm-install | orbstack | 18.757 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.870, combined_power_mw_max=3988, combined_power_mw_mean=2870.353, combined_power_mw_p50=2866, combined_power_mw_p75=3226, combined_power_mw_p95=3988, combined_power_mw_p99=3988, combined_power_mw_stddev=599.299, cpu_energy_to_solution_joules_estimate=51.665, cpu_power_mw_max=3916, cpu_power_mw_mean=2799.235, cpu_power_mw_p50=2793, cpu_power_mw_p75=3150, cpu_power_mw_p95=3916, cpu_power_mw_p99=3916, cpu_power_mw_stddev=598.303, cpu_power_watts=2.799, energy_to_solution_joules=52.978, energy_to_solution_joules_estimate=52.978, energy_verdict=measured, gpu_power_mw_max=76, gpu_power_mw_mean=71.176, gpu_power_mw_p50=72, gpu_power_mw_p75=73, gpu_power_mw_p95=76, gpu_power_mw_p99=76, gpu_power_mw_stddev=2.662, iteration=6, low_power_mode=false, matched_process_lines=36, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=18.720, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=17, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=18.457, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780205213742-217c69b7 | cargo-build | orbstack | 15.032 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.743, combined_power_mw_max=2180, combined_power_mw_mean=743.462, combined_power_mw_p50=561, combined_power_mw_p75=935, combined_power_mw_p95=2180, combined_power_mw_p99=2180, combined_power_mw_stddev=488.077, cpu_energy_to_solution_joules_estimate=1.142, cpu_power_mw_max=2110, cpu_power_mw_mean=676, cpu_power_mw_p50=493, cpu_power_mw_p75=866, cpu_power_mw_p95=2110, cpu_power_mw_p99=2110, cpu_power_mw_stddev=487.372, cpu_power_watts=0.676, energy_to_solution_joules=1.256, energy_to_solution_joules_estimate=1.256, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=67.462, gpu_power_mw_p50=68, gpu_power_mw_p75=70, gpu_power_mw_p95=70, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.530, iteration=6, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.007, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.689, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780205228827-680b0a0b | idle-power-sample | conjet | 32.036 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.630, combined_power_mw_max=1121, combined_power_mw_mean=630.300, combined_power_mw_p50=572, combined_power_mw_p75=780, combined_power_mw_p95=1043, combined_power_mw_p99=1121, combined_power_mw_stddev=219.364, cpu_power_mw_max=1059, cpu_power_mw_mean=564.900, cpu_power_mw_p50=503, cpu_power_mw_p75=717, cpu_power_mw_p95=975, cpu_power_mw_p99=1059, cpu_power_mw_stddev=220.269, cpu_power_watts=0.565, energy_verdict=measured, gpu_power_mw_max=69, gpu_power_mw_mean=65.450, gpu_power_mw_p50=65, gpu_power_mw_p75=67, gpu_power_mw_p95=69, gpu_power_mw_p99=69, gpu_power_mw_stddev=2.085, idle_power_watts=0.630, iteration=7, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780205260963-bb0217f4 | container-start-loop | conjet | 15.196 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.173, combined_power_mw_max=5717, combined_power_mw_mean=5172.769, combined_power_mw_p50=5187, combined_power_mw_p75=5457, combined_power_mw_p95=5717, combined_power_mw_p99=5717, combined_power_mw_stddev=372.978, cpu_energy_to_solution_joules_estimate=76.076, cpu_power_mw_max=5648, cpu_power_mw_mean=5100.846, cpu_power_mw_p50=5112, cpu_power_mw_p75=5388, cpu_power_mw_p95=5648, cpu_power_mw_p99=5648, cpu_power_mw_stddev=372.334, cpu_power_watts=5.101, energy_to_solution_joules=77.149, energy_to_solution_joules_estimate=77.149, energy_verdict=measured, gpu_power_mw_max=79, gpu_power_mw_mean=71.808, gpu_power_mw_p50=72, gpu_power_mw_p75=74, gpu_power_mw_p95=78, gpu_power_mw_p99=79, gpu_power_mw_stddev=3.340, iteration=7, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.172, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.914, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780205276212-9dd39181 | hot-reload-loop | conjet | 15.057 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.111, combined_power_mw_max=7268, combined_power_mw_mean=5110.538, combined_power_mw_p50=4752, combined_power_mw_p75=5448, combined_power_mw_p95=7268, combined_power_mw_p99=7268, combined_power_mw_stddev=791.658, cpu_energy_to_solution_joules_estimate=73.465, cpu_power_mw_max=7189, cpu_power_mw_mean=5034.462, cpu_power_mw_p50=4678, cpu_power_mw_p75=5369, cpu_power_mw_p95=7189, cpu_power_mw_p99=7189, cpu_power_mw_stddev=790.386, cpu_power_watts=5.034, energy_to_solution_joules=74.575, energy_to_solution_joules_estimate=74.575, energy_verdict=measured, gpu_power_mw_max=82, gpu_power_mw_mean=76.115, gpu_power_mw_p50=76, gpu_power_mw_p75=79, gpu_power_mw_p95=81, gpu_power_mw_p99=82, gpu_power_mw_stddev=2.860, iteration=7, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.016, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.592, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780205291324-184b5c11 | compose-loop | conjet | 15.056 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.692, combined_power_mw_max=7028, combined_power_mw_mean=5692.385, combined_power_mw_p50=6047, combined_power_mw_p75=6276, combined_power_mw_p95=7028, combined_power_mw_p99=7028, combined_power_mw_stddev=851.128, cpu_energy_to_solution_joules_estimate=81.280, cpu_power_mw_max=6954, cpu_power_mw_mean=5616.308, cpu_power_mw_p50=5973, cpu_power_mw_p75=6201, cpu_power_mw_p95=6954, cpu_power_mw_p99=6954, cpu_power_mw_stddev=851.795, cpu_power_watts=5.616, energy_to_solution_joules=82.381, energy_to_solution_joules_estimate=82.381, energy_verdict=measured, gpu_power_mw_max=80, gpu_power_mw_mean=76.077, gpu_power_mw_p50=76, gpu_power_mw_p75=77, gpu_power_mw_p95=80, gpu_power_mw_p99=80, gpu_power_mw_stddev=1.817, iteration=7, low_power_mode=false, matched_process_lines=13, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.012, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.472, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780205306440-457ee3f5 | npm-install | conjet | 15.074 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.113, combined_power_mw_max=4369, combined_power_mw_mean=3112.538, combined_power_mw_p50=3253, combined_power_mw_p75=3697, combined_power_mw_p95=4369, combined_power_mw_p99=4369, combined_power_mw_stddev=1003.852, cpu_energy_to_solution_joules_estimate=43.517, cpu_power_mw_max=4294, cpu_power_mw_mean=3039.308, cpu_power_mw_p50=3175, cpu_power_mw_p75=3623, cpu_power_mw_p95=4294, cpu_power_mw_p99=4294, cpu_power_mw_stddev=1002.418, cpu_power_watts=3.039, energy_to_solution_joules=44.565, energy_to_solution_joules_estimate=44.565, energy_verdict=measured, gpu_power_mw_max=78, gpu_power_mw_mean=73.423, gpu_power_mw_p50=74, gpu_power_mw_p75=75, gpu_power_mw_p95=78, gpu_power_mw_p99=78, gpu_power_mw_stddev=2.514, iteration=7, low_power_mode=false, matched_process_lines=12, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.024, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.318, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780205321583-7bf3093a | pnpm-install | conjet | 17.883 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.810, combined_power_mw_max=4059, combined_power_mw_mean=2810.250, combined_power_mw_p50=3061, combined_power_mw_p75=3484, combined_power_mw_p95=4059, combined_power_mw_p99=4059, combined_power_mw_stddev=906.129, cpu_energy_to_solution_joules_estimate=48.152, cpu_power_mw_max=3989, cpu_power_mw_mean=2737.062, cpu_power_mw_p50=2985, cpu_power_mw_p75=3414, cpu_power_mw_p95=3989, cpu_power_mw_p99=3989, cpu_power_mw_stddev=906.263, cpu_power_watts=2.737, energy_to_solution_joules=49.439, energy_to_solution_joules_estimate=49.439, energy_verdict=measured, gpu_power_mw_max=79, gpu_power_mw_mean=73.250, gpu_power_mw_p50=73, gpu_power_mw_p75=75, gpu_power_mw_p95=79, gpu_power_mw_p99=79, gpu_power_mw_stddev=2.411, iteration=7, low_power_mode=false, matched_process_lines=7, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=17.855, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=16, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=17.593, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780205339519-b4285f3f | cargo-build | conjet | 15.062 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.607, combined_power_mw_max=910, combined_power_mw_mean=607, combined_power_mw_p50=555, combined_power_mw_p75=712, combined_power_mw_p95=910, combined_power_mw_p99=910, combined_power_mw_stddev=163.792, cpu_energy_to_solution_joules_estimate=0.118, cpu_power_mw_max=841, cpu_power_mw_mean=538.231, cpu_power_mw_p50=481, cpu_power_mw_p75=645, cpu_power_mw_p95=841, cpu_power_mw_p99=841, cpu_power_mw_stddev=164.181, cpu_power_watts=0.538, energy_to_solution_joules=0.133, energy_to_solution_joules_estimate=0.133, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=68.692, gpu_power_mw_p50=68, gpu_power_mw_p75=71, gpu_power_mw_p95=74, gpu_power_mw_p99=75, gpu_power_mw_stddev=3.244, iteration=7, low_power_mode=false, matched_process_lines=2, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.014, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.218, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780205354652-1ace8c8b | idle-power-sample | orbstack | 32.215 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.581, combined_power_mw_max=1021, combined_power_mw_mean=581.433, combined_power_mw_p50=531, combined_power_mw_p75=650, combined_power_mw_p95=940, combined_power_mw_p99=1021, combined_power_mw_stddev=181.028, cpu_power_mw_max=958, cpu_power_mw_mean=515.533, cpu_power_mw_p50=464, cpu_power_mw_p75=583, cpu_power_mw_p95=875, cpu_power_mw_p99=958, cpu_power_mw_stddev=181.995, cpu_power_watts=0.516, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=65.967, gpu_power_mw_p50=66, gpu_power_mw_p75=68, gpu_power_mw_p95=71, gpu_power_mw_p99=71, gpu_power_mw_stddev=2.516, idle_power_watts=0.581, iteration=7, low_power_mode=false, matched_process_lines=44, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780205386988-0b8fa800 | container-start-loop | orbstack | 15.094 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.799, combined_power_mw_max=2637, combined_power_mw_mean=1798.692, combined_power_mw_p50=1632, combined_power_mw_p75=1902, combined_power_mw_p95=2637, combined_power_mw_p99=2637, combined_power_mw_stddev=381.134, cpu_energy_to_solution_joules_estimate=25.599, cpu_power_mw_max=2566, cpu_power_mw_mean=1730.692, cpu_power_mw_p50=1564, cpu_power_mw_p75=1836, cpu_power_mw_p95=2566, cpu_power_mw_p99=2566, cpu_power_mw_stddev=380.763, cpu_power_watts=1.731, energy_to_solution_joules=26.604, energy_to_solution_joules_estimate=26.604, energy_verdict=measured, gpu_power_mw_max=78, gpu_power_mw_mean=67.885, gpu_power_mw_p50=67, gpu_power_mw_p75=69, gpu_power_mw_p95=78, gpu_power_mw_p99=78, gpu_power_mw_stddev=3.836, iteration=7, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.057, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.791, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780205402140-4ad3656a | hot-reload-loop | orbstack | 15.066 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.872, combined_power_mw_max=3323, combined_power_mw_mean=1872.385, combined_power_mw_p50=1758, combined_power_mw_p75=2086, combined_power_mw_p95=3323, combined_power_mw_p99=3323, combined_power_mw_stddev=503.693, cpu_energy_to_solution_joules_estimate=26.371, cpu_power_mw_max=3253, cpu_power_mw_mean=1803, cpu_power_mw_p50=1689, cpu_power_mw_p75=2017, cpu_power_mw_p95=3253, cpu_power_mw_p99=3253, cpu_power_mw_stddev=503.601, cpu_power_watts=1.803, energy_to_solution_joules=27.386, energy_to_solution_joules_estimate=27.386, energy_verdict=measured, gpu_power_mw_max=73, gpu_power_mw_mean=69.346, gpu_power_mw_p50=70, gpu_power_mw_p75=71, gpu_power_mw_p95=72, gpu_power_mw_p99=73, gpu_power_mw_stddev=2.111, iteration=7, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.019, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.626, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780205417272-20486ab2 | compose-loop | orbstack | 15.056 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.820, combined_power_mw_max=2493, combined_power_mw_mean=1820.462, combined_power_mw_p50=1713, combined_power_mw_p75=2287, combined_power_mw_p95=2493, combined_power_mw_p99=2493, combined_power_mw_stddev=404.666, cpu_energy_to_solution_joules_estimate=25.821, cpu_power_mw_max=2423, cpu_power_mw_mean=1749.154, cpu_power_mw_p50=1643, cpu_power_mw_p75=2213, cpu_power_mw_p95=2423, cpu_power_mw_p99=2423, cpu_power_mw_stddev=404.857, cpu_power_watts=1.749, energy_to_solution_joules=26.874, energy_to_solution_joules_estimate=26.874, energy_verdict=measured, gpu_power_mw_max=76, gpu_power_mw_mean=71.192, gpu_power_mw_p50=71, gpu_power_mw_p75=73, gpu_power_mw_p95=76, gpu_power_mw_p99=76, gpu_power_mw_stddev=2.481, iteration=7, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.026, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.762, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780205432383-6db27bf2 | npm-install | orbstack | 15.593 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.380, combined_power_mw_max=3294, combined_power_mw_mean=2379.846, combined_power_mw_p50=2678, combined_power_mw_p75=2927, combined_power_mw_p95=3294, combined_power_mw_p99=3294, combined_power_mw_stddev=736.978, cpu_energy_to_solution_joules_estimate=35.351, cpu_power_mw_max=3225, cpu_power_mw_mean=2311.077, cpu_power_mw_p50=2606, cpu_power_mw_p75=2861, cpu_power_mw_p95=3225, cpu_power_mw_p99=3225, cpu_power_mw_stddev=735.606, cpu_power_watts=2.311, energy_to_solution_joules=36.403, energy_to_solution_joules_estimate=36.403, energy_verdict=measured, gpu_power_mw_max=73, gpu_power_mw_mean=68.769, gpu_power_mw_p50=69, gpu_power_mw_p75=70, gpu_power_mw_p95=73, gpu_power_mw_p99=73, gpu_power_mw_stddev=2.764, iteration=7, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.561, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.297, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780205448034-209370ba | pnpm-install | orbstack | 17.668 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.445, combined_power_mw_max=3883, combined_power_mw_mean=2444.625, combined_power_mw_p50=2594, combined_power_mw_p75=3173, combined_power_mw_p95=3883, combined_power_mw_p99=3883, combined_power_mw_stddev=689.501, cpu_energy_to_solution_joules_estimate=41.228, cpu_power_mw_max=3807, cpu_power_mw_mean=2374, cpu_power_mw_p50=2523, cpu_power_mw_p75=3101, cpu_power_mw_p95=3807, cpu_power_mw_p99=3807, cpu_power_mw_stddev=688.725, cpu_power_watts=2.374, energy_to_solution_joules=42.454, energy_to_solution_joules_estimate=42.454, energy_verdict=measured, gpu_power_mw_max=76, gpu_power_mw_mean=70.781, gpu_power_mw_p50=71, gpu_power_mw_p75=73, gpu_power_mw_p95=76, gpu_power_mw_p99=76, gpu_power_mw_stddev=2.770, iteration=7, low_power_mode=false, matched_process_lines=34, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=17.632, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=16, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=17.366, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780205465760-85619fe3 | cargo-build | orbstack | 15.065 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.917, combined_power_mw_max=2851, combined_power_mw_mean=916.538, combined_power_mw_p50=653, combined_power_mw_p75=739, combined_power_mw_p95=2851, combined_power_mw_p99=2851, combined_power_mw_stddev=696.419, cpu_energy_to_solution_joules_estimate=1.426, cpu_power_mw_max=2780, cpu_power_mw_mean=848.154, cpu_power_mw_p50=585, cpu_power_mw_p75=671, cpu_power_mw_p95=2780, cpu_power_mw_p99=2780, cpu_power_mw_stddev=695.759, cpu_power_watts=0.848, energy_to_solution_joules=1.541, energy_to_solution_joules_estimate=1.541, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=68.269, gpu_power_mw_p50=68, gpu_power_mw_p75=69, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=1.830, iteration=7, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.025, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.682, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780205480891-4aa59217 | idle-power-sample | conjet | 32.114 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.571, combined_power_mw_max=1333, combined_power_mw_mean=570.633, combined_power_mw_p50=480, combined_power_mw_p75=633, combined_power_mw_p95=911, combined_power_mw_p99=1333, combined_power_mw_stddev=215.868, cpu_power_mw_max=1267, cpu_power_mw_mean=506.633, cpu_power_mw_p50=419, cpu_power_mw_p75=570, cpu_power_mw_p95=849, cpu_power_mw_p99=1267, cpu_power_mw_stddev=215.139, cpu_power_watts=0.507, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=64.017, gpu_power_mw_p50=64, gpu_power_mw_p75=66, gpu_power_mw_p95=70, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.964, idle_power_watts=0.571, iteration=8, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780205513133-3326b394 | container-start-loop | conjet | 15.043 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.985, combined_power_mw_max=5841, combined_power_mw_mean=4985.154, combined_power_mw_p50=4962, combined_power_mw_p75=5147, combined_power_mw_p95=5841, combined_power_mw_p99=5841, combined_power_mw_stddev=362.941, cpu_energy_to_solution_joules_estimate=72.011, cpu_power_mw_max=5771, cpu_power_mw_mean=4914.846, cpu_power_mw_p50=4897, cpu_power_mw_p75=5080, cpu_power_mw_p95=5771, cpu_power_mw_p99=5771, cpu_power_mw_stddev=362.500, cpu_power_watts=4.915, energy_to_solution_joules=73.041, energy_to_solution_joules_estimate=73.041, energy_verdict=measured, gpu_power_mw_max=79, gpu_power_mw_mean=70.115, gpu_power_mw_p50=68, gpu_power_mw_p75=72, gpu_power_mw_p95=79, gpu_power_mw_p99=79, gpu_power_mw_stddev=4.668, iteration=8, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.011, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.652, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780205528227-f9805bf7 | hot-reload-loop | conjet | 15.032 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.324, combined_power_mw_max=6692, combined_power_mw_mean=5323.846, combined_power_mw_p50=5049, combined_power_mw_p75=5655, combined_power_mw_p95=6692, combined_power_mw_p99=6692, combined_power_mw_stddev=711.883, cpu_energy_to_solution_joules_estimate=76.754, cpu_power_mw_max=6614, cpu_power_mw_mean=5246.462, cpu_power_mw_p50=4969, cpu_power_mw_p75=5577, cpu_power_mw_p95=6614, cpu_power_mw_p99=6614, cpu_power_mw_stddev=712.454, cpu_power_watts=5.246, energy_to_solution_joules=77.887, energy_to_solution_joules_estimate=77.887, energy_verdict=measured, gpu_power_mw_max=81, gpu_power_mw_mean=77.500, gpu_power_mw_p50=77, gpu_power_mw_p75=79, gpu_power_mw_p95=81, gpu_power_mw_p99=81, gpu_power_mw_stddev=1.906, iteration=8, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.004, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.630, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780205543316-9b0c3465 | compose-loop | conjet | 15.060 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.797, combined_power_mw_max=5818, combined_power_mw_mean=4796.846, combined_power_mw_p50=4760, combined_power_mw_p75=4858, combined_power_mw_p95=5818, combined_power_mw_p99=5818, combined_power_mw_stddev=465.494, cpu_energy_to_solution_joules_estimate=68.732, cpu_power_mw_max=5741, cpu_power_mw_mean=4721.769, cpu_power_mw_p50=4686, cpu_power_mw_p75=4784, cpu_power_mw_p95=5741, cpu_power_mw_p99=5741, cpu_power_mw_stddev=464.553, cpu_power_watts=4.722, energy_to_solution_joules=69.825, energy_to_solution_joules_estimate=69.825, energy_verdict=measured, gpu_power_mw_max=78, gpu_power_mw_mean=74.962, gpu_power_mw_p50=75, gpu_power_mw_p75=76, gpu_power_mw_p95=78, gpu_power_mw_p99=78, gpu_power_mw_stddev=1.870, iteration=8, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.016, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.556, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780205558435-3e6febbf | npm-install | conjet | 15.178 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.739, combined_power_mw_max=5212, combined_power_mw_mean=3739.385, combined_power_mw_p50=3573, combined_power_mw_p75=4330, combined_power_mw_p95=5212, combined_power_mw_p99=5212, combined_power_mw_stddev=947.809, cpu_energy_to_solution_joules_estimate=54.542, cpu_power_mw_max=5137, cpu_power_mw_mean=3663.692, cpu_power_mw_p50=3498, cpu_power_mw_p75=4251, cpu_power_mw_p95=5137, cpu_power_mw_p99=5137, cpu_power_mw_stddev=946.422, cpu_power_watts=3.664, energy_to_solution_joules=55.669, energy_to_solution_joules_estimate=55.669, energy_verdict=measured, gpu_power_mw_max=84, gpu_power_mw_mean=75.615, gpu_power_mw_p50=76, gpu_power_mw_p75=79, gpu_power_mw_p95=83, gpu_power_mw_p99=84, gpu_power_mw_stddev=3.814, iteration=8, low_power_mode=false, matched_process_lines=12, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.150, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.887, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780205573667-6b1d6de4 | pnpm-install | conjet | 15.052 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.150, combined_power_mw_max=4124, combined_power_mw_mean=3149.846, combined_power_mw_p50=3109, combined_power_mw_p75=3616, combined_power_mw_p95=4124, combined_power_mw_p99=4124, combined_power_mw_stddev=599.639, cpu_energy_to_solution_joules_estimate=44.469, cpu_power_mw_max=4047, cpu_power_mw_mean=3075.231, cpu_power_mw_p50=3033, cpu_power_mw_p75=3541, cpu_power_mw_p95=4047, cpu_power_mw_p99=4047, cpu_power_mw_stddev=599.154, cpu_power_watts=3.075, energy_to_solution_joules=45.548, energy_to_solution_joules_estimate=45.548, energy_verdict=measured, gpu_power_mw_max=77, gpu_power_mw_mean=74.500, gpu_power_mw_p50=75, gpu_power_mw_p75=75, gpu_power_mw_p95=76, gpu_power_mw_p99=77, gpu_power_mw_stddev=1.337, iteration=8, low_power_mode=false, matched_process_lines=5, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.018, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.460, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780205588784-eb616c49 | cargo-build | conjet | 15.062 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.730, combined_power_mw_max=2031, combined_power_mw_mean=730.462, combined_power_mw_p50=533, combined_power_mw_p75=834, combined_power_mw_p95=2031, combined_power_mw_p99=2031, combined_power_mw_stddev=455.876, cpu_energy_to_solution_joules_estimate=0.154, cpu_power_mw_max=1951, cpu_power_mw_mean=659.462, cpu_power_mw_p50=462, cpu_power_mw_p75=767, cpu_power_mw_p95=1951, cpu_power_mw_p99=1951, cpu_power_mw_stddev=453.523, cpu_power_watts=0.659, energy_to_solution_joules=0.171, energy_to_solution_joules_estimate=0.171, energy_verdict=measured, gpu_power_mw_max=80, gpu_power_mw_mean=70.923, gpu_power_mw_p50=71, gpu_power_mw_p75=72, gpu_power_mw_p95=79, gpu_power_mw_p99=80, gpu_power_mw_stddev=3.430, iteration=8, low_power_mode=false, matched_process_lines=4, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.027, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.234, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780205603905-f9bfbe8d | idle-power-sample | orbstack | 32.189 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.606, combined_power_mw_max=1363, combined_power_mw_mean=606.467, combined_power_mw_p50=497, combined_power_mw_p75=662, combined_power_mw_p95=1326, combined_power_mw_p99=1363, combined_power_mw_stddev=305.989, cpu_power_mw_max=1293, cpu_power_mw_mean=540.500, cpu_power_mw_p50=436, cpu_power_mw_p75=596, cpu_power_mw_p95=1259, cpu_power_mw_p99=1293, cpu_power_mw_stddev=305.219, cpu_power_watts=0.540, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=65.917, gpu_power_mw_p50=66, gpu_power_mw_p75=68, gpu_power_mw_p95=70, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.584, idle_power_watts=0.606, iteration=8, low_power_mode=false, matched_process_lines=41, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780205636211-3a20b092 | container-start-loop | orbstack | 15.703 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.759, combined_power_mw_max=2742, combined_power_mw_mean=1759, combined_power_mw_p50=1789, combined_power_mw_p75=2056, combined_power_mw_p95=2742, combined_power_mw_p99=2742, combined_power_mw_stddev=469.784, cpu_energy_to_solution_joules_estimate=26.064, cpu_power_mw_max=2674, cpu_power_mw_mean=1691.286, cpu_power_mw_p50=1719, cpu_power_mw_p75=1989, cpu_power_mw_p95=2674, cpu_power_mw_p99=2674, cpu_power_mw_stddev=470.182, cpu_power_watts=1.691, energy_to_solution_joules=27.108, energy_to_solution_joules_estimate=27.108, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=67.750, gpu_power_mw_p50=67, gpu_power_mw_p75=69, gpu_power_mw_p95=75, gpu_power_mw_p99=75, gpu_power_mw_stddev=2.586, iteration=8, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.671, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.411, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780205651972-a53f3a48 | hot-reload-loop | orbstack | 16.591 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.768, combined_power_mw_max=2428, combined_power_mw_mean=1767.929, combined_power_mw_p50=1755, combined_power_mw_p75=2001, combined_power_mw_p95=2428, combined_power_mw_p99=2428, combined_power_mw_stddev=285.590, cpu_energy_to_solution_joules_estimate=27.696, cpu_power_mw_max=2358, cpu_power_mw_mean=1699.786, cpu_power_mw_p50=1680, cpu_power_mw_p75=1933, cpu_power_mw_p95=2358, cpu_power_mw_p99=2358, cpu_power_mw_stddev=285.704, cpu_power_watts=1.700, energy_to_solution_joules=28.806, energy_to_solution_joules_estimate=28.806, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=68.214, gpu_power_mw_p50=68, gpu_power_mw_p75=70, gpu_power_mw_p95=73, gpu_power_mw_p99=75, gpu_power_mw_stddev=2.664, iteration=8, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.560, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.294, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780205668620-f45a2c57 | compose-loop | orbstack | 15.227 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.683, combined_power_mw_max=2289, combined_power_mw_mean=1682.692, combined_power_mw_p50=1613, combined_power_mw_p75=1915, combined_power_mw_p95=2289, combined_power_mw_p99=2289, combined_power_mw_stddev=382.675, cpu_energy_to_solution_joules_estimate=24.117, cpu_power_mw_max=2219, cpu_power_mw_mean=1615, cpu_power_mw_p50=1546, cpu_power_mw_p75=1849, cpu_power_mw_p95=2219, cpu_power_mw_p99=2219, cpu_power_mw_stddev=382.101, cpu_power_watts=1.615, energy_to_solution_joules=25.127, energy_to_solution_joules_estimate=25.127, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=67.808, gpu_power_mw_p50=68, gpu_power_mw_p75=69, gpu_power_mw_p95=71, gpu_power_mw_p99=71, gpu_power_mw_stddev=1.387, iteration=8, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.199, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.933, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780205683905-e25d09aa | npm-install | orbstack | 17.406 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.500, combined_power_mw_max=3838, combined_power_mw_mean=2499.733, combined_power_mw_p50=2441, combined_power_mw_p75=2856, combined_power_mw_p95=3838, combined_power_mw_p99=3838, combined_power_mw_stddev=622.047, cpu_energy_to_solution_joules_estimate=41.587, cpu_power_mw_max=3770, cpu_power_mw_mean=2431.667, cpu_power_mw_p50=2371, cpu_power_mw_p75=2791, cpu_power_mw_p95=3770, cpu_power_mw_p99=3770, cpu_power_mw_stddev=621.333, cpu_power_watts=2.432, energy_to_solution_joules=42.751, energy_to_solution_joules_estimate=42.751, energy_verdict=measured, gpu_power_mw_max=73, gpu_power_mw_mean=68, gpu_power_mw_p50=68, gpu_power_mw_p75=70, gpu_power_mw_p95=73, gpu_power_mw_p99=73, gpu_power_mw_stddev=2.633, iteration=8, low_power_mode=false, matched_process_lines=32, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=17.367, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=15, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=17.102, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780205701370-cd98334f | pnpm-install | orbstack | 15.675 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.752, combined_power_mw_max=3574, combined_power_mw_mean=2751.929, combined_power_mw_p50=2809, combined_power_mw_p75=3127, combined_power_mw_p95=3574, combined_power_mw_p99=3574, combined_power_mw_stddev=512.531, cpu_energy_to_solution_joules_estimate=41.257, cpu_power_mw_max=3508, cpu_power_mw_mean=2682.429, cpu_power_mw_p50=2738, cpu_power_mw_p75=3054, cpu_power_mw_p95=3508, cpu_power_mw_p99=3508, cpu_power_mw_stddev=513.106, cpu_power_watts=2.682, energy_to_solution_joules=42.326, energy_to_solution_joules_estimate=42.326, energy_verdict=measured, gpu_power_mw_max=73, gpu_power_mw_mean=69.607, gpu_power_mw_p50=70, gpu_power_mw_p75=73, gpu_power_mw_p95=73, gpu_power_mw_p99=73, gpu_power_mw_stddev=3.039, iteration=8, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.644, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.381, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780205717102-24253633 | cargo-build | orbstack | 15.061 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.686, combined_power_mw_max=1972, combined_power_mw_mean=685.846, combined_power_mw_p50=539, combined_power_mw_p75=660, combined_power_mw_p95=1972, combined_power_mw_p99=1972, combined_power_mw_stddev=407.452, cpu_energy_to_solution_joules_estimate=1.139, cpu_power_mw_max=1906, cpu_power_mw_mean=617.615, cpu_power_mw_p50=467, cpu_power_mw_p75=591, cpu_power_mw_p95=1906, cpu_power_mw_p99=1906, cpu_power_mw_stddev=407.698, cpu_power_watts=0.618, energy_to_solution_joules=1.265, energy_to_solution_joules_estimate=1.265, energy_verdict=measured, gpu_power_mw_max=77, gpu_power_mw_mean=68.385, gpu_power_mw_p50=67, gpu_power_mw_p75=71, gpu_power_mw_p95=76, gpu_power_mw_p99=77, gpu_power_mw_stddev=3.398, iteration=8, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.022, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.845, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780205732228-51085ac7 | idle-power-sample | conjet | 32.088 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.549, combined_power_mw_max=899, combined_power_mw_mean=549.467, combined_power_mw_p50=506, combined_power_mw_p75=623, combined_power_mw_p95=849, combined_power_mw_p99=899, combined_power_mw_stddev=146.164, cpu_power_mw_max=835, cpu_power_mw_mean=485.933, cpu_power_mw_p50=441, cpu_power_mw_p75=561, cpu_power_mw_p95=785, cpu_power_mw_p99=835, cpu_power_mw_stddev=146.034, cpu_power_watts=0.486, energy_verdict=measured, gpu_power_mw_max=69, gpu_power_mw_mean=63.583, gpu_power_mw_p50=63, gpu_power_mw_p75=65, gpu_power_mw_p95=67, gpu_power_mw_p99=69, gpu_power_mw_stddev=2.027, idle_power_watts=0.549, iteration=9, low_power_mode=false, matched_process_lines=4, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780205764423-a7b2106c | container-start-loop | conjet | 15.075 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.849, combined_power_mw_max=5944, combined_power_mw_mean=4848.615, combined_power_mw_p50=4684, combined_power_mw_p75=5152, combined_power_mw_p95=5944, combined_power_mw_p99=5944, combined_power_mw_stddev=443.759, cpu_energy_to_solution_joules_estimate=69.155, cpu_power_mw_max=5871, cpu_power_mw_mean=4777.923, cpu_power_mw_p50=4612, cpu_power_mw_p75=5083, cpu_power_mw_p95=5871, cpu_power_mw_p99=5871, cpu_power_mw_stddev=443.571, cpu_power_watts=4.778, energy_to_solution_joules=70.178, energy_to_solution_joules_estimate=70.178, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=70.808, gpu_power_mw_p50=70, gpu_power_mw_p75=72, gpu_power_mw_p95=75, gpu_power_mw_p99=75, gpu_power_mw_stddev=1.840, iteration=9, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.025, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.474, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780205779555-ee61167f | hot-reload-loop | conjet | 15.036 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.809, combined_power_mw_max=5646, combined_power_mw_mean=4809.154, combined_power_mw_p50=4636, combined_power_mw_p75=4966, combined_power_mw_p95=5646, combined_power_mw_p99=5646, combined_power_mw_stddev=321.954, cpu_energy_to_solution_joules_estimate=67.606, cpu_power_mw_max=5570, cpu_power_mw_mean=4735.769, cpu_power_mw_p50=4566, cpu_power_mw_p75=4893, cpu_power_mw_p95=5570, cpu_power_mw_p99=5570, cpu_power_mw_stddev=321.247, cpu_power_watts=4.736, energy_to_solution_joules=68.654, energy_to_solution_joules_estimate=68.654, energy_verdict=measured, gpu_power_mw_max=77, gpu_power_mw_mean=73.231, gpu_power_mw_p50=73, gpu_power_mw_p75=75, gpu_power_mw_p95=77, gpu_power_mw_p99=77, gpu_power_mw_stddev=2.326, iteration=9, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.013, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.276, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780205794649-bf7191f9 | compose-loop | conjet | 15.037 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.744, combined_power_mw_max=5944, combined_power_mw_mean=4744.231, combined_power_mw_p50=4658, combined_power_mw_p75=4747, combined_power_mw_p95=5944, combined_power_mw_p99=5944, combined_power_mw_stddev=403.302, cpu_energy_to_solution_joules_estimate=66.528, cpu_power_mw_max=5870, cpu_power_mw_mean=4671.231, cpu_power_mw_p50=4584, cpu_power_mw_p75=4676, cpu_power_mw_p95=5870, cpu_power_mw_p99=5870, cpu_power_mw_stddev=402.905, cpu_power_watts=4.671, energy_to_solution_joules=67.568, energy_to_solution_joules_estimate=67.568, energy_verdict=measured, gpu_power_mw_max=76, gpu_power_mw_mean=72.846, gpu_power_mw_p50=73, gpu_power_mw_p75=74, gpu_power_mw_p95=76, gpu_power_mw_p99=76, gpu_power_mw_stddev=1.703, iteration=9, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.006, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.242, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780205809736-3bc8a950 | npm-install | conjet | 15.880 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3, combined_power_mw_max=4042, combined_power_mw_mean=3000, combined_power_mw_p50=3274, combined_power_mw_p75=3644, combined_power_mw_p95=4042, combined_power_mw_p99=4042, combined_power_mw_stddev=830.509, cpu_energy_to_solution_joules_estimate=45.653, cpu_power_mw_max=3965, cpu_power_mw_mean=2927.500, cpu_power_mw_p50=3203, cpu_power_mw_p75=3571, cpu_power_mw_p95=3965, cpu_power_mw_p99=3965, cpu_power_mw_stddev=829.278, cpu_power_watts=2.928, energy_to_solution_joules=46.783, energy_to_solution_joules_estimate=46.783, energy_verdict=measured, gpu_power_mw_max=77, gpu_power_mw_mean=72.393, gpu_power_mw_p50=72, gpu_power_mw_p75=74, gpu_power_mw_p95=76, gpu_power_mw_p99=77, gpu_power_mw_stddev=2.241, iteration=9, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.856, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.594, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780205825674-eb9cd98b | pnpm-install | conjet | 15.570 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.255, combined_power_mw_max=5352, combined_power_mw_mean=3254.643, combined_power_mw_p50=3434, combined_power_mw_p75=3982, combined_power_mw_p95=5352, combined_power_mw_p99=5352, combined_power_mw_stddev=1192.254, cpu_energy_to_solution_joules_estimate=48.638, cpu_power_mw_max=5275, cpu_power_mw_mean=3182.500, cpu_power_mw_p50=3363, cpu_power_mw_p75=3909, cpu_power_mw_p95=5275, cpu_power_mw_p99=5275, cpu_power_mw_stddev=1191.123, cpu_power_watts=3.183, energy_to_solution_joules=49.740, energy_to_solution_joules_estimate=49.740, energy_verdict=measured, gpu_power_mw_max=79, gpu_power_mw_mean=72.179, gpu_power_mw_p50=71, gpu_power_mw_p75=75, gpu_power_mw_p95=78, gpu_power_mw_p99=79, gpu_power_mw_stddev=3.185, iteration=9, low_power_mode=false, matched_process_lines=5, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.546, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.283, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780205841296-877454ac | cargo-build | conjet | 15.041 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.571, combined_power_mw_max=1121, combined_power_mw_mean=570.923, combined_power_mw_p50=508, combined_power_mw_p75=594, combined_power_mw_p95=1121, combined_power_mw_p99=1121, combined_power_mw_stddev=220.589, cpu_energy_to_solution_joules_estimate=0.107, cpu_power_mw_max=1049, cpu_power_mw_mean=501.077, cpu_power_mw_p50=436, cpu_power_mw_p75=518, cpu_power_mw_p95=1049, cpu_power_mw_p99=1049, cpu_power_mw_stddev=219.785, cpu_power_watts=0.501, energy_to_solution_joules=0.122, energy_to_solution_joules_estimate=0.122, energy_verdict=measured, gpu_power_mw_max=80, gpu_power_mw_mean=69.769, gpu_power_mw_p50=70, gpu_power_mw_p75=71, gpu_power_mw_p95=79, gpu_power_mw_p99=80, gpu_power_mw_stddev=4.003, iteration=9, low_power_mode=false, matched_process_lines=1, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.014, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.213, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780205856389-242dce91 | idle-power-sample | orbstack | 32.133 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.691, combined_power_mw_max=2961, combined_power_mw_mean=691.333, combined_power_mw_p50=536, combined_power_mw_p75=681, combined_power_mw_p95=1241, combined_power_mw_p99=2961, combined_power_mw_stddev=492.846, cpu_power_mw_max=2893, cpu_power_mw_mean=625.500, cpu_power_mw_p50=471, cpu_power_mw_p75=619, cpu_power_mw_p95=1175, cpu_power_mw_p99=2893, cpu_power_mw_stddev=492.506, cpu_power_watts=0.625, energy_verdict=measured, gpu_power_mw_max=70, gpu_power_mw_mean=65.800, gpu_power_mw_p50=66, gpu_power_mw_p75=68, gpu_power_mw_p95=70, gpu_power_mw_p99=70, gpu_power_mw_stddev=2.212, idle_power_watts=0.691, iteration=9, low_power_mode=false, matched_process_lines=44, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780205888627-db298c9a | container-start-loop | orbstack | 15.086 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.848, combined_power_mw_max=2456, combined_power_mw_mean=1847.769, combined_power_mw_p50=1729, combined_power_mw_p75=2063, combined_power_mw_p95=2456, combined_power_mw_p99=2456, combined_power_mw_stddev=326.954, cpu_energy_to_solution_joules_estimate=25.468, cpu_power_mw_max=2389, cpu_power_mw_mean=1781, cpu_power_mw_p50=1659, cpu_power_mw_p75=1994, cpu_power_mw_p95=2389, cpu_power_mw_p99=2389, cpu_power_mw_stddev=327.255, cpu_power_watts=1.781, energy_to_solution_joules=26.423, energy_to_solution_joules_estimate=26.423, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=66.808, gpu_power_mw_p50=67, gpu_power_mw_p75=69, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.896, iteration=9, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.029, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.300, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780205903773-abac9463 | hot-reload-loop | orbstack | 15.820 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.757, combined_power_mw_max=2487, combined_power_mw_mean=1757.357, combined_power_mw_p50=1618, combined_power_mw_p75=2046, combined_power_mw_p95=2487, combined_power_mw_p99=2487, combined_power_mw_stddev=359.983, cpu_energy_to_solution_joules_estimate=26.209, cpu_power_mw_max=2421, cpu_power_mw_mean=1688.571, cpu_power_mw_p50=1552, cpu_power_mw_p75=1973, cpu_power_mw_p95=2421, cpu_power_mw_p99=2421, cpu_power_mw_stddev=360.033, cpu_power_watts=1.689, energy_to_solution_joules=27.276, energy_to_solution_joules_estimate=27.276, energy_verdict=measured, gpu_power_mw_max=73, gpu_power_mw_mean=68.643, gpu_power_mw_p50=69, gpu_power_mw_p75=71, gpu_power_mw_p95=73, gpu_power_mw_p99=73, gpu_power_mw_stddev=2.423, iteration=9, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.788, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.521, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780205919649-5a9856bc | compose-loop | orbstack | 15.328 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.701, combined_power_mw_max=2288, combined_power_mw_mean=1701.385, combined_power_mw_p50=1577, combined_power_mw_p75=2069, combined_power_mw_p95=2288, combined_power_mw_p99=2288, combined_power_mw_stddev=345.438, cpu_energy_to_solution_joules_estimate=24.553, cpu_power_mw_max=2215, cpu_power_mw_mean=1633.538, cpu_power_mw_p50=1511, cpu_power_mw_p75=2001, cpu_power_mw_p95=2215, cpu_power_mw_p99=2215, cpu_power_mw_stddev=343.920, cpu_power_watts=1.634, energy_to_solution_joules=25.573, energy_to_solution_joules_estimate=25.573, energy_verdict=measured, gpu_power_mw_max=73, gpu_power_mw_mean=67.885, gpu_power_mw_p50=68, gpu_power_mw_p75=71, gpu_power_mw_p95=73, gpu_power_mw_p99=73, gpu_power_mw_stddev=2.621, iteration=9, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.295, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.030, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780205935037-dc5ea674 | npm-install | orbstack | 15.438 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.372, combined_power_mw_max=3048, combined_power_mw_mean=2372.231, combined_power_mw_p50=2332, combined_power_mw_p75=2788, combined_power_mw_p95=3048, combined_power_mw_p99=3048, combined_power_mw_stddev=448.592, cpu_energy_to_solution_joules_estimate=34.852, cpu_power_mw_max=2975, cpu_power_mw_mean=2301.538, cpu_power_mw_p50=2261, cpu_power_mw_p75=2719, cpu_power_mw_p95=2975, cpu_power_mw_p99=2975, cpu_power_mw_stddev=448.566, cpu_power_watts=2.302, energy_to_solution_joules=35.923, energy_to_solution_joules_estimate=35.923, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=70.615, gpu_power_mw_p50=70, gpu_power_mw_p75=73, gpu_power_mw_p95=75, gpu_power_mw_p99=75, gpu_power_mw_stddev=2.676, iteration=9, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.407, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.143, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780205950532-92f4f8f4 | pnpm-install | orbstack | 16.453 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.692, combined_power_mw_max=3502, combined_power_mw_mean=2692.500, combined_power_mw_p50=3011, combined_power_mw_p75=3209, combined_power_mw_p95=3502, combined_power_mw_p99=3502, combined_power_mw_stddev=706.056, cpu_energy_to_solution_joules_estimate=42.418, cpu_power_mw_max=3439, cpu_power_mw_mean=2625.571, cpu_power_mw_p50=2939, cpu_power_mw_p75=3141, cpu_power_mw_p95=3439, cpu_power_mw_p99=3439, cpu_power_mw_stddev=705.779, cpu_power_watts=2.626, energy_to_solution_joules=43.499, energy_to_solution_joules_estimate=43.499, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=66.929, gpu_power_mw_p50=67, gpu_power_mw_p75=68, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.562, iteration=9, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.422, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=16.156, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780205967044-945f54a6 | cargo-build | orbstack | 15.040 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.721, combined_power_mw_max=2105, combined_power_mw_mean=721.385, combined_power_mw_p50=513, combined_power_mw_p75=975, combined_power_mw_p95=2105, combined_power_mw_p99=2105, combined_power_mw_stddev=464.554, cpu_energy_to_solution_joules_estimate=1.144, cpu_power_mw_max=2032, cpu_power_mw_mean=654.538, cpu_power_mw_p50=447, cpu_power_mw_p75=911, cpu_power_mw_p95=2032, cpu_power_mw_p99=2032, cpu_power_mw_stddev=462.963, cpu_power_watts=0.655, energy_to_solution_joules=1.261, energy_to_solution_joules_estimate=1.261, energy_verdict=measured, gpu_power_mw_max=73, gpu_power_mw_mean=66.923, gpu_power_mw_p50=66, gpu_power_mw_p75=68, gpu_power_mw_p95=73, gpu_power_mw_p99=73, gpu_power_mw_stddev=2.986, iteration=9, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.011, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.748, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-conjet-1780205982134-4e7cfbee | idle-power-sample | conjet | 32.090 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.548, combined_power_mw_max=982, combined_power_mw_mean=547.633, combined_power_mw_p50=437, combined_power_mw_p75=656, combined_power_mw_p95=950, combined_power_mw_p99=982, combined_power_mw_stddev=212.623, cpu_power_mw_max=919, cpu_power_mw_mean=484.500, cpu_power_mw_p50=367, cpu_power_mw_p75=593, cpu_power_mw_p95=890, cpu_power_mw_p99=919, cpu_power_mw_stddev=212.481, cpu_power_watts=0.484, energy_verdict=measured, gpu_power_mw_max=69, gpu_power_mw_mean=63.083, gpu_power_mw_p50=63, gpu_power_mw_p75=64, gpu_power_mw_p95=68, gpu_power_mw_p99=69, gpu_power_mw_stddev=2.492, idle_power_watts=0.548, iteration=10, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780206014323-91d0e782 | container-start-loop | conjet | 15.051 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.875, combined_power_mw_max=5501, combined_power_mw_mean=4874.846, combined_power_mw_p50=4798, combined_power_mw_p75=4903, combined_power_mw_p95=5501, combined_power_mw_p99=5501, combined_power_mw_stddev=319.662, cpu_energy_to_solution_joules_estimate=70.071, cpu_power_mw_max=5427, cpu_power_mw_mean=4804.077, cpu_power_mw_p50=4733, cpu_power_mw_p75=4830, cpu_power_mw_p95=5427, cpu_power_mw_p99=5427, cpu_power_mw_stddev=318.681, cpu_power_watts=4.804, energy_to_solution_joules=71.104, energy_to_solution_joules_estimate=71.104, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=70.615, gpu_power_mw_p50=71, gpu_power_mw_p75=72, gpu_power_mw_p95=74, gpu_power_mw_p99=74, gpu_power_mw_stddev=2.573, iteration=10, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.016, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.586, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-conjet-1780206029430-372d0382 | hot-reload-loop | conjet | 15.064 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.856, combined_power_mw_max=5371, combined_power_mw_mean=4856.462, combined_power_mw_p50=4727, combined_power_mw_p75=5195, combined_power_mw_p95=5371, combined_power_mw_p99=5371, combined_power_mw_stddev=306.711, cpu_energy_to_solution_joules_estimate=68.930, cpu_power_mw_max=5297, cpu_power_mw_mean=4782.769, cpu_power_mw_p50=4652, cpu_power_mw_p75=5120, cpu_power_mw_p95=5297, cpu_power_mw_p99=5297, cpu_power_mw_stddev=306.293, cpu_power_watts=4.783, energy_to_solution_joules=69.993, energy_to_solution_joules_estimate=69.993, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=73.654, gpu_power_mw_p50=74, gpu_power_mw_p75=75, gpu_power_mw_p95=75, gpu_power_mw_p99=75, gpu_power_mw_stddev=1.072, iteration=10, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.025, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.412, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-conjet-1780206044562-ef4fa19c | compose-loop | conjet | 15.066 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.756, combined_power_mw_max=5128, combined_power_mw_mean=4755.615, combined_power_mw_p50=4734, combined_power_mw_p75=4960, combined_power_mw_p95=5128, combined_power_mw_p99=5128, combined_power_mw_stddev=264.875, cpu_energy_to_solution_joules_estimate=67.171, cpu_power_mw_max=5050, cpu_power_mw_mean=4680.615, cpu_power_mw_p50=4660, cpu_power_mw_p75=4884, cpu_power_mw_p95=5050, cpu_power_mw_p99=5050, cpu_power_mw_stddev=264.331, cpu_power_watts=4.681, energy_to_solution_joules=68.248, energy_to_solution_joules_estimate=68.248, energy_verdict=measured, gpu_power_mw_max=79, gpu_power_mw_mean=75, gpu_power_mw_p50=75, gpu_power_mw_p75=77, gpu_power_mw_p95=79, gpu_power_mw_p99=79, gpu_power_mw_stddev=2.270, iteration=10, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.021, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.351, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-conjet-1780206059697-13fd878a | npm-install | conjet | 15.035 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.389, combined_power_mw_max=3852, combined_power_mw_mean=3389.231, combined_power_mw_p50=3351, combined_power_mw_p75=3535, combined_power_mw_p95=3852, combined_power_mw_p99=3852, combined_power_mw_stddev=259.390, cpu_energy_to_solution_joules_estimate=47.268, cpu_power_mw_max=3780, cpu_power_mw_mean=3317.077, cpu_power_mw_p50=3279, cpu_power_mw_p75=3461, cpu_power_mw_p95=3780, cpu_power_mw_p99=3780, cpu_power_mw_stddev=258.678, cpu_power_watts=3.317, energy_to_solution_joules=48.296, energy_to_solution_joules_estimate=48.296, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=72.346, gpu_power_mw_p50=72, gpu_power_mw_p75=73, gpu_power_mw_p95=75, gpu_power_mw_p99=75, gpu_power_mw_stddev=1.357, iteration=10, low_power_mode=false, matched_process_lines=14, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.013, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.250, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-conjet-1780206074787-f6b6ba86 | pnpm-install | conjet | 17.415 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.270, combined_power_mw_max=4207, combined_power_mw_mean=3269.800, combined_power_mw_p50=3441, combined_power_mw_p75=4002, combined_power_mw_p95=4207, combined_power_mw_p99=4207, combined_power_mw_stddev=779.443, cpu_energy_to_solution_joules_estimate=54.743, cpu_power_mw_max=4135, cpu_power_mw_mean=3196.467, cpu_power_mw_p50=3363, cpu_power_mw_p75=3926, cpu_power_mw_p95=4135, cpu_power_mw_p99=4135, cpu_power_mw_stddev=779.724, cpu_power_watts=3.196, energy_to_solution_joules=55.999, energy_to_solution_joules_estimate=55.999, energy_verdict=measured, gpu_power_mw_max=78, gpu_power_mw_mean=73.233, gpu_power_mw_p50=72, gpu_power_mw_p75=76, gpu_power_mw_p95=78, gpu_power_mw_p99=78, gpu_power_mw_stddev=2.952, iteration=10, low_power_mode=false, matched_process_lines=7, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=17.389, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=15, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=17.126, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-conjet-1780206092257-45c586b3 | cargo-build | conjet | 15.054 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.573, combined_power_mw_max=921, combined_power_mw_mean=572.615, combined_power_mw_p50=496, combined_power_mw_p75=557, combined_power_mw_p95=921, combined_power_mw_p99=921, combined_power_mw_stddev=186.952, cpu_energy_to_solution_joules_estimate=0.117, cpu_power_mw_max=844, cpu_power_mw_mean=503.385, cpu_power_mw_p50=425, cpu_power_mw_p75=484, cpu_power_mw_p95=844, cpu_power_mw_p99=844, cpu_power_mw_stddev=185.534, cpu_power_watts=0.503, energy_to_solution_joules=0.133, energy_to_solution_joules_estimate=0.133, energy_verdict=measured, gpu_power_mw_max=77, gpu_power_mw_mean=69.346, gpu_power_mw_p50=70, gpu_power_mw_p75=71, gpu_power_mw_p95=76, gpu_power_mw_p99=77, gpu_power_mw_stddev=3.257, iteration=10, low_power_mode=false, matched_process_lines=3, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.024, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.232, workload_exit_code=127, workload_timeout_seconds=300 |
| bench-idle-power-sample-orbstack-1780206107382-610dd134 | idle-power-sample | orbstack | 32.156 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.592, combined_power_mw_max=1343, combined_power_mw_mean=592.133, combined_power_mw_p50=488, combined_power_mw_p75=651, combined_power_mw_p95=1130, combined_power_mw_p99=1343, combined_power_mw_stddev=262.294, cpu_power_mw_max=1279, cpu_power_mw_mean=526.400, cpu_power_mw_p50=422, cpu_power_mw_p75=587, cpu_power_mw_p95=1064, cpu_power_mw_p99=1279, cpu_power_mw_stddev=262.603, cpu_power_watts=0.526, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=65.650, gpu_power_mw_p50=65, gpu_power_mw_p75=68, gpu_power_mw_p95=70, gpu_power_mw_p99=71, gpu_power_mw_stddev=2.414, idle_power_watts=0.592, iteration=10, low_power_mode=false, matched_process_lines=43, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780206139655-09ca9ab8 | container-start-loop | orbstack | 15.079 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.772, combined_power_mw_max=2564, combined_power_mw_mean=1771.615, combined_power_mw_p50=1698, combined_power_mw_p75=2076, combined_power_mw_p95=2564, combined_power_mw_p99=2564, combined_power_mw_stddev=482.959, cpu_energy_to_solution_joules_estimate=25.190, cpu_power_mw_max=2493, cpu_power_mw_mean=1703.692, cpu_power_mw_p50=1629, cpu_power_mw_p75=2010, cpu_power_mw_p95=2493, cpu_power_mw_p99=2493, cpu_power_mw_stddev=481.994, cpu_power_watts=1.704, energy_to_solution_joules=26.194, energy_to_solution_joules_estimate=26.194, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=67.846, gpu_power_mw_p50=68, gpu_power_mw_p75=70, gpu_power_mw_p95=71, gpu_power_mw_p99=71, gpu_power_mw_stddev=2.299, iteration=10, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.051, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=14.786, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-hot-reload-loop-orbstack-1780206154792-ec8d221f | hot-reload-loop | orbstack | 16.276 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.928, combined_power_mw_max=2938, combined_power_mw_mean=1928.143, combined_power_mw_p50=1918, combined_power_mw_p75=2159, combined_power_mw_p95=2938, combined_power_mw_p99=2938, combined_power_mw_stddev=402.883, cpu_energy_to_solution_joules_estimate=29.700, cpu_power_mw_max=2867, cpu_power_mw_mean=1859.286, cpu_power_mw_p50=1854, cpu_power_mw_p75=2090, cpu_power_mw_p95=2867, cpu_power_mw_p99=2867, cpu_power_mw_stddev=402.100, cpu_power_watts=1.859, energy_to_solution_joules=30.800, energy_to_solution_joules_estimate=30.800, energy_verdict=measured, gpu_power_mw_max=72, gpu_power_mw_mean=69.179, gpu_power_mw_p50=70, gpu_power_mw_p75=71, gpu_power_mw_p95=72, gpu_power_mw_p99=72, gpu_power_mw_stddev=2.253, iteration=10, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=16.241, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.974, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-compose-loop-orbstack-1780206171129-53045068 | compose-loop | orbstack | 15.401 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.770, combined_power_mw_max=2666, combined_power_mw_mean=1769.769, combined_power_mw_p50=1736, combined_power_mw_p75=1927, combined_power_mw_p95=2666, combined_power_mw_p99=2666, combined_power_mw_stddev=417.905, cpu_energy_to_solution_joules_estimate=25.679, cpu_power_mw_max=2598, cpu_power_mw_mean=1700.308, cpu_power_mw_p50=1664, cpu_power_mw_p75=1856, cpu_power_mw_p95=2598, cpu_power_mw_p99=2598, cpu_power_mw_stddev=417.414, cpu_power_watts=1.700, energy_to_solution_joules=26.728, energy_to_solution_joules_estimate=26.728, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=69.462, gpu_power_mw_p50=70, gpu_power_mw_p75=71, gpu_power_mw_p95=74, gpu_power_mw_p99=74, gpu_power_mw_stddev=2.605, iteration=10, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.372, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.103, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-npm-install-orbstack-1780206186587-5b81999e | npm-install | orbstack | 15.570 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.372, combined_power_mw_max=3318, combined_power_mw_mean=2371.857, combined_power_mw_p50=2499, combined_power_mw_p75=2698, combined_power_mw_p95=3318, combined_power_mw_p99=3318, combined_power_mw_stddev=583.407, cpu_energy_to_solution_joules_estimate=35.182, cpu_power_mw_max=3247, cpu_power_mw_mean=2304.286, cpu_power_mw_p50=2433, cpu_power_mw_p75=2631, cpu_power_mw_p95=3247, cpu_power_mw_p99=3247, cpu_power_mw_stddev=582.709, cpu_power_watts=2.304, energy_to_solution_joules=36.213, energy_to_solution_joules_estimate=36.213, energy_verdict=measured, gpu_power_mw_max=71, gpu_power_mw_mean=67.679, gpu_power_mw_p50=68, gpu_power_mw_p75=70, gpu_power_mw_p95=71, gpu_power_mw_p99=71, gpu_power_mw_stddev=2.300, iteration=10, low_power_mode=false, matched_process_lines=30, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.539, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=14, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=15.268, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-pnpm-install-orbstack-1780206202217-5fa2115d | pnpm-install | orbstack | 18.671 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.621, combined_power_mw_max=3851, combined_power_mw_mean=2621.176, combined_power_mw_p50=2732, combined_power_mw_p75=3099, combined_power_mw_p95=3851, combined_power_mw_p99=3851, combined_power_mw_stddev=723.091, cpu_energy_to_solution_joules_estimate=46.859, cpu_power_mw_max=3777, cpu_power_mw_mean=2551.412, cpu_power_mw_p50=2663, cpu_power_mw_p75=3028, cpu_power_mw_p95=3777, cpu_power_mw_p99=3777, cpu_power_mw_stddev=722.646, cpu_power_watts=2.551, energy_to_solution_joules=48.141, energy_to_solution_joules_estimate=48.141, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=69.706, gpu_power_mw_p50=69, gpu_power_mw_p75=72, gpu_power_mw_p95=75, gpu_power_mw_p99=75, gpu_power_mw_stddev=2.946, iteration=10, low_power_mode=false, matched_process_lines=36, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=18.630, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=17, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=18.366, workload_exit_code=0, workload_timeout_seconds=300 |
| bench-cargo-build-orbstack-1780206220946-408a2d7a | cargo-build | orbstack | 15.043 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.700, combined_power_mw_max=1576, combined_power_mw_mean=699.538, combined_power_mw_p50=472, combined_power_mw_p75=940, combined_power_mw_p95=1576, combined_power_mw_p99=1576, combined_power_mw_stddev=391.317, cpu_energy_to_solution_joules_estimate=1.320, cpu_power_mw_max=1501, cpu_power_mw_mean=631.385, cpu_power_mw_p50=402, cpu_power_mw_p75=872, cpu_power_mw_p95=1501, cpu_power_mw_p99=1501, cpu_power_mw_stddev=389.237, cpu_power_watts=0.631, energy_to_solution_joules=1.462, energy_to_solution_joules_estimate=1.462, energy_verdict=measured, gpu_power_mw_max=75, gpu_power_mw_mean=68.154, gpu_power_mw_p50=68, gpu_power_mw_p75=70, gpu_power_mw_p95=74, gpu_power_mw_p99=75, gpu_power_mw_stddev=3.548, iteration=10, low_power_mode=false, matched_process_lines=28, minimum_active_sample_seconds=15, power_exit_code=0, power_sample_duration_seconds=15.013, power_sample_limit_seconds=300, power_source=ac-power, powermetrics_sample_count=13, requested_sample_count=300, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.090, workload_exit_code=127, workload_timeout_seconds=300 |

## Failures

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
symptomsd                          424    0.13      41.31  0.00    0.00               0.97    0.00              0.00
codex-aarch64-apple-darwin         66740  0.07      45.85  0.00    0.00               1.93    0.00              0.00
mDNSResponderHelper                475    0.06      43.15  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     1592.69   61.39  1188.05 0.00               4721.33 759.89            783.22

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1699 MHz
E-Cluster HW active residency:  85.55% (600 MHz:   0% 972 MHz:  11% 1332 MHz:  22% 1704 MHz:  25% 2064 MHz:  43%)
E-Cluster idle residency:  14.45%
CPU 0 frequency: 1694 MHz
CPU 0 active residency:  66.63% (600 MHz:   0% 972 MHz: 9.5% 1332 MHz:  13% 1704 MHz:  12% 2064 MHz:  31%)
CPU 0 idle residency:  33.37%
CPU 1 frequency: 1763 MHz
CPU 1 active residency:  60.74% (600 MHz:   0% 972 MHz: 4.3% 1332 MHz:  12% 1704 MHz:  12% 2064 MHz:  32%)
CPU 1 idle residency:  39.26%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2081 MHz
P0-Cluster HW active residency:  44.36% (600 MHz: 8.5% 828 MHz: 5.9% 1056 MHz:  17% 1296 MHz: 4.8% 1524 MHz: 3.7% 1752 MHz: 2.4% 1980 MHz: 3.5% 2208 MHz: 5.7% 2448 MHz: 8.5% 2676 MHz: 2.2% 2904 MHz: 2.1% 3036 MHz: 9.6% 3132 MHz:  22% 3168 MHz: .92% 3228 MHz: 3.4%)
P0-Cluster idle residency:  55.64%
CPU 2 frequency: 2833 MHz
CPU 2 active residency:  39.86% (600 MHz: .19% 828 MHz: .10% 1056 MHz: 3.4% 1296 MHz: 1.8% 1524 MHz: .42% 1752 MHz: .09% 1980 MHz: .27% 2208 MHz: .47% 2448 MHz: 2.5% 2676 MHz: .18% 2904 MHz: .45% 3036 MHz: .87% 3132 MHz: .47% 3168 MHz: 1.2% 3228 MHz:  27%)
CPU 2 idle residency:  60.14%
CPU 3 frequency: 3049 MHz
CPU 3 active residency:  35.57% (600 MHz: .04% 828 MHz: .01% 1056 MHz: .96% 1296 MHz: 1.1% 1524 MHz: .26% 1752 MHz: .02% 1980 MHz: .16% 2208 MHz: .26% 2448 MHz: .86% 2676 MHz: .04% 2904 MHz: .41% 3036 MHz: .87% 3132 MHz: .66% 3168 MHz: .98% 3228 MHz:  29%)
CPU 3 idle residency:  64.43%
CPU 4 frequency: 3001 MHz
CPU 4 active residency:   9.30% (600 MHz: .03% 828 MHz: .01% 1056 MHz: .29% 1296 MHz: .26% 1524 MHz: .18% 1752 MHz: .02% 1980 MHz: .02% 2208 MHz: .03% 2448 MHz: .24% 2676 MHz: .01% 2904 MHz: .29% 3036 MHz: .69% 3132 MHz: .36% 3168 MHz: .46% 3228 MHz: 6.4%)
CPU 4 idle residency:  90.70%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 840 MHz
P1-Cluster HW active residency:   2.99% (600 MHz:  87% 828 MHz: .38% 1056 MHz: 1.9% 1296 MHz: 1.5% 1524 MHz: .32% 1752 MHz: .10% 1980 MHz: .34% 2208 MHz: .04% 2448 MHz: 1.8% 2676 MHz:   0% 2904 MHz: .49% 3036 MHz: 1.0% 3132 MHz: .36% 3168 MHz: .72% 3228 MHz: 4.3%)
P1-Cluster idle residency:  97.01%
CPU 5 frequency: 2871 MHz
CPU 5 active residency:   2.77% (600 MHz: .13% 828 MHz: .01% 1056 MHz: .07% 1296 MHz: .12% 1524 MHz: .02% 1752 MHz: .00% 1980 MHz: .00% 2208 MHz: .00% 2448 MHz: .05% 2676 MHz:   0% 2904 MHz: .23% 3036 MHz: .45% 3132 MHz: .27% 3168 MHz: .04% 3228 MHz: 1.4%)
CPU 5 idle residency:  97.23%
CPU 6 frequency: 2920 MHz
CPU 6 active residency:   0.98% (600 MHz: .03% 828 MHz:   0% 1056 MHz: .03% 1296 MHz: .01% 1524 MHz: .01% 1752 MHz: .00% 1980 MHz: .00% 2208 MHz:   0% 2448 MHz: .02% 2676 MHz:   0% 2904 MHz: .10% 3036 MHz: .31% 3132 MHz: .20% 3168 MHz: .04% 3228 MHz: .23%)
CPU 6 idle residency:  99.02%
CPU 7 frequency: 3013 MHz
CPU 7 active residency:   0.62% (600 MHz: .01% 828 MHz:   0% 1056 MHz:   0% 1296 MHz: .00% 1524 MHz: .00% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: .01% 2676 MHz:   0% 2904 MHz: .07% 3036 MHz: .22% 3132 MHz: .16% 3168 MHz: .03% 3228 MHz: .11%)
CPU 7 idle residency:  99.38%

CPU Power: 1728 mW
GPU Power: 65 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1793 mW

**** GPU usage ****

GPU HW active frequency: 413 MHz
GPU HW active residency:  28.83% (389 MHz:  27% 486 MHz: .34% 648 MHz: .31% 778 MHz: 1.1% 972 MHz: .26% 1296 MHz:   0%)
GPU SW requested state: (P1 :  93% P2 : .91% P3 : 2.3% P4 : 3.6% P5 : .07% P6 :   0%)
GPU idle residency:  71.17%
GPU Power: 65 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
```

```text
codex-aarch64-apple-darwin         66740  0.08      70.89  0.00    0.00               0.96    0.00              0.00
codex                              41664  0.10      67.59  0.00    0.96               1.93    0.96              0.00
mDNSResponderHelper                475    0.06      42.87  0.00    0.00               0.96    0.00              0.00
ALL_TASKS                          -2     742.52    60.98  636.96  0.97               2426.23 384.10            100.68

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1822 MHz
E-Cluster HW active residency:  51.67% (600 MHz:   0% 972 MHz:  11% 1332 MHz: 8.0% 1704 MHz:  16% 2064 MHz:  64%)
E-Cluster idle residency:  48.33%
CPU 0 frequency: 1851 MHz
CPU 0 active residency:  34.31% (600 MHz:   0% 972 MHz: 1.8% 1332 MHz: 3.4% 1704 MHz: 7.8% 2064 MHz:  21%)
CPU 0 idle residency:  65.69%
CPU 1 frequency: 1831 MHz
CPU 1 active residency:  33.09% (600 MHz:   0% 972 MHz: 2.2% 1332 MHz: 3.5% 1704 MHz: 7.5% 2064 MHz:  20%)
CPU 1 idle residency:  66.91%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 907 MHz
P0-Cluster HW active residency:  11.85% (600 MHz:  42% 828 MHz:  18% 1056 MHz:  27% 1296 MHz: 6.7% 1524 MHz: 1.7% 1752 MHz: .38% 1980 MHz: .76% 2208 MHz: 1.5% 2448 MHz: 1.7% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz: .01% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .31%)
P0-Cluster idle residency:  88.15%
CPU 2 frequency: 1214 MHz
CPU 2 active residency:   8.87% (600 MHz: .38% 828 MHz: .65% 1056 MHz: 6.0% 1296 MHz: .70% 1524 MHz: .05% 1752 MHz: .01% 1980 MHz: .02% 2208 MHz: .28% 2448 MHz: .69% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .10%)
CPU 2 idle residency:  91.13%
CPU 3 frequency: 1282 MHz
CPU 3 active residency:   3.47% (600 MHz: .11% 828 MHz: .30% 1056 MHz: 2.1% 1296 MHz: .30% 1524 MHz: .08% 1752 MHz: .00% 1980 MHz: .01% 2208 MHz: .13% 2448 MHz: .42% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .02%)
CPU 3 idle residency:  96.53%
CPU 4 frequency: 1388 MHz
CPU 4 active residency:   1.38% (600 MHz: .01% 828 MHz: .03% 1056 MHz: .30% 1296 MHz: .86% 1524 MHz: .01% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .01% 2448 MHz: .17% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 4 idle residency:  98.62%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 634 MHz
P1-Cluster HW active residency:   0.43% (600 MHz:  97% 828 MHz:   0% 1056 MHz: 1.6% 1296 MHz:   0% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: 1.1% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz: .00% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .25%)
P1-Cluster idle residency:  99.57%
CPU 5 frequency: 2156 MHz
CPU 5 active residency:   0.43% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .03% 1296 MHz:   0% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: .34% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 5 idle residency:  99.57%
CPU 6 frequency: 1080 MHz
CPU 6 active residency:   0.02% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .01% 1296 MHz:   0% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  99.98%
CPU 7 frequency: 874 MHz
CPU 7 active residency:   0.01% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .00% 1296 MHz:   0% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 7 idle residency:  99.99%

CPU Power: 178 mW
GPU Power: 59 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 236 mW

**** GPU usage ****

GPU HW active frequency: 412 MHz
GPU HW active residency:  28.45% (389 MHz:  26% 486 MHz: .54% 648 MHz: .54% 778 MHz: 1.1% 972 MHz: .05% 1296 MHz:   0%)
GPU SW requested state: (P1 :  91% P2 : 2.8% P3 : 2.9% P4 : 3.4% P5 : .10% P6 :   0%)
GPU idle residency:  71.55%
GPU Power: 60 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.04      56.68  0.00    0.00               0.96    0.00              0.00
cfprefsd                           4550   0.03      40.94  0.00    0.00               0.96    0.00              0.00
Brave Browser Helper (Renderer)    96610  0.05      75.55  0.00    0.00               0.96    0.00              0.00
ALL_TASKS                          -2     816.55    60.08  721.63  2.88               2563.64 337.27            198.82

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1802 MHz
E-Cluster HW active residency:  49.45% (600 MHz:   0% 972 MHz:  17% 1332 MHz: 5.0% 1704 MHz:  11% 2064 MHz:  67%)
E-Cluster idle residency:  50.55%
CPU 0 frequency: 1883 MHz
CPU 0 active residency:  36.61% (600 MHz:   0% 972 MHz: 3.0% 1332 MHz: 2.1% 1704 MHz: 4.9% 2064 MHz:  27%)
CPU 0 idle residency:  63.39%
CPU 1 frequency: 1861 MHz
CPU 1 active residency:  29.70% (600 MHz:   0% 972 MHz: 2.5% 1332 MHz: 2.5% 1704 MHz: 4.1% 2064 MHz:  21%)
CPU 1 idle residency:  70.30%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1016 MHz
P0-Cluster HW active residency:  20.63% (600 MHz:  32% 828 MHz:  15% 1056 MHz:  39% 1296 MHz: 3.5% 1524 MHz: 1.1% 1752 MHz: 1.3% 1980 MHz: 1.2% 2208 MHz: 1.4% 2448 MHz: 2.3% 2676 MHz: 1.3% 2904 MHz: .95% 3036 MHz: .78% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .16%)
P0-Cluster idle residency:  79.37%
CPU 2 frequency: 1533 MHz
CPU 2 active residency:  17.31% (600 MHz: .83% 828 MHz: .87% 1056 MHz: 7.7% 1296 MHz: 1.4% 1524 MHz: .44% 1752 MHz: .78% 1980 MHz: .78% 2208 MHz: .90% 2448 MHz: 1.2% 2676 MHz: 1.2% 2904 MHz: .95% 3036 MHz: .31% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .05%)
CPU 2 idle residency:  82.69%
CPU 3 frequency: 1356 MHz
CPU 3 active residency:   5.01% (600 MHz: .27% 828 MHz: .34% 1056 MHz: 2.5% 1296 MHz: .74% 1524 MHz: .03% 1752 MHz: .07% 1980 MHz: .00% 2208 MHz: .53% 2448 MHz: .44% 2676 MHz: .07% 2904 MHz: .03% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .02%)
CPU 3 idle residency:  94.99%
CPU 4 frequency: 1173 MHz
CPU 4 active residency:   1.78% (600 MHz: .00% 828 MHz: .03% 1056 MHz: 1.3% 1296 MHz: .38% 1524 MHz: .01% 1752 MHz: .00% 1980 MHz:   0% 2208 MHz: .04% 2448 MHz: .05% 2676 MHz: .00% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 4 idle residency:  98.22%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 643 MHz
P1-Cluster HW active residency:   1.48% (600 MHz:  94% 828 MHz: .81% 1056 MHz: 2.9% 1296 MHz: 1.1% 1524 MHz: .58% 1752 MHz: .58% 1980 MHz:   0% 2208 MHz: .32% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .10%)
P1-Cluster idle residency:  98.52%
CPU 5 frequency: 1015 MHz
CPU 5 active residency:   0.36% (600 MHz: .09% 828 MHz: .01% 1056 MHz: .21% 1296 MHz: .05% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .01% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 5 idle residency:  99.64%
CPU 6 frequency: 1642 MHz
CPU 6 active residency:   0.31% (600 MHz: .03% 828 MHz: .06% 1056 MHz: .03% 1296 MHz: .02% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .17% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  99.69%
CPU 7 frequency: 1388 MHz
CPU 7 active residency:   0.91% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .51% 1524 MHz: .39% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  99.09%

CPU Power: 301 mW
GPU Power: 60 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 360 mW

**** GPU usage ****

GPU HW active frequency: 405 MHz
GPU HW active residency:  28.04% (389 MHz:  27% 486 MHz: .38% 648 MHz: .33% 778 MHz: .68% 972 MHz: .09% 1296 MHz:   0%)
GPU SW requested state: (P1 :  94% P2 : 1.6% P3 : 1.9% P4 : 1.9% P5 : .11% P6 :   0%)
GPU idle residency:  71.96%
GPU Power: 60 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
```

```text
fseventsd                          320    0.03      44.11  0.00    0.00               0.97    0.00              0.00
mDNSResponderHelper                475    0.06      53.78  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    96610  0.05      78.83  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     839.26    66.68  859.81  8.73               2593.99 360.03            167.63

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1705 MHz
E-Cluster HW active residency:  53.11% (600 MHz:   0% 972 MHz: 6.9% 1332 MHz:  21% 1704 MHz:  36% 2064 MHz:  36%)
E-Cluster idle residency:  46.89%
CPU 0 frequency: 1697 MHz
CPU 0 active residency:  36.87% (600 MHz:   0% 972 MHz: 1.2% 1332 MHz: 9.9% 1704 MHz:  14% 2064 MHz:  12%)
CPU 0 idle residency:  63.13%
CPU 1 frequency: 1730 MHz
CPU 1 active residency:  32.98% (600 MHz:   0% 972 MHz: 1.2% 1332 MHz: 7.6% 1704 MHz:  12% 2064 MHz:  13%)
CPU 1 idle residency:  67.02%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 983 MHz
P0-Cluster HW active residency:  13.51% (600 MHz:  61% 828 MHz: 3.7% 1056 MHz:  11% 1296 MHz: 7.0% 1524 MHz: 2.8% 1752 MHz: 1.2% 1980 MHz: 1.5% 2208 MHz: 3.4% 2448 MHz: 7.7% 2676 MHz:   0% 2904 MHz: .00% 3036 MHz: .02% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .56%)
P0-Cluster idle residency:  86.49%
CPU 2 frequency: 1571 MHz
CPU 2 active residency:  10.41% (600 MHz: .18% 828 MHz: .10% 1056 MHz: 3.7% 1296 MHz: 1.9% 1524 MHz: .65% 1752 MHz: .48% 1980 MHz: .25% 2208 MHz: 1.3% 2448 MHz: 1.7% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .14%)
CPU 2 idle residency:  89.59%
CPU 3 frequency: 1454 MHz
CPU 3 active residency:   4.34% (600 MHz: .03% 828 MHz: .03% 1056 MHz: 1.7% 1296 MHz: 1.2% 1524 MHz: .39% 1752 MHz: .08% 1980 MHz: .06% 2208 MHz: .31% 2448 MHz: .56% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .02%)
CPU 3 idle residency:  95.66%
CPU 4 frequency: 1522 MHz
CPU 4 active residency:   3.44% (600 MHz: .49% 828 MHz: .07% 1056 MHz: .61% 1296 MHz: .67% 1524 MHz: .33% 1752 MHz: .19% 1980 MHz: .09% 2208 MHz: .26% 2448 MHz: .72% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 4 idle residency:  96.56%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 720 MHz
P1-Cluster HW active residency:   3.00% (600 MHz:  90% 828 MHz:   0% 1056 MHz: 2.0% 1296 MHz: 1.7% 1524 MHz: 1.1% 1752 MHz: .82% 1980 MHz: .86% 2208 MHz: 1.1% 2448 MHz: 2.7% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .02%)
P1-Cluster idle residency:  97.00%
CPU 5 frequency: 1739 MHz
CPU 5 active residency:   2.81% (600 MHz: .07% 828 MHz:   0% 1056 MHz: .35% 1296 MHz: .09% 1524 MHz: .67% 1752 MHz: .37% 1980 MHz: .81% 2208 MHz: .10% 2448 MHz: .36% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 5 idle residency:  97.19%
CPU 6 frequency: 1469 MHz
CPU 6 active residency:   0.30% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .06% 1296 MHz: .00% 1524 MHz: .19% 1752 MHz: .00% 1980 MHz: .00% 2208 MHz: .00% 2448 MHz: .03% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  99.70%
CPU 7 frequency: 1635 MHz
CPU 7 active residency:   0.10% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .02% 1296 MHz: .00% 1524 MHz: .05% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: .03% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  99.90%

CPU Power: 241 mW
GPU Power: 64 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 305 mW

**** GPU usage ****

GPU HW active frequency: 438 MHz
GPU HW active residency:  27.98% (389 MHz:  24% 486 MHz: .85% 648 MHz: .82% 778 MHz: 2.6% 972 MHz: .12% 1296 MHz:   0%)
GPU SW requested state: (P1 :  84% P2 : 2.8% P3 : 5.8% P4 : 7.1% P5 : .27% P6 :   0%)
GPU idle residency:  72.02%
GPU Power: 61 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
OpenVPN Connect                    855    0.07      76.26  0.00    0.00               1.92    0.00              0.00
mDNSResponderHelper                475    0.08      37.44  0.00    0.00               0.96    0.00              0.00
Brave Browser Helper (Renderer)    52516  0.06      75.12  0.00    0.00               0.96    0.00              0.00
ALL_TASKS                          -2     788.05    57.26  583.89  4.79               2480.32 440.07            103.27

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1810 MHz
E-Cluster HW active residency:  53.13% (600 MHz:   0% 972 MHz:  14% 1332 MHz: 5.6% 1704 MHz:  15% 2064 MHz:  65%)
E-Cluster idle residency:  46.87%
CPU 0 frequency: 1873 MHz
CPU 0 active residency:  37.08% (600 MHz:   0% 972 MHz: 2.3% 1332 MHz: 2.9% 1704 MHz: 6.6% 2064 MHz:  25%)
CPU 0 idle residency:  62.92%
CPU 1 frequency: 1862 MHz
CPU 1 active residency:  33.94% (600 MHz:   0% 972 MHz: 2.3% 1332 MHz: 2.2% 1704 MHz: 7.7% 2064 MHz:  22%)
CPU 1 idle residency:  66.06%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 895 MHz
P0-Cluster HW active residency:  13.34% (600 MHz:  45% 828 MHz:  16% 1056 MHz:  30% 1296 MHz: 4.5% 1524 MHz: 1.0% 1752 MHz: .26% 1980 MHz: .42% 2208 MHz: 1.4% 2448 MHz: 1.7% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz: .02% 3132 MHz: .04% 3168 MHz:   0% 3228 MHz: .74%)
P0-Cluster idle residency:  86.66%
CPU 2 frequency: 1223 MHz
CPU 2 active residency:  12.42% (600 MHz: .60% 828 MHz: .81% 1056 MHz: 7.6% 1296 MHz: 1.5% 1524 MHz: .60% 1752 MHz: .00% 1980 MHz:   0% 2208 MHz: .34% 2448 MHz: .78% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .20%)
CPU 2 idle residency:  87.58%
CPU 3 frequency: 1533 MHz
CPU 3 active residency:   2.58% (600 MHz: .05% 828 MHz: .07% 1056 MHz: 1.2% 1296 MHz: .31% 1524 MHz: .21% 1752 MHz: .00% 1980 MHz:   0% 2208 MHz: .07% 2448 MHz: .69% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .03%)
CPU 3 idle residency:  97.42%
CPU 4 frequency: 1701 MHz
CPU 4 active residency:   0.93% (600 MHz: .02% 828 MHz: .01% 1056 MHz: .25% 1296 MHz: .12% 1524 MHz: .18% 1752 MHz: .00% 1980 MHz:   0% 2208 MHz: .02% 2448 MHz: .32% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .02%)
CPU 4 idle residency:  99.07%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 645 MHz
P1-Cluster HW active residency:   0.38% (600 MHz:  96% 828 MHz:   0% 1056 MHz: 1.9% 1296 MHz: .60% 1524 MHz: .21% 1752 MHz:   0% 1980 MHz: .27% 2208 MHz: .40% 2448 MHz: .55% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .36%)
P1-Cluster idle residency:  99.62%
CPU 5 frequency: 1370 MHz
CPU 5 active residency:   0.22% (600 MHz: .06% 828 MHz:   0% 1056 MHz: .03% 1296 MHz: .00% 1524 MHz: .07% 1752 MHz:   0% 1980 MHz: .03% 2208 MHz: .00% 2448 MHz: .02% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 5 idle residency:  99.78%
CPU 6 frequency: 1865 MHz
CPU 6 active residency:   0.27% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .01% 1296 MHz:   0% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz: .23% 2208 MHz: .00% 2448 MHz: .01% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  99.73%
CPU 7 frequency: 635 MHz
CPU 7 active residency:   0.01% (600 MHz: .01% 828 MHz:   0% 1056 MHz:   0% 1296 MHz: .00% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  99.99%

CPU Power: 193 mW
GPU Power: 60 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 253 mW

**** GPU usage ****

GPU HW active frequency: 442 MHz
GPU HW active residency:  27.78% (389 MHz:  23% 486 MHz: .77% 648 MHz: .97% 778 MHz: 2.8% 972 MHz: .12% 1296 MHz:   0%)
GPU SW requested state: (P1 :  83% P2 : 3.0% P3 : 5.9% P4 : 6.2% P5 : 1.9% P6 :   0%)
GPU idle residency:  72.22%
GPU Power: 60 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.03      37.58  0.00    0.00               0.95    0.00              0.00
Brave Browser Helper (Renderer)    28631  0.04      80.57  0.00    0.00               0.95    0.00              0.00
Brave Browser Helper (Renderer)    96592  0.04      72.79  0.00    0.00               0.95    0.00              0.00
ALL_TASKS                          -2     1950.36   74.73  1666.73 15.27              3436.55 0.00              577.14

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1702 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:  14% 1332 MHz:  20% 1704 MHz:  18% 2064 MHz:  48%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 1694 MHz
CPU 0 active residency:  78.82% (600 MHz:   0% 972 MHz:  11% 1332 MHz:  16% 1704 MHz:  15% 2064 MHz:  36%)
CPU 0 idle residency:  21.18%
CPU 1 frequency: 1715 MHz
CPU 1 active residency:  75.86% (600 MHz:   0% 972 MHz: 9.2% 1332 MHz:  15% 1704 MHz:  15% 2064 MHz:  36%)
CPU 1 idle residency:  24.14%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1323 MHz
P0-Cluster HW active residency:  29.66% (600 MHz:  36% 828 MHz: 5.8% 1056 MHz:  19% 1296 MHz:  12% 1524 MHz: 4.2% 1752 MHz: 3.0% 1980 MHz: 1.2% 2208 MHz: 2.1% 2448 MHz: 1.9% 2676 MHz: 2.5% 2904 MHz: 1.2% 3036 MHz: 3.3% 3132 MHz: 2.3% 3168 MHz: .39% 3228 MHz: 5.9%)
P0-Cluster idle residency:  70.34%
CPU 2 frequency: 1961 MHz
CPU 2 active residency:  20.55% (600 MHz: .48% 828 MHz: .13% 1056 MHz: 5.1% 1296 MHz: 3.7% 1524 MHz: 1.2% 1752 MHz: 1.1% 1980 MHz: .12% 2208 MHz: 1.0% 2448 MHz: .58% 2676 MHz: 1.2% 2904 MHz: .11% 3036 MHz: .30% 3132 MHz: .41% 3168 MHz: .03% 3228 MHz: 5.0%)
CPU 2 idle residency:  79.45%
CPU 3 frequency: 2235 MHz
CPU 3 active residency:  11.53% (600 MHz: .15% 828 MHz: .11% 1056 MHz: 1.5% 1296 MHz: 1.6% 1524 MHz: .22% 1752 MHz: .37% 1980 MHz: 1.1% 2208 MHz: 1.1% 2448 MHz: .67% 2676 MHz: .49% 2904 MHz: .35% 3036 MHz: .28% 3132 MHz: .33% 3168 MHz: .00% 3228 MHz: 3.2%)
CPU 3 idle residency:  88.47%
CPU 4 frequency: 2529 MHz
CPU 4 active residency:   6.00% (600 MHz:   0% 828 MHz: .01% 1056 MHz: .46% 1296 MHz: .19% 1524 MHz: .55% 1752 MHz: .10% 1980 MHz: .08% 2208 MHz: 1.2% 2448 MHz: .09% 2676 MHz: .48% 2904 MHz: .03% 3036 MHz: .09% 3132 MHz: .20% 3168 MHz: .02% 3228 MHz: 2.5%)
CPU 4 idle residency:  94.00%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 975 MHz
P1-Cluster HW active residency:   4.13% (600 MHz:  80% 828 MHz:   0% 1056 MHz: 1.1% 1296 MHz: 2.1% 1524 MHz: 1.2% 1752 MHz: .84% 1980 MHz: .96% 2208 MHz: 2.2% 2448 MHz: 1.6% 2676 MHz: .46% 2904 MHz: .42% 3036 MHz: .84% 3132 MHz: .98% 3168 MHz: .42% 3228 MHz: 6.8%)
P1-Cluster idle residency:  95.87%
CPU 5 frequency: 2207 MHz
CPU 5 active residency:   3.77% (600 MHz: .08% 828 MHz:   0% 1056 MHz: .23% 1296 MHz: .85% 1524 MHz: .18% 1752 MHz: .47% 1980 MHz: .08% 2208 MHz: .27% 2448 MHz: .08% 2676 MHz: .04% 2904 MHz: .00% 3036 MHz: .04% 3132 MHz: .23% 3168 MHz: .03% 3228 MHz: 1.2%)
CPU 5 idle residency:  96.23%
CPU 6 frequency: 2500 MHz
CPU 6 active residency:   0.60% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .00% 1524 MHz: .01% 1752 MHz: .00% 1980 MHz: .06% 2208 MHz: .15% 2448 MHz: .15% 2676 MHz: .01% 2904 MHz:   0% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz: .00% 3228 MHz: .19%)
CPU 6 idle residency:  99.40%
CPU 7 frequency: 2553 MHz
CPU 7 active residency:   0.30% (600 MHz: .00% 828 MHz:   0% 1056 MHz:   0% 1296 MHz:   0% 1524 MHz: .00% 1752 MHz:   0% 1980 MHz: .06% 2208 MHz: .12% 2448 MHz:   0% 2676 MHz: .01% 2904 MHz: .01% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .11%)
CPU 7 idle residency:  99.70%

CPU Power: 798 mW
GPU Power: 55 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 853 mW

**** GPU usage ****

GPU HW active frequency: 422 MHz
GPU HW active residency:  25.91% (389 MHz:  23% 486 MHz: .42% 648 MHz: .56% 778 MHz: 1.6% 972 MHz: .10% 1296 MHz:   0%)
GPU SW requested state: (P1 :  89% P2 : 1.9% P3 : 3.9% P4 : 3.3% P5 : 1.5% P6 :   0%)
GPU idle residency:  74.09%
GPU Power: 55 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
```

```text
sysmond                            38283  0.03      0.00   0.00    0.00               0.00    0.00              0.00
Brave Browser Helper (Renderer)    67069  0.04      51.22  0.00    0.00               0.96    0.00              0.00
mDNSResponderHelper                475    0.06      42.66  0.00    0.00               0.96    0.00              0.00
ALL_TASKS                          -2     1047.61   56.43  1475.86 12.46              3477.86 455.22            479.49

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1824 MHz
E-Cluster HW active residency:  55.77% (600 MHz:   0% 972 MHz:  11% 1332 MHz: 9.1% 1704 MHz:  16% 2064 MHz:  64%)
E-Cluster idle residency:  44.23%
CPU 0 frequency: 1833 MHz
CPU 0 active residency:  37.43% (600 MHz:   0% 972 MHz: 3.0% 1332 MHz: 4.1% 1704 MHz: 6.6% 2064 MHz:  24%)
CPU 0 idle residency:  62.57%
CPU 1 frequency: 1820 MHz
CPU 1 active residency:  36.93% (600 MHz:   0% 972 MHz: 2.8% 1332 MHz: 3.7% 1704 MHz: 8.9% 2064 MHz:  21%)
CPU 1 idle residency:  63.07%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1335 MHz
P0-Cluster HW active residency:  28.55% (600 MHz:  31% 828 MHz:  14% 1056 MHz:  24% 1296 MHz: 3.2% 1524 MHz: 1.7% 1752 MHz: 1.5% 1980 MHz: 1.9% 2208 MHz: 1.7% 2448 MHz: 3.3% 2676 MHz: 2.0% 2904 MHz: .42% 3036 MHz: 4.9% 3132 MHz: 4.1% 3168 MHz: .41% 3228 MHz: 5.2%)
P0-Cluster idle residency:  71.45%
CPU 2 frequency: 2185 MHz
CPU 2 active residency:  22.35% (600 MHz: .72% 828 MHz: 1.4% 1056 MHz: 4.8% 1296 MHz: 1.6% 1524 MHz: .72% 1752 MHz: .35% 1980 MHz: .54% 2208 MHz: .92% 2448 MHz: .98% 2676 MHz: .81% 2904 MHz: .40% 3036 MHz: .48% 3132 MHz: .35% 3168 MHz: .03% 3228 MHz: 8.4%)
CPU 2 idle residency:  77.65%
CPU 3 frequency: 2571 MHz
CPU 3 active residency:  13.80% (600 MHz: .06% 828 MHz: .15% 1056 MHz: 1.7% 1296 MHz: .61% 1524 MHz: .38% 1752 MHz: .40% 1980 MHz: .86% 2208 MHz: .26% 2448 MHz: .82% 2676 MHz: .57% 2904 MHz: .31% 3036 MHz: .42% 3132 MHz: .42% 3168 MHz: .02% 3228 MHz: 6.9%)
CPU 3 idle residency:  86.20%
CPU 4 frequency: 2623 MHz
CPU 4 active residency:   6.59% (600 MHz: .03% 828 MHz: .02% 1056 MHz: .82% 1296 MHz: .30% 1524 MHz: .02% 1752 MHz: .19% 1980 MHz: .48% 2208 MHz: .02% 2448 MHz: .40% 2676 MHz: .28% 2904 MHz: .12% 3036 MHz: .18% 3132 MHz: .18% 3168 MHz: .00% 3228 MHz: 3.5%)
CPU 4 idle residency:  93.41%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 979 MHz
P1-Cluster HW active residency:   3.23% (600 MHz:  78% 828 MHz: .82% 1056 MHz: 4.1% 1296 MHz: .80% 1524 MHz: .65% 1752 MHz: 1.4% 1980 MHz: 1.4% 2208 MHz: .47% 2448 MHz: .38% 2676 MHz: .70% 2904 MHz: .42% 3036 MHz: .59% 3132 MHz: .66% 3168 MHz: .42% 3228 MHz: 8.8%)
P1-Cluster idle residency:  96.77%
CPU 5 frequency: 2910 MHz
CPU 5 active residency:   3.00% (600 MHz: .08% 828 MHz: .00% 1056 MHz: .10% 1296 MHz: .03% 1524 MHz: .01% 1752 MHz: .02% 1980 MHz: .12% 2208 MHz: .00% 2448 MHz: .19% 2676 MHz: .13% 2904 MHz: .02% 3036 MHz: .13% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: 2.2%)
CPU 5 idle residency:  97.00%
CPU 6 frequency: 2873 MHz
CPU 6 active residency:   0.67% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .00% 1524 MHz: .00% 1752 MHz: .00% 1980 MHz: .10% 2208 MHz: .00% 2448 MHz: .00% 2676 MHz: .02% 2904 MHz:   0% 3036 MHz: .18% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .35%)
CPU 6 idle residency:  99.33%
CPU 7 frequency: 2697 MHz
CPU 7 active residency:   0.31% (600 MHz: .00% 828 MHz:   0% 1056 MHz:   0% 1296 MHz:   0% 1524 MHz:   0% 1752 MHz: .00% 1980 MHz: .12% 2208 MHz:   0% 2448 MHz: .00% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz: .05% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .14%)
CPU 7 idle residency:  99.69%

CPU Power: 814 mW
GPU Power: 65 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 879 mW

**** GPU usage ****

GPU HW active frequency: 471 MHz
GPU HW active residency:  28.04% (389 MHz:  21% 486 MHz: 1.6% 648 MHz: 1.6% 778 MHz: 3.6% 972 MHz: .59% 1296 MHz:   0%)
GPU SW requested state: (P1 :  74% P2 : 5.0% P3 : 8.0% P4 :  12% P5 : .80% P6 :   0%)
GPU idle residency:  71.96%
GPU Power: 65 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
fseventsd                          320    0.05      57.58  0.00    0.00               0.96    0.00              0.00
Brave Browser Helper (Renderer)    66855  0.02      64.15  0.00    0.00               0.96    0.96              0.00
mDNSResponderHelper                475    0.06      49.06  0.00    0.00               0.96    0.00              0.00
ALL_TASKS                          -2     831.34    59.61  535.23  0.00               2262.94 291.16            105.72

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1755 MHz
E-Cluster HW active residency:  56.07% (600 MHz:   0% 972 MHz:  12% 1332 MHz: 5.4% 1704 MHz:  37% 2064 MHz:  45%)
E-Cluster idle residency:  43.93%
CPU 0 frequency: 1741 MHz
CPU 0 active residency:  38.79% (600 MHz:   0% 972 MHz: 4.0% 1332 MHz: 3.6% 1704 MHz:  15% 2064 MHz:  16%)
CPU 0 idle residency:  61.21%
CPU 1 frequency: 1742 MHz
CPU 1 active residency:  37.93% (600 MHz:   0% 972 MHz: 3.5% 1332 MHz: 3.1% 1704 MHz:  17% 2064 MHz:  14%)
CPU 1 idle residency:  62.07%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 837 MHz
P0-Cluster HW active residency:  11.80% (600 MHz:  61% 828 MHz: 9.6% 1056 MHz:  17% 1296 MHz: 5.7% 1524 MHz: 1.3% 1752 MHz: 1.3% 1980 MHz: .88% 2208 MHz: .62% 2448 MHz: 2.1% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz: .01% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .31%)
P0-Cluster idle residency:  88.20%
CPU 2 frequency: 1272 MHz
CPU 2 active residency:   7.63% (600 MHz: .93% 828 MHz: .36% 1056 MHz: 3.9% 1296 MHz: .73% 1524 MHz: .09% 1752 MHz: .47% 1980 MHz: .13% 2208 MHz: .01% 2448 MHz: .95% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .07%)
CPU 2 idle residency:  92.37%
CPU 3 frequency: 1652 MHz
CPU 3 active residency:   4.40% (600 MHz: .02% 828 MHz: .04% 1056 MHz: .93% 1296 MHz: 1.6% 1524 MHz: .08% 1752 MHz: .12% 1980 MHz: .02% 2208 MHz: .58% 2448 MHz: 1.0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .02%)
CPU 3 idle residency:  95.60%
CPU 4 frequency: 1637 MHz
CPU 4 active residency:   1.63% (600 MHz: .00% 828 MHz: .01% 1056 MHz: .39% 1296 MHz: .28% 1524 MHz: .00% 1752 MHz: .32% 1980 MHz: .43% 2208 MHz: .05% 2448 MHz: .14% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 4 idle residency:  98.37%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 626 MHz
P1-Cluster HW active residency:   0.53% (600 MHz:  97% 828 MHz:   0% 1056 MHz: 1.5% 1296 MHz: .49% 1524 MHz: .23% 1752 MHz:   0% 1980 MHz: .27% 2208 MHz: .05% 2448 MHz: .51% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
P1-Cluster idle residency:  99.47%
CPU 5 frequency: 1692 MHz
CPU 5 active residency:   0.41% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .05% 1296 MHz: .13% 1524 MHz: .00% 1752 MHz:   0% 1980 MHz: .00% 2208 MHz: .00% 2448 MHz: .18% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 5 idle residency:  99.59%
CPU 6 frequency: 2278 MHz
CPU 6 active residency:   0.41% (600 MHz: .03% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .00% 1524 MHz: .00% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .00% 2448 MHz: .36% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 6 idle residency:  99.59%
CPU 7 frequency: 888 MHz
CPU 7 active residency:   0.02% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .01% 1296 MHz:   0% 1524 MHz: .00% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: .00% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  99.98%

CPU Power: 190 mW
GPU Power: 59 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 249 mW

**** GPU usage ****

GPU HW active frequency: 459 MHz
GPU HW active residency:  27.27% (389 MHz:  21% 486 MHz: .92% 648 MHz: 1.4% 778 MHz: 3.1% 972 MHz: .47% 1296 MHz:   0%)
GPU SW requested state: (P1 :  78% P2 : 2.8% P3 : 9.1% P4 : 9.3% P5 : .41% P6 :   0%)
GPU idle residency:  72.73%
GPU Power: 59 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.06      47.53  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    55732  0.05      78.79  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper               96567  0.04      62.92  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     727.68    60.28  658.49  7.76               2434.19 356.88            90.81

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1801 MHz
E-Cluster HW active residency:  51.01% (600 MHz:   0% 972 MHz:  14% 1332 MHz: 2.3% 1704 MHz:  26% 2064 MHz:  58%)
E-Cluster idle residency:  48.99%
CPU 0 frequency: 1838 MHz
CPU 0 active residency:  36.05% (600 MHz:   0% 972 MHz: 3.5% 1332 MHz: 1.1% 1704 MHz:  10% 2064 MHz:  22%)
CPU 0 idle residency:  63.95%
CPU 1 frequency: 1851 MHz
CPU 1 active residency:  31.51% (600 MHz:   0% 972 MHz: 2.3% 1332 MHz: .87% 1704 MHz:  10% 2064 MHz:  18%)
CPU 1 idle residency:  68.49%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 886 MHz
P0-Cluster HW active residency:   9.73% (600 MHz:  52% 828 MHz:  11% 1056 MHz:  25% 1296 MHz: 2.8% 1524 MHz: 1.7% 1752 MHz: 2.7% 1980 MHz: 1.4% 2208 MHz: .39% 2448 MHz: 2.4% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz: .00% 3132 MHz: .01% 3168 MHz:   0% 3228 MHz: .40%)
P0-Cluster idle residency:  90.27%
CPU 2 frequency: 1171 MHz
CPU 2 active residency:   8.42% (600 MHz: .94% 828 MHz: .69% 1056 MHz: 5.2% 1296 MHz: .29% 1524 MHz: .16% 1752 MHz: .21% 1980 MHz: .23% 2208 MHz: .01% 2448 MHz: .71% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .03%)
CPU 2 idle residency:  91.58%
CPU 3 frequency: 1318 MHz
CPU 3 active residency:   1.66% (600 MHz: .03% 828 MHz: .05% 1056 MHz: 1.0% 1296 MHz: .02% 1524 MHz: .20% 1752 MHz: .06% 1980 MHz: .07% 2208 MHz: .00% 2448 MHz: .18% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 3 idle residency:  98.34%
CPU 4 frequency: 1528 MHz
CPU 4 active residency:   1.07% (600 MHz: .01% 828 MHz: .01% 1056 MHz: .24% 1296 MHz: .02% 1524 MHz: .53% 1752 MHz: .17% 1980 MHz: .01% 2208 MHz:   0% 2448 MHz: .08% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 4 idle residency:  98.93%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 637 MHz
P1-Cluster HW active residency:   0.51% (600 MHz:  97% 828 MHz:   0% 1056 MHz: 1.2% 1296 MHz: .37% 1524 MHz:   0% 1752 MHz: .05% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: 1.1% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .28%)
P1-Cluster idle residency:  99.49%
CPU 5 frequency: 1989 MHz
CPU 5 active residency:   0.52% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .10% 1296 MHz: .00% 1524 MHz:   0% 1752 MHz: .00% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: .36% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 5 idle residency:  99.48%
CPU 6 frequency: 947 MHz
CPU 6 active residency:   0.03% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .00% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: .00% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  99.97%
CPU 7 frequency: 851 MHz
CPU 7 active residency:   0.01% (600 MHz: .00% 828 MHz:   0% 1056 MHz:   0% 1296 MHz: .00% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  99.99%

CPU Power: 164 mW
GPU Power: 63 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 227 mW

**** GPU usage ****

GPU HW active frequency: 431 MHz
GPU HW active residency:  27.83% (389 MHz:  24% 486 MHz: .90% 648 MHz: .69% 778 MHz: 2.0% 972 MHz: .21% 1296 MHz:   0%)
GPU SW requested state: (P1 :  87% P2 : 2.2% P3 : 4.0% P4 : 6.2% P5 : .24% P6 :   0%)
GPU idle residency:  72.17%
GPU Power: 63 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
contextstored                      355    0.08      34.78  0.00    0.00               0.97    0.00              0.00
mDNSResponderHelper                475    0.05      32.65  0.00    0.00               0.97    0.00              0.00
codex                              41664  0.03      53.46  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     1870.20   73.51  1935.53 22.26              3437.50 3.87              1010.16

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1440 MHz
E-Cluster HW active residency:  84.45% (600 MHz:   0% 972 MHz:  51% 1332 MHz: 7.8% 1704 MHz: 3.7% 2064 MHz:  38%)
E-Cluster idle residency:  15.55%
CPU 0 frequency: 1441 MHz
CPU 0 active residency:  60.05% (600 MHz:   0% 972 MHz:  30% 1332 MHz: 5.0% 1704 MHz: 2.6% 2064 MHz:  22%)
CPU 0 idle residency:  39.95%
CPU 1 frequency: 1446 MHz
CPU 1 active residency:  63.22% (600 MHz:   0% 972 MHz:  31% 1332 MHz: 6.5% 1704 MHz: 2.5% 2064 MHz:  24%)
CPU 1 idle residency:  36.78%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2156 MHz
P0-Cluster HW active residency:  41.93% (600 MHz: 6.3% 828 MHz: .27% 1056 MHz: .96% 1296 MHz: 2.1% 1524 MHz: 9.6% 1752 MHz:  13% 1980 MHz:  13% 2208 MHz:  16% 2448 MHz:  14% 2676 MHz: 5.1% 2904 MHz: 3.5% 3036 MHz: 5.6% 3132 MHz: 4.1% 3168 MHz: .22% 3228 MHz: 6.6%)
P0-Cluster idle residency:  58.07%
CPU 2 frequency: 2403 MHz
CPU 2 active residency:  28.10% (600 MHz: .12% 828 MHz: .00% 1056 MHz: .03% 1296 MHz: .75% 1524 MHz: 2.3% 1752 MHz: 4.1% 1980 MHz: 2.2% 2208 MHz: 3.1% 2448 MHz: 4.8% 2676 MHz: 2.1% 2904 MHz: .80% 3036 MHz: 1.4% 3132 MHz: .46% 3168 MHz: .18% 3228 MHz: 5.8%)
CPU 2 idle residency:  71.90%
CPU 3 frequency: 2477 MHz
CPU 3 active residency:  20.68% (600 MHz: .06% 828 MHz: .01% 1056 MHz: .11% 1296 MHz: .46% 1524 MHz: 1.7% 1752 MHz: 2.4% 1980 MHz: 2.3% 2208 MHz: 1.2% 2448 MHz: 2.9% 2676 MHz: 1.4% 2904 MHz: 1.4% 3036 MHz: 1.2% 3132 MHz: .39% 3168 MHz: .13% 3228 MHz: 5.1%)
CPU 3 idle residency:  79.32%
CPU 4 frequency: 2544 MHz
CPU 4 active residency:  10.57% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .19% 1524 MHz: 1.2% 1752 MHz: .84% 1980 MHz: .91% 2208 MHz: .91% 2448 MHz: 1.0% 2676 MHz: .41% 2904 MHz: .87% 3036 MHz: .98% 3132 MHz: .21% 3168 MHz: .15% 3228 MHz: 2.9%)
CPU 4 idle residency:  89.43%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1297 MHz
P1-Cluster HW active residency:  12.16% (600 MHz:  63% 828 MHz: .07% 1056 MHz: 1.1% 1296 MHz: 1.8% 1524 MHz: 3.9% 1752 MHz: 2.0% 1980 MHz: 1.6% 2208 MHz: 2.9% 2448 MHz: 6.0% 2676 MHz: 2.5% 2904 MHz: 1.6% 3036 MHz: 3.2% 3132 MHz: .75% 3168 MHz: .32% 3228 MHz: 9.3%)
P1-Cluster idle residency:  87.84%
CPU 5 frequency: 2527 MHz
CPU 5 active residency:   8.83% (600 MHz: .13% 828 MHz: .00% 1056 MHz: .22% 1296 MHz: .81% 1524 MHz: .79% 1752 MHz: .34% 1980 MHz: .27% 2208 MHz: .60% 2448 MHz: .65% 2676 MHz: .26% 2904 MHz: .75% 3036 MHz: .48% 3132 MHz: .08% 3168 MHz: .09% 3228 MHz: 3.3%)
CPU 5 idle residency:  91.17%
CPU 6 frequency: 2525 MHz
CPU 6 active residency:   3.56% (600 MHz: .03% 828 MHz:   0% 1056 MHz: .02% 1296 MHz: .08% 1524 MHz: .10% 1752 MHz: .15% 1980 MHz: .82% 2208 MHz: .26% 2448 MHz: .33% 2676 MHz: .34% 2904 MHz: .07% 3036 MHz: .32% 3132 MHz: .12% 3168 MHz: .04% 3228 MHz: .88%)
CPU 6 idle residency:  96.44%
CPU 7 frequency: 2445 MHz
CPU 7 active residency:   2.23% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .00% 1524 MHz: .38% 1752 MHz: .43% 1980 MHz: .15% 2208 MHz: .06% 2448 MHz: .00% 2676 MHz: .11% 2904 MHz: .03% 3036 MHz: .47% 3132 MHz: .03% 3168 MHz: .09% 3228 MHz: .46%)
CPU 7 idle residency:  97.77%

CPU Power: 1396 mW
GPU Power: 27 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1424 mW

**** GPU usage ****

GPU HW active frequency: 390 MHz
GPU HW active residency:  11.32% (389 MHz:  11% 486 MHz: .13% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 : .06% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  88.68%
GPU Power: 27 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.06      54.16  0.00    0.00               0.96    0.00              0.00
Brave Browser Helper (Renderer)    96592  0.04      68.32  0.00    0.00               0.96    0.00              0.00
Brave Browser Helper               96565  0.05      69.56  0.00    0.00               0.96    0.00              0.00
ALL_TASKS                          -2     1087.04   59.47  1729.02 11.49              3566.27 285.46            660.80

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1735 MHz
E-Cluster HW active residency:  54.10% (600 MHz:   0% 972 MHz: 7.6% 1332 MHz:  19% 1704 MHz:  29% 2064 MHz:  44%)
E-Cluster idle residency:  45.90%
CPU 0 frequency: 1778 MHz
CPU 0 active residency:  35.87% (600 MHz:   0% 972 MHz: 2.3% 1332 MHz: 6.1% 1704 MHz: 9.3% 2064 MHz:  18%)
CPU 0 idle residency:  64.13%
CPU 1 frequency: 1760 MHz
CPU 1 active residency:  36.60% (600 MHz:   0% 972 MHz: 1.5% 1332 MHz: 8.2% 1704 MHz: 9.5% 2064 MHz:  17%)
CPU 1 idle residency:  63.40%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1219 MHz
P0-Cluster HW active residency:  23.73% (600 MHz:  52% 828 MHz: 5.1% 1056 MHz:  15% 1296 MHz: 2.2% 1524 MHz: 2.3% 1752 MHz: 1.9% 1980 MHz: 1.9% 2208 MHz: 1.9% 2448 MHz: 1.3% 2676 MHz: 1.3% 2904 MHz: .76% 3036 MHz: 4.6% 3132 MHz: 4.4% 3168 MHz: .35% 3228 MHz: 4.7%)
P0-Cluster idle residency:  76.27%
CPU 2 frequency: 2229 MHz
CPU 2 active residency:  17.03% (600 MHz: 1.0% 828 MHz: .26% 1056 MHz: 2.8% 1296 MHz: 1.7% 1524 MHz: .94% 1752 MHz: .61% 1980 MHz: .37% 2208 MHz: .50% 2448 MHz: .48% 2676 MHz: .26% 2904 MHz: .38% 3036 MHz: .26% 3132 MHz: .41% 3168 MHz: .02% 3228 MHz: 7.0%)
CPU 2 idle residency:  82.97%
CPU 3 frequency: 2662 MHz
CPU 3 active residency:  10.96% (600 MHz: .06% 828 MHz: .05% 1056 MHz: .90% 1296 MHz: .46% 1524 MHz: .31% 1752 MHz: .21% 1980 MHz: .43% 2208 MHz: .84% 2448 MHz: .54% 2676 MHz: .61% 2904 MHz: .07% 3036 MHz: .33% 3132 MHz: .25% 3168 MHz: .01% 3228 MHz: 5.9%)
CPU 3 idle residency:  89.04%
CPU 4 frequency: 2793 MHz
CPU 4 active residency:   7.69% (600 MHz: .03% 828 MHz: .01% 1056 MHz: .18% 1296 MHz: .33% 1524 MHz: .21% 1752 MHz: .82% 1980 MHz: .28% 2208 MHz: .05% 2448 MHz: .15% 2676 MHz: .02% 2904 MHz: .02% 3036 MHz: .31% 3132 MHz: .32% 3168 MHz: .06% 3228 MHz: 4.9%)
CPU 4 idle residency:  92.31%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 972 MHz
P1-Cluster HW active residency:   5.14% (600 MHz:  83% 828 MHz:   0% 1056 MHz: 1.1% 1296 MHz: 1.2% 1524 MHz: .67% 1752 MHz:   0% 1980 MHz: .53% 2208 MHz:   0% 2448 MHz: .68% 2676 MHz: .56% 2904 MHz:   0% 3036 MHz: .79% 3132 MHz: 1.9% 3168 MHz: .38% 3228 MHz: 9.3%)
P1-Cluster idle residency:  94.86%
CPU 5 frequency: 3101 MHz
CPU 5 active residency:   4.13% (600 MHz: .06% 828 MHz:   0% 1056 MHz: .03% 1296 MHz: .05% 1524 MHz: .02% 1752 MHz:   0% 1980 MHz: .02% 2208 MHz:   0% 2448 MHz: .14% 2676 MHz: .00% 2904 MHz:   0% 3036 MHz: .12% 3132 MHz: .27% 3168 MHz: .01% 3228 MHz: 3.4%)
CPU 5 idle residency:  95.87%
CPU 6 frequency: 3128 MHz
CPU 6 active residency:   1.95% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .01% 1524 MHz: .00% 1752 MHz:   0% 1980 MHz: .00% 2208 MHz:   0% 2448 MHz: .12% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz: .09% 3132 MHz: .12% 3168 MHz:   0% 3228 MHz: 1.6%)
CPU 6 idle residency:  98.05%
CPU 7 frequency: 3077 MHz
CPU 7 active residency:   0.76% (600 MHz: .00% 828 MHz:   0% 1056 MHz:   0% 1296 MHz:   0% 1524 MHz: .00% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: .12% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz: .02% 3132 MHz: .06% 3168 MHz:   0% 3228 MHz: .55%)
CPU 7 idle residency:  99.24%

CPU Power: 894 mW
GPU Power: 66 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 960 mW

**** GPU usage ****

GPU HW active frequency: 433 MHz
GPU HW active residency:  27.49% (389 MHz:  24% 486 MHz: .62% 648 MHz: .51% 778 MHz: 2.3% 972 MHz: .20% 1296 MHz:   0%)
GPU SW requested state: (P1 :  86% P2 : 1.9% P3 : 4.7% P4 : 6.5% P5 : .44% P6 :   0%)
GPU idle residency:  72.51%
GPU Power: 66 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    28392  0.03      47.93  0.00    0.00               0.97    0.97              0.00
mDNSResponderHelper                475    0.02      42.79  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    55732  0.05      68.25  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     908.95    60.01  877.26  1.93               2727.33 297.25            239.65

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1796 MHz
E-Cluster HW active residency:  54.80% (600 MHz:   0% 972 MHz: 9.1% 1332 MHz: 6.6% 1704 MHz:  33% 2064 MHz:  51%)
E-Cluster idle residency:  45.20%
CPU 0 frequency: 1797 MHz
CPU 0 active residency:  41.79% (600 MHz:   0% 972 MHz: 2.9% 1332 MHz: 3.8% 1704 MHz:  15% 2064 MHz:  21%)
CPU 0 idle residency:  58.21%
CPU 1 frequency: 1800 MHz
CPU 1 active residency:  32.29% (600 MHz:   0% 972 MHz: 2.6% 1332 MHz: 2.3% 1704 MHz:  11% 2064 MHz:  16%)
CPU 1 idle residency:  67.71%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 993 MHz
P0-Cluster HW active residency:  14.89% (600 MHz:  58% 828 MHz: 6.4% 1056 MHz:  17% 1296 MHz: 3.5% 1524 MHz: 2.1% 1752 MHz: 1.5% 1980 MHz: 1.6% 2208 MHz: 1.1% 2448 MHz: 2.0% 2676 MHz: 1.1% 2904 MHz: .76% 3036 MHz: .84% 3132 MHz: 1.0% 3168 MHz: .98% 3228 MHz: 1.9%)
P0-Cluster idle residency:  85.11%
CPU 2 frequency: 1525 MHz
CPU 2 active residency:  10.40% (600 MHz: .96% 828 MHz: .43% 1056 MHz: 4.2% 1296 MHz: .80% 1524 MHz: .66% 1752 MHz: .36% 1980 MHz: .63% 2208 MHz: .50% 2448 MHz: .31% 2676 MHz: .27% 2904 MHz: .15% 3036 MHz: .18% 3132 MHz: .37% 3168 MHz: .29% 3228 MHz: .28%)
CPU 2 idle residency:  89.60%
CPU 3 frequency: 2026 MHz
CPU 3 active residency:   5.89% (600 MHz: .04% 828 MHz: .04% 1056 MHz: 1.4% 1296 MHz: .61% 1524 MHz: .63% 1752 MHz: .07% 1980 MHz: .23% 2208 MHz: .22% 2448 MHz: .74% 2676 MHz: .57% 2904 MHz: .26% 3036 MHz: .26% 3132 MHz: .26% 3168 MHz: .41% 3228 MHz: .20%)
CPU 3 idle residency:  94.11%
CPU 4 frequency: 1833 MHz
CPU 4 active residency:   3.27% (600 MHz: .01% 828 MHz: .01% 1056 MHz: .87% 1296 MHz: .52% 1524 MHz: .43% 1752 MHz: .00% 1980 MHz: .50% 2208 MHz: .12% 2448 MHz: .02% 2676 MHz: .10% 2904 MHz: .00% 3036 MHz: .16% 3132 MHz: .40% 3168 MHz: .01% 3228 MHz: .11%)
CPU 4 idle residency:  96.73%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 759 MHz
P1-Cluster HW active residency:   3.87% (600 MHz:  88% 828 MHz: .66% 1056 MHz: 1.9% 1296 MHz: 1.5% 1524 MHz: 1.3% 1752 MHz: 1.1% 1980 MHz: 1.5% 2208 MHz: .69% 2448 MHz: .93% 2676 MHz: .76% 2904 MHz: .38% 3036 MHz: .02% 3132 MHz: .43% 3168 MHz: .73% 3228 MHz: .37%)
P1-Cluster idle residency:  96.13%
CPU 5 frequency: 1530 MHz
CPU 5 active residency:   3.32% (600 MHz: .05% 828 MHz: .01% 1056 MHz: .88% 1296 MHz: .60% 1524 MHz: .25% 1752 MHz: .93% 1980 MHz: .40% 2208 MHz: .02% 2448 MHz: .14% 2676 MHz: .00% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .03% 3168 MHz: .01% 3228 MHz: .02%)
CPU 5 idle residency:  96.68%
CPU 6 frequency: 1531 MHz
CPU 6 active residency:   1.35% (600 MHz: .02% 828 MHz: .00% 1056 MHz: .44% 1296 MHz: .23% 1524 MHz: .20% 1752 MHz:   0% 1980 MHz: .21% 2208 MHz: .20% 2448 MHz: .02% 2676 MHz: .00% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .01% 3168 MHz: .01% 3228 MHz: .00%)
CPU 6 idle residency:  98.65%
CPU 7 frequency: 1388 MHz
CPU 7 active residency:   0.08% (600 MHz: .01% 828 MHz: .00% 1056 MHz: .04% 1296 MHz: .00% 1524 MHz: .01% 1752 MHz:   0% 1980 MHz: .00% 2208 MHz: .00% 2448 MHz:   0% 2676 MHz:   0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz: .00% 3228 MHz: .00%)
CPU 7 idle residency:  99.92%

CPU Power: 340 mW
GPU Power: 66 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 405 mW

**** GPU usage ****

GPU HW active frequency: 403 MHz
GPU HW active residency:  28.45% (389 MHz:  27% 486 MHz: .25% 648 MHz: .25% 778 MHz: .68% 972 MHz: .07% 1296 MHz:   0%)
GPU SW requested state: (P1 :  95% P2 : 1.4% P3 : 1.8% P4 : 1.7% P5 : .21% P6 :   0%)
GPU idle residency:  71.55%
GPU Power: 66 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponder                      449    0.11      44.01  0.98    0.00               1.96    0.00              0.00
fseventsd                          320    0.06      48.65  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96610  0.04      80.04  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     958.76    59.09  1104.79 8.86               2909.68 285.55            429.88

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1712 MHz
E-Cluster HW active residency:  51.24% (600 MHz:   0% 972 MHz:  15% 1332 MHz:  17% 1704 MHz:  19% 2064 MHz:  50%)
E-Cluster idle residency:  48.76%
CPU 0 frequency: 1711 MHz
CPU 0 active residency:  35.74% (600 MHz:   0% 972 MHz: 4.9% 1332 MHz: 6.5% 1704 MHz: 6.9% 2064 MHz:  17%)
CPU 0 idle residency:  64.26%
CPU 1 frequency: 1756 MHz
CPU 1 active residency:  32.18% (600 MHz:   0% 972 MHz: 4.2% 1332 MHz: 4.6% 1704 MHz: 5.4% 2064 MHz:  18%)
CPU 1 idle residency:  67.82%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1261 MHz
P0-Cluster HW active residency:  20.83% (600 MHz:  41% 828 MHz: 7.0% 1056 MHz:  22% 1296 MHz: 4.2% 1524 MHz: 1.6% 1752 MHz: 2.2% 1980 MHz: 1.9% 2208 MHz: 2.4% 2448 MHz: 1.9% 2676 MHz: 2.6% 2904 MHz: 1.1% 3036 MHz: 2.5% 3132 MHz: 3.7% 3168 MHz:   0% 3228 MHz: 5.5%)
P0-Cluster idle residency:  79.17%
CPU 2 frequency: 1994 MHz
CPU 2 active residency:  15.35% (600 MHz: .26% 828 MHz: .36% 1056 MHz: 5.1% 1296 MHz: 1.3% 1524 MHz: .47% 1752 MHz: .49% 1980 MHz: .51% 2208 MHz: .65% 2448 MHz: .25% 2676 MHz: .81% 2904 MHz: .40% 3036 MHz: .34% 3132 MHz: .63% 3168 MHz:   0% 3228 MHz: 3.7%)
CPU 2 idle residency:  84.65%
CPU 3 frequency: 2204 MHz
CPU 3 active residency:   8.06% (600 MHz: .06% 828 MHz: .06% 1056 MHz: 1.5% 1296 MHz: .57% 1524 MHz: .95% 1752 MHz: .43% 1980 MHz: .33% 2208 MHz: .25% 2448 MHz: .38% 2676 MHz: .28% 2904 MHz: .17% 3036 MHz: .25% 3132 MHz: .55% 3168 MHz:   0% 3228 MHz: 2.2%)
CPU 3 idle residency:  91.94%
CPU 4 frequency: 2103 MHz
CPU 4 active residency:   4.41% (600 MHz: .01% 828 MHz: .02% 1056 MHz: .77% 1296 MHz: .61% 1524 MHz: .49% 1752 MHz: .37% 1980 MHz: .41% 2208 MHz: .00% 2448 MHz: .05% 2676 MHz: .07% 2904 MHz: .02% 3036 MHz: .21% 3132 MHz: .05% 3168 MHz:   0% 3228 MHz: 1.3%)
CPU 4 idle residency:  95.59%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 914 MHz
P1-Cluster HW active residency:   4.43% (600 MHz:  82% 828 MHz: .35% 1056 MHz: 2.7% 1296 MHz: 1.7% 1524 MHz: 1.0% 1752 MHz: .85% 1980 MHz: 1.2% 2208 MHz: .86% 2448 MHz: .75% 2676 MHz: 1.6% 2904 MHz: .05% 3036 MHz: .23% 3132 MHz: 1.1% 3168 MHz:   0% 3228 MHz: 6.0%)
P1-Cluster idle residency:  95.57%
CPU 5 frequency: 2104 MHz
CPU 5 active residency:   3.07% (600 MHz: .07% 828 MHz: .00% 1056 MHz: .67% 1296 MHz: .18% 1524 MHz: .17% 1752 MHz: .06% 1980 MHz: .64% 2208 MHz: .09% 2448 MHz: .00% 2676 MHz: .32% 2904 MHz: .00% 3036 MHz: .00% 3132 MHz: .10% 3168 MHz:   0% 3228 MHz: .77%)
CPU 5 idle residency:  96.93%
CPU 6 frequency: 1882 MHz
CPU 6 active residency:   1.47% (600 MHz: .01% 828 MHz: .00% 1056 MHz: .18% 1296 MHz: .06% 1524 MHz: .01% 1752 MHz: .73% 1980 MHz: .25% 2208 MHz:   0% 2448 MHz: .00% 2676 MHz: .01% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .06% 3168 MHz:   0% 3228 MHz: .15%)
CPU 6 idle residency:  98.53%
CPU 7 frequency: 2242 MHz
CPU 7 active residency:   0.05% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .01% 1296 MHz:   0% 1524 MHz: .01% 1752 MHz: .01% 1980 MHz: .00% 2208 MHz:   0% 2448 MHz:   0% 2676 MHz: .00% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .03%)
CPU 7 idle residency:  99.95%

CPU Power: 525 mW
GPU Power: 70 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 595 mW

**** GPU usage ****

GPU HW active frequency: 424 MHz
GPU HW active residency:  28.30% (389 MHz:  25% 486 MHz: .55% 648 MHz: .58% 778 MHz: 1.7% 972 MHz: .21% 1296 MHz:   0%)
GPU SW requested state: (P1 :  89% P2 : 1.8% P3 : 3.8% P4 : 5.0% P5 : .17% P6 :   0%)
GPU idle residency:  71.70%
GPU Power: 70 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
fseventsd                          320    0.05      64.22  0.00    0.00               0.96    0.00              0.00
mDNSResponderHelper                475    0.03      35.31  0.00    0.00               0.96    0.00              0.00
codex-aarch64-apple-darwin         66740  0.02      51.93  0.00    0.00               0.96    0.00              0.00
ALL_TASKS                          -2     1705.96   76.12  1095.53 9.65               2998.96 99.42             464.68

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1810 MHz
E-Cluster HW active residency:  91.09% (600 MHz:   0% 972 MHz: 8.3% 1332 MHz:  11% 1704 MHz:  23% 2064 MHz:  57%)
E-Cluster idle residency:   8.91%
CPU 0 frequency: 1825 MHz
CPU 0 active residency:  69.45% (600 MHz:   0% 972 MHz: 5.3% 1332 MHz: 6.7% 1704 MHz:  16% 2064 MHz:  41%)
CPU 0 idle residency:  30.55%
CPU 1 frequency: 1843 MHz
CPU 1 active residency:  66.36% (600 MHz:   0% 972 MHz: 4.2% 1332 MHz: 4.8% 1704 MHz:  18% 2064 MHz:  39%)
CPU 1 idle residency:  33.64%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1267 MHz
P0-Cluster HW active residency:  24.36% (600 MHz:  37% 828 MHz: 8.2% 1056 MHz:  19% 1296 MHz: 5.6% 1524 MHz: 3.1% 1752 MHz: 3.6% 1980 MHz: 3.5% 2208 MHz: 6.3% 2448 MHz: 6.7% 2676 MHz: .82% 2904 MHz: 2.1% 3036 MHz: 1.6% 3132 MHz: 1.3% 3168 MHz: .41% 3228 MHz: 1.2%)
P0-Cluster idle residency:  75.64%
CPU 2 frequency: 1868 MHz
CPU 2 active residency:  19.61% (600 MHz: .26% 828 MHz: .42% 1056 MHz: 4.7% 1296 MHz: 1.3% 1524 MHz: 1.7% 1752 MHz: 1.8% 1980 MHz: 1.3% 2208 MHz: 1.6% 2448 MHz: 3.8% 2676 MHz: .44% 2904 MHz: .84% 3036 MHz: .14% 3132 MHz: .66% 3168 MHz: .01% 3228 MHz: .71%)
CPU 2 idle residency:  80.39%
CPU 3 frequency: 1974 MHz
CPU 3 active residency:   9.81% (600 MHz: .04% 828 MHz: .07% 1056 MHz: 1.6% 1296 MHz: 1.0% 1524 MHz: .59% 1752 MHz: .86% 1980 MHz: .71% 2208 MHz: 1.1% 2448 MHz: 2.7% 2676 MHz: .01% 2904 MHz: .13% 3036 MHz: .20% 3132 MHz: .28% 3168 MHz: .01% 3228 MHz: .42%)
CPU 3 idle residency:  90.19%
CPU 4 frequency: 2031 MHz
CPU 4 active residency:   5.67% (600 MHz: .01% 828 MHz: .01% 1056 MHz: .78% 1296 MHz: .39% 1524 MHz: .60% 1752 MHz: .36% 1980 MHz: .30% 2208 MHz: .59% 2448 MHz: 2.2% 2676 MHz: .01% 2904 MHz: .04% 3036 MHz: .00% 3132 MHz: .25% 3168 MHz: .00% 3228 MHz: .14%)
CPU 4 idle residency:  94.33%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 847 MHz
P1-Cluster HW active residency:   4.63% (600 MHz:  83% 828 MHz: .41% 1056 MHz: 2.4% 1296 MHz: .84% 1524 MHz: 1.5% 1752 MHz: 2.0% 1980 MHz: 1.0% 2208 MHz: .97% 2448 MHz: 4.4% 2676 MHz: .42% 2904 MHz: .77% 3036 MHz: .04% 3132 MHz: .40% 3168 MHz:   0% 3228 MHz: 1.6%)
P1-Cluster idle residency:  95.37%
CPU 5 frequency: 2177 MHz
CPU 5 active residency:   4.38% (600 MHz: .08% 828 MHz: .00% 1056 MHz: .09% 1296 MHz: .21% 1524 MHz: .65% 1752 MHz: .29% 1980 MHz: .11% 2208 MHz: .44% 2448 MHz: 2.1% 2676 MHz: .00% 2904 MHz: .01% 3036 MHz:   0% 3132 MHz: .26% 3168 MHz:   0% 3228 MHz: .13%)
CPU 5 idle residency:  95.62%
CPU 6 frequency: 2401 MHz
CPU 6 active residency:   1.45% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .00% 1296 MHz:   0% 1524 MHz: .06% 1752 MHz: .11% 1980 MHz: .00% 2208 MHz:   0% 2448 MHz: 1.1% 2676 MHz: .00% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .12% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  98.55%
CPU 7 frequency: 2305 MHz
CPU 7 active residency:   1.33% (600 MHz: .01% 828 MHz:   0% 1056 MHz:   0% 1296 MHz:   0% 1524 MHz: .10% 1752 MHz: .15% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: 1.0% 2676 MHz: .02% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .01%)
CPU 7 idle residency:  98.67%

CPU Power: 664 mW
GPU Power: 69 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 733 mW

**** GPU usage ****

GPU HW active frequency: 422 MHz
GPU HW active residency:  29.44% (389 MHz:  26% 486 MHz: .63% 648 MHz: .69% 778 MHz: 1.6% 972 MHz: .18% 1296 MHz:   0%)
GPU SW requested state: (P1 :  90% P2 : 1.9% P3 : 3.7% P4 : 4.4% P5 : .19% P6 :   0%)
GPU idle residency:  70.56%
GPU Power: 69 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.02      35.60  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    66855  0.06      70.13  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    52516  0.05      72.46  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     1445.07   53.99  1636.14 15.77              3844.92 249.36            680.08

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1741 MHz
E-Cluster HW active residency:  64.28% (600 MHz:   0% 972 MHz: 6.6% 1332 MHz:  26% 1704 MHz:  17% 2064 MHz:  51%)
E-Cluster idle residency:  35.72%
CPU 0 frequency: 1748 MHz
CPU 0 active residency:  52.58% (600 MHz:   0% 972 MHz: 3.4% 1332 MHz:  13% 1704 MHz: 9.9% 2064 MHz:  26%)
CPU 0 idle residency:  47.42%
CPU 1 frequency: 1749 MHz
CPU 1 active residency:  48.02% (600 MHz:   0% 972 MHz: 3.0% 1332 MHz:  12% 1704 MHz: 8.9% 2064 MHz:  24%)
CPU 1 idle residency:  51.98%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1510 MHz
P0-Cluster HW active residency:  27.62% (600 MHz:  37% 828 MHz: 5.7% 1056 MHz:  15% 1296 MHz: 4.8% 1524 MHz: 2.2% 1752 MHz: .46% 1980 MHz: 2.6% 2208 MHz: 3.2% 2448 MHz: 6.9% 2676 MHz: 2.8% 2904 MHz: 2.6% 3036 MHz: 8.5% 3132 MHz: 3.8% 3168 MHz: .97% 3228 MHz: 4.1%)
P0-Cluster idle residency:  72.38%
CPU 2 frequency: 2431 MHz
CPU 2 active residency:  22.01% (600 MHz: .32% 828 MHz: .28% 1056 MHz: 4.2% 1296 MHz: .89% 1524 MHz: .85% 1752 MHz: .04% 1980 MHz: .67% 2208 MHz: .85% 2448 MHz: 1.8% 2676 MHz: .45% 2904 MHz: .71% 3036 MHz: .75% 3132 MHz: .11% 3168 MHz: .31% 3228 MHz: 9.8%)
CPU 2 idle residency:  77.99%
CPU 3 frequency: 2626 MHz
CPU 3 active residency:  14.72% (600 MHz: .07% 828 MHz: .06% 1056 MHz: 1.8% 1296 MHz: .81% 1524 MHz: .60% 1752 MHz: .02% 1980 MHz: .43% 2208 MHz: .30% 2448 MHz: 1.0% 2676 MHz: .12% 2904 MHz: .68% 3036 MHz: .45% 3132 MHz: .11% 3168 MHz: .26% 3228 MHz: 8.0%)
CPU 3 idle residency:  85.28%
CPU 4 frequency: 2865 MHz
CPU 4 active residency:   8.29% (600 MHz: .02% 828 MHz: .01% 1056 MHz: .41% 1296 MHz: .15% 1524 MHz: .12% 1752 MHz: .01% 1980 MHz: .27% 2208 MHz: .74% 2448 MHz: .34% 2676 MHz: .03% 2904 MHz: .29% 3036 MHz: .24% 3132 MHz: .15% 3168 MHz: .11% 3228 MHz: 5.4%)
CPU 4 idle residency:  91.71%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 988 MHz
P1-Cluster HW active residency:   4.99% (600 MHz:  80% 828 MHz: .53% 1056 MHz: 2.8% 1296 MHz: .30% 1524 MHz: .46% 1752 MHz: .15% 1980 MHz: .39% 2208 MHz: 1.0% 2448 MHz: 2.0% 2676 MHz:   0% 2904 MHz: .55% 3036 MHz: .83% 3132 MHz: 1.1% 3168 MHz: .43% 3228 MHz: 9.0%)
P1-Cluster idle residency:  95.01%
CPU 5 frequency: 2947 MHz
CPU 5 active residency:   4.25% (600 MHz: .14% 828 MHz: .01% 1056 MHz: .21% 1296 MHz: .00% 1524 MHz: .00% 1752 MHz: .01% 1980 MHz: .07% 2208 MHz: .07% 2448 MHz: .20% 2676 MHz:   0% 2904 MHz: .01% 3036 MHz: .02% 3132 MHz: .01% 3168 MHz:   0% 3228 MHz: 3.5%)
CPU 5 idle residency:  95.75%
CPU 6 frequency: 2939 MHz
CPU 6 active residency:   1.74% (600 MHz: .03% 828 MHz:   0% 1056 MHz: .17% 1296 MHz: .00% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .04% 2448 MHz: .02% 2676 MHz:   0% 2904 MHz: .01% 3036 MHz: .00% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: 1.5%)
CPU 6 idle residency:  98.26%
CPU 7 frequency: 2948 MHz
CPU 7 active residency:   1.05% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .10% 1296 MHz: .00% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz:   0% 2448 MHz: .03% 2676 MHz:   0% 2904 MHz: .00% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .89%)
CPU 7 idle residency:  98.95%

CPU Power: 994 mW
GPU Power: 68 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1062 mW

**** GPU usage ****

GPU HW active frequency: 426 MHz
GPU HW active residency:  27.95% (389 MHz:  25% 486 MHz: .47% 648 MHz: .53% 778 MHz: 1.7% 972 MHz: .31% 1296 MHz:   0%)
GPU SW requested state: (P1 :  89% P2 : 1.8% P3 : 3.7% P4 : 4.1% P5 : 1.8% P6 :   0%)
GPU idle residency:  72.05%
GPU Power: 68 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.04      44.31  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    96593  0.04      70.79  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    96676  0.05      75.04  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     1021.59   60.22  894.46  3.86               2744.12 251.57            267.23

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1767 MHz
E-Cluster HW active residency:  56.85% (600 MHz:   0% 972 MHz: 8.4% 1332 MHz:  14% 1704 MHz:  27% 2064 MHz:  50%)
E-Cluster idle residency:  43.15%
CPU 0 frequency: 1791 MHz
CPU 0 active residency:  39.48% (600 MHz:   0% 972 MHz: 1.9% 1332 MHz: 6.2% 1704 MHz:  12% 2064 MHz:  20%)
CPU 0 idle residency:  60.52%
CPU 1 frequency: 1803 MHz
CPU 1 active residency:  39.25% (600 MHz:   0% 972 MHz: 2.1% 1332 MHz: 5.3% 1704 MHz:  11% 2064 MHz:  20%)
CPU 1 idle residency:  60.75%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1101 MHz
P0-Cluster HW active residency:  20.29% (600 MHz:  47% 828 MHz: 9.0% 1056 MHz:  20% 1296 MHz: 3.8% 1524 MHz: 2.7% 1752 MHz: 2.2% 1980 MHz: 2.2% 2208 MHz: 2.7% 2448 MHz: 3.6% 2676 MHz: 1.3% 2904 MHz: 3.2% 3036 MHz: 2.3% 3132 MHz: .34% 3168 MHz:   0% 3228 MHz: .41%)
P0-Cluster idle residency:  79.71%
CPU 2 frequency: 1667 MHz
CPU 2 active residency:  14.44% (600 MHz: .43% 828 MHz: .48% 1056 MHz: 4.3% 1296 MHz: 1.8% 1524 MHz: .93% 1752 MHz: .82% 1980 MHz: .89% 2208 MHz: 1.9% 2448 MHz: 1.1% 2676 MHz: .56% 2904 MHz: .82% 3036 MHz: .33% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .02%)
CPU 2 idle residency:  85.56%
CPU 3 frequency: 1927 MHz
CPU 3 active residency:   5.97% (600 MHz: .03% 828 MHz: .07% 1056 MHz: 1.5% 1296 MHz: .27% 1524 MHz: .88% 1752 MHz: .15% 1980 MHz: .29% 2208 MHz: .36% 2448 MHz: .73% 2676 MHz: .75% 2904 MHz: .63% 3036 MHz: .27% 3132 MHz: .01% 3168 MHz:   0% 3228 MHz: .01%)
CPU 3 idle residency:  94.03%
CPU 4 frequency: 1755 MHz
CPU 4 active residency:   5.23% (600 MHz: .01% 828 MHz: .01% 1056 MHz: 1.4% 1296 MHz: 1.1% 1524 MHz: .51% 1752 MHz: .05% 1980 MHz: .24% 2208 MHz: .11% 2448 MHz: 1.0% 2676 MHz: .41% 2904 MHz: .14% 3036 MHz: .15% 3132 MHz: .07% 3168 MHz:   0% 3228 MHz: .00%)
CPU 4 idle residency:  94.77%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 733 MHz
P1-Cluster HW active residency:   3.29% (600 MHz:  90% 828 MHz: .42% 1056 MHz: 1.8% 1296 MHz: 1.8% 1524 MHz: 1.1% 1752 MHz: .85% 1980 MHz: .85% 2208 MHz: .43% 2448 MHz: .36% 2676 MHz: .39% 2904 MHz: .43% 3036 MHz: 1.2% 3132 MHz: .36% 3168 MHz:   0% 3228 MHz: .38%)
P1-Cluster idle residency:  96.71%
CPU 5 frequency: 1804 MHz
CPU 5 active residency:   1.69% (600 MHz: .09% 828 MHz: .00% 1056 MHz: .36% 1296 MHz: .20% 1524 MHz: .14% 1752 MHz: .13% 1980 MHz: .29% 2208 MHz:   0% 2448 MHz: .02% 2676 MHz: .23% 2904 MHz: .19% 3036 MHz: .03% 3132 MHz: .01% 3168 MHz:   0% 3228 MHz: .00%)
CPU 5 idle residency:  98.31%
CPU 6 frequency: 1766 MHz
CPU 6 active residency:   1.93% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .51% 1296 MHz: .00% 1524 MHz: .43% 1752 MHz: .54% 1980 MHz: .00% 2208 MHz:   0% 2448 MHz:   0% 2676 MHz: .09% 2904 MHz: .12% 3036 MHz: .21% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz:   0%)
CPU 6 idle residency:  98.07%
CPU 7 frequency: 1363 MHz
CPU 7 active residency:   0.27% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .09% 1296 MHz: .14% 1524 MHz: .02% 1752 MHz: .00% 1980 MHz: .00% 2208 MHz:   0% 2448 MHz:   0% 2676 MHz: .00% 2904 MHz: .00% 3036 MHz: .01% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .01%)
CPU 7 idle residency:  99.73%

CPU Power: 383 mW
GPU Power: 66 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 448 mW

**** GPU usage ****

GPU HW active frequency: 432 MHz
GPU HW active residency:  29.19% (389 MHz:  25% 486 MHz: .88% 648 MHz: .91% 778 MHz: 2.2% 972 MHz: .16% 1296 MHz:   0%)
GPU SW requested state: (P1 :  86% P2 : 1.8% P3 : 6.5% P4 : 5.4% P5 : .26% P6 :   0%)
GPU idle residency:  70.81%
GPU Power: 65 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
Spotlight                          872    0.06      17.97  0.00    0.00               0.96    0.00              0.00
mDNSResponderHelper                475    0.05      42.97  0.00    0.00               0.96    0.00              0.00
codex-aarch64-apple-darwin         66740  0.12      58.01  0.00    0.00               1.93    0.00              0.00
ALL_TASKS                          -2     934.98    60.03  746.99  1.93               2519.53 267.95            226.31

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1692 MHz
E-Cluster HW active residency:  55.89% (600 MHz:   0% 972 MHz:  14% 1332 MHz:  18% 1704 MHz:  26% 2064 MHz:  43%)
E-Cluster idle residency:  44.11%
CPU 0 frequency: 1743 MHz
CPU 0 active residency:  38.50% (600 MHz:   0% 972 MHz: 3.3% 1332 MHz: 5.7% 1704 MHz:  13% 2064 MHz:  17%)
CPU 0 idle residency:  61.50%
CPU 1 frequency: 1735 MHz
CPU 1 active residency:  36.32% (600 MHz:   0% 972 MHz: 2.6% 1332 MHz: 6.8% 1704 MHz:  11% 2064 MHz:  16%)
CPU 1 idle residency:  63.68%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1044 MHz
P0-Cluster HW active residency:  17.69% (600 MHz:  48% 828 MHz: 6.3% 1056 MHz:  26% 1296 MHz: 4.3% 1524 MHz: 2.9% 1752 MHz: 1.2% 1980 MHz: 1.9% 2208 MHz: 1.5% 2448 MHz: 1.6% 2676 MHz: 1.1% 2904 MHz: 2.1% 3036 MHz: 1.7% 3132 MHz: .92% 3168 MHz:   0% 3228 MHz: .89%)
P0-Cluster idle residency:  82.31%
CPU 2 frequency: 1480 MHz
CPU 2 active residency:  13.30% (600 MHz: .93% 828 MHz: .29% 1056 MHz: 5.9% 1296 MHz: 1.2% 1524 MHz: 1.1% 1752 MHz: .58% 1980 MHz: .62% 2208 MHz: .69% 2448 MHz: .22% 2676 MHz: .46% 2904 MHz: .46% 3036 MHz: .41% 3132 MHz: .16% 3168 MHz:   0% 3228 MHz: .22%)
CPU 2 idle residency:  86.70%
CPU 3 frequency: 1730 MHz
CPU 3 active residency:   6.10% (600 MHz: .04% 828 MHz: .03% 1056 MHz: 2.1% 1296 MHz: 1.1% 1524 MHz: .35% 1752 MHz: .24% 1980 MHz: .35% 2208 MHz: .34% 2448 MHz: .15% 2676 MHz: .21% 2904 MHz: .60% 3036 MHz: .12% 3132 MHz: .21% 3168 MHz:   0% 3228 MHz: .22%)
CPU 3 idle residency:  93.90%
CPU 4 frequency: 1636 MHz
CPU 4 active residency:   2.85% (600 MHz: .02% 828 MHz: .01% 1056 MHz: .86% 1296 MHz: .97% 1524 MHz: .13% 1752 MHz: .18% 1980 MHz: .06% 2208 MHz: .06% 2448 MHz: .01% 2676 MHz: .01% 2904 MHz: .24% 3036 MHz: .19% 3132 MHz: .01% 3168 MHz:   0% 3228 MHz: .12%)
CPU 4 idle residency:  97.15%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 740 MHz
P1-Cluster HW active residency:   2.85% (600 MHz:  89% 828 MHz: .63% 1056 MHz: 2.2% 1296 MHz: 1.1% 1524 MHz: .92% 1752 MHz: .86% 1980 MHz: .41% 2208 MHz: .38% 2448 MHz: .84% 2676 MHz: .84% 2904 MHz: .43% 3036 MHz: .83% 3132 MHz: .43% 3168 MHz:   0% 3228 MHz: .61%)
P1-Cluster idle residency:  97.15%
CPU 5 frequency: 1989 MHz
CPU 5 active residency:   1.17% (600 MHz: .06% 828 MHz:   0% 1056 MHz: .29% 1296 MHz: .08% 1524 MHz: .05% 1752 MHz: .01% 1980 MHz:   0% 2208 MHz: .20% 2448 MHz: .00% 2676 MHz: .30% 2904 MHz: .06% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .09%)
CPU 5 idle residency:  98.83%
CPU 6 frequency: 2218 MHz
CPU 6 active residency:   1.76% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .04% 1296 MHz: .01% 1524 MHz: .01% 1752 MHz: .78% 1980 MHz:   0% 2208 MHz: .01% 2448 MHz: .61% 2676 MHz:   0% 2904 MHz: .04% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .25%)
CPU 6 idle residency:  98.24%
CPU 7 frequency: 2556 MHz
CPU 7 active residency:   0.05% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .01% 1296 MHz:   0% 1524 MHz: .00% 1752 MHz: .00% 1980 MHz:   0% 2208 MHz: .00% 2448 MHz: .00% 2676 MHz:   0% 2904 MHz: .03% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 7 idle residency:  99.95%

CPU Power: 328 mW
GPU Power: 64 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 391 mW

**** GPU usage ****

GPU HW active frequency: 421 MHz
GPU HW active residency:  27.11% (389 MHz:  25% 486 MHz: .25% 648 MHz: .67% 778 MHz: 1.1% 972 MHz: .42% 1296 MHz:   0%)
GPU SW requested state: (P1 :  91% P2 : .95% P3 : 1.8% P4 : 5.4% P5 : .40% P6 :   0%)
GPU idle residency:  72.89%
GPU Power: 64 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.03      37.03  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96676  0.05      58.80  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28631  0.02      44.16  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     1211.31   57.80  1720.67 12.75              3486.47 206.01            666.25

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1724 MHz
E-Cluster HW active residency:  55.35% (600 MHz:   0% 972 MHz: 5.1% 1332 MHz:  28% 1704 MHz:  22% 2064 MHz:  45%)
E-Cluster idle residency:  44.65%
CPU 0 frequency: 1731 MHz
CPU 0 active residency:  38.79% (600 MHz:   0% 972 MHz: 1.9% 1332 MHz: 9.9% 1704 MHz:  10% 2064 MHz:  17%)
CPU 0 idle residency:  61.21%
CPU 1 frequency: 1671 MHz
CPU 1 active residency:  35.88% (600 MHz:   0% 972 MHz: 2.7% 1332 MHz:  11% 1704 MHz: 8.4% 2064 MHz:  14%)
CPU 1 idle residency:  64.12%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1475 MHz
P0-Cluster HW active residency:  29.98% (600 MHz:  44% 828 MHz: 2.9% 1056 MHz:  10% 1296 MHz: 3.7% 1524 MHz: 2.3% 1752 MHz: 3.8% 1980 MHz: 3.9% 2208 MHz: 3.1% 2448 MHz: 3.6% 2676 MHz: 2.6% 2904 MHz: 2.7% 3036 MHz: 5.3% 3132 MHz: 3.7% 3168 MHz: 2.0% 3228 MHz: 6.5%)
P0-Cluster idle residency:  70.02%
CPU 2 frequency: 2345 MHz
CPU 2 active residency:  17.60% (600 MHz: .56% 828 MHz: .04% 1056 MHz: 2.3% 1296 MHz: 1.1% 1524 MHz: .32% 1752 MHz: 1.0% 1980 MHz: 1.8% 2208 MHz: .88% 2448 MHz: .87% 2676 MHz: .65% 2904 MHz: .84% 3036 MHz: .81% 3132 MHz: .12% 3168 MHz: .47% 3228 MHz: 5.8%)
CPU 2 idle residency:  82.40%
CPU 3 frequency: 2475 MHz
CPU 3 active residency:  17.16% (600 MHz: .05% 828 MHz: .03% 1056 MHz: 1.2% 1296 MHz: .63% 1524 MHz: 1.0% 1752 MHz: 1.0% 1980 MHz: 1.8% 2208 MHz: 1.9% 2448 MHz: 1.1% 2676 MHz: .57% 2904 MHz: .71% 3036 MHz: .83% 3132 MHz: .07% 3168 MHz: .36% 3228 MHz: 5.9%)
CPU 3 idle residency:  82.84%
CPU 4 frequency: 2451 MHz
CPU 4 active residency:   7.05% (600 MHz: .00% 828 MHz: .01% 1056 MHz: .88% 1296 MHz: .56% 1524 MHz: .20% 1752 MHz: .16% 1980 MHz: .75% 2208 MHz: .45% 2448 MHz: .30% 2676 MHz: .04% 2904 MHz: .29% 3036 MHz: .67% 3132 MHz: .00% 3168 MHz: .14% 3228 MHz: 2.6%)
CPU 4 idle residency:  92.95%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1111 MHz
P1-Cluster HW active residency:   7.49% (600 MHz:  72% 828 MHz: .80% 1056 MHz: 2.5% 1296 MHz: 1.4% 1524 MHz: 1.1% 1752 MHz: 2.1% 1980 MHz: 2.6% 2208 MHz: .97% 2448 MHz: 1.3% 2676 MHz: 1.3% 2904 MHz: .71% 3036 MHz: 1.7% 3132 MHz: .17% 3168 MHz: .90% 3228 MHz:  10%)
P1-Cluster idle residency:  92.51%
CPU 5 frequency: 2290 MHz
CPU 5 active residency:   6.16% (600 MHz: .07% 828 MHz: .00% 1056 MHz: .27% 1296 MHz: .47% 1524 MHz: .58% 1752 MHz: .69% 1980 MHz: .46% 2208 MHz: .70% 2448 MHz: .67% 2676 MHz: .40% 2904 MHz: .02% 3036 MHz: .11% 3132 MHz:   0% 3168 MHz: .01% 3228 MHz: 1.7%)
CPU 5 idle residency:  93.84%
CPU 6 frequency: 2282 MHz
CPU 6 active residency:   1.51% (600 MHz: .02% 828 MHz: .00% 1056 MHz: .01% 1296 MHz:   0% 1524 MHz: .01% 1752 MHz: .45% 1980 MHz: .43% 2208 MHz: .13% 2448 MHz: .01% 2676 MHz: .00% 2904 MHz: .00% 3036 MHz: .05% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .40%)
CPU 6 idle residency:  98.49%
CPU 7 frequency: 1991 MHz
CPU 7 active residency:   0.87% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .00% 1296 MHz:   0% 1524 MHz: .33% 1752 MHz: .14% 1980 MHz: .15% 2208 MHz: .09% 2448 MHz:   0% 2676 MHz: .00% 2904 MHz: .00% 3036 MHz: .03% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .12%)
CPU 7 idle residency:  99.13%

CPU Power: 911 mW
GPU Power: 64 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 975 mW

**** GPU usage ****

GPU HW active frequency: 448 MHz
GPU HW active residency:  28.51% (389 MHz:  23% 486 MHz: 1.4% 648 MHz: .83% 778 MHz: 2.8% 972 MHz: .38% 1296 MHz:   0%)
GPU SW requested state: (P1 :  81% P2 : 4.2% P3 : 6.5% P4 : 8.0% P5 : .33% P6 :   0%)
GPU idle residency:  71.49%
GPU Power: 64 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate conjet`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.04      52.39  0.00    0.00               0.98    0.00              0.00
codex-aarch64-apple-darwin         66740  0.05      61.70  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper               11621  0.04      65.95  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     1151.13   57.53  1644.56 13.70              3555.22 258.28            623.50

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1737 MHz
E-Cluster HW active residency:  53.62% (600 MHz:   0% 972 MHz: 8.0% 1332 MHz:  18% 1704 MHz:  30% 2064 MHz:  44%)
E-Cluster idle residency:  46.38%
CPU 0 frequency: 1729 MHz
CPU 0 active residency:  38.82% (600 MHz:   0% 972 MHz: 2.1% 1332 MHz: 8.4% 1704 MHz:  13% 2064 MHz:  16%)
CPU 0 idle residency:  61.18%
CPU 1 frequency: 1755 MHz
CPU 1 active residency:  34.80% (600 MHz:   0% 972 MHz: 2.0% 1332 MHz: 6.3% 1704 MHz:  11% 2064 MHz:  16%)
CPU 1 idle residency:  65.20%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1603 MHz
P0-Cluster HW active residency:  30.19% (600 MHz:  29% 828 MHz: 5.0% 1056 MHz:  17% 1296 MHz: 3.2% 1524 MHz: 3.1% 1752 MHz: 2.9% 1980 MHz: 5.6% 2208 MHz: 5.1% 2448 MHz: 8.2% 2676 MHz: 5.4% 2904 MHz: 2.4% 3036 MHz: 3.3% 3132 MHz: 3.0% 3168 MHz: .39% 3228 MHz: 7.0%)
P0-Cluster idle residency:  69.81%
CPU 2 frequency: 2267 MHz
CPU 2 active residency:  19.36% (600 MHz: .22% 828 MHz: .04% 1056 MHz: 3.8% 1296 MHz: .17% 1524 MHz: .97% 1752 MHz: .68% 1980 MHz: 1.6% 2208 MHz: 1.4% 2448 MHz: 2.7% 2676 MHz: 1.1% 2904 MHz: 1.0% 3036 MHz: .29% 3132 MHz: .19% 3168 MHz: .04% 3228 MHz: 5.1%)
CPU 2 idle residency:  80.64%
CPU 3 frequency: 2544 MHz
CPU 3 active residency:  14.31% (600 MHz: .06% 828 MHz: .01% 1056 MHz: 1.3% 1296 MHz: .09% 1524 MHz: .41% 1752 MHz: .36% 1980 MHz: 1.8% 2208 MHz: 1.4% 2448 MHz: .91% 2676 MHz: 1.2% 2904 MHz: .37% 3036 MHz: .19% 3132 MHz: .24% 3168 MHz: .00% 3228 MHz: 5.9%)
CPU 3 idle residency:  85.69%
CPU 4 frequency: 2371 MHz
CPU 4 active residency:   5.44% (600 MHz: .06% 828 MHz: .12% 1056 MHz: .83% 1296 MHz: .30% 1524 MHz: .16% 1752 MHz: .06% 1980 MHz: .34% 2208 MHz: .39% 2448 MHz: .33% 2676 MHz: .61% 2904 MHz: .16% 3036 MHz: .04% 3132 MHz: .01% 3168 MHz: .02% 3228 MHz: 2.0%)
CPU 4 idle residency:  94.56%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1087 MHz
P1-Cluster HW active residency:   6.02% (600 MHz:  72% 828 MHz: 2.2% 1056 MHz: 2.3% 1296 MHz: 2.3% 1524 MHz: 1.8% 1752 MHz: .86% 1980 MHz: 2.6% 2208 MHz: .61% 2448 MHz: 1.8% 2676 MHz: 1.9% 2904 MHz: 1.2% 3036 MHz: .34% 3132 MHz: .57% 3168 MHz:   0% 3228 MHz: 9.9%)
P1-Cluster idle residency:  93.98%
CPU 5 frequency: 2160 MHz
CPU 5 active residency:   5.19% (600 MHz: .07% 828 MHz: .01% 1056 MHz: .73% 1296 MHz: .24% 1524 MHz: 1.0% 1752 MHz: .39% 1980 MHz: .44% 2208 MHz: .07% 2448 MHz: .38% 2676 MHz: .05% 2904 MHz: .18% 3036 MHz: .01% 3132 MHz: .11% 3168 MHz:   0% 3228 MHz: 1.5%)
CPU 5 idle residency:  94.81%
CPU 6 frequency: 2646 MHz
CPU 6 active residency:   1.08% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .00% 1524 MHz: .01% 1752 MHz: .05% 1980 MHz: .02% 2208 MHz:   0% 2448 MHz: .32% 2676 MHz: .35% 2904 MHz: .02% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .28%)
CPU 6 idle residency:  98.92%
CPU 7 frequency: 2771 MHz
CPU 7 active residency:   0.19% (600 MHz: .00% 828 MHz:   0% 1056 MHz:   0% 1296 MHz:   0% 1524 MHz:   0% 1752 MHz: .01% 1980 MHz: .01% 2208 MHz:   0% 2448 MHz: .07% 2676 MHz: .00% 2904 MHz: .01% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .09%)
CPU 7 idle residency:  99.81%

CPU Power: 834 mW
GPU Power: 70 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 904 mW

**** GPU usage ****

GPU HW active frequency: 462 MHz
GPU HW active residency:  29.18% (389 MHz:  22% 486 MHz: 1.7% 648 MHz: 1.4% 778 MHz: 3.4% 972 MHz: .52% 1296 MHz:   0%)
GPU SW requested state: (P1 :  77% P2 : 5.1% P3 : 7.3% P4 : 9.1% P5 : 1.5% P6 :   0%)
GPU idle residency:  70.82%
GPU Power: 70 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 300 --workload /usr/bin/env sh -c set -eu
start=$(date +%s)
iterations=0
while :; do
  docker --context "$1" run --rm rust:1-bookworm sh -lc 'cargo --version >/dev/null && cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null'
  iterations=$((iterations + 1))
  now=$(date +%s)
  if [ "$iterations" -ge 1 ] && [ $((now - start)) -ge 15 ]; then
    break
  fi
done
echo "iterations=$iterations" conjet-energy-gate orbstack`

```text
workload_stderr:
sh: 1: cargo: not found

powermetrics_stderr:
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
Second underflow occured.
```

```text
contactsd                          5162   0.05      35.80  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.05      55.79  0.00    0.00               0.98    0.00              0.00
codex                              41664  0.04      59.40  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     895.31    59.41  837.00  5.90               2668.35 275.39            215.47

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1741 MHz
E-Cluster HW active residency:  53.74% (600 MHz:   0% 972 MHz: 7.3% 1332 MHz:  15% 1704 MHz:  38% 2064 MHz:  40%)
E-Cluster idle residency:  46.26%
CPU 0 frequency: 1735 MHz
CPU 0 active residency:  38.24% (600 MHz:   0% 972 MHz: 2.2% 1332 MHz: 6.8% 1704 MHz:  14% 2064 MHz:  15%)
CPU 0 idle residency:  61.76%
CPU 1 frequency: 1768 MHz
CPU 1 active residency:  35.14% (600 MHz:   0% 972 MHz: 1.4% 1332 MHz: 6.0% 1704 MHz:  12% 2064 MHz:  15%)
CPU 1 idle residency:  64.86%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1027 MHz
P0-Cluster HW active residency:  16.52% (600 MHz:  51% 828 MHz: 7.5% 1056 MHz:  19% 1296 MHz: 3.4% 1524 MHz: 3.1% 1752 MHz: 2.0% 1980 MHz: 3.0% 2208 MHz: 3.8% 2448 MHz: 3.3% 2676 MHz: 3.4% 2904 MHz:   0% 3036 MHz: .01% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .39%)
P0-Cluster idle residency:  83.48%
CPU 2 frequency: 1654 MHz
CPU 2 active residency:  11.90% (600 MHz: .15% 828 MHz: .28% 1056 MHz: 4.4% 1296 MHz: .72% 1524 MHz: 1.1% 1752 MHz: .47% 1980 MHz: 1.1% 2208 MHz: 1.2% 2448 MHz: 1.1% 2676 MHz: 1.4% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .05%)
CPU 2 idle residency:  88.10%
CPU 3 frequency: 1667 MHz
CPU 3 active residency:   5.29% (600 MHz: .03% 828 MHz: .17% 1056 MHz: 1.6% 1296 MHz: .54% 1524 MHz: .82% 1752 MHz: .30% 1980 MHz: .06% 2208 MHz: .44% 2448 MHz: .48% 2676 MHz: .81% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 3 idle residency:  94.71%
CPU 4 frequency: 1783 MHz
CPU 4 active residency:   3.25% (600 MHz: .00% 828 MHz: .02% 1056 MHz: .47% 1296 MHz: .77% 1524 MHz: .26% 1752 MHz: .47% 1980 MHz: .03% 2208 MHz: .41% 2448 MHz: .44% 2676 MHz: .36% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .02%)
CPU 4 idle residency:  96.75%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 717 MHz
P1-Cluster HW active residency:   2.07% (600 MHz:  90% 828 MHz:   0% 1056 MHz: 3.3% 1296 MHz: 1.4% 1524 MHz: .40% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .78% 2448 MHz: 1.2% 2676 MHz: 2.0% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .41%)
P1-Cluster idle residency:  97.93%
CPU 5 frequency: 1826 MHz
CPU 5 active residency:   1.39% (600 MHz: .06% 828 MHz:   0% 1056 MHz: .50% 1296 MHz: .05% 1524 MHz: .01% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .21% 2448 MHz: .36% 2676 MHz: .20% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 5 idle residency:  98.61%
CPU 6 frequency: 2233 MHz
CPU 6 active residency:   0.97% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .04% 1296 MHz: .03% 1524 MHz: .00% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .42% 2448 MHz: .36% 2676 MHz: .10% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  99.03%
CPU 7 frequency: 2028 MHz
CPU 7 active residency:   0.07% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .02% 1296 MHz:   0% 1524 MHz:   0% 1752 MHz:   0% 1980 MHz:   0% 2208 MHz: .01% 2448 MHz: .00% 2676 MHz: .04% 2904 MHz:   0% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  99.93%

CPU Power: 314 mW
GPU Power: 65 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 379 mW

**** GPU usage ****

GPU HW active frequency: 407 MHz
GPU HW active residency:  27.65% (389 MHz:  26% 486 MHz: .01% 648 MHz: .38% 778 MHz: .86% 972 MHz: .13% 1296 MHz:   0%)
GPU SW requested state: (P1 :  95% P2 : .50% P3 : 1.8% P4 : 2.3% P5 : .53% P6 :   0%)
GPU idle residency:  72.35%
GPU Power: 64 mW
```

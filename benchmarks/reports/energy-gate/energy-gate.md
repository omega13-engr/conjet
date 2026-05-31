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
| cargo-build | conjet | 10 | 10 | 2.018 | 2.020 | 2.021 | 2.021 | 2.017 | 0.004 |
| cargo-build | orbstack | 10 | 10 | 2.293 | 2.371 | 2.616 | 2.616 | 2.313 | 0.138 |
| compose-loop | conjet | 10 | 0 | 6.422 | 6.448 | 6.803 | 6.803 | 6.433 | 0.139 |
| compose-loop | orbstack | 10 | 10 | 30.356 | 30.366 | 30.372 | 30.372 | 30.354 | 0.013 |
| container-start-loop | conjet | 10 | 0 | 6.426 | 6.560 | 6.858 | 6.858 | 6.500 | 0.158 |
| container-start-loop | orbstack | 10 | 10 | 30.349 | 30.353 | 30.360 | 30.360 | 30.347 | 0.010 |
| hot-reload-loop | conjet | 10 | 0 | 6.367 | 6.399 | 6.470 | 6.470 | 6.367 | 0.059 |
| hot-reload-loop | orbstack | 10 | 10 | 30.350 | 30.360 | 30.365 | 30.365 | 30.350 | 0.014 |
| idle-power-sample | conjet | 10 | 0 | 32.038 | 32.081 | 32.149 | 32.149 | 32.039 | 0.074 |
| idle-power-sample | orbstack | 10 | 0 | 32.099 | 32.113 | 32.129 | 32.129 | 32.090 | 0.039 |
| npm-install | conjet | 10 | 0 | 2.012 | 2.020 | 2.022 | 2.022 | 2.013 | 0.007 |
| npm-install | orbstack | 10 | 0 | 3.123 | 3.502 | 3.852 | 3.852 | 3.191 | 0.353 |
| pnpm-install | conjet | 10 | 0 | 3.489 | 5.432 | 7.051 | 7.051 | 4.238 | 1.340 |
| pnpm-install | orbstack | 10 | 0 | 4.753 | 5.572 | 6.783 | 6.783 | 5.204 | 0.722 |

## Results

| Trace ID | Workload | Runtime | Duration (s) | Exit | Key Metrics |
| --- | --- | ---: | ---: | ---: | --- |
| bench-idle-power-sample-conjet-1780200549312-a8f3e8a9 | idle-power-sample | conjet | 31.850 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.499, combined_power_mw_max=5223, combined_power_mw_mean=1498.767, combined_power_mw_p50=1294, combined_power_mw_p75=1600, combined_power_mw_p95=3255, combined_power_mw_p99=5223, combined_power_mw_stddev=926.947, cpu_power_mw_max=4170, cpu_power_mw_mean=1294.533, cpu_power_mw_p50=1226, cpu_power_mw_p75=1473, cpu_power_mw_p95=2761, cpu_power_mw_p99=4170, cpu_power_mw_stddev=707.490, cpu_power_watts=1.295, energy_verdict=measured, gpu_power_mw_max=1054, gpu_power_mw_mean=204.200, gpu_power_mw_p50=106, gpu_power_mw_p75=132, gpu_power_mw_p95=894, gpu_power_mw_p99=1054, gpu_power_mw_stddev=257.163, idle_power_watts=1.499, iteration=1, low_power_mode=false, matched_process_lines=5, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780200581285-288d7636 | container-start-loop | conjet | 6.858 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=7.851, combined_power_mw_max=9401, combined_power_mw_mean=7851.400, combined_power_mw_p50=8511, combined_power_mw_p75=9020, combined_power_mw_p95=9401, combined_power_mw_p99=9401, combined_power_mw_stddev=1415.594, cpu_energy_to_solution_joules_estimate=48.978, cpu_power_mw_max=9357, cpu_power_mw_mean=7431, cpu_power_mw_p50=7669, cpu_power_mw_p75=8527, cpu_power_mw_p95=9357, cpu_power_mw_p99=9357, cpu_power_mw_stddev=1439.249, cpu_power_watts=7.431, energy_to_solution_joules=51.749, energy_to_solution_joules_estimate=51.749, energy_verdict=measured, gpu_power_mw_max=841, gpu_power_mw_mean=420.200, gpu_power_mw_p50=403, gpu_power_mw_p75=494, gpu_power_mw_p95=841, gpu_power_mw_p99=841, gpu_power_mw_stddev=258.682, iteration=1, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.848, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.591, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780200588206-1cdaa1fa | hot-reload-loop | conjet | 6.470 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.433, combined_power_mw_max=5754, combined_power_mw_mean=5433.400, combined_power_mw_p50=5472, combined_power_mw_p75=5598, combined_power_mw_p95=5754, combined_power_mw_p99=5754, combined_power_mw_stddev=243.571, cpu_energy_to_solution_joules_estimate=33.329, cpu_power_mw_max=5682, cpu_power_mw_mean=5370.800, cpu_power_mw_p50=5421, cpu_power_mw_p75=5540, cpu_power_mw_p95=5682, cpu_power_mw_p99=5682, cpu_power_mw_stddev=242.704, cpu_power_watts=5.371, energy_to_solution_joules=33.718, energy_to_solution_joules_estimate=33.718, energy_verdict=measured, gpu_power_mw_max=74, gpu_power_mw_mean=62.600, gpu_power_mw_p50=60, gpu_power_mw_p75=71, gpu_power_mw_p95=74, gpu_power_mw_p99=74, gpu_power_mw_stddev=8.273, iteration=1, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.462, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.206, workload_exit_code=0 |
| bench-compose-loop-conjet-1780200594731-a7fcbb05 | compose-loop | conjet | 6.803 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=8.666, combined_power_mw_max=11348, combined_power_mw_mean=8666, combined_power_mw_p50=8769, combined_power_mw_p75=10435, combined_power_mw_p95=11348, combined_power_mw_p99=11348, combined_power_mw_stddev=2053.170, cpu_energy_to_solution_joules_estimate=55.647, cpu_power_mw_max=11246, cpu_power_mw_mean=8512, cpu_power_mw_p50=8668, cpu_power_mw_p75=10336, cpu_power_mw_p95=11246, cpu_power_mw_p99=11246, cpu_power_mw_stddev=2104.063, cpu_power_watts=8.512, energy_to_solution_joules=56.654, energy_to_solution_joules_estimate=56.654, energy_verdict=measured, gpu_power_mw_max=353, gpu_power_mw_mean=154.200, gpu_power_mw_p50=102, gpu_power_mw_p75=116, gpu_power_mw_p95=353, gpu_power_mw_p99=353, gpu_power_mw_stddev=99.580, iteration=1, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.792, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.537, workload_exit_code=0 |
| bench-npm-install-conjet-1780200601595-7abb5974 | npm-install | conjet | 2.004 | 0 | energy_verdict=measured, iteration=1, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.004, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.141, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780200603660-fa063e58 | pnpm-install | conjet | 3.488 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=7.316, combined_power_mw_max=7941, combined_power_mw_mean=7316, combined_power_mw_p50=7941, combined_power_mw_p75=7941, combined_power_mw_p95=7941, combined_power_mw_p99=7941, combined_power_mw_stddev=625, cpu_energy_to_solution_joules_estimate=20.862, cpu_power_mw_max=7135, cpu_power_mw_mean=6468, cpu_power_mw_p50=7135, cpu_power_mw_p75=7135, cpu_power_mw_p95=7135, cpu_power_mw_p99=7135, cpu_power_mw_stddev=667, cpu_power_watts=6.468, energy_to_solution_joules=23.597, energy_to_solution_joules_estimate=23.597, energy_verdict=measured, gpu_power_mw_max=891, gpu_power_mw_mean=847.750, gpu_power_mw_p50=891, gpu_power_mw_p75=891, gpu_power_mw_p95=891, gpu_power_mw_p99=891, gpu_power_mw_stddev=43.251, iteration=1, low_power_mode=false, matched_process_lines=1, power_exit_code=0, power_sample_duration_seconds=3.484, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=3.225, workload_exit_code=0 |
| bench-cargo-build-conjet-1780200607212-d759059f | cargo-build | conjet | 2.008 | 127 | energy_verdict=measured, iteration=1, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.008, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.242, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780200609285-2f69ec94 | idle-power-sample | orbstack | 31.980 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.299, combined_power_mw_max=15556, combined_power_mw_mean=3299.433, combined_power_mw_p50=1495, combined_power_mw_p75=3751, combined_power_mw_p95=15450, combined_power_mw_p99=15556, combined_power_mw_stddev=4169.808, cpu_power_mw_max=14186, cpu_power_mw_mean=2933.300, cpu_power_mw_p50=1329, cpu_power_mw_p75=3187, cpu_power_mw_p95=14119, cpu_power_mw_p99=14186, cpu_power_mw_stddev=3937.933, cpu_power_watts=2.933, energy_verdict=measured, gpu_power_mw_max=1371, gpu_power_mw_mean=366.250, gpu_power_mw_p50=327, gpu_power_mw_p75=427, gpu_power_mw_p95=1347, gpu_power_mw_p99=1371, gpu_power_mw_stddev=317.033, idle_power_watts=3.299, iteration=1, low_power_mode=false, matched_process_lines=43, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780200641396-18d522d6 | container-start-loop | orbstack | 30.352 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.618, combined_power_mw_max=10824, combined_power_mw_mean=4617.643, combined_power_mw_p50=3880, combined_power_mw_p75=6580, combined_power_mw_p95=9734, combined_power_mw_p99=10824, combined_power_mw_stddev=2821.932, cpu_energy_to_solution_joules_estimate=122.675, cpu_power_mw_max=9915, cpu_power_mw_mean=4088.357, cpu_power_mw_p50=3410, cpu_power_mw_p75=6167, cpu_power_mw_p95=8826, cpu_power_mw_p99=9915, cpu_power_mw_stddev=2599.824, cpu_power_watts=4.088, energy_to_solution_joules=138.557, energy_to_solution_joules_estimate=138.557, energy_verdict=measured, gpu_power_mw_max=1524, gpu_power_mw_mean=529.179, gpu_power_mw_p50=399, gpu_power_mw_p75=908, gpu_power_mw_p95=1470, gpu_power_mw_p99=1524, gpu_power_mw_stddev=418.516, iteration=1, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.260, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.006, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780200671812-fba6acad | hot-reload-loop | orbstack | 30.365 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.763, combined_power_mw_max=5687, combined_power_mw_mean=3763.429, combined_power_mw_p50=4238, combined_power_mw_p75=4747, combined_power_mw_p95=5424, combined_power_mw_p99=5687, combined_power_mw_stddev=1319.929, cpu_energy_to_solution_joules_estimate=109.707, cpu_power_mw_max=5275, cpu_power_mw_mean=3655.786, cpu_power_mw_p50=4201, cpu_power_mw_p75=4677, cpu_power_mw_p95=5268, cpu_power_mw_p99=5275, cpu_power_mw_stddev=1320.633, cpu_power_watts=3.656, energy_to_solution_joules=112.937, energy_to_solution_joules_estimate=112.937, energy_verdict=measured, gpu_power_mw_max=467, gpu_power_mw_mean=107.643, gpu_power_mw_p50=61, gpu_power_mw_p75=147, gpu_power_mw_p95=365, gpu_power_mw_p99=467, gpu_power_mw_stddev=117.449, iteration=1, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.273, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.009, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780200702238-1862f917 | compose-loop | orbstack | 30.369 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.791, combined_power_mw_max=5465, combined_power_mw_mean=1790.571, combined_power_mw_p50=1567, combined_power_mw_p75=2121, combined_power_mw_p95=4303, combined_power_mw_p99=5465, combined_power_mw_stddev=984.673, cpu_energy_to_solution_joules_estimate=46.064, cpu_power_mw_max=4447, cpu_power_mw_mean=1534.750, cpu_power_mw_p50=1357, cpu_power_mw_p75=1811, cpu_power_mw_p95=3222, cpu_power_mw_p99=4447, cpu_power_mw_stddev=757.853, cpu_power_watts=1.535, energy_to_solution_joules=53.743, energy_to_solution_joules_estimate=53.743, energy_verdict=measured, gpu_power_mw_max=1081, gpu_power_mw_mean=255.875, gpu_power_mw_p50=210, gpu_power_mw_p75=252, gpu_power_mw_p95=1019, gpu_power_mw_p99=1081, gpu_power_mw_stddev=258.744, iteration=1, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.274, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.014, workload_exit_code=124 |
| bench-npm-install-orbstack-1780200732670-b598c44b | npm-install | orbstack | 3.567 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.876, combined_power_mw_max=4926, combined_power_mw_mean=3875.500, combined_power_mw_p50=4926, combined_power_mw_p75=4926, combined_power_mw_p95=4926, combined_power_mw_p99=4926, combined_power_mw_stddev=1050.500, cpu_energy_to_solution_joules_estimate=10.709, cpu_power_mw_max=4220, cpu_power_mw_mean=3256, cpu_power_mw_p50=4220, cpu_power_mw_p75=4220, cpu_power_mw_p95=4220, cpu_power_mw_p99=4220, cpu_power_mw_stddev=964, cpu_power_watts=3.256, energy_to_solution_joules=12.746, energy_to_solution_joules_estimate=12.746, energy_verdict=measured, gpu_power_mw_max=706, gpu_power_mw_mean=619.500, gpu_power_mw_p50=706, gpu_power_mw_p75=706, gpu_power_mw_p95=706, gpu_power_mw_p99=706, gpu_power_mw_stddev=86.500, iteration=1, low_power_mode=false, matched_process_lines=4, power_exit_code=0, power_sample_duration_seconds=3.556, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=3.289, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780200736306-aec1a4b8 | pnpm-install | orbstack | 4.740 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.268, combined_power_mw_max=3955, combined_power_mw_mean=3268.333, combined_power_mw_p50=2988, combined_power_mw_p75=3955, combined_power_mw_p95=3955, combined_power_mw_p99=3955, combined_power_mw_stddev=488.264, cpu_energy_to_solution_joules_estimate=12.855, cpu_power_mw_max=3737, cpu_power_mw_mean=2875, cpu_power_mw_p50=2643, cpu_power_mw_p75=3737, cpu_power_mw_p95=3737, cpu_power_mw_p99=3737, cpu_power_mw_stddev=630.811, cpu_power_watts=2.875, energy_to_solution_joules=14.614, energy_to_solution_joules_estimate=14.614, energy_verdict=measured, gpu_power_mw_max=742, gpu_power_mw_mean=393, gpu_power_mw_p50=219, gpu_power_mw_p75=742, gpu_power_mw_p95=742, gpu_power_mw_p99=742, gpu_power_mw_stddev=246.781, iteration=1, low_power_mode=false, matched_process_lines=6, power_exit_code=0, power_sample_duration_seconds=4.731, power_source=ac-power, powermetrics_sample_count=3, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=4.471, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780200741110-c2a4976b | cargo-build | orbstack | 2.432 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.430, combined_power_mw_max=1430, combined_power_mw_mean=1430, combined_power_mw_p50=1430, combined_power_mw_p75=1430, combined_power_mw_p95=1430, combined_power_mw_p99=1430, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=2.642, cpu_power_mw_max=1223, cpu_power_mw_mean=1223, cpu_power_mw_p50=1223, cpu_power_mw_p75=1223, cpu_power_mw_p95=1223, cpu_power_mw_p99=1223, cpu_power_mw_stddev=0, cpu_power_watts=1.223, energy_to_solution_joules=3.089, energy_to_solution_joules_estimate=3.089, energy_verdict=measured, gpu_power_mw_max=208, gpu_power_mw_mean=207.500, gpu_power_mw_p50=208, gpu_power_mw_p75=208, gpu_power_mw_p95=208, gpu_power_mw_p99=208, gpu_power_mw_stddev=0.500, iteration=1, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.426, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.160, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780200743607-66145e85 | idle-power-sample | conjet | 32.085 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.747, combined_power_mw_max=2390, combined_power_mw_mean=747.067, combined_power_mw_p50=569, combined_power_mw_p75=943, combined_power_mw_p95=1990, combined_power_mw_p99=2390, combined_power_mw_stddev=596.631, cpu_power_mw_max=2367, cpu_power_mw_mean=671.233, cpu_power_mw_p50=509, cpu_power_mw_p75=831, cpu_power_mw_p95=1819, cpu_power_mw_p99=2367, cpu_power_mw_stddev=552.280, cpu_power_watts=0.671, energy_verdict=measured, gpu_power_mw_max=489, gpu_power_mw_mean=75.717, gpu_power_mw_p50=30, gpu_power_mw_p75=106, gpu_power_mw_p95=239, gpu_power_mw_p99=489, gpu_power_mw_stddev=101.871, idle_power_watts=0.747, iteration=2, low_power_mode=false, matched_process_lines=2, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780200775799-0d21f69e | container-start-loop | conjet | 6.298 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.813, combined_power_mw_max=5399, combined_power_mw_mean=4813.200, combined_power_mw_p50=4672, combined_power_mw_p75=4732, combined_power_mw_p95=5399, combined_power_mw_p99=5399, combined_power_mw_stddev=296.104, cpu_energy_to_solution_joules_estimate=28.925, cpu_power_mw_max=5379, cpu_power_mw_mean=4795.600, cpu_power_mw_p50=4654, cpu_power_mw_p75=4712, cpu_power_mw_p95=5379, cpu_power_mw_p99=5379, cpu_power_mw_stddev=294.741, cpu_power_watts=4.796, energy_to_solution_joules=29.031, energy_to_solution_joules_estimate=29.031, energy_verdict=measured, gpu_power_mw_max=21, gpu_power_mw_mean=18, gpu_power_mw_p50=18, gpu_power_mw_p75=20, gpu_power_mw_p95=21, gpu_power_mw_p99=21, gpu_power_mw_stddev=2.280, iteration=2, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.290, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.032, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780200782151-823563f2 | hot-reload-loop | conjet | 6.324 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.936, combined_power_mw_max=5554, combined_power_mw_mean=4936.200, combined_power_mw_p50=4828, combined_power_mw_p75=5192, combined_power_mw_p95=5554, combined_power_mw_p99=5554, combined_power_mw_stddev=400.654, cpu_energy_to_solution_joules_estimate=29.762, cpu_power_mw_max=5532, cpu_power_mw_mean=4913, cpu_power_mw_p50=4806, cpu_power_mw_p75=5162, cpu_power_mw_p95=5532, cpu_power_mw_p99=5532, cpu_power_mw_stddev=399.103, cpu_power_watts=4.913, energy_to_solution_joules=29.902, energy_to_solution_joules_estimate=29.902, energy_verdict=measured, gpu_power_mw_max=30, gpu_power_mw_mean=23.600, gpu_power_mw_p50=22, gpu_power_mw_p75=23, gpu_power_mw_p95=30, gpu_power_mw_p99=30, gpu_power_mw_stddev=3.262, iteration=2, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.315, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.058, workload_exit_code=0 |
| bench-compose-loop-conjet-1780200788527-41fd07ab | compose-loop | conjet | 6.367 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.860, combined_power_mw_max=5104, combined_power_mw_mean=4860, combined_power_mw_p50=4852, combined_power_mw_p75=4998, combined_power_mw_p95=5104, combined_power_mw_p99=5104, combined_power_mw_stddev=172.612, cpu_energy_to_solution_joules_estimate=29.513, cpu_power_mw_max=5080, cpu_power_mw_mean=4837.600, cpu_power_mw_p50=4828, cpu_power_mw_p75=4975, cpu_power_mw_p95=5080, cpu_power_mw_p99=5080, cpu_power_mw_stddev=171.274, cpu_power_watts=4.838, energy_to_solution_joules=29.650, energy_to_solution_joules_estimate=29.650, energy_verdict=measured, gpu_power_mw_max=25, gpu_power_mw_mean=22.800, gpu_power_mw_p50=23, gpu_power_mw_p75=24, gpu_power_mw_p95=25, gpu_power_mw_p99=25, gpu_power_mw_stddev=1.600, iteration=2, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.359, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.101, workload_exit_code=0 |
| bench-npm-install-conjet-1780200794946-0f460173 | npm-install | conjet | 2.003 | 0 | energy_verdict=measured, iteration=2, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.003, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.999, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780200797001-67c53d48 | pnpm-install | conjet | 5.994 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.645, combined_power_mw_max=3369, combined_power_mw_mean=1645, combined_power_mw_p50=1850, combined_power_mw_p75=3369, combined_power_mw_p95=3369, combined_power_mw_p99=3369, combined_power_mw_stddev=1135.091, cpu_energy_to_solution_joules_estimate=9.300, cpu_power_mw_max=3347, cpu_power_mw_mean=1623, cpu_power_mw_p50=1829, cpu_power_mw_p75=3347, cpu_power_mw_p95=3347, cpu_power_mw_p99=3347, cpu_power_mw_stddev=1135.266, cpu_power_watts=1.623, energy_to_solution_joules=9.426, energy_to_solution_joules_estimate=9.426, energy_verdict=measured, gpu_power_mw_max=23, gpu_power_mw_mean=22, gpu_power_mw_p50=22, gpu_power_mw_p75=23, gpu_power_mw_p95=23, gpu_power_mw_p99=23, gpu_power_mw_stddev=0.707, iteration=2, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=5.988, power_source=ac-power, powermetrics_sample_count=4, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=5.730, workload_exit_code=0 |
| bench-cargo-build-conjet-1780200803047-eff4da85 | cargo-build | conjet | 2.015 | 127 | energy_verdict=measured, iteration=2, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.015, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.227, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780200805129-0bf10d50 | idle-power-sample | orbstack | 32.108 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.455, combined_power_mw_max=1880, combined_power_mw_mean=455, combined_power_mw_p50=270, combined_power_mw_p75=628, combined_power_mw_p95=1479, combined_power_mw_p99=1880, combined_power_mw_stddev=387.844, cpu_power_mw_max=1847, cpu_power_mw_mean=434.200, cpu_power_mw_p50=250, cpu_power_mw_p75=611, cpu_power_mw_p95=1442, cpu_power_mw_p99=1847, cpu_power_mw_stddev=383.415, cpu_power_watts=0.434, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=20.567, gpu_power_mw_p50=18, gpu_power_mw_p75=22, gpu_power_mw_p95=37, gpu_power_mw_p99=37, gpu_power_mw_stddev=6.294, idle_power_watts=0.455, iteration=2, low_power_mode=false, matched_process_lines=44, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780200837342-1a24bdb8 | container-start-loop | orbstack | 30.331 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.366, combined_power_mw_max=2783, combined_power_mw_mean=1366.464, combined_power_mw_p50=1187, combined_power_mw_p75=1706, combined_power_mw_p95=2153, combined_power_mw_p99=2783, combined_power_mw_stddev=477.298, cpu_energy_to_solution_joules_estimate=40.062, cpu_power_mw_max=2661, cpu_power_mw_mean=1335.214, cpu_power_mw_p50=1168, cpu_power_mw_p75=1685, cpu_power_mw_p95=2097, cpu_power_mw_p99=2661, cpu_power_mw_stddev=460.065, cpu_power_watts=1.335, energy_to_solution_joules=41.000, energy_to_solution_joules_estimate=41.000, energy_verdict=measured, gpu_power_mw_max=121, gpu_power_mw_mean=31.107, gpu_power_mw_p50=23, gpu_power_mw_p75=31, gpu_power_mw_p95=69, gpu_power_mw_p99=121, gpu_power_mw_stddev=21.266, iteration=2, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.264, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.005, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780200867726-a2073d68 | hot-reload-loop | orbstack | 30.329 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.710, combined_power_mw_max=3825, combined_power_mw_mean=1709.964, combined_power_mw_p50=1579, combined_power_mw_p75=2157, combined_power_mw_p95=2856, combined_power_mw_p99=3825, combined_power_mw_stddev=636.376, cpu_energy_to_solution_joules_estimate=50.303, cpu_power_mw_max=3788, cpu_power_mw_mean=1676.464, cpu_power_mw_p50=1537, cpu_power_mw_p75=2131, cpu_power_mw_p95=2768, cpu_power_mw_p99=3788, cpu_power_mw_stddev=627.135, cpu_power_watts=1.676, energy_to_solution_joules=51.308, energy_to_solution_joules_estimate=51.308, energy_verdict=measured, gpu_power_mw_max=89, gpu_power_mw_mean=33.464, gpu_power_mw_p50=26, gpu_power_mw_p75=39, gpu_power_mw_p95=73, gpu_power_mw_p99=89, gpu_power_mw_stddev=16.346, iteration=2, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.263, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.006, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780200898115-6cd97635 | compose-loop | orbstack | 30.347 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.710, combined_power_mw_max=3120, combined_power_mw_mean=1710.464, combined_power_mw_p50=1576, combined_power_mw_p75=2176, combined_power_mw_p95=2852, combined_power_mw_p99=3120, combined_power_mw_stddev=660.652, cpu_energy_to_solution_joules_estimate=50.160, cpu_power_mw_max=3032, cpu_power_mw_mean=1671.536, cpu_power_mw_p50=1551, cpu_power_mw_p75=2152, cpu_power_mw_p95=2671, cpu_power_mw_p99=3032, cpu_power_mw_stddev=640.672, cpu_power_watts=1.672, energy_to_solution_joules=51.328, energy_to_solution_joules_estimate=51.328, energy_verdict=measured, gpu_power_mw_max=181, gpu_power_mw_mean=38.875, gpu_power_mw_p50=28, gpu_power_mw_p75=45, gpu_power_mw_p95=88, gpu_power_mw_p99=181, gpu_power_mw_stddev=31.416, iteration=2, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.267, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.008, workload_exit_code=124 |
| bench-npm-install-orbstack-1780200928514-8be8e520 | npm-install | orbstack | 2.653 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.679, combined_power_mw_max=2679, combined_power_mw_mean=2679, combined_power_mw_p50=2679, combined_power_mw_p75=2679, combined_power_mw_p95=2679, combined_power_mw_p99=2679, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=6.357, cpu_power_mw_max=2656, cpu_power_mw_mean=2656, cpu_power_mw_p50=2656, cpu_power_mw_p75=2656, cpu_power_mw_p95=2656, cpu_power_mw_p99=2656, cpu_power_mw_stddev=0, cpu_power_watts=2.656, energy_to_solution_joules=6.412, energy_to_solution_joules_estimate=6.412, energy_verdict=measured, gpu_power_mw_max=23, gpu_power_mw_mean=23, gpu_power_mw_p50=23, gpu_power_mw_p75=23, gpu_power_mw_p95=23, gpu_power_mw_p99=23, gpu_power_mw_stddev=0, iteration=2, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.649, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.393, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780200931231-1d51fd38 | pnpm-install | orbstack | 5.119 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.377, combined_power_mw_max=3708, combined_power_mw_mean=2377.333, combined_power_mw_p50=2039, combined_power_mw_p75=3708, combined_power_mw_p95=3708, combined_power_mw_p99=3708, combined_power_mw_stddev=978.071, cpu_energy_to_solution_joules_estimate=11.414, cpu_power_mw_max=3684, cpu_power_mw_mean=2351.667, cpu_power_mw_p50=2013, cpu_power_mw_p75=3684, cpu_power_mw_p95=3684, cpu_power_mw_p99=3684, cpu_power_mw_stddev=979.316, cpu_power_watts=2.352, energy_to_solution_joules=11.539, energy_to_solution_joules_estimate=11.539, energy_verdict=measured, gpu_power_mw_max=27, gpu_power_mw_mean=25.667, gpu_power_mw_p50=26, gpu_power_mw_p75=27, gpu_power_mw_p95=27, gpu_power_mw_p99=27, gpu_power_mw_stddev=1.247, iteration=2, low_power_mode=false, matched_process_lines=6, power_exit_code=0, power_sample_duration_seconds=5.113, power_source=ac-power, powermetrics_sample_count=3, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=4.854, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780200936408-d961bf18 | cargo-build | orbstack | 2.160 | 127 | energy_verdict=measured, iteration=2, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.160, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.901, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780200938630-cf7efe06 | idle-power-sample | conjet | 32.081 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.214, combined_power_mw_max=8529, combined_power_mw_mean=2214, combined_power_mw_p50=1031, combined_power_mw_p75=3807, combined_power_mw_p95=7993, combined_power_mw_p99=8529, combined_power_mw_stddev=2208.877, cpu_power_mw_max=8037, cpu_power_mw_mean=1988.333, cpu_power_mw_p50=1009, cpu_power_mw_p75=3482, cpu_power_mw_p95=7642, cpu_power_mw_p99=8037, cpu_power_mw_stddev=2026.766, cpu_power_watts=1.988, energy_verdict=measured, gpu_power_mw_max=830, gpu_power_mw_mean=225.617, gpu_power_mw_p50=96, gpu_power_mw_p75=401, gpu_power_mw_p95=798, gpu_power_mw_p99=830, gpu_power_mw_stddev=257.683, idle_power_watts=2.214, iteration=3, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780200970840-705d21b2 | container-start-loop | conjet | 6.702 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=6.215, combined_power_mw_max=8118, combined_power_mw_mean=6215.200, combined_power_mw_p50=5364, combined_power_mw_p75=7270, combined_power_mw_p95=8118, combined_power_mw_p99=8118, combined_power_mw_stddev=1242.583, cpu_energy_to_solution_joules_estimate=39.347, cpu_power_mw_max=7951, cpu_power_mw_mean=6116.200, cpu_power_mw_p50=5330, cpu_power_mw_p75=7044, cpu_power_mw_p95=7951, cpu_power_mw_p99=7951, cpu_power_mw_stddev=1169.711, cpu_power_watts=6.116, energy_to_solution_joules=39.984, energy_to_solution_joules_estimate=39.984, energy_verdict=measured, gpu_power_mw_max=226, gpu_power_mw_mean=98.800, gpu_power_mw_p50=35, gpu_power_mw_p75=167, gpu_power_mw_p95=226, gpu_power_mw_p99=226, gpu_power_mw_stddev=81.930, iteration=3, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.691, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.433, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780200977594-d7f05410 | hot-reload-loop | conjet | 6.367 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.219, combined_power_mw_max=6035, combined_power_mw_mean=5219.400, combined_power_mw_p50=5019, combined_power_mw_p75=5185, combined_power_mw_p95=6035, combined_power_mw_p99=6035, combined_power_mw_stddev=419.183, cpu_energy_to_solution_joules_estimate=31.637, cpu_power_mw_max=6005, cpu_power_mw_mean=5187.400, cpu_power_mw_p50=4986, cpu_power_mw_p75=5153, cpu_power_mw_p95=6005, cpu_power_mw_p99=6005, cpu_power_mw_stddev=420.101, cpu_power_watts=5.187, energy_to_solution_joules=31.832, energy_to_solution_joules_estimate=31.832, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=32.200, gpu_power_mw_p50=32, gpu_power_mw_p75=33, gpu_power_mw_p95=35, gpu_power_mw_p99=35, gpu_power_mw_stddev=1.720, iteration=3, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.357, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.099, workload_exit_code=0 |
| bench-compose-loop-conjet-1780200984011-da741f47 | compose-loop | conjet | 6.320 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.132, combined_power_mw_max=5470, combined_power_mw_mean=5132.200, combined_power_mw_p50=5090, combined_power_mw_p75=5390, combined_power_mw_p95=5470, combined_power_mw_p99=5470, combined_power_mw_stddev=259.699, cpu_energy_to_solution_joules_estimate=30.887, cpu_power_mw_max=5440, cpu_power_mw_mean=5102, cpu_power_mw_p50=5061, cpu_power_mw_p75=5359, cpu_power_mw_p95=5440, cpu_power_mw_p99=5440, cpu_power_mw_stddev=259.615, cpu_power_watts=5.102, energy_to_solution_joules=31.070, energy_to_solution_joules_estimate=31.070, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=30.400, gpu_power_mw_p50=30, gpu_power_mw_p75=31, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=1.020, iteration=3, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.311, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.054, workload_exit_code=0 |
| bench-npm-install-conjet-1780200990381-0ba38ffa | npm-install | conjet | 2.016 | 0 | energy_verdict=measured, iteration=3, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.016, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.049, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780200992472-fa567d63 | pnpm-install | conjet | 2.969 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.982, combined_power_mw_max=4982, combined_power_mw_mean=4982, combined_power_mw_p50=4982, combined_power_mw_p75=4982, combined_power_mw_p95=4982, combined_power_mw_p99=4982, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=13.404, cpu_power_mw_max=4948, cpu_power_mw_mean=4948, cpu_power_mw_p50=4948, cpu_power_mw_p75=4948, cpu_power_mw_p95=4948, cpu_power_mw_p99=4948, cpu_power_mw_stddev=0, cpu_power_watts=4.948, energy_to_solution_joules=13.497, energy_to_solution_joules_estimate=13.497, energy_verdict=measured, gpu_power_mw_max=34, gpu_power_mw_mean=34, gpu_power_mw_p50=34, gpu_power_mw_p75=34, gpu_power_mw_p95=34, gpu_power_mw_p99=34, gpu_power_mw_stddev=0, iteration=3, low_power_mode=false, matched_process_lines=1, power_exit_code=0, power_sample_duration_seconds=2.967, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.709, workload_exit_code=0 |
| bench-cargo-build-conjet-1780200995494-71e65ab2 | cargo-build | conjet | 2.020 | 127 | energy_verdict=measured, iteration=3, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.020, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.194, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780200997584-985d4d96 | idle-power-sample | orbstack | 32.083 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.541, combined_power_mw_max=1050, combined_power_mw_mean=541.067, combined_power_mw_p50=459, combined_power_mw_p75=566, combined_power_mw_p95=1018, combined_power_mw_p99=1050, combined_power_mw_stddev=233.618, cpu_power_mw_max=1025, cpu_power_mw_mean=516.133, cpu_power_mw_p50=434, cpu_power_mw_p75=542, cpu_power_mw_p95=996, cpu_power_mw_p99=1025, cpu_power_mw_stddev=233.288, cpu_power_watts=0.516, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=24.767, gpu_power_mw_p50=24, gpu_power_mw_p75=27, gpu_power_mw_p95=32, gpu_power_mw_p99=35, gpu_power_mw_stddev=3.783, idle_power_watts=0.541, iteration=3, low_power_mode=false, matched_process_lines=44, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780201029776-024f34a8 | container-start-loop | orbstack | 30.343 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.673, combined_power_mw_max=4773, combined_power_mw_mean=1673, combined_power_mw_p50=1444, combined_power_mw_p75=1917, combined_power_mw_p95=2603, combined_power_mw_p99=4773, combined_power_mw_stddev=715.988, cpu_energy_to_solution_joules_estimate=49.330, cpu_power_mw_max=4739, cpu_power_mw_mean=1643.857, cpu_power_mw_p50=1417, cpu_power_mw_p75=1888, cpu_power_mw_p95=2572, cpu_power_mw_p99=4739, cpu_power_mw_stddev=715.145, cpu_power_watts=1.644, energy_to_solution_joules=50.205, energy_to_solution_joules_estimate=50.205, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=28.964, gpu_power_mw_p50=29, gpu_power_mw_p75=30, gpu_power_mw_p95=36, gpu_power_mw_p99=37, gpu_power_mw_stddev=3.365, iteration=3, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.266, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.009, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780201060172-93a85c85 | hot-reload-loop | orbstack | 30.350 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.606, combined_power_mw_max=2391, combined_power_mw_mean=1605.714, combined_power_mw_p50=1586, combined_power_mw_p75=1872, combined_power_mw_p95=2070, combined_power_mw_p99=2391, combined_power_mw_stddev=329.359, cpu_energy_to_solution_joules_estimate=47.319, cpu_power_mw_max=2362, cpu_power_mw_mean=1576.750, cpu_power_mw_p50=1554, cpu_power_mw_p75=1840, cpu_power_mw_p95=2039, cpu_power_mw_p99=2362, cpu_power_mw_stddev=329.043, cpu_power_watts=1.577, energy_to_solution_joules=48.188, energy_to_solution_joules_estimate=48.188, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=28.786, gpu_power_mw_p50=28, gpu_power_mw_p75=30, gpu_power_mw_p95=32, gpu_power_mw_p99=33, gpu_power_mw_stddev=1.634, iteration=3, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.270, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.010, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780201090583-09312c68 | compose-loop | orbstack | 30.365 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.704, combined_power_mw_max=2582, combined_power_mw_mean=1703.679, combined_power_mw_p50=1689, combined_power_mw_p75=1997, combined_power_mw_p95=2562, combined_power_mw_p99=2582, combined_power_mw_stddev=413.220, cpu_energy_to_solution_joules_estimate=50.316, cpu_power_mw_max=2556, cpu_power_mw_mean=1675.214, cpu_power_mw_p50=1658, cpu_power_mw_p75=1971, cpu_power_mw_p95=2534, cpu_power_mw_p99=2556, cpu_power_mw_stddev=413.322, cpu_power_watts=1.675, energy_to_solution_joules=51.171, energy_to_solution_joules_estimate=51.171, energy_verdict=measured, gpu_power_mw_max=31, gpu_power_mw_mean=28.232, gpu_power_mw_p50=29, gpu_power_mw_p75=30, gpu_power_mw_p95=31, gpu_power_mw_p99=31, gpu_power_mw_stddev=2.146, iteration=3, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.295, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.036, workload_exit_code=124 |
| bench-npm-install-orbstack-1780201121004-d1d4faab | npm-install | orbstack | 3.852 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.070, combined_power_mw_max=2651, combined_power_mw_mean=2070, combined_power_mw_p50=2651, combined_power_mw_p75=2651, combined_power_mw_p95=2651, combined_power_mw_p99=2651, combined_power_mw_stddev=581, cpu_energy_to_solution_joules_estimate=7.332, cpu_power_mw_max=2623, cpu_power_mw_mean=2043.500, cpu_power_mw_p50=2623, cpu_power_mw_p75=2623, cpu_power_mw_p95=2623, cpu_power_mw_p99=2623, cpu_power_mw_stddev=579.500, cpu_power_watts=2.043, energy_to_solution_joules=7.427, energy_to_solution_joules_estimate=7.427, energy_verdict=measured, gpu_power_mw_max=28, gpu_power_mw_mean=26.500, gpu_power_mw_p50=28, gpu_power_mw_p75=28, gpu_power_mw_p95=28, gpu_power_mw_p99=28, gpu_power_mw_stddev=1.500, iteration=3, low_power_mode=false, matched_process_lines=4, power_exit_code=0, power_sample_duration_seconds=3.847, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=3.588, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780201124916-cd692272 | pnpm-install | orbstack | 4.470 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.279, combined_power_mw_max=4207, combined_power_mw_mean=3278.667, combined_power_mw_p50=3560, combined_power_mw_p75=4207, combined_power_mw_p95=4207, combined_power_mw_p99=4207, combined_power_mw_stddev=895.218, cpu_energy_to_solution_joules_estimate=13.667, cpu_power_mw_max=4179, cpu_power_mw_mean=3250.667, cpu_power_mw_p50=3534, cpu_power_mw_p75=4179, cpu_power_mw_p95=4179, cpu_power_mw_p99=4179, cpu_power_mw_stddev=896.329, cpu_power_watts=3.251, energy_to_solution_joules=13.784, energy_to_solution_joules_estimate=13.784, energy_verdict=measured, gpu_power_mw_max=31, gpu_power_mw_mean=27.667, gpu_power_mw_p50=27, gpu_power_mw_p75=31, gpu_power_mw_p95=31, gpu_power_mw_p99=31, gpu_power_mw_stddev=2.494, iteration=3, low_power_mode=false, matched_process_lines=6, power_exit_code=0, power_sample_duration_seconds=4.463, power_source=ac-power, powermetrics_sample_count=3, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=4.204, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780201129450-483a179f | cargo-build | orbstack | 2.298 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.605, combined_power_mw_max=1605, combined_power_mw_mean=1605, combined_power_mw_p50=1605, combined_power_mw_p75=1605, combined_power_mw_p95=1605, combined_power_mw_p99=1605, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=3.200, cpu_power_mw_max=1573, cpu_power_mw_mean=1573, cpu_power_mw_p50=1573, cpu_power_mw_p75=1573, cpu_power_mw_p95=1573, cpu_power_mw_p99=1573, cpu_power_mw_stddev=0, cpu_power_watts=1.573, energy_to_solution_joules=3.265, energy_to_solution_joules_estimate=3.265, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=33, gpu_power_mw_p50=33, gpu_power_mw_p75=33, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=0, iteration=3, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.294, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.034, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780201131813-a932806f | idle-power-sample | conjet | 32.012 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.565, combined_power_mw_max=1514, combined_power_mw_mean=565, combined_power_mw_p50=401, combined_power_mw_p75=515, combined_power_mw_p95=1249, combined_power_mw_p99=1514, combined_power_mw_stddev=348.679, cpu_power_mw_max=1490, cpu_power_mw_mean=541.633, cpu_power_mw_p50=378, cpu_power_mw_p75=491, cpu_power_mw_p95=1222, cpu_power_mw_p99=1490, cpu_power_mw_stddev=348.830, cpu_power_watts=0.542, energy_verdict=measured, gpu_power_mw_max=28, gpu_power_mw_mean=23.367, gpu_power_mw_p50=24, gpu_power_mw_p75=25, gpu_power_mw_p95=27, gpu_power_mw_p99=28, gpu_power_mw_stddev=2.714, idle_power_watts=0.565, iteration=4, low_power_mode=false, matched_process_lines=4, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780201163937-4103fd01 | container-start-loop | conjet | 6.415 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.976, combined_power_mw_max=6005, combined_power_mw_mean=4975.800, combined_power_mw_p50=4766, combined_power_mw_p75=4850, combined_power_mw_p95=6005, combined_power_mw_p99=6005, combined_power_mw_stddev=524.773, cpu_energy_to_solution_joules_estimate=30.446, cpu_power_mw_max=5977, cpu_power_mw_mean=4952.200, cpu_power_mw_p50=4747, cpu_power_mw_p75=4823, cpu_power_mw_p95=5977, cpu_power_mw_p99=5977, cpu_power_mw_stddev=522.496, cpu_power_watts=4.952, energy_to_solution_joules=30.591, energy_to_solution_joules_estimate=30.591, energy_verdict=measured, gpu_power_mw_max=29, gpu_power_mw_mean=24.200, gpu_power_mw_p50=25, gpu_power_mw_p75=28, gpu_power_mw_p95=29, gpu_power_mw_p99=29, gpu_power_mw_stddev=3.156, iteration=4, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.406, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.148, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780201170404-2034a3c4 | hot-reload-loop | conjet | 6.381 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.017, combined_power_mw_max=5193, combined_power_mw_mean=5016.600, combined_power_mw_p50=5011, combined_power_mw_p75=5032, combined_power_mw_p95=5193, combined_power_mw_p99=5193, combined_power_mw_stddev=98.753, cpu_energy_to_solution_joules_estimate=30.518, cpu_power_mw_max=5169, cpu_power_mw_mean=4989.800, cpu_power_mw_p50=4979, cpu_power_mw_p75=5006, cpu_power_mw_p95=5169, cpu_power_mw_p99=5169, cpu_power_mw_stddev=99.554, cpu_power_watts=4.990, energy_to_solution_joules=30.682, energy_to_solution_joules_estimate=30.682, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=27.400, gpu_power_mw_p50=26, gpu_power_mw_p75=28, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=2.498, iteration=4, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.373, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.116, workload_exit_code=0 |
| bench-compose-loop-conjet-1780201176840-1a41544c | compose-loop | conjet | 6.441 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.908, combined_power_mw_max=5519, combined_power_mw_mean=4907.600, combined_power_mw_p50=4877, combined_power_mw_p75=4979, combined_power_mw_p95=5519, combined_power_mw_p99=5519, combined_power_mw_stddev=346.655, cpu_energy_to_solution_joules_estimate=30.136, cpu_power_mw_max=5489, cpu_power_mw_mean=4880.400, cpu_power_mw_p50=4849, cpu_power_mw_p75=4951, cpu_power_mw_p95=5489, cpu_power_mw_p99=5489, cpu_power_mw_stddev=344.896, cpu_power_watts=4.880, energy_to_solution_joules=30.304, energy_to_solution_joules_estimate=30.304, energy_verdict=measured, gpu_power_mw_max=30, gpu_power_mw_mean=27.800, gpu_power_mw_p50=29, gpu_power_mw_p75=29, gpu_power_mw_p95=30, gpu_power_mw_p99=30, gpu_power_mw_stddev=1.939, iteration=4, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.433, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.175, workload_exit_code=0 |
| bench-npm-install-conjet-1780201183332-385eedf2 | npm-install | conjet | 2.008 | 0 | energy_verdict=measured, iteration=4, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.008, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.015, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780201185394-ea1e5410 | pnpm-install | conjet | 4.062 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.902, combined_power_mw_max=3776, combined_power_mw_mean=2902, combined_power_mw_p50=3776, combined_power_mw_p75=3776, combined_power_mw_p95=3776, combined_power_mw_p99=3776, combined_power_mw_stddev=874, cpu_energy_to_solution_joules_estimate=10.931, cpu_power_mw_max=3750, cpu_power_mw_mean=2876.500, cpu_power_mw_p50=3750, cpu_power_mw_p75=3750, cpu_power_mw_p95=3750, cpu_power_mw_p99=3750, cpu_power_mw_stddev=873.500, cpu_power_watts=2.877, energy_to_solution_joules=11.028, energy_to_solution_joules_estimate=11.028, energy_verdict=measured, gpu_power_mw_max=27, gpu_power_mw_mean=26.500, gpu_power_mw_p50=27, gpu_power_mw_p75=27, gpu_power_mw_p95=27, gpu_power_mw_p99=27, gpu_power_mw_stddev=0.500, iteration=4, low_power_mode=false, matched_process_lines=1, power_exit_code=0, power_sample_duration_seconds=4.058, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=3.800, workload_exit_code=0 |
| bench-cargo-build-conjet-1780201189509-92eac769 | cargo-build | conjet | 2.017 | 127 | energy_verdict=measured, iteration=4, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.016, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.203, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780201191596-591cae2f | idle-power-sample | orbstack | 32.074 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.520, combined_power_mw_max=1005, combined_power_mw_mean=519.867, combined_power_mw_p50=425, combined_power_mw_p75=611, combined_power_mw_p95=929, combined_power_mw_p99=1005, combined_power_mw_stddev=222.275, cpu_power_mw_max=978, cpu_power_mw_mean=495.333, cpu_power_mw_p50=400, cpu_power_mw_p75=586, cpu_power_mw_p95=901, cpu_power_mw_p99=978, cpu_power_mw_stddev=220.887, cpu_power_watts=0.495, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=24.500, gpu_power_mw_p50=25, gpu_power_mw_p75=26, gpu_power_mw_p95=29, gpu_power_mw_p99=32, gpu_power_mw_stddev=2.723, idle_power_watts=0.520, iteration=4, low_power_mode=false, matched_process_lines=40, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780201223777-94b28afc | container-start-loop | orbstack | 30.349 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.568, combined_power_mw_max=2316, combined_power_mw_mean=1568.393, combined_power_mw_p50=1528, combined_power_mw_p75=1808, combined_power_mw_p95=2241, combined_power_mw_p99=2316, combined_power_mw_stddev=345.164, cpu_energy_to_solution_joules_estimate=46.251, cpu_power_mw_max=2288, cpu_power_mw_mean=1541.321, cpu_power_mw_p50=1498, cpu_power_mw_p75=1782, cpu_power_mw_p95=2214, cpu_power_mw_p99=2288, cpu_power_mw_stddev=345.259, cpu_power_watts=1.541, energy_to_solution_joules=47.064, energy_to_solution_joules_estimate=47.064, energy_verdict=measured, gpu_power_mw_max=30, gpu_power_mw_mean=27.161, gpu_power_mw_p50=27, gpu_power_mw_p75=28, gpu_power_mw_p95=30, gpu_power_mw_p99=30, gpu_power_mw_stddev=1.730, iteration=4, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.274, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.008, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780201254181-2d9ce5ff | hot-reload-loop | orbstack | 30.336 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.754, combined_power_mw_max=3485, combined_power_mw_mean=1753.929, combined_power_mw_p50=1681, combined_power_mw_p75=2051, combined_power_mw_p95=2857, combined_power_mw_p99=3485, combined_power_mw_stddev=527.382, cpu_energy_to_solution_joules_estimate=51.760, cpu_power_mw_max=3456, cpu_power_mw_mean=1724.821, cpu_power_mw_p50=1654, cpu_power_mw_p75=2022, cpu_power_mw_p95=2827, cpu_power_mw_p99=3456, cpu_power_mw_stddev=527.418, cpu_power_watts=1.725, energy_to_solution_joules=52.633, energy_to_solution_joules_estimate=52.633, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=28.911, gpu_power_mw_p50=29, gpu_power_mw_p75=30, gpu_power_mw_p95=32, gpu_power_mw_p99=33, gpu_power_mw_stddev=1.796, iteration=4, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.263, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.009, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780201284574-f4659162 | compose-loop | orbstack | 30.366 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.707, combined_power_mw_max=3910, combined_power_mw_mean=1707.214, combined_power_mw_p50=1579, combined_power_mw_p75=1969, combined_power_mw_p95=2651, combined_power_mw_p99=3910, combined_power_mw_stddev=609.667, cpu_energy_to_solution_joules_estimate=50.397, cpu_power_mw_max=3883, cpu_power_mw_mean=1679.071, cpu_power_mw_p50=1552, cpu_power_mw_p75=1940, cpu_power_mw_p95=2623, cpu_power_mw_p99=3883, cpu_power_mw_stddev=610.522, cpu_power_watts=1.679, energy_to_solution_joules=51.241, energy_to_solution_joules_estimate=51.241, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=28.179, gpu_power_mw_p50=28, gpu_power_mw_p75=30, gpu_power_mw_p95=33, gpu_power_mw_p99=35, gpu_power_mw_stddev=2.687, iteration=4, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.279, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.015, workload_exit_code=124 |
| bench-npm-install-orbstack-1780201315003-e855b33a | npm-install | orbstack | 3.267 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.196, combined_power_mw_max=2912, combined_power_mw_mean=2196, combined_power_mw_p50=2912, combined_power_mw_p75=2912, combined_power_mw_p95=2912, combined_power_mw_p99=2912, combined_power_mw_stddev=716, cpu_energy_to_solution_joules_estimate=6.510, cpu_power_mw_max=2882, cpu_power_mw_mean=2168.500, cpu_power_mw_p50=2882, cpu_power_mw_p75=2882, cpu_power_mw_p95=2882, cpu_power_mw_p99=2882, cpu_power_mw_stddev=713.500, cpu_power_watts=2.168, energy_to_solution_joules=6.593, energy_to_solution_joules_estimate=6.593, energy_verdict=measured, gpu_power_mw_max=30, gpu_power_mw_mean=28.250, gpu_power_mw_p50=30, gpu_power_mw_p75=30, gpu_power_mw_p95=30, gpu_power_mw_p99=30, gpu_power_mw_stddev=1.785, iteration=4, low_power_mode=false, matched_process_lines=4, power_exit_code=0, power_sample_duration_seconds=3.260, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=3.002, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780201318336-5706c2ca | pnpm-install | orbstack | 6.007 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.130, combined_power_mw_max=3612, combined_power_mw_mean=2130, combined_power_mw_p50=2702, combined_power_mw_p75=3612, combined_power_mw_p95=3612, combined_power_mw_p99=3612, combined_power_mw_stddev=1084.309, cpu_energy_to_solution_joules_estimate=12.044, cpu_power_mw_max=3586, cpu_power_mw_mean=2101, cpu_power_mw_p50=2673, cpu_power_mw_p75=3586, cpu_power_mw_p95=3586, cpu_power_mw_p99=3586, cpu_power_mw_stddev=1085.746, cpu_power_watts=2.101, energy_to_solution_joules=12.210, energy_to_solution_joules_estimate=12.210, energy_verdict=measured, gpu_power_mw_max=34, gpu_power_mw_mean=29, gpu_power_mw_p50=29, gpu_power_mw_p75=34, gpu_power_mw_p95=34, gpu_power_mw_p99=34, gpu_power_mw_stddev=3.082, iteration=4, low_power_mode=false, matched_process_lines=8, power_exit_code=0, power_sample_duration_seconds=5.997, power_source=ac-power, powermetrics_sample_count=4, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=5.732, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780201324403-e9c0646f | cargo-build | orbstack | 2.369 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.532, combined_power_mw_max=1532, combined_power_mw_mean=1532, combined_power_mw_p50=1532, combined_power_mw_p75=1532, combined_power_mw_p95=1532, combined_power_mw_p99=1532, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=3.159, cpu_power_mw_max=1503, cpu_power_mw_mean=1503, cpu_power_mw_p50=1503, cpu_power_mw_p75=1503, cpu_power_mw_p95=1503, cpu_power_mw_p99=1503, cpu_power_mw_stddev=0, cpu_power_watts=1.503, energy_to_solution_joules=3.220, energy_to_solution_joules_estimate=3.220, energy_verdict=measured, gpu_power_mw_max=29, gpu_power_mw_mean=29, gpu_power_mw_p50=29, gpu_power_mw_p75=29, gpu_power_mw_p95=29, gpu_power_mw_p99=29, gpu_power_mw_stddev=0, iteration=4, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.365, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.102, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780201326835-001ad81a | idle-power-sample | conjet | 32.149 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.681, combined_power_mw_max=3498, combined_power_mw_mean=680.833, combined_power_mw_p50=456, combined_power_mw_p75=908, combined_power_mw_p95=1568, combined_power_mw_p99=3498, combined_power_mw_stddev=612.012, cpu_power_mw_max=3476, cpu_power_mw_mean=655.900, cpu_power_mw_p50=432, cpu_power_mw_p75=883, cpu_power_mw_p95=1544, cpu_power_mw_p99=3476, cpu_power_mw_stddev=612.118, cpu_power_watts=0.656, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=24.700, gpu_power_mw_p50=25, gpu_power_mw_p75=26, gpu_power_mw_p95=29, gpu_power_mw_p99=32, gpu_power_mw_stddev=2.635, idle_power_watts=0.681, iteration=5, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780201359087-07fe4dd9 | container-start-loop | conjet | 6.488 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.381, combined_power_mw_max=6251, combined_power_mw_mean=5381.400, combined_power_mw_p50=5121, combined_power_mw_p75=5623, combined_power_mw_p95=6251, combined_power_mw_p99=6251, combined_power_mw_stddev=499.132, cpu_energy_to_solution_joules_estimate=33.275, cpu_power_mw_max=6227, cpu_power_mw_mean=5354.600, cpu_power_mw_p50=5094, cpu_power_mw_p75=5593, cpu_power_mw_p95=6227, cpu_power_mw_p99=6227, cpu_power_mw_stddev=499.671, cpu_power_watts=5.355, energy_to_solution_joules=33.441, energy_to_solution_joules_estimate=33.441, energy_verdict=measured, gpu_power_mw_max=29, gpu_power_mw_mean=26.800, gpu_power_mw_p50=27, gpu_power_mw_p75=29, gpu_power_mw_p95=29, gpu_power_mw_p99=29, gpu_power_mw_stddev=2.040, iteration=5, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.478, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.214, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780201365632-5f0d048c | hot-reload-loop | conjet | 6.319 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.169, combined_power_mw_max=5760, combined_power_mw_mean=5169.400, combined_power_mw_p50=5015, combined_power_mw_p75=5245, combined_power_mw_p95=5760, combined_power_mw_p99=5760, combined_power_mw_stddev=319.999, cpu_energy_to_solution_joules_estimate=31.115, cpu_power_mw_max=5732, cpu_power_mw_mean=5142, cpu_power_mw_p50=4987, cpu_power_mw_p75=5217, cpu_power_mw_p95=5732, cpu_power_mw_p99=5732, cpu_power_mw_stddev=319.453, cpu_power_watts=5.142, energy_to_solution_joules=31.281, energy_to_solution_joules_estimate=31.281, energy_verdict=measured, gpu_power_mw_max=29, gpu_power_mw_mean=28, gpu_power_mw_p50=28, gpu_power_mw_p75=29, gpu_power_mw_p95=29, gpu_power_mw_p99=29, gpu_power_mw_stddev=1.095, iteration=5, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.310, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.051, workload_exit_code=0 |
| bench-compose-loop-conjet-1780201372003-b4bbe958 | compose-loop | conjet | 6.448 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.666, combined_power_mw_max=7698, combined_power_mw_mean=5665.600, combined_power_mw_p50=5115, combined_power_mw_p75=5590, combined_power_mw_p95=7698, combined_power_mw_p99=7698, combined_power_mw_stddev=1043.549, cpu_energy_to_solution_joules_estimate=34.815, cpu_power_mw_max=7671, cpu_power_mw_mean=5636.600, cpu_power_mw_p50=5083, cpu_power_mw_p75=5558, cpu_power_mw_p95=7671, cpu_power_mw_p99=7671, cpu_power_mw_stddev=1044.295, cpu_power_watts=5.637, energy_to_solution_joules=34.994, energy_to_solution_joules_estimate=34.994, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=29, gpu_power_mw_p50=30, gpu_power_mw_p75=32, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=3.098, iteration=5, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.439, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.177, workload_exit_code=0 |
| bench-npm-install-conjet-1780201378509-3a604a68 | npm-install | conjet | 2.006 | 0 | energy_verdict=measured, iteration=5, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.006, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.028, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780201380595-5c02c30d | pnpm-install | conjet | 3.489 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.151, combined_power_mw_max=4508, combined_power_mw_mean=3151.500, combined_power_mw_p50=4508, combined_power_mw_p75=4508, combined_power_mw_p95=4508, combined_power_mw_p99=4508, combined_power_mw_stddev=1356.500, cpu_energy_to_solution_joules_estimate=10.067, cpu_power_mw_max=4478, cpu_power_mw_mean=3122, cpu_power_mw_p50=4478, cpu_power_mw_p75=4478, cpu_power_mw_p95=4478, cpu_power_mw_p99=4478, cpu_power_mw_stddev=1356, cpu_power_watts=3.122, energy_to_solution_joules=10.162, energy_to_solution_joules_estimate=10.162, energy_verdict=measured, gpu_power_mw_max=31, gpu_power_mw_mean=29.500, gpu_power_mw_p50=31, gpu_power_mw_p75=31, gpu_power_mw_p95=31, gpu_power_mw_p99=31, gpu_power_mw_stddev=1.500, iteration=5, low_power_mode=false, matched_process_lines=1, power_exit_code=0, power_sample_duration_seconds=3.486, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=3.224, workload_exit_code=0 |
| bench-cargo-build-conjet-1780201384136-d9e27087 | cargo-build | conjet | 2.021 | 127 | energy_verdict=measured, iteration=5, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.021, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.215, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780201386238-c886fb7a | idle-power-sample | orbstack | 32.099 | 0 | ane_power_mw_max=1, ane_power_mw_mean=0.033, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=1, ane_power_mw_stddev=0.180, average_power_watts=0.655, combined_power_mw_max=1424, combined_power_mw_mean=655.267, combined_power_mw_p50=484, combined_power_mw_p75=993, combined_power_mw_p95=1251, combined_power_mw_p99=1424, combined_power_mw_stddev=331.011, cpu_power_mw_max=1397, cpu_power_mw_mean=630.533, cpu_power_mw_p50=463, cpu_power_mw_p75=967, cpu_power_mw_p95=1226, cpu_power_mw_p99=1397, cpu_power_mw_stddev=330.639, cpu_power_watts=0.631, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=24.717, gpu_power_mw_p50=24, gpu_power_mw_p75=26, gpu_power_mw_p95=31, gpu_power_mw_p99=32, gpu_power_mw_stddev=2.608, idle_power_watts=0.655, iteration=5, low_power_mode=false, matched_process_lines=42, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780201418449-9d068972 | container-start-loop | orbstack | 30.353 | 124 | ane_power_mw_max=1, ane_power_mw_mean=0.036, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=1, ane_power_mw_stddev=0.186, average_power_watts=1.552, combined_power_mw_max=2493, combined_power_mw_mean=1552, combined_power_mw_p50=1491, combined_power_mw_p75=1721, combined_power_mw_p95=2209, combined_power_mw_p99=2493, combined_power_mw_stddev=340.293, cpu_energy_to_solution_joules_estimate=45.744, cpu_power_mw_max=2465, cpu_power_mw_mean=1524.250, cpu_power_mw_p50=1464, cpu_power_mw_p75=1692, cpu_power_mw_p95=2181, cpu_power_mw_p99=2465, cpu_power_mw_stddev=340.301, cpu_power_watts=1.524, energy_to_solution_joules=46.577, energy_to_solution_joules_estimate=46.577, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=27.429, gpu_power_mw_p50=27, gpu_power_mw_p75=28, gpu_power_mw_p95=31, gpu_power_mw_p99=32, gpu_power_mw_stddev=1.935, iteration=5, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.270, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.011, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780201448856-f5426131 | hot-reload-loop | orbstack | 30.360 | 124 | ane_power_mw_max=1, ane_power_mw_mean=0.036, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=1, ane_power_mw_stddev=0.186, average_power_watts=1.623, combined_power_mw_max=3141, combined_power_mw_mean=1623.250, combined_power_mw_p50=1517, combined_power_mw_p75=1697, combined_power_mw_p95=2920, combined_power_mw_p99=3141, combined_power_mw_stddev=486.884, cpu_energy_to_solution_joules_estimate=47.858, cpu_power_mw_max=3112, cpu_power_mw_mean=1594.643, cpu_power_mw_p50=1489, cpu_power_mw_p75=1671, cpu_power_mw_p95=2892, cpu_power_mw_p99=3112, cpu_power_mw_stddev=486.576, cpu_power_watts=1.595, energy_to_solution_joules=48.716, energy_to_solution_joules_estimate=48.716, energy_verdict=measured, gpu_power_mw_max=34, gpu_power_mw_mean=28.571, gpu_power_mw_p50=29, gpu_power_mw_p75=29, gpu_power_mw_p95=33, gpu_power_mw_p99=34, gpu_power_mw_stddev=2.078, iteration=5, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.277, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.012, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780201479272-a3913f67 | compose-loop | orbstack | 30.356 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.026, combined_power_mw_max=4057, combined_power_mw_mean=3025.679, combined_power_mw_p50=2993, combined_power_mw_p75=3261, combined_power_mw_p95=3872, combined_power_mw_p99=4057, combined_power_mw_stddev=436.037, cpu_energy_to_solution_joules_estimate=89.846, cpu_power_mw_max=4020, cpu_power_mw_mean=2994.071, cpu_power_mw_p50=2958, cpu_power_mw_p75=3233, cpu_power_mw_p95=3839, cpu_power_mw_p99=4020, cpu_power_mw_stddev=435.440, cpu_power_watts=2.994, energy_to_solution_joules=90.795, energy_to_solution_joules_estimate=90.795, energy_verdict=measured, gpu_power_mw_max=38, gpu_power_mw_mean=31.429, gpu_power_mw_p50=31, gpu_power_mw_p75=33, gpu_power_mw_p95=37, gpu_power_mw_p99=38, gpu_power_mw_stddev=2.590, iteration=5, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.273, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.008, workload_exit_code=124 |
| bench-npm-install-orbstack-1780201509682-d151d03e | npm-install | orbstack | 3.252 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.612, combined_power_mw_max=5234, combined_power_mw_mean=4612, combined_power_mw_p50=5234, combined_power_mw_p75=5234, combined_power_mw_p95=5234, combined_power_mw_p99=5234, combined_power_mw_stddev=622, cpu_energy_to_solution_joules_estimate=13.568, cpu_power_mw_max=5197, cpu_power_mw_mean=4577.500, cpu_power_mw_p50=5197, cpu_power_mw_p75=5197, cpu_power_mw_p95=5197, cpu_power_mw_p99=5197, cpu_power_mw_stddev=619.500, cpu_power_watts=4.577, energy_to_solution_joules=13.670, energy_to_solution_joules_estimate=13.670, energy_verdict=measured, gpu_power_mw_max=36, gpu_power_mw_mean=33.500, gpu_power_mw_p50=36, gpu_power_mw_p75=36, gpu_power_mw_p95=36, gpu_power_mw_p99=36, gpu_power_mw_stddev=2.500, iteration=5, low_power_mode=false, matched_process_lines=4, power_exit_code=0, power_sample_duration_seconds=3.244, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.964, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780201512995-e4cd92fd | pnpm-install | orbstack | 4.600 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.354, combined_power_mw_max=5459, combined_power_mw_mean=4353.667, combined_power_mw_p50=4147, combined_power_mw_p75=5459, combined_power_mw_p95=5459, combined_power_mw_p99=5459, combined_power_mw_stddev=831.079, cpu_energy_to_solution_joules_estimate=18.711, cpu_power_mw_max=5428, cpu_power_mw_mean=4322.667, cpu_power_mw_p50=4116, cpu_power_mw_p75=5428, cpu_power_mw_p95=5428, cpu_power_mw_p99=5428, cpu_power_mw_stddev=831.079, cpu_power_watts=4.323, energy_to_solution_joules=18.845, energy_to_solution_joules_estimate=18.845, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=31, gpu_power_mw_p50=31, gpu_power_mw_p75=32, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=0.816, iteration=5, low_power_mode=false, matched_process_lines=6, power_exit_code=0, power_sample_duration_seconds=4.592, power_source=ac-power, powermetrics_sample_count=3, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=4.328, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780201517651-fa495c2b | cargo-build | orbstack | 2.616 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.666, combined_power_mw_max=2666, combined_power_mw_mean=2666, combined_power_mw_p50=2666, combined_power_mw_p75=2666, combined_power_mw_p95=2666, combined_power_mw_p99=2666, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=6.183, cpu_power_mw_max=2633, cpu_power_mw_mean=2633, cpu_power_mw_p50=2633, cpu_power_mw_p75=2633, cpu_power_mw_p95=2633, cpu_power_mw_p99=2633, cpu_power_mw_stddev=0, cpu_power_watts=2.633, energy_to_solution_joules=6.260, energy_to_solution_joules_estimate=6.260, energy_verdict=measured, gpu_power_mw_max=34, gpu_power_mw_mean=34, gpu_power_mw_p50=34, gpu_power_mw_p75=34, gpu_power_mw_p95=34, gpu_power_mw_p99=34, gpu_power_mw_stddev=0, iteration=5, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.612, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.348, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780201520328-c6480b78 | idle-power-sample | conjet | 32.015 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.207, combined_power_mw_max=4088, combined_power_mw_mean=2207.167, combined_power_mw_p50=2119, combined_power_mw_p75=2338, combined_power_mw_p95=3759, combined_power_mw_p99=4088, combined_power_mw_stddev=596.709, cpu_power_mw_max=4052, cpu_power_mw_mean=2175.633, cpu_power_mw_p50=2089, cpu_power_mw_p75=2308, cpu_power_mw_p95=3728, cpu_power_mw_p99=4052, cpu_power_mw_stddev=596.634, cpu_power_watts=2.176, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=31.433, gpu_power_mw_p50=31, gpu_power_mw_p75=33, gpu_power_mw_p95=36, gpu_power_mw_p99=37, gpu_power_mw_stddev=2.499, idle_power_watts=2.207, iteration=6, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780201552460-4a60c989 | container-start-loop | conjet | 6.414 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=6.743, combined_power_mw_max=7522, combined_power_mw_mean=6743.400, combined_power_mw_p50=6655, combined_power_mw_p75=6679, combined_power_mw_p95=7522, combined_power_mw_p99=7522, combined_power_mw_stddev=403.757, cpu_energy_to_solution_joules_estimate=41.232, cpu_power_mw_max=7490, cpu_power_mw_mean=6712.200, cpu_power_mw_p50=6625, cpu_power_mw_p75=6649, cpu_power_mw_p95=7490, cpu_power_mw_p99=7490, cpu_power_mw_stddev=403.606, cpu_power_watts=6.712, energy_to_solution_joules=41.424, energy_to_solution_joules_estimate=41.424, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=31.600, gpu_power_mw_p50=32, gpu_power_mw_p75=33, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=1.356, iteration=6, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.405, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.143, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780201558927-c6467772 | hot-reload-loop | conjet | 6.306 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=6.631, combined_power_mw_max=6899, combined_power_mw_mean=6630.600, combined_power_mw_p50=6592, combined_power_mw_p75=6660, combined_power_mw_p95=6899, combined_power_mw_p99=6899, combined_power_mw_stddev=148.912, cpu_energy_to_solution_joules_estimate=39.815, cpu_power_mw_max=6864, cpu_power_mw_mean=6598.400, cpu_power_mw_p50=6562, cpu_power_mw_p75=6627, cpu_power_mw_p95=6864, cpu_power_mw_p99=6864, cpu_power_mw_stddev=147.782, cpu_power_watts=6.598, energy_to_solution_joules=40.009, energy_to_solution_joules_estimate=40.009, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=32.600, gpu_power_mw_p50=33, gpu_power_mw_p75=34, gpu_power_mw_p95=35, gpu_power_mw_p99=35, gpu_power_mw_stddev=1.855, iteration=6, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.297, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.034, workload_exit_code=0 |
| bench-compose-loop-conjet-1780201565286-40205f68 | compose-loop | conjet | 6.237 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=6.804, combined_power_mw_max=7345, combined_power_mw_mean=6804, combined_power_mw_p50=6781, combined_power_mw_p75=7345, combined_power_mw_p95=7345, combined_power_mw_p99=7345, combined_power_mw_stddev=328.852, cpu_energy_to_solution_joules_estimate=40.418, cpu_power_mw_max=7313, cpu_power_mw_mean=6772.500, cpu_power_mw_p50=6751, cpu_power_mw_p75=7313, cpu_power_mw_p95=7313, cpu_power_mw_p99=7313, cpu_power_mw_stddev=329.140, cpu_power_watts=6.772, energy_to_solution_joules=40.606, energy_to_solution_joules_estimate=40.606, energy_verdict=measured, gpu_power_mw_max=36, gpu_power_mw_mean=32, gpu_power_mw_p50=32, gpu_power_mw_p75=36, gpu_power_mw_p95=36, gpu_power_mw_p99=36, gpu_power_mw_stddev=2.550, iteration=6, low_power_mode=false, matched_process_lines=4, power_exit_code=0, power_sample_duration_seconds=6.230, power_source=ac-power, powermetrics_sample_count=4, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=5.968, workload_exit_code=0 |
| bench-npm-install-conjet-1780201571576-2ccc67ca | npm-install | conjet | 2.014 | 0 | energy_verdict=measured, iteration=6, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.014, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.039, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780201573651-fe2a1065 | pnpm-install | conjet | 7.051 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.795, combined_power_mw_max=3375, combined_power_mw_mean=1794.800, combined_power_mw_p50=1528, combined_power_mw_p75=2437, combined_power_mw_p95=3375, combined_power_mw_p99=3375, combined_power_mw_stddev=992.583, cpu_energy_to_solution_joules_estimate=11.980, cpu_power_mw_max=3347, cpu_power_mw_mean=1766.200, cpu_power_mw_p50=1499, cpu_power_mw_p75=2412, cpu_power_mw_p95=3347, cpu_power_mw_p99=3347, cpu_power_mw_stddev=993.985, cpu_power_watts=1.766, energy_to_solution_joules=12.174, energy_to_solution_joules_estimate=12.174, energy_verdict=measured, gpu_power_mw_max=31, gpu_power_mw_mean=29.400, gpu_power_mw_p50=30, gpu_power_mw_p75=31, gpu_power_mw_p95=31, gpu_power_mw_p99=31, gpu_power_mw_stddev=1.625, iteration=6, low_power_mode=false, matched_process_lines=1, power_exit_code=0, power_sample_duration_seconds=7.043, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.783, workload_exit_code=0 |
| bench-cargo-build-conjet-1780201580752-8e1876ba | cargo-build | conjet | 2.020 | 127 | energy_verdict=measured, iteration=6, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.020, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.200, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780201582843-0c3431d8 | idle-power-sample | orbstack | 32.104 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.560, combined_power_mw_max=2632, combined_power_mw_mean=1559.933, combined_power_mw_p50=1538, combined_power_mw_p75=1949, combined_power_mw_p95=2600, combined_power_mw_p99=2632, combined_power_mw_stddev=533.828, cpu_power_mw_max=2600, cpu_power_mw_mean=1532.067, cpu_power_mw_p50=1508, cpu_power_mw_p75=1919, cpu_power_mw_p95=2568, cpu_power_mw_p99=2600, cpu_power_mw_stddev=532.486, cpu_power_watts=1.532, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=27.850, gpu_power_mw_p50=28, gpu_power_mw_p75=30, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=3.043, idle_power_watts=1.560, iteration=6, low_power_mode=false, matched_process_lines=43, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780201615067-024d7960 | container-start-loop | orbstack | 30.359 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.753, combined_power_mw_max=4289, combined_power_mw_mean=2753.143, combined_power_mw_p50=2693, combined_power_mw_p75=3086, combined_power_mw_p95=3894, combined_power_mw_p99=4289, combined_power_mw_stddev=587.979, cpu_energy_to_solution_joules_estimate=81.647, cpu_power_mw_max=4251, cpu_power_mw_mean=2720, cpu_power_mw_p50=2660, cpu_power_mw_p75=3055, cpu_power_mw_p95=3862, cpu_power_mw_p99=4251, cpu_power_mw_stddev=586.664, cpu_power_watts=2.720, energy_to_solution_joules=82.642, energy_to_solution_joules_estimate=82.642, energy_verdict=measured, gpu_power_mw_max=39, gpu_power_mw_mean=33.054, gpu_power_mw_p50=33, gpu_power_mw_p75=35, gpu_power_mw_p95=38, gpu_power_mw_p99=39, gpu_power_mw_stddev=2.695, iteration=6, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.279, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.017, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780201645481-43863fe8 | hot-reload-loop | orbstack | 30.364 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.835, combined_power_mw_max=4053, combined_power_mw_mean=2834.821, combined_power_mw_p50=2947, combined_power_mw_p75=3246, combined_power_mw_p95=4003, combined_power_mw_p99=4053, combined_power_mw_stddev=682.036, cpu_energy_to_solution_joules_estimate=84.062, cpu_power_mw_max=4019, cpu_power_mw_mean=2800.393, cpu_power_mw_p50=2912, cpu_power_mw_p75=3212, cpu_power_mw_p95=3969, cpu_power_mw_p99=4019, cpu_power_mw_stddev=682.576, cpu_power_watts=2.800, energy_to_solution_joules=85.096, energy_to_solution_joules_estimate=85.096, energy_verdict=measured, gpu_power_mw_max=41, gpu_power_mw_mean=34.250, gpu_power_mw_p50=34, gpu_power_mw_p75=36, gpu_power_mw_p95=38, gpu_power_mw_p99=41, gpu_power_mw_stddev=2.654, iteration=6, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.283, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.018, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780201675901-fdedf9fb | compose-loop | orbstack | 30.334 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.790, combined_power_mw_max=2807, combined_power_mw_mean=1789.857, combined_power_mw_p50=1762, combined_power_mw_p75=2132, combined_power_mw_p95=2613, combined_power_mw_p99=2807, combined_power_mw_stddev=460.618, cpu_energy_to_solution_joules_estimate=52.789, cpu_power_mw_max=2777, cpu_power_mw_mean=1758.929, cpu_power_mw_p50=1734, cpu_power_mw_p75=2102, cpu_power_mw_p95=2582, cpu_power_mw_p99=2777, cpu_power_mw_stddev=460.369, cpu_power_watts=1.759, energy_to_solution_joules=53.717, energy_to_solution_joules_estimate=53.717, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=30.786, gpu_power_mw_p50=30, gpu_power_mw_p75=32, gpu_power_mw_p95=36, gpu_power_mw_p99=37, gpu_power_mw_stddev=2.820, iteration=6, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.266, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.012, workload_exit_code=124 |
| bench-npm-install-orbstack-1780201706292-09041831 | npm-install | orbstack | 3.123 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.855, combined_power_mw_max=3855, combined_power_mw_mean=3855, combined_power_mw_p50=3855, combined_power_mw_p75=3855, combined_power_mw_p95=3855, combined_power_mw_p99=3855, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=10.910, cpu_power_mw_max=3822, cpu_power_mw_mean=3822, cpu_power_mw_p50=3822, cpu_power_mw_p75=3822, cpu_power_mw_p95=3822, cpu_power_mw_p99=3822, cpu_power_mw_stddev=0, cpu_power_watts=3.822, energy_to_solution_joules=11.004, energy_to_solution_joules_estimate=11.004, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=32, gpu_power_mw_p50=32, gpu_power_mw_p75=32, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=0, iteration=6, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=3.119, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.854, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780201709482-0d779351 | pnpm-install | orbstack | 5.516 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.255, combined_power_mw_max=4817, combined_power_mw_mean=3255, combined_power_mw_p50=3162, combined_power_mw_p75=4817, combined_power_mw_p95=4817, combined_power_mw_p99=4817, combined_power_mw_stddev=1008.627, cpu_energy_to_solution_joules_estimate=16.872, cpu_power_mw_max=4786, cpu_power_mw_mean=3219, cpu_power_mw_p50=3122, cpu_power_mw_p75=4786, cpu_power_mw_p95=4786, cpu_power_mw_p99=4786, cpu_power_mw_stddev=1010.454, cpu_power_watts=3.219, energy_to_solution_joules=17.061, energy_to_solution_joules_estimate=17.061, energy_verdict=measured, gpu_power_mw_max=41, gpu_power_mw_mean=35.875, gpu_power_mw_p50=38, gpu_power_mw_p75=40, gpu_power_mw_p95=41, gpu_power_mw_p99=41, gpu_power_mw_stddev=3.655, iteration=6, low_power_mode=false, matched_process_lines=8, power_exit_code=0, power_sample_duration_seconds=5.503, power_source=ac-power, powermetrics_sample_count=4, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=5.241, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780201715058-36a33c40 | cargo-build | orbstack | 2.102 | 127 | energy_verdict=measured, iteration=6, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.102, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.839, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780201717222-83d20790 | idle-power-sample | conjet | 32.076 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.924, combined_power_mw_max=1618, combined_power_mw_mean=923.800, combined_power_mw_p50=810, combined_power_mw_p75=965, combined_power_mw_p95=1551, combined_power_mw_p99=1618, combined_power_mw_stddev=308.397, cpu_power_mw_max=1588, cpu_power_mw_mean=893.867, cpu_power_mw_p50=778, cpu_power_mw_p75=933, cpu_power_mw_p95=1527, cpu_power_mw_p99=1588, cpu_power_mw_stddev=308.698, cpu_power_watts=0.894, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=29.933, gpu_power_mw_p50=30, gpu_power_mw_p75=32, gpu_power_mw_p95=33, gpu_power_mw_p99=35, gpu_power_mw_stddev=2.250, idle_power_watts=0.924, iteration=7, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780201749412-cdb537d8 | container-start-loop | conjet | 6.560 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.552, combined_power_mw_max=5914, combined_power_mw_mean=5552.200, combined_power_mw_p50=5508, combined_power_mw_p75=5571, combined_power_mw_p95=5914, combined_power_mw_p99=5914, combined_power_mw_stddev=196.081, cpu_energy_to_solution_joules_estimate=34.759, cpu_power_mw_max=5882, cpu_power_mw_mean=5521.600, cpu_power_mw_p50=5477, cpu_power_mw_p75=5539, cpu_power_mw_p95=5882, cpu_power_mw_p99=5882, cpu_power_mw_stddev=195.156, cpu_power_watts=5.522, energy_to_solution_joules=34.952, energy_to_solution_joules_estimate=34.952, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=31, gpu_power_mw_p50=32, gpu_power_mw_p75=32, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=2, iteration=7, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.551, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.295, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780201756027-0ac52f00 | hot-reload-loop | conjet | 6.399 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.607, combined_power_mw_max=6110, combined_power_mw_mean=5606.800, combined_power_mw_p50=5520, combined_power_mw_p75=5541, combined_power_mw_p95=6110, combined_power_mw_p99=6110, combined_power_mw_stddev=257.619, cpu_energy_to_solution_joules_estimate=34.197, cpu_power_mw_max=6076, cpu_power_mw_mean=5572.600, cpu_power_mw_p50=5484, cpu_power_mw_p75=5506, cpu_power_mw_p95=6076, cpu_power_mw_p99=6076, cpu_power_mw_stddev=257.699, cpu_power_watts=5.573, energy_to_solution_joules=34.407, energy_to_solution_joules_estimate=34.407, energy_verdict=measured, gpu_power_mw_max=36, gpu_power_mw_mean=34.200, gpu_power_mw_p50=35, gpu_power_mw_p75=35, gpu_power_mw_p95=36, gpu_power_mw_p99=36, gpu_power_mw_stddev=1.470, iteration=7, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.390, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.137, workload_exit_code=0 |
| bench-compose-loop-conjet-1780201762478-c2f627f3 | compose-loop | conjet | 6.427 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.464, combined_power_mw_max=6235, combined_power_mw_mean=5463.600, combined_power_mw_p50=5284, combined_power_mw_p75=5605, combined_power_mw_p95=6235, combined_power_mw_p99=6235, combined_power_mw_stddev=429.117, cpu_energy_to_solution_joules_estimate=33.407, cpu_power_mw_max=6199, cpu_power_mw_mean=5427.200, cpu_power_mw_p50=5248, cpu_power_mw_p75=5569, cpu_power_mw_p95=6199, cpu_power_mw_p99=6199, cpu_power_mw_stddev=429.504, cpu_power_watts=5.427, energy_to_solution_joules=33.631, energy_to_solution_joules_estimate=33.631, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=36, gpu_power_mw_p50=36, gpu_power_mw_p75=36, gpu_power_mw_p95=37, gpu_power_mw_p99=37, gpu_power_mw_stddev=0.632, iteration=7, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.418, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.155, workload_exit_code=0 |
| bench-npm-install-conjet-1780201768957-ff08b37b | npm-install | conjet | 2.022 | 0 | energy_verdict=measured, iteration=7, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.021, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.170, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780201771052-a4415514 | pnpm-install | conjet | 3.134 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.022, combined_power_mw_max=4022, combined_power_mw_mean=4022, combined_power_mw_p50=4022, combined_power_mw_p75=4022, combined_power_mw_p95=4022, combined_power_mw_p99=4022, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=11.449, cpu_power_mw_max=3990, cpu_power_mw_mean=3990, cpu_power_mw_p50=3990, cpu_power_mw_p75=3990, cpu_power_mw_p95=3990, cpu_power_mw_p99=3990, cpu_power_mw_stddev=0, cpu_power_watts=3.990, energy_to_solution_joules=11.541, energy_to_solution_joules_estimate=11.541, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=32, gpu_power_mw_p50=32, gpu_power_mw_p75=32, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=0, iteration=7, low_power_mode=false, matched_process_lines=1, power_exit_code=0, power_sample_duration_seconds=3.133, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.870, workload_exit_code=0 |
| bench-cargo-build-conjet-1780201774239-6503d925 | cargo-build | conjet | 2.021 | 127 | energy_verdict=measured, iteration=7, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.020, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.224, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780201776332-414eb500 | idle-power-sample | orbstack | 32.113 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.834, combined_power_mw_max=1507, combined_power_mw_mean=833.933, combined_power_mw_p50=773, combined_power_mw_p75=1163, combined_power_mw_p95=1425, combined_power_mw_p99=1507, combined_power_mw_stddev=314.692, cpu_power_mw_max=1478, cpu_power_mw_mean=805.067, cpu_power_mw_p50=745, cpu_power_mw_p75=1136, cpu_power_mw_p95=1394, cpu_power_mw_p99=1478, cpu_power_mw_stddev=315.806, cpu_power_watts=0.805, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=28.967, gpu_power_mw_p50=29, gpu_power_mw_p75=31, gpu_power_mw_p95=33, gpu_power_mw_p99=35, gpu_power_mw_stddev=2.595, idle_power_watts=0.834, iteration=7, low_power_mode=false, matched_process_lines=42, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780201808559-3595f860 | container-start-loop | orbstack | 30.334 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.723, combined_power_mw_max=2706, combined_power_mw_mean=1723.036, combined_power_mw_p50=1700, combined_power_mw_p75=1983, combined_power_mw_p95=2560, combined_power_mw_p99=2706, combined_power_mw_stddev=427.022, cpu_energy_to_solution_joules_estimate=50.786, cpu_power_mw_max=2675, cpu_power_mw_mean=1692.679, cpu_power_mw_p50=1667, cpu_power_mw_p75=1951, cpu_power_mw_p95=2535, cpu_power_mw_p99=2675, cpu_power_mw_stddev=427.225, cpu_power_watts=1.693, energy_to_solution_joules=51.697, energy_to_solution_joules_estimate=51.697, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=30.232, gpu_power_mw_p50=31, gpu_power_mw_p75=32, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=2.283, iteration=7, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.267, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.003, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780201838981-42615143 | hot-reload-loop | orbstack | 30.348 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.868, combined_power_mw_max=2634, combined_power_mw_mean=1867.571, combined_power_mw_p50=1814, combined_power_mw_p75=2084, combined_power_mw_p95=2552, combined_power_mw_p99=2634, combined_power_mw_stddev=347.866, cpu_energy_to_solution_joules_estimate=55.092, cpu_power_mw_max=2602, cpu_power_mw_mean=1835.714, cpu_power_mw_p50=1783, cpu_power_mw_p75=2052, cpu_power_mw_p95=2519, cpu_power_mw_p99=2602, cpu_power_mw_stddev=347.636, cpu_power_watts=1.836, energy_to_solution_joules=56.048, energy_to_solution_joules_estimate=56.048, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=31.643, gpu_power_mw_p50=32, gpu_power_mw_p75=33, gpu_power_mw_p95=34, gpu_power_mw_p99=35, gpu_power_mw_stddev=1.663, iteration=7, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.267, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.011, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780201869386-ab64d846 | compose-loop | orbstack | 30.372 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.841, combined_power_mw_max=2505, combined_power_mw_mean=1840.500, combined_power_mw_p50=1780, combined_power_mw_p75=2048, combined_power_mw_p95=2431, combined_power_mw_p99=2505, combined_power_mw_stddev=310.611, cpu_energy_to_solution_joules_estimate=54.271, cpu_power_mw_max=2471, cpu_power_mw_mean=1807.821, cpu_power_mw_p50=1748, cpu_power_mw_p75=2015, cpu_power_mw_p95=2399, cpu_power_mw_p99=2471, cpu_power_mw_stddev=310.278, cpu_power_watts=1.808, energy_to_solution_joules=55.252, energy_to_solution_joules_estimate=55.252, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=32.482, gpu_power_mw_p50=32, gpu_power_mw_p75=34, gpu_power_mw_p95=37, gpu_power_mw_p99=37, gpu_power_mw_stddev=2.493, iteration=7, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.289, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.020, workload_exit_code=124 |
| bench-npm-install-orbstack-1780201899815-1026645c | npm-install | orbstack | 3.502 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.722, combined_power_mw_max=3945, combined_power_mw_mean=2722, combined_power_mw_p50=3945, combined_power_mw_p75=3945, combined_power_mw_p95=3945, combined_power_mw_p99=3945, combined_power_mw_stddev=1223, cpu_energy_to_solution_joules_estimate=8.704, cpu_power_mw_max=3909, cpu_power_mw_mean=2686, cpu_power_mw_p50=3909, cpu_power_mw_p75=3909, cpu_power_mw_p95=3909, cpu_power_mw_p99=3909, cpu_power_mw_stddev=1223, cpu_power_watts=2.686, energy_to_solution_joules=8.820, energy_to_solution_joules_estimate=8.820, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=36, gpu_power_mw_p50=37, gpu_power_mw_p75=37, gpu_power_mw_p95=37, gpu_power_mw_p99=37, gpu_power_mw_stddev=1, iteration=7, low_power_mode=false, matched_process_lines=4, power_exit_code=0, power_sample_duration_seconds=3.496, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=3.240, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780201903376-61db7ca4 | pnpm-install | orbstack | 4.753 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.390, combined_power_mw_max=4661, combined_power_mw_mean=3390, combined_power_mw_p50=2909, combined_power_mw_p75=4661, combined_power_mw_p95=4661, combined_power_mw_p99=4661, combined_power_mw_stddev=907.543, cpu_energy_to_solution_joules_estimate=15.048, cpu_power_mw_max=4628, cpu_power_mw_mean=3358.333, cpu_power_mw_p50=2878, cpu_power_mw_p75=4628, cpu_power_mw_p95=4628, cpu_power_mw_p99=4628, cpu_power_mw_stddev=906.609, cpu_power_watts=3.358, energy_to_solution_joules=15.190, energy_to_solution_joules_estimate=15.190, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=31.667, gpu_power_mw_p50=31, gpu_power_mw_p75=33, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=0.943, iteration=7, low_power_mode=false, matched_process_lines=6, power_exit_code=0, power_sample_duration_seconds=4.744, power_source=ac-power, powermetrics_sample_count=3, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=4.481, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780201908194-520cea6a | cargo-build | orbstack | 2.293 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.853, combined_power_mw_max=1853, combined_power_mw_mean=1853, combined_power_mw_p50=1853, combined_power_mw_p75=1853, combined_power_mw_p95=1853, combined_power_mw_p99=1853, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=3.697, cpu_power_mw_max=1817, cpu_power_mw_mean=1817, cpu_power_mw_p50=1817, cpu_power_mw_p75=1817, cpu_power_mw_p95=1817, cpu_power_mw_p99=1817, cpu_power_mw_stddev=0, cpu_power_watts=1.817, energy_to_solution_joules=3.771, energy_to_solution_joules_estimate=3.771, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=35, gpu_power_mw_p50=35, gpu_power_mw_p75=35, gpu_power_mw_p95=35, gpu_power_mw_p99=35, gpu_power_mw_stddev=0, iteration=7, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.289, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.035, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780201910547-b3768c77 | idle-power-sample | conjet | 32.038 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.073, combined_power_mw_max=3362, combined_power_mw_mean=1073.367, combined_power_mw_p50=857, combined_power_mw_p75=1226, combined_power_mw_p95=2723, combined_power_mw_p99=3362, combined_power_mw_stddev=641.128, cpu_power_mw_max=3327, cpu_power_mw_mean=1042.933, cpu_power_mw_p50=829, cpu_power_mw_p75=1194, cpu_power_mw_p95=2687, cpu_power_mw_p99=3327, cpu_power_mw_stddev=639.601, cpu_power_watts=1.043, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=30.417, gpu_power_mw_p50=30, gpu_power_mw_p75=33, gpu_power_mw_p95=37, gpu_power_mw_p99=37, gpu_power_mw_stddev=3.232, idle_power_watts=1.073, iteration=8, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780201942714-8def1046 | container-start-loop | conjet | 6.470 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.296, combined_power_mw_max=6004, combined_power_mw_mean=5296.200, combined_power_mw_p50=5123, combined_power_mw_p75=5534, combined_power_mw_p95=6004, combined_power_mw_p99=6004, combined_power_mw_stddev=421.872, cpu_energy_to_solution_joules_estimate=32.669, cpu_power_mw_max=5974, cpu_power_mw_mean=5267.200, cpu_power_mw_p50=5093, cpu_power_mw_p75=5502, cpu_power_mw_p95=5974, cpu_power_mw_p99=5974, cpu_power_mw_stddev=420.304, cpu_power_watts=5.267, energy_to_solution_joules=32.849, energy_to_solution_joules_estimate=32.849, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=29.800, gpu_power_mw_p50=31, gpu_power_mw_p75=31, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=2.135, iteration=8, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.461, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.202, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780201949237-c339be60 | hot-reload-loop | conjet | 6.457 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.739, combined_power_mw_max=6296, combined_power_mw_mean=5739.400, combined_power_mw_p50=5801, combined_power_mw_p75=6160, combined_power_mw_p95=6296, combined_power_mw_p99=6296, combined_power_mw_stddev=459.675, cpu_energy_to_solution_joules_estimate=35.336, cpu_power_mw_max=6261, cpu_power_mw_mean=5705.800, cpu_power_mw_p50=5767, cpu_power_mw_p75=6127, cpu_power_mw_p95=6261, cpu_power_mw_p99=6261, cpu_power_mw_stddev=459.064, cpu_power_watts=5.706, energy_to_solution_joules=35.544, energy_to_solution_joules_estimate=35.544, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=33.400, gpu_power_mw_p50=34, gpu_power_mw_p75=34, gpu_power_mw_p95=35, gpu_power_mw_p99=35, gpu_power_mw_stddev=1.356, iteration=8, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.447, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.193, workload_exit_code=0 |
| bench-compose-loop-conjet-1780201955748-d890dd77 | compose-loop | conjet | 6.415 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.224, combined_power_mw_max=6039, combined_power_mw_mean=5224.400, combined_power_mw_p50=5096, combined_power_mw_p75=5124, combined_power_mw_p95=6039, combined_power_mw_p99=6039, combined_power_mw_stddev=415.219, cpu_energy_to_solution_joules_estimate=31.940, cpu_power_mw_max=6006, cpu_power_mw_mean=5191.400, cpu_power_mw_p50=5066, cpu_power_mw_p75=5091, cpu_power_mw_p95=6006, cpu_power_mw_p99=6006, cpu_power_mw_stddev=415.479, cpu_power_watts=5.191, energy_to_solution_joules=32.143, energy_to_solution_joules_estimate=32.143, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=33.200, gpu_power_mw_p50=34, gpu_power_mw_p75=34, gpu_power_mw_p95=35, gpu_power_mw_p99=35, gpu_power_mw_stddev=1.720, iteration=8, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.406, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.152, workload_exit_code=0 |
| bench-npm-install-conjet-1780201962217-58c9c4fa | npm-install | conjet | 2.021 | 0 | energy_verdict=measured, iteration=8, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.021, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.019, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780201964310-7cf01fd8 | pnpm-install | conjet | 3.587 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.143, combined_power_mw_max=3953, combined_power_mw_mean=3142.500, combined_power_mw_p50=3953, combined_power_mw_p75=3953, combined_power_mw_p95=3953, combined_power_mw_p99=3953, combined_power_mw_stddev=810.500, cpu_energy_to_solution_joules_estimate=10.331, cpu_power_mw_max=3920, cpu_power_mw_mean=3111.500, cpu_power_mw_p50=3920, cpu_power_mw_p75=3920, cpu_power_mw_p95=3920, cpu_power_mw_p99=3920, cpu_power_mw_stddev=808.500, cpu_power_watts=3.111, energy_to_solution_joules=10.434, energy_to_solution_joules_estimate=10.434, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=30.500, gpu_power_mw_p50=32, gpu_power_mw_p75=32, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=1.500, iteration=8, low_power_mode=false, matched_process_lines=1, power_exit_code=0, power_sample_duration_seconds=3.583, power_source=ac-power, powermetrics_sample_count=2, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=3.320, workload_exit_code=0 |
| bench-cargo-build-conjet-1780201967948-c8e38221 | cargo-build | conjet | 2.012 | 127 | energy_verdict=measured, iteration=8, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.011, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.205, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780201970010-e0d38e1c | idle-power-sample | orbstack | 32.114 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.714, combined_power_mw_max=1272, combined_power_mw_mean=714.067, combined_power_mw_p50=588, combined_power_mw_p75=904, combined_power_mw_p95=1261, combined_power_mw_p99=1272, combined_power_mw_stddev=262.565, cpu_power_mw_max=1245, cpu_power_mw_mean=686.433, cpu_power_mw_p50=560, cpu_power_mw_p75=872, cpu_power_mw_p95=1235, cpu_power_mw_p99=1245, cpu_power_mw_stddev=262.782, cpu_power_watts=0.686, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=27.633, gpu_power_mw_p50=27, gpu_power_mw_p75=29, gpu_power_mw_p95=31, gpu_power_mw_p99=33, gpu_power_mw_stddev=1.879, idle_power_watts=0.714, iteration=8, low_power_mode=false, matched_process_lines=44, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780202002236-3f027412 | container-start-loop | orbstack | 30.353 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.696, combined_power_mw_max=2771, combined_power_mw_mean=1696.429, combined_power_mw_p50=1651, combined_power_mw_p75=1853, combined_power_mw_p95=2537, combined_power_mw_p99=2771, combined_power_mw_stddev=383.920, cpu_energy_to_solution_joules_estimate=50.026, cpu_power_mw_max=2739, cpu_power_mw_mean=1666.821, cpu_power_mw_p50=1620, cpu_power_mw_p75=1823, cpu_power_mw_p95=2510, cpu_power_mw_p99=2739, cpu_power_mw_stddev=383.751, cpu_power_watts=1.667, energy_to_solution_joules=50.915, energy_to_solution_joules_estimate=50.915, energy_verdict=measured, gpu_power_mw_max=35, gpu_power_mw_mean=29.446, gpu_power_mw_p50=29, gpu_power_mw_p75=31, gpu_power_mw_p95=33, gpu_power_mw_p99=35, gpu_power_mw_stddev=2.442, iteration=8, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.279, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.013, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780202032639-ad40b5af | hot-reload-loop | orbstack | 30.325 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.753, combined_power_mw_max=3883, combined_power_mw_mean=1752.750, combined_power_mw_p50=1603, combined_power_mw_p75=2083, combined_power_mw_p95=2495, combined_power_mw_p99=3883, combined_power_mw_stddev=537.442, cpu_energy_to_solution_joules_estimate=51.699, cpu_power_mw_max=3851, cpu_power_mw_mean=1722.821, cpu_power_mw_p50=1574, cpu_power_mw_p75=2052, cpu_power_mw_p95=2466, cpu_power_mw_p99=3851, cpu_power_mw_stddev=537.202, cpu_power_watts=1.723, energy_to_solution_joules=52.597, energy_to_solution_joules_estimate=52.597, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=29.964, gpu_power_mw_p50=30, gpu_power_mw_p75=32, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=1.955, iteration=8, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.262, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.008, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780202063019-61170547 | compose-loop | orbstack | 30.339 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.583, combined_power_mw_max=2127, combined_power_mw_mean=1582.571, combined_power_mw_p50=1515, combined_power_mw_p75=1907, combined_power_mw_p95=2094, combined_power_mw_p99=2127, combined_power_mw_stddev=298.182, cpu_energy_to_solution_joules_estimate=46.606, cpu_power_mw_max=2098, cpu_power_mw_mean=1553, cpu_power_mw_p50=1484, cpu_power_mw_p75=1874, cpu_power_mw_p95=2064, cpu_power_mw_p99=2098, cpu_power_mw_stddev=297.120, cpu_power_watts=1.553, energy_to_solution_joules=47.493, energy_to_solution_joules_estimate=47.493, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=29.500, gpu_power_mw_p50=30, gpu_power_mw_p75=31, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=2.018, iteration=8, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.265, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.010, workload_exit_code=124 |
| bench-npm-install-orbstack-1780202093412-c937d057 | npm-install | orbstack | 2.964 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.046, combined_power_mw_max=3046, combined_power_mw_mean=3046, combined_power_mw_p50=3046, combined_power_mw_p75=3046, combined_power_mw_p95=3046, combined_power_mw_p99=3046, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=8.154, cpu_power_mw_max=3017, cpu_power_mw_mean=3017, cpu_power_mw_p50=3017, cpu_power_mw_p75=3017, cpu_power_mw_p95=3017, cpu_power_mw_p99=3017, cpu_power_mw_stddev=0, cpu_power_watts=3.017, energy_to_solution_joules=8.232, energy_to_solution_joules_estimate=8.232, energy_verdict=measured, gpu_power_mw_max=29, gpu_power_mw_mean=29, gpu_power_mw_p50=29, gpu_power_mw_p75=29, gpu_power_mw_p95=29, gpu_power_mw_p99=29, gpu_power_mw_stddev=0, iteration=8, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.960, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.703, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780202096445-af68bbb1 | pnpm-install | orbstack | 4.483 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.343, combined_power_mw_max=4125, combined_power_mw_mean=3343, combined_power_mw_p50=3098, combined_power_mw_p75=4125, combined_power_mw_p95=4125, combined_power_mw_p99=4125, combined_power_mw_stddev=565.661, cpu_energy_to_solution_joules_estimate=13.957, cpu_power_mw_max=4095, cpu_power_mw_mean=3313.333, cpu_power_mw_p50=3069, cpu_power_mw_p75=4095, cpu_power_mw_p95=4095, cpu_power_mw_p99=4095, cpu_power_mw_stddev=565.517, cpu_power_watts=3.313, energy_to_solution_joules=14.082, energy_to_solution_joules_estimate=14.082, energy_verdict=measured, gpu_power_mw_max=30, gpu_power_mw_mean=29.667, gpu_power_mw_p50=30, gpu_power_mw_p75=30, gpu_power_mw_p95=30, gpu_power_mw_p99=30, gpu_power_mw_stddev=0.471, iteration=8, low_power_mode=false, matched_process_lines=6, power_exit_code=0, power_sample_duration_seconds=4.476, power_source=ac-power, powermetrics_sample_count=3, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=4.212, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780202100986-78366042 | cargo-build | orbstack | 2.371 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.796, combined_power_mw_max=1796, combined_power_mw_mean=1796, combined_power_mw_p50=1796, combined_power_mw_p75=1796, combined_power_mw_p95=1796, combined_power_mw_p99=1796, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=3.721, cpu_power_mw_max=1768, cpu_power_mw_mean=1768, cpu_power_mw_p50=1768, cpu_power_mw_p75=1768, cpu_power_mw_p95=1768, cpu_power_mw_p99=1768, cpu_power_mw_stddev=0, cpu_power_watts=1.768, energy_to_solution_joules=3.780, energy_to_solution_joules_estimate=3.780, energy_verdict=measured, gpu_power_mw_max=29, gpu_power_mw_mean=29, gpu_power_mw_p50=29, gpu_power_mw_p75=29, gpu_power_mw_p95=29, gpu_power_mw_p99=29, gpu_power_mw_stddev=0, iteration=8, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.368, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.105, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780202103415-abb849ea | idle-power-sample | conjet | 32.026 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.657, combined_power_mw_max=1658, combined_power_mw_mean=656.833, combined_power_mw_p50=516, combined_power_mw_p75=633, combined_power_mw_p95=1438, combined_power_mw_p99=1658, combined_power_mw_stddev=321.782, cpu_power_mw_max=1632, cpu_power_mw_mean=629.867, cpu_power_mw_p50=489, cpu_power_mw_p75=602, cpu_power_mw_p95=1408, cpu_power_mw_p99=1632, cpu_power_mw_stddev=321.910, cpu_power_watts=0.630, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=26.883, gpu_power_mw_p50=26, gpu_power_mw_p75=28, gpu_power_mw_p95=31, gpu_power_mw_p99=33, gpu_power_mw_stddev=2.296, idle_power_watts=0.657, iteration=9, low_power_mode=false, matched_process_lines=2, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780202135546-06c3b213 | container-start-loop | conjet | 6.426 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.253, combined_power_mw_max=5909, combined_power_mw_mean=5253.200, combined_power_mw_p50=5101, combined_power_mw_p75=5458, combined_power_mw_p95=5909, combined_power_mw_p99=5909, combined_power_mw_stddev=387.336, cpu_energy_to_solution_joules_estimate=32.162, cpu_power_mw_max=5885, cpu_power_mw_mean=5225.800, cpu_power_mw_p50=5073, cpu_power_mw_p75=5426, cpu_power_mw_p95=5885, cpu_power_mw_p99=5885, cpu_power_mw_stddev=387.751, cpu_power_watts=5.226, energy_to_solution_joules=32.331, energy_to_solution_joules_estimate=32.331, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=27.900, gpu_power_mw_p50=27, gpu_power_mw_p75=29, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=2.809, iteration=9, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.417, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.155, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780202142022-994514e0 | hot-reload-loop | conjet | 6.367 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.132, combined_power_mw_max=5790, combined_power_mw_mean=5132, combined_power_mw_p50=4994, combined_power_mw_p75=5012, combined_power_mw_p95=5790, combined_power_mw_p99=5790, combined_power_mw_stddev=330.665, cpu_energy_to_solution_joules_estimate=31.105, cpu_power_mw_max=5762, cpu_power_mw_mean=5103, cpu_power_mw_p50=4965, cpu_power_mw_p75=4980, cpu_power_mw_p95=5762, cpu_power_mw_p99=5762, cpu_power_mw_stddev=331.028, cpu_power_watts=5.103, energy_to_solution_joules=31.282, energy_to_solution_joules_estimate=31.282, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=29.800, gpu_power_mw_p50=30, gpu_power_mw_p75=30, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=1.939, iteration=9, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.358, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.095, workload_exit_code=0 |
| bench-compose-loop-conjet-1780202148439-6fe07eab | compose-loop | conjet | 6.452 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.084, combined_power_mw_max=5562, combined_power_mw_mean=5084, combined_power_mw_p50=5048, combined_power_mw_p75=5086, combined_power_mw_p95=5562, combined_power_mw_p99=5562, combined_power_mw_stddev=259.742, cpu_energy_to_solution_joules_estimate=31.263, cpu_power_mw_max=5529, cpu_power_mw_mean=5051.600, cpu_power_mw_p50=5017, cpu_power_mw_p75=5053, cpu_power_mw_p95=5529, cpu_power_mw_p99=5529, cpu_power_mw_stddev=259.465, cpu_power_watts=5.052, energy_to_solution_joules=31.464, energy_to_solution_joules_estimate=31.464, energy_verdict=measured, gpu_power_mw_max=34, gpu_power_mw_mean=32.800, gpu_power_mw_p50=33, gpu_power_mw_p75=33, gpu_power_mw_p95=34, gpu_power_mw_p99=34, gpu_power_mw_stddev=0.748, iteration=9, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.444, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.189, workload_exit_code=0 |
| bench-npm-install-conjet-1780202154946-1646561f | npm-install | conjet | 2.020 | 0 | energy_verdict=measured, iteration=9, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.020, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.058, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780202157037-20803a74 | pnpm-install | conjet | 5.432 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.104, combined_power_mw_max=4390, combined_power_mw_mean=2104.250, combined_power_mw_p50=2660, combined_power_mw_p75=4390, combined_power_mw_p95=4390, combined_power_mw_p99=4390, combined_power_mw_stddev=1546.879, cpu_energy_to_solution_joules_estimate=10.706, cpu_power_mw_max=4360, cpu_power_mw_mean=2074, cpu_power_mw_p50=2631, cpu_power_mw_p75=4360, cpu_power_mw_p95=4360, cpu_power_mw_p99=4360, cpu_power_mw_stddev=1547.422, cpu_power_watts=2.074, energy_to_solution_joules=10.862, energy_to_solution_joules_estimate=10.862, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=30.500, gpu_power_mw_p50=30, gpu_power_mw_p75=32, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=0.866, iteration=9, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=5.425, power_source=ac-power, powermetrics_sample_count=4, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=5.162, workload_exit_code=0 |
| bench-cargo-build-conjet-1780202162519-6790b894 | cargo-build | conjet | 2.020 | 127 | energy_verdict=measured, iteration=9, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.020, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.218, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780202164612-92202400 | idle-power-sample | orbstack | 32.129 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.564, combined_power_mw_max=1375, combined_power_mw_mean=564.267, combined_power_mw_p50=480, combined_power_mw_p75=650, combined_power_mw_p95=1086, combined_power_mw_p99=1375, combined_power_mw_stddev=256.200, cpu_power_mw_max=1351, cpu_power_mw_mean=539.533, cpu_power_mw_p50=457, cpu_power_mw_p75=622, cpu_power_mw_p95=1058, cpu_power_mw_p99=1351, cpu_power_mw_stddev=255.263, cpu_power_watts=0.540, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=24.733, gpu_power_mw_p50=24, gpu_power_mw_p75=28, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=3.530, idle_power_watts=0.564, iteration=9, low_power_mode=false, matched_process_lines=43, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780202196852-cf855040 | container-start-loop | orbstack | 30.360 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.523, combined_power_mw_max=2326, combined_power_mw_mean=1523.036, combined_power_mw_p50=1425, combined_power_mw_p75=1713, combined_power_mw_p95=2250, combined_power_mw_p99=2326, combined_power_mw_stddev=383.504, cpu_energy_to_solution_joules_estimate=44.894, cpu_power_mw_max=2297, cpu_power_mw_mean=1495.714, cpu_power_mw_p50=1401, cpu_power_mw_p75=1686, cpu_power_mw_p95=2213, cpu_power_mw_p99=2297, cpu_power_mw_stddev=381.869, cpu_power_watts=1.496, energy_to_solution_joules=45.714, energy_to_solution_joules_estimate=45.714, energy_verdict=measured, gpu_power_mw_max=37, gpu_power_mw_mean=27.321, gpu_power_mw_p50=27, gpu_power_mw_p75=29, gpu_power_mw_p95=31, gpu_power_mw_p99=37, gpu_power_mw_stddev=3.428, iteration=9, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.279, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.015, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780202227264-5bf04d78 | hot-reload-loop | orbstack | 30.360 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.648, combined_power_mw_max=2885, combined_power_mw_mean=1648.036, combined_power_mw_p50=1609, combined_power_mw_p75=1842, combined_power_mw_p95=2709, combined_power_mw_p99=2885, combined_power_mw_stddev=421.936, cpu_energy_to_solution_joules_estimate=48.621, cpu_power_mw_max=2858, cpu_power_mw_mean=1619.821, cpu_power_mw_p50=1577, cpu_power_mw_p75=1814, cpu_power_mw_p95=2683, cpu_power_mw_p99=2858, cpu_power_mw_stddev=421.962, cpu_power_watts=1.620, energy_to_solution_joules=49.468, energy_to_solution_joules_estimate=49.468, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=28.268, gpu_power_mw_p50=28, gpu_power_mw_p75=30, gpu_power_mw_p95=32, gpu_power_mw_p99=33, gpu_power_mw_stddev=2.475, iteration=9, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.282, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.016, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780202257677-a370c833 | compose-loop | orbstack | 30.357 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.563, combined_power_mw_max=2847, combined_power_mw_mean=1563.286, combined_power_mw_p50=1485, combined_power_mw_p75=1744, combined_power_mw_p95=2267, combined_power_mw_p99=2847, combined_power_mw_stddev=414.353, cpu_energy_to_solution_joules_estimate=46.079, cpu_power_mw_max=2820, cpu_power_mw_mean=1535.357, cpu_power_mw_p50=1459, cpu_power_mw_p75=1718, cpu_power_mw_p95=2237, cpu_power_mw_p99=2820, cpu_power_mw_stddev=414.143, cpu_power_watts=1.535, energy_to_solution_joules=46.917, energy_to_solution_joules_estimate=46.917, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=27.946, gpu_power_mw_p50=28, gpu_power_mw_p75=30, gpu_power_mw_p95=31, gpu_power_mw_p99=32, gpu_power_mw_stddev=1.950, iteration=9, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.273, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.012, workload_exit_code=124 |
| bench-npm-install-orbstack-1780202288113-36d180f5 | npm-install | orbstack | 2.862 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.710, combined_power_mw_max=3710, combined_power_mw_mean=3710, combined_power_mw_p50=3710, combined_power_mw_p75=3710, combined_power_mw_p95=3710, combined_power_mw_p99=3710, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=9.562, cpu_power_mw_max=3679, cpu_power_mw_mean=3679, cpu_power_mw_p50=3679, cpu_power_mw_p75=3679, cpu_power_mw_p95=3679, cpu_power_mw_p99=3679, cpu_power_mw_stddev=0, cpu_power_watts=3.679, energy_to_solution_joules=9.643, energy_to_solution_joules_estimate=9.643, energy_verdict=measured, gpu_power_mw_max=31, gpu_power_mw_mean=31, gpu_power_mw_p50=31, gpu_power_mw_p75=31, gpu_power_mw_p95=31, gpu_power_mw_p99=31, gpu_power_mw_stddev=0, iteration=9, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.858, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.599, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780202291038-0ad1c36d | pnpm-install | orbstack | 5.572 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.449, combined_power_mw_max=3799, combined_power_mw_mean=2449.250, combined_power_mw_p50=2253, combined_power_mw_p75=3799, combined_power_mw_p95=3799, combined_power_mw_p99=3799, combined_power_mw_stddev=803.285, cpu_energy_to_solution_joules_estimate=12.829, cpu_power_mw_max=3770, cpu_power_mw_mean=2420.750, cpu_power_mw_p50=2224, cpu_power_mw_p75=3770, cpu_power_mw_p95=3770, cpu_power_mw_p99=3770, cpu_power_mw_stddev=803.030, cpu_power_watts=2.421, energy_to_solution_joules=12.980, energy_to_solution_joules_estimate=12.980, energy_verdict=measured, gpu_power_mw_max=29, gpu_power_mw_mean=28.250, gpu_power_mw_p50=29, gpu_power_mw_p75=29, gpu_power_mw_p95=29, gpu_power_mw_p99=29, gpu_power_mw_stddev=0.829, iteration=9, low_power_mode=false, matched_process_lines=8, power_exit_code=0, power_sample_duration_seconds=5.561, power_source=ac-power, powermetrics_sample_count=4, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=5.299, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780202296669-d60d1489 | cargo-build | orbstack | 2.261 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.883, combined_power_mw_max=1883, combined_power_mw_mean=1883, combined_power_mw_p50=1883, combined_power_mw_p75=1883, combined_power_mw_p95=1883, combined_power_mw_p99=1883, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=3.697, cpu_power_mw_max=1854, cpu_power_mw_mean=1854, cpu_power_mw_p50=1854, cpu_power_mw_p75=1854, cpu_power_mw_p95=1854, cpu_power_mw_p99=1854, cpu_power_mw_stddev=0, cpu_power_watts=1.854, energy_to_solution_joules=3.755, energy_to_solution_joules_estimate=3.755, energy_verdict=measured, gpu_power_mw_max=29, gpu_power_mw_mean=29, gpu_power_mw_p50=29, gpu_power_mw_p75=29, gpu_power_mw_p95=29, gpu_power_mw_p99=29, gpu_power_mw_stddev=0, iteration=9, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.258, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.994, workload_exit_code=127 |
| bench-idle-power-sample-conjet-1780202298991-344e75a8 | idle-power-sample | conjet | 32.062 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.530, combined_power_mw_max=1162, combined_power_mw_mean=529.533, combined_power_mw_p50=466, combined_power_mw_p75=703, combined_power_mw_p95=930, combined_power_mw_p99=1162, combined_power_mw_stddev=235.136, cpu_power_mw_max=1138, cpu_power_mw_mean=505.767, cpu_power_mw_p50=444, cpu_power_mw_p75=674, cpu_power_mw_p95=910, cpu_power_mw_p99=1138, cpu_power_mw_stddev=235.001, cpu_power_watts=0.506, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=23.800, gpu_power_mw_p50=23, gpu_power_mw_p75=25, gpu_power_mw_p95=29, gpu_power_mw_p99=32, gpu_power_mw_stddev=3.113, idle_power_watts=0.530, iteration=10, low_power_mode=false, matched_process_lines=3, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-conjet-1780202331158-2c906c91 | container-start-loop | conjet | 6.373 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=4.909, combined_power_mw_max=5562, combined_power_mw_mean=4908.600, combined_power_mw_p50=4749, combined_power_mw_p75=4986, combined_power_mw_p95=5562, combined_power_mw_p99=5562, combined_power_mw_stddev=360.252, cpu_energy_to_solution_joules_estimate=29.816, cpu_power_mw_max=5539, cpu_power_mw_mean=4887, cpu_power_mw_p50=4731, cpu_power_mw_p75=4961, cpu_power_mw_p95=5539, cpu_power_mw_p99=5539, cpu_power_mw_stddev=358.965, cpu_power_watts=4.887, energy_to_solution_joules=29.948, energy_to_solution_joules_estimate=29.948, energy_verdict=measured, gpu_power_mw_max=26, gpu_power_mw_mean=22, gpu_power_mw_p50=22, gpu_power_mw_p75=23, gpu_power_mw_p95=26, gpu_power_mw_p99=26, gpu_power_mw_stddev=2.530, iteration=10, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.364, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.101, workload_exit_code=0 |
| bench-hot-reload-loop-conjet-1780202337587-cb658d03 | hot-reload-loop | conjet | 6.280 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.002, combined_power_mw_max=5398, combined_power_mw_mean=5001.800, combined_power_mw_p50=4945, combined_power_mw_p75=4948, combined_power_mw_p95=5398, combined_power_mw_p99=5398, combined_power_mw_stddev=207.283, cpu_energy_to_solution_joules_estimate=29.875, cpu_power_mw_max=5372, cpu_power_mw_mean=4974, cpu_power_mw_p50=4916, cpu_power_mw_p75=4917, cpu_power_mw_p95=5372, cpu_power_mw_p99=5372, cpu_power_mw_stddev=207.924, cpu_power_watts=4.974, energy_to_solution_joules=30.042, energy_to_solution_joules_estimate=30.042, energy_verdict=measured, gpu_power_mw_max=33, gpu_power_mw_mean=28.300, gpu_power_mw_p50=27, gpu_power_mw_p75=29, gpu_power_mw_p95=33, gpu_power_mw_p99=33, gpu_power_mw_stddev=2.571, iteration=10, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.272, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.006, workload_exit_code=0 |
| bench-compose-loop-conjet-1780202343917-48430fb1 | compose-loop | conjet | 6.422 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=5.241, combined_power_mw_max=6000, combined_power_mw_mean=5240.600, combined_power_mw_p50=4904, combined_power_mw_p75=5550, combined_power_mw_p95=6000, combined_power_mw_p99=6000, combined_power_mw_stddev=459.081, cpu_energy_to_solution_joules_estimate=32.062, cpu_power_mw_max=5969, cpu_power_mw_mean=5212, cpu_power_mw_p50=4876, cpu_power_mw_p75=5524, cpu_power_mw_p95=5969, cpu_power_mw_p99=5969, cpu_power_mw_stddev=458.680, cpu_power_watts=5.212, energy_to_solution_joules=32.238, energy_to_solution_joules_estimate=32.238, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=28.800, gpu_power_mw_p50=28, gpu_power_mw_p75=30, gpu_power_mw_p95=32, gpu_power_mw_p99=32, gpu_power_mw_stddev=2.040, iteration=10, low_power_mode=false, matched_process_lines=5, power_exit_code=0, power_sample_duration_seconds=6.413, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.152, workload_exit_code=0 |
| bench-npm-install-conjet-1780202350394-be9ecfec | npm-install | conjet | 2.012 | 0 | energy_verdict=measured, iteration=10, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.012, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.945, workload_exit_code=0 |
| bench-pnpm-install-conjet-1780202352474-5a6f98cb | pnpm-install | conjet | 3.174 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=3.588, combined_power_mw_max=3588, combined_power_mw_mean=3588, combined_power_mw_p50=3588, combined_power_mw_p75=3588, combined_power_mw_p95=3588, combined_power_mw_p99=3588, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=10.375, cpu_power_mw_max=3566, cpu_power_mw_mean=3566, cpu_power_mw_p50=3566, cpu_power_mw_p75=3566, cpu_power_mw_p95=3566, cpu_power_mw_p99=3566, cpu_power_mw_stddev=0, cpu_power_watts=3.566, energy_to_solution_joules=10.439, energy_to_solution_joules_estimate=10.439, energy_verdict=measured, gpu_power_mw_max=22, gpu_power_mw_mean=22, gpu_power_mw_p50=22, gpu_power_mw_p75=22, gpu_power_mw_p95=22, gpu_power_mw_p99=22, gpu_power_mw_stddev=0, iteration=10, low_power_mode=false, matched_process_lines=1, power_exit_code=0, power_sample_duration_seconds=3.173, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.909, workload_exit_code=0 |
| bench-cargo-build-conjet-1780202355701-549b102d | cargo-build | conjet | 2.018 | 127 | energy_verdict=measured, iteration=10, low_power_mode=false, matched_process_lines=0, power_exit_code=0, power_sample_duration_seconds=2.018, power_source=ac-power, powermetrics_sample_count=0, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=0.210, workload_exit_code=127 |
| bench-idle-power-sample-orbstack-1780202357794-1f5a8d03 | idle-power-sample | orbstack | 32.096 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=0.496, combined_power_mw_max=909, combined_power_mw_mean=495.900, combined_power_mw_p50=448, combined_power_mw_p75=564, combined_power_mw_p95=867, combined_power_mw_p99=909, combined_power_mw_stddev=192.098, cpu_power_mw_max=884, cpu_power_mw_mean=472.467, cpu_power_mw_p50=425, cpu_power_mw_p75=540, cpu_power_mw_p95=839, cpu_power_mw_p99=884, cpu_power_mw_stddev=191.642, cpu_power_watts=0.472, energy_verdict=measured, gpu_power_mw_max=28, gpu_power_mw_mean=23.367, gpu_power_mw_p50=23, gpu_power_mw_p75=24, gpu_power_mw_p95=28, gpu_power_mw_p99=28, gpu_power_mw_stddev=1.991, idle_power_watts=0.496, iteration=10, low_power_mode=false, matched_process_lines=42, power_source=ac-power, powermetrics_sample_count=30, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal |
| bench-container-start-loop-orbstack-1780202389993-b323b367 | container-start-loop | orbstack | 30.335 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.560, combined_power_mw_max=2279, combined_power_mw_mean=1559.893, combined_power_mw_p50=1601, combined_power_mw_p75=1807, combined_power_mw_p95=2277, combined_power_mw_p99=2279, combined_power_mw_stddev=353.257, cpu_energy_to_solution_joules_estimate=46.009, cpu_power_mw_max=2252, cpu_power_mw_mean=1533.143, cpu_power_mw_p50=1569, cpu_power_mw_p75=1783, cpu_power_mw_p95=2249, cpu_power_mw_p99=2252, cpu_power_mw_stddev=352.490, cpu_power_watts=1.533, energy_to_solution_joules=46.812, energy_to_solution_joules_estimate=46.812, energy_verdict=measured, gpu_power_mw_max=31, gpu_power_mw_mean=26.714, gpu_power_mw_p50=27, gpu_power_mw_p75=29, gpu_power_mw_p95=30, gpu_power_mw_p99=31, gpu_power_mw_stddev=2.657, iteration=10, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.273, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.010, workload_exit_code=124 |
| bench-hot-reload-loop-orbstack-1780202420381-049f09c0 | hot-reload-loop | orbstack | 30.358 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.616, combined_power_mw_max=2543, combined_power_mw_mean=1615.964, combined_power_mw_p50=1598, combined_power_mw_p75=1900, combined_power_mw_p95=2346, combined_power_mw_p99=2543, combined_power_mw_stddev=402.265, cpu_energy_to_solution_joules_estimate=47.690, cpu_power_mw_max=2513, cpu_power_mw_mean=1588.893, cpu_power_mw_p50=1572, cpu_power_mw_p75=1872, cpu_power_mw_p95=2321, cpu_power_mw_p99=2513, cpu_power_mw_stddev=402.173, cpu_power_watts=1.589, energy_to_solution_joules=48.503, energy_to_solution_joules_estimate=48.503, energy_verdict=measured, gpu_power_mw_max=31, gpu_power_mw_mean=27, gpu_power_mw_p50=27, gpu_power_mw_p75=29, gpu_power_mw_p95=30, gpu_power_mw_p99=31, gpu_power_mw_stddev=2.220, iteration=10, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.280, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.015, workload_exit_code=124 |
| bench-compose-loop-orbstack-1780202450799-e42dc513 | compose-loop | orbstack | 30.338 | 124 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.600, combined_power_mw_max=2285, combined_power_mw_mean=1599.750, combined_power_mw_p50=1493, combined_power_mw_p75=1873, combined_power_mw_p95=2251, combined_power_mw_p99=2285, combined_power_mw_stddev=329.759, cpu_energy_to_solution_joules_estimate=47.182, cpu_power_mw_max=2259, cpu_power_mw_mean=1572.107, cpu_power_mw_p50=1470, cpu_power_mw_p75=1846, cpu_power_mw_p95=2219, cpu_power_mw_p99=2259, cpu_power_mw_stddev=329.069, cpu_power_watts=1.572, energy_to_solution_joules=48.012, energy_to_solution_joules_estimate=48.012, energy_verdict=measured, gpu_power_mw_max=32, gpu_power_mw_mean=27.750, gpu_power_mw_p50=28, gpu_power_mw_p75=30, gpu_power_mw_p95=31, gpu_power_mw_p99=32, gpu_power_mw_stddev=2.270, iteration=10, low_power_mode=false, matched_process_lines=60, power_exit_code=0, power_sample_duration_seconds=30.276, power_source=ac-power, powermetrics_sample_count=28, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=30.012, workload_exit_code=124 |
| bench-npm-install-orbstack-1780202481192-a85bad50 | npm-install | orbstack | 2.868 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=2.809, combined_power_mw_max=2809, combined_power_mw_mean=2809, combined_power_mw_p50=2809, combined_power_mw_p75=2809, combined_power_mw_p95=2809, combined_power_mw_p99=2809, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=7.235, cpu_power_mw_max=2787, cpu_power_mw_mean=2787, cpu_power_mw_p50=2787, cpu_power_mw_p75=2787, cpu_power_mw_p95=2787, cpu_power_mw_p99=2787, cpu_power_mw_stddev=0, cpu_power_watts=2.787, energy_to_solution_joules=7.292, energy_to_solution_joules_estimate=7.292, energy_verdict=measured, gpu_power_mw_max=24, gpu_power_mw_mean=23.500, gpu_power_mw_p50=24, gpu_power_mw_p75=24, gpu_power_mw_p95=24, gpu_power_mw_p99=24, gpu_power_mw_stddev=0.500, iteration=10, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.864, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=2.596, workload_exit_code=0 |
| bench-pnpm-install-orbstack-1780202484131-197f96c8 | pnpm-install | orbstack | 6.783 | 0 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.997, combined_power_mw_max=3612, combined_power_mw_mean=1996.800, combined_power_mw_p50=2111, combined_power_mw_p75=2538, combined_power_mw_p95=3612, combined_power_mw_p99=3612, combined_power_mw_stddev=1054.236, cpu_energy_to_solution_joules_estimate=12.801, cpu_power_mw_max=3584, cpu_power_mw_mean=1968, cpu_power_mw_p50=2083, cpu_power_mw_p75=2508, cpu_power_mw_p95=3584, cpu_power_mw_p99=3584, cpu_power_mw_stddev=1054.326, cpu_power_watts=1.968, energy_to_solution_joules=12.988, energy_to_solution_joules_estimate=12.988, energy_verdict=measured, gpu_power_mw_max=31, gpu_power_mw_mean=28.800, gpu_power_mw_p50=28, gpu_power_mw_p75=31, gpu_power_mw_p95=31, gpu_power_mw_p99=31, gpu_power_mw_stddev=1.833, iteration=10, low_power_mode=false, matched_process_lines=10, power_exit_code=0, power_sample_duration_seconds=6.768, power_source=ac-power, powermetrics_sample_count=5, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=6.504, workload_exit_code=0 |
| bench-cargo-build-orbstack-1780202490976-c081e38e | cargo-build | orbstack | 2.230 | 127 | ane_power_mw_max=0, ane_power_mw_mean=0, ane_power_mw_p50=0, ane_power_mw_p75=0, ane_power_mw_p95=0, ane_power_mw_p99=0, ane_power_mw_stddev=0, average_power_watts=1.741, combined_power_mw_max=1741, combined_power_mw_mean=1741, combined_power_mw_p50=1741, combined_power_mw_p75=1741, combined_power_mw_p95=1741, combined_power_mw_p99=1741, combined_power_mw_stddev=0, cpu_energy_to_solution_joules_estimate=3.374, cpu_power_mw_max=1717, cpu_power_mw_mean=1717, cpu_power_mw_p50=1717, cpu_power_mw_p75=1717, cpu_power_mw_p95=1717, cpu_power_mw_p99=1717, cpu_power_mw_stddev=0, cpu_power_watts=1.717, energy_to_solution_joules=3.422, energy_to_solution_joules_estimate=3.422, energy_verdict=measured, gpu_power_mw_max=25, gpu_power_mw_mean=25, gpu_power_mw_p50=25, gpu_power_mw_p75=25, gpu_power_mw_p95=25, gpu_power_mw_p99=25, gpu_power_mw_stddev=0, iteration=10, low_power_mode=false, matched_process_lines=2, power_exit_code=0, power_sample_duration_seconds=2.228, power_source=ac-power, powermetrics_sample_count=1, requested_sample_count=30, requested_sample_rate_ms=1000, thermal_state_after=nominal, thermal_state_before=nominal, workload_duration_seconds=1.965, workload_exit_code=127 |

## Failures

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
```

```text
com.apple.SafariPlatformSupport.   11085  0.04      34.89  0.00    0.00               0.96    0.00              0.00
wifip2pd                           25354  0.06      66.06  0.00    0.00               0.00    0.00              0.00
mDNSResponderHelper                475    0.02      31.35  0.00    0.00               0.96    0.00              0.00
ALL_TASKS                          -2     3043.26   54.50  2847.46 72.79              8079.78 198.26            1375.30

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1885 MHz
E-Cluster HW active residency:  91.44% (600 MHz:   0% 972 MHz:  10% 1332 MHz: 4.2% 1704 MHz:  10% 2064 MHz:  75%)
E-Cluster idle residency:   8.56%
CPU 0 frequency: 1896 MHz
CPU 0 active residency:  87.78% (600 MHz:   0% 972 MHz: 8.0% 1332 MHz: 3.5% 1704 MHz: 9.5% 2064 MHz:  67%)
CPU 0 idle residency:  12.22%
CPU 1 frequency: 1898 MHz
CPU 1 active residency:  87.14% (600 MHz:   0% 972 MHz: 7.9% 1332 MHz: 3.4% 1704 MHz: 9.2% 2064 MHz:  67%)
CPU 1 idle residency:  12.86%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2108 MHz
P0-Cluster HW active residency:  69.25% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .89% 1296 MHz: 9.9% 1524 MHz: 8.5% 1752 MHz:  16% 1980 MHz:  14% 2208 MHz:  16% 2448 MHz:  18% 2676 MHz: 5.0% 2904 MHz: 4.6% 3036 MHz: 2.2% 3132 MHz: 1.7% 3168 MHz: .57% 3228 MHz: 2.5%)
P0-Cluster idle residency:  30.75%
CPU 2 frequency: 2040 MHz
CPU 2 active residency:  51.20% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .73% 1296 MHz: 5.9% 1524 MHz: 4.1% 1752 MHz: 8.7% 1980 MHz: 8.8% 2208 MHz: 7.6% 2448 MHz: 9.7% 2676 MHz: 1.9% 2904 MHz: 1.7% 3036 MHz: .18% 3132 MHz: .20% 3168 MHz: .18% 3228 MHz: 1.5%)
CPU 2 idle residency:  48.80%
CPU 3 frequency: 2079 MHz
CPU 3 active residency:  40.81% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .66% 1296 MHz: 4.0% 1524 MHz: 3.8% 1752 MHz: 7.4% 1980 MHz: 6.5% 2208 MHz: 5.0% 2448 MHz: 6.9% 2676 MHz: 1.9% 2904 MHz: 1.5% 3036 MHz: .63% 3132 MHz: .08% 3168 MHz: .43% 3228 MHz: 2.0%)
CPU 3 idle residency:  59.19%
CPU 4 frequency: 2021 MHz
CPU 4 active residency:  27.19% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .52% 1296 MHz: 3.6% 1524 MHz: 2.0% 1752 MHz: 4.7% 1980 MHz: 5.0% 2208 MHz: 3.2% 2448 MHz: 5.3% 2676 MHz: .92% 2904 MHz: .82% 3036 MHz: .09% 3132 MHz: .06% 3168 MHz: .21% 3228 MHz: .79%)
CPU 4 idle residency:  72.81%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1513 MHz
P1-Cluster HW active residency:  30.85% (600 MHz:  29% 828 MHz: .99% 1056 MHz: 9.3% 1296 MHz: 8.9% 1524 MHz: 6.7% 1752 MHz:  10% 1980 MHz: 9.2% 2208 MHz: 6.3% 2448 MHz:  13% 2676 MHz: 1.9% 2904 MHz: 1.9% 3036 MHz: .61% 3132 MHz: .15% 3168 MHz: .07% 3228 MHz: 1.7%)
P1-Cluster idle residency:  69.15%
CPU 5 frequency: 1936 MHz
CPU 5 active residency:  22.49% (600 MHz: .23% 828 MHz: .03% 1056 MHz: 1.7% 1296 MHz: 2.7% 1524 MHz: 2.4% 1752 MHz: 3.4% 1980 MHz: 3.7% 2208 MHz: 1.8% 2448 MHz: 4.4% 2676 MHz: .65% 2904 MHz: .87% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz: .01% 3228 MHz: .68%)
CPU 5 idle residency:  77.51%
CPU 6 frequency: 1909 MHz
CPU 6 active residency:  14.29% (600 MHz: .06% 828 MHz: .01% 1056 MHz: 1.7% 1296 MHz: 1.7% 1524 MHz: .95% 1752 MHz: 2.1% 1980 MHz: 2.4% 2208 MHz: 1.3% 2448 MHz: 3.3% 2676 MHz: .18% 2904 MHz: .23% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz: .08% 3228 MHz: .35%)
CPU 6 idle residency:  85.71%
CPU 7 frequency: 1987 MHz
CPU 7 active residency:   8.79% (600 MHz: .02% 828 MHz: .00% 1056 MHz: .46% 1296 MHz: 1.5% 1524 MHz: .22% 1752 MHz: 1.3% 1980 MHz: 1.6% 2208 MHz: .51% 2448 MHz: 2.4% 2676 MHz: .51% 2904 MHz: .03% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz: .01% 3228 MHz: .28%)
CPU 7 idle residency:  91.21%

CPU Power: 1956 mW
GPU Power: 296 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2252 mW

**** GPU usage ****

GPU HW active frequency: 492 MHz
GPU HW active residency:  33.07% (389 MHz:  21% 486 MHz: 2.8% 648 MHz: 3.9% 778 MHz: 4.2% 972 MHz: .79% 1296 MHz:   0%)
GPU SW requested state: (P1 :  65% P2 : 8.3% P3 :  11% P4 :  14% P5 : 1.2% P6 :   0%)
GPU idle residency:  66.93%
GPU Power: 300 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
appleh13camerad                    512    0.14      29.92  0.00    0.00               0.97    0.00              0.00
codex                              41664  0.05      56.57  0.00    0.00               0.97    0.00              0.00
wifip2pd                           25354  0.10      65.45  0.00    0.00               0.00    0.00              0.00
ALL_TASKS                          -2     1682.33   47.02  2002.72 23.04              5878.54 409.95            614.43

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1465 MHz
E-Cluster HW active residency:  83.91% (600 MHz:   0% 972 MHz:  42% 1332 MHz:  12% 1704 MHz:  13% 2064 MHz:  33%)
E-Cluster idle residency:  16.09%
CPU 0 frequency: 1499 MHz
CPU 0 active residency:  77.89% (600 MHz:   0% 972 MHz:  31% 1332 MHz: 9.0% 1704 MHz:  11% 2064 MHz:  27%)
CPU 0 idle residency:  22.11%
CPU 1 frequency: 1501 MHz
CPU 1 active residency:  76.57% (600 MHz:   0% 972 MHz:  31% 1332 MHz: 8.2% 1704 MHz:  10% 2064 MHz:  27%)
CPU 1 idle residency:  23.43%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2447 MHz
P0-Cluster HW active residency:  36.06% (600 MHz: 4.5% 828 MHz: .67% 1056 MHz: 1.8% 1296 MHz: 3.5% 1524 MHz: 5.7% 1752 MHz: .76% 1980 MHz: 6.7% 2208 MHz: 6.8% 2448 MHz:  11% 2676 MHz:  17% 2904 MHz:  28% 3036 MHz: .72% 3132 MHz: 3.4% 3168 MHz: 5.4% 3228 MHz: 4.5%)
P0-Cluster idle residency:  63.94%
CPU 2 frequency: 2498 MHz
CPU 2 active residency:  25.43% (600 MHz: .25% 828 MHz: .08% 1056 MHz: 1.0% 1296 MHz: 1.2% 1524 MHz: 1.4% 1752 MHz: .10% 1980 MHz: 1.1% 2208 MHz: .86% 2448 MHz: 3.9% 2676 MHz: 5.2% 2904 MHz: 6.9% 3036 MHz:   0% 3132 MHz: 1.5% 3168 MHz: .72% 3228 MHz: 1.2%)
CPU 2 idle residency:  74.57%
CPU 3 frequency: 2516 MHz
CPU 3 active residency:  17.23% (600 MHz: .09% 828 MHz: .02% 1056 MHz: .41% 1296 MHz: .96% 1524 MHz: 1.1% 1752 MHz: .02% 1980 MHz: .45% 2208 MHz: 1.1% 2448 MHz: 2.7% 2676 MHz: 3.6% 2904 MHz: 4.8% 3036 MHz:   0% 3132 MHz: .84% 3168 MHz: .21% 3228 MHz: .99%)
CPU 3 idle residency:  82.77%
CPU 4 frequency: 2585 MHz
CPU 4 active residency:   8.23% (600 MHz: .04% 828 MHz: .08% 1056 MHz: .32% 1296 MHz: .50% 1524 MHz: .14% 1752 MHz:   0% 1980 MHz: .15% 2208 MHz: .13% 2448 MHz: 1.1% 2676 MHz: 2.1% 2904 MHz: 2.0% 3036 MHz:   0% 3132 MHz: 1.1% 3168 MHz: .07% 3228 MHz: .54%)
CPU 4 idle residency:  91.77%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 964 MHz
P1-Cluster HW active residency:   8.25% (600 MHz:  68% 828 MHz: .82% 1056 MHz: 5.4% 1296 MHz: 8.1% 1524 MHz: 3.2% 1752 MHz: 2.2% 1980 MHz: 2.1% 2208 MHz: 2.4% 2448 MHz: 2.5% 2676 MHz: 1.3% 2904 MHz: 2.9% 3036 MHz: .01% 3132 MHz: .25% 3168 MHz:   0% 3228 MHz: .40%)
P1-Cluster idle residency:  91.75%
CPU 5 frequency: 1533 MHz
CPU 5 active residency:   6.57% (600 MHz: .20% 828 MHz: .13% 1056 MHz: 1.9% 1296 MHz: 1.5% 1524 MHz: .85% 1752 MHz: .62% 1980 MHz: .23% 2208 MHz: .08% 2448 MHz: .27% 2676 MHz: .16% 2904 MHz: .39% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .18%)
CPU 5 idle residency:  93.43%
CPU 6 frequency: 1452 MHz
CPU 6 active residency:   3.28% (600 MHz: .06% 828 MHz: .07% 1056 MHz: 1.1% 1296 MHz: 1.1% 1524 MHz: .24% 1752 MHz: .11% 1980 MHz: .01% 2208 MHz: .04% 2448 MHz: .20% 2676 MHz: .04% 2904 MHz: .21% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .04%)
CPU 6 idle residency:  96.72%
CPU 7 frequency: 1419 MHz
CPU 7 active residency:   1.34% (600 MHz: .03% 828 MHz: .00% 1056 MHz: .52% 1296 MHz: .48% 1524 MHz: .03% 1752 MHz: .07% 1980 MHz: .00% 2208 MHz: .00% 2448 MHz: .15% 2676 MHz: .00% 2904 MHz: .01% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .04%)
CPU 7 idle residency:  98.66%

CPU Power: 1068 mW
GPU Power: 26 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1094 mW

**** GPU usage ****

GPU HW active frequency: 510 MHz
GPU HW active residency:   8.50% (389 MHz: 5.6% 486 MHz:   0% 648 MHz: .59% 778 MHz: 2.3% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  65% P2 : 4.7% P3 : 5.0% P4 :  24% P5 : 1.3% P6 :   0%)
GPU idle residency:  91.50%
GPU Power: 26 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
mDNSResponderHelper                475    0.02      39.33  0.00    0.00               0.96    0.00              0.00
callservicesd                      99207  0.06      26.53  0.00    0.00               0.96    0.96              0.00
Brave Browser Helper (Renderer)    96609  0.07      66.76  0.00    0.00               1.91    0.00              0.00
ALL_TASKS                          -2     2164.93   46.35  2794.92 53.58              7653.74 632.47            822.40

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1537 MHz
E-Cluster HW active residency:  85.92% (600 MHz:   0% 972 MHz:  34% 1332 MHz:  16% 1704 MHz:  13% 2064 MHz:  38%)
E-Cluster idle residency:  14.08%
CPU 0 frequency: 1558 MHz
CPU 0 active residency:  78.59% (600 MHz:   0% 972 MHz:  25% 1332 MHz:  12% 1704 MHz:  10% 2064 MHz:  31%)
CPU 0 idle residency:  21.41%
CPU 1 frequency: 1562 MHz
CPU 1 active residency:  77.19% (600 MHz:   0% 972 MHz:  24% 1332 MHz:  12% 1704 MHz:  11% 2064 MHz:  31%)
CPU 1 idle residency:  22.81%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2083 MHz
P0-Cluster HW active residency:  51.20% (600 MHz: .37% 828 MHz: .16% 1056 MHz: .51% 1296 MHz: 1.1% 1524 MHz: 5.0% 1752 MHz:  13% 1980 MHz:  43% 2208 MHz:  18% 2448 MHz:  11% 2676 MHz: 3.0% 2904 MHz: .76% 3036 MHz: 1.6% 3132 MHz: .96% 3168 MHz: .34% 3228 MHz: 1.6%)
P0-Cluster idle residency:  48.80%
CPU 2 frequency: 2029 MHz
CPU 2 active residency:  38.63% (600 MHz: .03% 828 MHz: .00% 1056 MHz: .15% 1296 MHz: .41% 1524 MHz: 3.4% 1752 MHz: 6.2% 1980 MHz:  16% 2208 MHz: 7.4% 2448 MHz: 3.2% 2676 MHz: .92% 2904 MHz: .14% 3036 MHz: .73% 3132 MHz: .06% 3168 MHz: .23% 3228 MHz: .20%)
CPU 2 idle residency:  61.37%
CPU 3 frequency: 2064 MHz
CPU 3 active residency:  28.45% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .06% 1296 MHz: .46% 1524 MHz: 2.2% 1752 MHz: 4.8% 1980 MHz:  11% 2208 MHz: 5.3% 2448 MHz: 2.5% 2676 MHz: .65% 2904 MHz: .01% 3036 MHz: .49% 3132 MHz: .02% 3168 MHz: .01% 3228 MHz: 1.2%)
CPU 3 idle residency:  71.55%
CPU 4 frequency: 2044 MHz
CPU 4 active residency:  19.23% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .22% 1524 MHz: 1.5% 1752 MHz: 2.6% 1980 MHz: 8.3% 2208 MHz: 3.6% 2448 MHz: 1.8% 2676 MHz: .79% 2904 MHz: .00% 3036 MHz: .14% 3132 MHz: .00% 3168 MHz: .00% 3228 MHz: .22%)
CPU 4 idle residency:  80.77%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1343 MHz
P1-Cluster HW active residency:  19.94% (600 MHz:  42% 828 MHz: .90% 1056 MHz: 3.6% 1296 MHz: 6.8% 1524 MHz: 5.8% 1752 MHz: 9.9% 1980 MHz:  17% 2208 MHz: 6.6% 2448 MHz: 2.6% 2676 MHz: 1.8% 2904 MHz:   0% 3036 MHz: .61% 3132 MHz: .12% 3168 MHz: .37% 3228 MHz: 1.9%)
P1-Cluster idle residency:  80.06%
CPU 5 frequency: 1839 MHz
CPU 5 active residency:  15.47% (600 MHz: .28% 828 MHz: .23% 1056 MHz: .85% 1296 MHz: 1.7% 1524 MHz: 1.8% 1752 MHz: 1.8% 1980 MHz: 4.4% 2208 MHz: 2.5% 2448 MHz: 1.0% 2676 MHz: .57% 2904 MHz:   0% 3036 MHz: .11% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .10%)
CPU 5 idle residency:  84.53%
CPU 6 frequency: 1958 MHz
CPU 6 active residency:   8.85% (600 MHz: .06% 828 MHz: .05% 1056 MHz: .17% 1296 MHz: .79% 1524 MHz: .82% 1752 MHz: 1.3% 1980 MHz: 2.3% 2208 MHz: 1.7% 2448 MHz: 1.3% 2676 MHz: .16% 2904 MHz:   0% 3036 MHz: .16% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  91.15%
CPU 7 frequency: 1960 MHz
CPU 7 active residency:   4.62% (600 MHz: .02% 828 MHz: .00% 1056 MHz: .03% 1296 MHz: .33% 1524 MHz: .53% 1752 MHz: .60% 1980 MHz: 1.5% 2208 MHz: .90% 2448 MHz: .62% 2676 MHz: .01% 2904 MHz:   0% 3036 MHz: .05% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 7 idle residency:  95.38%

CPU Power: 1253 mW
GPU Power: 425 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1678 mW

**** GPU usage ****

GPU HW active frequency: 484 MHz
GPU HW active residency:  32.37% (389 MHz:  22% 486 MHz: 2.9% 648 MHz: 3.3% 778 MHz: 3.2% 972 MHz: 1.2% 1296 MHz:   0%)
GPU SW requested state: (P1 :  71% P2 : 8.6% P3 : 8.3% P4 :  10% P5 : 2.2% P6 :   0%)
GPU idle residency:  67.63%
GPU Power: 425 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    96609  0.02      59.79  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28614  0.06      66.71  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96610  0.05      69.06  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2114.44   42.07  2405.37 60.08              7093.96 568.34            795.91

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1597 MHz
E-Cluster HW active residency:  84.96% (600 MHz:   0% 972 MHz:  32% 1332 MHz: 7.2% 1704 MHz:  18% 2064 MHz:  43%)
E-Cluster idle residency:  15.04%
CPU 0 frequency: 1650 MHz
CPU 0 active residency:  78.98% (600 MHz:   0% 972 MHz:  22% 1332 MHz: 4.9% 1704 MHz:  15% 2064 MHz:  38%)
CPU 0 idle residency:  21.02%
CPU 1 frequency: 1657 MHz
CPU 1 active residency:  79.49% (600 MHz:   0% 972 MHz:  22% 1332 MHz: 4.3% 1704 MHz:  15% 2064 MHz:  38%)
CPU 1 idle residency:  20.51%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2053 MHz
P0-Cluster HW active residency:  46.72% (600 MHz: .16% 828 MHz:   0% 1056 MHz: .36% 1296 MHz: 9.5% 1524 MHz: 3.8% 1752 MHz:  18% 1980 MHz:  24% 2208 MHz:  20% 2448 MHz:  14% 2676 MHz: 4.5% 2904 MHz: 1.4% 3036 MHz: 1.1% 3132 MHz: .69% 3168 MHz: .54% 3228 MHz: 1.8%)
P0-Cluster idle residency:  53.28%
CPU 2 frequency: 2072 MHz
CPU 2 active residency:  35.44% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .28% 1296 MHz: 2.3% 1524 MHz: .85% 1752 MHz: 8.0% 1980 MHz: 9.0% 2208 MHz: 7.2% 2448 MHz: 4.2% 2676 MHz: .94% 2904 MHz: .51% 3036 MHz: .17% 3132 MHz:   0% 3168 MHz: .22% 3228 MHz: 1.7%)
CPU 2 idle residency:  64.56%
CPU 3 frequency: 2072 MHz
CPU 3 active residency:  23.21% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .27% 1296 MHz: 1.1% 1524 MHz: .72% 1752 MHz: 5.6% 1980 MHz: 5.4% 2208 MHz: 4.1% 2448 MHz: 4.1% 2676 MHz: .67% 2904 MHz: .31% 3036 MHz: .23% 3132 MHz:   0% 3168 MHz: .05% 3228 MHz: .66%)
CPU 3 idle residency:  76.79%
CPU 4 frequency: 2123 MHz
CPU 4 active residency:  16.13% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .27% 1296 MHz: .56% 1524 MHz: .18% 1752 MHz: 4.1% 1980 MHz: 3.4% 2208 MHz: 3.3% 2448 MHz: 2.4% 2676 MHz: .38% 2904 MHz: .23% 3036 MHz: .16% 3132 MHz:   0% 3168 MHz: .37% 3228 MHz: .77%)
CPU 4 idle residency:  83.87%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1307 MHz
P1-Cluster HW active residency:  17.22% (600 MHz:  46% 828 MHz: 1.5% 1056 MHz: 5.2% 1296 MHz: 4.8% 1524 MHz: 4.7% 1752 MHz: 6.3% 1980 MHz:  11% 2208 MHz: 7.6% 2448 MHz: 7.8% 2676 MHz: 2.3% 2904 MHz: .12% 3036 MHz: .41% 3132 MHz: .06% 3168 MHz: .19% 3228 MHz: 1.7%)
P1-Cluster idle residency:  82.78%
CPU 5 frequency: 1847 MHz
CPU 5 active residency:  11.72% (600 MHz: .37% 828 MHz: .01% 1056 MHz: 1.2% 1296 MHz: .98% 1524 MHz: 1.0% 1752 MHz: 1.8% 1980 MHz: 3.0% 2208 MHz: 1.4% 2448 MHz: 1.3% 2676 MHz: .24% 2904 MHz: .03% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz: .04% 3228 MHz: .33%)
CPU 5 idle residency:  88.28%
CPU 6 frequency: 1762 MHz
CPU 6 active residency:   7.98% (600 MHz: .10% 828 MHz: .01% 1056 MHz: 1.1% 1296 MHz: .92% 1524 MHz: .43% 1752 MHz: 2.0% 1980 MHz: 1.8% 2208 MHz: .66% 2448 MHz: .84% 2676 MHz: .04% 2904 MHz: .01% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz: .00% 3228 MHz: .10%)
CPU 6 idle residency:  92.02%
CPU 7 frequency: 1925 MHz
CPU 7 active residency:   5.12% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .57% 1296 MHz: .31% 1524 MHz: .50% 1752 MHz: 1.1% 1980 MHz: .78% 2208 MHz: .38% 2448 MHz: .75% 2676 MHz: .71% 2904 MHz: .00% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .02%)
CPU 7 idle residency:  94.88%

CPU Power: 1223 mW
GPU Power: 207 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1430 mW

**** GPU usage ****

GPU HW active frequency: 430 MHz
GPU HW active residency:  22.96% (389 MHz:  20% 486 MHz: .39% 648 MHz: 1.1% 778 MHz: 1.2% 972 MHz: .25% 1296 MHz:   0%)
GPU SW requested state: (P1 :  87% P2 : 3.8% P3 : 3.2% P4 : 5.5% P5 : .20% P6 :   0%)
GPU idle residency:  77.04%
GPU Power: 208 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
appleh13camerad                    512    0.07      24.14  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28392  0.06      56.42  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.03      51.51  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2117.74   45.30  2783.30 35.21              7031.59 460.62            1353.26

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1591 MHz
E-Cluster HW active residency:  81.76% (600 MHz:   0% 972 MHz:  34% 1332 MHz: 8.7% 1704 MHz:  11% 2064 MHz:  46%)
E-Cluster idle residency:  18.24%
CPU 0 frequency: 1627 MHz
CPU 0 active residency:  74.94% (600 MHz:   0% 972 MHz:  21% 1332 MHz: 8.0% 1704 MHz: 9.8% 2064 MHz:  36%)
CPU 0 idle residency:  25.06%
CPU 1 frequency: 1623 MHz
CPU 1 active residency:  74.43% (600 MHz:   0% 972 MHz:  22% 1332 MHz: 7.5% 1704 MHz:  10% 2064 MHz:  35%)
CPU 1 idle residency:  25.57%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2330 MHz
P0-Cluster HW active residency:  50.76% (600 MHz: 1.8% 828 MHz: .21% 1056 MHz: 1.6% 1296 MHz: 2.7% 1524 MHz: 8.0% 1752 MHz: 5.6% 1980 MHz:  12% 2208 MHz:  13% 2448 MHz:  21% 2676 MHz:  12% 2904 MHz: 2.9% 3036 MHz: 6.5% 3132 MHz: 5.4% 3168 MHz: 1.5% 3228 MHz: 5.7%)
P0-Cluster idle residency:  49.24%
CPU 2 frequency: 2455 MHz
CPU 2 active residency:  38.98% (600 MHz: .06% 828 MHz: .01% 1056 MHz: .55% 1296 MHz: 2.1% 1524 MHz: 2.7% 1752 MHz: 2.2% 1980 MHz: 3.5% 2208 MHz: 5.2% 2448 MHz: 4.8% 2676 MHz: 4.2% 2904 MHz: 1.3% 3036 MHz: 1.9% 3132 MHz: 1.1% 3168 MHz: 2.2% 3228 MHz: 7.1%)
CPU 2 idle residency:  61.02%
CPU 3 frequency: 2456 MHz
CPU 3 active residency:  28.97% (600 MHz: .01% 828 MHz: .00% 1056 MHz: .16% 1296 MHz: 1.6% 1524 MHz: 2.0% 1752 MHz: 1.8% 1980 MHz: 2.8% 2208 MHz: 4.0% 2448 MHz: 3.6% 2676 MHz: 3.0% 2904 MHz: 1.1% 3036 MHz: 1.5% 3132 MHz: .98% 3168 MHz: 1.6% 3228 MHz: 4.8%)
CPU 3 idle residency:  71.03%
CPU 4 frequency: 2419 MHz
CPU 4 active residency:  20.46% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .02% 1296 MHz: 1.4% 1524 MHz: 1.5% 1752 MHz: 1.6% 1980 MHz: 1.7% 2208 MHz: 3.0% 2448 MHz: 2.7% 2676 MHz: 1.9% 2904 MHz: .59% 3036 MHz: 1.1% 3132 MHz: .42% 3168 MHz: 1.3% 3228 MHz: 3.3%)
CPU 4 idle residency:  79.54%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1561 MHz
P1-Cluster HW active residency:  24.39% (600 MHz:  43% 828 MHz: .58% 1056 MHz: 4.0% 1296 MHz: 4.2% 1524 MHz: 6.0% 1752 MHz: 4.4% 1980 MHz: 3.2% 2208 MHz: 4.9% 2448 MHz: 7.0% 2676 MHz: 4.3% 2904 MHz: 1.6% 3036 MHz: 2.7% 3132 MHz: 3.1% 3168 MHz: 2.8% 3228 MHz: 8.0%)
P1-Cluster idle residency:  75.61%
CPU 5 frequency: 2366 MHz
CPU 5 active residency:  20.78% (600 MHz: .16% 828 MHz: .01% 1056 MHz: .67% 1296 MHz: 2.3% 1524 MHz: 1.3% 1752 MHz: 1.6% 1980 MHz: 1.4% 2208 MHz: 1.6% 2448 MHz: 2.8% 2676 MHz: 1.6% 2904 MHz: 1.0% 3036 MHz: 1.0% 3132 MHz: .67% 3168 MHz: 1.1% 3228 MHz: 3.7%)
CPU 5 idle residency:  79.22%
CPU 6 frequency: 2277 MHz
CPU 6 active residency:   7.91% (600 MHz: .02% 828 MHz: .00% 1056 MHz: .41% 1296 MHz: .57% 1524 MHz: .95% 1752 MHz: .60% 1980 MHz: .79% 2208 MHz: .76% 2448 MHz: 1.1% 2676 MHz: .41% 2904 MHz: .06% 3036 MHz: .15% 3132 MHz: .24% 3168 MHz: .83% 3228 MHz: 1.0%)
CPU 6 idle residency:  92.09%
CPU 7 frequency: 2212 MHz
CPU 7 active residency:   4.28% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .10% 1296 MHz: .22% 1524 MHz: .60% 1752 MHz: .53% 1980 MHz: .59% 2208 MHz: .64% 2448 MHz: .53% 2676 MHz: .12% 2904 MHz: .05% 3036 MHz: .01% 3132 MHz: .03% 3168 MHz: .11% 3228 MHz: .75%)
CPU 7 idle residency:  95.72%

CPU Power: 2002 mW
GPU Power: 69 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2071 mW

**** GPU usage ****

GPU HW active frequency: 423 MHz
GPU HW active residency:  16.94% (389 MHz:  15% 486 MHz: .46% 648 MHz: .33% 778 MHz: 1.1% 972 MHz: .05% 1296 MHz:   0%)
GPU SW requested state: (P1 :  89% P2 : .74% P3 : 4.5% P4 : 4.7% P5 : .61% P6 :   0%)
GPU idle residency:  83.06%
GPU Power: 69 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.02      39.16  0.00    0.00               0.98    0.00              0.00
wifip2pd                           25354  0.05      40.62  0.00    0.00               0.00    0.00              0.00
Brave Browser Helper (Renderer)    28392  0.02      62.28  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     1840.21   44.31  2837.04 38.39              6631.90 399.67            1168.98

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1429 MHz
E-Cluster HW active residency:  78.43% (600 MHz:   0% 972 MHz:  50% 1332 MHz: 8.6% 1704 MHz: 7.8% 2064 MHz:  34%)
E-Cluster idle residency:  21.57%
CPU 0 frequency: 1441 MHz
CPU 0 active residency:  72.60% (600 MHz:   0% 972 MHz:  35% 1332 MHz: 7.3% 1704 MHz: 5.2% 2064 MHz:  25%)
CPU 0 idle residency:  27.40%
CPU 1 frequency: 1448 MHz
CPU 1 active residency:  72.17% (600 MHz:   0% 972 MHz:  34% 1332 MHz: 7.1% 1704 MHz: 5.4% 2064 MHz:  26%)
CPU 1 idle residency:  27.83%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2276 MHz
P0-Cluster HW active residency:  46.59% (600 MHz: 1.7% 828 MHz: .16% 1056 MHz: 1.5% 1296 MHz: 3.9% 1524 MHz: 3.6% 1752 MHz:  10% 1980 MHz:  14% 2208 MHz:  21% 2448 MHz:  10% 2676 MHz:  12% 2904 MHz: 9.3% 3036 MHz: 6.0% 3132 MHz: 2.7% 3168 MHz: 1.6% 3228 MHz: 1.7%)
P0-Cluster idle residency:  53.41%
CPU 2 frequency: 2345 MHz
CPU 2 active residency:  32.19% (600 MHz: .07% 828 MHz: .00% 1056 MHz: .44% 1296 MHz: 1.3% 1524 MHz: 1.3% 1752 MHz: 1.7% 1980 MHz: 5.5% 2208 MHz: 6.3% 2448 MHz: 4.1% 2676 MHz: 3.4% 2904 MHz: 3.3% 3036 MHz: 2.2% 3132 MHz: 1.3% 3168 MHz: .80% 3228 MHz: .46%)
CPU 2 idle residency:  67.81%
CPU 3 frequency: 2391 MHz
CPU 3 active residency:  25.19% (600 MHz: .00% 828 MHz: .00% 1056 MHz: .26% 1296 MHz: .73% 1524 MHz: 1.4% 1752 MHz: 2.1% 1980 MHz: 3.1% 2208 MHz: 4.1% 2448 MHz: 2.8% 2676 MHz: 3.1% 2904 MHz: 3.2% 3036 MHz: 2.2% 3132 MHz: 1.3% 3168 MHz: .67% 3228 MHz: .21%)
CPU 3 idle residency:  74.81%
CPU 4 frequency: 2458 MHz
CPU 4 active residency:  16.30% (600 MHz: .01% 828 MHz: .00% 1056 MHz: .21% 1296 MHz: .53% 1524 MHz: .67% 1752 MHz: .65% 1980 MHz: 2.0% 2208 MHz: 2.7% 2448 MHz: 1.9% 2676 MHz: 1.8% 2904 MHz: 2.3% 3036 MHz: 2.2% 3132 MHz: .59% 3168 MHz: .32% 3228 MHz: .51%)
CPU 4 idle residency:  83.70%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1320 MHz
P1-Cluster HW active residency:  17.20% (600 MHz:  54% 828 MHz: .40% 1056 MHz: 4.6% 1296 MHz: 3.0% 1524 MHz: 3.5% 1752 MHz: 5.2% 1980 MHz: 5.3% 2208 MHz: 3.5% 2448 MHz: 2.7% 2676 MHz: 6.1% 2904 MHz: 6.1% 3036 MHz: 3.1% 3132 MHz: 1.5% 3168 MHz: .73% 3228 MHz: .11%)
P1-Cluster idle residency:  82.80%
CPU 5 frequency: 2255 MHz
CPU 5 active residency:  13.45% (600 MHz: .22% 828 MHz: .01% 1056 MHz: .85% 1296 MHz: 1.1% 1524 MHz: .98% 1752 MHz: .80% 1980 MHz: 1.9% 2208 MHz: 1.1% 2448 MHz: 1.1% 2676 MHz: 1.2% 2904 MHz: 1.1% 3036 MHz: 1.3% 3132 MHz: 1.1% 3168 MHz: .61% 3228 MHz: .13%)
CPU 5 idle residency:  86.55%
CPU 6 frequency: 2252 MHz
CPU 6 active residency:   6.78% (600 MHz: .06% 828 MHz:   0% 1056 MHz: .58% 1296 MHz: .49% 1524 MHz: .93% 1752 MHz: .16% 1980 MHz: .66% 2208 MHz: .21% 2448 MHz: .64% 2676 MHz: .73% 2904 MHz: 1.0% 3036 MHz: .69% 3132 MHz: .34% 3168 MHz: .04% 3228 MHz: .25%)
CPU 6 idle residency:  93.22%
CPU 7 frequency: 2329 MHz
CPU 7 active residency:   3.08% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .33% 1296 MHz: .17% 1524 MHz: .27% 1752 MHz: .04% 1980 MHz: .24% 2208 MHz: .29% 2448 MHz: .23% 2676 MHz: .07% 2904 MHz: .78% 3036 MHz: .36% 3132 MHz: .28% 3168 MHz: .00% 3228 MHz: .00%)
CPU 7 idle residency:  96.92%

CPU Power: 1666 mW
GPU Power: 26 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1691 mW

**** GPU usage ****

GPU HW active frequency: 483 MHz
GPU HW active residency:   7.91% (389 MHz: 5.2% 486 MHz: .75% 648 MHz: .64% 778 MHz: 1.3% 972 MHz: .02% 1296 MHz:   0%)
GPU SW requested state: (P1 :  66% P2 :  12% P3 : 8.6% P4 :  10% P5 : 2.5% P6 :   0%)
GPU idle residency:  92.09%
GPU Power: 26 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
appleh13camerad                    512    0.09      28.78  0.00    0.00               0.97    0.97              0.00
Brave Browser Helper (Renderer)    96609  0.08      76.58  0.00    0.00               1.94    0.00              0.00
mDNSResponderHelper                475    0.04      38.74  0.00    0.00               0.97    0.97              0.00
ALL_TASKS                          -2     1761.87   46.08  2499.88 24.19              6144.25 599.82            810.14

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1424 MHz
E-Cluster HW active residency:  76.46% (600 MHz:   0% 972 MHz:  52% 1332 MHz: 5.4% 1704 MHz: 9.5% 2064 MHz:  33%)
E-Cluster idle residency:  23.54%
CPU 0 frequency: 1480 MHz
CPU 0 active residency:  70.16% (600 MHz:   0% 972 MHz:  32% 1332 MHz: 4.3% 1704 MHz: 7.4% 2064 MHz:  26%)
CPU 0 idle residency:  29.84%
CPU 1 frequency: 1478 MHz
CPU 1 active residency:  70.35% (600 MHz:   0% 972 MHz:  32% 1332 MHz: 4.4% 1704 MHz: 7.8% 2064 MHz:  26%)
CPU 1 idle residency:  29.65%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1860 MHz
P0-Cluster HW active residency:  40.51% (600 MHz: 9.0% 828 MHz:   0% 1056 MHz: 4.9% 1296 MHz: 9.0% 1524 MHz:  12% 1752 MHz:  17% 1980 MHz: 7.8% 2208 MHz:  18% 2448 MHz: 7.8% 2676 MHz: 6.1% 2904 MHz: 1.5% 3036 MHz: 2.2% 3132 MHz: 2.3% 3168 MHz: .41% 3228 MHz: 1.4%)
P0-Cluster idle residency:  59.49%
CPU 2 frequency: 1998 MHz
CPU 2 active residency:  31.11% (600 MHz: .07% 828 MHz:   0% 1056 MHz: 2.0% 1296 MHz: 4.8% 1524 MHz: 3.4% 1752 MHz: 4.3% 1980 MHz: 1.9% 2208 MHz: 5.4% 2448 MHz: 3.3% 2676 MHz: 2.3% 2904 MHz: .63% 3036 MHz: .97% 3132 MHz: 1.0% 3168 MHz: .29% 3228 MHz: .62%)
CPU 2 idle residency:  68.89%
CPU 3 frequency: 2019 MHz
CPU 3 active residency:  21.84% (600 MHz: .00% 828 MHz:   0% 1056 MHz: 1.7% 1296 MHz: 3.0% 1524 MHz: 2.4% 1752 MHz: 1.8% 1980 MHz: 1.2% 2208 MHz: 4.9% 2448 MHz: 3.2% 2676 MHz: 1.2% 2904 MHz: .29% 3036 MHz: .53% 3132 MHz: .86% 3168 MHz: .35% 3228 MHz: .24%)
CPU 3 idle residency:  78.16%
CPU 4 frequency: 2080 MHz
CPU 4 active residency:  14.71% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .90% 1296 MHz: 2.3% 1524 MHz: 1.6% 1752 MHz: .84% 1980 MHz: .51% 2208 MHz: 2.2% 2448 MHz: 3.5% 2676 MHz: 1.6% 2904 MHz: .04% 3036 MHz: .58% 3132 MHz: .34% 3168 MHz: .21% 3228 MHz: .20%)
CPU 4 idle residency:  85.29%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1132 MHz
P1-Cluster HW active residency:  16.08% (600 MHz:  61% 828 MHz:   0% 1056 MHz: 4.1% 1296 MHz: 5.8% 1524 MHz: 3.9% 1752 MHz: 4.5% 1980 MHz: 4.0% 2208 MHz: 3.8% 2448 MHz: 4.5% 2676 MHz: 3.5% 2904 MHz: .92% 3036 MHz: 1.1% 3132 MHz: 1.4% 3168 MHz: .53% 3228 MHz: .64%)
P1-Cluster idle residency:  83.92%
CPU 5 frequency: 1902 MHz
CPU 5 active residency:  13.99% (600 MHz: .22% 828 MHz:   0% 1056 MHz: 2.0% 1296 MHz: 2.4% 1524 MHz: 1.6% 1752 MHz: .72% 1980 MHz: .73% 2208 MHz: 1.4% 2448 MHz: 2.4% 2676 MHz: 1.2% 2904 MHz: .09% 3036 MHz: .57% 3132 MHz: .47% 3168 MHz: .13% 3228 MHz: .01%)
CPU 5 idle residency:  86.01%
CPU 6 frequency: 1943 MHz
CPU 6 active residency:   8.22% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .87% 1296 MHz: 1.2% 1524 MHz: 1.1% 1752 MHz: .51% 1980 MHz: .58% 2208 MHz: .86% 2448 MHz: 2.1% 2676 MHz: .39% 2904 MHz: .39% 3036 MHz: .09% 3132 MHz: .05% 3168 MHz: .03% 3228 MHz: .00%)
CPU 6 idle residency:  91.78%
CPU 7 frequency: 1925 MHz
CPU 7 active residency:   6.66% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .64% 1296 MHz: 1.0% 1524 MHz: .66% 1752 MHz: .26% 1980 MHz: .94% 2208 MHz: .76% 2448 MHz: 2.2% 2676 MHz: .08% 2904 MHz: .00% 3036 MHz: .01% 3132 MHz: .02% 3168 MHz: .01% 3228 MHz:   0%)
CPU 7 idle residency:  93.34%

CPU Power: 1183 mW
GPU Power: 30 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1213 mW

**** GPU usage ****

GPU HW active frequency: 495 MHz
GPU HW active residency:   9.88% (389 MHz: 7.1% 486 MHz: .25% 648 MHz: .48% 778 MHz: 1.6% 972 MHz: .48% 1296 MHz:   0%)
GPU SW requested state: (P1 :  70% P2 : 1.1% P3 :  13% P4 :  12% P5 : 3.0% P6 :   0%)
GPU idle residency:  90.12%
GPU Power: 30 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=orbstack
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
Brave Browser Helper               96565  0.04      22.39  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28631  0.03      40.74  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96593  0.02      59.84  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2296.91   48.55  2909.56 39.20              6506.08 479.21            1004.56

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1458 MHz
E-Cluster HW active residency:  78.38% (600 MHz:   0% 972 MHz:  48% 1332 MHz: 3.8% 1704 MHz:  14% 2064 MHz:  34%)
E-Cluster idle residency:  21.62%
CPU 0 frequency: 1515 MHz
CPU 0 active residency:  72.16% (600 MHz:   0% 972 MHz:  31% 1332 MHz: 2.5% 1704 MHz:  10% 2064 MHz:  28%)
CPU 0 idle residency:  27.84%
CPU 1 frequency: 1517 MHz
CPU 1 active residency:  72.52% (600 MHz:   0% 972 MHz:  31% 1332 MHz: 2.3% 1704 MHz:  11% 2064 MHz:  28%)
CPU 1 idle residency:  27.48%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2021 MHz
P0-Cluster HW active residency:  51.37% (600 MHz: 1.6% 828 MHz: .60% 1056 MHz: 4.3% 1296 MHz:  13% 1524 MHz: 6.0% 1752 MHz: 6.2% 1980 MHz:  21% 2208 MHz:  18% 2448 MHz:  11% 2676 MHz:  13% 2904 MHz: 4.9% 3036 MHz: .76% 3132 MHz: .13% 3168 MHz:   0% 3228 MHz: .31%)
P0-Cluster idle residency:  48.63%
CPU 2 frequency: 1997 MHz
CPU 2 active residency:  40.56% (600 MHz: .07% 828 MHz: .01% 1056 MHz: 2.2% 1296 MHz: 6.2% 1524 MHz: 2.0% 1752 MHz: 2.2% 1980 MHz: 9.1% 2208 MHz: 8.6% 2448 MHz: 4.6% 2676 MHz: 3.5% 2904 MHz: 1.3% 3036 MHz: .25% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .34%)
CPU 2 idle residency:  59.44%
CPU 3 frequency: 2037 MHz
CPU 3 active residency:  26.69% (600 MHz: .02% 828 MHz:   0% 1056 MHz: 1.1% 1296 MHz: 3.8% 1524 MHz: 1.2% 1752 MHz: 1.4% 1980 MHz: 5.6% 2208 MHz: 6.2% 2448 MHz: 3.4% 2676 MHz: 2.9% 2904 MHz: .73% 3036 MHz: .05% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .23%)
CPU 3 idle residency:  73.31%
CPU 4 frequency: 2090 MHz
CPU 4 active residency:  18.35% (600 MHz: .01% 828 MHz:   0% 1056 MHz: 1.0% 1296 MHz: 2.1% 1524 MHz: .78% 1752 MHz: .89% 1980 MHz: 3.6% 2208 MHz: 3.8% 2448 MHz: 2.7% 2676 MHz: 2.0% 2904 MHz: .90% 3036 MHz: .35% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .19%)
CPU 4 idle residency:  81.65%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1210 MHz
P1-Cluster HW active residency:  19.31% (600 MHz:  52% 828 MHz: 1.1% 1056 MHz: 7.8% 1296 MHz: 5.1% 1524 MHz: 4.4% 1752 MHz: 6.7% 1980 MHz: 5.6% 2208 MHz: 5.1% 2448 MHz: 4.0% 2676 MHz: 4.4% 2904 MHz: 2.9% 3036 MHz: .69% 3132 MHz: .11% 3168 MHz:   0% 3228 MHz: .25%)
P1-Cluster idle residency:  80.69%
CPU 5 frequency: 1901 MHz
CPU 5 active residency:  14.73% (600 MHz: .21% 828 MHz: .28% 1056 MHz: 2.2% 1296 MHz: 1.1% 1524 MHz: 1.1% 1752 MHz: 2.0% 1980 MHz: 1.2% 2208 MHz: 2.2% 2448 MHz: 2.4% 2676 MHz: 1.3% 2904 MHz: .47% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .22%)
CPU 5 idle residency:  85.27%
CPU 6 frequency: 1703 MHz
CPU 6 active residency:   8.33% (600 MHz: .05% 828 MHz: .19% 1056 MHz: 1.8% 1296 MHz: 1.3% 1524 MHz: .74% 1752 MHz: 1.0% 1980 MHz: 1.0% 2208 MHz: 1.1% 2448 MHz: .55% 2676 MHz: .22% 2904 MHz: .16% 3036 MHz: .02% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .20%)
CPU 6 idle residency:  91.67%
CPU 7 frequency: 1722 MHz
CPU 7 active residency:   4.24% (600 MHz: .02% 828 MHz: .13% 1056 MHz: 1.0% 1296 MHz: .86% 1524 MHz: .17% 1752 MHz: .24% 1980 MHz: .35% 2208 MHz: .63% 2448 MHz: .52% 2676 MHz: .06% 2904 MHz: .05% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .21%)
CPU 7 idle residency:  95.76%

CPU Power: 1380 mW
GPU Power: 36 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1416 mW

**** GPU usage ****

GPU HW active frequency: 508 MHz
GPU HW active residency:  12.59% (389 MHz: 8.7% 486 MHz: .38% 648 MHz: .59% 778 MHz: 2.0% 972 MHz: .92% 1296 MHz:   0%)
GPU SW requested state: (P1 :  70% P2 : 2.6% P3 : 6.6% P4 :  19% P5 : 2.4% P6 :   0%)
GPU idle residency:  87.41%
GPU Power: 37 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    96676  0.04      74.02  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96593  0.03      45.74  0.00    0.00               0.98    0.98              0.00
Brave Browser Helper (Renderer)    28631  0.08      59.82  0.00    0.00               0.98    0.98              0.00
ALL_TASKS                          -2     1723.53   46.59  2693.93 19.55              6790.55 589.42            825.89

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1465 MHz
E-Cluster HW active residency:  79.80% (600 MHz:   0% 972 MHz:  44% 1332 MHz:  10% 1704 MHz:  13% 2064 MHz:  33%)
E-Cluster idle residency:  20.20%
CPU 0 frequency: 1486 MHz
CPU 0 active residency:  74.69% (600 MHz:   0% 972 MHz:  30% 1332 MHz: 8.5% 1704 MHz:  11% 2064 MHz:  25%)
CPU 0 idle residency:  25.31%
CPU 1 frequency: 1486 MHz
CPU 1 active residency:  73.14% (600 MHz:   0% 972 MHz:  30% 1332 MHz: 8.2% 1704 MHz:  11% 2064 MHz:  25%)
CPU 1 idle residency:  26.86%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2038 MHz
P0-Cluster HW active residency:  41.13% (600 MHz: 9.0% 828 MHz: .12% 1056 MHz: 2.8% 1296 MHz: 4.0% 1524 MHz: 2.5% 1752 MHz: 7.7% 1980 MHz:  30% 2208 MHz:  13% 2448 MHz:  10% 2676 MHz: 7.1% 2904 MHz: 5.5% 3036 MHz: 3.7% 3132 MHz: 1.3% 3168 MHz: .69% 3228 MHz: 2.0%)
P0-Cluster idle residency:  58.87%
CPU 2 frequency: 2186 MHz
CPU 2 active residency:  29.44% (600 MHz: .13% 828 MHz: .01% 1056 MHz: .96% 1296 MHz: .89% 1524 MHz: .47% 1752 MHz: 2.4% 1980 MHz:  11% 2208 MHz: 3.5% 2448 MHz: 4.0% 2676 MHz: 2.4% 2904 MHz: 2.0% 3036 MHz: 1.2% 3132 MHz: .08% 3168 MHz: .07% 3228 MHz: .70%)
CPU 2 idle residency:  70.56%
CPU 3 frequency: 2260 MHz
CPU 3 active residency:  22.12% (600 MHz: .01% 828 MHz: .01% 1056 MHz: .67% 1296 MHz: .34% 1524 MHz: .17% 1752 MHz: 2.1% 1980 MHz: 7.1% 2208 MHz: 3.3% 2448 MHz: 3.1% 2676 MHz: 1.5% 2904 MHz: 1.1% 3036 MHz: 1.0% 3132 MHz: .01% 3168 MHz: .44% 3228 MHz: 1.5%)
CPU 3 idle residency:  77.88%
CPU 4 frequency: 2169 MHz
CPU 4 active residency:  13.83% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .34% 1296 MHz: .06% 1524 MHz: .08% 1752 MHz: 1.9% 1980 MHz: 5.7% 2208 MHz: 1.1% 2448 MHz: 2.2% 2676 MHz: 1.3% 2904 MHz: .40% 3036 MHz: .56% 3132 MHz: .00% 3168 MHz: .03% 3228 MHz: .18%)
CPU 4 idle residency:  86.17%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1203 MHz
P1-Cluster HW active residency:  14.03% (600 MHz:  59% 828 MHz: .73% 1056 MHz: 2.7% 1296 MHz: 1.8% 1524 MHz: 3.5% 1752 MHz: 6.0% 1980 MHz: 8.6% 2208 MHz: 3.7% 2448 MHz: 4.2% 2676 MHz: 2.5% 2904 MHz: 2.1% 3036 MHz: 3.0% 3132 MHz: .21% 3168 MHz: .39% 3228 MHz: 1.1%)
P1-Cluster idle residency:  85.97%
CPU 5 frequency: 1991 MHz
CPU 5 active residency:  10.72% (600 MHz: .13% 828 MHz: .00% 1056 MHz: .40% 1296 MHz: .61% 1524 MHz: 1.2% 1752 MHz: 1.7% 1980 MHz: 3.1% 2208 MHz: .97% 2448 MHz: 1.3% 2676 MHz: .53% 2904 MHz: .05% 3036 MHz: .61% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .09%)
CPU 5 idle residency:  89.28%
CPU 6 frequency: 1937 MHz
CPU 6 active residency:   6.67% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .60% 1296 MHz: .04% 1524 MHz: .83% 1752 MHz: 1.0% 1980 MHz: 2.2% 2208 MHz: .79% 2448 MHz: .79% 2676 MHz: .16% 2904 MHz: .07% 3036 MHz: .18% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .01%)
CPU 6 idle residency:  93.33%
CPU 7 frequency: 2045 MHz
CPU 7 active residency:   3.57% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .09% 1296 MHz:   0% 1524 MHz: .01% 1752 MHz: .81% 1980 MHz: 1.4% 2208 MHz: .38% 2448 MHz: .77% 2676 MHz: .04% 2904 MHz:   0% 3036 MHz: .03% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 7 idle residency:  96.43%

CPU Power: 1189 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1218 mW

**** GPU usage ****

GPU HW active frequency: 448 MHz
GPU HW active residency:  10.20% (389 MHz: 8.7% 486 MHz:   0% 648 MHz:   0% 778 MHz: 1.3% 972 MHz: .14% 1296 MHz:   0%)
GPU SW requested state: (P1 :  85% P2 :   0% P3 : 2.5% P4 :  12% P5 : .43% P6 :   0%)
GPU idle residency:  89.80%
GPU Power: 29 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
Discord Helper                     8502   0.04      68.47  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    28631  0.05      70.50  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    96676  0.03      61.82  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     1782.04   47.38  2773.15 29.99              6630.62 537.80            828.68

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1436 MHz
E-Cluster HW active residency:  80.85% (600 MHz:   0% 972 MHz:  48% 1332 MHz: 7.7% 1704 MHz:  15% 2064 MHz:  30%)
E-Cluster idle residency:  19.15%
CPU 0 frequency: 1481 MHz
CPU 0 active residency:  75.67% (600 MHz:   0% 972 MHz:  33% 1332 MHz: 5.6% 1704 MHz:  12% 2064 MHz:  26%)
CPU 0 idle residency:  24.33%
CPU 1 frequency: 1479 MHz
CPU 1 active residency:  74.77% (600 MHz:   0% 972 MHz:  33% 1332 MHz: 5.3% 1704 MHz:  11% 2064 MHz:  25%)
CPU 1 idle residency:  25.23%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1971 MHz
P0-Cluster HW active residency:  44.84% (600 MHz: 9.9% 828 MHz: .50% 1056 MHz: 4.6% 1296 MHz: 4.6% 1524 MHz: 3.3% 1752 MHz: 7.4% 1980 MHz:  22% 2208 MHz:  17% 2448 MHz:  16% 2676 MHz: 7.4% 2904 MHz: 4.8% 3036 MHz: 1.3% 3132 MHz: .12% 3168 MHz:   0% 3228 MHz: 1.1%)
P0-Cluster idle residency:  55.16%
CPU 2 frequency: 2112 MHz
CPU 2 active residency:  33.19% (600 MHz: .40% 828 MHz: .01% 1056 MHz: 1.3% 1296 MHz: 2.0% 1524 MHz: 2.6% 1752 MHz: 2.5% 1980 MHz: 7.0% 2208 MHz: 4.5% 2448 MHz: 7.1% 2676 MHz: 2.7% 2904 MHz: 1.8% 3036 MHz: .50% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .69%)
CPU 2 idle residency:  66.81%
CPU 3 frequency: 2152 MHz
CPU 3 active residency:  24.59% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .77% 1296 MHz: 1.8% 1524 MHz: 1.9% 1752 MHz: 1.9% 1980 MHz: 5.1% 2208 MHz: 2.9% 2448 MHz: 4.7% 2676 MHz: 2.3% 2904 MHz: 2.4% 3036 MHz: .57% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .21%)
CPU 3 idle residency:  75.41%
CPU 4 frequency: 2045 MHz
CPU 4 active residency:  14.90% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .53% 1296 MHz: 1.7% 1524 MHz: 1.8% 1752 MHz: .65% 1980 MHz: 3.1% 2208 MHz: 2.0% 2448 MHz: 3.1% 2676 MHz: .84% 2904 MHz: .69% 3036 MHz: .33% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .14%)
CPU 4 idle residency:  85.10%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1204 MHz
P1-Cluster HW active residency:  16.20% (600 MHz:  55% 828 MHz: 2.0% 1056 MHz: 4.9% 1296 MHz: 5.3% 1524 MHz: 3.6% 1752 MHz: 2.5% 1980 MHz: 6.0% 2208 MHz: 5.2% 2448 MHz: 5.7% 2676 MHz: 5.0% 2904 MHz: 3.5% 3036 MHz: .89% 3132 MHz: .06% 3168 MHz:   0% 3228 MHz: .02%)
P1-Cluster idle residency:  83.80%
CPU 5 frequency: 1975 MHz
CPU 5 active residency:  13.83% (600 MHz: .19% 828 MHz: .11% 1056 MHz: 1.1% 1296 MHz: 2.2% 1524 MHz: 1.4% 1752 MHz: .85% 1980 MHz: 1.8% 2208 MHz: 1.8% 2448 MHz: 1.5% 2676 MHz: 1.1% 2904 MHz: 1.4% 3036 MHz: .27% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .18%)
CPU 5 idle residency:  86.17%
CPU 6 frequency: 1820 MHz
CPU 6 active residency:   6.90% (600 MHz: .05% 828 MHz: .00% 1056 MHz: .76% 1296 MHz: 1.5% 1524 MHz: .85% 1752 MHz: .72% 1980 MHz: .79% 2208 MHz: .76% 2448 MHz: .65% 2676 MHz: .26% 2904 MHz: .43% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .14%)
CPU 6 idle residency:  93.10%
CPU 7 frequency: 1567 MHz
CPU 7 active residency:   3.24% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .55% 1296 MHz: 1.2% 1524 MHz: .65% 1752 MHz: .03% 1980 MHz: .26% 2208 MHz: .19% 2448 MHz: .17% 2676 MHz: .09% 2904 MHz: .01% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .09%)
CPU 7 idle residency:  96.76%

CPU Power: 1240 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1269 mW

**** GPU usage ****

GPU HW active frequency: 505 MHz
GPU HW active residency:  10.11% (389 MHz: 6.3% 486 MHz: 1.1% 648 MHz: .63% 778 MHz: 1.8% 972 MHz: .37% 1296 MHz:   0%)
GPU SW requested state: (P1 :  65% P2 : 8.4% P3 : 8.7% P4 :  14% P5 : 4.1% P6 :   0%)
GPU idle residency:  89.89%
GPU Power: 29 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
bluetoothd                         381    0.09      38.36  0.00    0.00               0.98    0.98              0.00
codex                              41664  0.05      60.47  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.03      37.79  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     1996.11   41.95  2589.85 36.46              6444.08 508.51            1118.61

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1510 MHz
E-Cluster HW active residency:  77.16% (600 MHz:   0% 972 MHz:  42% 1332 MHz: 4.8% 1704 MHz:  16% 2064 MHz:  37%)
E-Cluster idle residency:  22.84%
CPU 0 frequency: 1587 MHz
CPU 0 active residency:  71.74% (600 MHz:   0% 972 MHz:  26% 1332 MHz: 3.3% 1704 MHz:  11% 2064 MHz:  32%)
CPU 0 idle residency:  28.26%
CPU 1 frequency: 1579 MHz
CPU 1 active residency:  72.18% (600 MHz:   0% 972 MHz:  26% 1332 MHz: 3.5% 1704 MHz:  11% 2064 MHz:  32%)
CPU 1 idle residency:  27.82%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2141 MHz
P0-Cluster HW active residency:  48.38% (600 MHz: 2.5% 828 MHz:   0% 1056 MHz: 2.1% 1296 MHz: 4.6% 1524 MHz: 6.5% 1752 MHz:  20% 1980 MHz:  17% 2208 MHz: 8.3% 2448 MHz:  15% 2676 MHz: 7.5% 2904 MHz: 5.4% 3036 MHz: 3.5% 3132 MHz: 3.0% 3168 MHz: .95% 3228 MHz: 3.6%)
P0-Cluster idle residency:  51.62%
CPU 2 frequency: 2180 MHz
CPU 2 active residency:  35.60% (600 MHz: .07% 828 MHz:   0% 1056 MHz: .43% 1296 MHz: 1.5% 1524 MHz: 1.9% 1752 MHz: 7.2% 1980 MHz: 6.5% 2208 MHz: 3.0% 2448 MHz: 8.4% 2676 MHz: 1.9% 2904 MHz: .95% 3036 MHz: .63% 3132 MHz: 1.2% 3168 MHz: .68% 3228 MHz: 1.3%)
CPU 2 idle residency:  64.40%
CPU 3 frequency: 2275 MHz
CPU 3 active residency:  26.20% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .22% 1296 MHz: .36% 1524 MHz: .97% 1752 MHz: 4.4% 1980 MHz: 4.6% 2208 MHz: 2.6% 2448 MHz: 7.8% 2676 MHz: 1.3% 2904 MHz: .54% 3036 MHz: .87% 3132 MHz: .68% 3168 MHz: .62% 3228 MHz: 1.3%)
CPU 3 idle residency:  73.80%
CPU 4 frequency: 2324 MHz
CPU 4 active residency:  19.54% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .03% 1296 MHz: .24% 1524 MHz: .18% 1752 MHz: 3.4% 1980 MHz: 3.1% 2208 MHz: 1.9% 2448 MHz: 5.9% 2676 MHz: 1.4% 2904 MHz: 1.4% 3036 MHz: .69% 3132 MHz: .55% 3168 MHz: .21% 3228 MHz: .60%)
CPU 4 idle residency:  80.46%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1314 MHz
P1-Cluster HW active residency:  18.16% (600 MHz:  53% 828 MHz: .78% 1056 MHz: 2.6% 1296 MHz: 4.8% 1524 MHz: 2.8% 1752 MHz: 8.3% 1980 MHz: 5.6% 2208 MHz: 3.3% 2448 MHz: 7.2% 2676 MHz: 3.4% 2904 MHz: 1.7% 3036 MHz: 1.7% 3132 MHz: 1.7% 3168 MHz: 1.7% 3228 MHz: 1.7%)
P1-Cluster idle residency:  81.84%
CPU 5 frequency: 2100 MHz
CPU 5 active residency:  13.27% (600 MHz: .23% 828 MHz: .01% 1056 MHz: .57% 1296 MHz: 1.2% 1524 MHz: .46% 1752 MHz: 2.1% 1980 MHz: 2.4% 2208 MHz: 1.4% 2448 MHz: 2.5% 2676 MHz: .50% 2904 MHz: .47% 3036 MHz: .19% 3132 MHz: .36% 3168 MHz: .45% 3228 MHz: .40%)
CPU 5 idle residency:  86.73%
CPU 6 frequency: 2097 MHz
CPU 6 active residency:   8.66% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .23% 1296 MHz: .35% 1524 MHz: .05% 1752 MHz: 1.6% 1980 MHz: 2.2% 2208 MHz: 1.4% 2448 MHz: 2.0% 2676 MHz: .39% 2904 MHz: .02% 3036 MHz: .04% 3132 MHz: .05% 3168 MHz: .09% 3228 MHz: .11%)
CPU 6 idle residency:  91.34%
CPU 7 frequency: 2289 MHz
CPU 7 active residency:   8.20% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .05% 1296 MHz: .29% 1524 MHz: .01% 1752 MHz: 1.5% 1980 MHz: 1.5% 2208 MHz: 1.2% 2448 MHz: 1.2% 2676 MHz: 1.0% 2904 MHz: .55% 3036 MHz: .39% 3132 MHz: .39% 3168 MHz: .03% 3228 MHz: .14%)
CPU 7 idle residency:  91.80%

CPU Power: 1573 mW
GPU Power: 33 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1605 mW

**** GPU usage ****

GPU HW active frequency: 414 MHz
GPU HW active residency:  11.80% (389 MHz:  11% 486 MHz:   0% 648 MHz: .37% 778 MHz: .46% 972 MHz: .03% 1296 MHz:   0%)
GPU SW requested state: (P1 :  92% P2 : 2.1% P3 : 1.9% P4 : 3.5% P5 : .09% P6 :   0%)
GPU idle residency:  88.20%
GPU Power: 33 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.08      58.99  0.00    0.00               0.97    0.00              0.00
OpenVPN Connect                    855    0.03      65.95  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    96609  0.03      56.56  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     1752.10   51.92  3569.30 27.25              8027.27 579.15            1379.28

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1385 MHz
E-Cluster HW active residency:  74.89% (600 MHz:   0% 972 MHz:  53% 1332 MHz: 8.8% 1704 MHz: 9.5% 2064 MHz:  29%)
E-Cluster idle residency:  25.11%
CPU 0 frequency: 1375 MHz
CPU 0 active residency:  67.60% (600 MHz:   0% 972 MHz:  36% 1332 MHz: 6.0% 1704 MHz: 7.2% 2064 MHz:  18%)
CPU 0 idle residency:  32.40%
CPU 1 frequency: 1369 MHz
CPU 1 active residency:  68.29% (600 MHz:   0% 972 MHz:  37% 1332 MHz: 6.2% 1704 MHz: 7.1% 2064 MHz:  18%)
CPU 1 idle residency:  31.71%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2304 MHz
P0-Cluster HW active residency:  48.42% (600 MHz: 1.4% 828 MHz: .02% 1056 MHz: .53% 1296 MHz: 1.4% 1524 MHz: 4.9% 1752 MHz:  13% 1980 MHz:  18% 2208 MHz:  17% 2448 MHz:  12% 2676 MHz: 9.7% 2904 MHz: 4.1% 3036 MHz: 8.9% 3132 MHz: 4.0% 3168 MHz: .76% 3228 MHz: 4.9%)
P0-Cluster idle residency:  51.58%
CPU 2 frequency: 2462 MHz
CPU 2 active residency:  37.79% (600 MHz: .04% 828 MHz: .00% 1056 MHz: .23% 1296 MHz: .59% 1524 MHz: 2.3% 1752 MHz: 3.5% 1980 MHz: 6.6% 2208 MHz: 4.9% 2448 MHz: 3.1% 2676 MHz: 3.3% 2904 MHz: 1.3% 3036 MHz: 1.1% 3132 MHz: .50% 3168 MHz: .60% 3228 MHz: 9.8%)
CPU 2 idle residency:  62.21%
CPU 3 frequency: 2468 MHz
CPU 3 active residency:  27.76% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .09% 1296 MHz: .24% 1524 MHz: 2.3% 1752 MHz: 2.4% 1980 MHz: 4.1% 2208 MHz: 4.1% 2448 MHz: 2.6% 2676 MHz: 2.0% 2904 MHz: .96% 3036 MHz: .62% 3132 MHz: .36% 3168 MHz: .40% 3228 MHz: 7.6%)
CPU 3 idle residency:  72.24%
CPU 4 frequency: 2580 MHz
CPU 4 active residency:  21.38% (600 MHz: .06% 828 MHz:   0% 1056 MHz: .02% 1296 MHz: .10% 1524 MHz: 1.3% 1752 MHz: 1.4% 1980 MHz: 2.4% 2208 MHz: 2.6% 2448 MHz: 2.5% 2676 MHz: 2.3% 2904 MHz: .98% 3036 MHz: .59% 3132 MHz: .06% 3168 MHz: .35% 3228 MHz: 6.9%)
CPU 4 idle residency:  78.62%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1415 MHz
P1-Cluster HW active residency:  20.19% (600 MHz:  53% 828 MHz: .95% 1056 MHz: 1.9% 1296 MHz: 2.4% 1524 MHz: 5.0% 1752 MHz: 3.7% 1980 MHz: 4.9% 2208 MHz: 4.8% 2448 MHz: 3.1% 2676 MHz: 3.2% 2904 MHz: 1.5% 3036 MHz: 3.1% 3132 MHz: 1.9% 3168 MHz: .19% 3228 MHz:  10%)
P1-Cluster idle residency:  79.81%
CPU 5 frequency: 2495 MHz
CPU 5 active residency:  15.87% (600 MHz: .13% 828 MHz: .20% 1056 MHz: .41% 1296 MHz: .63% 1524 MHz: 1.4% 1752 MHz: .53% 1980 MHz: 1.0% 2208 MHz: 2.1% 2448 MHz: .90% 2676 MHz: 1.6% 2904 MHz: .97% 3036 MHz: .78% 3132 MHz: .03% 3168 MHz: .37% 3228 MHz: 4.8%)
CPU 5 idle residency:  84.13%
CPU 6 frequency: 2486 MHz
CPU 6 active residency:  11.45% (600 MHz: .02% 828 MHz: .17% 1056 MHz: .47% 1296 MHz: .33% 1524 MHz: .77% 1752 MHz: .41% 1980 MHz: .56% 2208 MHz: 1.9% 2448 MHz: 1.3% 2676 MHz: .97% 2904 MHz: .60% 3036 MHz: .44% 3132 MHz: .00% 3168 MHz: .38% 3228 MHz: 3.2%)
CPU 6 idle residency:  88.55%
CPU 7 frequency: 2806 MHz
CPU 7 active residency:   5.80% (600 MHz: .01% 828 MHz: .01% 1056 MHz: .08% 1296 MHz: .02% 1524 MHz: .22% 1752 MHz: .03% 1980 MHz: .18% 2208 MHz: .65% 2448 MHz: .23% 2676 MHz: .81% 2904 MHz: .47% 3036 MHz: .47% 3132 MHz: .03% 3168 MHz: .24% 3228 MHz: 2.4%)
CPU 7 idle residency:  94.20%

CPU Power: 2028 mW
GPU Power: 28 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2057 mW

**** GPU usage ****

GPU HW active frequency: 398 MHz
GPU HW active residency:  10.32% (389 MHz:  10% 486 MHz:   0% 648 MHz:   0% 778 MHz: .25% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  97% P2 :   0% P3 :   0% P4 : 2.4% P5 : .10% P6 :   0%)
GPU idle residency:  89.68%
GPU Power: 28 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.02      41.08  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    87639  0.08      45.93  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96610  0.07      54.35  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2174.79   46.05  3805.05 51.99              7688.57 411.99            1503.71

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1469 MHz
E-Cluster HW active residency:  75.07% (600 MHz:   0% 972 MHz:  49% 1332 MHz: 4.9% 1704 MHz: 5.8% 2064 MHz:  40%)
E-Cluster idle residency:  24.93%
CPU 0 frequency: 1528 MHz
CPU 0 active residency:  69.58% (600 MHz:   0% 972 MHz:  30% 1332 MHz: 3.2% 1704 MHz: 4.9% 2064 MHz:  31%)
CPU 0 idle residency:  30.42%
CPU 1 frequency: 1532 MHz
CPU 1 active residency:  70.24% (600 MHz:   0% 972 MHz:  30% 1332 MHz: 3.1% 1704 MHz: 5.3% 2064 MHz:  31%)
CPU 1 idle residency:  29.76%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2309 MHz
P0-Cluster HW active residency:  55.40% (600 MHz: .35% 828 MHz: .03% 1056 MHz: 1.1% 1296 MHz: .80% 1524 MHz: 1.3% 1752 MHz:  11% 1980 MHz:  12% 2208 MHz:  36% 2448 MHz:  12% 2676 MHz: 7.8% 2904 MHz: 4.4% 3036 MHz: 8.2% 3132 MHz: 2.8% 3168 MHz: .40% 3228 MHz: 2.1%)
P0-Cluster idle residency:  44.60%
CPU 2 frequency: 2386 MHz
CPU 2 active residency:  40.13% (600 MHz: .01% 828 MHz: .00% 1056 MHz: .31% 1296 MHz: .47% 1524 MHz: .68% 1752 MHz: 3.8% 1980 MHz: 4.0% 2208 MHz:  15% 2448 MHz: 3.8% 2676 MHz: 2.3% 2904 MHz: 1.8% 3036 MHz: 2.9% 3132 MHz: .66% 3168 MHz: .47% 3228 MHz: 4.3%)
CPU 2 idle residency:  59.87%
CPU 3 frequency: 2348 MHz
CPU 3 active residency:  31.73% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .33% 1296 MHz: .45% 1524 MHz: .42% 1752 MHz: 2.8% 1980 MHz: 3.5% 2208 MHz:  13% 2448 MHz: 3.4% 2676 MHz: 1.4% 2904 MHz: 1.0% 3036 MHz: 2.0% 3132 MHz: .47% 3168 MHz: .37% 3228 MHz: 2.9%)
CPU 3 idle residency:  68.27%
CPU 4 frequency: 2443 MHz
CPU 4 active residency:  24.01% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .23% 1296 MHz: .58% 1524 MHz: .42% 1752 MHz: 1.3% 1980 MHz: 2.1% 2208 MHz: 8.5% 2448 MHz: 3.0% 2676 MHz: .71% 2904 MHz: .76% 3036 MHz: 1.8% 3132 MHz: .46% 3168 MHz: .39% 3228 MHz: 3.8%)
CPU 4 idle residency:  75.99%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1504 MHz
P1-Cluster HW active residency:  24.94% (600 MHz:  40% 828 MHz: .86% 1056 MHz: 6.4% 1296 MHz: 5.4% 1524 MHz: 4.9% 1752 MHz: 2.8% 1980 MHz: 6.7% 2208 MHz:  10% 2448 MHz: 7.5% 2676 MHz: 2.9% 2904 MHz: 2.0% 3036 MHz: 3.9% 3132 MHz: 1.5% 3168 MHz: .00% 3228 MHz: 4.6%)
P1-Cluster idle residency:  75.06%
CPU 5 frequency: 2135 MHz
CPU 5 active residency:  20.29% (600 MHz: .20% 828 MHz:   0% 1056 MHz: 1.8% 1296 MHz: 2.5% 1524 MHz: 2.3% 1752 MHz: 1.5% 1980 MHz: 1.6% 2208 MHz: 2.6% 2448 MHz: 1.6% 2676 MHz: .78% 2904 MHz: .37% 3036 MHz: .91% 3132 MHz: .34% 3168 MHz: .35% 3228 MHz: 3.3%)
CPU 5 idle residency:  79.71%
CPU 6 frequency: 2057 MHz
CPU 6 active residency:  11.31% (600 MHz: .05% 828 MHz:   0% 1056 MHz: 1.4% 1296 MHz: 1.5% 1524 MHz: 1.0% 1752 MHz: .89% 1980 MHz: 1.5% 2208 MHz: 1.5% 2448 MHz: .59% 2676 MHz: .18% 2904 MHz: .29% 3036 MHz: .63% 3132 MHz: .29% 3168 MHz: .36% 3228 MHz: 1.2%)
CPU 6 idle residency:  88.69%
CPU 7 frequency: 2181 MHz
CPU 7 active residency:  10.36% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .91% 1296 MHz: 1.3% 1524 MHz: 1.2% 1752 MHz: .76% 1980 MHz: .57% 2208 MHz: .99% 2448 MHz: .83% 2676 MHz: .44% 2904 MHz: 1.1% 3036 MHz: .47% 3132 MHz: .49% 3168 MHz: .33% 3228 MHz: .93%)
CPU 7 idle residency:  89.64%

CPU Power: 2108 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2137 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  11.40% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  88.60%
GPU Power: 29 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.05      37.80  0.00    0.00               0.98    0.98              0.00
Brave Browser Helper               11622  0.03      51.99  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper               11621  0.02      47.45  0.00    0.00               0.98    0.98              0.00
ALL_TASKS                          -2     1281.35   49.79  2318.62 20.66              5943.62 646.30            592.18

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1275 MHz
E-Cluster HW active residency:  68.94% (600 MHz:   0% 972 MHz:  67% 1332 MHz: 4.5% 1704 MHz: 7.9% 2064 MHz:  21%)
E-Cluster idle residency:  31.06%
CPU 0 frequency: 1285 MHz
CPU 0 active residency:  62.15% (600 MHz:   0% 972 MHz:  41% 1332 MHz: 3.2% 1704 MHz: 4.7% 2064 MHz:  14%)
CPU 0 idle residency:  37.85%
CPU 1 frequency: 1285 MHz
CPU 1 active residency:  61.61% (600 MHz:   0% 972 MHz:  40% 1332 MHz: 3.1% 1704 MHz: 4.8% 2064 MHz:  13%)
CPU 1 idle residency:  38.39%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2090 MHz
P0-Cluster HW active residency:  37.33% (600 MHz: 4.3% 828 MHz: .44% 1056 MHz: 2.1% 1296 MHz: 3.9% 1524 MHz: 4.1% 1752 MHz: 4.6% 1980 MHz:  29% 2208 MHz:  26% 2448 MHz: 8.4% 2676 MHz: 7.9% 2904 MHz: 3.6% 3036 MHz: 2.3% 3132 MHz: .86% 3168 MHz:   0% 3228 MHz: 2.4%)
P0-Cluster idle residency:  62.67%
CPU 2 frequency: 2162 MHz
CPU 2 active residency:  26.94% (600 MHz: .06% 828 MHz: .00% 1056 MHz: .36% 1296 MHz: 1.5% 1524 MHz: 1.9% 1752 MHz: 2.2% 1980 MHz: 7.9% 2208 MHz: 5.4% 2448 MHz: 1.8% 2676 MHz: 1.7% 2904 MHz: 1.4% 3036 MHz: .54% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: 2.0%)
CPU 2 idle residency:  73.06%
CPU 3 frequency: 2104 MHz
CPU 3 active residency:  16.56% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .26% 1296 MHz: .84% 1524 MHz: 1.4% 1752 MHz: 1.4% 1980 MHz: 5.6% 2208 MHz: 2.8% 2448 MHz: 1.4% 2676 MHz: .92% 2904 MHz: 1.2% 3036 MHz: .47% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .27%)
CPU 3 idle residency:  83.44%
CPU 4 frequency: 2156 MHz
CPU 4 active residency:  10.29% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .15% 1296 MHz: .65% 1524 MHz: .94% 1752 MHz: 1.1% 1980 MHz: 3.2% 2208 MHz: .93% 2448 MHz: .40% 2676 MHz: 1.1% 2904 MHz: .68% 3036 MHz: .29% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .80%)
CPU 4 idle residency:  89.71%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1161 MHz
P1-Cluster HW active residency:   9.48% (600 MHz:  60% 828 MHz: .59% 1056 MHz: 1.0% 1296 MHz: 4.2% 1524 MHz: 6.7% 1752 MHz: 5.8% 1980 MHz: 6.8% 2208 MHz: 5.6% 2448 MHz: 2.6% 2676 MHz: 1.9% 2904 MHz: 1.7% 3036 MHz: 1.2% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: 2.1%)
P1-Cluster idle residency:  90.52%
CPU 5 frequency: 1861 MHz
CPU 5 active residency:   7.22% (600 MHz: .18% 828 MHz: .00% 1056 MHz: .23% 1296 MHz: .96% 1524 MHz: 1.6% 1752 MHz: .87% 1980 MHz: 1.2% 2208 MHz: .85% 2448 MHz: .32% 2676 MHz: .59% 2904 MHz: .27% 3036 MHz: .05% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .11%)
CPU 5 idle residency:  92.78%
CPU 6 frequency: 1897 MHz
CPU 6 active residency:   3.24% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .06% 1296 MHz: .70% 1524 MHz: .49% 1752 MHz: .35% 1980 MHz: .32% 2208 MHz: .81% 2448 MHz: .01% 2676 MHz: .09% 2904 MHz: .28% 3036 MHz: .03% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .07%)
CPU 6 idle residency:  96.76%
CPU 7 frequency: 2129 MHz
CPU 7 active residency:   0.54% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .01% 1524 MHz: .07% 1752 MHz: .13% 1980 MHz: .06% 2208 MHz: .04% 2448 MHz:   0% 2676 MHz: .02% 2904 MHz: .11% 3036 MHz: .06% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  99.46%

CPU Power: 868 mW
GPU Power: 30 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 898 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  13.16% (389 MHz:  13% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  86.84%
GPU Power: 30 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
contactsd                          90875  0.07      26.27  0.00    0.00               0.98    0.00              0.00
contactsd                          90874  0.08      28.14  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.08      35.64  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     1851.71   42.71  2554.81 43.34              6119.14 458.96            1042.83

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1520 MHz
E-Cluster HW active residency:  72.90% (600 MHz:   0% 972 MHz:  40% 1332 MHz: 5.7% 1704 MHz:  19% 2064 MHz:  36%)
E-Cluster idle residency:  27.10%
CPU 0 frequency: 1559 MHz
CPU 0 active residency:  66.95% (600 MHz:   0% 972 MHz:  24% 1332 MHz: 4.1% 1704 MHz:  12% 2064 MHz:  27%)
CPU 0 idle residency:  33.05%
CPU 1 frequency: 1558 MHz
CPU 1 active residency:  67.61% (600 MHz:   0% 972 MHz:  25% 1332 MHz: 4.1% 1704 MHz:  12% 2064 MHz:  27%)
CPU 1 idle residency:  32.39%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2171 MHz
P0-Cluster HW active residency:  47.30% (600 MHz: 5.6% 828 MHz: .32% 1056 MHz: 1.2% 1296 MHz: 2.5% 1524 MHz: 4.1% 1752 MHz:  19% 1980 MHz:  11% 2208 MHz:  14% 2448 MHz:  14% 2676 MHz:  10% 2904 MHz: 6.2% 3036 MHz: 4.9% 3132 MHz: 2.3% 3168 MHz: 1.5% 3228 MHz: 3.1%)
P0-Cluster idle residency:  52.70%
CPU 2 frequency: 2285 MHz
CPU 2 active residency:  32.25% (600 MHz: .08% 828 MHz: .01% 1056 MHz: .34% 1296 MHz: .66% 1524 MHz: 1.7% 1752 MHz: 5.1% 1980 MHz: 3.0% 2208 MHz: 6.2% 2448 MHz: 6.6% 2676 MHz: 2.7% 2904 MHz: 2.1% 3036 MHz: 1.6% 3132 MHz: .90% 3168 MHz: .41% 3228 MHz: .88%)
CPU 2 idle residency:  67.75%
CPU 3 frequency: 2390 MHz
CPU 3 active residency:  26.31% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .24% 1296 MHz: .57% 1524 MHz: 1.3% 1752 MHz: 3.1% 1980 MHz: 2.4% 2208 MHz: 4.6% 2448 MHz: 4.8% 2676 MHz: 1.9% 2904 MHz: 1.8% 3036 MHz: 1.4% 3132 MHz: .50% 3168 MHz: 1.1% 3228 MHz: 2.5%)
CPU 3 idle residency:  73.69%
CPU 4 frequency: 2248 MHz
CPU 4 active residency:  17.06% (600 MHz: .06% 828 MHz:   0% 1056 MHz: .09% 1296 MHz: .24% 1524 MHz: .97% 1752 MHz: 3.3% 1980 MHz: 1.7% 2208 MHz: 2.8% 2448 MHz: 4.3% 2676 MHz: 1.2% 2904 MHz: .87% 3036 MHz: 1.2% 3132 MHz: .37% 3168 MHz: .03% 3228 MHz: .10%)
CPU 4 idle residency:  82.94%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1284 MHz
P1-Cluster HW active residency:  17.21% (600 MHz:  55% 828 MHz:   0% 1056 MHz: 3.2% 1296 MHz: 3.7% 1524 MHz: 5.9% 1752 MHz: 6.7% 1980 MHz: 3.2% 2208 MHz: 3.0% 2448 MHz: 6.6% 2676 MHz: 4.5% 2904 MHz: 4.0% 3036 MHz: 2.4% 3132 MHz: .80% 3168 MHz: .71% 3228 MHz: .65%)
P1-Cluster idle residency:  82.79%
CPU 5 frequency: 1989 MHz
CPU 5 active residency:  12.45% (600 MHz: .19% 828 MHz:   0% 1056 MHz: 1.2% 1296 MHz: 1.1% 1524 MHz: 1.9% 1752 MHz: 1.8% 1980 MHz: .89% 2208 MHz: .56% 2448 MHz: 2.2% 2676 MHz: .98% 2904 MHz: .83% 3036 MHz: .47% 3132 MHz: .31% 3168 MHz: .01% 3228 MHz: .01%)
CPU 5 idle residency:  87.55%
CPU 6 frequency: 2103 MHz
CPU 6 active residency:   8.10% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .36% 1296 MHz: .71% 1524 MHz: .81% 1752 MHz: 1.3% 1980 MHz: .72% 2208 MHz: .72% 2448 MHz: 1.5% 2676 MHz: .84% 2904 MHz: .61% 3036 MHz: .19% 3132 MHz: .31% 3168 MHz:   0% 3228 MHz: .00%)
CPU 6 idle residency:  91.90%
CPU 7 frequency: 2092 MHz
CPU 7 active residency:   4.51% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .15% 1296 MHz: .32% 1524 MHz: .46% 1752 MHz: .63% 1980 MHz: .42% 2208 MHz: .91% 2448 MHz: 1.1% 2676 MHz: .04% 2904 MHz: .09% 3036 MHz: .36% 3132 MHz: .03% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  95.49%

CPU Power: 1503 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1532 mW

**** GPU usage ****

GPU HW active frequency: 401 MHz
GPU HW active residency:  11.25% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz: .36% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  97% P2 :   0% P3 :   0% P4 : 3.2% P5 : .13% P6 :   0%)
GPU idle residency:  88.75%
GPU Power: 29 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
appleh13camerad                    512    0.06      26.47  0.00    0.00               0.98    0.00              0.00
appstoreagent                      39631  0.07      25.89  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.03      36.51  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     1941.86   46.31  2612.07 35.36              6414.75 449.92            1028.48

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1457 MHz
E-Cluster HW active residency:  74.39% (600 MHz:   0% 972 MHz:  49% 1332 MHz: 5.8% 1704 MHz: 8.7% 2064 MHz:  37%)
E-Cluster idle residency:  25.61%
CPU 0 frequency: 1515 MHz
CPU 0 active residency:  69.01% (600 MHz:   0% 972 MHz:  30% 1332 MHz: 3.7% 1704 MHz: 6.6% 2064 MHz:  29%)
CPU 0 idle residency:  30.99%
CPU 1 frequency: 1518 MHz
CPU 1 active residency:  68.42% (600 MHz:   0% 972 MHz:  30% 1332 MHz: 3.8% 1704 MHz: 6.4% 2064 MHz:  29%)
CPU 1 idle residency:  31.58%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2228 MHz
P0-Cluster HW active residency:  49.90% (600 MHz: .40% 828 MHz:   0% 1056 MHz: 5.9% 1296 MHz: 9.6% 1524 MHz: 6.0% 1752 MHz: 3.8% 1980 MHz:  11% 2208 MHz: 9.7% 2448 MHz:  20% 2676 MHz:  17% 2904 MHz: 6.9% 3036 MHz: 5.2% 3132 MHz: 2.4% 3168 MHz: 1.2% 3228 MHz: 1.5%)
P0-Cluster idle residency:  50.10%
CPU 2 frequency: 2090 MHz
CPU 2 active residency:  35.43% (600 MHz: .04% 828 MHz:   0% 1056 MHz: 2.8% 1296 MHz: 5.9% 1524 MHz: 2.2% 1752 MHz: 1.7% 1980 MHz: 4.3% 2208 MHz: 3.6% 2448 MHz: 4.8% 2676 MHz: 5.5% 2904 MHz: 1.2% 3036 MHz: 1.4% 3132 MHz: .53% 3168 MHz: .17% 3228 MHz: 1.4%)
CPU 2 idle residency:  64.57%
CPU 3 frequency: 2097 MHz
CPU 3 active residency:  28.25% (600 MHz: .01% 828 MHz:   0% 1056 MHz: 2.1% 1296 MHz: 5.3% 1524 MHz: 1.6% 1752 MHz: 1.6% 1980 MHz: 2.6% 2208 MHz: 2.8% 2448 MHz: 3.5% 2676 MHz: 3.8% 2904 MHz: 2.5% 3036 MHz: .92% 3132 MHz: .39% 3168 MHz: .06% 3228 MHz: 1.0%)
CPU 3 idle residency:  71.75%
CPU 4 frequency: 2108 MHz
CPU 4 active residency:  18.18% (600 MHz:   0% 828 MHz:   0% 1056 MHz: 1.3% 1296 MHz: 2.8% 1524 MHz: 1.3% 1752 MHz: .91% 1980 MHz: 2.1% 2208 MHz: 2.6% 2448 MHz: 2.1% 2676 MHz: 2.3% 2904 MHz: .45% 3036 MHz: .51% 3132 MHz: .38% 3168 MHz: .05% 3228 MHz: 1.3%)
CPU 4 idle residency:  81.82%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1320 MHz
P1-Cluster HW active residency:  20.49% (600 MHz:  50% 828 MHz:   0% 1056 MHz: 5.8% 1296 MHz: 3.7% 1524 MHz: 6.2% 1752 MHz: 4.1% 1980 MHz: 6.3% 2208 MHz: 6.3% 2448 MHz: 5.2% 2676 MHz: 5.7% 2904 MHz: 2.5% 3036 MHz: .91% 3132 MHz: .65% 3168 MHz: .36% 3228 MHz: 2.1%)
P1-Cluster idle residency:  79.51%
CPU 5 frequency: 1901 MHz
CPU 5 active residency:  16.04% (600 MHz: .18% 828 MHz:   0% 1056 MHz: 1.6% 1296 MHz: 2.3% 1524 MHz: 2.1% 1752 MHz: 1.2% 1980 MHz: 1.9% 2208 MHz: 2.9% 2448 MHz: 1.7% 2676 MHz: 1.3% 2904 MHz: .37% 3036 MHz: .03% 3132 MHz: .19% 3168 MHz: .02% 3228 MHz: .26%)
CPU 5 idle residency:  83.96%
CPU 6 frequency: 1770 MHz
CPU 6 active residency:   8.65% (600 MHz: .08% 828 MHz:   0% 1056 MHz: 1.6% 1296 MHz: 1.5% 1524 MHz: .98% 1752 MHz: .32% 1980 MHz: .88% 2208 MHz: 1.7% 2448 MHz: 1.1% 2676 MHz: .20% 2904 MHz: .16% 3036 MHz: .00% 3132 MHz: .01% 3168 MHz:   0% 3228 MHz: .09%)
CPU 6 idle residency:  91.35%
CPU 7 frequency: 1716 MHz
CPU 7 active residency:   5.82% (600 MHz: .03% 828 MHz:   0% 1056 MHz: .98% 1296 MHz: 1.3% 1524 MHz: .45% 1752 MHz: .76% 1980 MHz: .55% 2208 MHz: .98% 2448 MHz: .55% 2676 MHz: .17% 2904 MHz: .04% 3036 MHz:   0% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .02%)
CPU 7 idle residency:  94.18%

CPU Power: 1464 mW
GPU Power: 28 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1491 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  10.71% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  89.29%
GPU Power: 28 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.06      50.98  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96592  0.04      65.45  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28615  0.03      61.88  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2611.98   66.94  2189.13 15.73              5893.73 0.00              1671.94

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1480 MHz
E-Cluster HW active residency:  73.38% (600 MHz:   0% 972 MHz:  45% 1332 MHz: 6.8% 1704 MHz:  11% 2064 MHz:  37%)
E-Cluster idle residency:  26.62%
CPU 0 frequency: 1514 MHz
CPU 0 active residency:  67.17% (600 MHz:   0% 972 MHz:  28% 1332 MHz: 4.7% 1704 MHz: 7.8% 2064 MHz:  27%)
CPU 0 idle residency:  32.83%
CPU 1 frequency: 1508 MHz
CPU 1 active residency:  65.65% (600 MHz:   0% 972 MHz:  28% 1332 MHz: 4.6% 1704 MHz: 7.3% 2064 MHz:  26%)
CPU 1 idle residency:  34.35%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1851 MHz
P0-Cluster HW active residency:  93.69% (600 MHz:   0% 828 MHz: .23% 1056 MHz:  16% 1296 MHz: 5.0% 1524 MHz:  13% 1752 MHz:  14% 1980 MHz:  16% 2208 MHz:  20% 2448 MHz: 9.9% 2676 MHz: 5.5% 2904 MHz: 1.0% 3036 MHz: .01% 3132 MHz: .13% 3168 MHz:   0% 3228 MHz: .23%)
P0-Cluster idle residency:   6.31%
CPU 2 frequency: 1851 MHz
CPU 2 active residency:  54.39% (600 MHz:   0% 828 MHz: .00% 1056 MHz: 9.8% 1296 MHz: 3.6% 1524 MHz: 5.0% 1752 MHz: 7.6% 1980 MHz: 7.5% 2208 MHz: 9.9% 2448 MHz: 7.2% 2676 MHz: 2.8% 2904 MHz: .65% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .29%)
CPU 2 idle residency:  45.61%
CPU 3 frequency: 1921 MHz
CPU 3 active residency:  43.98% (600 MHz:   0% 828 MHz:   0% 1056 MHz: 7.1% 1296 MHz: 1.3% 1524 MHz: 2.0% 1752 MHz: 4.3% 1980 MHz:  10% 2208 MHz:  12% 2448 MHz: 5.0% 2676 MHz: 1.9% 2904 MHz: .23% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .12%)
CPU 3 idle residency:  56.02%
CPU 4 frequency: 1922 MHz
CPU 4 active residency:  37.51% (600 MHz:   0% 828 MHz:   0% 1056 MHz: 1.9% 1296 MHz: 1.6% 1524 MHz: 6.8% 1752 MHz: 8.4% 1980 MHz: 4.8% 2208 MHz: 6.7% 2448 MHz: 4.3% 2676 MHz: 2.8% 2904 MHz: .26% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 4 idle residency:  62.49%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1043 MHz
P1-Cluster HW active residency:  32.79% (600 MHz:  59% 828 MHz:   0% 1056 MHz:  14% 1296 MHz: 3.6% 1524 MHz: 2.5% 1752 MHz: 4.2% 1980 MHz: 4.7% 2208 MHz: 4.0% 2448 MHz: 5.2% 2676 MHz: 1.9% 2904 MHz: .58% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .17%)
P1-Cluster idle residency:  67.21%
CPU 5 frequency: 1702 MHz
CPU 5 active residency:  27.45% (600 MHz: .18% 828 MHz:   0% 1056 MHz: 8.8% 1296 MHz: 2.3% 1524 MHz: 2.0% 1752 MHz: 2.4% 1980 MHz: 3.5% 2208 MHz: 3.0% 2448 MHz: 3.8% 2676 MHz: .94% 2904 MHz: .53% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .10%)
CPU 5 idle residency:  72.55%
CPU 6 frequency: 1922 MHz
CPU 6 active residency:  13.54% (600 MHz: .06% 828 MHz:   0% 1056 MHz: 1.9% 1296 MHz: 1.1% 1524 MHz: .55% 1752 MHz: 2.2% 1980 MHz: 2.2% 2208 MHz: 1.4% 2448 MHz: 2.9% 2676 MHz: 1.1% 2904 MHz: .15% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 6 idle residency:  86.46%
CPU 7 frequency: 2001 MHz
CPU 7 active residency:   8.97% (600 MHz: .01% 828 MHz:   0% 1056 MHz: 1.1% 1296 MHz: .93% 1524 MHz: .13% 1752 MHz: .65% 1980 MHz: 1.7% 2208 MHz: .90% 2448 MHz: 2.7% 2676 MHz: .84% 2904 MHz: .00% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  91.03%

CPU Power: 2102 mW
GPU Power: 26 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2127 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:   9.73% (389 MHz: 9.7% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  90.27%
GPU Power: 26 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    96590  0.08      50.11  0.00    0.00               0.97    0.00              0.00
wifip2pd                           25354  0.04      47.47  0.00    0.00               0.00    0.00              0.00
Brave Browser Helper (Renderer)    96592  0.03      63.24  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     2709.13   66.14  2895.80 33.17              6571.17 0.00              2426.90

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1543 MHz
E-Cluster HW active residency:  76.84% (600 MHz:   0% 972 MHz:  43% 1332 MHz: 3.1% 1704 MHz: 6.4% 2064 MHz:  47%)
E-Cluster idle residency:  23.16%
CPU 0 frequency: 1597 MHz
CPU 0 active residency:  68.42% (600 MHz:   0% 972 MHz:  27% 1332 MHz: 1.9% 1704 MHz: 4.1% 2064 MHz:  36%)
CPU 0 idle residency:  31.58%
CPU 1 frequency: 1610 MHz
CPU 1 active residency:  68.64% (600 MHz:   0% 972 MHz:  26% 1332 MHz: 2.0% 1704 MHz: 4.1% 2064 MHz:  37%)
CPU 1 idle residency:  31.36%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2222 MHz
P0-Cluster HW active residency:  82.64% (600 MHz: .88% 828 MHz:   0% 1056 MHz: 4.7% 1296 MHz: 3.3% 1524 MHz: 8.5% 1752 MHz: 1.2% 1980 MHz:  13% 2208 MHz:  33% 2448 MHz:  11% 2676 MHz: 7.5% 2904 MHz: 4.6% 3036 MHz: 6.1% 3132 MHz: 3.7% 3168 MHz: .60% 3228 MHz: 2.3%)
P0-Cluster idle residency:  17.36%
CPU 2 frequency: 2331 MHz
CPU 2 active residency:  55.46% (600 MHz: .01% 828 MHz:   0% 1056 MHz: 2.5% 1296 MHz: 1.9% 1524 MHz: 3.9% 1752 MHz: .91% 1980 MHz: 5.2% 2208 MHz:  16% 2448 MHz: 6.4% 2676 MHz: 4.4% 2904 MHz: 3.8% 3036 MHz: 3.4% 3132 MHz: 1.1% 3168 MHz: .63% 3228 MHz: 5.0%)
CPU 2 idle residency:  44.54%
CPU 3 frequency: 2314 MHz
CPU 3 active residency:  38.46% (600 MHz: .02% 828 MHz:   0% 1056 MHz: 1.3% 1296 MHz: 1.1% 1524 MHz: 2.9% 1752 MHz: .82% 1980 MHz: 2.4% 2208 MHz:  15% 2448 MHz: 3.5% 2676 MHz: 2.8% 2904 MHz: 2.2% 3036 MHz: 1.8% 3132 MHz: .69% 3168 MHz: .24% 3228 MHz: 3.4%)
CPU 3 idle residency:  61.54%
CPU 4 frequency: 2203 MHz
CPU 4 active residency:  30.53% (600 MHz:   0% 828 MHz:   0% 1056 MHz: 1.3% 1296 MHz: .89% 1524 MHz: 4.8% 1752 MHz: .77% 1980 MHz: 4.3% 2208 MHz: 8.1% 2448 MHz: 2.5% 2676 MHz: 2.0% 2904 MHz: .97% 3036 MHz: 1.5% 3132 MHz: .53% 3168 MHz: .21% 3228 MHz: 2.6%)
CPU 4 idle residency:  69.47%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1282 MHz
P1-Cluster HW active residency:  35.31% (600 MHz:  49% 828 MHz:   0% 1056 MHz:  12% 1296 MHz: 3.9% 1524 MHz: 6.1% 1752 MHz: 2.6% 1980 MHz: 3.7% 2208 MHz: 5.5% 2448 MHz: 4.5% 2676 MHz: 2.6% 2904 MHz: 1.7% 3036 MHz: 2.9% 3132 MHz: 1.5% 3168 MHz:   0% 3228 MHz: 3.3%)
P1-Cluster idle residency:  64.69%
CPU 5 frequency: 2048 MHz
CPU 5 active residency:  26.42% (600 MHz: .23% 828 MHz:   0% 1056 MHz: 5.2% 1296 MHz: 2.2% 1524 MHz: 2.8% 1752 MHz: 1.0% 1980 MHz: 1.9% 2208 MHz: 3.2% 2448 MHz: 2.1% 2676 MHz: 1.7% 2904 MHz: .85% 3036 MHz: 1.4% 3132 MHz: .66% 3168 MHz:   0% 3228 MHz: 3.2%)
CPU 5 idle residency:  73.58%
CPU 6 frequency: 2182 MHz
CPU 6 active residency:  15.45% (600 MHz: .08% 828 MHz:   0% 1056 MHz: 1.2% 1296 MHz: 1.3% 1524 MHz: 1.8% 1752 MHz: 1.2% 1980 MHz: 1.7% 2208 MHz: 1.8% 2448 MHz: 1.4% 2676 MHz: 1.1% 2904 MHz: .62% 3036 MHz: .99% 3132 MHz: .43% 3168 MHz:   0% 3228 MHz: 1.9%)
CPU 6 idle residency:  84.55%
CPU 7 frequency: 2422 MHz
CPU 7 active residency:   7.20% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .32% 1296 MHz: .07% 1524 MHz: 1.1% 1752 MHz: .13% 1980 MHz: .66% 2208 MHz: .90% 2448 MHz: .52% 2676 MHz: .65% 2904 MHz: .81% 3036 MHz: .86% 3132 MHz: .29% 3168 MHz:   0% 3228 MHz: .94%)
CPU 7 idle residency:  92.80%

CPU Power: 2898 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2927 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  11.22% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  88.78%
GPU Power: 29 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.02      39.92  0.00    0.00               0.98    0.00              0.00
wifip2pd                           25354  0.05      41.12  0.00    0.00               0.00    0.00              0.00
Brave Browser Helper (Renderer)    96593  0.05      75.85  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2687.49   64.55  2303.60 14.79              6001.00 0.00              2132.19

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1534 MHz
E-Cluster HW active residency:  74.00% (600 MHz:   0% 972 MHz:  41% 1332 MHz: 6.4% 1704 MHz: 8.6% 2064 MHz:  44%)
E-Cluster idle residency:  26.00%
CPU 0 frequency: 1626 MHz
CPU 0 active residency:  67.28% (600 MHz:   0% 972 MHz:  22% 1332 MHz: 4.2% 1704 MHz: 6.7% 2064 MHz:  34%)
CPU 0 idle residency:  32.72%
CPU 1 frequency: 1632 MHz
CPU 1 active residency:  67.22% (600 MHz:   0% 972 MHz:  22% 1332 MHz: 4.3% 1704 MHz: 6.5% 2064 MHz:  35%)
CPU 1 idle residency:  32.78%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2113 MHz
P0-Cluster HW active residency:  84.88% (600 MHz: .34% 828 MHz: .45% 1056 MHz: 6.4% 1296 MHz: .74% 1524 MHz: 8.0% 1752 MHz:  27% 1980 MHz:  13% 2208 MHz: 8.0% 2448 MHz:  14% 2676 MHz: 5.1% 2904 MHz: 4.6% 3036 MHz: 2.4% 3132 MHz: 5.1% 3168 MHz: .67% 3228 MHz: 4.1%)
P0-Cluster idle residency:  15.12%
CPU 2 frequency: 2117 MHz
CPU 2 active residency:  58.50% (600 MHz: .01% 828 MHz: .01% 1056 MHz: 2.5% 1296 MHz: .68% 1524 MHz: 5.4% 1752 MHz:  17% 1980 MHz: 6.1% 2208 MHz: 5.9% 2448 MHz: 9.4% 2676 MHz: 1.9% 2904 MHz: 3.3% 3036 MHz: .59% 3132 MHz: .75% 3168 MHz: .54% 3228 MHz: 4.0%)
CPU 2 idle residency:  41.50%
CPU 3 frequency: 2197 MHz
CPU 3 active residency:  38.73% (600 MHz:   0% 828 MHz: .00% 1056 MHz: 2.6% 1296 MHz: .17% 1524 MHz: 2.4% 1752 MHz: 8.9% 1980 MHz: 3.3% 2208 MHz: 3.0% 2448 MHz: 9.7% 2676 MHz: 1.7% 2904 MHz: 2.6% 3036 MHz: .18% 3132 MHz: .78% 3168 MHz: .11% 3228 MHz: 3.3%)
CPU 3 idle residency:  61.27%
CPU 4 frequency: 2124 MHz
CPU 4 active residency:  34.38% (600 MHz:   0% 828 MHz:   0% 1056 MHz: 1.9% 1296 MHz: .09% 1524 MHz: 3.7% 1752 MHz: 8.5% 1980 MHz: 4.6% 2208 MHz: 3.0% 2448 MHz: 6.3% 2676 MHz: .63% 2904 MHz: 2.0% 3036 MHz: .03% 3132 MHz: .46% 3168 MHz: .10% 3228 MHz: 3.1%)
CPU 4 idle residency:  65.62%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1262 MHz
P1-Cluster HW active residency:  35.04% (600 MHz:  52% 828 MHz:   0% 1056 MHz:  14% 1296 MHz: 2.5% 1524 MHz: 3.2% 1752 MHz: 4.0% 1980 MHz: 1.5% 2208 MHz: 4.3% 2448 MHz: 8.1% 2676 MHz: .75% 2904 MHz: 2.6% 3036 MHz: .14% 3132 MHz: 1.3% 3168 MHz: .28% 3228 MHz: 5.6%)
P1-Cluster idle residency:  64.96%
CPU 5 frequency: 1945 MHz
CPU 5 active residency:  27.56% (600 MHz: .19% 828 MHz:   0% 1056 MHz: 7.7% 1296 MHz: 1.7% 1524 MHz: 2.1% 1752 MHz: 1.8% 1980 MHz: .87% 2208 MHz: 2.1% 2448 MHz: 5.9% 2676 MHz: .43% 2904 MHz: 2.0% 3036 MHz:   0% 3132 MHz: .35% 3168 MHz: .03% 3228 MHz: 2.5%)
CPU 5 idle residency:  72.44%
CPU 6 frequency: 2128 MHz
CPU 6 active residency:  14.77% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .52% 1296 MHz: .62% 1524 MHz: 1.7% 1752 MHz: 2.2% 1980 MHz: .82% 2208 MHz: 2.1% 2448 MHz: 5.4% 2676 MHz: .07% 2904 MHz: .66% 3036 MHz:   0% 3132 MHz: .01% 3168 MHz: .28% 3228 MHz: .35%)
CPU 6 idle residency:  85.23%
CPU 7 frequency: 2237 MHz
CPU 7 active residency:  11.11% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .31% 1296 MHz: .72% 1524 MHz: 1.3% 1752 MHz: .84% 1980 MHz: .19% 2208 MHz: 1.1% 2448 MHz: 4.7% 2676 MHz: .02% 2904 MHz: 1.4% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz: .03% 3228 MHz: .54%)
CPU 7 idle residency:  88.89%

CPU Power: 2633 mW
GPU Power: 34 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2666 mW

**** GPU usage ****

GPU HW active frequency: 434 MHz
GPU HW active residency:  12.50% (389 MHz:  11% 486 MHz: .43% 648 MHz: .30% 778 MHz: .88% 972 MHz: .18% 1296 MHz:   0%)
GPU SW requested state: (P1 :  85% P2 : 3.5% P3 : 6.3% P4 : 4.9% P5 : .21% P6 :   0%)
GPU idle residency:  87.50%
GPU Power: 34 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
amsaccountsd                       39632  0.07      22.42  0.00    0.00               0.98    0.00              0.00
mediaanalysisd                     36014  0.08      21.00  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.02      41.85  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2548.85   63.52  2699.16 36.26              6162.79 0.00              2069.43

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1446 MHz
E-Cluster HW active residency:  61.11% (600 MHz:   0% 972 MHz:  51% 1332 MHz: 5.6% 1704 MHz: 5.4% 2064 MHz:  38%)
E-Cluster idle residency:  38.89%
CPU 0 frequency: 1527 MHz
CPU 0 active residency:  55.52% (600 MHz:   0% 972 MHz:  24% 1332 MHz: 3.4% 1704 MHz: 4.1% 2064 MHz:  24%)
CPU 0 idle residency:  44.48%
CPU 1 frequency: 1517 MHz
CPU 1 active residency:  54.21% (600 MHz:   0% 972 MHz:  24% 1332 MHz: 3.2% 1704 MHz: 3.6% 2064 MHz:  24%)
CPU 1 idle residency:  45.79%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2081 MHz
P0-Cluster HW active residency:  92.64% (600 MHz:   0% 828 MHz: .07% 1056 MHz: 4.8% 1296 MHz: 6.5% 1524 MHz: 9.0% 1752 MHz:  20% 1980 MHz:  14% 2208 MHz:  10% 2448 MHz:  13% 2676 MHz: 9.7% 2904 MHz: 5.4% 3036 MHz: 5.2% 3132 MHz: 1.0% 3168 MHz: .58% 3228 MHz: .19%)
P0-Cluster idle residency:   7.36%
CPU 2 frequency: 2054 MHz
CPU 2 active residency:  62.07% (600 MHz:   0% 828 MHz: .00% 1056 MHz: 4.4% 1296 MHz: 4.2% 1524 MHz: 5.1% 1752 MHz:  14% 1980 MHz: 7.2% 2208 MHz: 6.2% 2448 MHz: 8.5% 2676 MHz: 5.0% 2904 MHz: 3.4% 3036 MHz: 3.4% 3132 MHz: .54% 3168 MHz: .26% 3228 MHz: .31%)
CPU 2 idle residency:  37.93%
CPU 3 frequency: 2142 MHz
CPU 3 active residency:  39.65% (600 MHz:   0% 828 MHz: .01% 1056 MHz: .88% 1296 MHz: 1.2% 1524 MHz: 3.1% 1752 MHz: 9.4% 1980 MHz: 5.5% 2208 MHz: 4.9% 2448 MHz: 5.0% 2676 MHz: 4.8% 2904 MHz: 2.2% 3036 MHz: 1.6% 3132 MHz: .45% 3168 MHz: .24% 3228 MHz: .26%)
CPU 3 idle residency:  60.35%
CPU 4 frequency: 2178 MHz
CPU 4 active residency:  38.46% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .50% 1296 MHz: 2.6% 1524 MHz: 2.7% 1752 MHz: 5.4% 1980 MHz: 6.8% 2208 MHz: 4.0% 2448 MHz: 7.6% 2676 MHz: 3.6% 2904 MHz: 2.8% 3036 MHz: 1.6% 3132 MHz: .41% 3168 MHz: .30% 3228 MHz: .14%)
CPU 4 idle residency:  61.54%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1329 MHz
P1-Cluster HW active residency:  42.03% (600 MHz:  42% 828 MHz:   0% 1056 MHz:  17% 1296 MHz: 3.1% 1524 MHz: 3.6% 1752 MHz: 6.0% 1980 MHz: 4.3% 2208 MHz: 7.6% 2448 MHz: 6.4% 2676 MHz: 3.5% 2904 MHz: 2.1% 3036 MHz: 3.0% 3132 MHz: .89% 3168 MHz: .04% 3228 MHz: .21%)
P1-Cluster idle residency:  57.97%
CPU 5 frequency: 1815 MHz
CPU 5 active residency:  32.65% (600 MHz: .16% 828 MHz:   0% 1056 MHz: 9.3% 1296 MHz: 2.2% 1524 MHz: 2.0% 1752 MHz: 3.8% 1980 MHz: 2.9% 2208 MHz: 4.6% 2448 MHz: 3.2% 2676 MHz: 1.6% 2904 MHz: 1.1% 3036 MHz: 1.2% 3132 MHz: .52% 3168 MHz: .04% 3228 MHz: .07%)
CPU 5 idle residency:  67.35%
CPU 6 frequency: 2028 MHz
CPU 6 active residency:  16.79% (600 MHz: .06% 828 MHz:   0% 1056 MHz: 1.5% 1296 MHz: 1.2% 1524 MHz: 1.6% 1752 MHz: 3.0% 1980 MHz: 1.8% 2208 MHz: 2.6% 2448 MHz: 1.6% 2676 MHz: .94% 2904 MHz: .92% 3036 MHz: 1.1% 3132 MHz: .23% 3168 MHz: .00% 3228 MHz: .26%)
CPU 6 idle residency:  83.21%
CPU 7 frequency: 2060 MHz
CPU 7 active residency:   7.84% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .39% 1296 MHz: .85% 1524 MHz: 1.0% 1752 MHz: 1.2% 1980 MHz: .17% 2208 MHz: 1.4% 2448 MHz: 1.2% 2676 MHz: .55% 2904 MHz: .23% 3036 MHz: .37% 3132 MHz: .30% 3168 MHz:   0% 3228 MHz: .08%)
CPU 7 idle residency:  92.16%

CPU Power: 2643 mW
GPU Power: 32 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2676 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  12.16% (389 MHz:  12% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  87.84%
GPU Power: 32 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
appleh13camerad                    512    0.07      22.88  0.00    0.00               0.98    0.00              0.00
amsengagementd                     39635  0.16      43.93  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.04      39.58  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2369.91   43.53  2182.65 23.52              5241.50 0.00              878.25

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1516 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:  39% 1332 MHz: 9.5% 1704 MHz:  16% 2064 MHz:  36%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 1550 MHz
CPU 0 active residency:  86.89% (600 MHz:   0% 972 MHz:  31% 1332 MHz: 8.5% 1704 MHz:  13% 2064 MHz:  34%)
CPU 0 idle residency:  13.11%
CPU 1 frequency: 1563 MHz
CPU 1 active residency:  84.07% (600 MHz:   0% 972 MHz:  28% 1332 MHz: 8.4% 1704 MHz:  14% 2064 MHz:  33%)
CPU 1 idle residency:  15.93%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1984 MHz
P0-Cluster HW active residency:  44.96% (600 MHz: 3.4% 828 MHz: .02% 1056 MHz: 6.4% 1296 MHz: 2.9% 1524 MHz:  11% 1752 MHz:  17% 1980 MHz:  16% 2208 MHz:  13% 2448 MHz:  16% 2676 MHz: 9.4% 2904 MHz: 3.3% 3036 MHz: .46% 3132 MHz: .05% 3168 MHz:   0% 3228 MHz: .95%)
P0-Cluster idle residency:  55.04%
CPU 2 frequency: 2168 MHz
CPU 2 active residency:  33.26% (600 MHz: .10% 828 MHz: .00% 1056 MHz: 1.4% 1296 MHz: .83% 1524 MHz: 2.3% 1752 MHz: 3.1% 1980 MHz: 6.9% 2208 MHz: 3.9% 2448 MHz: 7.5% 2676 MHz: 5.4% 2904 MHz: 1.7% 3036 MHz: .04% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .14%)
CPU 2 idle residency:  66.74%
CPU 3 frequency: 2218 MHz
CPU 3 active residency:  21.86% (600 MHz: .09% 828 MHz: .00% 1056 MHz: .43% 1296 MHz: .58% 1524 MHz: 1.5% 1752 MHz: 1.8% 1980 MHz: 4.5% 2208 MHz: 2.2% 2448 MHz: 5.2% 2676 MHz: 3.9% 2904 MHz: 1.6% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .05%)
CPU 3 idle residency:  78.14%
CPU 4 frequency: 2288 MHz
CPU 4 active residency:  13.84% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .21% 1296 MHz: .12% 1524 MHz: .73% 1752 MHz: .47% 1980 MHz: 3.1% 2208 MHz: 1.3% 2448 MHz: 4.3% 2676 MHz: 2.9% 2904 MHz: .68% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 4 idle residency:  86.16%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1079 MHz
P1-Cluster HW active residency:  14.48% (600 MHz:  60% 828 MHz: .29% 1056 MHz: 8.5% 1296 MHz: 6.6% 1524 MHz: 3.5% 1752 MHz: 3.0% 1980 MHz: 4.0% 2208 MHz: 3.5% 2448 MHz: 5.6% 2676 MHz: 2.1% 2904 MHz: 2.0% 3036 MHz: .22% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .67%)
P1-Cluster idle residency:  85.52%
CPU 5 frequency: 1716 MHz
CPU 5 active residency:  11.64% (600 MHz: .18% 828 MHz: .01% 1056 MHz: 3.4% 1296 MHz: 1.4% 1524 MHz: .59% 1752 MHz: .81% 1980 MHz: 1.2% 2208 MHz: 1.3% 2448 MHz: 2.2% 2676 MHz: .19% 2904 MHz: .35% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 5 idle residency:  88.36%
CPU 6 frequency: 1753 MHz
CPU 6 active residency:   5.50% (600 MHz: .07% 828 MHz:   0% 1056 MHz: 1.3% 1296 MHz: .83% 1524 MHz: .37% 1752 MHz: .19% 1980 MHz: .50% 2208 MHz: 1.2% 2448 MHz: .74% 2676 MHz: .01% 2904 MHz: .22% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 6 idle residency:  94.50%
CPU 7 frequency: 1718 MHz
CPU 7 active residency:   3.02% (600 MHz: .03% 828 MHz:   0% 1056 MHz: .78% 1296 MHz: .29% 1524 MHz: .32% 1752 MHz: .15% 1980 MHz: .36% 2208 MHz: .86% 2448 MHz: .20% 2676 MHz: .01% 2904 MHz: .04% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  96.98%

CPU Power: 1242 mW
GPU Power: 34 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1276 mW

**** GPU usage ****

GPU HW active frequency: 400 MHz
GPU HW active residency:  12.99% (389 MHz:  13% 486 MHz:   0% 648 MHz:   0% 778 MHz: .37% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  97% P2 :   0% P3 :   0% P4 : 2.9% P5 : .19% P6 :   0%)
GPU idle residency:  87.01%
GPU Power: 34 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
replayd                            79603  0.04      22.94  0.00    0.00               0.98    0.00              0.00
iconservicesagent                  43618  0.04      29.17  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.03      36.04  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     3053.98   51.41  3382.13 28.32              8019.24 0.00              1713.70

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 2062 MHz
E-Cluster HW active residency:  99.91% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz: .65% 2064 MHz:  99%)
E-Cluster idle residency:   0.09%
CPU 0 frequency: 2062 MHz
CPU 0 active residency:  99.67% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz: .65% 2064 MHz:  99%)
CPU 0 idle residency:   0.33%
CPU 1 frequency: 2062 MHz
CPU 1 active residency:  99.53% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz: .65% 2064 MHz:  99%)
CPU 1 idle residency:   0.47%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2361 MHz
P0-Cluster HW active residency:  55.26% (600 MHz: .20% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: 3.1% 1524 MHz: 3.3% 1752 MHz: 8.3% 1980 MHz:  12% 2208 MHz:  27% 2448 MHz:  14% 2676 MHz:  11% 2904 MHz: 6.9% 3036 MHz: 6.2% 3132 MHz: 4.2% 3168 MHz: 1.2% 3228 MHz: 3.7%)
P0-Cluster idle residency:  44.74%
CPU 2 frequency: 2400 MHz
CPU 2 active residency:  39.38% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .54% 1524 MHz: 1.3% 1752 MHz: 2.5% 1980 MHz: 4.2% 2208 MHz:  13% 2448 MHz: 5.2% 2676 MHz: 3.6% 2904 MHz: 2.9% 3036 MHz: 3.1% 3132 MHz: .70% 3168 MHz: .35% 3228 MHz: 2.5%)
CPU 2 idle residency:  60.62%
CPU 3 frequency: 2411 MHz
CPU 3 active residency:  31.71% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .57% 1524 MHz: .64% 1752 MHz: 2.0% 1980 MHz: 4.1% 2208 MHz: 8.0% 2448 MHz: 5.3% 2676 MHz: 4.1% 2904 MHz: 2.3% 3036 MHz: 1.2% 3132 MHz: .73% 3168 MHz: .06% 3228 MHz: 2.7%)
CPU 3 idle residency:  68.29%
CPU 4 frequency: 2450 MHz
CPU 4 active residency:  20.12% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .63% 1524 MHz: .35% 1752 MHz: 1.2% 1980 MHz: 1.4% 2208 MHz: 5.2% 2448 MHz: 3.6% 2676 MHz: 2.8% 2904 MHz: 1.4% 3036 MHz: 1.5% 3132 MHz: .23% 3168 MHz: .01% 3228 MHz: 1.9%)
CPU 4 idle residency:  79.88%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1452 MHz
P1-Cluster HW active residency:  20.16% (600 MHz:  49% 828 MHz: .39% 1056 MHz: 1.1% 1296 MHz: 2.6% 1524 MHz: 4.7% 1752 MHz: 4.8% 1980 MHz: 5.4% 2208 MHz:  12% 2448 MHz: 4.5% 2676 MHz: 3.4% 2904 MHz: 3.3% 3036 MHz: 3.3% 3132 MHz: .89% 3168 MHz: .42% 3228 MHz: 4.6%)
P1-Cluster idle residency:  79.84%
CPU 5 frequency: 2261 MHz
CPU 5 active residency:  15.91% (600 MHz: .16% 828 MHz:   0% 1056 MHz: .23% 1296 MHz: .72% 1524 MHz: 1.7% 1752 MHz: .78% 1980 MHz: 2.0% 2208 MHz: 3.0% 2448 MHz: 2.1% 2676 MHz: 2.5% 2904 MHz: 1.1% 3036 MHz: .74% 3132 MHz: .22% 3168 MHz: .01% 3228 MHz: .68%)
CPU 5 idle residency:  84.09%
CPU 6 frequency: 2292 MHz
CPU 6 active residency:   8.34% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .19% 1296 MHz: .56% 1524 MHz: .85% 1752 MHz: .34% 1980 MHz: .54% 2208 MHz: 1.2% 2448 MHz: 1.2% 2676 MHz: 1.7% 2904 MHz: 1.1% 3036 MHz: .48% 3132 MHz: .05% 3168 MHz: .00% 3228 MHz: .07%)
CPU 6 idle residency:  91.66%
CPU 7 frequency: 2260 MHz
CPU 7 active residency:   4.26% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .19% 1296 MHz: .12% 1524 MHz: .85% 1752 MHz: .02% 1980 MHz: .06% 2208 MHz: .84% 2448 MHz: .54% 2676 MHz: .76% 2904 MHz: .20% 3036 MHz: .59% 3132 MHz: .02% 3168 MHz: .00% 3228 MHz: .05%)
CPU 7 idle residency:  95.74%

CPU Power: 2291 mW
GPU Power: 30 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2321 mW

**** GPU usage ****

GPU HW active frequency: 396 MHz
GPU HW active residency:  11.54% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz: .22% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  98% P2 :   0% P3 :   0% P4 : 1.9% P5 : .09% P6 :   0%)
GPU idle residency:  88.46%
GPU Power: 31 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=orbstack
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
replayd                            79603  0.07      21.09  0.00    0.00               0.98    0.00              0.00
OpenVPN Connect Helper (GPU)       861    0.08      85.71  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.04      35.13  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2163.85   55.59  2647.35 22.49              6839.89 33.25             945.33

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1319 MHz
E-Cluster HW active residency:  99.87% (600 MHz:   0% 972 MHz:  60% 1332 MHz: 8.9% 1704 MHz: 7.8% 2064 MHz:  24%)
E-Cluster idle residency:   0.13%
CPU 0 frequency: 1330 MHz
CPU 0 active residency:  86.88% (600 MHz:   0% 972 MHz:  51% 1332 MHz: 8.0% 1704 MHz: 7.1% 2064 MHz:  21%)
CPU 0 idle residency:  13.12%
CPU 1 frequency: 1321 MHz
CPU 1 active residency:  87.86% (600 MHz:   0% 972 MHz:  52% 1332 MHz: 8.0% 1704 MHz: 6.9% 2064 MHz:  21%)
CPU 1 idle residency:  12.14%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2354 MHz
P0-Cluster HW active residency:  40.06% (600 MHz: 1.9% 828 MHz:   0% 1056 MHz: .71% 1296 MHz: 5.1% 1524 MHz: .98% 1752 MHz: 1.7% 1980 MHz:  11% 2208 MHz:  22% 2448 MHz:  25% 2676 MHz:  14% 2904 MHz: 7.0% 3036 MHz: 3.1% 3132 MHz: 2.6% 3168 MHz: .80% 3228 MHz: 3.8%)
P0-Cluster idle residency:  59.94%
CPU 2 frequency: 2365 MHz
CPU 2 active residency:  25.79% (600 MHz: .11% 828 MHz:   0% 1056 MHz: .24% 1296 MHz: 1.2% 1524 MHz: .69% 1752 MHz: .32% 1980 MHz: 4.1% 2208 MHz: 4.8% 2448 MHz: 5.3% 2676 MHz: 4.4% 2904 MHz: 2.0% 3036 MHz: .55% 3132 MHz: .57% 3168 MHz: .13% 3228 MHz: 1.3%)
CPU 2 idle residency:  74.21%
CPU 3 frequency: 2508 MHz
CPU 3 active residency:  20.65% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .10% 1296 MHz: .26% 1524 MHz: .14% 1752 MHz: .27% 1980 MHz: 3.1% 2208 MHz: 3.3% 2448 MHz: 4.2% 2676 MHz: 4.3% 2904 MHz: 1.7% 3036 MHz: .39% 3132 MHz: .47% 3168 MHz: .04% 3228 MHz: 2.5%)
CPU 3 idle residency:  79.35%
CPU 4 frequency: 2548 MHz
CPU 4 active residency:  11.90% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .02% 1296 MHz: .02% 1524 MHz: .02% 1752 MHz: .03% 1980 MHz: 2.4% 2208 MHz: 1.8% 2448 MHz: 2.2% 2676 MHz: 2.0% 2904 MHz: 1.0% 3036 MHz: .33% 3132 MHz: .10% 3168 MHz: .02% 3228 MHz: 2.1%)
CPU 4 idle residency:  88.10%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1277 MHz
P1-Cluster HW active residency:  11.28% (600 MHz:  59% 828 MHz: .40% 1056 MHz: 2.0% 1296 MHz: 3.3% 1524 MHz: 2.4% 1752 MHz: 2.1% 1980 MHz: 6.3% 2208 MHz: 4.4% 2448 MHz: 5.7% 2676 MHz: 3.4% 2904 MHz: 3.4% 3036 MHz: .42% 3132 MHz: 1.2% 3168 MHz: .42% 3228 MHz: 5.0%)
P1-Cluster idle residency:  88.72%
CPU 5 frequency: 2111 MHz
CPU 5 active residency:  10.45% (600 MHz: .17% 828 MHz: .00% 1056 MHz: .12% 1296 MHz: .94% 1524 MHz: 1.1% 1752 MHz: 1.0% 1980 MHz: 1.6% 2208 MHz: 1.7% 2448 MHz: 1.7% 2676 MHz: .79% 2904 MHz: .43% 3036 MHz: .37% 3132 MHz: .19% 3168 MHz: .00% 3228 MHz: .29%)
CPU 5 idle residency:  89.55%
CPU 6 frequency: 2173 MHz
CPU 6 active residency:   2.43% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .23% 1524 MHz: .21% 1752 MHz: .08% 1980 MHz: .39% 2208 MHz: .43% 2448 MHz: .55% 2676 MHz: .18% 2904 MHz: .09% 3036 MHz: .16% 3132 MHz: .00% 3168 MHz: .00% 3228 MHz: .05%)
CPU 6 idle residency:  97.57%
CPU 7 frequency: 2323 MHz
CPU 7 active residency:   0.73% (600 MHz: .01% 828 MHz:   0% 1056 MHz:   0% 1296 MHz: .03% 1524 MHz: .04% 1752 MHz: .00% 1980 MHz: .18% 2208 MHz: .04% 2448 MHz: .21% 2676 MHz: .06% 2904 MHz: .02% 3036 MHz: .11% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .02%)
CPU 7 idle residency:  99.27%

CPU Power: 1286 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1315 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  11.50% (389 MHz:  12% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  88.50%
GPU Power: 29 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.03      46.33  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28614  0.02      50.78  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96592  0.02      45.88  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2697.77   50.32  2456.24 26.31              6660.39 7.79              1151.79

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 2064 MHz
E-Cluster HW active residency:  99.96% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz: 100%)
E-Cluster idle residency:   0.04%
CPU 0 frequency: 2064 MHz
CPU 0 active residency:  99.42% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz:  99%)
CPU 0 idle residency:   0.58%
CPU 1 frequency: 2064 MHz
CPU 1 active residency:  99.41% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz:  99%)
CPU 1 idle residency:   0.59%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2171 MHz
P0-Cluster HW active residency:  42.03% (600 MHz: .93% 828 MHz:   0% 1056 MHz: .86% 1296 MHz: 3.7% 1524 MHz: 8.4% 1752 MHz: 6.8% 1980 MHz:  24% 2208 MHz:  23% 2448 MHz:  11% 2676 MHz: 8.7% 2904 MHz: 6.4% 3036 MHz: 3.3% 3132 MHz: .72% 3168 MHz:   0% 3228 MHz: 1.9%)
P0-Cluster idle residency:  57.97%
CPU 2 frequency: 2317 MHz
CPU 2 active residency:  31.30% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .12% 1296 MHz: .38% 1524 MHz: 2.2% 1752 MHz: 3.4% 1980 MHz: 5.6% 2208 MHz: 5.3% 2448 MHz: 3.7% 2676 MHz: 3.4% 2904 MHz: 3.1% 3036 MHz: 1.8% 3132 MHz: .23% 3168 MHz:   0% 3228 MHz: 1.9%)
CPU 2 idle residency:  68.70%
CPU 3 frequency: 2337 MHz
CPU 3 active residency:  20.75% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .05% 1296 MHz: .76% 1524 MHz: .46% 1752 MHz: 2.3% 1980 MHz: 3.7% 2208 MHz: 3.9% 2448 MHz: 1.7% 2676 MHz: 2.9% 2904 MHz: 2.2% 3036 MHz: 2.1% 3132 MHz: .29% 3168 MHz:   0% 3228 MHz: .39%)
CPU 3 idle residency:  79.25%
CPU 4 frequency: 2418 MHz
CPU 4 active residency:  13.06% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .17% 1524 MHz: .09% 1752 MHz: 1.7% 1980 MHz: 2.6% 2208 MHz: 1.6% 2448 MHz: 1.0% 2676 MHz: 1.4% 2904 MHz: 2.4% 3036 MHz: 1.9% 3132 MHz: .17% 3168 MHz:   0% 3228 MHz: .05%)
CPU 4 idle residency:  86.94%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1271 MHz
P1-Cluster HW active residency:  12.59% (600 MHz:  58% 828 MHz: .43% 1056 MHz: 2.4% 1296 MHz: 3.5% 1524 MHz: 3.5% 1752 MHz: 3.5% 1980 MHz: 4.3% 2208 MHz: 6.1% 2448 MHz: 3.6% 2676 MHz: 3.5% 2904 MHz: 5.1% 3036 MHz: 3.1% 3132 MHz: .60% 3168 MHz:   0% 3228 MHz: 2.2%)
P1-Cluster idle residency:  87.41%
CPU 5 frequency: 2245 MHz
CPU 5 active residency:   9.17% (600 MHz: .19% 828 MHz:   0% 1056 MHz: .24% 1296 MHz: .85% 1524 MHz: .43% 1752 MHz: 1.2% 1980 MHz: .63% 2208 MHz: 1.2% 2448 MHz: 1.0% 2676 MHz: .55% 2904 MHz: 1.9% 3036 MHz: .94% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz: .09%)
CPU 5 idle residency:  90.83%
CPU 6 frequency: 2410 MHz
CPU 6 active residency:   5.93% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .11% 1296 MHz: .01% 1524 MHz: .20% 1752 MHz: .48% 1980 MHz: 1.3% 2208 MHz: .32% 2448 MHz: .59% 2676 MHz: .95% 2904 MHz: 1.1% 3036 MHz: .80% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .02%)
CPU 6 idle residency:  94.07%
CPU 7 frequency: 2499 MHz
CPU 7 active residency:   1.65% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .01% 1524 MHz: .03% 1752 MHz: .30% 1980 MHz: .17% 2208 MHz: .05% 2448 MHz: .14% 2676 MHz: .04% 2904 MHz: .45% 3036 MHz: .42% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .01%)
CPU 7 idle residency:  98.35%

CPU Power: 1608 mW
GPU Power: 30 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1638 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  12.08% (389 MHz:  12% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 : .13% P6 :   0%)
GPU idle residency:  87.92%
GPU Power: 30 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    28615  0.02      62.23  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96592  0.02      52.47  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28614  0.03      57.61  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2766.27   54.52  2793.15 25.54              8205.54 0.00              1254.38

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 2064 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz: 100%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 2064 MHz
CPU 0 active residency:  99.99% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz: 100%)
CPU 0 idle residency:   0.01%
CPU 1 frequency: 2064 MHz
CPU 1 active residency: 100.00% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz: 100%)
CPU 1 idle residency:   0.00%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2284 MHz
P0-Cluster HW active residency:  41.20% (600 MHz: 3.4% 828 MHz:   0% 1056 MHz: 1.3% 1296 MHz: 1.3% 1524 MHz: 2.1% 1752 MHz: 2.1% 1980 MHz:  17% 2208 MHz:  32% 2448 MHz:  13% 2676 MHz:  12% 2904 MHz: 4.5% 3036 MHz: 5.1% 3132 MHz: 3.2% 3168 MHz: .56% 3228 MHz: 2.3%)
P0-Cluster idle residency:  58.80%
CPU 2 frequency: 2389 MHz
CPU 2 active residency:  30.77% (600 MHz: .13% 828 MHz:   0% 1056 MHz: .52% 1296 MHz: .36% 1524 MHz: .22% 1752 MHz: .41% 1980 MHz: 5.0% 2208 MHz:  11% 2448 MHz: 2.9% 2676 MHz: 3.2% 2904 MHz: 1.4% 3036 MHz: 1.5% 3132 MHz: 1.1% 3168 MHz: .46% 3228 MHz: 2.4%)
CPU 2 idle residency:  69.23%
CPU 3 frequency: 2435 MHz
CPU 3 active residency:  20.85% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .15% 1296 MHz: .29% 1524 MHz: .08% 1752 MHz: .22% 1980 MHz: 3.0% 2208 MHz: 7.3% 2448 MHz: 2.5% 2676 MHz: 2.4% 2904 MHz: 1.5% 3036 MHz: 1.2% 3132 MHz: .47% 3168 MHz: .27% 3228 MHz: 1.5%)
CPU 3 idle residency:  79.15%
CPU 4 frequency: 2399 MHz
CPU 4 active residency:  14.42% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .12% 1296 MHz: .15% 1524 MHz: .04% 1752 MHz: .08% 1980 MHz: 1.8% 2208 MHz: 6.1% 2448 MHz: 1.4% 2676 MHz: 2.2% 2904 MHz: .85% 3036 MHz: .62% 3132 MHz: .27% 3168 MHz: .07% 3228 MHz: .69%)
CPU 4 idle residency:  85.58%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1215 MHz
P1-Cluster HW active residency:  14.63% (600 MHz:  62% 828 MHz: .39% 1056 MHz: 2.1% 1296 MHz: 1.9% 1524 MHz: 2.9% 1752 MHz: 2.5% 1980 MHz: 5.9% 2208 MHz: 6.5% 2448 MHz: 3.0% 2676 MHz: 3.4% 2904 MHz: 1.9% 3036 MHz: 1.8% 3132 MHz: 1.8% 3168 MHz: .38% 3228 MHz: 2.9%)
P1-Cluster idle residency:  85.37%
CPU 5 frequency: 2314 MHz
CPU 5 active residency:  11.15% (600 MHz: .14% 828 MHz:   0% 1056 MHz: .75% 1296 MHz: .47% 1524 MHz: .69% 1752 MHz: .29% 1980 MHz: 1.0% 2208 MHz: 1.9% 2448 MHz: 1.1% 2676 MHz: 1.9% 2904 MHz: 1.0% 3036 MHz: .76% 3132 MHz: .58% 3168 MHz: .29% 3228 MHz: .24%)
CPU 5 idle residency:  88.85%
CPU 6 frequency: 2230 MHz
CPU 6 active residency:   5.73% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .51% 1296 MHz: .12% 1524 MHz: .14% 1752 MHz: .84% 1980 MHz: .35% 2208 MHz: 1.1% 2448 MHz: .50% 2676 MHz: .92% 2904 MHz: .70% 3036 MHz: .28% 3132 MHz: .01% 3168 MHz: .01% 3228 MHz: .17%)
CPU 6 idle residency:  94.27%
CPU 7 frequency: 2427 MHz
CPU 7 active residency:   1.91% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .17% 1524 MHz: .00% 1752 MHz: .03% 1980 MHz: .11% 2208 MHz: .29% 2448 MHz: .38% 2676 MHz: .50% 2904 MHz: .34% 3036 MHz: .07% 3132 MHz: .00% 3168 MHz: .00% 3228 MHz: .00%)
CPU 7 idle residency:  98.09%

CPU Power: 1712 mW
GPU Power: 31 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1744 mW

**** GPU usage ****

GPU HW active frequency: 409 MHz
GPU HW active residency:  11.39% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz: .60% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  94% P2 :   0% P3 :   0% P4 : 5.3% P5 : .31% P6 :   0%)
GPU idle residency:  88.61%
GPU Power: 31 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    96593  0.03      67.74  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28631  0.04      77.94  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    96676  0.02      66.93  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2922.25   60.07  2715.27 38.40              6795.07 0.00              1317.00

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 2064 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz: 100%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 2064 MHz
CPU 0 active residency:  99.90% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz: 100%)
CPU 0 idle residency:   0.10%
CPU 1 frequency: 2064 MHz
CPU 1 active residency:  99.86% (600 MHz:   0% 972 MHz:   0% 1332 MHz:   0% 1704 MHz:   0% 2064 MHz: 100%)
CPU 1 idle residency:   0.14%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2185 MHz
P0-Cluster HW active residency:  50.45% (600 MHz: .67% 828 MHz: 2.5% 1056 MHz: 1.9% 1296 MHz: 1.7% 1524 MHz: 5.7% 1752 MHz: 8.9% 1980 MHz:  19% 2208 MHz:  24% 2448 MHz:  14% 2676 MHz: 9.2% 2904 MHz: 5.9% 3036 MHz: 3.3% 3132 MHz: 1.4% 3168 MHz: .70% 3228 MHz: 1.7%)
P0-Cluster idle residency:  49.55%
CPU 2 frequency: 2255 MHz
CPU 2 active residency:  36.93% (600 MHz: .05% 828 MHz: .63% 1056 MHz: .36% 1296 MHz: .24% 1524 MHz: .74% 1752 MHz: 3.0% 1980 MHz: 8.0% 2208 MHz: 9.0% 2448 MHz: 6.6% 2676 MHz: 3.9% 2904 MHz: 2.5% 3036 MHz: .67% 3132 MHz: .61% 3168 MHz: .12% 3228 MHz: .65%)
CPU 2 idle residency:  63.07%
CPU 3 frequency: 2271 MHz
CPU 3 active residency:  26.04% (600 MHz: .01% 828 MHz: .05% 1056 MHz: .24% 1296 MHz: .13% 1524 MHz: .40% 1752 MHz: 2.3% 1980 MHz: 5.9% 2208 MHz: 5.9% 2448 MHz: 5.8% 2676 MHz: 2.4% 2904 MHz: 1.6% 3036 MHz: .34% 3132 MHz: .30% 3168 MHz: .01% 3228 MHz: .55%)
CPU 3 idle residency:  73.96%
CPU 4 frequency: 2335 MHz
CPU 4 active residency:  17.19% (600 MHz:   0% 828 MHz: .02% 1056 MHz: .12% 1296 MHz: .01% 1524 MHz: .12% 1752 MHz: 1.4% 1980 MHz: 4.1% 2208 MHz: 3.4% 2448 MHz: 3.4% 2676 MHz: 1.7% 2904 MHz: 1.1% 3036 MHz: 1.0% 3132 MHz: .16% 3168 MHz: .35% 3228 MHz: .26%)
CPU 4 idle residency:  82.81%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1407 MHz
P1-Cluster HW active residency:  18.74% (600 MHz:  46% 828 MHz: .30% 1056 MHz: 4.1% 1296 MHz: 4.4% 1524 MHz: 3.1% 1752 MHz: 5.6% 1980 MHz: 5.8% 2208 MHz:  11% 2448 MHz: 7.9% 2676 MHz: 4.7% 2904 MHz: 2.1% 3036 MHz: 1.8% 3132 MHz: 1.2% 3168 MHz: .65% 3228 MHz: .85%)
P1-Cluster idle residency:  81.26%
CPU 5 frequency: 2001 MHz
CPU 5 active residency:  14.97% (600 MHz: .20% 828 MHz: .00% 1056 MHz: 1.2% 1296 MHz: 1.2% 1524 MHz: .69% 1752 MHz: 2.4% 1980 MHz: 2.5% 2208 MHz: 2.4% 2448 MHz: 2.5% 2676 MHz: .80% 2904 MHz: .25% 3036 MHz: .17% 3132 MHz: .07% 3168 MHz: .01% 3228 MHz: .46%)
CPU 5 idle residency:  85.03%
CPU 6 frequency: 2032 MHz
CPU 6 active residency:   6.57% (600 MHz: .04% 828 MHz: .00% 1056 MHz: .53% 1296 MHz: .36% 1524 MHz: .43% 1752 MHz: .57% 1980 MHz: 1.2% 2208 MHz: 1.4% 2448 MHz: 1.5% 2676 MHz: .27% 2904 MHz: .05% 3036 MHz: .12% 3132 MHz: .05% 3168 MHz: .00% 3228 MHz:   0%)
CPU 6 idle residency:  93.43%
CPU 7 frequency: 1913 MHz
CPU 7 active residency:   3.08% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .77% 1296 MHz: .05% 1524 MHz: .22% 1752 MHz: .20% 1980 MHz: .47% 2208 MHz: .15% 2448 MHz: .88% 2676 MHz: .18% 2904 MHz: .10% 3036 MHz: .04% 3132 MHz: .00% 3168 MHz: .00% 3228 MHz:   0%)
CPU 7 idle residency:  96.92%

CPU Power: 1817 mW
GPU Power: 35 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1853 mW

**** GPU usage ****

GPU HW active frequency: 497 MHz
GPU HW active residency:  11.86% (389 MHz: 8.1% 486 MHz: .82% 648 MHz: .63% 778 MHz: 1.7% 972 MHz: .66% 1296 MHz:   0%)
GPU SW requested state: (P1 :  68% P2 : 7.4% P3 : 9.3% P4 :  14% P5 : .50% P6 :   0%)
GPU idle residency:  88.14%
GPU Power: 35 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
searchpartyuseragent               35216  0.07      15.82  0.00    0.00               0.97    0.00              0.00
mediaanalysisd                     36014  0.06      26.67  0.00    0.00               0.97    0.00              0.00
mDNSResponderHelper                475    0.04      48.52  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     2752.45   55.76  2713.00 25.34              6930.62 0.00              986.48

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1718 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:  13% 1332 MHz:  21% 1704 MHz:  15% 2064 MHz:  51%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 1719 MHz
CPU 0 active residency:  93.08% (600 MHz:   0% 972 MHz:  12% 1332 MHz:  20% 1704 MHz:  14% 2064 MHz:  48%)
CPU 0 idle residency:   6.92%
CPU 1 frequency: 1727 MHz
CPU 1 active residency:  92.98% (600 MHz:   0% 972 MHz:  11% 1332 MHz:  20% 1704 MHz:  13% 2064 MHz:  49%)
CPU 1 idle residency:   7.02%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1904 MHz
P0-Cluster HW active residency:  53.34% (600 MHz: 6.1% 828 MHz: .67% 1056 MHz: 8.2% 1296 MHz: 7.4% 1524 MHz: 9.2% 1752 MHz:  13% 1980 MHz:  17% 2208 MHz:  12% 2448 MHz:  11% 2676 MHz: 7.2% 2904 MHz: 2.8% 3036 MHz: 3.1% 3132 MHz: 1.1% 3168 MHz: .25% 3228 MHz: .81%)
P0-Cluster idle residency:  46.66%
CPU 2 frequency: 1986 MHz
CPU 2 active residency:  39.68% (600 MHz: .09% 828 MHz: .01% 1056 MHz: 3.0% 1296 MHz: 2.7% 1524 MHz: 5.2% 1752 MHz: 5.7% 1980 MHz: 7.7% 2208 MHz: 5.2% 2448 MHz: 5.1% 2676 MHz: 1.3% 2904 MHz: .47% 3036 MHz: .71% 3132 MHz: .42% 3168 MHz: .62% 3228 MHz: 1.4%)
CPU 2 idle residency:  60.32%
CPU 3 frequency: 2009 MHz
CPU 3 active residency:  30.93% (600 MHz: .01% 828 MHz: .00% 1056 MHz: 2.4% 1296 MHz: 2.3% 1524 MHz: 3.7% 1752 MHz: 4.8% 1980 MHz: 5.9% 2208 MHz: 3.3% 2448 MHz: 3.2% 2676 MHz: 1.9% 2904 MHz: .82% 3036 MHz: .53% 3132 MHz: .44% 3168 MHz: .61% 3228 MHz: 1.1%)
CPU 3 idle residency:  69.07%
CPU 4 frequency: 2052 MHz
CPU 4 active residency:  19.53% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .99% 1296 MHz: 1.4% 1524 MHz: 1.9% 1752 MHz: 3.3% 1980 MHz: 2.6% 2208 MHz: 3.5% 2448 MHz: 3.6% 2676 MHz: .47% 2904 MHz: .27% 3036 MHz: .20% 3132 MHz: .30% 3168 MHz: .26% 3228 MHz: .74%)
CPU 4 idle residency:  80.47%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1255 MHz
P1-Cluster HW active residency:  18.26% (600 MHz:  49% 828 MHz: .83% 1056 MHz: 6.8% 1296 MHz: 4.5% 1524 MHz: 5.7% 1752 MHz: 5.7% 1980 MHz: 9.8% 2208 MHz: 5.5% 2448 MHz: 5.1% 2676 MHz: 2.8% 2904 MHz: 1.5% 3036 MHz: .69% 3132 MHz: .47% 3168 MHz: .20% 3228 MHz: 1.1%)
P1-Cluster idle residency:  81.74%
CPU 5 frequency: 1841 MHz
CPU 5 active residency:  15.01% (600 MHz: .23% 828 MHz: .01% 1056 MHz: 2.3% 1296 MHz: 1.3% 1524 MHz: 1.5% 1752 MHz: 2.2% 1980 MHz: 2.9% 2208 MHz: 1.3% 2448 MHz: 1.7% 2676 MHz: .67% 2904 MHz: .11% 3036 MHz: .00% 3132 MHz: .00% 3168 MHz: .05% 3228 MHz: .58%)
CPU 5 idle residency:  84.99%
CPU 6 frequency: 1833 MHz
CPU 6 active residency:   7.41% (600 MHz: .04% 828 MHz:   0% 1056 MHz: 1.1% 1296 MHz: .45% 1524 MHz: .49% 1752 MHz: 1.4% 1980 MHz: 1.6% 2208 MHz: 1.5% 2448 MHz: .79% 2676 MHz: .05% 2904 MHz: .01% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz: .02% 3228 MHz: .04%)
CPU 6 idle residency:  92.59%
CPU 7 frequency: 1934 MHz
CPU 7 active residency:   3.17% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .41% 1296 MHz: .02% 1524 MHz: .15% 1752 MHz: .69% 1980 MHz: .50% 2208 MHz: .84% 2448 MHz: .52% 2676 MHz:   0% 2904 MHz: .00% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz: .01% 3228 MHz: .03%)
CPU 7 idle residency:  96.83%

CPU Power: 1406 mW
GPU Power: 35 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1441 mW

**** GPU usage ****

GPU HW active frequency: 528 MHz
GPU HW active residency:  12.23% (389 MHz: 7.7% 486 MHz: .24% 648 MHz: .68% 778 MHz: 2.9% 972 MHz: .62% 1296 MHz:   0%)
GPU SW requested state: (P1 :  62% P2 : 3.2% P3 :  10% P4 :  23% P5 : 2.3% P6 :   0%)
GPU idle residency:  87.77%
GPU Power: 35 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
amsondevicestoraged                88654  0.09      20.73  0.00    0.00               0.97    0.00              0.00
wifip2pd                           25354  0.07      58.36  0.00    0.00               0.00    0.00              0.00
mDNSResponderHelper                475    0.04      27.88  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     2668.66   58.86  3487.18 45.51              7499.23 0.00              1540.63

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1615 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:  32% 1332 MHz: 9.0% 1704 MHz: 9.0% 2064 MHz:  50%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 1630 MHz
CPU 0 active residency:  89.36% (600 MHz:   0% 972 MHz:  27% 1332 MHz: 7.9% 1704 MHz: 8.3% 2064 MHz:  46%)
CPU 0 idle residency:  10.64%
CPU 1 frequency: 1623 MHz
CPU 1 active residency:  86.83% (600 MHz:   0% 972 MHz:  27% 1332 MHz: 7.5% 1704 MHz: 7.9% 2064 MHz:  44%)
CPU 1 idle residency:  13.17%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2220 MHz
P0-Cluster HW active residency:  58.21% (600 MHz: 1.9% 828 MHz: .29% 1056 MHz: .31% 1296 MHz:  12% 1524 MHz: 4.1% 1752 MHz:  21% 1980 MHz: 5.2% 2208 MHz: 6.6% 2448 MHz:  12% 2676 MHz:  11% 2904 MHz: 7.4% 3036 MHz: 7.9% 3132 MHz: 3.9% 3168 MHz: .52% 3228 MHz: 5.4%)
P0-Cluster idle residency:  41.79%
CPU 2 frequency: 2410 MHz
CPU 2 active residency:  44.80% (600 MHz: .06% 828 MHz: .01% 1056 MHz: .13% 1296 MHz: 2.0% 1524 MHz: .78% 1752 MHz:  11% 1980 MHz: 2.3% 2208 MHz: 2.4% 2448 MHz: 6.5% 2676 MHz: 6.3% 2904 MHz: 3.1% 3036 MHz: 1.3% 3132 MHz: .39% 3168 MHz: .73% 3228 MHz: 8.0%)
CPU 2 idle residency:  55.20%
CPU 3 frequency: 2450 MHz
CPU 3 active residency:  31.77% (600 MHz: .01% 828 MHz: .00% 1056 MHz: .08% 1296 MHz: .99% 1524 MHz: .64% 1752 MHz: 7.0% 1980 MHz: 1.2% 2208 MHz: 2.4% 2448 MHz: 5.3% 2676 MHz: 4.6% 2904 MHz: 1.3% 3036 MHz: .98% 3132 MHz: .34% 3168 MHz: 1.0% 3228 MHz: 6.1%)
CPU 3 idle residency:  68.23%
CPU 4 frequency: 2472 MHz
CPU 4 active residency:  22.34% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .02% 1296 MHz: .33% 1524 MHz: .33% 1752 MHz: 5.3% 1980 MHz: .78% 2208 MHz: 1.7% 2448 MHz: 4.2% 2676 MHz: 2.6% 2904 MHz: .80% 3036 MHz: .85% 3132 MHz: .43% 3168 MHz: .51% 3228 MHz: 4.5%)
CPU 4 idle residency:  77.66%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1620 MHz
P1-Cluster HW active residency:  23.14% (600 MHz:  39% 828 MHz: .02% 1056 MHz: 3.1% 1296 MHz: 5.4% 1524 MHz: 5.1% 1752 MHz: 9.4% 1980 MHz: 3.4% 2208 MHz: 2.8% 2448 MHz: 7.2% 2676 MHz: 7.3% 2904 MHz: 2.4% 3036 MHz: 2.5% 3132 MHz: .96% 3168 MHz: 1.4% 3228 MHz: 9.9%)
P1-Cluster idle residency:  76.86%
CPU 5 frequency: 2282 MHz
CPU 5 active residency:  19.42% (600 MHz: .18% 828 MHz: .00% 1056 MHz: .72% 1296 MHz: 1.6% 1524 MHz: 1.5% 1752 MHz: 2.7% 1980 MHz: .94% 2208 MHz: 1.2% 2448 MHz: 3.4% 2676 MHz: 2.4% 2904 MHz: .67% 3036 MHz: .58% 3132 MHz: .15% 3168 MHz: .46% 3228 MHz: 2.9%)
CPU 5 idle residency:  80.58%
CPU 6 frequency: 2183 MHz
CPU 6 active residency:   9.49% (600 MHz: .04% 828 MHz: .00% 1056 MHz: .50% 1296 MHz: .97% 1524 MHz: .77% 1752 MHz: 1.5% 1980 MHz: .30% 2208 MHz: .64% 2448 MHz: 1.9% 2676 MHz: 1.1% 2904 MHz: .42% 3036 MHz: .14% 3132 MHz: .13% 3168 MHz: .11% 3228 MHz: .96%)
CPU 6 idle residency:  90.51%
CPU 7 frequency: 2260 MHz
CPU 7 active residency:   3.93% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .18% 1296 MHz: .27% 1524 MHz: .25% 1752 MHz: .59% 1980 MHz: .09% 2208 MHz: .24% 2448 MHz: 1.1% 2676 MHz: .43% 2904 MHz: .26% 3036 MHz: .04% 3132 MHz: .04% 3168 MHz: .06% 3228 MHz: .38%)
CPU 7 idle residency:  96.07%

CPU Power: 2219 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 2248 mW

**** GPU usage ****

GPU HW active frequency: 396 MHz
GPU HW active residency:  11.49% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz: .21% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  98% P2 :   0% P3 :   0% P4 : 1.8% P5 : .12% P6 :   0%)
GPU idle residency:  88.51%
GPU Power: 29 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
OpenVPN Connect Helper             862    0.02      62.15  0.00    0.00               0.98    0.00              0.00
Discord Helper                     8480   0.02      64.87  0.00    0.00               0.98    0.00              0.00
mDNSResponderHelper                475    0.05      43.14  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2444.53   72.64  2474.42 17.70              6634.51 0.00              960.81

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1853 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:  17% 1332 MHz: 1.3% 1704 MHz: 3.4% 2064 MHz:  78%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 1886 MHz
CPU 0 active residency:  94.58% (600 MHz:   0% 972 MHz:  14% 1332 MHz: 1.1% 1704 MHz: 3.1% 2064 MHz:  77%)
CPU 0 idle residency:   5.42%
CPU 1 frequency: 1871 MHz
CPU 1 active residency:  96.49% (600 MHz:   0% 972 MHz:  15% 1332 MHz: 1.1% 1704 MHz: 3.2% 2064 MHz:  77%)
CPU 1 idle residency:   3.51%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2115 MHz
P0-Cluster HW active residency:  39.58% (600 MHz: 6.7% 828 MHz: .39% 1056 MHz: 1.6% 1296 MHz: 4.9% 1524 MHz: 6.0% 1752 MHz:  15% 1980 MHz:  17% 2208 MHz: 7.4% 2448 MHz: 9.4% 2676 MHz:  15% 2904 MHz: 6.4% 3036 MHz: 4.9% 3132 MHz: 1.8% 3168 MHz: 1.3% 3228 MHz: 2.7%)
P0-Cluster idle residency:  60.42%
CPU 2 frequency: 2283 MHz
CPU 2 active residency:  29.69% (600 MHz: .20% 828 MHz: .02% 1056 MHz: .95% 1296 MHz: 1.1% 1524 MHz: 1.8% 1752 MHz: 4.6% 1980 MHz: 3.5% 2208 MHz: 3.0% 2448 MHz: 3.6% 2676 MHz: 4.0% 2904 MHz: 2.3% 3036 MHz: 1.6% 3132 MHz: .04% 3168 MHz: .66% 3228 MHz: 2.4%)
CPU 2 idle residency:  70.31%
CPU 3 frequency: 2236 MHz
CPU 3 active residency:  19.83% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .93% 1296 MHz: .85% 1524 MHz: 1.5% 1752 MHz: 2.6% 1980 MHz: 2.3% 2208 MHz: 1.8% 2448 MHz: 3.0% 2676 MHz: 3.4% 2904 MHz: 1.5% 3036 MHz: 1.0% 3132 MHz: .05% 3168 MHz: .31% 3228 MHz: .65%)
CPU 3 idle residency:  80.17%
CPU 4 frequency: 2251 MHz
CPU 4 active residency:   7.18% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .53% 1296 MHz: .35% 1524 MHz: .44% 1752 MHz: .67% 1980 MHz: .91% 2208 MHz: .53% 2448 MHz: 1.0% 2676 MHz: 1.2% 2904 MHz: .53% 3036 MHz: .61% 3132 MHz: .00% 3168 MHz: .28% 3228 MHz: .09%)
CPU 4 idle residency:  92.82%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1240 MHz
P1-Cluster HW active residency:  10.40% (600 MHz:  62% 828 MHz: .44% 1056 MHz: 2.4% 1296 MHz: 2.2% 1524 MHz: 3.1% 1752 MHz: 4.4% 1980 MHz: 3.0% 2208 MHz: 2.7% 2448 MHz: 4.2% 2676 MHz: 5.4% 2904 MHz: 3.3% 3036 MHz: 2.9% 3132 MHz: .03% 3168 MHz: .74% 3228 MHz: 3.4%)
P1-Cluster idle residency:  89.60%
CPU 5 frequency: 2123 MHz
CPU 5 active residency:   8.64% (600 MHz: .16% 828 MHz: .00% 1056 MHz: .52% 1296 MHz: .52% 1524 MHz: .82% 1752 MHz: 1.4% 1980 MHz: .66% 2208 MHz: .70% 2448 MHz: 1.2% 2676 MHz: 1.7% 2904 MHz: .41% 3036 MHz: .18% 3132 MHz:   0% 3168 MHz: .11% 3228 MHz: .29%)
CPU 5 idle residency:  91.36%
CPU 6 frequency: 1923 MHz
CPU 6 active residency:   2.54% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .42% 1296 MHz: .21% 1524 MHz: .40% 1752 MHz: .12% 1980 MHz: .02% 2208 MHz: .41% 2448 MHz: .37% 2676 MHz: .44% 2904 MHz: .05% 3036 MHz: .03% 3132 MHz:   0% 3168 MHz: .01% 3228 MHz: .00%)
CPU 6 idle residency:  97.46%
CPU 7 frequency: 1691 MHz
CPU 7 active residency:   0.67% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .33% 1296 MHz: .00% 1524 MHz: .02% 1752 MHz: .04% 1980 MHz: .03% 2208 MHz: .00% 2448 MHz: .11% 2676 MHz: .11% 2904 MHz: .01% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .00%)
CPU 7 idle residency:  99.33%

CPU Power: 1321 mW
GPU Power: 30 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1350 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  11.04% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  88.96%
GPU Power: 30 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
wifip2pd                           25354  0.04      60.38  0.00    0.00               0.00    0.00              0.00
SubmitDiagInfo                     9246   0.08      50.66  0.00    0.00               0.99    0.00              0.00
mDNSResponderHelper                475    0.04      36.79  0.00    0.00               0.99    0.00              0.00
ALL_TASKS                          -2     2548.96   56.93  2590.11 38.45              6163.21 0.00              1230.50

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1518 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:  43% 1332 MHz: 5.8% 1704 MHz:  11% 2064 MHz:  41%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 1540 MHz
CPU 0 active residency:  88.63% (600 MHz:   0% 972 MHz:  36% 1332 MHz: 4.9% 1704 MHz: 8.9% 2064 MHz:  39%)
CPU 0 idle residency:  11.37%
CPU 1 frequency: 1535 MHz
CPU 1 active residency:  83.08% (600 MHz:   0% 972 MHz:  35% 1332 MHz: 4.5% 1704 MHz: 7.8% 2064 MHz:  36%)
CPU 1 idle residency:  16.92%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2285 MHz
P0-Cluster HW active residency:  53.03% (600 MHz: 1.3% 828 MHz:   0% 1056 MHz: .37% 1296 MHz: 1.7% 1524 MHz: 6.1% 1752 MHz:  21% 1980 MHz:  19% 2208 MHz: 5.5% 2448 MHz:  11% 2676 MHz: 8.6% 2904 MHz: 6.1% 3036 MHz: 6.1% 3132 MHz: 5.3% 3168 MHz: 1.4% 3228 MHz: 7.5%)
P0-Cluster idle residency:  46.97%
CPU 2 frequency: 2360 MHz
CPU 2 active residency:  41.74% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .06% 1296 MHz: 1.1% 1524 MHz: 2.1% 1752 MHz: 9.4% 1980 MHz: 6.1% 2208 MHz: 2.2% 2448 MHz: 5.3% 2676 MHz: 2.5% 2904 MHz: 2.0% 3036 MHz: .78% 3132 MHz: .68% 3168 MHz: .91% 3228 MHz: 8.5%)
CPU 2 idle residency:  58.26%
CPU 3 frequency: 2317 MHz
CPU 3 active residency:  27.30% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .18% 1296 MHz: .63% 1524 MHz: 1.4% 1752 MHz: 7.5% 1980 MHz: 2.6% 2208 MHz: 1.8% 2448 MHz: 4.0% 2676 MHz: 1.9% 2904 MHz: 1.2% 3036 MHz: .78% 3132 MHz: .44% 3168 MHz: .23% 3228 MHz: 4.7%)
CPU 3 idle residency:  72.70%
CPU 4 frequency: 2316 MHz
CPU 4 active residency:  18.77% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .90% 1524 MHz: .58% 1752 MHz: 6.1% 1980 MHz: 1.3% 2208 MHz: .94% 2448 MHz: 2.6% 2676 MHz: .60% 2904 MHz: 1.1% 3036 MHz: .35% 3132 MHz: .51% 3168 MHz: .03% 3228 MHz: 3.8%)
CPU 4 idle residency:  81.23%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1364 MHz
P1-Cluster HW active residency:  20.92% (600 MHz:  49% 828 MHz: 1.0% 1056 MHz: 4.2% 1296 MHz: 5.6% 1524 MHz: 3.2% 1752 MHz: 8.6% 1980 MHz: 4.2% 2208 MHz: 3.6% 2448 MHz: 4.9% 2676 MHz: 3.3% 2904 MHz: 1.9% 3036 MHz: 1.9% 3132 MHz: 1.3% 3168 MHz: .21% 3228 MHz: 6.5%)
P1-Cluster idle residency:  79.08%
CPU 5 frequency: 1983 MHz
CPU 5 active residency:  17.12% (600 MHz: .17% 828 MHz: .01% 1056 MHz: .95% 1296 MHz: 3.2% 1524 MHz: 1.6% 1752 MHz: 3.2% 1980 MHz: 1.3% 2208 MHz: .81% 2448 MHz: 2.6% 2676 MHz: .75% 2904 MHz: .61% 3036 MHz: .44% 3132 MHz: .04% 3168 MHz: .00% 3228 MHz: 1.5%)
CPU 5 idle residency:  82.88%
CPU 6 frequency: 1888 MHz
CPU 6 active residency:   7.38% (600 MHz: .02% 828 MHz: .01% 1056 MHz: .43% 1296 MHz: 1.9% 1524 MHz: .88% 1752 MHz: 1.3% 1980 MHz: .07% 2208 MHz: .65% 2448 MHz: 1.0% 2676 MHz: .17% 2904 MHz: .29% 3036 MHz: .14% 3132 MHz: .02% 3168 MHz: .00% 3228 MHz: .47%)
CPU 6 idle residency:  92.62%
CPU 7 frequency: 1915 MHz
CPU 7 active residency:   4.41% (600 MHz: .00% 828 MHz: .00% 1056 MHz: .38% 1296 MHz: .95% 1524 MHz: .51% 1752 MHz: .92% 1980 MHz: .03% 2208 MHz: .11% 2448 MHz: .53% 2676 MHz: .45% 2904 MHz: .21% 3036 MHz: .01% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .29%)
CPU 7 idle residency:  95.59%

CPU Power: 1768 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1796 mW

**** GPU usage ****

GPU HW active frequency: 389 MHz
GPU HW active residency:  10.88% (389 MHz:  11% 486 MHz:   0% 648 MHz:   0% 778 MHz:   0% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 : 100% P2 :   0% P3 :   0% P4 :   0% P5 :   0% P6 :   0%)
GPU idle residency:  89.12%
GPU Power: 29 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
extension-host                     96574  0.03      58.31  0.00    0.00               0.00    0.00              0.00
managedappdistributionagent        44800  0.11      65.96  0.00    0.00               0.97    0.00              0.00
mDNSResponderHelper                475    0.05      43.52  0.00    0.00               0.97    0.97              0.00
ALL_TASKS                          -2     1611.29   46.04  2364.13 23.23              5809.64 525.69            954.82

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1471 MHz
E-Cluster HW active residency:  67.19% (600 MHz:   0% 972 MHz:  47% 1332 MHz: 8.3% 1704 MHz: 6.1% 2064 MHz:  39%)
E-Cluster idle residency:  32.81%
CPU 0 frequency: 1526 MHz
CPU 0 active residency:  60.21% (600 MHz:   0% 972 MHz:  25% 1332 MHz: 5.0% 1704 MHz: 4.6% 2064 MHz:  26%)
CPU 0 idle residency:  39.79%
CPU 1 frequency: 1527 MHz
CPU 1 active residency:  60.66% (600 MHz:   0% 972 MHz:  25% 1332 MHz: 5.0% 1704 MHz: 4.5% 2064 MHz:  26%)
CPU 1 idle residency:  39.34%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2217 MHz
P0-Cluster HW active residency:  40.80% (600 MHz: 5.5% 828 MHz: .41% 1056 MHz: 1.7% 1296 MHz: 2.7% 1524 MHz: 6.1% 1752 MHz: 4.7% 1980 MHz:  16% 2208 MHz:  16% 2448 MHz: 8.0% 2676 MHz:  26% 2904 MHz: 2.5% 3036 MHz: 3.5% 3132 MHz: 2.2% 3168 MHz: .78% 3228 MHz: 3.1%)
P0-Cluster idle residency:  59.20%
CPU 2 frequency: 2325 MHz
CPU 2 active residency:  29.91% (600 MHz: .19% 828 MHz: .03% 1056 MHz: .65% 1296 MHz: .53% 1524 MHz: 1.1% 1752 MHz: 1.7% 1980 MHz: 4.8% 2208 MHz: 7.6% 2448 MHz: 2.9% 2676 MHz: 6.0% 2904 MHz: .74% 3036 MHz: .48% 3132 MHz: .47% 3168 MHz: .12% 3228 MHz: 2.7%)
CPU 2 idle residency:  70.09%
CPU 3 frequency: 2344 MHz
CPU 3 active residency:  20.58% (600 MHz: .04% 828 MHz: .00% 1056 MHz: .38% 1296 MHz: .24% 1524 MHz: .99% 1752 MHz: .61% 1980 MHz: 3.6% 2208 MHz: 5.4% 2448 MHz: 1.5% 2676 MHz: 4.8% 2904 MHz: .54% 3036 MHz: .89% 3132 MHz: .41% 3168 MHz: .03% 3228 MHz: 1.2%)
CPU 3 idle residency:  79.42%
CPU 4 frequency: 2357 MHz
CPU 4 active residency:  15.06% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .10% 1296 MHz: 1.4% 1524 MHz: .19% 1752 MHz: .50% 1980 MHz: 2.4% 2208 MHz: 3.5% 2448 MHz: .91% 2676 MHz: 2.7% 2904 MHz: .94% 3036 MHz: .39% 3132 MHz: .46% 3168 MHz: .01% 3228 MHz: 1.6%)
CPU 4 idle residency:  84.94%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1164 MHz
P1-Cluster HW active residency:  13.98% (600 MHz:  65% 828 MHz:   0% 1056 MHz: .92% 1296 MHz: 3.6% 1524 MHz: 2.2% 1752 MHz: 2.9% 1980 MHz: 3.7% 2208 MHz: 7.9% 2448 MHz: 3.9% 2676 MHz: 1.9% 2904 MHz: 1.5% 3036 MHz: 1.5% 3132 MHz: 1.1% 3168 MHz: .42% 3228 MHz: 3.2%)
P1-Cluster idle residency:  86.02%
CPU 5 frequency: 2111 MHz
CPU 5 active residency:  10.02% (600 MHz: .14% 828 MHz:   0% 1056 MHz: .18% 1296 MHz: .99% 1524 MHz: 1.3% 1752 MHz: .78% 1980 MHz: 1.7% 2208 MHz: 1.9% 2448 MHz: .74% 2676 MHz: .72% 2904 MHz: .53% 3036 MHz: .13% 3132 MHz: .07% 3168 MHz: .00% 3228 MHz: .92%)
CPU 5 idle residency:  89.98%
CPU 6 frequency: 2273 MHz
CPU 6 active residency:   7.73% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .13% 1296 MHz: .70% 1524 MHz: .90% 1752 MHz: .65% 1980 MHz: .67% 2208 MHz: 1.3% 2448 MHz: .36% 2676 MHz: .65% 2904 MHz: .70% 3036 MHz: .44% 3132 MHz: .42% 3168 MHz: .42% 3228 MHz: .37%)
CPU 6 idle residency:  92.27%
CPU 7 frequency: 1940 MHz
CPU 7 active residency:   3.55% (600 MHz: .03% 828 MHz:   0% 1056 MHz: .02% 1296 MHz: .32% 1524 MHz: .86% 1752 MHz: .79% 1980 MHz: .35% 2208 MHz: .54% 2448 MHz: .05% 2676 MHz: .25% 2904 MHz: .17% 3036 MHz: .01% 3132 MHz: .00% 3168 MHz:   0% 3228 MHz: .18%)
CPU 7 idle residency:  96.45%

CPU Power: 1320 mW
GPU Power: 27 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1347 mW

**** GPU usage ****

GPU HW active frequency: 401 MHz
GPU HW active residency:  10.72% (389 MHz:  10% 486 MHz:   0% 648 MHz:   0% 778 MHz: .35% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  97% P2 :   0% P3 :   0% P4 : 3.2% P5 : .14% P6 :   0%)
GPU idle residency:  89.28%
GPU Power: 27 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
mDNSResponderHelper                475    0.06      39.82  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28392  0.05      62.58  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    87470  0.04      64.77  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2185.87   59.58  2546.90 37.22              6114.51 148.90            1215.63

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1515 MHz
E-Cluster HW active residency:  89.92% (600 MHz:   0% 972 MHz:  41% 1332 MHz: 8.1% 1704 MHz:  12% 2064 MHz:  39%)
E-Cluster idle residency:  10.08%
CPU 0 frequency: 1547 MHz
CPU 0 active residency:  78.39% (600 MHz:   0% 972 MHz:  29% 1332 MHz: 6.3% 1704 MHz:  10% 2064 MHz:  32%)
CPU 0 idle residency:  21.61%
CPU 1 frequency: 1532 MHz
CPU 1 active residency:  78.54% (600 MHz:   0% 972 MHz:  31% 1332 MHz: 6.0% 1704 MHz: 9.3% 2064 MHz:  32%)
CPU 1 idle residency:  21.46%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2305 MHz
P0-Cluster HW active residency:  44.27% (600 MHz: 1.4% 828 MHz:   0% 1056 MHz: .52% 1296 MHz: .31% 1524 MHz: 7.7% 1752 MHz: 6.1% 1980 MHz:  17% 2208 MHz:  11% 2448 MHz:  31% 2676 MHz: 7.9% 2904 MHz: 4.6% 3036 MHz: 5.1% 3132 MHz: 3.1% 3168 MHz: .85% 3228 MHz: 2.5%)
P0-Cluster idle residency:  55.73%
CPU 2 frequency: 2320 MHz
CPU 2 active residency:  33.70% (600 MHz: .06% 828 MHz:   0% 1056 MHz: .22% 1296 MHz: .08% 1524 MHz: 3.8% 1752 MHz: 1.7% 1980 MHz: 6.0% 2208 MHz: 3.7% 2448 MHz: 9.2% 2676 MHz: 2.7% 2904 MHz: 1.3% 3036 MHz: 1.6% 3132 MHz: .84% 3168 MHz: .92% 3228 MHz: 1.6%)
CPU 2 idle residency:  66.30%
CPU 3 frequency: 2360 MHz
CPU 3 active residency:  23.82% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .11% 1296 MHz: .01% 1524 MHz: 2.4% 1752 MHz: 1.4% 1980 MHz: 5.6% 2208 MHz: 2.2% 2448 MHz: 4.3% 2676 MHz: 1.6% 2904 MHz: 1.1% 3036 MHz: 1.6% 3132 MHz: 1.4% 3168 MHz: .30% 3228 MHz: 1.8%)
CPU 3 idle residency:  76.18%
CPU 4 frequency: 2349 MHz
CPU 4 active residency:  14.06% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .01% 1296 MHz: .00% 1524 MHz: .88% 1752 MHz: .82% 1980 MHz: 3.9% 2208 MHz: 1.9% 2448 MHz: 2.1% 2676 MHz: 1.2% 2904 MHz: .88% 3036 MHz: .88% 3132 MHz: .49% 3168 MHz: .11% 3228 MHz: .88%)
CPU 4 idle residency:  85.94%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1200 MHz
P1-Cluster HW active residency:  14.31% (600 MHz:  60% 828 MHz: .98% 1056 MHz: 1.7% 1296 MHz: 2.5% 1524 MHz: 7.0% 1752 MHz: 4.9% 1980 MHz: 6.8% 2208 MHz: 3.1% 2448 MHz: 2.4% 2676 MHz: 2.3% 2904 MHz: 1.6% 3036 MHz: 2.7% 3132 MHz: 1.7% 3168 MHz: .75% 3228 MHz: 1.9%)
P1-Cluster idle residency:  85.69%
CPU 5 frequency: 2149 MHz
CPU 5 active residency:  11.24% (600 MHz: .16% 828 MHz: .00% 1056 MHz: .23% 1296 MHz: .97% 1524 MHz: 1.9% 1752 MHz: 1.0% 1980 MHz: 1.6% 2208 MHz: .90% 2448 MHz: .78% 2676 MHz: 1.2% 2904 MHz: .54% 3036 MHz: 1.0% 3132 MHz: .24% 3168 MHz: .09% 3228 MHz: .60%)
CPU 5 idle residency:  88.76%
CPU 6 frequency: 2261 MHz
CPU 6 active residency:   7.41% (600 MHz: .03% 828 MHz:   0% 1056 MHz: .14% 1296 MHz: .28% 1524 MHz: 1.1% 1752 MHz: .63% 1980 MHz: 1.3% 2208 MHz: .50% 2448 MHz: .82% 2676 MHz: .46% 2904 MHz: .64% 3036 MHz: .74% 3132 MHz: .40% 3168 MHz: .09% 3228 MHz: .28%)
CPU 6 idle residency:  92.59%
CPU 7 frequency: 2280 MHz
CPU 7 active residency:   3.82% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .03% 1296 MHz: .28% 1524 MHz: .48% 1752 MHz: .35% 1980 MHz: .75% 2208 MHz: .09% 2448 MHz: .24% 2676 MHz: .43% 2904 MHz: .34% 3036 MHz: .55% 3132 MHz: .00% 3168 MHz: .09% 3228 MHz: .19%)
CPU 7 idle residency:  96.18%

CPU Power: 1577 mW
GPU Power: 32 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1609 mW

**** GPU usage ****

GPU HW active frequency: 395 MHz
GPU HW active residency:  13.02% (389 MHz:  13% 486 MHz:   0% 648 MHz:   0% 778 MHz: .21% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  98% P2 :   0% P3 :   0% P4 : 1.6% P5 : .11% P6 :   0%)
GPU idle residency:  86.98%
GPU Power: 32 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    87470  0.05      72.84  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28392  0.05      68.19  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper               96567  0.02      55.24  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     1321.62   48.72  1900.97 10.83              5554.17 556.50            569.69

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1328 MHz
E-Cluster HW active residency:  68.92% (600 MHz:   0% 972 MHz:  58% 1332 MHz: 7.2% 1704 MHz:  15% 2064 MHz:  20%)
E-Cluster idle residency:  31.08%
CPU 0 frequency: 1353 MHz
CPU 0 active residency:  61.99% (600 MHz:   0% 972 MHz:  34% 1332 MHz: 4.8% 1704 MHz:  11% 2064 MHz:  13%)
CPU 0 idle residency:  38.01%
CPU 1 frequency: 1340 MHz
CPU 1 active residency:  61.59% (600 MHz:   0% 972 MHz:  34% 1332 MHz: 4.9% 1704 MHz: 9.8% 2064 MHz:  13%)
CPU 1 idle residency:  38.41%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 1795 MHz
P0-Cluster HW active residency:  36.00% (600 MHz:  12% 828 MHz: .70% 1056 MHz: 7.5% 1296 MHz: 7.4% 1524 MHz:  19% 1752 MHz: 8.8% 1980 MHz: 7.5% 2208 MHz: 7.0% 2448 MHz:  13% 2676 MHz: 9.0% 2904 MHz: 5.3% 3036 MHz: 1.0% 3132 MHz: .50% 3168 MHz:   0% 3228 MHz: 1.0%)
P0-Cluster idle residency:  64.00%
CPU 2 frequency: 2050 MHz
CPU 2 active residency:  29.03% (600 MHz: .14% 828 MHz: .02% 1056 MHz: 2.8% 1296 MHz: 1.4% 1524 MHz: 4.5% 1752 MHz: 3.6% 1980 MHz: 2.3% 2208 MHz: 2.2% 2448 MHz: 5.5% 2676 MHz: 3.2% 2904 MHz: 1.9% 3036 MHz: .43% 3132 MHz: .25% 3168 MHz:   0% 3228 MHz: .69%)
CPU 2 idle residency:  70.97%
CPU 3 frequency: 2045 MHz
CPU 3 active residency:  16.66% (600 MHz: .03% 828 MHz: .00% 1056 MHz: 1.7% 1296 MHz: .71% 1524 MHz: 2.5% 1752 MHz: 2.0% 1980 MHz: 1.9% 2208 MHz: 1.6% 2448 MHz: 2.4% 2676 MHz: 1.6% 2904 MHz: 1.3% 3036 MHz: .19% 3132 MHz: .28% 3168 MHz:   0% 3228 MHz: .37%)
CPU 3 idle residency:  83.34%
CPU 4 frequency: 1997 MHz
CPU 4 active residency:   8.44% (600 MHz: .01% 828 MHz: .01% 1056 MHz: 1.0% 1296 MHz: .57% 1524 MHz: 1.1% 1752 MHz: 1.1% 1980 MHz: .76% 2208 MHz: 1.2% 2448 MHz: 1.2% 2676 MHz: .43% 2904 MHz: .49% 3036 MHz: .21% 3132 MHz: .06% 3168 MHz:   0% 3228 MHz: .31%)
CPU 4 idle residency:  91.56%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1009 MHz
P1-Cluster HW active residency:   8.72% (600 MHz:  72% 828 MHz: .42% 1056 MHz: 3.1% 1296 MHz: 2.2% 1524 MHz: 2.9% 1752 MHz: 3.3% 1980 MHz: 2.2% 2208 MHz: 2.3% 2448 MHz: 5.2% 2676 MHz: 3.1% 2904 MHz: 1.7% 3036 MHz: .46% 3132 MHz: .37% 3168 MHz:   0% 3228 MHz: .97%)
P1-Cluster idle residency:  91.28%
CPU 5 frequency: 1940 MHz
CPU 5 active residency:   6.74% (600 MHz: .14% 828 MHz:   0% 1056 MHz: 1.1% 1296 MHz: .47% 1524 MHz: 1.0% 1752 MHz: .34% 1980 MHz: .41% 2208 MHz: .54% 2448 MHz: 1.8% 2676 MHz: .49% 2904 MHz: .18% 3036 MHz:   0% 3132 MHz: .09% 3168 MHz:   0% 3228 MHz: .17%)
CPU 5 idle residency:  93.26%
CPU 6 frequency: 1854 MHz
CPU 6 active residency:   3.42% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .74% 1296 MHz: .14% 1524 MHz: .57% 1752 MHz: .14% 1980 MHz: .28% 2208 MHz: .39% 2448 MHz: .93% 2676 MHz: .07% 2904 MHz: .08% 3036 MHz:   0% 3132 MHz: .01% 3168 MHz:   0% 3228 MHz: .03%)
CPU 6 idle residency:  96.58%
CPU 7 frequency: 1832 MHz
CPU 7 active residency:   1.63% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .46% 1296 MHz: .02% 1524 MHz: .12% 1752 MHz: .02% 1980 MHz: .62% 2208 MHz: .14% 2448 MHz: .10% 2676 MHz: .03% 2904 MHz: .01% 3036 MHz:   0% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .12%)
CPU 7 idle residency:  98.37%

CPU Power: 872 mW
GPU Power: 27 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 898 mW

**** GPU usage ****

GPU HW active frequency: 425 MHz
GPU HW active residency:   9.76% (389 MHz: 8.7% 486 MHz: .17% 648 MHz: .06% 778 MHz: .83% 972 MHz:   0% 1296 MHz:   0%)
GPU SW requested state: (P1 :  89% P2 : 1.7% P3 : 3.1% P4 : 6.1% P5 : .21% P6 :   0%)
GPU idle residency:  90.24%
GPU Power: 28 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    28614  0.04      43.95  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    28615  0.03      40.89  0.00    0.00               0.98    0.00              0.00
Brave Browser Helper (Renderer)    1130   0.02      56.85  0.00    0.00               0.98    0.00              0.00
ALL_TASKS                          -2     2261.58   49.08  2847.63 46.36              6938.07 352.13            1290.49

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1719 MHz
E-Cluster HW active residency:  81.62% (600 MHz:   0% 972 MHz:  26% 1332 MHz: 2.5% 1704 MHz:  13% 2064 MHz:  59%)
E-Cluster idle residency:  18.38%
CPU 0 frequency: 1747 MHz
CPU 0 active residency:  77.29% (600 MHz:   0% 972 MHz:  17% 1332 MHz: 2.2% 1704 MHz:  11% 2064 MHz:  47%)
CPU 0 idle residency:  22.71%
CPU 1 frequency: 1744 MHz
CPU 1 active residency:  75.77% (600 MHz:   0% 972 MHz:  17% 1332 MHz: 2.2% 1704 MHz:  10% 2064 MHz:  46%)
CPU 1 idle residency:  24.23%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2108 MHz
P0-Cluster HW active residency:  52.95% (600 MHz: 6.0% 828 MHz: .83% 1056 MHz: 6.2% 1296 MHz: 5.3% 1524 MHz: 4.0% 1752 MHz:  12% 1980 MHz: 9.1% 2208 MHz:  15% 2448 MHz:  14% 2676 MHz:  12% 2904 MHz: 4.6% 3036 MHz: 2.5% 3132 MHz: 1.5% 3168 MHz: .35% 3228 MHz: 6.7%)
P0-Cluster idle residency:  47.05%
CPU 2 frequency: 2321 MHz
CPU 2 active residency:  40.25% (600 MHz: .07% 828 MHz: .00% 1056 MHz: 2.1% 1296 MHz: 1.4% 1524 MHz: 1.8% 1752 MHz: 4.0% 1980 MHz: 3.5% 2208 MHz: 6.1% 2448 MHz: 6.3% 2676 MHz: 6.3% 2904 MHz: 3.0% 3036 MHz: 1.5% 3132 MHz: .39% 3168 MHz: .03% 3228 MHz: 3.9%)
CPU 2 idle residency:  59.75%
CPU 3 frequency: 2236 MHz
CPU 3 active residency:  29.76% (600 MHz: .08% 828 MHz: .02% 1056 MHz: 1.1% 1296 MHz: 1.6% 1524 MHz: 1.7% 1752 MHz: 3.3% 1980 MHz: 2.4% 2208 MHz: 5.6% 2448 MHz: 5.4% 2676 MHz: 3.7% 2904 MHz: 2.4% 3036 MHz: 1.2% 3132 MHz: .02% 3168 MHz: .07% 3228 MHz: 1.2%)
CPU 3 idle residency:  70.24%
CPU 4 frequency: 2243 MHz
CPU 4 active residency:  20.99% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .69% 1296 MHz: 1.0% 1524 MHz: 1.1% 1752 MHz: 2.0% 1980 MHz: 1.8% 2208 MHz: 4.7% 2448 MHz: 4.2% 2676 MHz: 2.6% 2904 MHz: 1.4% 3036 MHz: .98% 3132 MHz: .00% 3168 MHz: .06% 3228 MHz: .53%)
CPU 4 idle residency:  79.01%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1471 MHz
P1-Cluster HW active residency:  20.70% (600 MHz:  44% 828 MHz: 1.0% 1056 MHz: 4.9% 1296 MHz: 3.6% 1524 MHz: 2.9% 1752 MHz: 3.2% 1980 MHz: 6.1% 2208 MHz: 9.3% 2448 MHz:  11% 2676 MHz: 5.0% 2904 MHz: 2.9% 3036 MHz: 1.5% 3132 MHz: .04% 3168 MHz:   0% 3228 MHz: 4.1%)
P1-Cluster idle residency:  79.30%
CPU 5 frequency: 2167 MHz
CPU 5 active residency:  16.19% (600 MHz: .18% 828 MHz: .01% 1056 MHz: 1.1% 1296 MHz: 1.3% 1524 MHz: .72% 1752 MHz: .60% 1980 MHz: 2.1% 2208 MHz: 2.9% 2448 MHz: 4.0% 2676 MHz: 1.3% 2904 MHz: .80% 3036 MHz: .83% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .47%)
CPU 5 idle residency:  83.81%
CPU 6 frequency: 2168 MHz
CPU 6 active residency:  10.95% (600 MHz: .03% 828 MHz: .00% 1056 MHz: .72% 1296 MHz: .83% 1524 MHz: .79% 1752 MHz: .38% 1980 MHz: .97% 2208 MHz: 2.2% 2448 MHz: 3.1% 2676 MHz: .35% 2904 MHz: .89% 3036 MHz: .58% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .13%)
CPU 6 idle residency:  89.05%
CPU 7 frequency: 2260 MHz
CPU 7 active residency:   6.26% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .36% 1296 MHz: .18% 1524 MHz: .19% 1752 MHz: .20% 1980 MHz: .95% 2208 MHz: 1.2% 2448 MHz: 2.0% 2676 MHz: .28% 2904 MHz: .41% 3036 MHz: .42% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .13%)
CPU 7 idle residency:  93.74%

CPU Power: 1854 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1883 mW

**** GPU usage ****

GPU HW active frequency: 429 MHz
GPU HW active residency:  10.05% (389 MHz: 9.2% 486 MHz:   0% 648 MHz:   0% 778 MHz: .65% 972 MHz: .25% 1296 MHz:   0%)
GPU SW requested state: (P1 :  91% P2 :   0% P3 :   0% P4 : 9.0% P5 : .42% P6 :   0%)
GPU idle residency:  89.95%
GPU Power: 29 mW
```

### cargo-build / conjet

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate conjet`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
```

```text
process_pattern=conjetd
workload_stdout:

powermetrics_stdout:
Machine model: MacBookPro18,3
OS version: 25E253
Boot arguments:
Boot time: Wed May 27 11:45:46 2026
```

### container-start-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
networkserviceproxy                39733  0.03      0.00   0.00    0.00               0.00    0.00              0.00
mDNSResponderHelper                475    0.03      49.88  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    96593  0.06      59.69  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     1721.95   53.99  3603.69 22.23              7827.96 565.49            1327.22

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1451 MHz
E-Cluster HW active residency:  68.55% (600 MHz:   0% 972 MHz:  51% 1332 MHz: 2.4% 1704 MHz:  11% 2064 MHz:  35%)
E-Cluster idle residency:  31.45%
CPU 0 frequency: 1494 MHz
CPU 0 active residency:  63.36% (600 MHz:   0% 972 MHz:  29% 1332 MHz: 2.0% 1704 MHz: 9.0% 2064 MHz:  24%)
CPU 0 idle residency:  36.64%
CPU 1 frequency: 1496 MHz
CPU 1 active residency:  62.81% (600 MHz:   0% 972 MHz:  28% 1332 MHz: 2.0% 1704 MHz: 8.9% 2064 MHz:  24%)
CPU 1 idle residency:  37.19%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2157 MHz
P0-Cluster HW active residency:  45.78% (600 MHz:  11% 828 MHz: .42% 1056 MHz: 6.2% 1296 MHz: 2.0% 1524 MHz: 4.8% 1752 MHz: 9.3% 1980 MHz: 7.9% 2208 MHz:  10% 2448 MHz:  11% 2676 MHz: 9.0% 2904 MHz: 6.2% 3036 MHz: 6.5% 3132 MHz: 5.4% 3168 MHz: 2.0% 3228 MHz: 7.8%)
P0-Cluster idle residency:  54.22%
CPU 2 frequency: 2517 MHz
CPU 2 active residency:  36.68% (600 MHz: .20% 828 MHz: .01% 1056 MHz: .79% 1296 MHz: .38% 1524 MHz: 1.4% 1752 MHz: 2.9% 1980 MHz: 2.9% 2208 MHz: 5.8% 2448 MHz: 5.7% 2676 MHz: 2.4% 2904 MHz: 2.2% 3036 MHz: .98% 3132 MHz: .53% 3168 MHz: 1.1% 3228 MHz: 9.3%)
CPU 2 idle residency:  63.32%
CPU 3 frequency: 2534 MHz
CPU 3 active residency:  25.02% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .42% 1296 MHz: .31% 1524 MHz: .78% 1752 MHz: 2.1% 1980 MHz: 2.4% 2208 MHz: 3.8% 2448 MHz: 4.4% 2676 MHz: 1.3% 2904 MHz: .60% 3036 MHz: .28% 3132 MHz: .32% 3168 MHz: .60% 3228 MHz: 7.6%)
CPU 3 idle residency:  74.98%
CPU 4 frequency: 2502 MHz
CPU 4 active residency:  16.82% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .17% 1296 MHz: .26% 1524 MHz: .60% 1752 MHz: 1.0% 1980 MHz: 1.7% 2208 MHz: 2.6% 2448 MHz: 3.7% 2676 MHz: 1.5% 2904 MHz: .69% 3036 MHz: .11% 3132 MHz: .06% 3168 MHz: .10% 3228 MHz: 4.3%)
CPU 4 idle residency:  83.18%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1545 MHz
P1-Cluster HW active residency:  21.44% (600 MHz:  51% 828 MHz: .40% 1056 MHz: 1.7% 1296 MHz: 1.3% 1524 MHz: 2.0% 1752 MHz: 3.6% 1980 MHz: 4.1% 2208 MHz: 5.0% 2448 MHz: 6.5% 2676 MHz: 3.6% 2904 MHz: 3.2% 3036 MHz: 1.9% 3132 MHz: 2.2% 3168 MHz: 1.8% 3228 MHz:  12%)
P1-Cluster idle residency:  78.56%
CPU 5 frequency: 2517 MHz
CPU 5 active residency:  18.81% (600 MHz: .11% 828 MHz:   0% 1056 MHz: .14% 1296 MHz: .60% 1524 MHz: .28% 1752 MHz: 1.5% 1980 MHz: 1.7% 2208 MHz: 2.4% 2448 MHz: 3.6% 2676 MHz: 1.9% 2904 MHz: 1.2% 3036 MHz: .92% 3132 MHz: .40% 3168 MHz: .26% 3228 MHz: 3.9%)
CPU 5 idle residency:  81.19%
CPU 6 frequency: 2335 MHz
CPU 6 active residency:   7.56% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .04% 1296 MHz: .53% 1524 MHz: .25% 1752 MHz: .79% 1980 MHz: .72% 2208 MHz: 1.3% 2448 MHz: 2.0% 2676 MHz: .16% 2904 MHz: .02% 3036 MHz: .10% 3132 MHz: .02% 3168 MHz: .03% 3228 MHz: 1.5%)
CPU 6 idle residency:  92.44%
CPU 7 frequency: 2328 MHz
CPU 7 active residency:   3.83% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .00% 1296 MHz: .44% 1524 MHz: .13% 1752 MHz: .36% 1980 MHz: .38% 2208 MHz: .26% 2448 MHz: 1.3% 2676 MHz: .01% 2904 MHz: .09% 3036 MHz: .01% 3132 MHz: .00% 3168 MHz: .00% 3228 MHz: .79%)
CPU 7 idle residency:  96.17%

CPU Power: 1896 mW
GPU Power: 29 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1925 mW

**** GPU usage ****

GPU HW active frequency: 467 MHz
GPU HW active residency:   9.60% (389 MHz: 7.3% 486 MHz: .48% 648 MHz: .46% 778 MHz: 1.2% 972 MHz: .19% 1296 MHz:   0%)
GPU SW requested state: (P1 :  77% P2 : 2.6% P3 : 6.2% P4 :  14% P5 : .30% P6 :   0%)
GPU idle residency:  90.40%
GPU Power: 29 mW
```

### hot-reload-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    28631  0.04      72.36  0.00    0.00               0.97    0.00              0.00
nesessionmanager                   365    0.01      0.00   0.00    0.00               0.00    0.00              0.00
Brave Browser Helper (Renderer)    96590  0.03      57.79  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     2409.26   66.69  3260.41 34.88              6992.68 0.00              1413.66

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1469 MHz
E-Cluster HW active residency: 100.00% (600 MHz:   0% 972 MHz:  49% 1332 MHz: 4.8% 1704 MHz: 6.3% 2064 MHz:  40%)
E-Cluster idle residency:   0.00%
CPU 0 frequency: 1454 MHz
CPU 0 active residency:  83.07% (600 MHz:   0% 972 MHz:  42% 1332 MHz: 4.1% 1704 MHz: 5.1% 2064 MHz:  32%)
CPU 0 idle residency:  16.93%
CPU 1 frequency: 1465 MHz
CPU 1 active residency:  81.84% (600 MHz:   0% 972 MHz:  41% 1332 MHz: 3.7% 1704 MHz: 5.6% 2064 MHz:  32%)
CPU 1 idle residency:  18.16%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2246 MHz
P0-Cluster HW active residency:  52.79% (600 MHz: 5.4% 828 MHz: .41% 1056 MHz: 5.8% 1296 MHz: 5.4% 1524 MHz: 3.4% 1752 MHz: 6.2% 1980 MHz:  14% 2208 MHz:  13% 2448 MHz: 8.0% 2676 MHz: 6.9% 2904 MHz: 8.4% 3036 MHz: 6.5% 3132 MHz: 4.9% 3168 MHz: 1.4% 3228 MHz:  11%)
P0-Cluster idle residency:  47.21%
CPU 2 frequency: 2506 MHz
CPU 2 active residency:  35.22% (600 MHz: .09% 828 MHz: .01% 1056 MHz: .42% 1296 MHz: 1.6% 1524 MHz: 1.2% 1752 MHz: 2.2% 1980 MHz: 4.9% 2208 MHz: 4.5% 2448 MHz: 2.6% 2676 MHz: 2.6% 2904 MHz: 3.6% 3036 MHz: 1.5% 3132 MHz: .66% 3168 MHz: .79% 3228 MHz: 8.5%)
CPU 2 idle residency:  64.78%
CPU 3 frequency: 2494 MHz
CPU 3 active residency:  29.10% (600 MHz: .05% 828 MHz:   0% 1056 MHz: .32% 1296 MHz: .89% 1524 MHz: .98% 1752 MHz: 2.2% 1980 MHz: 4.1% 2208 MHz: 4.1% 2448 MHz: 2.9% 2676 MHz: 2.0% 2904 MHz: 2.9% 3036 MHz: .96% 3132 MHz: .72% 3168 MHz: 1.0% 3228 MHz: 6.0%)
CPU 3 idle residency:  70.90%
CPU 4 frequency: 2422 MHz
CPU 4 active residency:  15.97% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .15% 1296 MHz: .75% 1524 MHz: .56% 1752 MHz: 1.3% 1980 MHz: 2.4% 2208 MHz: 2.3% 2448 MHz: 1.7% 2676 MHz: 1.6% 2904 MHz: 1.6% 3036 MHz: .70% 3132 MHz: .19% 3168 MHz: .35% 3228 MHz: 2.4%)
CPU 4 idle residency:  84.03%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1498 MHz
P1-Cluster HW active residency:  16.76% (600 MHz:  52% 828 MHz: .40% 1056 MHz: 1.5% 1296 MHz: 2.2% 1524 MHz: 2.2% 1752 MHz: 4.7% 1980 MHz: 3.7% 2208 MHz: 5.3% 2448 MHz: 4.4% 2676 MHz: 3.3% 2904 MHz: 4.6% 3036 MHz: 1.2% 3132 MHz: 1.3% 3168 MHz: 1.0% 3228 MHz:  12%)
P1-Cluster idle residency:  83.24%
CPU 5 frequency: 2393 MHz
CPU 5 active residency:  13.76% (600 MHz: .11% 828 MHz:   0% 1056 MHz: .43% 1296 MHz: .73% 1524 MHz: .84% 1752 MHz: 1.7% 1980 MHz: .83% 2208 MHz: 1.4% 2448 MHz: 1.0% 2676 MHz: 2.1% 2904 MHz: .91% 3036 MHz: .73% 3132 MHz: .35% 3168 MHz: .58% 3228 MHz: 2.0%)
CPU 5 idle residency:  86.24%
CPU 6 frequency: 2392 MHz
CPU 6 active residency:   5.84% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .03% 1296 MHz: .46% 1524 MHz: .16% 1752 MHz: .80% 1980 MHz: .56% 2208 MHz: .93% 2448 MHz: .53% 2676 MHz: .14% 2904 MHz: .55% 3036 MHz: .30% 3132 MHz: .00% 3168 MHz: .03% 3228 MHz: 1.3%)
CPU 6 idle residency:  94.16%
CPU 7 frequency: 2052 MHz
CPU 7 active residency:   2.06% (600 MHz: .00% 828 MHz:   0% 1056 MHz: .06% 1296 MHz: .31% 1524 MHz: .15% 1752 MHz: .54% 1980 MHz: .14% 2208 MHz: .22% 2448 MHz: .18% 2676 MHz: .01% 2904 MHz: .23% 3036 MHz: .07% 3132 MHz: .00% 3168 MHz: .00% 3228 MHz: .14%)
CPU 7 idle residency:  97.94%

CPU Power: 1904 mW
GPU Power: 26 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1930 mW

**** GPU usage ****

GPU HW active frequency: 532 MHz
GPU HW active residency:   9.13% (389 MHz: 5.8% 486 MHz: .24% 648 MHz: .24% 778 MHz: 2.4% 972 MHz: .50% 1296 MHz:   0%)
GPU SW requested state: (P1 :  60% P2 : 6.7% P3 : 6.9% P4 :  21% P5 : 5.3% P6 :   0%)
GPU idle residency:  90.87%
GPU Power: 28 mW
```

### compose-loop / orbstack

- Exit: 124
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c i=0
while [ "$i" -lt 30 ]; do
  docker --context "$1" run --rm alpine:3.20 true >/dev/null || exit $?
  i=$((i + 1))
done conjet-energy-gate orbstack`

```text
workload_stderr:
process timed out after 30.000s
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
Second underflow occured.
Second underflow occured.
```

```text
Brave Browser Helper (Renderer)    96676  0.06      64.59  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    28631  0.02      57.39  0.00    0.00               0.97    0.00              0.00
Brave Browser Helper (Renderer)    96593  0.04      63.55  0.00    0.00               0.97    0.00              0.00
ALL_TASKS                          -2     1774.77   47.16  2718.57 36.76              6288.51 429.55            1014.90

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1462 MHz
E-Cluster HW active residency:  71.58% (600 MHz:   0% 972 MHz:  48% 1332 MHz: 5.7% 1704 MHz:  11% 2064 MHz:  35%)
E-Cluster idle residency:  28.42%
CPU 0 frequency: 1524 MHz
CPU 0 active residency:  65.62% (600 MHz:   0% 972 MHz:  26% 1332 MHz: 4.9% 1704 MHz: 9.0% 2064 MHz:  25%)
CPU 0 idle residency:  34.38%
CPU 1 frequency: 1523 MHz
CPU 1 active residency:  65.91% (600 MHz:   0% 972 MHz:  26% 1332 MHz: 4.9% 1704 MHz: 9.1% 2064 MHz:  26%)
CPU 1 idle residency:  34.09%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2252 MHz
P0-Cluster HW active residency:  48.27% (600 MHz: 3.4% 828 MHz:   0% 1056 MHz: .16% 1296 MHz: 2.7% 1524 MHz: 6.0% 1752 MHz:  10% 1980 MHz:  17% 2208 MHz:  13% 2448 MHz:  15% 2676 MHz:  12% 2904 MHz: 9.6% 3036 MHz: 4.6% 3132 MHz: 2.3% 3168 MHz: 1.2% 3228 MHz: 2.3%)
P0-Cluster idle residency:  51.73%
CPU 2 frequency: 2274 MHz
CPU 2 active residency:  35.05% (600 MHz: .08% 828 MHz:   0% 1056 MHz: .04% 1296 MHz: 1.1% 1524 MHz: 2.8% 1752 MHz: 4.7% 1980 MHz: 4.9% 2208 MHz: 5.2% 2448 MHz: 5.4% 2676 MHz: 3.8% 2904 MHz: 3.8% 3036 MHz: 1.5% 3132 MHz: .75% 3168 MHz: .37% 3228 MHz: .60%)
CPU 2 idle residency:  64.95%
CPU 3 frequency: 2286 MHz
CPU 3 active residency:  26.43% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .08% 1296 MHz: .50% 1524 MHz: 1.8% 1752 MHz: 2.4% 1980 MHz: 5.0% 2208 MHz: 4.8% 2448 MHz: 4.3% 2676 MHz: 2.8% 2904 MHz: 2.5% 3036 MHz: 1.1% 3132 MHz: .57% 3168 MHz: .10% 3228 MHz: .52%)
CPU 3 idle residency:  73.57%
CPU 4 frequency: 2210 MHz
CPU 4 active residency:  17.38% (600 MHz: .04% 828 MHz:   0% 1056 MHz: .02% 1296 MHz: .36% 1524 MHz: 1.5% 1752 MHz: 2.2% 1980 MHz: 3.5% 2208 MHz: 2.9% 2448 MHz: 2.3% 2676 MHz: 2.2% 2904 MHz: 1.8% 3036 MHz: .46% 3132 MHz: .05% 3168 MHz: .02% 3228 MHz: .04%)
CPU 4 idle residency:  82.62%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1329 MHz
P1-Cluster HW active residency:  14.11% (600 MHz:  55% 828 MHz: .93% 1056 MHz: 2.7% 1296 MHz: 3.6% 1524 MHz: 2.1% 1752 MHz: 3.3% 1980 MHz: 3.6% 2208 MHz: 7.3% 2448 MHz: 6.4% 2676 MHz: 6.0% 2904 MHz: 4.9% 3036 MHz: 1.8% 3132 MHz: .74% 3168 MHz: .32% 3228 MHz: 1.5%)
P1-Cluster idle residency:  85.89%
CPU 5 frequency: 2115 MHz
CPU 5 active residency:  11.13% (600 MHz: .17% 828 MHz: .00% 1056 MHz: .81% 1296 MHz: 1.2% 1524 MHz: .59% 1752 MHz: .15% 1980 MHz: 2.0% 2208 MHz: 1.9% 2448 MHz: 1.5% 2676 MHz: 1.5% 2904 MHz: .78% 3036 MHz: .57% 3132 MHz: .07% 3168 MHz: .01% 3228 MHz: .03%)
CPU 5 idle residency:  88.87%
CPU 6 frequency: 2114 MHz
CPU 6 active residency:   5.10% (600 MHz: .05% 828 MHz: .01% 1056 MHz: .32% 1296 MHz: .38% 1524 MHz: .47% 1752 MHz: .02% 1980 MHz: .87% 2208 MHz: .97% 2448 MHz: 1.1% 2676 MHz: .41% 2904 MHz: .28% 3036 MHz: .18% 3132 MHz: .05% 3168 MHz:   0% 3228 MHz: .02%)
CPU 6 idle residency:  94.90%
CPU 7 frequency: 1889 MHz
CPU 7 active residency:   2.35% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .44% 1296 MHz: .47% 1524 MHz: .10% 1752 MHz: .00% 1980 MHz: .25% 2208 MHz: .36% 2448 MHz: .28% 2676 MHz: .18% 2904 MHz: .11% 3036 MHz: .11% 3132 MHz: .02% 3168 MHz:   0% 3228 MHz:   0%)
CPU 7 idle residency:  97.65%

CPU Power: 1465 mW
GPU Power: 28 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1493 mW

**** GPU usage ****

GPU HW active frequency: 430 MHz
GPU HW active residency:  10.06% (389 MHz: 8.9% 486 MHz: .18% 648 MHz:   0% 778 MHz: 1.0% 972 MHz: .01% 1296 MHz:   0%)
GPU SW requested state: (P1 :  88% P2 : 1.8% P3 : 2.5% P4 : 7.2% P5 : .94% P6 :   0%)
GPU idle residency:  89.94%
GPU Power: 28 mW
```

### cargo-build / orbstack

- Exit: 127
- Command: `/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy --handle-invalid-values --buffer-size 1 --sample-rate 1000 --sample-count 30 --workload /usr/bin/env sh -c docker --context "$1" run --rm rust:1-alpine sh -lc 'cargo new --bin /tmp/conjet-energy >/dev/null && cd /tmp/conjet-energy && cargo build >/dev/null' conjet-energy-gate orbstack`

```text
workload_stderr:
sh: cargo: not found

powermetrics_stderr:
Second underflow occured.
```

```text
com.apple.appkit.xpc.openAndSave   43929  0.06      24.29  0.00    0.00               0.99    0.00              0.00
assistantd                         49075  0.09      53.72  0.00    0.00               0.99    0.99              0.00
mDNSResponderHelper                475    0.03      37.32  0.00    0.00               0.99    0.00              0.00
ALL_TASKS                          -2     1893.11   47.33  3016.20 32.52              6871.92 506.48            1261.87

**** Processor usage ****

E-Cluster Online: 100%
E-Cluster HW active frequency: 1441 MHz
E-Cluster HW active residency:  75.84% (600 MHz:   0% 972 MHz:  49% 1332 MHz: 6.1% 1704 MHz:  13% 2064 MHz:  32%)
E-Cluster idle residency:  24.16%
CPU 0 frequency: 1492 MHz
CPU 0 active residency:  70.00% (600 MHz:   0% 972 MHz:  30% 1332 MHz: 4.3% 1704 MHz:  10% 2064 MHz:  25%)
CPU 0 idle residency:  30.00%
CPU 1 frequency: 1501 MHz
CPU 1 active residency:  68.69% (600 MHz:   0% 972 MHz:  29% 1332 MHz: 4.4% 1704 MHz:  11% 2064 MHz:  25%)
CPU 1 idle residency:  31.31%

P0-Cluster Online: 100%
P0-Cluster HW active frequency: 2177 MHz
P0-Cluster HW active residency:  50.14% (600 MHz: 5.6% 828 MHz:   0% 1056 MHz: 6.1% 1296 MHz: 5.5% 1524 MHz: 8.7% 1752 MHz: 5.7% 1980 MHz: 8.0% 2208 MHz:  16% 2448 MHz:  12% 2676 MHz: 5.6% 2904 MHz: 8.2% 3036 MHz: 4.9% 3132 MHz: 4.1% 3168 MHz: 1.1% 3228 MHz: 7.9%)
P0-Cluster idle residency:  49.86%
CPU 2 frequency: 2353 MHz
CPU 2 active residency:  39.17% (600 MHz: .11% 828 MHz:   0% 1056 MHz: 1.7% 1296 MHz: 1.8% 1524 MHz: 3.0% 1752 MHz: 2.0% 1980 MHz: 2.6% 2208 MHz: 8.7% 2448 MHz: 6.4% 2676 MHz: 1.2% 2904 MHz: 2.1% 3036 MHz: 1.1% 3132 MHz: .41% 3168 MHz: .79% 3228 MHz: 7.3%)
CPU 2 idle residency:  60.83%
CPU 3 frequency: 2386 MHz
CPU 3 active residency:  26.16% (600 MHz: .02% 828 MHz:   0% 1056 MHz: .55% 1296 MHz: 1.3% 1524 MHz: 2.6% 1752 MHz: .52% 1980 MHz: 1.4% 2208 MHz: 6.7% 2448 MHz: 4.2% 2676 MHz: 1.2% 2904 MHz: 1.2% 3036 MHz: .65% 3132 MHz: .10% 3168 MHz: .40% 3228 MHz: 5.3%)
CPU 3 idle residency:  73.84%
CPU 4 frequency: 2487 MHz
CPU 4 active residency:  17.74% (600 MHz:   0% 828 MHz:   0% 1056 MHz: .15% 1296 MHz: .50% 1524 MHz: 1.1% 1752 MHz: .20% 1980 MHz: .79% 2208 MHz: 5.2% 2448 MHz: 3.4% 2676 MHz: .46% 2904 MHz: .93% 3036 MHz: .41% 3132 MHz: .07% 3168 MHz: .47% 3228 MHz: 4.0%)
CPU 4 idle residency:  82.26%

P1-Cluster Online: 100%
P1-Cluster HW active frequency: 1462 MHz
P1-Cluster HW active residency:  17.98% (600 MHz:  49% 828 MHz: .41% 1056 MHz: 3.4% 1296 MHz: 3.0% 1524 MHz: 6.3% 1752 MHz: 2.7% 1980 MHz: 2.8% 2208 MHz: 9.2% 2448 MHz: 6.3% 2676 MHz: .87% 2904 MHz: 3.3% 3036 MHz: .65% 3132 MHz: .69% 3168 MHz: .42% 3228 MHz:  11%)
P1-Cluster idle residency:  82.02%
CPU 5 frequency: 2224 MHz
CPU 5 active residency:  14.60% (600 MHz: .14% 828 MHz:   0% 1056 MHz: 1.3% 1296 MHz: 1.0% 1524 MHz: 1.5% 1752 MHz: 1.2% 1980 MHz: .66% 2208 MHz: 2.1% 2448 MHz: 2.1% 2676 MHz: .47% 2904 MHz: .84% 3036 MHz: .07% 3132 MHz:   0% 3168 MHz: .26% 3228 MHz: 2.9%)
CPU 5 idle residency:  85.40%
CPU 6 frequency: 1947 MHz
CPU 6 active residency:   7.37% (600 MHz: .03% 828 MHz:   0% 1056 MHz: 1.0% 1296 MHz: 1.0% 1524 MHz: .98% 1752 MHz: .59% 1980 MHz: .11% 2208 MHz: 1.3% 2448 MHz: 1.4% 2676 MHz: .10% 2904 MHz: .05% 3036 MHz: .01% 3132 MHz:   0% 3168 MHz: .01% 3228 MHz: .73%)
CPU 6 idle residency:  92.63%
CPU 7 frequency: 1893 MHz
CPU 7 active residency:   3.49% (600 MHz: .01% 828 MHz:   0% 1056 MHz: .69% 1296 MHz: .48% 1524 MHz: .49% 1752 MHz: .30% 1980 MHz: .02% 2208 MHz: .35% 2448 MHz: .69% 2676 MHz: .02% 2904 MHz: .01% 3036 MHz: .00% 3132 MHz:   0% 3168 MHz:   0% 3228 MHz: .43%)
CPU 7 idle residency:  96.51%

CPU Power: 1717 mW
GPU Power: 25 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1741 mW

**** GPU usage ****

GPU HW active frequency: 507 MHz
GPU HW active residency:   7.97% (389 MHz: 5.4% 486 MHz: .18% 648 MHz: .50% 778 MHz: 1.7% 972 MHz: .25% 1296 MHz:   0%)
GPU SW requested state: (P1 :  66% P2 : 5.6% P3 : 6.5% P4 :  21% P5 : 1.1% P6 :   0%)
GPU idle residency:  92.03%
GPU Power: 25 mW
```

# Conjet Benchmark Final Verdict

Date: 2026-05-31

## Executive Verdict

Conjet's strongest supported claim remains the previously verified warm 30-sample wall-time gate against OrbStack.

This iteration materially improves benchmark credibility: cold/no-cache phases exist, strict bind is separated from SmartMount/native-overlay bind, topology metadata is reported, polyglot and energy gates exist, the stop path is bounded, and process output capture has a stress guard.

The new measured evidence does not support global cold superiority or global energy superiority yet. It does support a narrower idle-power result: in the clean 10-sample powermetrics run, Conjet measured lower idle average power than OrbStack.

## Evidence Reviewed

- Warm baseline: previous verified 30-sample warm gate, candidate `conjet`, baseline `orbstack`, verdict `passed`.
- Cold raw data: `bench/reports/next-iteration/cold-base-prepulled-run/docker.json`.
- Energy clean run: `bench/reports/energy-gate-clean/all-results.json` and `bench/reports/energy-gate-clean/energy-gate.md`.
- Energy cargo run: `bench/reports/energy-gate-cargo/all-results.json` and `bench/reports/energy-gate-cargo/energy-gate.md`.
- Implementation report: `bench/reports/next-iteration/REPORT.md`.

## Category Verdicts

| Category | Verdict | Evidence | Caveat |
|---|---|---|---|
| Warm wall-time | Proven | Previous 30-sample warm gate passed | Warm/dev-loop only; not cold/no-cache |
| Cold/no-cache | Partial, strict gate failed | 500 cold-base-prepulled rows; Conjet 0/250 failures; Conjet P50 faster on 23/25 comparable workloads | OrbStack had 16/250 failures; 4 P95 regressions; wrapper needed manual termination after writing `docker.json` |
| Strict bind | Not proven | Strict-bind workloads and metadata exist | Topology performance gate was not completed cleanly |
| SmartMount/native-overlay | Not proven as a gate | Smart-bind workloads and metadata exist | Cold P95 regressions were seen for `smart-bind-hot-reload` and `smart-bind-pnpm-install` |
| ConjetFS fast path | Not proven as a new gate | ConjetFS workloads remain present and labeled | Cold fast-path gate was affected by baseline failures and missing clean hot-reload baseline evidence |
| Polyglot real projects | Infrastructure proven, performance not proven | `polyglot-gate` implementation exists for JS, Python, JVM, .NET, Go, Rust, and C/C++ | Full Conjet vs OrbStack polyglot run was not measured |
| Energy/power | Partial | Clean powermetrics run measured idle and active workloads; cargo rerun fixed failures | Only idle favors Conjet; active energy favors OrbStack in these runs |
| Stop hook | Implementation/test proven | Bounded stop timeout and tests | Full benchmark stop-hook completion should still be watched in the next long run |
| Process output capture | Proven by test | 500-process capture stress test passed | This is a regression guard, not a performance benchmark |

## Cold Gate Evaluation

Raw file: `bench/reports/next-iteration/cold-base-prepulled-run/docker.json`.

Summary:

- Total rows: 500.
- Conjet: 250 samples, 0 failures.
- OrbStack: 250 samples, 16 failures.
- Comparable workload names: 25.
- Conjet P50 wins: 23/25.
- Conjet P95 wins: 21/25.

P95 regressions where Conjet was slower:

| Workload | Conjet P95 | OrbStack P95 | Ratio |
|---|---:|---:|---:|
| `smart-bind-hot-reload` | 1.028s | 0.539s | 1.907 |
| `smart-bind-pnpm-install` | 3.950s | 3.376s | 1.170 |
| `strict-bind-hot-reload` | 1.067s | 0.364s | 2.929 |
| `strict-bind-pnpm-install` | 3.735s | 3.556s | 1.050 |

Verdict: Partial, strict gate failed.

Interpretation: Conjet looks competitive and often faster in raw cold-base-prepulled timing, with zero candidate failures, but the result is not claim-grade. The baseline instability and P95 regressions prevent a cold superiority claim.

## Energy Gate Evaluation

Clean run file: `bench/reports/energy-gate-clean/all-results.json`.

Cargo rerun file: `bench/reports/energy-gate-cargo/all-results.json`.

Idle power:

| Runtime | Samples | Failures | Mean Power |
|---|---:|---:|---:|
| Conjet | 10 | 0 | 0.513 W |
| OrbStack | 10 | 0 | 0.545 W |

Idle verdict: Proven for this measured run. Conjet used lower idle average power, ratio 0.943.

Active energy-to-solution ratios, Conjet divided by OrbStack:

| Workload | Duration P50 Ratio | Energy P50 Ratio | Mean Energy Ratio | Mean Power Ratio |
|---|---:|---:|---:|---:|
| `compose-loop` | 0.983 | 2.553 | 2.463 | 2.557 |
| `container-start-loop` | 0.989 | 2.608 | 2.668 | 2.755 |
| `hot-reload-loop` | 0.952 | 2.522 | 2.572 | 2.755 |
| `npm-install` | 0.974 | 1.308 | 1.246 | 1.303 |
| `pnpm-install` | 0.964 | 1.172 | 1.118 | 1.136 |
| `cargo-build` | 1.018 | 2.114 | 2.025 | 2.019 |

Active energy verdict: Failed for Conjet energy superiority in these measured workloads. Conjet was similar or faster in some durations, but powermetrics reported materially higher active average power and higher energy-to-solution than OrbStack.

Cargo status: Fixed as a harness failure. The cargo-only energy run produced 20 rows, 10 samples per runtime, 0 failures, 10 power rows per runtime, and 10 energy rows per runtime. The result does not favor Conjet on energy.

## Supported Claims

Proven:

- Conjet beats OrbStack on the previously verified configured warm 30-sample wall-time benchmark matrix.
- In the clean 10-sample idle powermetrics run, Conjet measured lower idle average power than OrbStack: 0.513 W vs 0.545 W.

Supported by implementation and tests:

- Benchmark results now carry typed metadata needed for cache, topology, and energy reporting.
- Strict bind and SmartMount/native-overlay bind workloads are named and labeled distinctly.
- Deprecated `bind-*` aliases are explicit compatibility aliases rather than silent strict-bind claims.
- Cold/no-cache phases are separate from warm phases.
- Energy measurement can run with powermetrics and can skip honestly when privilege is unavailable.
- Stop cleanup is bounded and reports structured cleanup outcomes.
- Process output capture passed the 500-process stress guard.

## Failed Or Not Supported Claims

Failed in current measured energy data:

- Conjet has lower active energy-to-solution than OrbStack on `compose-loop`, `container-start-loop`, `hot-reload-loop`, `npm-install`, `pnpm-install`, or `cargo-build`.
- Conjet has lower active average power than OrbStack on those measured active workloads.

Not proven:

- Conjet beats OrbStack on cold/no-cache first-run workloads.
- Conjet strict bind is faster than OrbStack strict bind.
- Conjet SmartMount/native-overlay topology is faster than OrbStack on a completed topology gate.
- Conjet ConjetFS fast path beats OrbStack on the new cold/topology gates.
- Conjet polyglot real-project workloads beat OrbStack.
- Conjet is globally 10x faster.
- Conjet is always faster than OrbStack.

## Recommended Next Increment

1. Fix the cold gate wrapper so it exits cleanly after writing and scoring raw Docker results.
2. Stabilize the OrbStack baseline before rerunning cold gates; the missing socket and EOF failures make the current cold comparison non-final.
3. Tune or explain the P95 regressions in `strict-bind-pnpm-install`, `smart-bind-pnpm-install`, `strict-bind-hot-reload`, and `smart-bind-hot-reload`.
4. Run `topology-gate` cleanly with 10 samples to turn the naming/topology implementation into measured topology evidence.
5. Run `polyglot-gate` with at least 5 samples after confirming each ecosystem image/dependency path is pre-pulled or explicitly labeled online.
6. Keep the idle-power claim narrow. Investigate why active powermetrics reports higher Conjet power before making any active energy claim.

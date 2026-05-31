# Conjet Next Iteration Report

Date: 2026-05-31

## Benchmark Run Addendum

Run command:

```sh
swift run conjet bench global-gate --contexts conjet,orbstack --samples 10 --phase cold-base-prepulled --no-sudo --no-power --output-dir bench/reports/next-iteration/cold-base-prepulled-run
```

Raw results:

- `bench/reports/next-iteration/cold-base-prepulled-run/docker.json`
- 500 Docker benchmark result rows.
- 250 Conjet rows, 0 failures.
- 250 OrbStack rows, 16 failures.
- Conjet was faster at P50 on 23 of 25 directly comparable workload names.
- Conjet was faster at P95 on 21 of 25 directly comparable workload names.

Strict gate score:

```sh
swift run conjet bench gate --reports bench/reports/next-iteration/cold-base-prepulled-run/docker.json --candidate conjet --baselines orbstack --min-samples 10 --phase cold-base-prepulled --no-idle --no-power --json
```

Strict gate verdict: Failed.

Reason: The gate evaluator returned `benchmark gate failed; faster-than-OrbStack claim is not proven`. OrbStack had 16 baseline failures, mostly Docker socket `EOF` / missing socket errors after OrbStack restarted during the run. The strict rules also flagged P95 regressions for `strict-bind-pnpm-install` and `smart-bind-pnpm-install`, and missing baseline `hot_reload_seconds` evidence for the fast-path hot-reload rule.

Wrapper caveat: Docker collection completed and wrote `docker.json`, but the `global-gate` wrapper did not exit after final Docker collection. It was terminated after the raw result file was confirmed complete and independently scored with `bench gate`.

Energy command:

```sh
swift run conjet bench energy-gate --contexts conjet,orbstack --workloads idle --samples 1 --output-dir bench/reports/next-iteration/energy-skip-run
```

Energy verdict: Skipped.

Reason: `powermetrics requires sudo/noninteractive privileges`.

## 1. Summary of Changes

This iteration adds the benchmark/reporting infrastructure needed to distinguish warm dev-loop wins from cold/no-cache behavior, strict bind from SmartMount/native-overlay bind, and measured energy from unmeasured claims.

- Added benchmark phases for `warm`, `cold-base-prepulled`, `no-cache`, and `true-cold`.
- Split ambiguous `bind-*` workloads into `strict-bind-*` and `smart-bind-*` workloads, while preserving old `bind-*` aliases as deprecated mappings to smart bind.
- Added topology metadata to benchmark results, including strict bind, SmartMount/native-overlay count, Linux-native write paths, ConjetFS fast-path state, and cache mode.
- Added `topology-gate`, `polyglot-gate`, and `energy-gate` CLI entry points.
- Added an energy harness that measures with `powermetrics` when privilege is available and skips honestly when it is not.
- Bounded the daemon stop path so cleanup failures/timeouts are reported separately instead of hanging the stop hook.
- Added regression tests for benchmark naming, metadata, cold/no-cache behavior, energy skip/fail policy, stop timeout, and process output capture stress.

## 2. Commits or Files Changed

No commit was created in this iteration.

Primary code changes:

- `Sources/ConjetBench/BenchmarkResult.swift`
- `Sources/ConjetBench/BenchmarkClaimGate.swift`
- `Sources/ConjetBench/DockerBenchmarkSuite.swift`
- `Sources/ConjetBench/BenchmarkReleaseGate.swift`
- `Sources/ConjetBench/BenchmarkMarkdownReport.swift`
- `Sources/ConjetBench/BenchmarkEnergyGate.swift`
- `Sources/ConjetBench/PolyglotBenchmarkSuite.swift`
- `Sources/ConjetBench/ActivePowerSampler.swift`
- `Sources/ConjetBench/PowerMetricsSampler.swift`
- `Sources/ConjetCLI/main.swift`
- `Sources/ConjetCore/UnixSocket.swift`
- `Sources/ConjetDaemon/main.swift`
- `Sources/ConjetVZ/VirtualMachineController.swift`
- `Tests/ConjetBenchTests/BenchmarkSchemaTests.swift`
- `Tests/ConjetCoreTests/ProcessRunnerTests.swift`
- `Tests/ConjetCoreTests/UnixSocketTests.swift`
- `bench/reports/next-iteration/REPORT.md`

## 3. Warm Gate Status

Status: Proven from the previous verified gate.

Evidence: The existing 30-sample warm gate passed before this iteration with candidate `conjet`, baseline `orbstack`, sample phase `warm`, and verdict `passed`.

Caveat: This iteration did not rerun the full warm 30-sample wall-time matrix. The supported claim remains limited to the configured warm benchmark matrix that already passed.

## 4. Cold/No-Cache Gate Status

Status: Failed under the strict cold-base-prepulled gate; Conjet cold superiority is not proven.

Evidence: The 10-sample cold-base-prepulled Docker collection completed with 500 rows. Conjet had 0 failures, OrbStack had 16 failures, and the strict gate evaluator failed the gate. Raw timing data strongly favored Conjet on most workloads, but the gate cannot be counted as passed because the baseline failed during the run and two pnpm bind P95 comparisons exceeded 1.0.

Caveat: Cold first-run superiority is not claimed. The OrbStack baseline instability must be resolved and the gate rerun cleanly before this can become a proven cold claim.

## 5. Strict-Bind vs Smart-Bind vs ConjetFS Status

Status: Infrastructure proven; performance not proven.

Evidence: Workloads are now separated into:

- `strict-bind-*`: host bind into `/app`, no Linux-native dependency or build overlay.
- `smart-bind-*`: host bind into `/app` plus Linux-native overlay paths such as `/app/node_modules` or `/app/target`.
- `volume-*`: Linux-native Docker volume workspace.
- `conjetfs-*`: ConjetFS-managed source sync and Linux-native workspace.

Tests verify strict bind and smart bind expose distinct topology metadata, and deprecated `bind-*` aliases map explicitly to smart bind.

Caveat: The topology performance gate was not run against OrbStack in this closeout. No strict-bind speed claim is made.

## 6. Polyglot Gate Status

Status: Infrastructure added; performance not proven.

Evidence: The new polyglot suite includes JS, Python, JVM, .NET, Go, Rust, and C/C++ workload families, with topology labels carried into results.

Caveat: The full `polyglot-gate` was not run against Conjet and OrbStack. Some ecosystem workloads are deliberately small/minimal first-pass projects; deeper framework-native projects remain a recommended next increment.

## 7. Energy Gate Status

Status: Skipped.

Evidence: `energy-gate` was run without `--require-power`. Noninteractive `powermetrics` privilege was unavailable, so the harness skipped honestly and emitted:

- `energy_verdict = "skipped"`
- `energy_skip_reason = "powermetrics requires sudo/noninteractive privileges"`
- null power and energy fields

Caveat: No measured energy-to-solution data was collected in this environment. Conjet energy or power superiority is not claimed.

## 8. Stop Hook Status

Status: Fixed at the control-path level.

Evidence: `conjet stop` now accepts `--timeout`, applies socket send/receive timeouts, and daemon stop cleanup is bounded. Cleanup completion, failure, or timeout is reported separately from the stop request.

Caveat: The normal benchmark-completion stop hook was not exercised through a full Docker benchmark gate in this closeout.

## 9. Process Output Capture Stress Status

Status: Proven by test.

Evidence: The process runner stress test runs 500 captured child processes, verifies stdout/stderr tails, checks for no `Bad file descriptor` failure, and verifies temporary capture files are cleaned up.

## 10. Any Benchmark Failures

The cold-base-prepulled strict gate failed.

Primary causes:

- OrbStack baseline instability: 16 failed OrbStack samples, mostly Docker socket `EOF` or missing socket errors.
- `strict-bind-pnpm-install`: Conjet P95 3.735s vs OrbStack P95 3.556s, ratio 1.050.
- `smart-bind-pnpm-install`: Conjet P95 3.950s vs OrbStack P95 3.376s, ratio 1.170.
- `hot-reload-fast-path`: baseline had failures and missing `hot_reload_seconds` evidence for the mapped baseline rule.

The energy run skipped because `powermetrics` requires sudo/noninteractive privilege.

## 11. Caveats

- Cold/no-cache performance is not proven until a 10-sample or 30-sample gate is run.
- Energy superiority is not proven until `powermetrics` data is collected under a permitted sudo/noninteractive setup.
- Strict bind performance is not proven until `topology-gate` results compare strict bind, smart bind, volume, and ConjetFS directly.
- SmartMount/native-overlay workloads are no longer treated as raw strict bind.
- BuildKit cache-hit detection fields are present but null when detection is unavailable.
- The previous warm gate remains valid as a warm dev-loop result, not a cold first-run result.

## 12. Exact Claims Now Supported

Proven:

- Conjet beats OrbStack on the previously verified configured warm 30-sample wall-time benchmark matrix.

Supported by implementation and tests:

- Conjet benchmark JSON can now carry mixed typed metrics needed for topology, cache, and energy reporting.
- Strict bind and smart bind/native-overlay workloads are named and labeled distinctly.
- Deprecated `bind-*` workload aliases are explicitly mapped to smart bind/native-overlay semantics.
- Cold/no-cache phases are represented separately from warm phases.
- Docker no-cache build workloads set no-cache metadata and build arguments.
- Energy measurement has a noninteractive `powermetrics` path and an honest skip path.
- Stop requests have bounded timeout behavior and structured cleanup outcomes.
- Process output capture remains stable under a 500-process stress test.
- In the cold-base-prepulled 10-sample raw run, Conjet completed all 250 collected samples without failure.

## 13. Exact Claims Still Unproven

Not proven:

- Conjet beats OrbStack on cold/no-cache first-run workloads.
- Conjet uses less power or has lower energy-to-solution than OrbStack.
- Conjet strict bind is faster than OrbStack strict bind.
- Conjet SmartMount/native-overlay is faster than OrbStack on the new topology gate.
- Conjet polyglot real-project workloads beat OrbStack.
- Conjet is globally 10x faster.
- Conjet is always faster than OrbStack.

## 14. Recommended Next Increment

Run the new gates in this order:

1. `swift run conjet bench global-gate --contexts conjet,orbstack --samples 10 --phase cold-base-prepulled --output-dir bench/reports/cold-gate-smoke`
2. `swift run conjet bench global-gate --contexts conjet,orbstack --samples 10 --phase no-cache --output-dir bench/reports/no-cache-gate-smoke`
3. `swift run conjet bench topology-gate --contexts conjet,orbstack --samples 10 --output-dir bench/reports/topology-gate-smoke`
4. `swift run conjet bench polyglot-gate --contexts conjet,orbstack --samples 5 --ecosystems js,python,jvm,dotnet,go,rust,cpp --output-dir bench/reports/polyglot-gate-smoke`
5. `swift run conjet bench energy-gate --contexts conjet,orbstack --samples 10 --output-dir bench/reports/energy-gate-smoke`

If noninteractive sudo is configured, rerun energy with `--require-power` to convert the energy status from skipped to measured.

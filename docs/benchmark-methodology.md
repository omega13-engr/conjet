# Benchmark Methodology

Conjet benchmark code lives in the standalone Swift package under
`benchmarks/`. The production `conjet` executable must not contain benchmark
commands or link benchmark modules.

All performance claims must be backed by raw JSON under `benchmarks/reports/`
and by a Markdown report that states cache mode, topology, sample count,
failures, and caveats.

## Parallel Wrapper

The standard local runner is:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,orbstack,colima \
  --samples 10 \
  --output-dir benchmarks/reports/run-all-YYYYMMDD-HHMMSS
```

The wrapper requires `sudo -v` before starting. It runs wall-time suites in
parallel and then runs energy in isolation:

- warm wall-time gate
- cold base-prepulled gate
- no-cache gate
- topology gate
- polyglot real-project gate
- energy gate

Each suite writes raw `all-results.json` and a suite Markdown report. The root
runner writes `run-all.json` and `run-all.md`.

## Topology Labels

Every result must include topology metadata:

- `strict-bind`: host source bind mounted into the container, no native overlay
  for write-heavy paths.
- `smart-bind`: host source bind mounted with Linux-native overlays for paths
  such as `/app/node_modules` or `/app/target`.
- `volume`: Linux-native Docker volume baseline.
- `conjetfs`: ConjetFS synchronized source with Linux-native workspace output.

Reports must not call a smart-bind/native-overlay workload a strict bind.

## Warm And Cold Claims

Warm gates prove warm dev-loop behavior only. Cold/no-cache claims require
results labeled with one of the cold sample phases:

- `cold-base-prepulled`
- `no-cache`
- `true-cold`

The primary cold gate should pre-pull base images, clear benchmark-specific
BuildKit cache where applicable, remove benchmark volumes between samples, and
use `docker build --no-cache` for no-cache build workloads.

## Hot Reload

Hot reload workloads measure host file write to updated HTTP response where the
workload supports it. Reports should split:

- `strict-bind-hot-reload`
- `smart-bind-hot-reload`
- `conjetfs-hot-reload`

Failures must keep `failure_reason` or `bind_failure_reason` visible in raw
metrics rather than being hidden by aggregate summaries.

## Polyglot Coverage

The polyglot gate is intended to test whether filesystem/topology benefits
generalize beyond synthetic Node/Cargo workloads:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,orbstack,colima \
  --samples 10 \
  --polyglot-samples 5 \
  --ecosystems js,python,jvm,dotnet,go,rust,cpp \
  --output-dir benchmarks/reports/polyglot-local
```

The minimum acceptable coverage is at least three non-JS ecosystems. Strong
coverage includes JS, Python, JVM, .NET, Go, Rust, and C/C++.

## Energy Claims

Energy superiority requires measured `powermetrics` data:

```sh
swift run --package-path benchmarks conjet-bench energy-gate \
  --contexts conjet,orbstack,colima \
  --workloads idle,container-start-loop,hot-reload-loop,compose-loop,npm-install,pnpm-install,cargo-build \
  --samples 10 \
  --require-power \
  --output-dir benchmarks/reports/energy-gate-YYYYMMDD-HHMMSS
```

If `powermetrics` is unavailable and `--require-power` is not passed, the report
must mark the energy verdict as skipped. Skipped power data is not evidence for
lower energy or lower power.

## Claim Gate

Existing raw JSON reports can be scored with:

```sh
swift run --package-path benchmarks conjet-bench gate \
  --reports benchmarks/reports/run-all-local/warm-gate/all-results.json \
  --candidate conjet \
  --baselines orbstack,colima \
  --min-samples 10 \
  --phase warm \
  --markdown
```

Markdown reports are summaries, not proof artifacts. Gate input must be raw
JSON.

## Claim Policy

- Proven: benchmark gate passed with enough samples.
- Partial: some measured workloads passed and some failed.
- Not proven: not measured, skipped, or insufficient samples.
- Failed: measured and did not meet the gate.

Never claim global speedup, cold superiority, strict-bind superiority, or energy
superiority without matching evidence.

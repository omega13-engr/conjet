# Conjet Benchmarks

`benchmarks/` is a standalone Swift package. It depends on `ConjetCore` for
shared process, JSON, Docker, project, and host utilities, but the production
`conjet` executable does not depend on benchmark code.

## Commands

Build and test the benchmark package:

```sh
swift build --package-path benchmarks
swift test --package-path benchmarks
```

Run the combined wrapper for Conjet, OrbStack, and Colima:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,orbstack,colima \
  --samples 10 \
  --output-dir benchmarks/reports/run-all-local
```

`conjet-bench run` validates `sudo -v` before it starts. It runs wall-time suites
in parallel and then runs energy in isolation so power samples are not polluted
by other benchmark work:

- `warm-gate`
- `cold-base-prepulled-gate`
- `no-cache-gate`
- `topology-gate`
- `polyglot-gate`
- `energy-gate`

The wrapper writes `run-all.json` and `run-all.md` in the selected output
directory, with each suite writing its own reports in a child directory.

## Energy Gate

Run the energy gate with required power measurement:

```sh
swift run --package-path benchmarks conjet-bench energy-gate \
  --contexts conjet,orbstack,colima \
  --workloads idle,container-start-loop,hot-reload-loop,compose-loop,npm-install,pnpm-install,cargo-build \
  --samples 10 \
  --require-power \
  --output-dir benchmarks/reports/energy-gate-local
```

When `powermetrics` cannot measure and `--require-power` is absent, the suite
records an honest skip. When `--require-power` is present, missing privileges or
missing power samples fail the command.

## Gate Existing Reports

```sh
swift run --package-path benchmarks conjet-bench gate \
  --reports benchmarks/reports/run-all-local/warm-gate/all-results.json \
  --candidate conjet \
  --baselines orbstack,colima \
  --min-samples 10 \
  --phase warm \
  --markdown
```

## Topology Vocabulary

Benchmark results include topology metadata so reports do not blur different
mount strategies:

- `strict-bind`: host source mounted at `/app`, no Linux-native dependency or
  build overlays.
- `smart-bind`: host source mounted at `/app` with Linux-native overlays for
  write-heavy paths such as `/app/node_modules` or `/app/target`.
- `volume`: Linux-native Docker volume baseline.
- `conjetfs`: ConjetFS synchronized source with a Linux-native workspace.

Old `bind-*` aliases are treated as deprecated compatibility names and must be
reported with their actual topology metadata.

## Claim Discipline

- Warm wins prove warm dev-loop performance only.
- Cold/no-cache wins require cold/no-cache reports with matching sample phase.
- Energy superiority requires measured power data, not skipped powermetrics.
- Strict bind claims require strict-bind workloads.
- SmartMount/native-overlay claims require smart-bind workloads.
- Kubernetes is intentionally out of scope for this benchmark generation.

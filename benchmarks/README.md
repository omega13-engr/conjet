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

Run the combined wrapper for Conjet, ReferenceRuntime, and Colima:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,reference-runtime,colima \
  --samples 10 \
  --output-dir benchmarks/reports/run-all-local
```

`conjet-bench run` validates `sudo -v` before it starts. It runs energy first in
isolation so power samples are not polluted by other benchmark work, then runs
wall-time suites in parallel:

- `warm-gate`
- `cold-base-prepulled-gate`
- `no-cache-gate`
- `topology-gate`
- `polyglot-gate`
- `energy-gate`

The wrapper writes `run-all.json` and `run-all.md` in the selected output
directory, with each suite writing its own reports in a child directory. By
default it removes generated `work/` dump trees after report files are written;
pass `--keep-work` when you need the generated workload directories for
debugging.

The combined runner defaults energy and polyglot suites to 10 samples when
`--samples 10` is used. For quick local smoke runs, lower those explicitly with
`--energy-samples 2` or `--polyglot-samples 2`. For publication confidence,
raise core polyglot ecosystems with `--polyglot-samples 30`.

Rust/Cargo benchmark workloads use a local `conjet-bench-rust-llvm:1` image
derived from `rust:1-alpine` with `clang` and `lld` installed. The runner builds
that image once per Docker context when needed, then exports `RUSTFLAGS` so
Cargo links with LLVM lld instead of the slower default system linker. Go
polyglot workloads keep builds local and deterministic with `GOTOOLCHAIN=local`,
`CGO_ENABLED=0`, `GOFLAGS="-buildvcs=false -trimpath"`, and parallel `go build`
or `go test` jobs based on available CPUs.

C/C++ rows keep CMake-generated build files under `/workspace/.native` for
smart-bind runs. Configure rows also set `CC`, `CXX`, `CMAKE_GENERATOR`, and
`CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY` so compiler detection does less
repeated bind-mounted metadata work.

To rerun only selected suites, pass `--suites`:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,reference-runtime,colima \
  --samples 5 \
  --suites warm-gate,no-cache-gate,cold-base-prepulled-gate \
  --output-dir benchmarks/reports/rerun-failed-gates
```

## Fresh lifecycle baseline

The [pinned scenario](scenarios/fresh-lifecycle-v1.json) runs separate API
and CLI samples for both network modes. Pass `--benchmark-output` to the
[isolated runtime launchers](../docs/engineering/speedup-environment.md).
Use `--benchmark-samples` to choose the measured count per lane and network.
Each launcher validates its engine and owns cleanup for the duration of
the benchmark. Reports preserve all observations and distinguish API
removal from the guest cleanup boundary.

For a matched static ARM64 fixture, build `fixtures/fresh-arm64-exit.S`
as a Linux ELF with an AArch64 assembler and static linker, then pass it
to `create-fresh-fixture.py` with a new ExternalSSD output directory.
The script writes the image archive, the OCI manifest, the executable,
and a scenario containing their digests and runtime limits. Pass the
scenario and archive via `--benchmark-scenario` and `--benchmark-archive`
to either launcher. Each launcher imports the image after validating
the private Docker endpoint. Use `native-fresh-lifecycle.py` with the
same fixture directory and branch-built native guest and host tools to
measure the separate native API and experimental native CLI.

The native runner accepts `--prepared` for the isolated one-slot no-network
experiment. Its raw rows separate preparation, claim acknowledgement,
exec observation, and verified cleanup. Cancellation and expiry probes
include miss timing. Each sample prepares a new slot, so preparation
also records the refill cost under sequential churn.

Run `--memory-pressure` to audit active and prepared cgroup ownership,
authenticated eviction, and refill. This mode records empty and
ready VMM footprints and checks a live allocation canary through
the pressure transition. The separate `--balloon-pressure` mode
uses a disposable 512 MiB guest and a 72 MiB balloon target to
verify the automatic admission guard from guest memory telemetry.
Use a new ExternalSSD output directory for each boot.

## Energy Gate

Run the energy gate with required power measurement:

```sh
swift run --package-path benchmarks conjet-bench energy-gate \
  --contexts conjet,reference-runtime,colima \
  --workloads idle,container-start-loop,hot-reload-loop,compose-loop,npm-install,pnpm-install,cargo-build \
  --samples 10 \
  --require-power \
  --output-dir benchmarks/reports/energy-gate-local
```

When `powermetrics` cannot measure and `--require-power` is absent, the suite
records an honest skip. When `--require-power` is present, missing privileges or
missing power samples fail the command.

Energy publication runs should use at least 10 samples per workload. Active
energy claims require Conjet, ReferenceRuntime, and Colima to be measured in the same
report under the same power source and thermal conditions.

## Gate Existing Reports

```sh
swift run --package-path benchmarks conjet-bench gate \
  --reports benchmarks/reports/run-all-local/warm-gate/all-results.json \
  --candidate conjet \
  --baselines reference-runtime,colima \
  --required-baselines reference-runtime \
  --min-samples 10 \
  --phase warm \
  --markdown
```

Baselines outside `--required-baselines` are still reported, but they are
advisory and do not decide the gate verdict.

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

## Experimental product path

`native-product.py` boots the packaged `conjet native --experimental`
surface and separately measures its persistent authenticated API and
CLI. It also exercises the native guest with the ARM64 canary, including
its memory, isolation, output, cleanup and one-use checks. Keep inputs
and output under ExternalSSD. Use the published kernel and its sidecar,
the package's CLI/VMM pair, and the same pinned workload for repeat runs.

The timer for API execution starts at launch or claim submission and
ends at verified guest cleanup. CLI timing includes process startup and
captured-output collection. Preparation through ready is recorded
separately. Serial prepared throughput includes every refill. Raw
outputs are written even when a check fails. See the
[qualification report](../docs/engineering/speed-qualification.md)
for the documented M1 Pro runs and the
[experimental feature](../docs/engineering/speed-release-scope.md)
for the supported configuration.

## Paired Docker comparison

The [frozen protocol](../docs/engineering/docker-benchmark-plan.md) controls
the Docker comparison. Use the build outputs and verified Core assets from
the [isolated environment runbook](../docs/engineering/speedup-environment.md).
Run each command in the foreground. Outputs must be new directories under
ExternalSSD.

```sh
python3 benchmarks/docker-comparison.py --mode lifecycle \
  --group alpine-true/none/api --pair 2 --timeout 3600 \
  --output "$evidence/alpine-true-none-api-pair-2" \
  --swift-bin "$speed_build/swift/debug" \
  --core "$speed_build/cargo/debug/jetstream" \
  --network-helper "$speed_build/conjet-network" \
  --core-assets "$core_assets"
```

Use `--mode preflight` before a new environment, `pilot` for annotated pilot
timings, and `probes` for capability checks. A selected lifecycle group runs
its full per-session budget. Repeat at every pair index for a qualifying
series. Use `--all-pairs` in place of `--pair` to run a mode or lifecycle
group through all five pairs with one foreground lock. If a session fails,
keep its evidence and resume each remaining pair into a new output directory.
The launchers record the running VM's reported memory and the container view
of `/proc/meminfo` before timing. The other modes are `images`, `builds`, `compose`, `control`,
`storage_network` and `stress`. They run their own frozen per-session counts
and retain failed operations. A successful launcher exit confirms capture and
cleanup. Check each scenario's errors and coverage before using its timings.

The image suite separates public image pulls, known-warm load/save,
and private registry pulls. A host HTTP client seeds the owned loopback
registry directly. The first-pull result records which config and layer
bytes were served, and describes the transfer as unknown when the witness
is incomplete. [Registry HTTP API](https://distribution.github.io/distribution/spec/api/)

The build suite uses a uniquely named
pinned BuildKit worker with its own guest volume and separates preloading,
build/export, load and output validation. To keep guest registry egress out
of that experiment, stage the same pinned build bases once outside any
timing session, then pass `--build-bases "$speed_build/oci-bases"` with
`--mode builds` for both halves. Buildx reads the bases as local OCI named
contexts. [Buildx named contexts](https://docs.docker.com/reference/cli/docker/buildx/build/#build-context)

```sh
python3 benchmarks/fetch-comparison-build-bases.py --output "$speed_build/oci-bases"
```

Compose uses Node and Redis with
functional readiness and a persistent transaction counter. No benchmark
rewrites the installed Docker context or prunes a shared store.

`docker-comparison-summary.py` emits per-session percentiles and failure
counts from retained reports. Use the paired estimator only with five
complete, independent, semantically matched pairs.

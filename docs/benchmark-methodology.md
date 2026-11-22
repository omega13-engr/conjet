# Benchmark Methodology

Conjet benchmark code lives in the standalone Swift package under
`benchmarks/`. The production `conjet` executable must not contain benchmark
commands or link benchmark modules.

All performance claims must be backed by raw JSON under `benchmarks/reports/`
and by a Markdown report that states cache mode, topology, sample count,
failures, and caveats.

## Startup Timeline

Fastboot and microVM claims must include a startup trace collected by the
startup-trace runner:

```sh
swift run --package-path benchmarks conjet-bench startup-trace \
  --conjet .build/debug/conjet \
  --conjet-home "$qa_root/conjet-home" \
  --trace-guest-readiness \
  --samples 10 \
  --output-dir "$qa_root/startup-trace"
```

Each sample invokes:

```sh
conjet vm backend boot-attempt --timeline-jsonl "$trace" --trace-guest-readiness
```

The trace is newline-delimited JSON with one `StartupTimelineEvent` per line.
Events use host `mach_continuous_time` nanoseconds and must be complete and
ordered before a result can support a performance claim:

- `T0`: request accepted by Conjet.
- `T1`: launch plan, profile, cache inputs, and resources resolved.
- `T2`: guest RAM mapped and VM creation path ready.
- `T3`: first guest instruction attempted.
- `T4`: PID 1 control channel or equivalent guest readiness reached.
- `T5`: OCI bundle/rootfs mounted and configured.
- `T6`: process launch observation. The legacy Pulse process-start record marks child creation.
- `T7`: first useful response or launch exit result.
- `TD`: Docker API readiness for the resident Docker lane.

The bounded Rust boot command records T0, T1, and T7 on the host clock. T7 on
this command is VMM subprocess completion, which includes returning the boot
report or failure. Guest readiness records remain separate in the VMM report.
Supply `--early-console-only` for a bounded fixture that powers off directly.

Reports must keep the per-sample JSONL files, full VMM response output,
`all-results.json`, and `startup-trace.md`. At minimum, startup reports must state:

- sample count and failures;
- T0-to-T7 p50 and p95;
- warm/cold cache state;
- whether rootfs/image preparation was excluded from the measured launch path;
- bytes copied before T3, mapped memory bytes, and loaded artifact bytes when
  available;
- the HVF backend version and whether the binary readiness path or
  serial debug readiness path satisfied T4.

Cache-state labels are mandatory:

- `warm-daemon`: Conjet daemon already running.
- `warm-page-cache`: kernel/init/rootfs artifacts already in host page cache.
- `prepared-rootfs`: registry pull and layer unpack are completed before T0.
- `cold-daemon`: daemon startup included in T0-to-T7.
- `cold-page-cache`: no deliberate page-cache warmup.
- `true-cold`: reboot or equivalent cache reset was performed and documented.

Never use a startup microbenchmark to claim full Docker-appliance cold-start
speed. Docker cold boot, resident Docker operations, and Pulse/direct-OCI
launches must be reported as separate lanes.

## Guest readiness records

The optional `--trace-guest-readiness` boot flag enables Jetstream's bounded
guest-to-host readiness stream on VSOCK port 1029. The Rust boot report
includes `readiness_records`, and the outer `conjet vm backend boot-attempt`
report preserves those records. An empty array means the host saw no valid
records. Existing boots omit the field.

The transport accepts the existing v1 readiness envelope and retains at
most 16 events per boot. The legacy event ID 2 is reported as
`legacy_process_started`. Pulse uses it for fork completion and the Docker
appliance uses it as a boot marker. IDs 3 through 7 are reserved for
`child_created`, `exec_confirmed`, `application_ready`, `exec_failed`,
and `process_exited`, respectively. The report keeps status and an event
code along with the boot ID hash.

The Pulse guest emits IDs 3 through 7 with `conjet.trace_exec=1`. This
diagnostic mode observes the kernel's ptrace exec event and releases the
child immediately after that observation. Use trusted fixtures for this mode.
It changes execution timing and may affect credential transitions. The
`exec_failed` code carries errno. The `process_exited` code carries the exit
status when status is zero and the signal number when status is one.

The static `conjet-init` binary doubles as the application fixture when
execed as `/init --readiness-fixture`. It writes a one-byte readiness marker
through `CONJET_READY_FD` after exec. The `early-exit` argument exits with
status 23 before writing that marker. The missing-executable fixture uses
`/missing`, and the permissions fixture uses `/etc/conjet-release`.
Use `conjet.qa_exit=1` to power off after the fixture is reaped. The
launcher retains the legacy fork marker when exec tracing is disabled.

`host_offset_ns` is the elapsed time from the start of the Rust VMM boot
runner to complete frame receipt. Durations between host observations use
the same host monotonic clock. `guest_monotonic_ns` is the raw guest clock
reading, for guest intervals only. The host offset includes transport and
decoding, and excludes the outer CLI and VMM process startup. Qualification
requires a separate paired measurement of tracing overhead.

## Parallel Wrapper

The standard local runner is:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,reference-runtime,colima \
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
- network gate
- energy gate

Each suite writes raw `all-results.json` and a suite Markdown report. The root
runner writes `run-all.json` and `run-all.md`.

To rerun only specific suites after a partial failure, use `--suites`:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,reference-runtime,colima \
  --samples 5 \
  --suites warm-gate,no-cache-gate,cold-base-prepulled-gate \
  --output-dir benchmarks/reports/rerun-failed-gates
```

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
  --contexts conjet,reference-runtime,colima \
  --samples 10 \
  --polyglot-samples 10 \
  --ecosystems js,python,jvm,dotnet,go,rust,cpp \
  --output-dir benchmarks/reports/polyglot-local
```

The minimum acceptable coverage is at least three non-JS ecosystems. Strong
coverage includes JS, Python, JVM, .NET, Go, Rust, and C/C++.

Rust rows use the local `conjet-bench-rust-llvm:1` image. It is built from
`rust:1-alpine` with `clang` and `lld`, then Cargo is run with
`RUSTFLAGS="-C linker=clang -C link-arg=-fuse-ld=lld"` appended to any existing
flags. Result metadata records `cargo_llvm_lld=1`, `rust_toolchain=llvm-lld`,
and the benchmark image name.

Go rows use the stock `golang:1.23-alpine` image but disable avoidable benchmark
overhead with `GOTOOLCHAIN=local`, `CGO_ENABLED=0`, and
`GOFLAGS="-buildvcs=false -trimpath"`. Build and test rows pass `-p` using the
container CPU count. Result metadata records the Go cache/toolchain mode so
reports can distinguish this fast path from a default Go invocation.

C/C++ configure rows are measured across the same topology labels as other
polyglot rows. The current root-cause hypothesis for slow configure runs is
metadata amplification from CMake compiler detection and `CMakeFiles` writes on
shared/bind-mounted paths. Smart-bind runs therefore keep generated configure
state under `/workspace/.native/cmake-build`, set `CC=cc`, `CXX=c++`,
`CMAKE_GENERATOR=Unix Makefiles`, and set
`CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`.

Use 10 samples for initial confidence. Use 30 samples for publication-grade
core ecosystems, especially `cpp-configure`, `python-install`, `python-test`,
`go-test`, `js-install`, `js-build`, and `rust-build`.

## Energy Claims

Energy superiority requires measured `powermetrics` data:

```sh
swift run --package-path benchmarks conjet-bench energy-gate \
  --contexts conjet,reference-runtime,colima \
  --workloads idle,container-start-loop,hot-reload-loop,compose-loop,npm-install,pnpm-install,cargo-build \
  --samples 10 \
  --require-power \
  --output-dir benchmarks/reports/energy-gate-YYYYMMDD-HHMMSS
```

If `powermetrics` is unavailable and `--require-power` is not passed, the report
must mark the energy verdict as skipped. Skipped power data is not evidence for
lower energy or lower power.

Energy publication runs must use at least 10 samples per workload. Conjet has
shown very low idle power in directional measurements, but active energy
optimization is ongoing until measured active joules are at or below ReferenceRuntime
on the target workloads.

## Network Gate

ConjetNet networking is measured with:

```sh
swift run --package-path benchmarks conjet-bench network-gate \
  --contexts conjet,reference-runtime,colima \
  --samples 10 \
  --output-dir benchmarks/reports/network-gate-local
```

The network gate reports localhost TCP publication latency, localhost HTTP
latency, high-concurrency HTTP rows such as `http-localhost-c100`, UDP echo
latency, and selected UDP payload-size rows when requested. Reports split the
Conjet functional gate from baseline failures, so a Colima UDP failure is
classified as a baseline failure instead of a Conjet TCP/UDP failure.

Port publication rows report both `listener_visible_ms` and
`first_connect_success_ms`. The first measures host listener registration; the
second measures the first successful request through the full forwarding path.

It does not prove global networking superiority by itself. Claims must name the
specific workload, sample count, and compared contexts.

Proxy engines can be compared by restarting Conjet per engine:

```sh
swift run --package-path benchmarks conjet-bench network-gate \
  --contexts conjet \
  --proxy-engines gcd-evented,nio \
  --samples 10 \
  --output-dir benchmarks/reports/network-proxy-engines
```

The runner verifies `conjet network status` before sampling and labels results
as separate runtimes, for example `conjet-gcd-evented` and `conjet-nio`.

Path segmentation is measured separately:

```sh
swift run --package-path benchmarks conjet-bench network-segments \
  --contexts conjet \
  --samples 30 \
  --output-dir benchmarks/reports/network-segments
```

Segment reports distinguish measured full-path rows from unavailable internal
segments. Current guest images do not expose a VSOCK-only echo endpoint, so
those rows are skipped explicitly instead of inferred.

## Claim Gate

Existing raw JSON reports can be scored with:

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

Markdown reports are summaries, not proof artifacts. Gate input must be raw
JSON. Baselines not listed in `--required-baselines` remain in the comparison
table as advisory evidence but do not decide the gate verdict.

## Claim Policy

- Proven: benchmark gate passed with enough samples.
- Partial: some measured workloads passed and some failed.
- Not proven: not measured, skipped, or insufficient samples.
- Failed: measured and did not meet the gate.

Never claim global speedup, cold superiority, strict-bind superiority, or energy
superiority without matching evidence.

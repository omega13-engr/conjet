# Conjet Benchmark Harness

The harness starts before the runtime so performance claims remain testable.

Initial commands:

```sh
swift run conjet bench profile --json
swift run conjet bench small-files --files 10000 --bytes 128 --json
swift run conjet bench docker-compare --contexts conjet,colima --iterations 3 --warmup --markdown \
  --output bench/reports/docker-contexts.md
```

`docker-compare` runs the same Docker API, container start, image build,
`COPY node_modules`, Dockerfile npm/pnpm install, Dockerfile `cargo build`,
bind-mounted npm/pnpm/Cargo workflows, VM-native volume npm/pnpm/Cargo
workflows, ConjetFS sync-to-volume npm/pnpm/Cargo workflows, named-volume IO,
tmpfs IO, hot reload probes, and small Compose startup probes against each
named Docker context. Hot reload probes run an in-container Node `fs.watch`
listener so they measure Linux watcher delivery, not a polling loop.
`conjetfs-hot-reload` drives the same host-side FSEvents watch path as
`conjet sync watch`, records `watch_sync_seconds`, and gates the claim on the
`hot_reload_seconds` metric rather than total setup time. Fast-path gate rules
compare ConjetFS workloads against the equivalent baseline bind workloads while
raw bind workload results remain visible in the report. Store raw JSON or
Markdown in `bench/reports/` before making performance claims against OrbStack,
Docker Desktop, Colima default, or Colima tuned VZ + VirtioFS.

For a focused subset, pass workload names explicitly:

```sh
swift run conjet bench docker-compare --contexts conjet,colima \
  --workloads npm-install,pnpm-install,copy-node-modules,cargo-build,bind-npm-install,volume-npm-install,conjetfs-npm-install,bind-cargo-build,volume-cargo-build,conjetfs-cargo-build,named-volume-io,tmpfs-volume-io \
  --iterations 1 --warmup --markdown
```

Available Docker workloads:

- `docker-version`
- `container-start`
- `image-build`
- `copy-node-modules`
- `npm-install`
- `pnpm-install`
- `cargo-build`
- `bind-npm-install`
- `bind-pnpm-install`
- `volume-npm-install`
- `volume-pnpm-install`
- `bind-cargo-build`
- `volume-cargo-build`
- `conjetfs-npm-install`
- `conjetfs-pnpm-install`
- `conjetfs-cargo-build`
- `bind-hot-reload`
- `conjetfs-hot-reload`
- `named-volume-io`
- `tmpfs-volume-io`
- `compose-up`

Idle daemon/resource sampling is exposed separately:

```sh
swift run conjet bench idle --runtime conjet --seconds 60 --interval 1 --markdown
swift run conjet bench idle --runtime colima --seconds 60 --interval 1 --markdown
swift run conjet bench idle --runtime orbstack --seconds 60 --interval 1 --markdown
```

Power sampling uses macOS `powermetrics` and records permission failures as
benchmark failures so missing evidence is visible in reports:

```sh
swift run conjet bench power --runtime conjet --seconds 60 --interval 1 --markdown
swift run conjet bench power --runtime colima --seconds 60 --interval 1 --markdown
swift run conjet bench power --runtime orbstack --seconds 60 --interval 1 --markdown
```

The faster-than-OrbStack release claim is gated by raw JSON, not Markdown. The
production path is the release-gate orchestrator:

```sh
swift run conjet bench release-gate \
  --contexts conjet,orbstack,colima \
  --iterations 5 \
  --warmup \
  --seconds 60 \
  --output-dir bench/reports/release-gate-YYYYMMDD-HHMMSS \
  --json
```

`release-gate` writes `docker.json`, `idle-<runtime>.json`,
`power-<runtime>.json`, `all-results.json`, `all-results.md`, `gate.json`, and
`gate.md`. It exits nonzero unless the gate passes, so missing OrbStack or tuned
Colima evidence blocks the release claim by default.

The lower-level manual path is still available when debugging one collector:

```sh
swift run conjet bench docker-compare --contexts conjet,orbstack,colima \
  --iterations 5 --warmup --json \
  --output bench/reports/docker-release-gate.json
for runtime in conjet orbstack colima; do
  swift run conjet bench idle --runtime "$runtime" --seconds 60 --interval 1 --json \
    --output "bench/reports/idle-$runtime.json"
  swift run conjet bench power --runtime "$runtime" --seconds 60 --interval 1 --json \
    --output "bench/reports/power-$runtime.json"
done
swift run conjet bench gate \
  --reports bench/reports/docker-release-gate.json,bench/reports/idle-conjet.json,bench/reports/idle-orbstack.json,bench/reports/idle-colima.json,bench/reports/power-conjet.json,bench/reports/power-orbstack.json,bench/reports/power-colima.json \
  --json
```

`bench gate` fails if required workloads, OrbStack/tuned-Colima baselines,
sample counts, zero-failure evidence, or candidate P50/P95 wins are missing.
For release evidence, prefer `bench release-gate` because it collects every
runtime's idle and power reports before evaluating the same gate.
When evaluating a targeted Docker-only report, pass `--workloads NAME,...`
plus `--no-idle --no-power` so the gate evaluates the selected workload rules
instead of the full production release rule set.

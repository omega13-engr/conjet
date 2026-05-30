# Benchmark Methodology

Benchmarks must include machine profile, power source, thermal state, command
line, runtime name, wall time, exit code, and workload metrics. Claims against
OrbStack, Colima, or Docker Desktop are not valid until raw JSON for every
runtime is kept under `bench/reports/`.

For Docker compatibility and Colima comparison, use:

```sh
conjet bench docker-compare --contexts conjet,colima --iterations 3 --warmup --json \
  --output bench/reports/docker-contexts.json
```

The runner intentionally uses Docker contexts instead of changing the global
Docker context. It records `docker-version`, `container-start`, `image-build`,
`copy-node-modules`, `npm-install`, `pnpm-install`, `cargo-build`, bind-mounted
npm/pnpm/Cargo workloads, VM-native volume npm/pnpm/Cargo workloads, ConjetFS
sync-to-volume npm/pnpm/Cargo workloads, `named-volume-io`, `tmpfs-volume-io`,
`bind-hot-reload`, `conjetfs-hot-reload`, and `compose-up` for every context
and iteration.

Hot-reload workloads must publish `hot_reload_seconds` from an in-container
Node `fs.watch` listener. The release gate uses that metric for raw
`bind-hot-reload`, raw `conjetfs-hot-reload`, and the mapped
`hot-reload-fast-path` rule that compares Conjet `conjetfs-hot-reload` against
baseline `bind-hot-reload`. This keeps the claim based on edit-to-detection
latency, not container startup, one-time setup, or a polling loop. For ConjetFS,
the hot-reload workload must use the host-side FSEvents watcher path and publish
`watch_sync_seconds` plus `watch_event_paths`.

Use `--workloads NAME,...` for a targeted run when isolating one subsystem. For
example, use `--workloads conjetfs-npm-install,conjetfs-pnpm-install,conjetfs-cargo-build`
to focus on the ConjetFS path, or `--workloads named-volume-io,tmpfs-volume-io`
to focus on Docker-managed storage. Do not compare these results with older
reports that only included narrower Docker probes.

Idle CPU sampling is separate from Docker workload timing:

```sh
conjet bench idle --runtime conjet --seconds 60 --interval 1 --markdown
conjet bench idle --runtime colima --seconds 60 --interval 1 --markdown
conjet bench idle --runtime orbstack --seconds 60 --interval 1 --markdown
```

These process samples are not a substitute for `powermetrics` energy data, but
they are a low-friction regression guard for daemon and watcher CPU burn.

Power and wakeup sampling uses macOS `powermetrics`:

```sh
conjet bench power --runtime conjet --seconds 60 --interval 1 --markdown
conjet bench power --runtime colima --seconds 60 --interval 1 --markdown
conjet bench power --runtime orbstack --seconds 60 --interval 1 --markdown
```

`bench power` runs `sudo -n powermetrics` by default so CI or scripted runs do
not hang on a password prompt. Use `--no-sudo` only for local parser/debug
checks. A nonzero exit is kept as a benchmark result and must be published with
the report; it means power evidence is missing for that runtime.

Active energy-to-solution sampling wraps a real workload:

```sh
conjet bench energy \
  --runtime conjet \
  --workload compose-up-energy \
  --seconds 120 \
  --interval 1 \
  --output bench/reports/energy-conjet.json \
  -- docker --context conjet compose -f compose.yaml up --build --abort-on-container-exit
```

Run the same command shape for OrbStack and tuned Colima. The workload command
must appear after `--`; any flags after that separator belong to the workload,
not the Conjet benchmark command. The result records workload duration, sampled
power duration, powermetrics exit code, workload exit code, and estimated
combined/CPU joules when `powermetrics` returns power rails.

Before any faster-than-OrbStack release claim, run the release-gate
orchestrator:

```sh
conjet bench release-gate \
  --contexts conjet,orbstack,colima \
  --iterations 5 \
  --warmup \
  --seconds 60 \
  --output-dir bench/reports/release-gate-YYYYMMDD-HHMMSS \
  --json
```

The command writes raw Docker, idle CPU, power, combined-result, and gate
artifacts into the output directory. It exits nonzero if any required workload,
OrbStack/tuned-Colima baseline, sample count, zero-failure requirement, or
Conjet P50/P95 win is missing.
Power-enabled release gates also collect `container-start-energy-sample`, a
fixed container-start loop measured by `conjet bench energy`, and compare
`energy_to_solution_joules_estimate` across runtimes. Use `--no-power` only for
wall-time-only debug runs; it disables both idle power and active energy
requirements.
Mapped fast-path rules do not hide raw bind-mount evidence; the reports still
include direct bind workloads, while rules such as `hot-reload-fast-path`
explicitly show the candidate and baseline workload names being compared.

For manual debugging, combine raw JSON reports and run the lower-level claim
gate directly:

```sh
conjet bench gate \
  --reports bench/reports/docker-release-gate.json,bench/reports/idle-conjet.json,bench/reports/idle-orbstack.json,bench/reports/idle-colima.json,bench/reports/power-conjet.json,bench/reports/power-orbstack.json,bench/reports/power-colima.json \
  --candidate conjet \
  --baselines orbstack,colima \
  --min-samples 3 \
  --json
```

The gate requires the required workloads and runtime baselines to exist, each
candidate and baseline group to have at least the minimum sample count, zero
failed samples, and Conjet P50/P95 at or below every baseline for each measure.
Markdown reports are intentionally rejected by the gate; they are readable
summaries, not proof artifacts.
For targeted JSON reports, pass the same `--workloads NAME,...` list used by
`docker-compare`; add `--no-idle --no-power` when the report intentionally
omits idle and power samples.

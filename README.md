<img src="docs/assets/Conjet.png" width="150">

**Super Sonic Speed, Power Efficient, dev-friendly Docker-compatible containers for macOS only.**

Conjet is an open-source macOS container runtime built around a simple idea:

> Keep developer source files easy to edit on macOS, but move heavy container work into fast Linux-native storage.

Conjet is designed for developers who want the convenience of Docker on macOS without paying the usual performance tax from slow bind mounts, dependency directories, and hot-reload file events.

---

## Why Conjet?

Most macOS container slowdowns come from the boundary between macOS and the Linux VM. Conjet attacks that boundary directly.

Instead of treating every project folder as one generic shared mount, Conjet separates:

- **source files** that developers edit on macOS,
- **dependency directories** such as `node_modules`, `vendor`, `.venv`, and `target`,
- **build outputs** such as `.next`, `.turbo`, `dist`, and `build`,
- **runtime data** and temporary files,
- **exported artifacts** that actually need to return to macOS.

The result is a workflow that still feels familiar:

```sh
conjet start
conjet run hello-world
conjet compose up
```

…but avoids unnecessary macOS ↔ Linux filesystem churn where possible.

---

## Performance Snapshot

Conjet includes a standalone benchmark suite for warm, cold/no-cache, topology, polyglot, and energy gates.

In a 30-sample warm benchmark gate against OrbStack, Conjet passed the configured wall-time matrix across workloads including container start, image build, package install, Cargo build, volume I/O, ConjetFS fast paths, hot reload, and Compose startup.

Representative warm benchmark ratios from the gate report:


| Workload              | Conjet P50 | OrbStack P50 | Ratio |
| --------------------- | ---------- | ------------ | ----- |
| `container-start`     | 0.405s     | 1.697s       | 0.239 |
| `image-build`         | 0.484s     | 3.795s       | 0.128 |
| `copy-node-modules`   | 0.640s     | 7.580s       | 0.084 |
| `npm-install`         | 3.320s     | 9.960s       | 0.333 |
| `pnpm-install`        | 4.215s     | 10.566s      | 0.399 |
| `cargo-build`         | 1.980s     | 9.324s       | 0.212 |
| `conjetfs-hot-reload` | 0.147s     | 0.269s       | 0.547 |
| `compose-up`          | 0.417s     | 2.299s       | 0.181 |


**Important:** benchmark claims are scoped. Warm cached results are not cold/no-cache evidence, and energy superiority should only be claimed when the power gate has measured and passed.

---

## Features

### Developer Workflow

- `conjet` CLI and `conjetd` daemon for macOS.
- Docker-compatible runtime commands.
- Docker socket bridge exposed under the active Conjet profile.
- Compose support for local development.
- Profile-scoped VM, Docker socket, logs, and project state.

### ConjetFS

- Source sync into a VM-native workspace.
- Linux-native dependency and build paths.
- Project commands for `init`, `attach`, `status`, `run`, `watch`, `repair`, and `export`.
- Export-on-demand for generated artifacts.
- Smart project layout that avoids syncing dependency/build churn back to macOS.

### macOS + Linux Runtime

- Virtualization.framework VM lifecycle.
- Profile-specific VM state.
- VM image import/fetch support for:
  - Conjet Core,
  - Ubuntu cloud images,
  - Fedora,
  - Alpine,
  - custom EFI disks.
- Runtime commands for start, stop, status, shell, Docker run, and Compose.

### Benchmarking

- Standalone benchmark package.
- Warm gate.
- Cold/no-cache gate.
- Topology gate.
- Polyglot project gate.
- Energy gate using `powermetrics` when privileges are available.
- Benchmarks across Conjet, OrbStack, and Colima.

Kubernetes commands are not part of this generation.

---

## Install

### From Source

```sh
git clone https://github.com/zdxsector/conjet.git
cd conjet

swift build -c release
build-support/sign-debug.sh

sudo install .build/release/conjet /usr/local/bin/conjet
sudo install .build/release/conjetd /usr/local/bin/conjetd
```

Virtualization.framework requires a signed binary with the virtualization entitlement for local VM runs.

For debug builds:

```sh
swift build
build-support/sign-debug.sh
.build/debug/conjet start
```

### Homebrew

The repository includes a Homebrew tap layout:

```sh
brew tap omega13-engr/conjet
brew install conjet
```

The formula expects the tap repository to publish this project source. See `[docs/homebrew.md](docs/homebrew.md)` for release notes and tap maintenance details.

---

## Quick Start

Check your host and Conjet configuration:

```sh
conjet doctor
```

Start the default runtime profile:

```sh
conjet start
conjet status
```

Confirm Docker can see the Conjet context:

```sh
docker context ls
docker ps
```

Run a container:

```sh
conjet run hello-world
```

Use Compose:

```sh
conjet compose up
```

Stop the runtime:

```sh
conjet stop
```

---

## Profiles

Use profiles to isolate VM state, Docker sockets, logs, and project metadata.

```sh
conjet --profile work start --cpu 4 --memory 8 --disk 100
conjet --profile work status
```

Move all Conjet profile state out of `~/.conjet` with `CONJET_HOME`:

```sh
export CONJET_HOME=/Volumes/ExternalSSD/conjet
conjet start
```

---

## Project Workflow

Initialize and attach a project:

```sh
conjet project init /path/to/project
conjet project attach /path/to/project
```

Push source into the ConjetFS workspace:

```sh
conjet sync push /path/to/project
```

Watch for source changes:

```sh
conjet sync watch /path/to/project
```

Run a command inside the project workspace:

```sh
conjet project run --path /path/to/project node:22-alpine npm install
```

Export generated output back to macOS:

```sh
conjet sync export dist --to /tmp/exported --path /path/to/project
```

ConjetFS keeps host-authoritative files synchronized, including source files, lockfiles, Dockerfiles, Compose files, and project configuration.

Dependency and build directories are intentionally created inside Linux-native storage when possible, including:

```text
node_modules/
target/
.next/
.turbo/
.cache/
vendor/
.venv/
build/
dist/
```

This is the core Conjet design: macOS remains the editing environment, while Linux-native storage handles the heavy container work.

---

## Runtime Commands

```sh
conjet start
conjet status
conjet shell
conjet run hello-world
conjet compose up
conjet stop
```

Run:

```sh
conjet --help
```

for the current command surface.

---

## VM Image Commands

Fetch Conjet Core:

```sh
conjet vm fetch-conjet-core --force
```

Fetch an Ubuntu cloud image:

```sh
conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker --force
```

Import a custom EFI disk:

```sh
conjet vm import-efi-disk --image /path/to/disk.raw --cloud-init-docker
```

Validate the VM image and inspect logs:

```sh
conjet vm validate
conjet vm logs --lines 100
```

---

## Build and Test

Build:

```sh
swift build
```

Run tests:

```sh
swift test
```

Build release binaries:

```sh
swift build -c release
```

Sign for local VM runs:

```sh
build-support/sign-debug.sh
```

---

## Benchmarks

Benchmark code is isolated from the production Conjet package.

Build the benchmark package:

```sh
swift build --package-path benchmarks
```

Run benchmark tests:

```sh
swift test --package-path benchmarks
```

Show benchmark help:

```sh
swift run --package-path benchmarks conjet-bench --help
```

Run the full local wrapper across Conjet, OrbStack, and Colima:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,orbstack,colima \
  --samples 10 \
  --output-dir benchmarks/reports/run-all-local
```

The command validates `sudo -v` first because the energy gate needs `powermetrics` privileges.

Run the energy gate only:

```sh
swift run --package-path benchmarks conjet-bench energy-gate \
  --contexts conjet,orbstack,colima \
  --workloads idle,container-start-loop,hot-reload-loop,compose-loop,npm-install,pnpm-install,cargo-build \
  --samples 10 \
  --require-power \
  --output-dir benchmarks/reports/energy-gate-local
```

### Benchmark Claim Discipline

The benchmark report distinguishes:

- warm results,
- cold/no-cache results,
- strict-bind topology,
- smart-bind/native-overlay topology,
- ConjetFS fast path,
- polyglot real-project coverage,
- measured or skipped energy claims.

Use the right claim for the right gate:

```text
Warm gate passed      -> warm dev-loop claim
Cold gate passed      -> cold/no-cache claim
Energy gate passed    -> power/energy claim
Skipped energy gate   -> energy claim remains unproven
```

Do not use warm cached results as cold evidence, and do not claim energy superiority unless the power gate measured and passed.

---

## Repository Layout

```text
Sources/ConjetCLI       Production CLI
Sources/ConjetDaemon    Daemon entry point
Sources/ConjetCore      Runtime, VM, Docker, project, and sync logic
Sources/ConjetPower     Power policy support
Sources/ConjetVZ        Virtualization.framework integration
benchmarks/             Standalone benchmark Swift package and reports
docs/                   Architecture, benchmark methodology, power methodology, and assets
guest/                  Conjet Core guest image build assets
Formula/                Homebrew formula for the tap
```

---

## Philosophy

Conjet is built around a few practical principles:

1. **Make the default path fast.** Developers should not need deep filesystem tuning to get good performance.
2. **Keep source editable on macOS.** The host remains the human-facing development environment.
3. **Move generated churn into Linux.** Dependency trees, build outputs, caches, and temp files should avoid slow host/guest round trips.
4. **Benchmark honestly.** Warm, cold, topology, and energy claims must be measured separately.
5. **Stay Docker-friendly.** Conjet should preserve familiar container workflows while improving the internals.

---

## Status

Conjet is under active development.

Current focus areas:

- refining SmartBind and ConjetFS behavior,
- expanding cold/no-cache benchmark coverage,
- adding real-project polyglot gates,
- measuring energy-to-solution when `powermetrics` privileges are available,
- improving Docker-compatible developer workflows.

---

## License

Conjet is free and open source.
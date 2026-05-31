# Conjet

![Conjet](docs/assets/Conjet.png)

Conjet is a lightweight macOS container runtime and synchronized Linux workspace
toolkit. It focuses on a fast developer loop: start a small VM, expose a Docker
socket, keep source files host-authoritative, and place dependency/build output
on Linux-native storage when that is the truthful topology.

Benchmarking is intentionally separate from the production executable. The
runtime ships as `conjet`; research and comparison tooling lives in
`benchmarks/` as `conjet-bench`.

## Features

- macOS Swift command line tools: `conjet` and `conjetd`.
- Virtualization.framework VM lifecycle with profile-scoped state.
- Docker socket bridge exposed under the active Conjet profile.
- ConjetFS project workflow for source sync plus Linux-native dependency paths.
- Project commands for init, attach, status, run, watch, repair, and export.
- Runtime commands for start, stop, status, shell, Docker run, and Compose.
- VM image import/fetch paths for Conjet Core, Ubuntu cloud images, Fedora,
  Alpine, and custom EFI disks.
- Power policy state model for runtime behavior.
- Standalone benchmark package with warm, cold/no-cache, topology, polyglot,
  and energy gates across Conjet, OrbStack, and Colima.

Kubernetes commands are not part of this generation.

## Install

From a checkout:

```sh
swift build -c release
build-support/sign-debug.sh
install .build/release/conjet /usr/local/bin/conjet
install .build/release/conjetd /usr/local/bin/conjetd
```

Homebrew tap layout is included for:

```sh
brew tap omega13-engr/conjet
brew install conjet
```

The formula expects the tap repository to publish this project source. See
`docs/homebrew.md` for release notes and tap maintenance details.

## Getting Started

Check the host and Conjet configuration:

```sh
conjet doctor
```

Start the runtime with the default profile:

```sh
conjet start
conjet status
docker context ls
docker ps
```

Use an isolated profile for a separate VM, Docker socket, logs, and project
state:

```sh
conjet --profile work start --cpu 4 --memory 8 --disk 100
conjet --profile work status
```

`CONJET_HOME` moves all profile state out of `~/.conjet`:

```sh
export CONJET_HOME=/Volumes/ExternalSSD/conjet
conjet start
```

## Usage

Runtime commands:

```sh
conjet start
conjet status
conjet shell
conjet run hello-world
conjet compose up
conjet stop
```

Project workflow:

```sh
conjet project init /path/to/project
conjet project attach /path/to/project
conjet sync push /path/to/project
conjet sync watch /path/to/project
conjet project run --path /path/to/project node:22-alpine npm install
conjet sync export dist --to /tmp/exported --path /path/to/project
```

ConjetFS keeps host-authoritative files such as source, lockfiles, Dockerfiles,
and compose files synchronized into the VM-native workspace. Dependency and
build directories such as `node_modules`, `target`, `.next`, `.turbo`, `.cache`,
and `vendor` are intentionally created inside Linux-native storage.

VM image commands:

```sh
conjet vm fetch-conjet-core --force
conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker --force
conjet vm import-efi-disk --image /path/to/disk.raw --cloud-init-docker
conjet vm validate
conjet vm logs --lines 100
```

Run `conjet --help` for the current command surface.

## Build

```sh
swift build
swift test
```

Virtualization.framework requires a signed binary with the virtualization
entitlement for local VM runs:

```sh
swift build
build-support/sign-debug.sh
.build/debug/conjet start
```

## Benchmarks

Benchmark code is isolated from the production Conjet package:

```sh
swift build --package-path benchmarks
swift test --package-path benchmarks
swift run --package-path benchmarks conjet-bench --help
```

Run the full parallel benchmark wrapper across Conjet, OrbStack, and Colima.
This command validates `sudo -v` first because the energy gate needs
`powermetrics` privileges:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,orbstack,colima \
  --samples 10 \
  --output-dir benchmarks/reports/run-all-local
```

Run only the energy superiority gate:

```sh
swift run --package-path benchmarks conjet-bench energy-gate \
  --contexts conjet,orbstack,colima \
  --workloads idle,container-start-loop,hot-reload-loop,compose-loop,npm-install,pnpm-install,cargo-build \
  --samples 10 \
  --require-power \
  --output-dir benchmarks/reports/energy-gate-local
```

The benchmark report distinguishes warm results, cold/no-cache results,
strict-bind topology, smart-bind/native-overlay topology, ConjetFS fast path,
polyglot real-project coverage, and measured/skipped energy claims. Do not use
warm cached results as cold evidence, and do not claim energy superiority unless
the power gate measured and passed.

## Repository Layout

- `Sources/ConjetCLI`: production CLI.
- `Sources/ConjetDaemon`: daemon entry point.
- `Sources/ConjetCore`: shared runtime, VM, Docker, project, and sync logic.
- `Sources/ConjetPower`: power policy support.
- `Sources/ConjetVZ`: Virtualization.framework integration.
- `benchmarks/`: standalone benchmark Swift package and reports.
- `docs/`: architecture, benchmark methodology, power methodology, and assets.
- `guest/`: Conjet Core guest image build assets.
- `Formula/`: Homebrew formula for the tap.

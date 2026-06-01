<img src="docs/assets/Conjet.png" width="150">

**Super Sonic Speed containers for macOS developers.**

Conjet is an open-source, Docker-friendly container runtime for macOS. It is
designed to make local container development feel fast, simple, and natural.

Use Conjet when you want a lightweight macOS container workflow with quick
startup, responsive project loops, Compose support, and clean command-line
tools.

---

## Features

- Fast macOS container runtime
- Docker-compatible developer workflow
- Compose support for local projects
- Secure localhost Docker TCP/UDP port publishing
- Simple profiles for separate workspaces
- Project sync commands for local development
- Smart storage behavior for dependency and build-heavy projects
- Benchmark tooling for comparing Conjet, OrbStack, and Colima
- Energy benchmark path when macOS power metrics are available

Kubernetes is not supported yet. It is planned for a later iteration.

---

## Install

### Homebrew

```sh
brew tap omega13-engr/conjet https://github.com/omega13-engr/conjet.git
brew install conjet
```

### From Source

```sh
git clone https://github.com/omega13-engr/conjet.git
cd conjet
swift build
swift test
```

Run the CLI from source:

```sh
swift run conjet --help
```

---

## Quick Start

Check your setup:

```sh
conjet doctor
```

Start Conjet:

```sh
conjet start
```

Check status:

```sh
conjet status
```

Run a container:

```sh
conjet run hello-world
```

Use Compose:

```sh
conjet compose up
```

Inspect published ports:

```sh
conjet port list
conjet port diagnose 3000/tcp
conjet network status
```

Conjet publishes Docker ports to localhost by default. Use `conjet port list`
and `conjet port diagnose` when you need to inspect a local service.

Open a shell:

```sh
conjet shell
```

Stop Conjet:

```sh
conjet stop
```

See all commands:

```sh
conjet --help
```

---

## Profiles

Profiles let you keep separate Conjet environments.

```sh
conjet --profile work start
conjet --profile work status
conjet --profile work stop
```

You can move Conjet state with:

```sh
export CONJET_HOME=/path/to/conjet-home
```

---

## Project Workflow

Initialize a project:

```sh
conjet project init .
```

Attach it to Conjet:

```sh
conjet project attach .
```

Push source into the Conjet workspace:

```sh
conjet sync push .
```

Watch for changes:

```sh
conjet sync watch .
```

Run a command in the project:

```sh
conjet project run --path . node:22-alpine npm install
```

Export generated output:

```sh
conjet sync export dist --to ./exported --path .
```

---

## Build

```sh
swift build
swift test
```

Release build:

```sh
swift build -c release
```

---

## Releases

Conjet and Conjet Core images are released separately:

- `conjet-vX.Y.Z` for the CLI and daemon
- `conjet-core-vX.Y.Z` for the VM image

Both release lanes use semantic versioning.

---

## Benchmarks

Conjet includes a separate benchmark package for local comparisons.

The benchmark runner can compare:

- Conjet
- OrbStack
- Colima

It reports timing, failures, topology labels, and energy data when power
measurement is available. The benchmark output is comparison data, not a global
performance claim.

Build the benchmark package:

```sh
swift build --package-path benchmarks
```

Run benchmark tests:

```sh
swift test --package-path benchmarks
```

Run the local comparison:

```sh
swift run --package-path benchmarks conjet-bench run \
  --contexts conjet,orbstack,colima \
  --samples 10 \
  --output-dir benchmarks/reports/run-all-local
```

Run only the energy benchmark:

```sh
swift run --package-path benchmarks conjet-bench energy-gate \
  --contexts conjet,orbstack,colima \
  --workloads idle,container-start-loop,hot-reload-loop,compose-loop,npm-install,pnpm-install,cargo-build \
  --samples 10 \
  --require-power \
  --output-dir benchmarks/reports/energy-gate-local
```

Energy measurements may require `sudo` because macOS power metrics are
privileged.

Run only the networking benchmark:

```sh
swift run --package-path benchmarks conjet-bench network-gate \
  --contexts conjet,orbstack,colima \
  --samples 10 \
  --output-dir benchmarks/reports/network-gate-local
```

---

## Status

Conjet is under active development.

Current focus:

- faster local container workflows
- better project sync behavior
- broader benchmark comparisons
- clearer energy measurements
- production-ready macOS developer experience

---

## License

Conjet is free and open source.

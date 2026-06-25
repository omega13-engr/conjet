---
name: conjet-container-engineering
description: Use for Conjet container engineering across Docker compatibility, conjet run/compose workflows, metadata repair, port publishing, filesystem sync, and fast container build performance.
---

# Conjet Container Engineering

Use this skill when work touches Docker-compatible container behavior, fast
container builds, filesystem sharing, metadata repair, or container networking.

## Context To Read

- `Sources/ConjetCLI/main.swift`
- `Sources/ConjetVZ/DockerRunExecutor.swift`
- `Sources/ConjetVZ/DockerSocketBridge.swift`
- `Sources/ConjetVZ/DockerCreatePublicationIntent.swift`
- `Sources/ConjetVZ/DockerPublishedPortForwarder.swift`
- `Sources/ConjetVZ/DockerServiceQuiescer.swift`
- `Sources/ConjetCore/DockerMetadataRepair.swift`
- `Sources/ConjetCore/DockerContextManager.swift`
- `Sources/ConjetCore/ConjetFS.swift`
- `Sources/ConjetCore/HostShareMounter.swift`
- `Sources/ConjetCore/ConjetPackageTopologyOptimizer.swift`
- `docs/benchmark-methodology.md`
- `benchmarks/README.md`

## Engineering Rules

- Preserve Docker CLI and API expectations unless the divergence is explicit and
  documented.
- Treat metadata repair as safety-critical. Prefer dry-run, backups, and
  containerd state verification before destructive changes.
- Optimize fast-build paths around real dependency-heavy workflows, not synthetic
  micro-optimizations alone.
- Keep host share and path classification behavior predictable across internal
  disks, external volumes, and ignored build/dependency directories.
- For performance claims, provide benchmark commands, sample counts, and any
  caveats about environment or power state.

## Change QA Requirements

For any code change, bug fix, update, or new feature:

- Run focused local tests that prove the change.
- Store generated artifacts, scratch homes, logs, screenshots, staged apps, and
  DMGs under `/tmp` using `mktemp -d`.
- Capture E2E QA screenshots for affected user-visible app, runtime, packaging,
  or release surfaces. If the changed surface has no meaningful screenshot
  target, state why and keep other local test evidence under `/tmp`.
- Do not stop, restart, kill, or otherwise interrupt the user's running Conjet
  app, `conjetd`, VM, containers, or Docker socket unless the user explicitly
  approves it.

## Validation

```sh
swift test --filter DockerRunExecutorTests
swift test --filter DockerSocketBridgeTests
swift test --filter DockerPublishedPortForwarderTests
swift test --filter DockerMetadataRepairerTests
swift test --filter DockerContextManagerTests
swift test --filter ConjetPackageTopologyOptimizerTests
swift test --package-path benchmarks
```

Broaden to `swift test` when container behavior crosses daemon, CLI, or VM
boundaries.

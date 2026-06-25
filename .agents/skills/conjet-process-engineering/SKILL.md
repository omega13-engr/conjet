---
name: conjet-process-engineering
description: Use for Conjet process engineering including subprocess execution, daemon supervision, pid files, sockets, signals, timeouts, environment, and non-hanging CLI behavior.
---

# Conjet Process Engineering

Use this skill when work touches process launching, daemon supervision, lock
recovery, sockets, protocol framing, stdout/stderr handling, or CLI hangs.

## Context To Read

- `Sources/ConjetCLI/main.swift`
- `Sources/ConjetDaemon/main.swift`
- `Sources/ConjetCore/DaemonProcessSupervisor.swift`
- `Sources/ConjetCore/ProcessRunner.swift`
- `Sources/ConjetCore/UnixSocket.swift`
- `Sources/ConjetCore/DaemonProtocol.swift`
- `Sources/ConjetCore/ConjetBinaryFrame.swift`
- `Sources/ConjetCore/ConjetPaths.swift`
- `Sources/ConjetCore/ConjetEnvironment.swift`
- `Tests/ConjetCoreTests/DaemonProcessSupervisorTests.swift`
- `Tests/ConjetCoreTests/ProcessRunnerTests.swift`
- `Tests/ConjetCoreTests/UnixSocketTests.swift`
- `Tests/ConjetCoreTests/DaemonProtocolTests.swift`
- `Tests/ConjetCoreTests/BinaryFrameTests.swift`

## Engineering Rules

- A stuck or unresponsive daemon should not leave `conjet start`, `stop`, or
  `status` waiting forever.
- Treat pid files and socket files as evidence, not proof of a healthy daemon.
- Preserve stdout/stderr when it matters for diagnosis, but keep normal user
  output concise.
- Use deterministic timeouts and explicit errors at process boundaries.
- Avoid zombie processes and orphaned supervisors.
- Do not mutate user SSH configuration while solving process issues.

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
swift test --filter DaemonProcessSupervisorTests
swift test --filter ProcessRunnerTests
swift test --filter UnixSocketTests
swift test --filter DaemonProtocolTests
swift test --filter BinaryFrameTests
```

Add tests for stale locks, refused sockets, timeout paths, and process output
when changing lifecycle behavior.

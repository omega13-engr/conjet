---
name: conjet-runtime-debug
description: Use for Conjet daemon lifecycle bugs including conjet start/stop/restart/status, stale pid files, sockets, CONJET_HOME, app startup, and external volume permissions.
---

# Conjet Runtime Debug

Use this skill when diagnosing runtime behavior in the CLI, daemon, or
`Conjet.app`.

## Context To Read

- `Sources/ConjetCLI/main.swift`
- `Sources/ConjetCore/DaemonProcessSupervisor.swift`
- `Sources/ConjetCore/ConjetPaths.swift`
- `Sources/ConjetCore/ConjetEnvironment.swift`
- `Sources/ConjetAppCore/ToolResolver.swift`
- `Sources/ConjetApp/Services/ConjetBackgroundService.swift`
- `Tests/ConjetCoreTests/DaemonProcessSupervisorTests.swift`
- `Tests/ConjetAppCoreTests/ConjetAppCoreTests.swift`

## Evidence Checklist

Gather this before deciding the fix:

- exact command and output,
- current `CONJET_HOME`,
- profile name,
- pid file path and pid state,
- daemon socket path and connection result,
- whether `Conjet.app` is running,
- whether the home path is under `/Volumes`,
- relevant `conjetd` log tail,
- whether the CLI is the bundled cask binary, formula binary, or source build.

## Diagnostic Rules

- If a pid exists but the socket refuses connections, classify it as stale or
  unresponsive unless evidence shows a healthy daemon.
- If `CONJET_HOME` points under `/Volumes`, include macOS TCC in the diagnosis:
  Terminal and `Conjet.app` may need Removable Volumes or Full Disk Access.
- If `conjet start` hangs after SSH config registration, inspect daemon launch,
  lock recovery, socket readiness, and user-facing timeout handling.
- The app and CLI should resolve the same configured home when launched from the
  same user intent. Be explicit when launchd or Finder cannot inherit shell env.
- Do not delete user runtime data unless the user explicitly asks for cleanup.
- Do not edit `~/.ssh/config`.

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

Use targeted tests and temporary homes:

```sh
swift test --filter DaemonProcessSupervisorTests
swift test --filter ConjetAppCoreTests
swift build
qa_root="$(mktemp -d /tmp/conjet-runtime.XXXXXX)"
CONJET_DISABLE_MENU_BAR_APP=1 CONJET_HOME="$qa_root/home" .build/debug/conjet status
```

When changing lifecycle behavior, add or update tests for stale locks,
unresponsive daemons, and user-facing recovery output.

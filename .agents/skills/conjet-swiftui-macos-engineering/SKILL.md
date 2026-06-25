---
name: conjet-swiftui-macos-engineering
description: Use for Conjet SwiftUI macOS app engineering, menu bar behavior, app state, settings, windows, background service calls, and bundled tool resolution.
---

# Conjet SwiftUI macOS Engineering

Use this skill when work touches the SwiftUI app, menu bar UI, app state,
settings, windows, or app-to-CLI integration.

## Context To Read

- `Sources/ConjetApp/App/ConjetApp.swift`
- `Sources/ConjetApp/Views/MenuBarView.swift`
- `Sources/ConjetApp/Views/ContentView.swift`
- `Sources/ConjetApp/Views/OverviewView.swift`
- `Sources/ConjetApp/Views/SidebarView.swift`
- `Sources/ConjetApp/Views/UIComponents.swift`
- `Sources/ConjetApp/Views/SettingsView.swift`
- `Sources/ConjetApp/Stores/ConjetAppState.swift`
- `Sources/ConjetApp/Services/ConjetBackgroundService.swift`
- `Sources/ConjetAppCore/ConjetManagementService.swift`
- `Sources/ConjetAppCore/ToolResolver.swift`
- `Tests/ConjetAppTests/ConjetAppStateTests.swift`
- `Tests/ConjetAppCoreTests/ConjetAppCoreTests.swift`

## Engineering Rules

- Keep UI updates main-thread safe and avoid blocking views or menu bar actions
  while shelling out or polling daemon state.
- Preserve menu bar startup behavior. The app should still communicate useful
  status when the daemon is offline or unresponsive.
- Resolve bundled tools from `Conjet.app` first when running from the packaged
  app, then fall back to reasonable developer paths.
- Be explicit about `CONJET_HOME`: Finder-launched apps do not automatically
  inherit shell environment variables.
- Distinguish legitimate macOS privacy prompts from packaging/quarantine bugs.

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
swift test --filter ConjetAppStateTests
swift test --filter ConjetAppCoreTests
swift build
```

For UI changes, also run screenshot-backed E2E QA with screenshot output under
`/tmp`.

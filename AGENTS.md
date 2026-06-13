# Conjet Agent Instructions

These instructions apply to AI coding agents working in this repository.

## Project Context

Conjet is a SwiftPM-first macOS container runtime. The main products are:

- `conjet`: command-line client.
- `conjetd`: daemon and VM/runtime supervisor.
- `Conjet.app`: SwiftUI macOS app bundled with the CLI tools.
- `conjet-core`: guest VM image released on its own release lane.

The repository also owns the Homebrew formula and cask used for distribution.

## Operating Rules

- Use conventional commit messages for any commit.
- Do not edit the user's global SSH configuration, including `~/.ssh/config`.
- Preserve unrelated working tree changes. Inspect before editing files that may contain user changes.
- Prefer project scripts and existing release docs over ad hoc commands.
- Keep macOS release work aligned with Homebrew behavior: the cask installs `/Applications/Conjet.app` and links the bundled `conjet` and `conjetd` tools; the formula remains useful for source or keg-managed CLI installs.
- Treat ad-hoc signing as an early-release fallback only. Production releases should use Developer ID signing, notarization, stapling, and a checksum generated from the final DMG.

## Discovery

For release and packaging work, read these first:

- `VERSION`
- `docs/release.md`
- `docs/homebrew.md`
- `.github/workflows/release-conjet.yml`
- `build-support/stage-macos-app.sh`
- `build-support/create-macos-dmg.sh`
- `build-support/render-homebrew-formula.sh`
- `build-support/render-homebrew-cask.sh`

For runtime lifecycle work, read these first:

- `Sources/ConjetCLI/main.swift`
- `Sources/ConjetCore/DaemonProcessSupervisor.swift`
- `Sources/ConjetCore/ConjetPaths.swift`
- `Sources/ConjetCore/ConjetEnvironment.swift`
- `Sources/ConjetAppCore/ToolResolver.swift`
- `Sources/ConjetApp/Services/ConjetBackgroundService.swift`

For container, Docker, and fast-build work, read these first:

- `Sources/ConjetVZ/DockerRunExecutor.swift`
- `Sources/ConjetVZ/DockerSocketBridge.swift`
- `Sources/ConjetVZ/DockerPublishedPortForwarder.swift`
- `Sources/ConjetCore/DockerMetadataRepair.swift`
- `Sources/ConjetCore/DockerContextManager.swift`
- `Sources/ConjetCore/ConjetFS.swift`
- `Sources/ConjetCore/HostShareMounter.swift`
- `Sources/ConjetCore/ConjetPackageTopologyOptimizer.swift`
- `benchmarks/README.md`

For SwiftUI macOS app and menu bar work, read these first:

- `Sources/ConjetApp/App/ConjetApp.swift`
- `Sources/ConjetApp/Views/MenuBarView.swift`
- `Sources/ConjetApp/Stores/ConjetAppState.swift`
- `Sources/ConjetApp/Services/ConjetBackgroundService.swift`
- `Sources/ConjetAppCore/ConjetManagementService.swift`
- `Sources/ConjetAppCore/ToolResolver.swift`

For process engineering work, read these first:

- `Sources/ConjetDaemon/main.swift`
- `Sources/ConjetCore/ProcessRunner.swift`
- `Sources/ConjetCore/UnixSocket.swift`
- `Sources/ConjetCore/DaemonProtocol.swift`
- `Sources/ConjetCore/ConjetBinaryFrame.swift`

For macOS host VM and Linux guest VM work, read these first:

- `Sources/ConjetVZ/VirtualMachineController.swift`
- `Sources/ConjetVZ/VirtualizationProbe.swift`
- `Sources/ConjetVZ/VMAssetManifest.swift`
- `Sources/ConjetVZ/CloudInitSeedBuilder.swift`
- `Sources/ConjetVZ/InitramfsBuilder.swift`
- `guest/image/conjet-core/README.md`
- `guest/image/conjet-core/scripts/image.sh`
- `guest/image/conjet-core/scripts/cloud-image.sh`

If `.chum-mem` exists, load its `projectId` before using ChumMem MCP tools. If the ChumMem MCP transport fails, report the failure and continue with direct repository inspection.

## Validation

Use focused checks while iterating and broader checks before finishing release-sensitive work:

```sh
swift build
swift test
swift test --filter DaemonProcessSupervisorTests
swift test --filter ConjetAppCoreTests
```

For packaging simulation:

```sh
swift test
build-support/stage-macos-app.sh \
  --configuration release \
  --version "$(cat VERSION)" \
  --dist-dir dist \
  --signing-identity - \
  --entitlements build-support/conjet-release.entitlements
build-support/create-macos-dmg.sh \
  --version "$(cat VERSION)" \
  --dist-dir dist \
  --arch "$(uname -m)"
```

Verify generated app and DMG behavior before changing release assets:

```sh
/usr/bin/codesign --verify --deep --strict --verbose=2 dist/Conjet.app
/usr/bin/xattr -l dist/Conjet.app || true
hdiutil attach "dist/conjet-$(cat VERSION)-macos-$(uname -m).dmg"
```

## AI Agent Surfaces

Project-local Claude Code agents live in `.claude/agents/`.
Project-local Claude Code skills live in `.claude/skills/`.
Project-local Codex custom agents live in `.codex/agents/`.
Project-local Codex skills live in `.agents/skills/`.

See `docs/ai-agents-and-skills.md` for the registry and maintenance rules.

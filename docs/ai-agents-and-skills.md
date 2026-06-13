# AI Agents and Skills

Conjet keeps project-specific AI guidance in the repository so Claude Code and
Codex CLI can use the same release, runtime, packaging, container, SwiftUI app,
process, and VM engineering expectations.

## Source Formats

The files follow these official formats:

- Claude Agent Skills require a `SKILL.md` file with YAML frontmatter containing `name` and `description`: <https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview>
- Claude Code project subagents are Markdown files under `.claude/agents/`: <https://code.claude.com/docs/en/sub-agents>
- Claude Code project skills are under `.claude/skills/<skill-name>/SKILL.md`: <https://code.claude.com/docs/en/skills>
- Codex skills are under `.agents/skills/<skill-name>/SKILL.md`: <https://developers.openai.com/codex/skills>
- Codex custom agents are TOML files under `.codex/agents/`: <https://developers.openai.com/codex/subagents>

## Repository Layout

| Surface | Path | Purpose |
| --- | --- | --- |
| Codex instructions | `AGENTS.md` | Repository-wide operating rules for Codex CLI and compatible agents. |
| Claude memory | `CLAUDE.md` | Short Claude Code entry point pointing to project agents and skills. |
| Claude subagents | `.claude/agents/*.md` | Specialized Claude Code agents that can be delegated to. |
| Claude skills | `.claude/skills/*/SKILL.md` | Focused Claude Code workflows, invocable with `/skill-name`. |
| Codex custom agents | `.codex/agents/*.toml` | Specialized Codex CLI subagent configurations. |
| Codex skills | `.agents/skills/*/SKILL.md` | Focused Codex workflows, invocable with `$skill-name` or implicitly by description. |

## Agents

### `conjet-release-engineer`

Use for:

- release workflow changes,
- version bumps and semantic release tags,
- GitHub Actions release failures,
- GitHub release asset validation,
- Homebrew formula and cask updates.

Primary files:

- `VERSION`
- `docs/release.md`
- `docs/homebrew.md`
- `.github/workflows/release-conjet.yml`
- `Formula/conjet.rb`
- `Casks/conjet.rb`
- `build-support/render-homebrew-formula.sh`
- `build-support/render-homebrew-cask.sh`

### `conjet-runtime-debugger`

Use for:

- `conjet start`, `stop`, `restart`, or `status` bugs,
- stale pid files or unresponsive `conjetd` sockets,
- `CONJET_HOME` behavior,
- external volume permission and TCC behavior,
- daemon/app lifecycle mismatches.

Primary files:

- `Sources/ConjetCLI/main.swift`
- `Sources/ConjetCore/DaemonProcessSupervisor.swift`
- `Sources/ConjetCore/ConjetPaths.swift`
- `Sources/ConjetCore/ConjetEnvironment.swift`
- `Sources/ConjetAppCore/ToolResolver.swift`
- `Sources/ConjetApp/Services/ConjetBackgroundService.swift`

### `conjet-macos-packaging-engineer`

Use for:

- `Conjet.app` layout and bundled CLI tools,
- app signing, entitlements, xattrs, and Gatekeeper behavior,
- DMG staging and mount validation,
- Homebrew cask installation of the app and linked binaries.

Primary files:

- `build-support/stage-macos-app.sh`
- `build-support/create-macos-dmg.sh`
- `build-support/conjet-release.entitlements`
- `.github/workflows/release-conjet.yml`
- `Casks/conjet.rb`
- `Formula/conjet.rb`

### `conjet-container-engineer`

Use for:

- Docker-compatible command behavior,
- container image and metadata repair,
- `conjet run`, Compose-adjacent workflows, and fast build paths,
- filesystem sync and host share behavior,
- Docker socket bridging and published ports.

Primary files:

- `Sources/ConjetVZ/DockerRunExecutor.swift`
- `Sources/ConjetVZ/DockerSocketBridge.swift`
- `Sources/ConjetVZ/DockerPublishedPortForwarder.swift`
- `Sources/ConjetCore/DockerMetadataRepair.swift`
- `Sources/ConjetCore/DockerContextManager.swift`
- `Sources/ConjetCore/ConjetFS.swift`
- `Sources/ConjetCore/HostShareMounter.swift`
- `Sources/ConjetCore/ConjetPackageTopologyOptimizer.swift`
- `benchmarks/README.md`

### `conjet-swiftui-macos-app-engineer`

Use for:

- SwiftUI app views, state, settings, and window behavior,
- menu bar startup and actions,
- app background service calls,
- bundled tool resolution,
- app behavior around `CONJET_HOME` and macOS privacy prompts.

Primary files:

- `Sources/ConjetApp/App/ConjetApp.swift`
- `Sources/ConjetApp/Views/MenuBarView.swift`
- `Sources/ConjetApp/Stores/ConjetAppState.swift`
- `Sources/ConjetApp/Services/ConjetBackgroundService.swift`
- `Sources/ConjetAppCore/ConjetManagementService.swift`
- `Sources/ConjetAppCore/ToolResolver.swift`

### `conjet-process-engineer`

Use for:

- subprocess execution,
- daemon supervision and pid files,
- socket readiness and daemon protocol behavior,
- signal, timeout, stdout, and stderr handling,
- preventing hung CLI operations.

Primary files:

- `Sources/ConjetCLI/main.swift`
- `Sources/ConjetDaemon/main.swift`
- `Sources/ConjetCore/DaemonProcessSupervisor.swift`
- `Sources/ConjetCore/ProcessRunner.swift`
- `Sources/ConjetCore/UnixSocket.swift`
- `Sources/ConjetCore/DaemonProtocol.swift`
- `Sources/ConjetCore/ConjetBinaryFrame.swift`

### `conjet-vm-engineer`

Use for:

- macOS Virtualization.framework host work,
- Linux guest image engineering,
- cloud-init, initramfs, and boot diagnostics,
- VM asset manifests and architecture handling,
- guest Docker service behavior and VM boundary networking.

Primary files:

- `Sources/ConjetVZ/VirtualMachineController.swift`
- `Sources/ConjetVZ/VirtualizationProbe.swift`
- `Sources/ConjetVZ/VMAssetManifest.swift`
- `Sources/ConjetVZ/CloudInitSeedBuilder.swift`
- `Sources/ConjetVZ/InitramfsBuilder.swift`
- `Sources/ConjetCore/ConjetCoreReleaseResolver.swift`
- `guest/image/conjet-core/README.md`
- `guest/image/conjet-core/scripts/image.sh`
- `guest/image/conjet-core/scripts/cloud-image.sh`

## Skills

The project ships the same focused skill workflows for Claude Code and
Codex CLI:

- `conjet-release`: release CI/CD, versioning, GitHub Release, formula, and cask workflow.
- `conjet-runtime-debug`: daemon lifecycle, socket, pid, `CONJET_HOME`, and external volume troubleshooting.
- `conjet-macos-packaging`: app bundle, DMG, signing, xattr, cask, and bundled CLI validation.
- `conjet-container-engineering`: Docker compatibility, metadata repair, filesystem sync, networking, and fast build validation.
- `conjet-swiftui-macos-engineering`: SwiftUI app, menu bar, app state, background service, and bundled tool workflows.
- `conjet-process-engineering`: process execution, daemon supervision, pid/socket readiness, timeouts, and CLI hang prevention.
- `conjet-vm-engineering`: macOS host VM, Linux guest image, cloud-init, initramfs, VM assets, and guest Docker workflows.

Skills should remain instruction-only unless a deterministic validation script
is clearly worth sharing across both assistant surfaces.

## Invocation Examples

Claude Code:

```text
Use the conjet-release-engineer agent to review the release workflow changes.
/conjet-macos-packaging validate the DMG and cask install path.
/conjet-swiftui-macos-engineering debug why the menu bar is not starting.
```

Codex CLI:

```text
Spawn conjet_release_engineer to inspect this release branch.
$conjet-runtime-debug diagnose why conjet start is stuck.
Spawn conjet_container_engineer to inspect Docker build performance.
```

## Maintenance Rules

- Keep each agent narrow. Add a new agent only when the task needs a different mental model or validation surface.
- Keep skill descriptions short and trigger-oriented; both Claude and Codex use descriptions for discovery.
- Do not add hidden network fetches, install commands, or credential access to skills.
- Keep the change QA rule in every agent and skill: code changes, updates, fixes, and features require local validation with artifacts under `/tmp`, screenshot-backed E2E QA for affected user-visible surfaces, and no interruption of the user's running Conjet app, `conjetd`, VM, containers, or Docker socket without explicit approval.
- Keep release and packaging instructions synchronized with `docs/release.md`, `docs/homebrew.md`, and `.github/workflows/release-conjet.yml`.
- If the cask/formula behavior changes, update both the Homebrew docs and the release skill instructions in the same change.

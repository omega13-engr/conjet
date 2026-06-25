# Claude Code Notes

This project includes Claude Code subagents and skills for the Conjet release,
runtime, macOS packaging, container, SwiftUI app, process, and VM workflows.

Use these project subagents when the task matches their scope:

- `conjet-release-engineer`: release workflow, GitHub Actions, versioning, Homebrew formula/cask, GitHub Releases.
- `conjet-runtime-debugger`: `conjet start`, daemon socket/pid lock recovery, `CONJET_HOME`, external volume and TCC issues.
- `conjet-macos-packaging-engineer`: `Conjet.app`, bundled tools, signing, entitlements, xattrs, DMG layout, cask install behavior.
- `conjet-container-engineer`: Docker compatibility, container metadata, run/build flows, port publishing, filesystem sync, fast container builds.
- `conjet-swiftui-macos-app-engineer`: SwiftUI app, menu bar app, app state, settings, windows, background service, bundled tool resolution.
- `conjet-process-engineer`: subprocess execution, daemon supervision, pid files, sockets, signals, timeouts, non-hanging CLI behavior.
- `conjet-vm-engineer`: macOS Virtualization.framework host work, Linux guest image, cloud-init, initramfs, VM assets, guest Docker services.

Use these project skills when a focused workflow is enough:

- `/conjet-release`
- `/conjet-runtime-debug`
- `/conjet-macos-packaging`
- `/conjet-container-engineering`
- `/conjet-swiftui-macos-engineering`
- `/conjet-process-engineering`
- `/conjet-vm-engineering`

For any code change, bug fix, update, or new feature, run local validation with generated artifacts under `/tmp`, capture E2E QA screenshots for affected user-visible surfaces, and do not interrupt the user's running Conjet app, `conjetd`, VM, containers, or Docker socket unless explicitly approved.

Follow `AGENTS.md` for repository-wide operating rules and validation commands.

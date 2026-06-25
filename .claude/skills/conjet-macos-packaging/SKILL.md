---
name: conjet-macos-packaging
description: Use for Conjet.app packaging, bundled CLI tools, code signing, entitlements, xattrs, Gatekeeper prompts, DMG creation, and Homebrew cask install behavior.
---

# Conjet macOS Packaging

Use this skill when the task touches app bundle structure, signing, notarization,
DMG creation, Homebrew cask behavior, or macOS privacy prompts after install.

## Context To Read

- `build-support/stage-macos-app.sh`
- `build-support/create-macos-dmg.sh`
- `build-support/notarize-macos-dmg.sh`
- `build-support/conjet-release.entitlements`
- `.github/workflows/release-conjet.yml`
- `Casks/conjet.rb`
- `Formula/conjet.rb`
- `Sources/ConjetApp/App/ConjetApp.swift`
- `Sources/ConjetAppCore/ToolResolver.swift`

## Bundle Contract

- `Conjet.app/Contents/MacOS/ConjetApp` is the app executable.
- `Conjet.app/Contents/Resources/ConjetTools/conjet` is the bundled CLI.
- `Conjet.app/Contents/Resources/ConjetTools/conjetd` is the bundled daemon.
- The release DMG contains `Conjet.app`, `bin/conjet`, `bin/conjetd`, and an
  `/Applications` alias.
- The cask installs `Conjet.app` into `/Applications` and links bundled CLI tools
  into Homebrew's bin directory.
- Packaging must clear quarantine and other extended attributes during staging
  so users do not need to run `xattr -cr /Applications/Conjet.app`.

## Signing Rules

- Use ad-hoc signing only for local simulation and early distribution.
- Production release builds should use Developer ID signing with the release
  entitlements, notarize the DMG, staple it, then compute the checksum.
- If a prompt appears after install, distinguish quarantine/xattr problems from
  legitimate macOS privacy prompts caused by external volumes or protected
  folders.

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
qa_root="$(mktemp -d /tmp/conjet-package.XXXXXX)"
build-support/stage-macos-app.sh --configuration release --version "$(cat VERSION)" --dist-dir "$qa_root/dist" --signing-identity - --entitlements build-support/conjet-release.entitlements
/usr/bin/codesign --verify --deep --strict --verbose=2 "$qa_root/dist/Conjet.app"
/usr/bin/xattr -l "$qa_root/dist/Conjet.app" || true
build-support/create-macos-dmg.sh --version "$(cat VERSION)" --dist-dir "$qa_root/dist" --arch "$(uname -m)"
```

After DMG creation, mount it and verify the app, `bin/conjet`, `bin/conjetd`,
and `/Applications` alias are present.

---
name: conjet-release
description: Use for Conjet release CI/CD, semantic version bumps, GitHub Releases, DMG assets, and Homebrew formula or cask updates.
---

# Conjet Release

Use this skill when the task touches the Conjet app, CLI, daemon, GitHub release
workflow, Homebrew formula, Homebrew cask, or release documentation.

## Context To Read

Read these before proposing changes:

- `VERSION`
- `docs/release.md`
- `docs/homebrew.md`
- `.github/workflows/release-conjet.yml`
- `Formula/conjet.rb`
- `Casks/conjet.rb`
- `build-support/render-homebrew-formula.sh`
- `build-support/render-homebrew-cask.sh`
- `build-support/stage-macos-app.sh`
- `build-support/create-macos-dmg.sh`

## Release Model

- App, CLI, and daemon releases use `conjet-vX.Y.Z`.
- Conjet Core VM image releases use `conjet-core-vX.Y.Z` and are independent.
- The release DMG is the source artifact for both formula and cask rendering.
- The cask is the normal one-step install for `Conjet.app` plus linked bundled
  `conjet` and `conjetd` binaries.
- The formula remains valid for Homebrew-managed CLI installs and source builds,
  but do not design the normal user path around installing both formula and cask.
- If Developer ID secrets are absent, ad-hoc signing is acceptable for early
  distribution. Production releases should use Developer ID signing,
  notarization, stapling, and checksums computed after notarization.

## Workflow

1. Confirm the intended version and release lane.
2. Verify `VERSION`, workflow defaults, tags, formula, cask, docs, and caveats
   all describe the same install model.
3. Prefer existing build-support scripts over one-off release commands.
4. Update formula and cask rendering templates together when the DMG layout or
   install behavior changes.
5. Keep release notes and caveats honest about ad-hoc signing versus notarized
   production releases.
6. Do not edit the user's SSH configuration.

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

Use the narrowest command that proves the change, then broaden before release:

```sh
qa_root="$(mktemp -d /tmp/conjet-release.XXXXXX)"
swift build
swift test
build-support/stage-macos-app.sh --configuration release --version "$(cat VERSION)" --dist-dir "$qa_root/dist" --signing-identity - --entitlements build-support/conjet-release.entitlements
build-support/create-macos-dmg.sh --version "$(cat VERSION)" --dist-dir "$qa_root/dist" --arch "$(uname -m)"
```

For release workflow changes, also inspect the generated artifact names,
checksums, formula URL, cask URL, binary links, and caveats.

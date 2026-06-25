# Release Process

Conjet has two separate release lanes.

## Conjet App, CLI, and Daemon

Production runtime releases use semantic version tags:

```text
conjet-vX.Y.Z
```

The pushed tag is the source of truth for the release version.

Publishing a tag like `conjet-v0.1.0` runs `.github/workflows/release-conjet.yml`.
The workflow builds `Conjet.app`, `conjet`, `conjetd`, and the bundled Conjet
Core VMM, runs tests, signs the app bundle, creates a read-only DMG, publishes it to
GitHub Releases, renders the Homebrew formula and cask from the final DMG checksum,
opens a pull request for `Formula/conjet.rb` and `Casks/conjet.rb`, and uploads
the generated Homebrew package files to the release.

If Developer ID signing secrets are configured, the workflow signs with
Developer ID. If Apple notarization secrets are also configured, the workflow
notarizes and staples the DMG before computing the published checksum. If those
secrets are absent, the workflow intentionally falls back to ad-hoc signing and
publishes a non-notarized DMG for early distribution.

The DMG contains:

- `Conjet.app`
- `bin/conjet`
- `bin/conjetd`
- `bin/ConjetCoreVMM/Conjet Core`
- an `/Applications` alias for drag-install users

The formula installs the CLI tools and a keg-local app copy. The cask installs
`Conjet.app` into `/Applications`, which is the Homebrew-standard route for GUI
applications.

Production notarized releases require these repository secrets:

- `MACOS_CERTIFICATE_P12`: base64-encoded Developer ID Application `.p12`
- `MACOS_CERTIFICATE_PASSWORD`: password for the `.p12`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization

Optional release automation secret:

- `CONJET_RELEASE_PR_TOKEN`: fine-grained token with pull request creation
  permission. If omitted and the default GitHub Actions token cannot create
  pull requests, the release workflow still pushes the Homebrew update branch
  and prints the manual PR creation URL instead of failing the release.

Manual release:

```sh
gh workflow run release-conjet.yml -f version=0.1.0
```

For normal releases, push a semantic version tag:

```sh
git tag conjet-v0.1.0
git push origin conjet-v0.1.0
```

## Conjet Core Jetstream Assets

Conjet Core Jetstream asset releases use their own semantic version tags:

```text
conjet-core-vX.Y.Z
```

The tag must match `guest/image/conjet-core/VERSION`.

Publishing a tag like `conjet-core-v0.1.0` runs
`.github/workflows/conjet-core-image.yml`. The workflow builds the ARM64
Jetstream Linux kernel `Image` plus the Conjet-owned Docker rootfs appliance
disk and publishes both asset triplets to a separate GitHub release. It does
not fetch an Ubuntu cloud image; the rootfs appliance is built by the Conjet
rootfs builder and is required for Docker-compatible Jetstream direct-kernel
boot.

Manual release:

```sh
gh workflow run conjet-core-image.yml \
  -f version=0.1.0 \
  -f kernel_version=6.12.86 \
  -f root_disk_gb=16
```

Before publishing Jetstream assets, rehearse the workflow commands in a local
Linux container and keep outputs under `/tmp`:

```sh
build-support/run-conjet-core-release-local.sh \
  --version "$(cat guest/image/conjet-core/VERSION)"
```

## Versioning

Use semantic versioning for both lanes:

- patch: bug fixes and small compatibility fixes,
- minor: new commands or backwards-compatible feature work,
- major: breaking CLI, config, or image compatibility changes.

Keep the two versions independent. A Conjet CLI release does not require a
Conjet Core image release, and a Conjet Core image release does not require a
Conjet CLI release.

## Local Release Simulation

Use ad-hoc signing for local packaging validation:

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

Ad-hoc DMGs are useful for early distribution and structure/signing-order
validation, but they are not Gatekeeper-notarized production distributables.
Production releases should use Developer ID signing, notarization, and stapling
in GitHub Actions.

## AI-Assisted Release Work

Project-local Claude Code and Codex CLI agents and skills are available for
release, runtime, and macOS packaging work. See `docs/ai-agents-and-skills.md`
for the registry, expected trigger scopes, and validation rules.

## Runtime Updates

`conjet update` updates the active profile's Conjet Core boot assets from the
latest stable `conjet-core-vX.Y.Z` release, preserving the profile data disk.
HVF profiles fetch the matching custom Linux kernel and Docker rootfs appliance
from the same release and import them as Jetstream direct-kernel boot assets. A
fresh `conjet start` uses the same resolution path automatically when the active
profile has no VM manifest yet, so a Homebrew cask install does not require a
manual `conjet update` first.
If Conjet is running, the command stops it before replacing the boot image and
starts it again after the update. Use `--no-restart` to leave the runtime
stopped, or `--restart` to start it even when it was previously stopped.

`conjet restart` performs the matching stop/start lifecycle operation for the
active profile, prunes runtime cache before shutdown when Conjet Core is running,
and accepts the same configuration flags as `conjet start`.

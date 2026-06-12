# Release Process

Conjet has two separate release lanes.

## Conjet App, CLI, and Daemon

Production runtime releases use semantic version tags:

```text
conjet-vX.Y.Z
```

The pushed tag is the source of truth for the release version.

Publishing a tag like `conjet-v0.1.0` runs `.github/workflows/release-conjet.yml`.
The workflow builds `Conjet.app`, `conjet`, and `conjetd`, runs tests, signs the
app bundle with Developer ID, creates a read-only DMG, notarizes and staples the
DMG, publishes it to GitHub Releases, renders the Homebrew formula from the
final stapled DMG checksum, updates `Formula/conjet.rb`, and uploads the
generated formula to the release.

The DMG contains:

- `Conjet.app`
- `bin/conjet`
- `bin/conjetd`
- an `/Applications` alias for drag-install users

The release workflow requires these repository secrets:

- `MACOS_CERTIFICATE_P12`: base64-encoded Developer ID Application `.p12`
- `MACOS_CERTIFICATE_PASSWORD`: password for the `.p12`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization

Manual release:

```sh
gh workflow run release-conjet.yml -f version=0.1.0
```

For normal releases, push a semantic version tag:

```sh
git tag conjet-v0.1.0
git push origin conjet-v0.1.0
```

## Conjet Core Image

Conjet Core VM image releases use their own semantic version tags:

```text
conjet-core-vX.Y.Z
```

The tag must match `guest/image/conjet-core/VERSION`.

Publishing a tag like `conjet-core-v0.1.0` runs
`.github/workflows/conjet-core-image.yml`. The workflow builds architecture
specific VM images and publishes them to a separate GitHub release.

Manual release:

```sh
gh workflow run conjet-core-image.yml \
  -f version=0.1.0 \
  -f root_disk_gb=16 \
  -f runtime=docker
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

Local ad-hoc DMGs are useful for structure and signing-order validation, but
they are not production distributables. Production releases must use Developer ID
signing, notarization, and stapling in GitHub Actions.

## Runtime Updates

`conjet update` updates the active profile's Conjet Core VM image from the
latest stable `conjet-core-vX.Y.Z` release, preserving the profile data disk.
If Conjet is running, the command stops it before replacing the boot image and
starts it again after the update. Use `--no-restart` to leave the runtime
stopped, or `--restart` to start it even when it was previously stopped.

`conjet restart` performs the matching stop/start lifecycle operation for the
active profile, prunes runtime cache before shutdown when `conjetd` is running,
and accepts the same configuration flags as `conjet start`.

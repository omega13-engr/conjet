# Release Process

Conjet has two separate release lanes.

## Conjet CLI and Daemon

Production runtime releases use semantic version tags:

```text
conjet-vX.Y.Z
```

The pushed tag is the source of truth for the release version.

Publishing a tag like `conjet-v0.1.0` runs `.github/workflows/release-conjet.yml`.
The workflow builds `conjet` and `conjetd`, runs tests, publishes release
archives, renders the Homebrew formula from the release asset checksum, updates
`Formula/conjet.rb`, and uploads the generated formula to the release.

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

## Runtime Updates

`conjet update` updates the active profile's Conjet Core VM image from the
latest stable `conjet-core-vX.Y.Z` release, preserving the profile data disk.
If Conjet is running, the command stops it before replacing the boot image and
starts it again after the update. Use `--no-restart` to leave the runtime
stopped, or `--restart` to start it even when it was previously stopped.

`conjet restart` performs the matching stop/start lifecycle operation for the
active profile and accepts the same configuration flags as `conjet start`.

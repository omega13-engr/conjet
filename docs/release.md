# Release Process

Conjet has two separate release lanes.

## Conjet CLI and Daemon

Production runtime releases use semantic version tags:

```text
conjet-vX.Y.Z
```

The tag must match the root `VERSION` file.

Publishing a tag like `conjet-v0.1.0` runs `.github/workflows/release-conjet.yml`.
The workflow builds `conjet` and `conjetd`, runs tests, publishes release
archives, and prepares the Homebrew formula for the tap.

Manual release:

```sh
gh workflow run release-conjet.yml -f version=0.1.0
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

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
commits `Formula/conjet.rb` and `Casks/conjet.rb` back to the default branch, and
uploads the generated Homebrew package files to the release.

The current production workflow requires Developer ID signing and Apple
notarization credentials. It notarizes and staples the DMG before
computing the published checksum. Ad-hoc signing is available for local
packaging validation.

Conjet 3.0.0 was authorized for ad-hoc signing. In that mode, persistent
privileged-port authorization is unavailable. The existing
sudo-authorized one-shot helper remains the fallback. After reviewing the known
limitations, the user explicitly requested publishing the current implementation.
Conjet 3.0.0 therefore documents the unresolved host-bind failure and unvalidated
authorized low-port path rather than claiming full production readiness.

The DMG contains:

- `Conjet.app`
- `bin/conjet`
- `bin/conjetd`
- `bin/ConjetCoreVMM/Conjet Core`
- `bin/ConjetCoreVMM/conjet-network`
- `bin/ConjetCoreVMM/conjet-launchd-linux-arm64`
- an `/Applications` alias for drag-install users

The formula installs the CLI tools and a keg-local app copy. The cask installs
`Conjet.app` into `/Applications`, which is the Homebrew-standard route for GUI
applications.

Source builds require Rust and Go 1.25 or newer alongside Swift/Xcode. The stage
script builds the pinned host networking helper with CGO enabled for native
macOS DNS, bundles it beside the VMM in both app copies, and signs it without
hypervisor privileges. The helper is an app-lane artifact; this networking change
does not require a new Core/kernel image.

The experimental native executable path bundles its own static Linux
supervisor as an app resource. The release workflow builds it from the
same revision with `rustup target add aarch64-unknown-linux-musl` and
`CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld cargo build
--locked --release --target aarch64-unknown-linux-musl -p
conjet-launch-service --bin conjet-launchd`. Pass the artifact to
the stage script with `--native-guest`. The experiment uses the
existing verified Conjet Core v1.3.1 kernel; no Core release is needed.
See [experimental native execution](engineering/speed-release-scope.md).

### Native Docker default

CI and release staging build the static ARM64 Core memory helpers from
the same revision and verify the Conjet Core v1.3.1 Linux 6.12.86 Image
against the checked-in SHA-512. The staged app, menu bar helper, and
DMG command-line payload carry the guest supervisor and the verified
native Core assets. The standalone executable command retains its
`--experimental` flag.

The native Docker candidate passed 71 compatibility cases on
`c8cc705`. The separate Kiri comparison passed 81 of 91 pairs. Its
incomplete pairs include public registry setup timeouts and Kiri OOM
verification failures. Benchmark scope and engine limits apply to any
release notes. [Qualification and results](engineering/docker-benchmark-results.md#speed-065-docker-29101-comparison)
The separate [packaged 3.1.0 evaluation](engineering/packaged-native-release-evaluation.md)
recorded 58/71 frozen cases and retains the remaining release gates.

Fresh packaged Apple Silicon profiles select `native-docker` through the
ordinary start path. Native profiles use two vCPUs, a 2 GiB memory ceiling,
and a 16 GiB sparse disk. Core owns dynamic admission and reclaim. The
package provides the verified Alpine OCI layout and a clean disk template
for first boot. The daemon owns the native VM and its Docker socket and
drains the guest on stop.

Existing profile settings and Docker appliance disks stay in place. To
change an engine, first stop that profile. `conjet start --runtime docker`
selects the appliance. To select Native Docker for an existing profile,
use `conjet start --runtime native-docker --cpus 2 --memory 2G --disk 16G`
with packaged boot assets. Native Docker keeps its volume and image data
under the profile's `run/native-data` directory. Engine selection does
not convert or copy data between the two disks.

Before installing an older Conjet app, stop the profile and select the
appliance runtime. The older app can then open the original Docker disk.
The rollback rehearsal retained a named volume on the appliance and
verified each inactive engine's disk checksum during the switch.

The native scope covers the pinned Linux ARM64 public images, local image
archives, named volumes, and the qualified Docker Buildx worker. Writable
container layers and local image aliases are scoped to a boot. Host binds
use owned directories inside `run/native-data/binds` when host mounts are
enabled. SSH, privileged containers, arbitrary registries, removable host
binds, and AMD64 images use the Docker appliance profile. The native Docker
build API uses private copies of Docker 29.10.1 and Buildx 0.39.1 when
their installed checksums match the packaged pins.
Create a named volume explicitly before mounting it. Image pulls require
an idle native guest.
Use Buildx with the pinned BuildKit worker for Native Docker CLI builds.
The desktop Dockerfile editor is available in Docker appliance profiles.

Release gates include fresh packaged compatibility, legacy rollback,
independent review, required CI, Developer ID signing, notarization,
stapling, and the final DMG checksum.

Production notarized releases require these repository secrets:

- `MACOS_CERTIFICATE_P12`: base64-encoded Developer ID Application `.p12`
- `MACOS_CERTIFICATE_PASSWORD`: password for the `.p12`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization

Optional release automation secret:

- `CONJET_RELEASE_PR_TOKEN`: fine-grained token with contents write permission
  for pushing generated Homebrew updates through the repository's normal
  Git and pull request rules. If omitted, the release workflow uses the
  default GitHub Actions token.

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

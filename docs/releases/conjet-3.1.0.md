# Conjet 3.1.0 — ad-hoc signed

Fresh packaged Apple silicon profiles select Native Docker through the
ordinary Conjet startup path. Existing profiles keep their configured
runtime and data. Native and appliance volumes use separate disks.
[Native Docker scope and rollback](../release.md#native-docker-default)

The standalone command for launching a static ARM64 Linux executable
remains experimental. It supports fresh execution, preparation, one-use
claims, cancellation, bounded output, and verified guest cleanup in a
foreground Jetstream session.

This is an explicitly authorized **ad-hoc signed, non-notarized** Apple Silicon
release. Gatekeeper may block first launch. Developer ID signing, notarization
and stapling remain requirements for a future notarized release.

The speedup work was merged in PR #33. The expanded Docker compatibility suite
is separate unfinished work and is not included or claimed complete here.
The [installed ad-hoc evaluation](../engineering/installed-native-compatibility.md)
records 71/71 frozen cases with Docker 29.10.1, Buildx 0.39.1, and Compose 5.8.0.

The standalone executable experiment was tested on a single Apple M1 Pro
with no guest network and one active workload or prepared slot per session. In three
local sessions, fresh API p99 was 7.258–7.737 ms and prepared claim
through verified cleanup p99 was 2.080–3.291 ms. Preparation and
refill are measured separately. This release makes no superiority claim.
Second-host coverage, energy, equivalent Kiri guest teardown, and the
sub-1 ms target remain deferred comparative research.

The app bundles its own static guest supervisor. The experiment uses
the existing Conjet Core 1.3.1 kernel.

[Opt-in, limits, and disable instructions](../engineering/speed-release-scope.md)

[Local measurement details](../engineering/speed-qualification.md)

## Native Docker limitations

- Qualification covers the frozen 71-case ARM64 profile, not full Docker parity.
- Writable container layers and local image aliases are boot-scoped; use named
  volumes for persistent application data. Create named volumes before use.
- Native and appliance profiles retain separate disks; switching does not migrate data.
- Arbitrary registries, privileged containers, AMD64 images and general host bind
  paths are outside the qualified native scope; use the appliance profile where applicable.
- Native builds require the qualified Docker/Buildx clients and BuildKit worker.
- The separate Kiri comparison completed 81 of 91 pairs; this release does not
  claim universal performance superiority.
- Existing profiles retain their runtime choice. Stop a profile before changing
  engines; select the appliance before rolling back to Conjet 3.0.0.

The CI release builds a new package from this tag. The earlier 71-case installed
qualification applies to source 748c2a7; release metadata/workflow changes do not
constitute a fresh 71-case run on the new DMG.

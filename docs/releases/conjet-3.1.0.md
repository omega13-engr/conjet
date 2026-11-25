# Conjet 3.1.0 candidate

Fresh packaged Apple silicon profiles select Native Docker through the
ordinary Conjet startup path. Existing profiles keep their configured
runtime and data. Native and appliance volumes use separate disks.
[Native Docker scope and rollback](../release.md#native-docker-default)

The standalone command for launching a static ARM64 Linux executable
remains experimental. It supports fresh execution, preparation, one-use
claims, cancellation, bounded output, and verified guest cleanup in a
foreground Jetstream session.

The proposed version is 3.1.0. Independent review, Developer ID signing,
notarization and stapling are production release gates.
The [packaged evaluation](../engineering/packaged-native-release-evaluation.md)
records 58/71 frozen cases. Production promotion remains held.

The local verification envelope is a single Apple M1 Pro, with no guest
network and one active workload or prepared slot per session. In three
local sessions, fresh API p99 was 7.258–7.737 ms and prepared claim
through verified cleanup p99 was 2.080–3.291 ms. Preparation and
refill are measured separately. This release makes no superiority claim.
Second-host coverage, energy, equivalent Kiri guest teardown, and the
sub-1 ms target remain deferred comparative research.

The app bundles its own static guest supervisor. The experiment uses
the existing Conjet Core 1.3.1 kernel.

[Opt-in, limits, and disable instructions](../engineering/speed-release-scope.md)

[Local measurement details](../engineering/speed-qualification.md)

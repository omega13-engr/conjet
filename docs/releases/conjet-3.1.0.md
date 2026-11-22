# Conjet 3.1.0

Conjet adds an opt-in experiment for launching one static ARM64 Linux
executable in a foreground Jetstream session. The native API supports
fresh execution, explicit preparation, one-use claims, cancellation,
bounded output, and verified guest cleanup. The normal Docker commands
continue to use the existing Docker runtime.

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

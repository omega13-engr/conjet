# Conjet Docker performance plan

Superseded execution scope: the user now authorizes the [native engine plan](native-engine-v2-plan.md). Retained-engine findings below remain historical evidence.

Historical retained-engine iteration: [retained Docker latency architecture](retained-docker-latency-architecture.md).
It preserves dynamic memory and defines the SPEED-050–055 diagnostic and
optimization sequence. All gains remain unqualified until measured.

## Retained Docker architecture

Conjet keeps the unmodified Docker, Buildx and Compose clients and the
existing dockerd, containerd and runc stack. BuildKit continues to own
build execution. Compose continues to use Docker's normal API for
service lifecycle, health, networking and volumes. The performance
work targets Conjet's runtime beneath that stack.

```text
Docker / Buildx / Compose clients
             |
   private Docker Unix socket
             |
       Jetstream transport
             |
  dockerd -> containerd -> runc
     |
  BuildKit worker for builds
```

The Rust Docker adapter and authenticated native workload supervisor
remain isolated research. SPEED-027 through SPEED-036 retain their
verified fixture results. SPEED-037A is an unfinished volume-disk
experiment. The replacement expansion and qualification sequence
SPEED-037 through SPEED-045 is superseded. The research is available
for comparison through the isolated launcher and remains outside
the retained Docker release path. [Task board](task-board.md)

## Profile the retained path

SPEED-046 profiles the original Docker path with the release CLI,
daemon, Jetstream and network helper plus the pinned Core guest.
Use the existing foreground launcher with `--legacy-baseline`.
Verify the endpoint and Docker, containerd and runc versions. Record
actual artifact hashes, commands, limits, resources and cleanup.
Start with a small boot to measure the create, start, wait, remove
and CLI-exit boundaries. Trace attach separately if it contributes
and record which stages require finer attribution.

Separate host process spawn and Docker API work from guest-local
dockerd, containerd and runc spans. Use host monotonic time for host
elapsed intervals and keep guest-local spans on their own clock.
Keep cached execution, image acquisition, cold boot, application
readiness and removal acknowledgement as separate observations.
Record guest cleanup only where the backend supplies a witness.

The existing Docker path at `7e075c0` recorded API medians of
57.924 ms for create, 265.928 ms for start, 240.407 ms for wait and
20.176 ms for remove in one release comparison boot. The adapter
study at `cabbea9` used a different execution path and recorded a
0.841 candidate/Kiri API median ratio and CLI p50/p99 ratios of
1.076/1.099. Historical experiments retain their original versions,
boundaries, adverse outcomes and report verdicts. [Benchmark results](docker-benchmark-results.md)

## Evaluate one integration boundary

Keep lifecycle state, container identity, image ownership, output,
exit status and resource cleanup with their current owners. A
successful narrow experiment changes one measured host or guest
runtime boundary and preserves the normal Docker API, BuildKit and
Compose behavior. Choose an integration only after identifying where
the retained path spends time.

- If host-to-guest forwarding or wakeup delay dominates, test one
  bounded transport or scheduling adjustment through the existing
  Jetstream Docker route.
- If the time belongs to dockerd, containerd or runc, first profile
  the affected stage with the current executor. Evaluate a supported
  runtime integration only for costs attributable to that boundary.
- Keep the 25 ms host tick while the known tick-disabled stall remains
  unresolved. Preserve authenticated peer verification, output EOF,
  actual exit status, backpressure and cleanup boundaries.

Any implementation needs a named fixture, a rollback route and a
bounded correctness and performance check. Use cold and warm
diagnostics separately. An ambiguous or failed run stays in the
record. The transition authorizes evaluation of this boundary and
leaves runtime implementation for the resulting scoped task.

## Qualification and isolation

For qualification of an integration, freeze the release artifacts,
workload manifest and paired analysis before timing. Use official
pinned Kiri, identical unmodified clients and workloads, five
alternating boot pairs, and the existing 2,000 measured lifecycle
operations plus ten warmups per engine, lane and boot. Retain the
report's per-operation, cache, resource, concurrency and backend
coverage tables. The CLI parity target remains an upper paired 95%
endpoint of 1.05 for both p50 and p99. Retain the declared throughput
rules for later workloads. [Benchmark contract](docker-benchmark-plan.md)

SPEED-048 tested an opt-in Jetstream ingress wake through the retained
Docker endpoint. Use `--retained-event-wake` on the isolated launcher
or paired comparison command to select it. Omit the flag to select
the original polling path. Both modes keep the 25 ms fallback tick.
SPEED-049 measured the pinned no-network `alpine-true` API and CLI
groups against signed Kiri 0.2.2. The API missed parity. One CLI
operation failed, leaving four eligible pairs and no CLI interval.
[Retained Docker results](docker-benchmark-results.md#speed-049-retained-docker-release-lifecycle-against-kiri)

Use explicit private contexts, session-owned foreground services and
ExternalSSD scratch for artifacts and evidence. Keep builds and
timings separate. Check the installed production process identities,
Docker endpoint and selected context before and after isolation
checks. Independent review and CI gate merge. Signing,
notarization, checksum and Homebrew verification gate release.
Second-host, privileged energy, equivalent Kiri guest cleanup and
sub-1 ms research remain deferred. [Environment runbook](speedup-environment.md)

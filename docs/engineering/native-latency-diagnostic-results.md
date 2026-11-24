# Native lifecycle latency results

## SPEED-081

The frozen release from `6d98acf` reproduced the warm API baseline at
36.29 ms p50, 61.62 ms p95, and 71.59 ms p99 in a 200-operation isolated
boot. That boot and the paired runs used the pinned ARM64 Alpine image
and Docker client, no networking, the existing workload limits, and
Core dynamic memory. Each lane ran ten warmups. The production endpoint
was already offline. Candidate preflight verified the refused local
socket, absence of the installed Conjet processes, and stable socket
and configuration fingerprints before and after the boots.

The first observer pair exceeded the 5% median threshold. The revised
observer defers host serialization, uses existing guest lock holds for
stage updates, and attaches guest timestamps to the terminal reply.
The same release binaries ran each compact observer pair. The compact
API p50 overhead was 0.65% and 3.35% relative to its paired control.
The separately run CLI diagnostic had 0.66% median overhead.

| Boot | Lane | Trace | p50 (ms) | p95 (ms) | p99 (ms) |
| --- | --- | --- | ---: | ---: | ---: |
| Pair 1 first | API | off | 41.89 | 126.98 | 170.90 |
| Pair 1 second | API | on | 42.16 | 67.53 | 79.26 |
| Pair 2 first | API | on | 40.88 | 65.79 | 71.42 |
| Pair 2 second | API | off | 39.55 | 66.31 | 74.20 |
| Separate control | CLI | off | 34.33 | 56.69 | 72.80 |
| Separate trace | CLI | on | 34.56 | 52.84 | 60.90 |

All operations passed. All 420 traced API operations joined by
boot ID, workload ID, and request sequence. The three host-only workload
IDs per boot are the preflight UID/GID and output canaries. Both host
buffers reported zero overflow. The observed high tail in the first
untraced boot is retained in the evidence.

| Span | Clock | Pair 1 p50 / p95 / p99 (ms) | Pair 2 p50 / p95 / p99 (ms) |
| --- | --- | --- | --- |
| Acceptance to first demand observation | Guest | 27.32 / 33.68 / 40.11 | 26.36 / 33.32 / 40.47 |
| Observation to accepted grant | Guest | 0.91 / 29.32 / 32.47 | 1.85 / 26.44 / 29.60 |
| Observation exchange | Host | 0.60 / 2.97 / 10.86 | 0.67 / 1.70 / 12.19 |
| Publication to approval | Host | 0.06 / 27.78 / 31.46 | 0.11 / 24.75 / 28.51 |
| Helper spawn return to namespace child witness | Guest | 0.67 / 2.96 / 4.83 | 1.00 / 3.24 / 4.95 |
| Child witness to confirmed exec | Guest | 1.65 / 13.00 / 19.56 | 1.93 / 9.31 / 13.46 |
| Exit witness to reaped helper and drained output | Guest | 0.37 / 0.92 / 1.74 | 0.45 / 0.99 / 1.58 |
| Terminal read to end of API lifecycle | Host | 0.72 / 2.29 / 4.62 | 0.86 / 2.01 / 4.68 |

Pending discovery is the largest warm median stage. Publication to
approval has the largest correlation with the warm lifecycle tail in
the two traces (Pearson 0.70 and 0.80 with total latency). The request-level
span values and correlations are retained in the joined reports. Guest
timestamps share a guest-local origin. Host controller and host client
durations are measured on host clocks. The terminal reply stamp precedes
serialization, and the exec and exit stamps are supervisor receipts.
Percentiles represent each span independently.

In a separate reduced-capacity boot, the first launch discovered pending
demand after 19.85 ms and waited another 393.89 ms for the grant while
Core restored capacity. Core moved from a converged 448 MiB to 2,048 MiB
and returned to 448 MiB after cleanup. The data checksum still matched
through 12 fresh launches, and stale or expired grants were rejected.
The reduced-capacity workload has a different command and is excluded
from the warm timing table.

Raw release hashes, launcher reports, the initial observer and its
replacement, and the joined percentiles are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-081/`.

## SPEED-082

Two alternating API pairs used the same release host, guest, and
fixture. Only the diagnostic delay between authoritative demand
observations changed. The controller, authenticated workload grants,
25 ms safety tick, and terminal cleanup boundary stayed in force. Each
leg retained ten warmups and 200 measured operations. All 840 operations
passed and joined, with zero trace overflow.

| Pair | Configured observation interval | Discovery p50 / p95 / p99 (ms) | API p50 / p95 / p99 (ms) | Idle observations per second | Idle VMM CPU (% of one core) |
| --- | ---: | --- | --- | ---: | ---: |
| 1 | 30 ms | 26.09 / 32.20 / 34.45 | 40.25 / 63.67 / 71.27 | 29.14 | 5.62 |
| 1 | 5 ms | 3.28 / 4.76 / 6.24 | 6.70 / 22.18 / 26.69 | 139.86 | 14.62 |
| 2 | 5 ms | 3.48 / 4.87 / 6.34 | 6.54 / 19.56 / 25.44 | 141.43 | 13.87 |
| 2 | 30 ms | 25.47 / 32.05 / 33.33 | 40.43 / 64.77 / 70.31 | 29.43 | 5.25 |

Idle rates count completed observation exchanges in the full one-second
host clock bins inside each separate eight-second idle window. CPU
comes from cumulative VMM process time in the same window. All four
windows saw Core converge from the warm 2,048 MiB target to 448 MiB.
The measured cadence effect confirms that periodic pending discovery is
a large part of the lifecycle median. The higher idle traffic and CPU
cost rule out 5 ms polling as the release default.

The separate pressure canaries passed at both cadences. The pressure
service raised 170 high events before any container ran, triggering
growth from 448 MiB to 2,048 MiB. Each run preserved the data checksum
across 12 launches and returned to 448 MiB within the existing
pressure-qualified idle window. Final counts were 238 events at 30 ms
and 221 at 5 ms. All candidate boots verified cleanup and preserved the
production snapshot.

SPEED-083 will test a versioned, authenticated pending-demand wait on
the existing admission control connection. One thread owns the stream
and refreshes the authoritative snapshot when a pending request arrives
or the existing reconciliation interval expires. Workload-specific
approval still follows the existing controller path.

Raw timing, resource, and release identity evidence is in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-082/`.

## SPEED-083

The guest exposes `core_pending_watch_v1` on the authenticated native
Core connection. The session owner issues a bounded request and reads
its correlated reply on the same stream. The guest checks pending
demand under the ledger lock before waiting and wakes that waiter
after admitting work. On wake or the 30 ms reconciliation deadline,
it returns the current authoritative snapshot. One waiter is allowed
per guest. The host still publishes each observation to Core and sends
grants for the current boot, workload ID, sequence, and deadline.
The 25 ms VMM safety tick and verified removal boundary are unchanged.
Native Core uses the watch by default on peers with the capability.
Older guests, the explicit polling control, and the 5 ms diagnostic
cadence retain periodic discovery.

The live protocol canary started at 448 MiB. It admitted two pending
workloads and observed both identities in one snapshot. The armed
waiter saw the first admission. A watcher started after admission
returned the current snapshot immediately. Resubmitting each launch
reused the original handle. Both workloads were cancelled before exec,
and their late grants were refused. The guest rejected stale boot IDs,
invalid watch budgets and scopes, and an overlapping waiter. A
disconnected watcher expired, and a reauthenticated connection obtained
the same boot's empty snapshot.

The same release artifacts ran two untraced alternating API pairs of
200 measured operations per leg plus ten warmups. All operations
verified guest cleanup and passed.

| Pair | Mode | API p50 / p95 / p99 (ms) |
| --- | --- | --- |
| 1 | Periodic | 37.50 / 62.66 / 73.44 |
| 1 | Watch | 2.51 / 3.40 / 11.80 |
| 2 | Watch | 2.47 / 3.35 / 5.84 |
| 2 | Periodic | 40.22 / 64.72 / 72.39 |

A separate traced pair joined all 420 operations. Pending discovery
p50 fell from 24.52 ms to 0.053 ms. Watch discovery was 0.130 ms at
p95 and 0.211 ms at p99. Observation exchange spans include time
spent awaiting demand in the watch. They are separate from the
guest-local discovery duration. The eight-second idle observation
windows measured 30.00 exchanges per second and 5.37% VMM CPU with
periodic discovery, and 31.14 exchanges per second and 5.50% with the
watch. Core returned to 448 MiB in both idle windows.

The watch-mode reduced-capacity and independent-pressure canaries
both grew from 448 MiB to 2,048 MiB and shrank again. The pressure
service raised 153 high events before any container existed, then
170 by the end of churn. Both canaries preserved the checksum across
12 launches. Stale and expired grants were refused and the ownership
and shutdown checks passed.

The final release exposed the watch through the normal entry point.
Its default trace measured discovery p50 at 0.050 ms. With the same
host binary and the earlier guest, the authenticated capability check
selected periodic discovery, which measured 26.01 ms p50. Both runs
joined all warmups and measured operations with verified cleanup.

The final release passed the eight-workload concurrency diagnostic.
A separate fault probe killed its owned VMM. The adapter invalidated
the in-flight wait and refused both replay and new admission. The
launcher reported unresolved guest cleanup after SIGKILL. The fault
runner's exact private session directory was removed after verifying
the VMM had exited and no process held the directory.

### Post-change Kiri pilot

The final default release ran two 200-operation API and CLI pairs in
alternating order with the pinned Kiri 0.2.2 binary. All 1,600 measured
operations and 80 warmups passed. All native workloads verified their
guest cleanup. Kiri guest teardown remains unobserved.

| Pair | Engine | API p50 / p95 / p99 (ms) | CLI p50 / p95 / p99 (ms) | API / CLI harness operations per second |
| --- | --- | --- | --- | --- |
| 1 | Conjet native | 2.65 / 3.37 / 20.13 | 21.08 / 24.39 / 26.80 | 287.47 / 44.96 |
| 1 | Kiri 0.2.2 | 3.88 / 4.63 / 5.52 | 21.73 / 23.10 / 23.98 | 252.90 / 45.93 |
| 2 | Kiri 0.2.2 | 3.47 / 4.04 / 4.24 | 20.92 / 22.28 / 24.28 | 285.04 / 47.53 |
| 2 | Conjet native | 2.58 / 3.67 / 18.76 | 21.92 / 30.21 / 37.60 | 285.21 / 42.47 |

The isolated warm API median passed the below-5-ms target in both
boots. Native API p99 exceeded Kiri's in both pairs. The two-pair pilot
leaves formal API and CLI parity unqualified. The five-pair and broader
SPEED-065 matrix still depends on SPEED-063.

Raw data, process inventories, and release hashes are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-083/`.

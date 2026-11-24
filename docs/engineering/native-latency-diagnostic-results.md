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

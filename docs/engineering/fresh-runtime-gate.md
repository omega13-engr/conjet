# Fresh runtime gate

**SPEED-008 is in progress.** The transport experiment identified avoidable
host wake latency. Equivalent-work qualification remains open.

## Comparison criteria

Use verified image digests, equal ARM64 compute and memory limits, the same
physical host for each paired session, matching storage and cache state, and
equivalent network behavior for the timed work. Report no-network and bridge
separately. Identify the API removal and verified cleanup boundaries. A
response or an observed exit provides only its own boundary.

Use a minimum of 10,000 measured operations in each scenario across five or
more independent sessions covering two supported physical host configurations.
Alternate engine order. Report session p50, p95, and p99, and report elapsed
time and failures for all samples. Compute a paired 95% bootstrap confidence
interval by resampling independent sessions within each host configuration.
A proceed decision requires candidate p50 and p99 at least 10% below Kiri at
the equivalent boundaries for each supported configuration, with the
confidence interval supporting a gain. It also requires sustained successful
throughput at least equal to Kiri at matched concurrency after cleanup,
and passing isolation, failure and pressure checks. Report CPU time, energy,
memory and background production contention.

## Initial baseline

SPEED-002 ran original Conjet and the official Kiri 0.2.2 on an M1 Pro.
Both used the same native ARM64 Alpine image and `/bin/true`, with warm
image caches. The Docker API-visible p50/p99 was 396.837/479.683 ms for
Conjet and 3.773/5.058 ms for Kiri without networking. The bridge result
was 493.304/567.220 ms and 34.437/63.064 ms respectively. These are
100-operation descriptive observations per lane in one session per engine.
The Docker adapters could not observe verified guest cleanup. Selected
reports are under `benchmarks/reports/speed-002-initial`, and raw evidence is
under `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-002`.

## Candidate transport diagnostic

The isolated fixture used the pinned guest binary from SPEED-007. It
alternated adjacent ping requests with pings following 40 ms of idle time
and attempted 20 launches per network mode. For the table below, ping
numbers are nearest-rank percentiles of 100 idle pings and lifecycle
numbers are medians from host submission to a cleanup-complete reply.

| Native transport | Idle ping p50/p95/p99 (ms) | No-network fixture p50 (ms) | Bridge fixture p50 (ms) |
| --- | --- | ---: | ---: |
| Original, 25 ms wake tick | 17.062 / 24.645 / 27.426 | 33.886 | 110.726 |
| Socket readiness, 25 ms wake tick | 1.610 / 5.420 / 7.361 | 4.086 | 88.747 |
| Socket readiness, tick disabled, retry | 2.158 / 3.858 / 5.781 | 3.746 | 76.382 |

The original transport with its tick disabled closed the connection after
eight responses. Socket readiness completed all 200 pings in the first
tick-disabled trial, but the tenth lifecycle stalled while the bridge
workload was running and the VM reached its diagnostic time limit. The
repeat completed. Treat the tick-disabled result as diagnostic until the
stall is understood. Preserve all four sessions and the retry under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/transport`.

The wake callbacks affect only the opt-in native socket. The watcher
blocks on kernel notifications when idle, and the virtio queue owner
continues to read the stream and apply its credit limits. The bridge fixture
adds DNS and TCP canary work, while the baseline executes `/bin/true`.
These diagnostic results quantify part of Conjet's native path. The
comparison still requires a matched workload and cleanup observation.
Only the M1 Pro is currently authorized. Production stayed in service.

# Fresh runtime gate

**Decision is revise. SPEED-008 remains INPROGRESS.** The native path
improved on this Mac. The required equivalent-work qualification is open.

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

## Common static image probe

The three adapters ran the same SHA-256-pinned static ARM64 executable
with two vCPUs, a 2 GiB VM ceiling and requested workload limits of
16 MiB, four PIDs and 500 millicores. The original Conjet VMM was built
from `bbe80193412c7fc150df5a50e35b0f9b1c4f1a63`. Kiri used the
official unmodified 0.2.2 binary. Each group had 10 warmups and 20
measured operations. All 240 measurements passed their adapter's exit
and lifecycle checks. Production remained in service. The recorded
one-minute system load ranged from 5.1 to 12.4 across the session endpoints.

| Engine | Network | Lane | p50 / p95 / p99 (ms) | Sequential ops/s |
| --- | --- | --- | --- | ---: |
| Original Conjet | none | Docker API | 375.357 / 410.793 / 441.084 | 2.6 |
| Official Kiri | none | Docker API | 4.074 / 4.911 / 5.025 | 243.9 |
| Native candidate | none | Native API | 2.156 / 2.936 / 6.997 | 406.9 |
| Original Conjet | bridge | Docker API | 462.728 / 526.631 / 559.878 | 2.1 |
| Official Kiri | bridge | Docker API | 37.155 / 59.208 / 73.133 | 26.1 |
| Native candidate | bridge | Native API | 76.018 / 92.148 / 92.926 | 13.2 |
| Original Conjet | none | Docker CLI | 438.738 / 510.541 / 513.531 | 2.2 |
| Official Kiri | none | Docker CLI | 21.398 / 23.853 / 27.676 | 45.9 |
| Native candidate | none | Experimental CLI | 8.038 / 9.224 / 9.858 | 121.3 |
| Original Conjet | bridge | Docker CLI | 572.340 / 621.496 / 660.189 | 1.7 |
| Official Kiri | bridge | Docker CLI | 48.181 / 63.889 / 72.050 | 20.3 |
| Native candidate | bridge | Experimental CLI | 91.477 / 104.988 / 106.753 | 10.9 |

The Docker API adapters record removal acknowledgement. The native API
reports removal after verified cleanup. The native bridge has a separate
cleanup state and a private IPv4 topology. None of these workloads send
network packets. Kiri's pinned guest source sends the exit event before
teardown and handles removal without a cleanup reply. The available Docker
adapters leave verified guest cleanup unobserved. At 20 operations, the
nearest-rank p99 is the individual maximum. The probe supplies neither
independent-session uncertainty estimates nor sustained churn.

The raw reports include host CPU-time and RSS snapshots, image identities,
commands, and hashes at
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/common-image`.
Energy capture requires authorized `powermetrics` execution. The host
returned that an administrator password was required.

The experiment identifies a faster typical no-network observation with a
weaker tail and slower bridge observations. The gate remains open while
bridge phase costs and the comparison boundaries are investigated.

[Kiri 0.2.2 guest exit path](https://github.com/libracoder/kiri/blob/686bffa5f38ba6ecc3d086c36ec7148cd7fb976a/crates/kiri-init/src/linux/agent.rs#L1050)
[Kiri 0.2.2 network teardown](https://github.com/libracoder/kiri/blob/686bffa5f38ba6ecc3d086c36ec7148cd7fb976a/crates/kiri-init/src/linux/container.rs#L845)

## Bridge phase attribution

Six separate disposable boots ran 50 measured operations per mode and
lane, with the same workload, guest kernel, host resources and VMM.
The two traced runs showed 18.9–19.0 ms median from helper preparation
to the authorized child and 39.8–41.5 ms from process exit to verified
network removal. Child authorization to exec confirmation took less
than 0.8 ms at the median. The no-network median for exit through final
cleanup was about 0.2 ms.

The four default-kernel runs alternated trace settings in off/on/on/off
order. No-network API p50 ranged from 2.170 to 3.144 ms without tracing
and 2.310 to 2.408 ms with tracing. Bridge API p50 ranged from 63.460
to 67.626 ms without tracing and 63.996 to 68.004 ms with tracing. The
overlapping intervals across this small set do not resolve the cost of
tracing. External latency and guest-local timestamps use separate clocks.

Expedited RCU in the benchmark guest increased bridge API p50 to
101.292 and 104.478 ms, with teardown medians of 67.4 and 63.5 ms.
Both diagnostic sessions completed without correctness failures. VMM
CPU-time deltas were 1.64 and 2.71 seconds, versus 1.49–1.60 seconds
across the four default-kernel sessions, including 40 warmups each.
The diagnostic flag remains opt-in. Commands and raw stage records are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/phase-analysis`.
[Linux kernel RCU parameter documentation](https://docs.kernel.org/admin-guide/kernel-parameters.html)

## Grouped bridge teardown

The bridge and its owned parent veth now use one nonzero group in the
helper's private namespace. One synchronous rtnetlink call removes both
links. Teardown still verifies link and address removal on both sides,
and the acknowledgement still precedes the network-complete state.

Two follow-up boots across 800 measured API and CLI operations passed.
Bridge API p50 fell to 43.689 and 42.222 ms. Median traced network
teardown fell from about 40 ms to 19.616 and 18.775 ms. Median setup
remained about 19 ms. The live DNS/TCP, private scope, fault and
cancellation checks also passed. Production observations matched.
Evidence is under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/grouped-teardown`.
[Linux 6.12 group link deletion](https://github.com/torvalds/linux/blob/v6.12/net/core/rtnetlink.c#L3058-L3090)

## Direct veth placement

The veth peer is now registered in its final namespace using the namespace
descriptor carried in the peer creation message. There is no separate
link move. Startup probes peer creation and teardown before advertising
the bridge capability.

Two further boots ran 100 measurements per mode and lane with the same
ARM64 fixture. Traced bridge setup p50 fell from about 19 ms to 0.382
and 0.309 ms. Bridge API p50/p99 became 20.171/43.929 and 20.333/43.699 ms.
No-network API p50/p99 was 2.009/3.080 and 2.071/7.954 ms. The full live
bridge, cancellation and recovery regressions passed again. These
single-host figures remain preliminary and use the native cleanup-complete
boundary. Raw evidence is under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/direct-peer`.
[Linux 6.12 veth peer creation](https://github.com/torvalds/linux/blob/v6.12/drivers/net/veth.c#L1784-L1830)

## Serial API churn on the M1 Pro

The final code revision tested was `64fe82397bbf302bdb9ad0d23e0cafddb7db41e6`.
All engines used the same ARM64 image artifact, 10 warmups per mode,
the same requested workload limits and two vCPUs with a 2 GiB VM
configuration. Engines ran serially with production Conjet in service.
Across the recorded endpoints, system one-minute load ranged from 4.86
to 6.52. No adapter reported a failed operation in these windows.

| Engine and observed boundary | Network | Samples | p50 / p95 / p99 (ms) | Window (s) | Ops/s |
| --- | --- | ---: | --- | ---: | ---: |
| Native, verified cleanup | none | 2,000 | 2.109 / 3.051 / 4.406 | 4.463 | 448.15 |
| Native, verified cleanup | bridge | 2,000 | 20.196 / 27.845 / 32.315 | 42.352 | 47.22 |
| Kiri, Docker removal acknowledgement | none | 2,000 | 4.521 / 9.935 / 20.773 | 10.777 | 185.58 |
| Kiri, Docker removal acknowledgement | bridge | 2,000 | 33.608 / 53.843 / 63.461 | 68.784 | 29.08 |
| Original Conjet, Docker removal acknowledgement | none | 100 | 394.564 / 478.224 / 602.113 | 40.501 | 2.47 |
| Original Conjet, Docker removal acknowledgement | bridge | 100 | 479.779 / 515.515 / 541.395 | 47.623 | 2.10 |

The native VMM used 15.84 CPU seconds across both windows and their
warmups. Its physical footprint grew from 31.08 to 80.50 MiB. RSS
grew from 100,912 to 715,056 KiB. The balloon report recorded 4.67 GiB
in cumulative backing decommit across repeated free-page reports.
The Kiri VM could only be attributed at the final snapshot, so a paired
VM footprint or CPU delta is unavailable. Energy use and the effect of
memory reclamation on running services require separate qualification.

Kiri's read-only `--pid=host` probe observed its own BusyBox process as
PID 1. It could not verify the guest init's mount, cgroup or veth inventory.
The Docker acknowledgements and native cleanup measurements therefore
retain separate scopes. Commands, raw samples, failures from earlier
probes, topology and resource metadata are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/api-churn`.

## Release gate

Proceed requires a verified equivalent cleanup observation for the
official competitor, a comparison across two supported physical host
configurations with the predeclared sample and session counts, and
authorized energy measurement. Further qualification also needs matched
network scope and sustained concurrency beyond this single-active-workload
fixture. The authorized M1 Pro remains under production load. The
tick-disabled native trial that stalled remains outside the tested
configuration. SPEED-009 through SPEED-014 remain blocked, including
the pull request, merge, signing and publication.

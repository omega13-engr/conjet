# Speed qualification preflight

SPEED-008 retains its unresolved **revise** verdict. The user authorized
an experimental opt-in release on the available M1 Pro on 2026-11-23.
The original comparative program is deferred and the recorded runs remain
historical evidence. [Fresh runtime gate](fresh-runtime-gate.md)

## Required experimental acceptance

Exercise the final product candidate with fresh and prepared workloads,
concurrent requests and bounded admission, cancellation, disconnect and
timeout recovery, expiry, one-use claims, bounded output, memory pressure
and active preservation, and verified cleanup. Verify Docker compatibility
and record production identity and endpoint before/after. Record supported
configuration, commands, commit and hashes, raw latency samples, failures,
CPU, memory, background load, preparation/refill, misses, and throughput.
Required local acceptance precedes the PR. Independent review and CI precede
merge, and production signing and artifact verification precede publication.

## Evidence available

- The fresh one-host runs retain original Conjet, Kiri API removal and
  native verified-cleanup observations separately. Bridge timing
  records the native cleanup work. [Fresh runtime gate](fresh-runtime-gate.md)
- Prepared operation records include preparation, refill, misses,
  claim acknowledgement, observed exec and verified cleanup. The tested
  scope is one no-network slot and one admitted workload. The final
  untraced 200-operation run measured claim-to-exec p50/p99 of
  1.338/2.478 ms. The local tail exceeds the prepared target.
  [SPEED-009](task-board.md#speed-009)
- The native memory experiments include cgroup accounting, authenticated
  pressure and eviction, a constrained Linux balloon boot, live
  allocation and refill, and entitled backing-release tests. The
  simultaneous active-workload and reserve case needs a broader fixture.
  [SPEED-010](task-board.md#speed-010)

## Deferred comparative qualification inputs

1. Access to a second supported physical ARM64 Mac and measurement windows
   on both hosts with background load within the predeclared limits.
   Keep production running. Record the host configuration and load with
   each session.
2. An approved read-only observation path for the official Kiri build
   that can timestamp actual guest cgroup, mount and network teardown for
   the workload under test. Match the bridge topology and packet behavior
   before comparing it with the native bridge.
3. Permission to collect host energy telemetry through `powermetrics` or
   an approved equivalent on both machines. The local noninteractive
   privilege check required administrator authentication.

Collect at least 10,000 operations per microbenchmark scenario across at
least five independent sessions and both hardware configurations. Run
fresh, prepared, CLI, sustained churn, build and running-service scenarios
with their declared endpoints. Include concurrency, pressure, pool
exhaustion and refill, resource consumption, and CPU and energy evidence.
Retain failed trials and calculate the predeclared uncertainty on
independent sessions. Keep the original sub-1 ms prepared p99 and
equivalent-work superiority criteria. Neither claim has passing evidence.
[Verification and claim policy](speed-engineering-plan.md#verification-and-claim-policy)

## Local experimental verdict

The M1 Pro (16 GiB host RAM) passed the scoped native correctness and performance-measurement
matrix using the release-optimized app binaries built from
`ff1877c3b75b73d310179dfebb2684f0f4e6072c`. The packaging increment
`764b39a` distributes the same guest and runtime. Each session used a
separate boot for the safety canary and the timing workload. There were
200 measured operations and 10 warmups per lane per session. All 2,400
measured operations succeeded. Expected misses, admission rejections and
cancellations are recorded separately. Earlier failed development runs
remain in the SPEED-012 evidence directory.

The API used a persistent authenticated connection. Fresh API latency
starts at launch submission and ends at verified cleanup. Prepared API
latency starts at claim and ends at verified cleanup. Preparation is
measured from submission through ready. CLI latency includes process
startup and bounded output collection. Prepared throughput includes a
refill on every iteration. The 25 ms host tick remained enabled.

| Session | Lane | p50 / p95 / p99 (ms) | Throughput (ops/s) |
| --- | --- | ---: | ---: |
| 1 | Fresh API | 1.951 / 3.383 / 7.737 | 434.4 |
| 2 | Fresh API | 1.922 / 2.928 / 7.258 | 430.4 |
| 3 | Fresh API | 1.948 / 4.269 / 7.398 | 423.1 |
| 1 | Prepared API | 1.468 / 2.350 / 3.291 | 324.3 |
| 2 | Prepared API | 1.258 / 1.787 / 2.080 | 409.8 |
| 3 | Prepared API | 1.260 / 1.838 / 2.314 | 397.1 |
| 1 | Fresh CLI | 21.601 / 38.309 / 72.051 | 40.4 |
| 2 | Fresh CLI | 21.130 / 25.547 / 27.778 | 46.0 |
| 3 | Fresh CLI | 20.756 / 24.019 / 27.177 | 47.2 |
| 1 | Prepared CLI | 19.956 / 25.336 / 33.659 | 24.3 |
| 2 | Prepared CLI | 20.679 / 26.305 / 31.144 | 23.4 |
| 3 | Prepared CLI | 20.457 / 25.637 / 28.698 | 23.7 |

API refill p50 was 0.969–1.205 ms and p99 was 1.782–4.216 ms.
CLI refill p50 was 19.668–20.273 ms and p99 was 29.292–33.838 ms.
CLI replay and expiry misses took 17.228–25.029 ms, including spawning
the client. The VMM CPU-time deltas across the four timing lanes and
warmups were 3.83, 3.70 and 3.71 seconds. Sampled VMM RSS at those
window endpoints ranged from 78,320 to 122,416 KiB. Endpoint 1-minute
host load ranged from 6.82 to 16.77 in the timing boots with production
left in service. This experiment reports per-session nearest-rank
percentiles under observed contention.

The active canary held 8 MiB through an explicit pressure request,
checked every page, and then completed. Guest cgroups reported
8,470,528–8,912,896 charged bytes in those observations. Idle prepared
slots were evicted with verified cleanup, creation paused under
pressure, and refill succeeded after the signal was cleared. The six
guests negotiated free-page reporting and reported about 2.1–2.9 GB of
cumulative reclaimed bytes with zero reported reclamation errors.
Cumulative counts include repeated reuse. Concurrent claims had one
winner, the connection ceiling rejected excess admission, and stale
slots, changed operation IDs and unsupported network requests failed
explicitly. Bounded output, private writable roots, timeout and
disconnect cancellation, verified drain, and session-directory removal
passed. The isolated Docker smoke used the separate `conjet-speedup`
context. Production identities, endpoint and configuration observations
matched before and after.

Raw reports, exact commands, software and hardware observations, and
kernel/CLI/VMM/guest/executable digests are retained in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-011/packaged-{1,2,3}`.
The workloads have no network, host shares or Docker lifecycle. The
local verdict supports the [experimental scope](speed-release-scope.md).
Kiri API removal acknowledgement and Conjet verified cleanup remain
separately scoped in the historical [fresh-runtime gate](fresh-runtime-gate.md).


The three independently entitled memory checks also passed on the final
runtime source. The Linux allocation/free/reuse canary ran against the
pinned kernel and observed VMM RSS fall from 136,609,792 to 69,599,232
bytes before successfully reusing guest memory. The two HVF checks
covered partial backing discard and immediate backing release with
uncorrupted guest reuse. Raw reports are under SPEED-011.

The historical 200-sample SPEED-009 trace was recomputed from its
untraced retained sample file. Its host claim-to-exec p50/p99 was
1.338/2.478 ms. That fixture result uses a different endpoint from
the product's claim-through-cleanup distributions.

The later [isolated Docker candidate results](docker-benchmark-results.md#release-build-native-docker-lifecycle)
report five release-build native/Kiri pairs for a pinned, no-network Alpine
workload. They cover Docker acknowledgement and client exit on the M1 Pro.
Kiri guest teardown remains unobservable, and the original SPEED-008
comparative qualification stays unresolved.

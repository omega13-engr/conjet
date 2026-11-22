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

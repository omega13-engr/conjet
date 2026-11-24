# Retained Docker latency architecture

Superseded execution scope: the user now authorizes the [native engine plan](native-engine-v2-plan.md). Retained-engine findings below remain historical evidence.

Status: proposed, not implemented or performance-qualified. Research date:
2026-11-24. Conjet source baseline: `46f2a14` (SPEED-049 results; measured
runtime `84e29ab`). This plan preserves dockerd, containerd, runc, BuildKit,
Compose, and Conjet dynamic memory. It does not restart the Rust Docker
Engine replacement program.

## Decision and honest feasibility

Optimize the retained engine by separating Docker data delivery from routine
memory-maintenance triggers, then removing measured transport stalls. First
measure the guest-local engine floor. Do not promise a 100x gain from relay
changes or describe an architecture proposal as a benchmark win.

SPEED-049 measured API lifecycle boot medians of 419.257–468.607 ms versus
Kiri's 3.739–5.036 ms. Conjet start took 189.529–214.157 ms and wait
217.272–228.704 ms. The full paired API median ratio was 102.9228.
Guest task execution near 2 ms in SPEED-047 excluded runtime setup and
cleanup and used instrumentation; it is not the engine's lifecycle floor.
The CLI had one exit-127 failure and lacks a qualifying five-pair interval.
[Full report](docker-benchmark-results.md#speed-049-retained-docker-release-lifecycle-against-kiri)

Below 5 ms is a stretch target for the warm no-network API lifecycle,
including create, start, wait and removal acknowledgement. It is not a
promise for docker CLI, builds, pulls, bridge networking, or cold boot.
Kiri CLI medians on our host were about 20 ms. Matching Kiri means passing
the existing paired comparison, not merely reaching a round-number target.
If direct guest Docker exceeds 5 ms, removing all transport overhead still
cannot deliver the target under that configuration. Report that result and
identify the engine stage; do not change limits, cleanup boundaries or
replace Docker to turn the result into a pass.

## What Kiri actually does

Research is pinned to Kiri v0.2.2 commit
`686bffa5f38ba6ecc3d086c36ec7148cd7fb976a`, matching the release family
used in SPEED-049. Source inspection is not proof that every source detail
matches the signed binary; retain binary hashes in benchmark evidence.

- The guest launches a child with `clone3` into namespaces and its cgroup.
  Its runtime omits runc and per-container shims. Preparation happens before
  the clone; root readiness and execution errors have explicit signalling.
  This removes process and IPC stages that retained Docker still performs.
  [Pinned container implementation](https://github.com/libracoder/kiri/blob/686bffa5f38ba6ecc3d086c36ec7148cd7fb976a/crates/kiri-init/src/linux/container.rs)
- A guest event loop polls transport, child-exit signals, output and readiness
  descriptors. Exit notification follows output draining. This supports
  prompt completion without inferring completion from periodic polling.
  [Pinned agent implementation](https://github.com/libracoder/kiri/blob/686bffa5f38ba6ecc3d086c36ec7148cd7fb976a/crates/kiri-init/src/linux/agent.rs)
- Its published 2.55 ms API figure is a 30-run warm median on a different
  host/configuration; results.json identifies bridge mode and reports a
  separate no-network figure. It is not our four-PID, 16 MiB, 500-millicore
  five-boot-pair qualification. The repository has different benchmark paths:
  `kiri bench` includes direct engine execution as well as Docker API/CLI
  lanes; its Docker API lane pre-registers an AutoRemove wait. `bench/api.sh`
  instead shells out to curl/jq. Do not equate all those timers or infer the
  exact historical published run from current source alone.
  [Published metadata](https://github.com/libracoder/kiri/blob/686bffa5f38ba6ecc3d086c36ec7148cd7fb976a/bench/results.json),
  [benchmark source](https://github.com/libracoder/kiri/blob/686bffa5f38ba6ecc3d086c36ec7148cd7fb976a/crates/kiri/src/bench.rs),
  [shell benchmark](https://github.com/libracoder/kiri/blob/686bffa5f38ba6ecc3d086c36ec7148cd7fb976a/bench/api.sh).

The transferable principle is event-driven completion and less incidental
work. Copying Kiri's engine would violate this project's retained-stack
scope. No Kiri source is incorporated by this documentation change. The
Conjet-specific design below preserves its memory controller and Docker
compatibility; superiority over Kiri remains unproven.

## Source findings and falsifiable hypotheses

| Boundary | Confirmed in Conjet source | What remains unproven |
| --- | --- | --- |
| Guest HTTP relay | `handle_docker_proxy` connects to dockerd per accepted stream; ordinary complete requests and responses are rewritten to Connection: close; a response pump thread is created and joined | How much connection/thread churn contributes to lifecycle latency |
| Host ingress watcher | `NativeEventQueue::watch` registers EVFILT_READ; SPEED-048 wakes the VM on ingress | Whether write-blocked response flushing waits for fallback polling in this workload |
| Memory scheduling | The boot loop calls `schedule_guest_memory_reclaim` on completed stream phases and completed workload streams; in-flight work is coalesced with a pending flag | Whether reclaim actually executes during measured launches, evicts useful cache, or adds material contention |
| Resource isolation | Four-PID runc diagnostic failed 12/12; eight-PID diagnostic passed 13/13 | Identity/cgroup of the failing qualified CLI process; CPU throttling contribution |

Source anchors: [guest relay](../../guest/image/conjet-core/src/conjet-netd.c)
(`handle_docker_proxy`, `docker_response_pump_thread`),
[VSOCK](../../jetstream/src/devices/vsock.rs) (`NativeEventQueue::watch`,
`poll_host_streams`, `flush_host_output`, `finish_guest_shutdown_if_drained`),
[boot controller](../../jetstream/src/hvf/boot.rs)
(`schedule_guest_memory_reclaim`, `CoreMemoryController`).

## Proposed architecture

```text
Unmodified Docker / Buildx / Compose
                 |
        private conjet-speedup socket
                 |
     Jetstream VSOCK queue owner
      | ingress readiness notification
      | conditional writable notification (if justified)
      | existing 25 ms recovery tick retained
                 |
    conjet-netd bounded HTTP relay
      | explicit message framing / EOF
      | optional connection reuse (separate experiment)
                 |
       dockerd -> containerd -> runc -> workload
                 |
        actual exit / output / removal response
                 +-----------------------> client

Conjet dynamic memory -- separate control path, same VM
  pressure / guest telemetry ------> existing pressure policy
  Docker activity ----------------> activity generation
  completed HTTP stream ----------> pending maintenance hint
  quiet dwell + guest safety probe -> scoped routine reclaim
  balloon-owned / reported pages --> host backing release
```

An HTTP connection ending is a transport fact, not proof that container
memory is idle. Preserve existing workload classification and guest memory
probes; never free backing based on socket closure. Long-lived events or
idle keep-alive sockets must not pin the VM's peak memory allocation.

### 1. Establish the floor before optimizing

Extend SPEED-050 with a guest-local runner against `/var/run/docker.sock`.
Use the same image, four API operations, limits and removal boundary as the
host harness. Import the shared workload definition; validate output and
exit status. Run local and forwarded lanes serially, with release binaries,
four warmups and 12 timed operations per diagnostic boot, two untraced and
two traced boots. Timing rows must identify lane and observer configuration.
Add guest-local and forwarded `_ping` controls; these diagnose transport,
not container speed. Do not run the lanes concurrently.

Trace guest receipt, completed request delivery, first response byte and
complete response; host ingress, ring publication, response receive, final
client write and shutdown. Use a correlation ID and clock-local durations.
Do not subtract host timestamps from guest timestamps or subtract unrelated
medians as if they were a per-request transport measurement. Capture guest
cpu.stat/pids.events deltas, runtime process cgroups, reclaim request counts,
reclaim completions and memory targets. If guest-local is slow, split
containerd task creation, runc setup, task execution, exit and deletion
before selecting a runtime change. No Go-versus-Rust causal claim.

### 2. Make routine reclaim follow activity, not every stream close

SPEED-052 is a bounded A/B experiment in the existing boot controller.
Compare current scheduling with stream completions setting one pending
routine-maintenance hint. Submit that hint only after the existing quiet
dwell and guest safety checks; use a generation counter so new classified
work invalidates stale routine submissions before they start. Reuse the
existing cancellation/epoch contract only after verifying its actual scope.
Already-running reclaim may finish; do not claim cancellation is synchronous.

Keep the current pressure path, balloon targets, growth/resume behavior,
page-reporting ownership checks, service reclamation and idle convergence.
Do not suppress pressure reclaim, pin a fixed RAM allocation, globally drop
caches, or add a permanent prewarm process. Missing telemetry uses the
existing conservative policy. No new infinite cache-retention mode.

A successful experiment must show reduced routine requests during a burst,
subsequent idle reclaim, pressure response while the burst is active, and
unchanged live-container data. Measure launch latency and memory together.
If timing does not improve or memory regresses, retain the current policy
and record a rejected experiment. Source coupling alone is not causality.

### 3. Complete response readiness only where traces justify it

SPEED-053 targets `flush_host_output` after WouldBlock. If SPEED-050 observes
this stall, arm write readiness only while output is pending; notify the
existing queue owner, flush in order, then disarm once drained. Keep byte
ownership in the queue owner and remove registrations before descriptor
reuse. If no such stall is present, close the investigation with evidence
and do not add an always-writable watcher. Preserve credit updates,
half-close ordering, final output and EOF. Keep the 25 ms recovery tick.

### 4. Test connection reuse separately

SPEED-054 first measures fresh versus reused connections locally and through
the relay. Implement persistent ordinary HTTP only if connection churn is
material after earlier changes. Keep one upstream connection per downstream
connection; no shared multiplexing or response cache. Parse every request
before applying the existing create/build CgroupParent policy. Respect
Content-Length, chunked framing, informational responses, HEAD/no-body
responses, client close and bounded buffering. Handle upgrades/attach,
events, logs and build streams separately without delaying their bytes.
Do not merely remove Connection: close: the existing relay handles a single
ordinary transaction, and its lifecycle/memory accounting must be updated
before connection reuse is safe. Do not change the frozen benchmark client
to manufacture a gain; report optional persistent-client diagnostics apart.

## Dynamic memory acceptance is mandatory

Before accepting any candidate, compare the same initial memory target and
workload against the retained baseline on isolated boots:

1. Run 200 warm launches; record latency, reclaim counts, balloon targets,
   attributable host footprint and guest available memory over time.
2. Keep the existing active data-canary workload alive during churn and
   pressure. Verify every byte and workload exit/cleanup, not just RSS.
3. Apply the existing bounded pressure fixture during churn. Show that
   pressure handling still operates and foreground work makes progress;
   never raise fixture limits or disable ballooning to obtain a speed pass.
4. After churn stops, observe the existing configured idle-convergence
   deadline and target. Record time-to-target versus baseline. Extra held
   memory, missed deadlines, OOMs, stalls or corruption reject the candidate.
5. Re-run balloon backing-ownership/release tests. Only balloon-owned or
   page-reported ranges may release host backing; no reclaim of active pages.

Diagnostic configurations must be printed in the report. Timed final runs
use normal dynamic memory, not a benchmark-only fixed-memory configuration.

## Sequence, qualification and stop rules

SPEED-051 fixes the existing correctness blocker. SPEED-050 establishes the
latency floor and attribution. Then evaluate SPEED-052, SPEED-053 and
SPEED-054 in order, one variable at a time. A rejected experiment can finish
as a documented decision without merging its candidate code. It cannot be
recorded as a performance improvement. SPEED-055 freezes only accepted
changes and repeats the existing five alternating boot pairs, 2,000 timed
operations and ten warmups per engine/lane/boot. Keep failures in the record.

Preserve the detailed report format: versions/hashes, per-boot p50/p95/p99,
throughput, stage timings, paired ratios and 95% intervals, correctness,
resources, cleanup, coverage and explicit verdict. CLI parity still requires
both p50 and p99 upper ratio endpoints <= 1.05. Add a separately labelled API parity assessment with the same 1.05
upper-bound rule for both percentiles; retain API superiority separately; do not loosen the
existing advantage criterion. Report <5 ms as its own descriptive target,
not a substitute for paired inference or a p99 guarantee.

Retest the affected bridge, exec/output, image, storage, build and Compose
fixtures from SPEED-020–025. Historical results do not qualify the new
candidate. Run full workload comparison via the existing matrix after the
lifecycle/correctness gate; do not extrapolate a launch win to build speed.
Second-host, energy and equivalent guest teardown gaps stay disclosed.

Use only private `conjet-speedup` endpoints and ExternalSSD scratch. Preserve
production identities, endpoints, contexts and Buildx selector. No installed
services, background registrations, merge or release in this design step.
All implementation increments retain rollback to the current retained stack.

## This revision's evidence

Reviewed Conjet source and SPEED-049 artifacts documented in the report;
read the pinned Kiri source and benchmark metadata above. This revision
changes architecture/task documentation only. No runtime optimization or
new speed measurement has been performed. No claim of matching or beating
Kiri is supported by this revision.

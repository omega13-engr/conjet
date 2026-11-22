# Conjet speed engineering plan

Status: proposed architecture; implementation and performance qualification pending.

Created: 2026-11-22. Execution tracking: [task board](task-board.md).

Development branch: `enhancement/speed-up`. Validate, review, commit, and push
each coherent increment. Open a PR to `main` only when all development tasks
and required final benchmarks are complete and passed; release the next Conjet
version after merge and release validation. The task board records these gates
as SPEED-013 and SPEED-014.

## Objective and honest feasibility

Make Conjet faster for real development workloads while preserving isolation,
Docker compatibility, dynamic memory correctness, and energy efficiency.
Investigate sub-1 ms prepared launches without promising that result for fresh
containers, cold VM boots, or complete Docker CLI invocations.

| Operation | Feasibility assessment |
|---|---|
| Cold VM boot including Linux startup | Not a defensible sub-1 ms target |
| New Docker CLI process through container completion | Not a credible initial sub-1 ms target |
| Fresh container lifecycle through a resident API | Aggressive research target; unproven |
| Prepared container through confirmed application execution | Plausible sub-1 ms research target; unproven |
| Application response | Depends on application initialization and work |

Kiri reports a 2.55 ms median Alpine `true` lifecycle through its Docker API.
That is an author-reported result, not a Conjet measurement or an independently
reproduced baseline. A prepared Conjet launch is not equivalent to that fresh
lifecycle. Pin competitor versions and rerun equivalent workloads before making
competitive claims. See [Kiri's recorded results][kiri-results].

macOS scheduling prevents a hard sub-1 ms guarantee under arbitrary host load.
The outcome may be a useful improvement that does not meet the research target.

## Existing foundations and gaps

- [Jetstream](../../jetstream/src/) provides the Rust HVF VMM, devices, VSOCK,
  and memory reclamation.
- [DockerRunExecutor](../../Sources/ConjetVZ/DockerRunExecutor.swift) invokes the
  Docker CLI for its run surface; accelerating the VMM alone does not remove
  Docker/containerd or CLI overhead.
- [Direct OCI loading](../../Sources/ConjetCore/ConjetContainerRuntime.swift)
  and [guest init](../../guest/init/conjet-init.c) provide a limited direct-launch
  substrate, not a reusable production container supervisor.
- The current init reports `PROCESS_STARTED` after `fork()` without confirming
  successful `execve()`. This event cannot prove application execution.
- [Startup tracing](../../Sources/ConjetCore/StartupTimeline.swift) and the
  [benchmark methodology](../benchmark-methodology.md) supply an existing evidence
  framework to extend rather than replace.

These observations describe the source inspected during planning, not installed
runtime qualification. Preserve the existing Docker lane throughout development.

## Isolated speedup environment

SPEED-000 is a mandatory prerequisite for every runtime test. Deliver a
session-scoped environment launcher and runbook using the enhancement branch's
own Conjet CLI, conjetd, and Core VMM executables. Do not use or replace installed
production binaries. The launcher owns child processes and cleans them up on
normal exit, cancellation, or failure; no launchd registration or detached helper.

```text
Production (untouched)                Speedup QA session
Installed Conjet / conjetd / Core     Branch-built Conjet / conjetd / Core
Existing home, disks and sockets     Separate home, disks, locks and sockets
Existing Docker context             Docker context: conjet-speedup
Existing Docker configuration        Private Docker configuration directory
                                     |
                                     +-- benchmark adapter: candidate
                                     +-- benchmark adapter: pinned Kiri
```

Use these explicit environment bindings in every candidate child process:

- `CONJET_HOME`: a task-owned directory under the external SSD QA root.
- `CONJET_PROFILE=speedup`: current CLI naming produces `conjet-speedup`.
- `DOCKER_CONFIG`: a private QA directory; never the user's Docker configuration.
- `CONJET_DISABLE_BACKGROUND_SERVICE_REGISTRATION=1` and
  `CONJET_DISABLE_MENU_BAR_APP=1`.
- Resolve executable overrides to staged branch-built binaries and verify actual
  process executable paths; do not allow installed-binary fallback.

The CLI currently configures its Docker context with `makeCurrent: true`.
A private DOCKER_CONFIG is therefore required even with a separate CONJET_HOME.
Do not call `docker context use` against the user's configuration or persist QA
runtime bindings into the production app's runtime-environment.json.

The runbook must provide a wrapper that always passes the private Docker config
and `--context conjet-speedup`, with conflicting DOCKER_HOST/DOCKER_CONTEXT
removed from its child environment. Derive socket paths from ConjetPaths or the
runtime manifest: long paths can resolve to hashed directories under /tmp.
Inventory and clean only those task-owned paths.

Use fresh mutable root/data disks and volumes. Verified immutable boot assets
may be copied or shared read-only. Never attach production mutable disks, mount
production databases, import secrets, or run global Docker pruning. Reserve
nonconflicting loopback ports and network ranges; fail on collisions rather than
stopping another process. Do not change global DNS, Docker socket symlinks, app
registration, production contexts, or default builders.

Before launch and after shutdown, record production process identities, context
endpoint/current-context selection, and a read-only health observation. Verify
candidate PIDs, executable paths, VM identity, sockets, and disks are distinct.
Run a harmless fixture through the private conjet-speedup context to prove routing.
If isolation cannot be demonstrated, stop the QA processes and fail the setup.

Pin Kiri's binary/image versions. The user accepted its official settings under
~/.kiri and official host shares provided test data stays on ExternalSSD and
production Docker configuration remains unchanged. Use the session-scoped
[official Kiri launcher](speedup-environment.md) with private Docker configuration
and the explicit kiri-speedup endpoint. This is data/context separation, not full
host filesystem confinement. Do not assume Kiri supports CONJET_HOME.
The benchmark runner must accept explicit candidate and Kiri endpoints and
validate their identities before each run.

Production remains running. Alternate candidate and Kiri measurement windows,
stop only task-owned competitor instances, and report production/background load.
Logical isolation cannot eliminate shared CPU, memory, thermal, and disk
contention. Clean performance qualification requires a dedicated host or an
explicitly authorized quiet window; a contaminated run cannot pass the final gate.

## Architecture and ownership

```text
HOST
+-----------------------+       +-----------------------------+
| App / CLI / resident  |------>| conjetd                     |
| API client            |       | lifecycle + admission       |
+-----------------------+       +--------------+--------------+
                                               |
                              authenticated, bounded requests
                                               |
+----------------------------------------------v--------------+
| Jetstream Rust VMM                                          |
| HVF | virtio devices | persistent VSOCK transport            |
| Existing memory ownership and backing-release machinery     |
+----------------------------------------------+--------------+
                                               |
GUEST                                          |
+----------------------------------------------v--------------+
| Rust launch service                                         |
| validation | process supervision | resource accounting       |
|                                                             |
| +--------------------------+ +----------------------------+  |
| | Fresh launch             | | Prepared launch            |  |
| | Create isolation now     | | Consume one ready slot     |  |
| +--------------------------+ +----------------------------+  |
+-------------------------------------------------------------+

Existing Docker/containerd lane remains available.
Every container has exactly one lifecycle owner.
```

Initially expose the new service through a distinct native Conjet API. Do not
silently route Docker requests between independent engines. Listing, events,
volumes, logs, restart policies, and deletion must all address the same owner.
Reject unsupported options explicitly before creating resources.

Keep guest supervision and filesystem work outside VMM device-processing locks.
Use persistent VSOCK first. Introduce shared-memory transport only if measured
transport cost justifies its additional ownership and synchronization complexity.
Do not use permanent busy polling to obtain a latency result.

The Rust supervisor owns child lifetime, pidfd-based process tracking where
supported, bounded output, cancellation, and teardown. Use a single-threaded
fork/clone execution helper or another explicitly verified child-creation model;
do not perform allocating Rust work after fork from a multithreaded process.
Define crash recovery and disconnection behavior before exposing the service.

## Fresh launch lane

```text
Request accepted
      |
Validate specification and allocate identity
      |
Prepare private rootfs, cgroup and namespaces
      |
clone3 + CLONE_INTO_CGROUP
      |
Apply credentials, capabilities, limits and seccomp
      |
exec application
      |
Confirm exec / observe application readiness separately
      |
Observe exit -> finish cleanup -> acknowledge removal
```

Use direct Linux syscalls rather than launching a separate runtime executable
per operation. `clone3` supports namespace creation and cgroup placement, but
does not imply any latency guarantee; see [the Linux documentation][clone].

Keep unpacked image layers on Linux-native storage. Cache immutable metadata,
not mutable execution state. Start with a restricted, documented native ARM64,
no-network workload. Add private bridge networking as a separately tested stage.
Neither mode may omit security or resource limits merely to meet a benchmark.

## Prepared launch lane

A ready slot is a private environment prepared for an immutable launch
specification. Its container init waits before executing any application code.

```text
EXPLICIT PREPARATION                       TIMED LAUNCH

Resolve image digest                       Receive request
Validate immutable specification                 |
Create private writable rootfs                   v
Create namespaces and cgroup               Validate handle + generation
Prepare private network resources                |
Create waiting container init                    v
Prefault selected executable pages         Atomically claim ready slot
              |                                  |
              v                                  v
          READY SLOT ---------------------> Release waiting init
                                                 |
                                                 v
                                            exec application
                                                 |
                                                 v
                                      Confirm exec / report readiness
```

Bind preparation to image digest, command, environment, user, mounts, resource
limits, security policy, and network configuration. Changed specifications or
invalidated mount/image state require preparation again. Authenticate ownership
of handles and reject expired or stale generations.

Each slot is one-use. Never recycle a slot after application code has executed.
Share immutable image data only; mutable roots, identities, and network state
remain private. Do not snapshot initialized applications with credentials or
live network connections as a shortcut.

Bound slot count, memory, preparation concurrency, queue size, and lifetime.
Require explicit preparation or an explicitly enabled bounded policy; do not
register startup jobs or create a persistent prewarming helper. Replenishment
must be charged to CPU, memory, and throughput results.

Record preparation time, hit rate, misses, expiry, eviction, and refill cost.
A pool miss may take the fresh path only before execution and with explicit
reporting. Never retry an ambiguously started process as a new execution;
request IDs and lifecycle state must prevent duplicate side effects.

## Experimental latency budget

Assumptions: resident VM and client connection, native ARM64, prepared slot,
known specification, and warm executable pages. CLI startup is excluded and
measured separately. These are investigation allowances, not predictions.

| Component | Allowance |
|---|---:|
| Host admission and lookup | 100 microseconds |
| Host-to-guest delivery | 150 microseconds |
| Slot claim and wakeup | 100 microseconds |
| Final restrictions, exec and confirmation | 350 microseconds |
| Guest-to-host acknowledgment | 100 microseconds |
| Scheduling margin | 200 microseconds |
| Total research budget | 1,000 microseconds |

Do not change timing boundaries to obtain a passing result. If execution or
scheduling exceeds the budget, revise the target or stop the experiment.

## Dynamic memory integration

```text
                     Memory admission
                            |
             +--------------+--------------+
             |                             |
       Active workload                Prepared slots
       protected demand               bounded reserve
             |                             |
             +--------------+--------------+
                            |
                    Host / guest pressure
                            |
                   Evict unused ready slots
                            |
                   Linux releases resources
                            |
                Balloon / free-page reporting
                            |
              Jetstream releases owned backing
```

Account for the new runtime and prepared slots in guest cgroups and telemetry
before runtime qualification. Otherwise the controller could mistake active
work for idle capacity. Preserve [controller safeguards](../dynamic-memory-debugging.md)
and [host-backing release guarantees](../jetstream-host-backing-reclaim.md).

Destroy unused slots before pressuring active workloads. Reclaim host backing
only after the existing guest-to-host ownership transition. Do not reserve full
configured capacity merely to keep slots ready. Report idle footprint with and
without slots and measure launch latency after pressure-driven eviction.

## Measurement contract

Extend existing tracing with distinct execution events rather than overloading
the VM startup timeline:

```text
REQUEST_SENT -> REQUEST_ACCEPTED -> RESOURCES_READY -> CHILD_CREATED
     -> EXEC_CONFIRMED -> APPLICATION_READY -> EXIT_OBSERVED
     -> CLEANUP_COMPLETE -> RESPONSE_RECEIVED
```

Each result declares its endpoint. Exec confirmation is not application
readiness or proof of the first application instruction. Use an instrumented
application for readiness; use a trustworthy exec observation and explicit
exec-failure reporting for process-start measurements.

Measure end-to-end intervals with a host monotonic clock. Guest-local timestamps
explain guest stages; do not subtract unsynchronized host and guest clocks.
Measure and report instrumentation overhead.

Keep these lanes separate:

1. Fresh API lifecycle, including complete cleanup.
2. Prepared launch, with preparation and misses reported separately.
3. CLI end-to-end invocation.
4. Sustained churn including cleanup and slot replenishment.
5. Real builds and running-service latency during reclaim.

Also record API-visible removal independently from cleanup completion for fair
comparison with Kiri's lifecycle boundary. Its guest sends exit before teardown,
and network cleanup can be deferred; inspect the pinned [exit path][kiri-agent]
and [network path][kiri-net]. Do not attribute the full reported performance gap
to those differences without profiling.

## Incremental delivery and decision gates

Follow the implementation dependencies in [the task board](task-board.md):

0. Prove the isolated conjet-speedup environment and competitor routing.
1. Correct tracing and establish equivalent baselines.
2. Specify lifecycle, ownership, protocol, recovery, and runtime support.
3. Implement isolated transport and a narrow fresh runtime.
4. Qualify fresh execution, security boundaries, and cleanup before adding speed features.
5. Add and validate fresh bridge networking; measure the first competitive gate.
6. Implement bounded, one-use preparation.
7. Integrate memory pressure, eviction, and resource accounting.
8. Tune measured bottlenecks and run competitive qualification.
9. Integrate qualified native product surfaces; gate Docker compatibility separately.

The reviewed fresh implementation through SPEED-007 is the development
prerequisite for experimental SPEED-009. SPEED-010 builds on the prepared
implementation from SPEED-009. Both may develop, test and collect local
evidence in isolated fixtures while SPEED-008 remains open. Keep those
results tied to their experimental scope and revision.

SPEED-008 remains required for final qualification. Completing an experimental
implementation leaves every outstanding qualification requirement in force.
SPEED-011 must pass the applicable qualification gates before SPEED-012
exposes product surfaces. All required gates must pass before the final PR,
merge, release or a superiority claim. A revise or stop verdict remains
valid evidence and leaves the affected qualification gate open.

## Verification and claim policy

- Run at least 10,000 measured operations per microbenchmark scenario across
  at least five independent sessions and two supported hardware configurations.
  Report warmups, raw samples, failures, p50/p95/p99, throughput, and run-to-run
  variation. Use enough independent samples and confidence intervals for the
  claimed percentile; do not claim p99.9 from these minimums alone.
- Pin code, binaries, images, guest kernels, CPUs, RAM, network mode, storage
  topology, and runtime settings. Alternate engine order and run engines in
  isolation. Match cache/preparation state and completion boundaries.
- Exercise no-network and bridge modes, concurrency, long-running churn, host
  contention, pressure, pool exhaustion, cancellation, exec failure, disconnects,
  and daemon/guest recovery. Include data and isolation canaries.
- Include representative builds and services. Collect energy and CPU evidence;
  lower latency alone does not establish better energy efficiency.
- A prepared-launch sub-1 ms claim requires p99 below 1 ms in every qualifying
  session for the declared configuration, with uncertainty reported and no
  correctness failures. This is a measured operating envelope, not a hard deadline.
- A fresh-lifecycle superiority claim requires equivalent fresh work, both
  API-visible and cleanup-complete results, repeatable p50/p99 gains, and
  sustainable throughput without unbounded deferred work. Predeclare the
  required margin and statistical method before running the comparison.
- Never describe a prepared-only win as a fresh Docker lifecycle win. Never
  generalize a microbenchmark win to builds, application throughput, or memory.

Use the project benchmark package; production binaries must not contain
benchmark commands. Follow [benchmark evidence conventions](../benchmark-methodology.md)
and retain selected raw JSON and reports under `benchmarks/reports/`.

Use isolated `CONJET_HOME`, sockets, ports, and disposable disks. Follow applicable
workspace artifact rules: temporary builds, tests, and scripts belong under
`/Volumes/ExternalSSD/dev_workspace/tmp`; repository QA also requires `/tmp`
QA roots. Where a tool needs `/tmp`, use a task-owned QA root there backed by
the designated external scratch directory when supported, and document paths.
Keep all generated outputs in those roots rather than default global caches.
Never interrupt the installed runtime. Capture screenshots for affected UI or
runtime-status surfaces; explain when a low-level change has no screenshot target.
Stop temporary processes and remove scratch resources after retaining evidence.

## Final recommendation

Proceed with a gated Rust launch-service experiment on Jetstream. Sub-1 ms
prepared execution is plausible enough to investigate. Sub-1 ms fresh lifecycle
and reliable superiority over Kiri remain unproven. Preserve Docker compatibility
and dynamic memory, and ship only the behavior supported by reproducible evidence.

[kiri-results]: https://github.com/libracoder/kiri/blob/0de1837588eed54c945890f955ef861f2da71cc4/bench/results.json
[kiri-agent]: https://github.com/libracoder/kiri/blob/0de1837588eed54c945890f955ef861f2da71cc4/crates/kiri-init/src/linux/agent.rs
[kiri-net]: https://github.com/libracoder/kiri/blob/0de1837588eed54c945890f955ef861f2da71cc4/crates/kiri-init/src/linux/net.rs
[clone]: https://man7.org/linux/man-pages/man2/clone.2.html

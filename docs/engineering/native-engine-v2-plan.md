# Conjet native engine: implementation mandate

Status: authorized implementation direction; no new parity or superiority claim.
The user explicitly reversed the retained dockerd/containerd/runc constraint.
This plan supersedes that constraint in earlier plans and worker prompts.
Production migration is still gated; the isolated candidate uses the new engine.
Conjet Core dynamic memory is mandatory throughout development and timing.

## Scope and measurable goal

Build on Conjet's existing Rust Docker owner and authenticated native guest
runtime. Do not discard verified SPEED-027–036 work or relabel it production
ready. Re-run its acceptance on current release binaries. The unfinished
volume checkpoint c60304f is evidence, not a patch to cherry-pick wholesale.

The candidate executes containers without dockerd, containerd or runc.
Unmodified Docker clients and Compose continue using the Docker HTTP API.
Build support is a separate integration milestone: evaluate BuildKit's OCI
worker with a compatible Conjet executor; do not silently fall back to a
containerd or runc worker and claim the new engine executed the build. Do
not write a Dockerfile/build-cache engine from scratch in this iteration.
Unsupported calls return explicit capability errors before side effects.

Initial performance gates retain the existing matched warm Alpine lifecycle
and CLI fixtures, effective limits, cleanup boundary and five paired boots.
API parity and CLI parity require the declared upper paired 95% ratio bound
<= 1.05 for p50 and p99. Report API advantage under its existing stricter
criterion separately. A below-5-ms API median is a separate target, not proof
of superiority, tail latency, CLI speed or general workload compatibility.
Kiri remains the pinned official comparison binary. No target is guaranteed.

## Why this differs from the retained path

Kiri uses a direct guest launch agent and avoids the Docker runtime chain;
its pinned source and benchmark limits are recorded in the
[research](retained-docker-latency-architecture.md#what-kiri-actually-does).
Adopt the architectural principle, not source copied or cosmetically rewritten
from Kiri. Reuse Conjet's own implementation and normal Linux interfaces.
If external code is later proposed, review provenance/license before inclusion.

The proposed Conjet distinction is explicit resource ownership tied to its
existing dynamic-memory controller, plus bounded lifecycle recovery and
observable cleanup. These are design requirements, not claims that Kiri
lacks them. Different syntax alone is not an engineering improvement.

## Concrete component boundaries

```text
Docker CLI / Compose / Buildx
              |
   Rust Docker API owner (host)
   IDs, names, request validation, Docker semantics
              |
   bounded authenticated session, boot generation + request IDs
              |
   guest supervisor / launch authority
   namespaces + cgroups + immutable image root + private writable root
              |
    direct clone3 -> root/credentials/seccomp setup -> execve
              |
   exit event + output drain + resource cleanup witness
              |
   terminal state -> wait / logs / inspect / removal response

Guest cgroup telemetry + pressure -------------------+
Lifecycle resource ownership -----------------------+-> Core memory policy
Prepared/cache ownership (if enabled later) ---------+        |
                                                     balloon/page reporting
                                                             |
                                                  owned host backing release
```

Host: extend `jetstream/src/native/docker.rs` and its `http`, `request`,
`image`, `registry`, `exec`, `network` and `port` modules. Keep HTTP parsing
and Docker JSON translation at the edge. Internal state uses typed IDs,
request/result enums and explicit transitions; do not broadly refactor
unrelated code just to make it stylistically uniform.

Guest: reuse `guest/launch-service/src/{server,fresh_fixture,oci,cgroups,
security,output,memory,wire}.rs`. Inspect actual responsibilities before
moving code. One launch authority owns PID, namespace, cgroup, mount and
output handles. Never execute an allocator/lock-using post-clone child from
a multithreaded Rust process without a justified safe launch boundary. Use
an isolated single-threaded launch broker if the current server's threading
requires it; prepare child inputs before clone and confine unsafe syscalls
to small audited wrappers. Async HTTP workers do not fork themselves.

Maintain the existing authenticated wire contract unless a versioned change
is necessary. Use finite admission queues and output budgets; refuse overload
explicitly. Persistent event delivery may replace measured polling, but do
not claim lower latency by acknowledging start before the documented readiness
boundary or remove before the selected cleanup boundary. Preserve stdout,
stderr, exit status, backpressure, half-close and cancellation semantics.

```text
Created -> Starting -> Running -> Exited -> Cleaning -> Removed
                |          |          |          |
                +----------+----------+----------+-> Failed/NeedsReconcile
```

Record a monotonically increasing generation for reused slots/handles. A lost
start reply must not launch twice. An unknown backend disposition blocks unsafe
reuse until reconciliation. Start/stop/restart must create the expected fresh
process state; do not substitute a paused precreated process for fresh execution.
Durable metadata and crash recovery must be qualified before persistence is
advertised. Disconnecting a client alone does not prove the workload exited.

## Dynamic memory is part of the engine contract

Preserve the actual Core controller, pressure policy, cgroup telemetry,
conjet-memd/reclaimd behavior where applicable, virtio balloon and page-reporting
ownership ledger. Audit the native guest path: exposing a `memory` RPC or
passing a prepared-slot eviction test does not establish full Core parity.
The native path must supply the controller's real inputs and obey its actions.

- Workload IDs map to cgroups and owned resources; active memory cannot be
  released based solely on Docker socket closure or a cached host state.
- Routine cache/prepared-resource eviction is distinct from active-container
  memory. Core pressure handling remains effective during sustained launches.
- Preserve growth from a reduced target, shrink after idle, allocation data
  integrity and recovery under pressure. Start the growth fixture below maximum
  capacity; earlier full-capacity tests did not prove growth.
- Host backing release remains limited to balloon-owned/page-reported ranges.
  No fixed-RAM performance configuration, globally disabled reclaim, or pinned
  permanent pool. Keep the 25 ms safety tick until its known stall is resolved.
- Prepared launch remains separately labelled research until normal fresh
  lifecycle, refill/expiry/cancellation and pressure behavior are qualified.

Run the same memory canary during launch churn; verify bytes, pressure-induced
growth, target convergence and actual backing release, not only RSS snapshots.
Record initial/maximum memory, policy deadlines, telemetry, targets, failures
and cleanup. Unverified growth is a blocking result for native promotion.

## Incremental delivery

SPEED-057 audits current native capabilities and proves the isolated candidate
has no hidden retained-engine fallback. SPEED-058 integrates/proves Core dynamic
memory on that native path. SPEED-059 freezes a new native lifecycle baseline.
SPEED-060 implements one measured lifecycle bottleneck with typed, bounded
ownership and a regression test. Repeat with a new narrow task if needed;
never change benchmark semantics to obtain a pass.

Then SPEED-061 resolves private volume filesystem recovery, SPEED-062 adds
container volume ownership, SPEED-063 integrates a minimal BuildKit execution
contract, SPEED-064 qualifies a concrete Compose fixture, and SPEED-065 freezes
comparative qualification. Split a task before coding if discovery reveals
multiple independently reviewable changes; preserve the stated acceptance.
Earlier superseded tasks remain historical; do not mark them completed by
association. Retained-engine SPEED-051/055 are historical failures, not native
implementation gates. Re-run equivalent correctness tests on the new engine.

Every increment: release build where timing matters, focused tests, applicable
Rust format/Clippy, regression and cleanup checks, evidence, diff review,
conventional commit and verified push to enhancement/speed-up. Use the existing
PR #33 and update its scope honestly. Keep unsupported features visible in a
capability table. Passing a small fixture is not full Docker compatibility.

All private disks, scratch, builds and evidence stay on ExternalSSD. Do not
interrupt installed production, change its endpoint/context/Buildx selection,
register persistent services or migrate user data. Independent review, complete
candidate compatibility, memory gates, CI and release signing/notarization
remain necessary before promotion. Second-host/energy/guest-cleanup comparison
limitations stay explicit. A slower or failed result stays in the report.

## Evidence at authorization

Current code baseline: 7dd2a95. Native research already includes OCI/image,
eight-container, exec/output, bridge DNS and loopback-port fixtures, with
restricted semantics. Retained-engine work has not achieved parity. This
plan changes scope and task ownership, not measured performance. The next
worker must execute native validation rather than continue retained-engine
slice experiments or infer current results from historical native timings.

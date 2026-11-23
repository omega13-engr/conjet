# Conjet speed engineering task board

Architecture: [speed engineering plan](speed-engineering-plan.md).

## Working rules

- Each task must deliver the artifact or behavior named in Description. Complete
  Approach steps in order and record commands, results, and artifact paths in Evidence.
- Follow implementation dependencies; move a task between sections as its status changes.
- Start implementation when its development prerequisites are DONE with review evidence. Each implementation
  task includes focused automated checks, diff review, and resource cleanup.
- Evidence is pending until actual commands, results, revisions, configurations,
  and artifact links are recorded. Targets are not benchmark results.
- UNDERREVIEW requires an implementation and verification evidence; DONE requires
  acceptance criteria and review to pass. Record blockers and failed experiments.
- On 2026-11-23 the user authorized an opt-in M1 Pro experimental release.
  SPEED-008 remains unresolved and deferred with its revise verdict. SPEED-011
  tracks local acceptance and carries the original comparative research criteria.
  SPEED-009 and SPEED-010 DONE evidence covers the isolated implementation only.
- Preserve the installed runtime and unrelated changes. Use isolated QA resources,
  designated temporary artifact locations, and screenshot evidence where applicable,
  as described in the plan. No persistent prewarming services or startup jobs.

## Branch, increment, PR, and release workflow

- Implementation branch: `enhancement/speed-up`. PR base: `main`.
- Complete one coherent increment at a time. Run its applicable checks, review
  the diff, update this board and evidence, then commit with a conventional
  message containing the task ID and push to `origin/enhancement/speed-up`.
- Record implementation commit IDs and verification artifacts in each task's
  Evidence field. Verify the pushed remote head before starting the next increment.
  Use ordinary pushes; do not force-push or include unrelated working-tree files.
- A failing increment stays INPROGRESS or UNDERREVIEW until fixed. Never mark it
  DONE or claim a passing benchmark because its code was committed or pushed.
- Open the PR to `main` only after audited development, local experimental
  acceptance, Docker compatibility, and final candidate measurement evidence
  pass. Preserve unresolved comparative research under SPEED-008 and SPEED-011.
- Prepare the release only after that gate. Choose the next semantic version
  from the final change scope and current release state; do not bump VERSION or
  publish a release tag during intermediate increments.
- Merge only after PR review and required CI pass. Release from the merged main
  revision after packaging validation, following [release.md](../release.md) and
  [homebrew.md](../homebrew.md). Revalidate affected evidence after merge changes.
- The app and guest Core have separate version lanes. Determine whether the new
  guest service requires a Core release, verify asset compatibility, and order
  those releases accordingly. Production signing, notarization, stapling, final
  DMG checksums, and Homebrew validation remain release gates.

## Release scope audit

| Tasks | Retained result and use in this release |
| --- | --- |
| SPEED-000 | Session-scoped launchers and private endpoints. Candidate Docker isolation was rerun with final source; production observations matched. |
| SPEED-001, SPEED-002 | Distinct exec, readiness, removal and cleanup observations, with the pinned baseline retained. Docker acknowledgement and native verified cleanup use separate boundaries. |
| SPEED-003, SPEED-004 | Bounded authenticated protocol, single-owner contract, v1 framing and generation checks. The product capability adds Inspect and unique operation IDs. |
| SPEED-005, SPEED-006 | Restricted Linux execution path, explicit failure and recovery. Final product canaries reran isolation, output, cancellation, teardown and recovery checks. |
| SPEED-007 | Private bridge fixture retained for research. The product explicitly rejects bridge and removes the guest network device. |
| SPEED-008 | Original revise verdict recorded and unresolved. Comparative requirements deferred. |
| SPEED-009, SPEED-010 | One-slot fixture and backing-ownership evidence retained. SPEED-012 integrates the relevant semantics with the product session. |

## Docker and native benchmark extension

SPEED-015 through SPEED-026 form a new sequential benchmark program requested
by the user. They do not mark SPEED-008 passed or change the previously authorized
experimental release gate. SPEED-015 can start without waiting for release/signing;
each following task depends on the preceding task. A valid slower result or an
explicitly unsupported operation is evidence, not a reason to fabricate a pass.
Do not call the native API Docker-compatible until actual Docker client operations
and their semantics are verified. Integration work in SPEED-018 must stay isolated
and opt-in; broader support gaps become explicit implementation tasks.

## BACKLOG

### SPEED-020

Title: Benchmark Docker image and registry operations

Description: Measure pull, local load/save, image inspection and removal with controlled registry and cache conditions.

Is blocked by task: SPEED-019.

Acceptance Criteria:

- Use identical immutable images and architecture; separate manifest lookup, transfer, decompression/unpack and ready-to-run where observable.
- Measure cold and cached pulls using a task-owned local registry when supported; report public-network pulls separately without attributing network variation to the runtime.
- Verify digest and runnable contents after pull/load; measure save/load throughput and disk expansion. Delete only task-owned images and artifacts.
- Record unsupported image-management operations for native-only endpoints; image preparation is included in native readiness cost where relevant.

Problem and Evidence: Container startup with cached layers says nothing about image acquisition or unpack cost.

Approach:

1. Create small and multilayer pinned image fixtures and an isolated registry topology.
2. Run cold/cache-hit pull and load/save cycles with scoped cache resets.
3. Verify hashes and report latency, bytes, storage and errors.

Evidence: Pending implementation where applicable, commands, pinned revisions,
raw measurements, validation results, and cleanup verification under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-020`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Create the image fixture and cache-state inventory.

### SPEED-021

Title: Benchmark Docker build and BuildKit

Description: Measure real docker build/buildx build workflows and verify resulting images.

Is blocked by task: SPEED-020.

Acceptance Criteria:

- Pin Dockerfiles, source trees, build arguments, BuildKit versions/driver where controllable, CPU/RAM and package dependencies. Record engine-managed differences.
- Measure empty builder cache with base preloaded, unchanged rebuild, source-only change, dependency change and multi-stage build. Separate image pull, build execution and image export/load.
- Use representative small Rust, Go and Node projects with correctness checks and consistent dependency availability. Verify produced binaries or service responses.
- Report build wall time, cache hits, CPU, memory peak, disk I/O and resulting image size. Record whether BuildKit uses the native runtime, Docker/containerd, or another backend.
- No native build speed claim is allowed merely because a native launch microbenchmark is fast; unsupported Kiri build configurations remain explicit.

Problem and Evidence: Build performance depends on BuildKit, filesystem behavior and caching; the new native launch service is not itself a build engine.

Approach:

1. Reuse the polyglot fixtures and define private builders with explicit endpoints.
2. Execute the cache matrix serially and validate each output image.
3. Publish per-project and per-cache-state comparisons with builder provenance.

Evidence: Pending implementation where applicable, commands, pinned revisions,
raw measurements, validation results, and cleanup verification under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-021`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Pin the three build fixtures and builder configurations.

### SPEED-022

Title: Benchmark Docker Compose application workflows

Description: Measure a real multi-service Compose application from up through readiness and down.

Is blocked by task: SPEED-021.

Acceptance Criteria:

- Pin the same Compose plugin/file/images and use unique project names, isolated networks, volumes and host ports for each engine.
- Measure pre-pulled up --wait, no-change up, one-service recreate, scale, restart and down; separate build/pull cost from startup. Record unsupported commands.
- Use an app plus database/cache fixture with health checks and a functional transaction; readiness requires working dependencies, not only running containers.
- Validate logs, service DNS, published ports and expected data persistence across restart; separately measure down --volumes using only owned volumes.
- Report critical-path readiness, per-service latency, resources and verified cleanup. Attribute mixed native/legacy execution per service.

Problem and Evidence: Compose includes orchestration, network dependencies and storage behavior absent from the single-container native fixture.

Approach:

1. Create the deterministic application fixture and readiness/data canaries.
2. Run the workflow matrix in alternating engine sessions.
3. Verify application correctness and project-scoped cleanup after every cycle.

Evidence: Pending implementation where applicable, commands, pinned revisions,
raw measurements, validation results, and cleanup verification under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-022`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Add the Compose fixture and transaction-based readiness check.

### SPEED-023

Title: Benchmark exec, streams and control-plane operations

Description: Measure Docker exec, attach/logs, inspect/list/events and file copy for supported workloads.

Is blocked by task: SPEED-022.

Acceptance Criteria:

- Separate persistent-container docker exec from fresh docker run; measure API and CLI overhead where supported.
- Validate stdout/stderr separation, bounded large output, exit codes, stdin/TTY behavior where supported, and cancellation without deadlocks.
- Measure inspect/list latency with fixed owned-container counts and event delivery/order under churn; do not query or manipulate production containers.
- Measure docker cp in/out with checksummed small-file and large-file sets. Record unsupported native or Kiri behavior without substituting another operation.

Problem and Evidence: Interactive development and tooling depend on control-plane and stream behavior beyond launch latency.

Approach:

1. Add long-lived fixture containers and deterministic stream/file workloads.
2. Run operation-specific latency and throughput cases with correctness assertions.
3. Inspect backpressure, cancellation and cleanup evidence before publishing results.

Evidence: Pending implementation where applicable, commands, pinned revisions,
raw measurements, validation results, and cleanup verification under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-023`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Create exec and output-integrity fixtures.

### SPEED-024

Title: Benchmark filesystem, networking and sustained workloads

Description: Measure storage and network performance plus realistic long-running service throughput.

Is blocked by task: SPEED-023.

Acceptance Criteria:

- Test named volumes, supported host bind mounts and container writable layers separately: metadata/small files, sequential/random I/O, and fsync durability. Keep datasets and backing files on ExternalSSD.
- Measure container-to-container DNS/TCP, published host ports, connection churn, request latency and throughput with identical topology/payload; record unsupported native networking.
- Validate checksums, acknowledged durable writes and application responses. Use task-owned services and ports; record filesystem/cache settings and client placement.
- Run at least one sustained application workload with latency under load and active-data canaries. Capture CPU, memory and disk growth with a declared steady-state interval.
- Keep raw transport throughput, application readiness and launch latency as separate metrics.

Problem and Evidence: Bridge creation timings do not measure packet performance, and static no-network execution does not establish Docker workload compatibility.

Approach:

1. Reuse existing filesystem/network benchmark utilities with the pinned datasets.
2. Run storage and networking cases independently, then the application load fixture.
3. Verify data integrity and publish topology, throughput, latency and resource observations.

Evidence: Pending implementation where applicable, commands, pinned revisions,
raw measurements, validation results, and cleanup verification under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-024`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Define the bind/volume/writable-layer and network topology matrix.

### SPEED-025

Title: Qualify concurrency, pressure, recovery and efficiency

Description: Run the cross-workload stress matrix and quantify whether speed gains persist under realistic contention.

Is blocked by task: SPEED-024.

Acceptance Criteria:

- Sweep declared concurrency levels for launches and representative builds/services; bound queues and report rejected, failed and timed-out work as well as successful latency.
- Exercise CPU and guest-memory pressure, prepared-slot exhaustion/refill and active-data preservation without inducing unsafe host-wide pressure or stopping production.
- Test request cancellation, client disconnect and task-owned runtime crash/restart with leak inventories and explicit recovery outcomes; use only disposable test state.
- Collect host plus attributed guest CPU/memory, idle footprint, disk growth and reclamation with measurement limitations. Run energy sampling separately only when authorized and available; otherwise mark it unavailable.
- Observe cleanup lag and steady-state resource growth independently from API acknowledgement. Unknown Kiri guest teardown remains unknown.

Problem and Evidence: Fast sequential medians can hide queueing, memory reservation, deferred cleanup and recovery costs.

Approach:

1. Freeze safe resource ceilings and deterministic fault points.
2. Run bounded stress and recovery sessions with canaries and before/after inventories.
3. Analyze scaling, tails, failure rates, resource reclamation and optional energy without discarding adverse sessions.

Evidence: Pending implementation where applicable, commands, pinned revisions,
raw measurements, validation results, and cleanup verification under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-025`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Add the concurrency matrix and owned-resource leak inventory.

### SPEED-026

Title: Publish the Docker and native comparison verdict

Description: Create docs/engineering/docker-benchmark-results.md with reproducible results and a reviewed claim for each workload.

Is blocked by task: SPEED-025.

Acceptance Criteria:

- Publish exact revisions, hashes, commands, effective resources, cache states, timing boundaries, raw evidence links and per-session results for every planned row.
- Report Kiri versus Conjet Docker API, Docker CLI/build/Compose, and native API as separate comparisons. Distinguish accelerated, legacy, mixed and unsupported paths.
- Compute predeclared confidence intervals from independent sessions; avoid treating repeated operations as independent hardware/session evidence. Report failures and missing coverage alongside speed.
- Use per-workload pass/fail/inconclusive/unsupported verdicts. Task completion means valid measurements and an honest report, not a mandatory Conjet win.
- Scope claims to observed M1 Pro conditions; retain deferred cross-host, energy and guest-teardown requirements. Do not use this report to silently expand the earlier release scope or declare all Docker operations accelerated.
- Review findings, create concrete follow-up tasks for regressions/gaps, verify production and cleanup, and commit/push the report without automatically merging or publishing a release.

Problem and Evidence: The current comparison cannot support a general Docker performance claim, and the requested suite must expose both wins and regressions.

Approach:

1. Freeze the measured candidate and audit every scenario against raw evidence.
2. Generate comparable tables and uncertainty estimates; explain backend attribution and missing features.
3. Review the final verdict and evidence links, update the board accurately and record follow-up implementation needs.

Evidence: Pending implementation where applicable, commands, pinned revisions,
raw measurements, validation results, and cleanup verification under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-026`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Build the coverage and claim audit from the completed suite reports.

### SPEED-014

Title: Validate and release the next Conjet version

Description: Release the merged speed enhancement through the existing app and,
if required, guest Core release lanes.

Is blocked by task: SPEED-013.

Acceptance Criteria:

- Select semantic versions from final scope and current releases; version metadata
  and release notes identify only verified behavior and performance claims.
- Merged revision passes applicable final checks and isolated app/DMG installation,
  launch, signing, notarization, stapling, and Homebrew validation.
- Required guest Core assets are released and verified compatible before the app
  release depends on them; release tags match their respective version metadata.
- Release workflows succeed, published assets and final checksums are verified,
  and temporary QA processes, mounts, disks, and files are cleaned up.

Problem and Evidence: Runtime performance qualification does not validate packaged
artifacts or app/Core compatibility; the existing project has separate release lanes.

Approach:

1. Inspect current release workflows and versions, select the next versions, and
   land reviewed release metadata through the repository's normal process.
2. Run isolated release simulations and verify the final artifact and guest-asset
   compatibility; resolve all failures before tagging.
3. Publish the appropriate tags from qualified revisions, monitor workflows, and
   verify release assets, Homebrew output, and cleanup.

Evidence: Local rehearsal and Homebrew rendering are recorded under
SPEED-012. The static guest is distributed in the app; the verified Core
v1.3.1 kernel remains compatible, so a separate Core release is unnecessary.
The production workflow fails closed on missing signing and notarization
credentials. Its keychain setup was exercised with the system Bash,
including a retained keychain path containing spaces. The repository
Actions secrets endpoint reports zero
repository secrets and the environments endpoint reports no environments.
Developer ID certificate and Apple notarization credentials must be
configured or their organization-level availability verified before
production publication. Tags, workflow evidence and published assets are pending.

Source: [Release process](../release.md), [Homebrew](../homebrew.md),
[repository instructions](../../AGENTS.md).

Review: Pending; verify production artifact readiness, version/tag consistency,
asset compatibility, and evidence supporting every release claim.

Next Action: After the PR merges, inspect current versions and release workflows to select the release scope.

## INPROGRESS

### SPEED-019

Title: Benchmark Docker run and container lifecycle

Description: Measure fresh Docker API and docker run end-to-end against Kiri, retaining native API measurements as a distinct comparison.

Is blocked by task: SPEED-018 for the accelerated Docker route. Existing
Docker and native lanes can proceed independently.

Acceptance Criteria:

- Measure create/start/wait/removal through HTTP and docker run --rm through the same pinned CLI separately. Validate nonzero exits and output; include true and a small observable application.
- Cover warm-image no-network and supported bridge cases; separate first-use/image acquisition from cached runs. Keep VM cold boot outside warm lifecycle timing.
- Report p50/p95/p99, raw failures, wall time, throughput and per-session distributions. Record API removal and verified guest cleanup separately; do not infer one from the other.
- Compare native fresh/prepared only where workload semantics match; include preparation/refill, missed claims and actual dispatch backend. Do not label a native RPC measurement docker run.
- Exercise create/start of pre-created containers, stop/kill/restart and remove; mark unsupported lifecycle operations explicitly.

Problem and Evidence: The orchestrator exposes the frozen lifecycle counts and allows
one complete network/workload/adapter group per paired session. The
launchers keep API removal acknowledgement separate from cleanup. The
pilot measured 121.6 s for 240 Conjet operations. At that rate the
full frozen 12-group, five-session Conjet matrix alone requires about
17 hours of measured windows. Start with an independently booted,
complete group and keep partial coverage explicit.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Run the frozen serial group on the existing Docker endpoints,
retain full raw windows and later repeat across the remaining pairs and groups.

### SPEED-018

Title: Qualify Docker-to-native routing before claiming Docker acceleration

Description: Define and, for the explicitly supported subset, implement an opt-in Docker-compatible route to the new native execution service; qualify it before performance measurement.

Is blocked by task: SPEED-017.

Acceptance Criteria:

- Write a supported Docker operation/option contract and single-owner lifecycle design before implementation. General Alpine/OCI execution requires verified image/rootfs admission and execution support, not a static-binary substitution.
- Support the selected real docker run lifecycle, including API negotiation, create/start, attach/output, actual exit status, wait conditions, inspect and removal. Test event ordering, names/IDs, cancellation and disconnect recovery.
- Record backend selection per container. Reject unsupported requests clearly or route them explicitly to the existing Docker backend before allocation/start; never silently ignore flags or retry after ambiguous execution.
- Verify isolation, bounded resources, image semantics and no leaks on success/failure. Keep the experimental route isolated and opt-in; ordinary production routing is unchanged.
- If integration is not viable within the declared subset, record an unavailable accelerated Docker lane and a reviewed follow-up implementation task. Benchmark existing Docker and native lanes separately; do not claim this benchmark work created Docker acceleration.

Problem and Evidence: [Adapter contract and reproduced limitation](docker-native-adapter.md).
The extracted pinned Alpine `/bin/busybox` needs a dynamic interpreter.
The existing native loader rejected the exact executable before VM boot.
Both engines exported the same image config and uncompressed rootfs diff ID.
The archive admission checker verified matching 519-entry receipts without
extracting a host file tree. Its digest, platform and path tests passed.
The exact rejection and receipts are under ExternalSSD `SPEED-018`.

Subtasks:
- Verified image metadata and one-layer archive admission.
- Stage that image as an immutable guest root and execute a bounded OCI
  process spec through the native supervisor.
- Add an explicit Docker socket owner with negotiation, attach, wait,
  inspect, events and removal.
- Qualify the real Docker CLI, cancellation/replay and cleanup before
  measuring the accelerated lane.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Verified containerd and native dispatch boundaries, image config and
layer verification, strict path checks and the static-only rejection.
Docker backend qualification remains open.

Next Action: Implement guest rootfs staging and the Docker protocol owner.
The independent existing Docker and native lanes can run while this route is unavailable.

### SPEED-008

Title: Run the fresh-runtime comparison and record the gate decision

Description: Create docs/engineering/fresh-runtime-gate.md linking the baseline and candidate reports and a proceed/revise/stop verdict.

Is blocked by task: SPEED-007.

Acceptance Criteria:

- Measure equivalent no-network and bridge lifecycle scenarios, including cleanup.
- Report latency distributions, sustainable churn, CPU, memory, failures, and uncertainty.
- Attribute observed bottlenecks with traces; do not infer that all savings belong to Jetstream.
- Record a proceed/revise/stop decision and preserve any regression evidence.

Problem and Evidence: The architecture plausibly removes launch overhead, but
neither its performance nor superiority has been measured.

Approach:

1. Run the SPEED-002 scenarios against original Conjet, the candidate, and pinned Kiri with matching cache and network modes.
2. Compare API-visible and cleanup-complete latency, throughput, CPU, memory, and failures; profile the dominant stages.
3. Record which gains are demonstrated, any regressions, and whether prepared-launch work is justified; block it on a revise/stop verdict.

Evidence: The signed native VSOCK diagnostic with 25 ms host ticks
showed a 17.062 ms idle ping p50 and 27.426 ms p99. Without ticks eight
pings returned before the session stopped. The Darwin native socket
watcher now waits on kqueue and wakes the VMM on accept or incoming data.
With the same tick setting, idle ping p50/p99 became 1.610/7.361 ms.
The tick-disabled variant completed 200 pings in both trials, but the
first stalled on a bridge lifecycle. Preserve that failure and keep the
tick-enabled fixture for comparative work. Raw RPCs, commands, hashes,
and matching production snapshots are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/transport`.

The workspace passed 156 Rust tests with three existing opt-in tests
ignored. The focused VSOCK suite passed 29 tests. The branch-built
candidate's separate Docker smoke passed. The [fresh runtime gate](fresh-runtime-gate.md)
records the comparison method and the limited diagnostic results.
The matched image probe used a single pinned static ARM64 executable
and the same requested workload resource limits on original Conjet at
`bbe8019`, the official Kiri 0.2.2 app, and the native candidate. All 240
measurements passed their adapter checks. Native no-network API p50 was
2.156 ms and p99 was 6.997 ms, versus Kiri's 4.074 and 5.025 ms. Native
bridge API p50 was 76.018 ms versus Kiri's 37.155 ms. Native terminal
responses require verified cleanup. The Docker API observations stop at
removal acknowledgement and do not establish equivalent cleanup. This
M1 Pro run remained under production background load and yields no
competitive qualification decision. The reports, hashes, host snapshots,
and launcher verification are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/common-image`.
The Kiri smoke and mid-benchmark cancellation checks verified the official
peer, matching production observations, removed socket, and no residual
VM disk holder. Python compilation, 17 focused Rust tests and strict
macOS and ARM64 Linux Clippy passed.

Six further isolated native boots measured optional guest-local phase
timestamps. Two traced default-kernel runs attributed about 19 ms median
to bridge preparation before child authorization and 40–41 ms median to
verified network teardown after exit. The on/off trials overlapped and do
not resolve trace overhead. Expedited RCU increased bridge latency and
remains a diagnostic flag. All 1,200 measured operations passed fixture
checks. Evidence and passing production comparisons are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/phase-analysis`.

Grouped synchronous removal halved the measured bridge teardown median
from roughly 40 ms to 19 ms. Bridge API p50 fell from 64–68 ms to
42–44 ms. The complete kernel bridge and previous recovery matrices,
800 follow-up measurements, focused Rust tests, and strict ARM64 Clippy
passed. Retained evidence is in `SPEED-008/grouped-teardown`.

Direct peer registration reduced measured bridge preparation from about
19 ms to under 0.4 ms. Two boots measured native bridge API p50 about
20.2 ms and p99 about 44 ms. All 800 operations and the bridge, private
scope, teardown, fault and cancellation regressions passed. The runner
records the timed measurement window in addition to individual operations
and tracks the native VMM and owned networking helper. Reports are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/direct-peer`.

The serial common-image run on `64fe823` captured 4,000 native operations
with verified cleanup, 4,000 Kiri Docker API operations, and 200 original
Conjet Docker API operations. All completed at their adapter's boundary.
The native bridge recorded 20.196 ms p50 and 32.315 ms p99 across 42.352
seconds, while Kiri's API acknowledgement was 33.608 ms p50 and 63.461 ms
p99. Kiri's read-only guest visibility probe saw its own container as
PID 1 and could not verify guest cleanup. Raw timings, launcher
observations, physical footprint, CPU and balloon evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/api-churn`.
The reviewed gate decision is **revise**. Qualification is still pending.

Source: [Delivery gates](speed-engineering-plan.md#incremental-delivery-and-decision-gates),
[verification policy](speed-engineering-plan.md#verification-and-claim-policy).

Review: Reviewed the kqueue callback and queue ownership, guest phase
attribution, grouped link teardown, and direct peer registration. The
revised native path passed the scoped correctness and recovery matrix.
The gate remains unmet because the Docker competitor cleanup endpoint,
second physical host configuration, equivalent network scope, energy,
and full qualification matrix are unverified.

Next Action: Deferred for comparative research. Obtain a second ARM64 host,
a way to observe official Kiri guest teardown, and authorized energy sampling,
then rerun the original matrix. Experimental release proceeds under local
acceptance without changing the SPEED-008 verdict.

## UNDERREVIEW

### SPEED-013

Title: Open and qualify the speed enhancement PR to main

Description: Submit the completed enhancement with its final benchmark and
correctness evidence, then resolve review and CI findings before merging.

Is blocked by task: SPEED-012 and SPEED-011 required experimental checks.

Acceptance Criteria:

- Prior development and required local gates are audited with passing evidence
  and verified pushed commits. SPEED-008 continues to record its revise verdict.
- Final qualification reports identify the tested revision and exact claim scope;
  no required check is skipped or unresolved.
- PR targets main from enhancement/speed-up and links the plan, board, reports,
  compatibility limitations, and rollback procedure.
- Required CI and review pass; changes during review receive applicable validation
  and are pushed as additional increments before merge.

Problem and Evidence: A pushed implementation branch alone does not establish
reviewed integration or release readiness.

Approach:

1. Audit every task and final gate against the remote branch revision.
2. Open the PR with concrete behavior, benchmark results, and validation evidence.
3. Resolve findings, rerun affected checks, push increments, and merge only when
   repository review and CI requirements are satisfied.

Evidence: The final local gate was audited against `cb1f80f` and the
remote enhancement branch matched. [PR #33](https://github.com/omega13-engr/conjet/pull/33)
targets main and discloses the experimental scope, local measurements,
rollback procedure and deferred comparative work. On `d613c87`,
[hosted CI](https://github.com/omega13-engr/conjet/actions/runs/45083820209)
passed the build and host tests, then failed the existing overflow-pulse
app test. Its fixed 220 ms sleep could end before asynchronous inventory
loading recorded any invocations. The test now awaits the scheduled
refresh and retains all five Docker inventory assertions. The application
change only exposes the existing task on its test hook. The 50-test
focused suite and the 440-test full Swift suite passed locally, with two
configuration skips in the full suite. Failure and regression logs are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-013`.
Independent review, passing hosted CI and merge remain pending.

Source: [Qualification policy](speed-engineering-plan.md#verification-and-claim-policy),
[release process](../release.md).

Review: Pending; verify all development gates before opening the PR and all CI
and review requirements before merge.

Next Action: Collect required CI and independent review before merging.

## DONE

### SPEED-017

Title: Capture current Docker and native baselines

Description: Run a bounded pilot of the unchanged engines and native product before implementing an accelerated Docker adapter.

Is blocked by task: SPEED-016.

Acceptance Criteria:

- Capture direct Docker API and actual Docker CLI lifecycle on both engines, plus separately labeled native fresh/prepared timings for the same supported payload.
- Probe build, Compose, exec, volumes and networking capabilities; record unsupported/error outcomes explicitly and retain them in coverage.
- Record native preparation/refill and misses separately; retain original data and do not combine pilot samples with final qualification.
- Identify which Docker operations reach Docker/containerd and which, if any, reach the native service using runtime dispatch evidence.

Problem and Evidence: Under ExternalSSD `conjet-speedup-evidence/SPEED-017`, the initial
pair retained 240 measured and 120 warmup lifecycle records per Docker
engine, with zero failures. Both engines observed 16 MiB, 4 PIDs and a
500-millicore CPU quota inside the Alpine canary. Kiri reported VM memory
as zero in /info, so its guest memory total is unknown. Conjet's Docker
engine reported runc on the existing bridged Docker/containerd path;
Kiri reported its own runtime. The Docker API timings end at removal
acknowledgement. Separate native endpoint measurements verified cleanup
and reported fresh/claim/refill/miss separately. The follow-up Compose
probe verified a Redis write/read transaction through service DNS on each
engine. Image save and basic exec, volume and network probes passed.
Conjet's embedded BuildKit built and verified the canary. Kiri started a
private pinned BuildKit container; a build through it remains for SPEED-021.
The initial missing Compose applet error was preserved. Both launchers
verified production and shutdown.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Audited stream canaries, exit 23, cgroup observations, actual
engine identities and cleanup. Keep one-session pilot results out of the
qualifying distributions.

Next Action: Address OCI admission and runtime ownership in SPEED-018.

### SPEED-016

Title: Make the benchmark orchestrator safe and reproducible

Description: Extend the isolated launchers and reporting harness to execute the frozen suite serially with explicit engine identities.

Is blocked by task: SPEED-015.

Acceptance Criteria:

- Use private DOCKER_CONFIG and explicit contexts/endpoints: conjet-speedup for the candidate and kiri-speedup for Kiri. Identify actual binaries, servers, builders and VM disk holders; reject production endpoints.
- Store all images, volumes, build contexts, caches, logs and scratch artifacts on ExternalSSD; verify backing paths. Use unique labels, Compose project names and task-owned builders.
- Alternate engine order between paired sessions; run timing suites without overlapping builds or other benchmark engines. Preserve production and record its contention.
- Exercise interruption, timeout and partial-report recovery. Cleanup only owned resources; no global prune/context switch, persistent jobs or global credential changes. Verify production snapshots and no owned process/disk/socket holders.

Problem and Evidence: The isolated launchers now run the comparison coordinator with
pinned clients, a private context and an endpoint peer check. The serial
preflight passed in Kiri-then-Conjet order, verified that the actual VM
processes held only the designated backing files, and confirmed shutdown
and unchanged production. The first attempt established that Kiri can
answer metadata before its VM boots; the runner now uses an untimed pinned
launch before measuring disks. A one-second timeout stopped the owned Kiri
daemon and removed its socket while retaining partial evidence. Three new
safety tests and the five existing adapter tests passed. Evidence is under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-016`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Checked mounted storage paths, process and context attribution,
serial pairing, cancellation, partial evidence and lease scope. Builder
execution and effective workload limits are checked by the workload probes.

Next Action: Run the SPEED-017 pilot with the frozen endpoints.

### SPEED-015

Title: Freeze the Docker comparison contract and capability matrix

Description: Create benchmarks/scenarios/docker-comparison-v1.json and docs/engineering/docker-benchmark-plan.md defining the workloads, adapters, timing boundaries, and qualification rules.

Is blocked by task: None; uses completed SPEED-000 through SPEED-012 evidence. Does not wait for SPEED-014.

Acceptance Criteria:

- List four separate lanes: official Kiri Docker API/CLI, existing Conjet Docker API/CLI, native fresh/prepared API, and any verified Docker-to-native adapter. Record supported/unsupported operations per lane; never substitute native execution for docker build or Compose.
- Pin official Kiri version/hash, candidate revision, ARM64 image digests, Docker/Compose/Buildx clients, guest resources, storage placement, network behavior, and cache policies. Record effective limits, not only requested values.
- Predeclare warmups, repetitions, concurrency, timeouts, failure treatment, session ordering and statistics. Lifecycle qualification retains at least 10,000 operations per scenario across five sessions; declare practical independent-session counts for expensive builds/Compose before measuring.
- Scope local conclusions to the M1 Pro. Preserve the deferred second-host, energy and equivalent-teardown requirements; unavailable observability must produce unknown, not pass.

Problem and Evidence: Previous comparisons mixed native and Docker endpoints; the experimental native product cannot yet run general OCI images, bridge workloads, or Docker commands.

Approach:

1. Inventory the existing harnesses and runtime capabilities without changing production.
2. Write the scenario manifest and an ASCII diagram for each execution path; identify integration gaps as separate implementation prerequisites.
3. Review the manifest against each requested Docker operation and freeze the initial measurement policy.

Evidence: [Frozen contract](docker-benchmark-plan.md) and [manifest](../../benchmarks/scenarios/docker-comparison-v1.json). Verified the installed Kiri signature and host client hashes. Resolved Docker Hub ARM64 child manifests through the registry and checked the HTTP digest against each index body. Baseline source is `7e075c0`. No timing samples were taken for this task.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Checked the four execution paths, minimum lifecycle sample budget, paired-session resampling and separate timing boundaries against the previous gates. Unobserved cleanup and effective limits remain unknown.

Next Action: Apply the manifest in SPEED-016.

### SPEED-012

Title: Expose the qualified native launch mode and document release scope

Description: Integrate the passing native API, CLI, and status behavior; deliver E2E evidence, rollback instructions, and an explicit Docker-integration decision.

Is blocked by task: reviewed implementation through SPEED-007 and isolated
SPEED-009/SPEED-010 evidence (available). SPEED-011 local acceptance gates the PR.

Acceptance Criteria:

- Native API/CLI/status surfaces identify runtime owner, fresh/prepared mode,
  preparation costs, misses, and unsupported features clearly.
- Existing Docker/containerd behavior passes relevant regression checks.
- Screenshot-backed E2E validates affected user-visible surfaces using isolated resources.
- Docker routing is enabled only after a separately documented ownership and
  compatibility gate; otherwise retain the existing Docker lane and record follow-up scope.
- Document rollback, evidence-backed claims, remaining limits, and all temporary-resource cleanup.

Problem and Evidence: A fast prototype does not establish product compatibility,
operational readiness, or a safe unified Docker lifecycle.

Approach:

1. Expose runtime owner, launch mode, preparation state, misses, and errors through the selected native surfaces.
2. Run existing Docker regressions and isolated native E2E flows; capture screenshots for affected UI/status surfaces and test rollback.
3. Write docs/engineering/speed-release-scope.md with supported configurations and measured claims; leave Docker routing on its existing engine unless a separate compatibility gate is approved and passed.

Evidence: The 2026-11-23 scope revision separates local product and
release acceptance from the deferred comparative gates. Local and remote
development heads agreed at `3aaf062` before the revision. Reviewed the
original qualification criteria and retained evidence references.

The foreground native session exposes fresh, prepare, claim, status, cancellation,
memory pressure and stop through the authenticated API and `conjet native
--experimental`. Its Linux guest accepts a pinned static ARM64 executable with
no arguments or network. The host creates no Docker or memory socket in this
mode. CLI admission is nonblocking and it never resubmits an indeterminate
execution. The independent Docker lane retains its existing ownership.

M1 Pro validation used `swift test --build-system native` (440 tests, two
skips), `cargo test --locked --workspace` (159 passing, three entitlement
tests excluded from the default run), strict ARM64 Linux Clippy, Python
compilation and formatting. The strict host Clippy diagnostics also
appear on the archived `a9f06d9` baseline. The live product probe
(`benchmarks/native-product.py`) checked no-network isolation, fresh and
prepared execution, concurrent claims, eviction, active memory preservation,
bounded output, disconnect replay/cancellation, expiration and verified
cleanup. Its two guests both negotiated page reporting with zero
reclamation errors. The separate branch-built `conjet-speedup` Docker
smoke passed. Both launchers recorded matching production snapshots.
Logs, partial runs, raw samples, and Docker evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-012`.
The development timings were collected with other builds active. The
source implementation was pushed as `ff1877c`.

The release stage builds and bundles the static Linux guest beside the VMM.
An isolated ARM64 app and DMG built with the repository scripts passed
deep signature validation, byte comparison of the DMG-extracted CLI, VMM
and guest against staging, DMG verification, SHA-256 verification, and
Formula/Cask Ruby validation. `diskutil image attach --readOnly` mounted the
DMG on this macOS host after legacy `hdiutil attach` returned permission
denied. The local artifact used ad-hoc signing for rehearsal only.
Logs are in the SPEED-012 evidence directory. No app was registered or
launched. Final measurements use the packaged CLI and the app-sealed guest.

Source: [Architecture ownership](speed-engineering-plan.md#architecture-and-ownership),
[final recommendation](speed-engineering-plan.md#final-recommendation),
[repository instructions](../../AGENTS.md).

Review: Checked native endpoint ownership and key permissions, operation IDs
and replay, bounded admission and output, expiry, and guest/host cleanup.
Verified staged app and binary signatures, packaged/extracted byte matches
and a successful native run from the DMG layout with default tool resolution.
The changed surface is a JSON CLI and API with no graphical UI screenshot
target. A second mount attempt raised a system prompt, was canceled, and
the owned disk image was ejected. CI covers the mounted DMG contents.

Next Action: Carry the validated experimental runtime and release
documentation into SPEED-013.

### SPEED-011

Title: Run the qualification matrix and publish measured verdicts

Description: Create docs/engineering/speed-qualification.md linking raw reports and pass/fail results for each proposed performance claim.

Is blocked by task: SPEED-012 product path for local acceptance (DONE).
The deferred comparative matrix additionally requires SPEED-008.

Acceptance Criteria:

Required for experimental release: frozen M1 Pro product candidate,
reproducible fresh/prepared API and CLI samples, failures, refill, misses,
churn, CPU and memory observations, pressure and cleanup evidence, and
declared operating limits.

Deferred comparative research criteria:

- Follow the plan's minimum sample/session/hardware matrix and predefined statistical method.
- Report fresh, prepared, CLI, sustained churn, builds, and running-service scenarios separately.
- Include pool misses/refill, CPU, memory, energy, host contention, and memory pressure.
- Prepared sub-1 ms claims meet the declared p99 gate; fresh superiority meets
  equivalent-work latency and throughput gates without correctness regressions.
- Record go/no-go per claim; a missed target is reported honestly rather than concealed.

Problem and Evidence: The 1,000-microsecond budget is a research allowance, not a
measurement; neither fresh nor prepared superiority is established.

Approach:

1. Run the predeclared sample/session/hardware matrix for fresh, prepared, CLI, churn, builds, and services under reclaim.
2. Record preparation/refill, misses, failures, CPU, memory, energy, contention, and pressure; profile and change one demonstrated bottleneck at a time.
3. Evaluate the sub-1 ms prepared p99 gate and equivalent-work fresh superiority independently; document failed targets and uncertainty.

Evidence: The [local qualification report](speed-qualification.md) links
three M1 Pro packaged-candidate sessions, with safety canaries and 2,400
measured operations passing. The report records the exact executable
and kernel hashes, latency, refill, misses, throughput, CPU, RSS,
background contention and raw evidence. The 45-test Swift benchmark package, Go network race suite, and three
separately entitled memory/backing tests passed. The historical 2.478 ms prepared p99 was
recomputed from the retained raw samples. The comparative matrix remains
deferred with its original acceptance criteria and unresolved verdict.

Source: [Latency budget](speed-engineering-plan.md#experimental-latency-budget),
[claim policy](speed-engineering-plan.md#verification-and-claim-policy),
[benchmark package](../../benchmarks/README.md).

Review: Verified per-session nearest-rank results against raw samples,
cleanup boundaries, expected failures, and measured refill throughput.
Comparative work and its independent review are deferred.

Next Action: Carry the scoped evidence into SPEED-013. Resume comparative work when the deferred inputs become available.

### SPEED-010

Title: Connect launch-service cgroups to memory accounting and eviction

Description: Register active workloads and prepared reserves with the memory controller. Deliver pressure-eviction and allocation/free/reuse evidence.

Development prerequisite: SPEED-009 (DONE).

Final qualification prerequisites: SPEED-008 and the applicable SPEED-011 gates.

Acceptance Criteria:

- Controller telemetry distinguishes active workloads, prepared reserve, and empty scopes.
- Pressure destroys unused slots before reclaiming active demand; accounting is bounded.
- Existing ownership, host-granule, backing-release, and service-pressure safeguards remain valid.
- Exercise allocation/free/reuse, data canaries, pool eviction, rebuild, and launch after pressure.
- Measure idle footprint with/without slots and verify cleanup without disturbing installed services.

Problem and Evidence: Unregistered runtime cgroups could be mistaken for idle
capacity; prepared resources consume memory even when launch latency is low.

Approach:

1. Expose separate active and prepared cgroup telemetry with validity indicators; verify idle classification against live workloads.
2. Stop admitting slots and destroy unused slots under pressure; let existing ownership-based reclamation release backing.
3. Run live canaries through allocation/free, eviction, fresh fallback, and preparation rebuild; compare footprint with zero and populated slots.

Evidence: The isolated native controller now reports active and prepared
ownership separately, including sample validity, current cgroup charge,
population, and limit. A claimed reservation becomes active before release
and retains its cgroup until teardown. The authenticated pressure input
evicts unused slots and pauses preparation. The Docker-only idle controller
cannot classify the isolated native mode. Existing page ownership and
backing release paths are unchanged.

Two live boots verified eviction in 1.430 and 1.681 ms through cleanup,
explicit fresh work under pressure, and refill in 2.056 and 1.640 ms.
An active 8 MiB byte canary reported 8,642,560 charged bytes and survived
the pressure signal. The recorded claim/pressure race produced a single
winning claim and verified cleanup. VMM footprint increased by 49,152
and 81,920 bytes between empty and ready observations. The 50-operation
prepared regression, workspace tests, Linux ARM64 Clippy and Python
byte compilation passed. The initial too-large integer canary failures
and successful reruns are preserved under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-010`.
These runs used an authenticated pressure signal. The guest now also
fails closed on missing availability or less than 64 MiB. A separate
512 MiB disposable VM with a 72 MiB balloon target reported 25,894,912
available bytes and rejected preparation automatically while a fresh
workload executed and cleaned up successfully. The low-start test
verified automatic admission. Ready-slot eviction was exercised with
the authenticated pressure signal.

The final baseline, pressure and prepared regressions passed. Three
entitled tests separately exercised Linux free-page reporting and
uncorrupted reuse, partial backing release, and immediate HVF backing
release. The Linux reuse test recorded RSS falling from 137,904,128 to
69,566,464 bytes. Reports and binary identities are in
`SPEED-010/guest-availability` and `SPEED-010/backing-release`.
The experimental scope is one owned workload. Production adaptive policy
integration and competitive qualification remain gated.

Source: [Memory integration](speed-engineering-plan.md#dynamic-memory-integration),
[memory debugging](../dynamic-memory-debugging.md),
[backing reclamation](../jetstream-host-backing-reclaim.md).

Review: Checked accounting through cleanup, active protection at claim,
serialization with pressure, and the opt-in scope of the host guard.

Next Action: Keep local measurements experimental and prepare the final
qualification matrix. The paired preparation trace led to the preclaim sandbox experiment
recorded in SPEED-009.

### SPEED-009

Title: Implement prepare, claim, expire, and destroy for one-use slots

Description: Add explicit prepared-launch API operations and a bounded slot table. Deliver state-machine and isolation tests plus preparation/hit/miss measurements.

Development prerequisite: SPEED-007 (DONE).

Final qualification prerequisites: SPEED-008 and the applicable SPEED-011 gates.

Acceptance Criteria:

- Bind authenticated handles to image/specification digests, ownership, and generation.
- Atomically consume each slot once; executed slots are destroyed rather than recycled.
- Enforce slot count, memory, queue, lifetime, and preparation-concurrency bounds.
- Record preparation, hits, misses, expiry, and replenishment; miss fallback is explicit
  and occurs only before execution.
- Test concurrent claims, invalidation, cancellation, exhaustion, and no cross-run state leakage.

Problem and Evidence: Fresh resource setup may dominate latency; prepared execution
moves that cost earlier but creates memory and stale-state risks.

Approach:

1. Implement specification digest, owner and generation validation, and atomic READY-to-CLAIMED transition.
2. Create a private waiting init without running application code; consume once, then destroy the slot and its resources.
3. Enforce configured limits and expiry; test concurrent claims, stale handles, changed specifications, cancellation, exhaustion, and explicit fresh fallback before execution.

Evidence: The isolated no-network fixture implements authenticated prepare and
claim with one exclusive slot, no queue, a 32 MiB cgroup ceiling, a bounded
lifetime and explicit fallback. Two independent local boots each measured
100 post-warmup prepared launches. Preparation p50/p99 was 1.040/2.755
and 1.033/1.722 ms. Claim-to-exec observation p50/p99 was 1.512/2.709
and 1.500/2.484 ms. Verified cleanup p50/p99 was 2.231/4.421 and
2.126/3.775 ms from claim. Cancel and expiry misses took 0.360–0.470 ms
across the four checks. Preparation is charged again on every refill.

The two live runs verified credential, root and seccomp canaries,
simultaneous claims, replay, stale generation, changed spec, slot exhaustion,
cancellation, expiry and explicit fresh fallback after proven non-execution.
The final run also rejected requests above the experimental reserve limit
and checked distinct handles across refills. Fresh API and CLI regression
passed for both network modes. The 19 focused Rust tests, Linux ARM64
Clippy, Python byte compilation, formatting and diff review passed.
Raw samples, commands, binary hashes and production snapshots are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-009`.
These are local implementation checks. Final qualification remains open.

The follow-up experiment parks the trusted child with the private root
mounted, limits applied, and credentials dropped. Seccomp and exec
remain behind the claim. Two final boots measured 200 operations each.
The traced guest claim-to-exec median fell from 1.080 to 0.768 ms.
Untraced host claim-to-exec p50/p99 was 1.338/2.478 ms, with preparation
p50/p99 of 1.472/3.024 ms. Record the extra preparation cost explicitly.
Both runs passed the prepared safety cases. Fresh API/CLI, live pressure,
and the balloon guard passed on the revised guest. The final workspace
run passed 159 tests. The three ignored-by-default tests ran separately
with the required entitlement in SPEED-010. See
`SPEED-009/preclaim-sandbox` for raw runs and checks.

Source: [Prepared lane](speed-engineering-plan.md#prepared-launch-lane),
[latency budget](speed-engineering-plan.md#experimental-latency-budget).

Review: Checked serialized claim and release, pre-exec isolation, fail-closed
expired or indeterminate claims, verified cleanup, and repeat preparation costs.

Next Action: Wire experimental cgroup telemetry and pressure eviction in SPEED-010.

### SPEED-007

Title: Implement fresh bridge networking with verified teardown

Description: Add one private bridge mode with addresses, DNS, and the explicitly supported port behavior. Deliver network correctness and cleanup tests.

Is blocked by task: SPEED-006.

Acceptance Criteria:

- Implement the declared bridge, addressing, DNS, and port behavior or explicitly
  reject unsupported networking options.
- Verify identity isolation, traffic correctness, address reuse, and teardown under churn.
- API-visible removal and actual network cleanup are independently observable.
- No unbounded deferred cleanup or networking changes to the installed runtime.

Problem and Evidence: A no-network result cannot substantiate a bridge-network
win against Kiri; deferred veth cleanup changes the lifecycle boundary.

Approach:

1. Allocate network identity and interfaces as owned launch resources; unwind every partial failure.
2. Verify DNS, peer isolation, supported port traffic, concurrent address reuse, and rejection of unsupported network options.
3. Observe interface, address, DNS, and port cleanup before declaring cleanup complete; run repeated bridge launches with traffic canaries.

Evidence: The standalone ARM64 kernel fixture opened a new private
network namespace, used checked rtnetlink requests to create an IPv4 bridge
and move a veth peer into a second network namespace, and verified TCP
traffic from the assigned address. It removed the bridge and veth and
confirmed on both sides that their addresses could no longer bind.
Ten consecutive allocations reused the same address pair with no residual
interfaces. The normal host remained unchanged. The pinned musl rebuild,
command, hashes, guest logs and production observations are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-007/network-kernel`.
Strict ARM64 Clippy, 17 focused Rust tests, formatting, and diff checks passed.
The opt-in native bridge now passes authenticated launch and root, DNS,
TCP and teardown canaries. The bridge and peer use a private IPv4 /30
with no uplink. Its test resolver answers one pinned name, and TCP uses
one guest-private port. Host networking and published ports are rejected
before allocation. The no-network mode retains its original seccomp deny
rules. The bridge filter allows IPv4 stream and datagram sockets and
rejects raw sockets and AF_VSOCK. The focused run observed actual workload
exit while network cleanup was pending, then network removal and total
lifecycle removal in separate states. Injected helper failures recovered
after bridge creation, peer attachment, and before link cleanup. Five
complete launch cycles in each mode and the SPEED-006 failure and
cancellation regression matrix passed, with matching production snapshots.
The pinned rebuild, raw RPC, guest logs and verification scripts are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-007/bridge-launch`.
The final native binary probes bridge creation, resolver and TCP socket
binding, and verified removal before advertising its capability. Two
independent kernel bridge scopes in the same guest used the same addresses
and TCP port simultaneously, with separate namespace IDs and different
payload canaries, for five rounds. Native admission still enforces one
active workload. Fifty serial native bridge launches passed in each of the
normal and recovery boots, along with separate exit and network-cleanup
observations and forced recovery. Pinned binary hashes, raw traces, logs,
and passing production comparisons are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-007/bridge-scopes`.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[measurement contract](speed-engineering-plan.md#measurement-contract).

Review: The link proof reviewed the kernel sender and request sequence,
namespace ownership, explicit link deletion and address cleanup. Reviewed
the workload socket filter, fixed guest DNS and port bindings, peer
namespace FD lifetime, the separate network-cleanup state, the
kernel capability probe, and concurrent network identity isolation.
The one-workload fixture rejects host networking, user port maps and
arbitrary DNS. Broader Docker networking remains on its existing owner.

Next Action: Begin SPEED-008 with matching scenarios and a focused
transport timing experiment before claiming any lifecycle speedup.

### SPEED-006

Title: Add lifecycle failure injection and recovery tests

Description: Deliver a deterministic test matrix proving that launch failures, disconnects, and cancellation do not leak resources or duplicate execution.

Is blocked by task: SPEED-005.

Acceptance Criteria:

- Exercise cancellation at each lifecycle stage, malformed specs, exec failure,
  output backpressure, resource exhaustion, disconnects, and supervisor/guest failure.
- Verify isolation and data canaries, child reaping, and absence of resource leaks.
- Restart/recovery reconciles state without re-executing ambiguous requests.
- Relevant automated checks pass; unresolved correctness failures block later tasks.

Problem and Evidence: Direct supervision removes runtime layers whose lifecycle
and cleanup responsibilities must now be implemented by Conjet.

Approach:

1. Inject failure after each resource allocation and at child creation, exec, output handling, and cleanup.
2. Test cancellation before start, during execution, and during cleanup; reconnect using the same request ID and verify no duplicate start.
3. Kill the supervisor or disposable guest at defined stages; reconcile state and compare process, mount, and cgroup inventories before and after repeated runs.

Evidence: The fixture records a single root-private workload intent before
starting its helper. The helper verifies that intent and uses the same ID for
the cgroup leaf. Completion releases the record only after the helper confirms
cleanup. A corrupt or outstanding intent blocks admission on start. Cancellation
does not regress an observed cleanup phase.

`cargo test --locked -p conjet-launch-service` passed 17 tests, including
exclusive intent creation, re-opening a recorded ID, rejection of a different
owner, and preservation of corrupt state. Strict Linux ARM64 Clippy passed.
The pinned ARM64 musl build and live repeat of the fresh lifecycle matrix,
with before/after production observations, are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-006/intent`.
A separate live ARM64 run killed the guest supervisor after the kernel
confirmed workload exec. Guest init pinned the exited leader's PID while
signaling only its process group, reaped the group, and verified removal of
the recorded cgroup and sandbox before restarting the supervisor. The next
authenticated generation rejected the original launch and handle, then ran
a new workload and shut down cleanly. The companion normal boot passed the
same lifecycle checks without crash injection. Both runs verified production
snapshots and are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-006/restart`.
The helper-failure matrix passed after injected loss following sandbox,
mount, cgroup and child creation, exec confirmation, and the exit notification
before cleanup. The live supervisor reconciled each owned workload without
rotating the generation. Tests also verified a kernel exec failure (127),
bounded output (64 KiB per stream with exact dropped-byte counts), and a
memory cgroup kill (signal 9 and `oom_kill 1`). An independent disposable
VMM kill after exec left that outcome ambiguous. A replacement VM rejected
the old launch and handle and completed new work. All three runs preserved
the production snapshots. Commands, raw protocol observations, compiler and
guest logs are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-006/helper-faults`.
The final live matrix paused independently during preparation, with the
child created but before exec authorization, and during cleanup after
application exit. Cancellation before resources returned no exit.
Cancellation at the child barrier returned its actual exit 125 and no
exec confirmation. Cancellation during cleanup preserved the confirmed
exec and exit 0. Exact launch retries kept the same handle at each stage
and the reserved admission quota rejected a different launch. The full
matrix repeated all six helper failures, verified recovery of the owned
processes, cgroup and sandbox before reuse, and passed the normal boot
and disposable VM-loss runs again. This was the restricted one-workload
fixture, on the M1 Pro with production running and matching before/after
snapshots. All 17 focused Rust tests and strict Linux ARM64 Clippy passed.
The pinned rebuild, verification scripts, binary hashes and raw traces are
under `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-006/cancellation`.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[verification policy](speed-engineering-plan.md#verification-and-claim-policy).

Review: Reviewed write-before-helper ordering, deterministic cgroup identity,
and fail-closed admission after an unresolved intent. Reviewed the
guest-only process group, PID pinning, stale generation check before
admission, named cgroup teardown, private root canaries, the authorization
barrier and the distinction between accepting cancellation and finishing
cleanup. The fixture has no production activation path.

Next Action: Begin the private IPv4 bridge and verify its independently
owned link, addressing, DNS and port resources under teardown.

### SPEED-005

Title: Implement one fresh ARM64 no-network container launch

Description: Implement launch, wait, cancel, output, and cleanup for the approved minimal specification. Deliver a working isolated end-to-end fixture.

Is blocked by task: SPEED-004.

Acceptance Criteria:

- Implement private rootfs, namespaces, cgroup limits, credentials, capability
  restrictions, and seccomp for the declared supported configuration.
- Confirm exec separately from application readiness and return actual exit status.
- Supervise children, bound output, cancel safely, and acknowledge complete cleanup.
- Reject unsupported options and avoid duplicate starts on ambiguous disconnections.
- Successful and failed launches leave no orphan process, mount, or cgroup.

Problem and Evidence: The spec increment adds a closed native launch request and
validates the digest, canonical root-relative paths, environment,
credentials, network mode, and resource limits before allocation. The original transport-only service still rejects fresh
execution. A separate, explicitly selected disposable-guest mode advertises
its restricted fresh fixture capability.
Fifteen Rust tests, scoped Clippy, and the Linux ARM64 cross-check passed.
Logs are in `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-005/spec`.
The kernel fixture created a private cgroup v2 mount in the disposable
ARM64 guest, installed memory, pids and CPU controls on a workload leaf,
created a namespaced child with `clone3` and `CLONE_INTO_CGROUP`, obtained a
pidfd, and reaped the child. It verified that the cgroup was empty and
removed the leaf and mount before guest poweroff. Production observations
matched. The binary was built with the pinned ARM64 musl compiler image.
The first musl attempt caught a signedness mismatch in `statfs.f_type`
that the GNU target had accepted. The corrected native boot report,
commands, hashes and failure log are retained under `SPEED-005`.

The next fixture executed a static ARM64 application in an isolated
namespaced child with the private overlay root, closed stdin, descriptor
closure, bounded resource limits, UID/GID 65532, no supplementary groups,
empty capabilities, no-new-privileges and the ARM64 seccomp allowlist.
The kernel confirmed exec. The executed application verified its
credentials and empty capabilities, could not see an outside canary,
wrote to its private upper layer, and received EPERM creating AF_VSOCK.
The fixture reaped the child and verified that the lower root was
unchanged. The cgroup and mount were removed and the guest powered off.
The isolated ARM64 report and production snapshots are retained in
`SPEED-005/sandbox-fixture`. Prior failures preserve the overlay denial
before switching to mapped setup credentials and the early process
failure before explicitly allowing the fd-poll syscall used at startup.
Linux-target Clippy passed.

The service resolves one root-owned ARM64 fixture manifest and checks its
staged executable's SHA-256 before accepting launches. The fresh mode
supports one active workload and one retained record. Over authenticated
VSOCK it verifies kernel exec independently of application output, returns
the exit code or signal, and reports removal only after the helper has
reaped the child and confirmed cleanup. It rejects unverified executables,
returns the original handle for identical retried requests, and rejects
conflicting and superseded sequences. A disconnected client can reconnect
and cancel the same workload. Tests verify nonzero exit, replay protection,
cleanup, and successful reuse of the workspace after failures.

Evidence: `cargo fmt --all -- --check`, `git diff --check`,
`cargo test --locked -p conjet-launch-service` (16 passed), and
`cargo clippy --locked -p conjet-launch-service --all-targets --target aarch64-unknown-linux-gnu -- -D warnings`
passed with ExternalSSD target directories. The pinned ARM64 musl build,
verified manifest and executable hashes, replay commands, raw VSOCK frames,
serial log, and production observations are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-005/fresh-service`.
Earlier attempts are retained separately, including the raw-clone trace
identity failure and the private cancellation socket reset.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[guest init](../../guest/init/conjet-init.c).

Review: Reviewed the single-helper ownership path, the identity and isolation
checks applied before exec, exit collection, output limits, and the boundary
between exit and removal. This fixture uses its pinned executable and a
closed no-network workload shape. General OCI image admission, restart
reconciliation, and stage-by-stage cleanup fault coverage remain outside this
fixture's qualified envelope. Production was observed without interaction.

Next Action: Begin SPEED-006 with named resource ownership and recovery tests.

### SPEED-000

Title: Build and prove the isolated conjet-speedup environment

Description: Deliver a session-scoped launcher under build-support/ and
`docs/engineering/speedup-environment.md` with setup, run, benchmark, and cleanup
commands for separate branch-built Conjet, conjetd, and Core processes.

Is blocked by task: None.

Acceptance Criteria:

- Separate CONJET_HOME, speedup profile, private DOCKER_CONFIG, mutable disks,
  locks, logs, sockets, and branch-built executables are verified at runtime.
- The private Docker context is named conjet-speedup; a test container reaches
  its VM and cannot be confused with the production context.
- Production PIDs, health, context endpoint and selected context remain unchanged;
  no app runtime binding, global socket link, builder, DNS, or startup registration changes.
- Launcher rejects executable fallback, production path overlap, endpoint mismatch,
  port collisions, and conflicting inherited Docker endpoint variables.
- Pinned Kiri uses ExternalSSD test data, a private Docker configuration and
  explicit endpoint. Per the user-approved scope, official settings may remain
  in ~/.kiri and official host shares remain; do not claim full filesystem confinement.
- Normal exit, cancellation, and startup failure stop owned processes and remove
  transient sockets/mounts. Retain explicitly managed test data, private contexts,
  and selected evidence for reuse; document their removal separately.
- Smoke comparison records engine identities and production background load;
  final clean benchmark qualification is not inferred from a contaminated run.

Problem and Evidence: CONJET_HOME and CONJET_PROFILE isolate runtime paths, but
CLI startup uses makeCurrent: true for Docker context creation. Shared Docker
configuration or installed-binary fallback could alter the production context.

Approach:

1. Audit startup, executable resolution, configuration persistence, network ports,
   and teardown; implement a fail-closed launcher with a private environment and
   task-owned resource manifest.
2. Build/stage isolated binaries, start separate processes under session ownership,
   create conjet-speedup in private Docker configuration, and prove routing with
   a disposable fixture plus before/after production observations.
3. Verify Kiri isolation and explicit endpoints, run a smoke comparison, exercise
   failure/cancellation cleanup, and document reproducible commands in the runbook.

Evidence: The branch baseline was `8e5144683e3cb9bc89dd60a11d81585ec94ebd98`.
Installed production Docker responded as 29.1.3 and kept its `conjet`
context. The initial candidate boot reached PSCI CPU_ON but failed with
`hv_vcpu_set_pending_interrupt = HV_UNSUPPORTED`; the failure and matching
production snapshots are retained in `initial-hvf-failure/session.json` and its VM logs
under the SPEED-000 evidence root. The local Hypervisor SDK declares this call
unsupported with a GIC. The correction uses the existing GIC SPI and
redistributor injection paths and preserves their error handling.

The corrected candidate ran the pinned ARM64 Alpine no-network fixture at
two vCPUs and 2,048 MiB. `smoke/session.json` records the staged executable
hashes, live process paths, Docker socket peer PID, context endpoint, VM paths,
production before/after observations, and background load. Official Kiri 0.2.2
ran the same pinned Alpine digest separately. Its evidence is retained in
`conjet-speedup-kiri/pinned-smoke-session.json`. No performance gate ran.

The native SwiftPM build and 38 focused Swift tests passed. Jetstream ran 133
tests successfully with three ignored using Apple's system archiver. The
default SwiftPM build failed in SwiftTerm's Metal step, and the GNU archiver
produced an unaligned archive for the Rust test link. Commands and workarounds
are in the [environment runbook](speedup-environment.md). Candidate artifacts
and command logs are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-000`.

SIGTERM during asset import returned 143 and the observed gzip child exited.
SIGTERM during the verified VM session returned 143 and left no staged
processes or sockets. A test VMM that exited 27 during startup produced a
failed session and clean shutdown. A conflicting inherited `DOCKER_HOST`
was rejected before launch. The candidate run left no private mounts.
Disposable session directories and disks were removed after evidence capture.
Verification used machine-readable terminal and daemon evidence for this
headless launcher.

Source: [Isolated environment](speed-engineering-plan.md#isolated-speedup-environment),
[paths](../../Sources/ConjetCore/ConjetPaths.swift),
[environment](../../Sources/ConjetCore/ConjetEnvironment.swift),
[CLI context configuration](../../Sources/ConjetCLI/main.swift).

Review: The launcher uses a fresh private profile, verifies the daemon peer
before sending commands, validates imported asset paths before starting a VM,
and verifies that the candidate VMM owns the Docker socket before invoking the
fixture. Production health, endpoints and fingerprints matched in success,
startup failure, and cancellation. The launcher removes residual socket entries
only after confirming the staged runtime exited.

Next Action: Begin SPEED-001 with process tracing and a post-exec fixture.

### SPEED-001

Title: Correct process-start events and add a readiness fixture

Description: Update the guest event producer and host decoder; add a fixture that signals readiness only after exec. Deliver trace-schema documentation and failure-path tests.

Is blocked by task: SPEED-000.

Acceptance Criteria:

- Current post-fork notification is not reported as successful application execution.
- Missing executable, permission failure, and early process exit produce accurate outcomes.
- End-to-end timing uses one host monotonic clock; guest durations remain separate.
- Trace schema and benchmark methodology document endpoints and instrumentation overhead.

Problem and Evidence: `guest/init/conjet-init.c` reports PROCESS_STARTED after
fork before exec success; the existing timeline labels T6 as first instruction.

Approach:

1. Trace PROCESS_STARTED from guest/init/conjet-init.c through its host decoder and replace the false exec-success interpretation.
2. Add distinct child-created, exec-confirmed, application-ready, and exec-failed outcomes; retain compatibility for existing event consumers.
3. Run a valid executable, missing path, non-executable file, and immediate exit; verify each trace and measure tracing overhead.

Evidence: The active Rust VMM had no receiver for guest-initiated readiness
connections, and the Rust CLI boot command rejected the benchmark's
`--timeline-jsonl` argument. The host increment adds an explicit
`--trace-guest-readiness` flag, bounded v1 VSOCK reception, separate host and
guest timestamps, and labels the legacy event as a launch observation.

Built and signed the branch VMM, then ran `jetstream boot` with the isolated
Core 1.3.1 manifest, two vCPUs, 2,048 MiB, 25 ms host tick,
`--require-docker-ready --hold-after-ready-ms 1000 --trace-guest-readiness
--json`. Docker reached readiness and the host collected `control_ready` and
`legacy_process_started` records with the same guest boot ID and ordered host
offsets. The first decode attempt rejected the appliance producer's
`VMADDR_CID_ANY` envelope. The corrected decoder validates the transport
CID and accepts that existing envelope marker.

Raw reports, production observations, the VMM hash, and Cargo and Swift test
logs are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-001/host-decoder`.
Two Swift StartupTimeline tests and 135 Rust tests passed, with three Rust
tests ignored. The published Docker guest emitted legacy markers only.

Built the static ARM64 Pulse init on the verified candidate Docker endpoint
using Alpine's GCC 14.2.0 and musl. The guest boot fixture proved control,
child creation, exec confirmation, application readiness, and normal exit.
A missing executable returned errno 2 and exit 127. A non-executable file
returned errno 13 and exit 127. An early exit confirmed exec and returned
status 23 with no application readiness. Production observations matched.
The focused Swift guest, initramfs, and timeline suites passed 33 tests.

Ten alternating pairs measured host-monotonic VMM invocation through guest
poweroff, with the same fixture and host collector enabled in both arms.
Guest tracing added a median 0.693 ms, with paired differences from -5.342
to +5.425 ms on this shared host. An initial run had a median of -0.969 ms.
Boot variance prevents a precise estimate of the tracing cost. Raw
reports, compiler details, hashes and the replay scripts are under the
SPEED-001 evidence root in `guest-fixtures` and `initial-guest-fixtures`.
The restored `conjet-bench startup-trace` ran against the isolated
fixture with `--early-console-only --trace-guest-readiness`. It retained
ordered T0, T1, T7 JSONL and a full boot response with all five expected
guest events. Both CLI and benchmark builds passed, and all 45 benchmark
package tests passed. Exact arguments and output are under
`timeline-adapter`. Production observations matched for the final run.

Source: [Measurement contract](speed-engineering-plan.md#measurement-contract),
[guest init](../../guest/init/conjet-init.c),
[timeline](../../Sources/ConjetCore/StartupTimeline.swift).

Review: Host increment reviewed for bounded frames, guest port and stream
validation, legacy event classification, and clock boundaries. The boot
report retains the legacy markers as guest observations. Guest review
confirmed exec from the kernel event and fixture readiness from the
inherited descriptor, and verified errors and early exit in raw reports.
The benchmark adapter uses host monotonic time for CLI intervals and
keeps raw guest timestamps separate. The underlying timed subprocess
boundary is documented. Runtime checks were headless and verified through
raw event streams and process observations.

Next Action: Begin SPEED-002 with a pinned and endpoint-verified fresh
lifecycle harness.

### SPEED-002

Title: Add and run the fresh-lifecycle baseline harness

Description: Extend benchmarks/ with pinned scenarios and explicit runtime endpoints. Deliver baseline JSON and a report for both engines.

Is blocked by task: SPEED-001.

Acceptance Criteria:

- Pin engine revisions, images, kernels, hardware, resources, cache state, and network mode.
- Distinguish API-visible removal from cleanup completion and exclude no failed samples silently.
- Preserve raw samples, stage traces, p50/p95/p99, CPU, footprint, and throughput.
- Record an initial baseline and predeclare comparison margin/statistical method;
  do not claim superiority from unmatched published figures.

Problem and Evidence: Kiri's published 2.55 ms result does not include Conjet;
its exit notification and cleanup boundaries differ.

Approach:

1. Use the SPEED-000 private conjet-speedup and verified Kiri endpoints; add scenario manifests for native ARM64 Alpine true with no-network and bridge modes, using the same image digest and resource limits.
2. Measure API create/start/wait/remove and CLI invocation separately; record API removal and observable cleanup independently.
3. Run isolated baseline sessions and write configuration, raw samples, failures, and percentiles under benchmarks/reports/; mark cleanup unknown if it cannot be observed.

Evidence: `benchmarks/fresh-lifecycle.py` and the pinned scenario ran
100 measured operations and 10 warmups per engine per network and lane,
with zero fixture failures across the completed sessions. The M1 Pro host
ran production Conjet throughout. Both engines used the same ARM64 Alpine
configuration ID, host Docker client and API 1.44. Guest kernels were
`6.12.86-conjet` and `6.18-kiri`. The launchers allocated two vCPUs and a
2,048 MiB ceiling to each engine.

No-network API p50/p99 was 396.837/479.683 ms for Conjet and 3.773/5.058 ms
for Kiri. Bridge API p50/p99 was 493.304/567.220 ms and 34.437/63.064 ms
respectively. The selected report contains both CLI lanes, stage latencies,
throughput, CPU and memory observations, image and binary digests, and all
raw samples. Kiri's initial footprint snapshot covered its Docker peer
only. Its final snapshot also identified the VM process by the private disk.

Report and selected raw captures are under
`benchmarks/reports/speed-002-initial/`. Commands, launcher evidence,
failed attempts, and the report renderer are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-002`.
The initial API 1.41 attempt failed Conjet negotiation. A subsequent slow
candidate run was interrupted and its partial evidence was retained.
The complete run used API 1.44 and reported progress by group.

Five fixture accounting and cleanup tests and Ruff passed. The official
Kiri smoke passed. SIGTERM during the Kiri benchmark retained the partial
report, recovered one labeled fixture, and stopped its VM and daemon.
No socket or disk holder remained. Production observations matched.
This headless benchmark used raw evidence and has no screenshot surface.

Source: [Verification policy](speed-engineering-plan.md#verification-and-claim-policy),
[benchmark methodology](../benchmark-methodology.md),
[Kiri results](https://github.com/libracoder/kiri/blob/0de1837588eed54c945890f955ef861f2da71cc4/bench/results.json).

Review: Endpoint and CLI identities were revalidated, and both engines
completed the same pinned Docker work. The benchmark preserves failure and
abort records. API removal and guest cleanup are explicit separate fields.
Guest cleanup is unknown in this initial baseline, and the single-host
samples do not establish a competitive result. The comparison margin and
paired-session statistical method were declared before the completed runs.

Next Action: Begin SPEED-003 with a native launch protocol and lifecycle
ownership contract.

### SPEED-003

Title: Write the launch-service protocol and lifecycle specification

Description: Create docs/engineering/launch-service-contract.md with the message schema, state transitions, ownership rules, and initial supported options.

Is blocked by task: SPEED-002.

Acceptance Criteria:

- Specify one lifecycle owner, request IDs, cancellation, disconnect/retry behavior,
  recovery, and exactly-once slot consumption without promising exactly-once external side effects.
- Define supported OCI options and reject unsupported configurations before resource creation.
- Define authentication, bounded frames/queues/output, handles, generations, and error semantics.
- Document state transitions, child-creation safety, cgroup layout, and cleanup ownership.
- Keep the existing Docker lane explicit; prohibit silent mixed-engine ownership.

Problem and Evidence: Existing direct-OCI support is limited and lacks the proposed
reusable supervisor; an ambiguous retry could execute user work twice.

Approach:

1. Specify handshake, launch, cancel, status, output, exit, and cleanup messages with request IDs, deadlines, maximum sizes, and errors.
2. Define states from accepted through removed, and behavior for duplicate requests, disconnected clients, and service restart.
3. Specify a native ARM64 no-network feature matrix, cgroup ownership, and a safe child-creation model; reject all other options explicitly.

Evidence: [Launch service contract](launch-service-contract.md) defines
the dedicated VSOCK lane, 16 message types, mutual per-VM authentication,
deadlines and quotas, native ARM64 feature matrix, Linux execution and cleanup,
and recovery across connection and service loss. Verified all local links,
the contiguous message kind assignments, and `git diff --check`. The contract
uses the Linux `clone3`, pidfd and cgroup v2 interfaces documented in its
references.

Source: [Architecture](speed-engineering-plan.md#architecture-and-ownership),
[OCI loader](../../Sources/ConjetCore/ConjetContainerRuntime.swift),
[binary framing](../../Sources/ConjetCore/ConjetBinaryFrame.swift).

Review: Checked that queue and output limits are explicit, that retries
cannot readmit an evicted sequence, and that guest restart reconciles only
native-owned resources. The contract separates exec, application readiness
and cleanup. It binds claims to the declared native scope and leaves Docker
lifecycle ownership with the Docker engine.

Next Action: Begin SPEED-004 with the frame codec, authenticated persistent
VSOCK handshake, and bounded control request loop.

### SPEED-004

Title: Implement the VSOCK service handshake and bounded request loop

Description: Add a Rust guest-service skeleton and native host client using the approved contract. Deliver an isolated round-trip fixture without application execution.

Is blocked by task: SPEED-003.

Acceptance Criteria:

- Versioned, bounded protocol implements handshake, capability discovery, errors,
  deadlines, cancellation, and orderly shutdown.
- Unauthorized, malformed, oversized, disconnected, and saturated requests are tested.
- Guest supervision never runs under VMM device-processing locks.
- Round-trip measurements and service resource costs are recorded without busy polling.
- Disposable QA resources are cleaned up; no installed service registration changes.

Problem and Evidence: Existing VSOCK machinery provides transport, but the proposed
launch protocol and guest supervisor are not implemented.

Approach:

1. Implement version negotiation, capability reporting, request IDs, framing limits, deadlines, and shutdown over persistent VSOCK.
2. Add malformed-frame, unauthorized-client, queue-full, timeout, and disconnect tests.
3. Run the fixture in a disposable VM, record round-trip latency and resource use, then verify shutdown and cleanup.

Evidence: Added a pinned Rust launch-service crate with a 28-byte v1
frame codec, a pre-allocation payload bound, typed JSON, and mutual
HMAC-SHA256 authentication. Seven tests passed via
`cargo test --locked -p conjet-launch-service`, including an independent
HMAC vector, a persistent socket-pair handshake, replay rejection, peer
rejection, oversized frames and truncation. The scoped Clippy command
`cargo clippy --locked -p conjet-launch-service --all-targets -- -D warnings`
passed. Logs are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-004/codec`.
The transport increment added the Linux AF_VSOCK listener on port 2380,
a native Darwin client, an opt-in private Jetstream listener, and bounded
control handling. `cargo test --locked --workspace` passed 149 tests with
three existing opt-in integration tests ignored. Linux ARM64 cross-check
and scoped Clippy passed. The builder compiled a static ARM64 release
binary in the verified candidate using pinned Rust 1.91.1 Alpine and
`--target aarch64-unknown-linux-musl`. The first build failure and the
ad-hoc signing repair are retained alongside successful build logs.

In the isolated 512 MiB, two-vCPU VM, the live host fixture proved wrong
peer rejection, oversized and malformed frames, wait deadlines, full
wait and connection queues, cancellation, disconnect, and authenticated
shutdown. The shutdown acknowledgement was followed by VMM exit and
native socket removal. Production observations matched, and the runtime
roots and ephemeral key were removed. Existing Docker smoke passed with
the updated VMM. Results are in `SPEED-004/transport` under the retained
evidence root. Replay commands identify the kernel, VMM, host client and
guest binary by hash.

Across 100 control pings, p50/p95/p99 were 0.197/0.329/29.171 ms with a
39.349 ms handshake. The prior 100-ping run recorded 0.345/0.427/0.495 ms.
The larger p99 stays in the evidence. The final guest service reported
4.022 ms user CPU, 32.177 ms system CPU, and 472 KiB peak RSS across the
fixture session. VMM footprint was 32,457,520 bytes before the ping loop
and 31,572,784 after it. The measurements cover a transport fixture on
the shared host. The headless fixture produced raw records and no UI.

Source: [Architecture](speed-engineering-plan.md#architecture-and-ownership),
[VSOCK device](../../jetstream/src/devices/vsock.rs).

Review: Frame header and declared length are checked before payload
allocation. The transcript binds both role proofs, version negotiation,
peer nonces and the boot generation. The guest and host reject each other's
invalid proof before lifecycle traffic. Bounded pending waits and connections passed both unit and live tests.
Guest waits block in the kernel. The new host listener uses a wakeable
poll and joins on teardown. The live tests identified and fixed Docker
HTTP inference on native frames, raw EOF propagation, and the shared-VM
state lifetime that initially delayed listener cleanup. Docker retains
its existing bridge path.

Next Action: Begin SPEED-005 with the validated launch spec and the
isolated fresh execution path.

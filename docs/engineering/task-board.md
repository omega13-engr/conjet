# Conjet speed engineering task board

Architecture: [speed engineering plan](speed-engineering-plan.md).

## Working rules

- Each task must deliver the artifact or behavior named in Description. Complete
  Approach steps in order and record commands, results, and artifact paths in Evidence.
- Work sequentially by task ID; move a task between sections rather than copying it.
- Start only when dependencies are DONE with review evidence. Each implementation
  task includes focused automated checks, diff review, and resource cleanup.
- Evidence is pending until actual commands, results, revisions, configurations,
  and artifact links are recorded. Targets are not benchmark results.
- UNDERREVIEW requires an implementation and verification evidence; DONE requires
  acceptance criteria and review to pass. Record blockers and failed experiments.
- A no-go at a research gate blocks downstream work until the plan is revised;
  do not weaken acceptance criteria merely to obtain a passing result.
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
- Open the PR to `main` only after SPEED-000 through SPEED-012 are DONE and all
  required final benchmark, correctness, compatibility, and review gates pass.
  Missing hardware coverage, skipped required checks, and failed speed targets
  remain blockers under this workflow; any scope change must be explicit.
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

## BACKLOG

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

Evidence: Pending reproducible failure matrix, test results, recovery traces, and leak inventories.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[verification policy](speed-engineering-plan.md#verification-and-claim-policy).

Review: Pending; qualify cancellation races, PID reuse, recovery, and resource ownership.

Next Action: Add allocation-stage failure hooks and a resource-inventory assertion to the isolated harness.

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

Evidence: Pending network integration results, concurrent traffic checks, and cleanup traces.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[measurement contract](speed-engineering-plan.md#measurement-contract).

Review: Pending; inspect identity reuse, DNS/port cleanup, and concurrent teardown.

Next Action: Define the bridge-mode resource inventory and implement allocation/rollback.

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

Evidence: Pending raw comparative reports, profiles, and recorded gate decision.

Source: [Delivery gates](speed-engineering-plan.md#incremental-delivery-and-decision-gates),
[verification policy](speed-engineering-plan.md#verification-and-claim-policy).

Review: Pending; assess causal attribution, regressions, and whether preparation remains worthwhile.

Next Action: Run the no-network baseline scenario against the qualified candidate and retain its raw trace.

### SPEED-009

Title: Implement prepare, claim, expire, and destroy for one-use slots

Description: Add explicit prepared-launch API operations and a bounded slot table. Deliver state-machine and isolation tests plus preparation/hit/miss measurements.

Is blocked by task: SPEED-008, with a reviewed proceed decision.

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

Evidence: Pending slot state-machine tests, isolation canaries, preparation costs,
and hit/miss latency traces.

Source: [Prepared lane](speed-engineering-plan.md#prepared-launch-lane),
[latency budget](speed-engineering-plan.md#experimental-latency-budget).

Review: Pending; verify one-use semantics, invalidation, hidden pre-execution, and refill accounting.

Next Action: Implement the slot state machine and concurrent one-use claim tests before allocating waiting processes.

### SPEED-010

Title: Connect launch-service cgroups to memory accounting and eviction

Description: Register active workloads and prepared reserves with the memory controller. Deliver pressure-eviction and allocation/free/reuse evidence.

Is blocked by task: SPEED-009.

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

Evidence: Pending memory-ledger snapshots, native/HVF regressions, workload
correctness results, footprint measurements, and eviction traces.

Source: [Memory integration](speed-engineering-plan.md#dynamic-memory-integration),
[memory debugging](../dynamic-memory-debugging.md),
[backing reclamation](../jetstream-host-backing-reclaim.md).

Review: Pending; inspect active-demand classification, pressure races, and unsafe discard counters.

Next Action: Add explicit active-workload and prepared-reserve telemetry to the guest memory snapshot contract.

### SPEED-011

Title: Run the qualification matrix and publish measured verdicts

Description: Create docs/engineering/speed-qualification.md linking raw reports and pass/fail results for each proposed performance claim.

Is blocked by task: SPEED-010.

Acceptance Criteria:

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

Evidence: Pending raw JSON, stage profiles, repeated comparison reports, power
measurements, and a reviewed claim-by-claim verdict.

Source: [Latency budget](speed-engineering-plan.md#experimental-latency-budget),
[claim policy](speed-engineering-plan.md#verification-and-claim-policy),
[benchmark package](../../benchmarks/README.md).

Review: Pending; independently check repeatability, equivalent work, tail latency,
sustainable throughput, and memory/energy tradeoffs.

Next Action: Freeze the candidate revision and qualification scenario manifest before collecting results.

### SPEED-012

Title: Expose the qualified native launch mode and document release scope

Description: Integrate the passing native API, CLI, and status behavior; deliver E2E evidence, rollback instructions, and an explicit Docker-integration decision.

Is blocked by task: SPEED-011, with a reviewed go decision for the shipped behavior.

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

Evidence: Pending final diffs, automated results, UI screenshots, compatibility
matrix, rollback check, and release-scope decision.

Source: [Architecture ownership](speed-engineering-plan.md#architecture-and-ownership),
[final recommendation](speed-engineering-plan.md#final-recommendation),
[repository instructions](../../AGENTS.md).

Review: Pending; assess product behavior, compatibility, runtime ownership,
performance claims, and operational cleanup separately.

Next Action: Select the configurations that passed SPEED-011 and map them to native API, CLI, and status changes.

### SPEED-013

Title: Open and qualify the speed enhancement PR to main

Description: Submit the completed enhancement with its final benchmark and
correctness evidence, then resolve review and CI findings before merging.

Is blocked by task: SPEED-012 and all required final gates COMPLETE and PASSED.

Acceptance Criteria:

- SPEED-000 through SPEED-012 are DONE with passing evidence and pushed commits.
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

Evidence: Pending gate audit, remote revision, PR URL, CI results, and merge revision.

Source: [Qualification policy](speed-engineering-plan.md#verification-and-claim-policy),
[release process](../release.md).

Review: Pending; verify all development gates before opening the PR and all CI
and review requirements before merge.

Next Action: Audit SPEED-000 through SPEED-012 after their final passing evidence is available.

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

Evidence: Pending version decision, packaging QA, signed artifact checks, tags,
workflow URLs, published checksums, and release URLs.

Source: [Release process](../release.md), [Homebrew](../homebrew.md),
[repository instructions](../../AGENTS.md).

Review: Pending; verify production artifact readiness, version/tag consistency,
asset compatibility, and evidence supporting every release claim.

Next Action: After the PR merges, inspect current versions and release workflows to select the release scope.

## INPROGRESS

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
credentials, network mode, and resource limits before allocation. Valid
requests still receive an unavailable response until fresh execution is
wired. The service advertises its transport fixture capabilities only.
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

Verified image admission and service-level launch, output, cancellation,
wait, idempotency and cleanup reporting remain pending. Fresh execution
is still unavailable on the service endpoint.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[guest init](../../guest/init/conjet-init.c).

Review: Request validation reviewed for closed fields, path ambiguity, privilege options, and request bounds. Pending execution review; inspect syscall/FFI safety, isolation, limits, exec errors, and teardown.

Next Action: Implement resource allocation with rollback for a single no-network launch.

## UNDERREVIEW

None.

## DONE

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

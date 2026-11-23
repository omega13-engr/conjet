# Conjet speed engineering task board

Architecture: [speed engineering plan](speed-engineering-plan.md).

Current iteration: [native-default Docker speed plan](native-docker-speed-plan.md).

## Current native-default priority

The user directs the next iteration to improve the overall Docker experience on
the new native architecture. SPEED-027 through SPEED-045 are the active sequential
implementation and qualification path. SPEED-027 starts from completed SPEED-018;
the following new tasks depend on their preceding task. Candidate measurements
must use release-optimized native Conjet selected by default in conjet-speedup.
There is no experimental opt-in requirement for this isolated candidate and no
silent legacy backend fallback. The installed production runtime stays untouched.

SPEED-019 through SPEED-026 retain their existing status and historical evidence.
Their old Next Action lines do not authorize resuming legacy repetitions:
new native measurement work is assigned to SPEED-040 through SPEED-044 and the
report audit to SPEED-045. SPEED-020's completed legacy image evidence remains
under review as historical evidence, not proof of native image support. Do not
mark superseded or deferred work DONE merely because the new sequence exists.
SPEED-008 remains deferred research. SPEED-013/014 review and release requirements
remain intact; promoting the expanded native default additionally requires the
new compatibility and qualification audit. Preserve the exact recent detailed
report table formats, percentile units, paired intervals and failure evidence.

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
and their semantics are verified. SPEED-018 defaults to native routing inside
the isolated `conjet-speedup` launcher. Wider promotion requires separate
compatibility evidence.

## BACKLOG

### SPEED-027

Title: Trace the release native Docker CLI critical path

Description: Add diagnostic timing to the current adapter and a single-run transcript collector.

Is blocked by task: SPEED-018 (DONE); uses the frozen release comparison at cabbea9. Does not wait for legacy benchmark completion.

Acceptance Criteria:

- Capture negotiation, create, attach headers, start, native admission, terminal state, output EOF, wait response and client exit for pinned Alpine true and a stdout/stderr exit-23 canary.
- Record request counts, connections, thread handoffs and monotonic host spans; keep guest clocks separate. Compare direct API and CLI traces and quantify tracing overhead.
- Publish a ranked latency attribution with measured spans and unresolved gaps; do not attribute the whole CLI deficit to Python without evidence.

Problem and Evidence: Release API median already leads Kiri, while CLI median trails by 7.6%; the remaining ~1–2 ms is not yet attributed.

Approach:

1. Instrument the existing native Docker handler and collect one diagnostic pair plus untraced controls.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Built the optimized Swift CLI, Jetstream and ARM64 musl guest
with the environment runbook commands from `cf0a94e`. Ran
`python3 build-support/run-conjet-speedup.py --diagnostics {control,trace}`
with the pinned release assets in control/trace/trace/control order, then
`python3 benchmarks/native-docker-diagnostic.py` on the four output folders.
All 704 operations (640 measured, 64 warmups) verified unique native workload
IDs and completed cleanup. Each CLI canary checked exact streams and exit code.
`python3 benchmarks/test-native-docker-adapter.py` passed four tests.
Build logs, artifact hashes, complete command vectors, observations and
cleanup records are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-027`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[diagnostic results](docker-benchmark-results.md#speed-027-native-docker-critical-path-diagnostics),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated runtime checks passed. Trace capture is opt-in,
bounded and flushed after handler shutdown. All four launchers verified unchanged
production and removal of the owned VM session and Docker socket. This is a
headless diagnostic and uses JSON evidence. Independent PR review is separate.

Next Action: Reuse the authenticated connection in SPEED-028 and repeat both
diagnostic canaries to measure the change in handshake count and latency.

### SPEED-028

Title: Reuse a boot-bound authenticated native channel

Description: Change the adapter connection owner to reuse its native channel across sequential Docker launches.

Is blocked by task: SPEED-027.

Acceptance Criteria:

- Authenticate once per verified boot generation; retain operation identity and sequence checks and explicit channel ownership.
- Test idle reuse, guest reboot, disconnect before and after admission, cancellation and timeout. Never resubmit an ambiguous Launch; reconcile or fail closed.
- Compare handshake count and authentication span against SPEED-027 using the same canaries; reject a latency improvement that weakens isolation or increases unbounded resource use.

Problem and Evidence: Native.execute currently connects and authenticates for each launch; the measured authentication span is about 0.45–0.48 ms.

Approach:

1. Implement a bounded connection lease and boot-generation invalidation tests.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Used the `cf0a94e` release artifacts from SPEED-027 with the
updated adapter on `a4c5c8c`. Ran
`python3 build-support/run-conjet-speedup.py --diagnostics trace` three times
with the pinned release assets and summarized with
`python3 benchmarks/native-docker-diagnostic.py`. All 528 operations passed
with one authenticated connection per boot and unique native workload IDs.
The final boot reused the channel after 11 seconds idle. The six tests in
`python3 benchmarks/test-native-docker-adapter.py` passed, including injected
disconnect before reply, disconnect after admission, timeout, different
boot generation, and cancellation without replay. Exact commands, hashes,
observations and cleanup are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-028`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated runtime checks passed. One lease owns the
authenticated socket until shutdown or failure. Any failed exchange closes it
and preserves the pending launch identity. The adapter does not reconnect or
replay. The launcher verified guest cleanup, socket removal, and unchanged
production for all three boots. Fault injection used the adapter transport
boundary. Independent PR review is separate.

Next Action: Add bounded terminal output delivery in SPEED-029. The two
post-cleanup stream requests remain on every launch.

### SPEED-029

Title: Deliver terminal output without redundant round trips

Description: Add one bounded terminal/output delivery contract between the native guest client and Docker owner.

Is blocked by task: SPEED-028.

Acceptance Criteria:

- Reduce separate stdout/stderr fetch requests where terminal metadata or streaming can deliver them safely; include explicit EOF, exit and cleanup fields.
- Verify zero output, mixed streams, 64 KiB boundaries, overflow, slow reader, disconnected attach and nonzero exit.
- Removal remains after verified cleanup; cancellation and capacity reuse do not depend on an attach client consuming bytes. Record request-count and latency changes.

Problem and Evidence: The adapter fetches stdout and stderr after terminal cleanup and only then completes attach; extra requests are confirmed but their cost must be measured.

Approach:

1. Specify bounded terminal/output framing and implement its codec and lifecycle tests.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Rebuilt the release guest and VMM from the SPEED-029
working tree on `7fbc189` and reused the source-identical Swift release CLI.
Ran `python3 build-support/run-conjet-speedup.py --diagnostics trace` twice
with the pinned assets and summarized with
`python3 benchmarks/native-docker-diagnostic.py`. Both boots passed 176 standard
canaries and eight supplemental output and capacity checks each.
Ran `python3 benchmarks/test-native-docker-adapter.py`, guest `cargo test --locked`,
`cargo fmt --check`, and `cargo clippy --locked --target aarch64-unknown-linux-musl -- -D warnings`.
Commands, artifact hashes, tests, raw transcripts and cleanup records are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-029`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and runtime checks passed. Terminal wait carries a bounded
inline prefix and explicit EOF and truncation states. Exact 65,535- and
65,536-byte output passed through the real Docker CLI. Overflow returned an
explicit wait error and retained the observed guest exit. Slow and disconnected
attach clients did not block native teardown, removal or reuse. Both launchers
verified unchanged production and removed their sessions and sockets.
Independent PR review is separate.

Next Action: Port this contract to the Rust host in SPEED-030 while retaining
the Python adapter as the comparison reference.

### SPEED-030

Title: Port the supported Docker owner into the Rust host

Description: Implement the existing supported Docker API contract as a Rust host component, retaining Python as the comparison reference.

Is blocked by task: SPEED-029.

Acceptance Criteria:

- Pass the same request/response fixtures for negotiation, create/start/attach/wait/inspect/remove, errors and duplicate-start prevention.
- Use the persistent channel and terminal contract, bounded connection/admission counts, one lifecycle owner and explicit backend identity; do not add a second VM or legacy fallback.
- Package and launch the Rust owner by default for conjet-speedup without experimental opt-in; verify it needs no Python benchmark modules at runtime.
- Run matched release A/B against the Python reference; preserve timings even if the Rust port is not faster.

Problem and Evidence: The candidate Docker endpoint currently imports Python benchmark code and spawns connection/execution threads; it is not yet a packaged Rust runtime component.

Approach:

1. Create the Rust Docker module and transfer the narrow contract tests before switching the isolated launcher.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Built the release VMM and guest from the SPEED-030 working
tree on `f202be5` and reused the source-identical Swift release CLI. Ran
`python3 build-support/run-conjet-speedup.py --diagnostics control --docker-owner {rust,python}`
in Rust/Python/Python/Rust order with the same pinned release assets. Both
owners passed 176 standard canaries per boot and the shared output, inspect,
unsupported request, capacity, duplicate-start and forced removal checks.
An ordinary launcher smoke selected Rust without diagnostics or an owner
override. Jetstream `cargo test --locked` passed 139 tests with three existing
ignored tests. Rust formatting and Python adapter tests passed. Full
Jetstream Clippy stopped on existing PSCI discriminant and Hypervisor FFI
lints. A diagnostic run allowing those two existing lints completed.
Commands, hashes, initial keep-alive failure, repaired runs, and cleanup
are under `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-030`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and runtime checks passed. The Rust owner binds one
private endpoint, caps admission and request handlers, and holds a single
authenticated guest connection. The launcher confirmed the actual Rust
peer executable and native guest attribution. The default smoke path does
not load benchmark code. All runs verified removal of owned resources
and unchanged production. Independent PR review is separate.

Next Action: Stage a verified two-layer OCI image in SPEED-031.

### SPEED-031

Title: Stage a two-layer OCI image with whiteouts

Description: Extend native image admission from one layer to a pinned two-layer test image.

Is blocked by task: SPEED-030.

Acceptance Criteria:

- Verify manifest/config/compressed and uncompressed layer identities and deterministic layer ordering.
- Test file replacement, deletion whiteouts, opaque directories, symlinks and required hard links; reject traversal, escaping links, malformed archives and unsafe special entries.
- Run a dynamic ARM64 canary from the final immutable root and prove separate writable overlays do not mutate lower layers; failed staging removes owned partial state.

Problem and Evidence: The current single-layer package excludes ordinary multilayer application images needed by builds and Compose.

Approach:

1. Add a deterministic two-layer fixture and negative archive tests, then extend staging.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Built release Jetstream and the ARM64 guest from the SPEED-031
working tree on `4a19b0a`, with source-identical Swift CLI. Generated the
pinned two-layer fixture and ran 14 negative staging cases with
`python3 benchmarks/native-oci-two-layer.py`. Two independent staging runs
produced identical packages. The release launcher with `--diagnostics oci`
verified dynamic execution, inode identity, deletion and opaque whiteouts,
symlinks, writes through hard links, and fresh overlay isolation. Guest and
Jetstream tests, formatting checks, guest Clippy and existing Python
admission tests passed. Full Jetstream Clippy retains the SPEED-030 baseline
errors. Commands, source and artifact identities, failed pilots and verified
live results are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-031`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated runtime checks passed. The archive pipeline
verifies all four digest boundaries and publishes a complete directory
exclusively. Both failed and successful live launchers verified unchanged
production and session cleanup. The final OCI test checked the same inode
for both names, alias mutation within one workload, and original data in
the next workload. The workload retains the existing capability and
syscall restrictions. Independent PR review is separate.

Next Action: Integrate verified root staging with native pull. The current
guest only selects an OCI image at boot. Resolve live image installation
in SPEED-032A before exposing Docker pull.

### SPEED-032A

Title: Install a verified OCI root into an already booted guest

Description: Add a generation-bound, bounded installation path for the pinned
two-layer fixture, with an explicit image identity for launch selection.

Is blocked by task: SPEED-031 (DONE).

Acceptance Criteria:

- On one live native boot, install the staged two-layer fixture through the
  authenticated owner and run its canary with the original boot ID.
- Reject stale boot IDs, invalid offsets, wrong digests, exceeded quotas,
  and removal of a referenced lower root. Verify that interrupted transfers
  create no runnable image and that retries cannot disturb existing roots.
- Preserve original boot image execution, hard-link behavior, independent
  writable overlays, and guest cleanup.

Problem and Evidence: SPEED-031 delivers verified roots at boot. The existing
guest admits exactly one configured digest and uses a fixed OCI lower path.
Docker pull needs a runnable image in an already authenticated guest.

Approach: Add a single bounded transfer lease, verify before publication,
and bind the resulting lower root to the launch image digest.

Evidence: DONE. Rebuilt the release guest and VMM from the working tree on
`0096f36` and reused the source-identical Swift CLI. Ran the private
launcher with `--diagnostics oci-import` and the pinned SPEED-031 fixture.
The Rust installer transferred, verified, and published the package into
the same authenticated boot. The negative cases checked stale generation,
capacity, wrong offset, bad hash, a foreign connection, and disconnect
before commit. Live checks verified referenced-root rejection, removal
after cleanup, rejection of requests for the removed digest without
admission, and original boot-image execution after removal. The imported
fixture's hard-link and writable-overlay canaries passed through Docker.
Formatting, guest and Jetstream tests, guest Clippy, and the Python adapter
tests passed. Jetstream Clippy retains its baseline PSCI and FFI errors.
Exact commands, hashes and launcher evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-032A`.

Source: [Launch service contract](launch-service-contract.md),
[`fresh_fixture.rs`](../../guest/launch-service/src/fresh_fixture.rs),
[`sandbox_fixture.rs`](../../guest/launch-service/src/sandbox_fixture.rs).

Review: Local runtime and diff checks passed. Transfer ownership follows
the authenticated connection and boot generation. Bounds cover image
count, staged bytes, frame size and time. Publication requires a complete
verified package. A lost commit reply requires Inspect rather than replay.
The launchers verified unchanged production and removed their sessions
and sockets. Independent PR review is separate.

Next Action: Integrate this guest protocol with Docker pull and the
ExternalSSD content store in SPEED-032.

### SPEED-032

Title: Implement native image pull, inspect and removal

Description: Connect the native Docker image endpoints to a bounded content-addressed store on ExternalSSD.

Is blocked by task: SPEED-032A.

Acceptance Criteria:

- Pull the pinned small and multilayer fixtures from a task-owned registry; expose verified identity through Docker inspect and launch the pulled image.
- Test cached pull without duplicate extraction, digest mismatch, interrupted download and retry, shared-layer reference counts, and deletion while an image is in use.
- Track image/VM backing paths and remove only unreferenced task-owned content; do not shell out to the existing Docker engine to prepare the candidate image.

Problem and Evidence: Pre-admitted images bypass acquisition; native pull cannot be represented by the historical legacy image timings.

Approach:

1. Implement digest-addressed download/admission and Docker image inspect using the SPEED-031 fixtures.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Built the release Rust owner on `47e7b65` and reused the
source-identical release Swift CLI and guest supervisor. Generated and
verified the pinned registry fixtures with
`python3 benchmarks/native-docker-registry.py`, then ran
`python3 build-support/run-conjet-speedup.py --diagnostics registry`.
Unmodified Docker verified pull, inspect, run and removal for both
fixtures. Corrupted and interrupted transfers retained no partial image.
The cached pull made no registry request and retained the staged package
inode. Pulling and deleting the related image preserved the shared layer,
and deleting the final image freed all fixture blobs. In-use deletion,
mutable references and off-allowlist references were rejected. Jetstream
tests and Rust formatting passed. The existing Clippy errors are recorded
in SPEED-030. Commands, requests, hashes, prior pilot and final evidence
are under `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-032`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated runtime checks passed. Host registry
traffic is confined to the explicit loopback endpoint and the pinned
content is verified before native guest admission. The launcher checked
ExternalSSD backing, native execution, production preservation, and
cleanup of its registry, sockets, guest and image store. The store does
not qualify general registry authorization, tags, or image indexes.
Independent PR review is separate.

Next Action: Separate per-workload guest resource ownership before increasing
admission in SPEED-033.

### SPEED-033A

Title: Give each native OCI workload its own guest resource paths

Description: Scope the writable overlay, cgroup mount and cgroup tree to
one native workload ID before allowing overlapping lifecycle records.

Is blocked by task: SPEED-032 (DONE).

Acceptance Criteria:

- Observe two successive real OCI workloads with different populated
  cgroup and overlay paths derived from their workload IDs.
- Verify complete removal of owned paths after cancellation and failed
  execution. Keep the static fixture's existing recovery paths working.

Problem and Evidence: Until SPEED-032, OCI launches reused the static
fixture's fixed guest overlay directory and cgroup mount and tree.
Overlapping helpers would conflict at those resources.

Approach: Use identity-derived resource paths for native OCI, and assert
their absence before terminal cleanup acknowledges removal.

Evidence: DONE. Rebuilt the release ARM64 guest on `7104f53` and ran
`python3 build-support/run-conjet-speedup.py --diagnostics oci-import`.
The two sequential hold canaries each observed a populated cgroup and
present overlay at their distinct paths, then verified cancellation and
cleanup. A missing executable returned failed exec and completed cleanup.
The subsequent Docker hard-link and writable-overlay canaries passed.
Guest formatting, tests and ARM64 Clippy are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-033A`,
along with launcher commands, hashes, and raw witnesses.

Source: [Launch service contract](launch-service-contract.md),
[`kernel_fixture.rs`](../../guest/launch-service/src/kernel_fixture.rs),
[`sandbox_fixture.rs`](../../guest/launch-service/src/sandbox_fixture.rs).

Review: Local diff and isolated runtime checks passed. Both successful and
recovery paths address the exact workload ID. The launcher verified unchanged
production and removed its guest and socket. The owner still admits one
workload. Independent PR review is separate.

Next Action: Bound independent intent and terminal records, scope recovery
to the owning helper, and qualify simultaneous admission in SPEED-033.

### SPEED-033

Title: Replace the single workload slot with bounded lifecycle records

Description: Implement native create/start/wait/stop/kill/restart/remove for up to eight admitted containers.

Is blocked by task: SPEED-033A (DONE).

Acceptance Criteria:

- Give each workload independent rootfs, cgroup, handle, output and cleanup state; bound metadata retention and return explicit capacity errors.
- Test concurrency 1/2/4/8, name conflicts, create without execution, start replay, stop timeout, kill, restart with a new execution generation and forced removal.
- Reconstruct or safely invalidate records after VM/channel loss without duplicate execution; no mount/cgroup/process leaks and no cross-workload data access.
- Support only fixture-required credential and syscall extensions, with negative privilege tests; never enable unrestricted guest-root execution as a shortcut.

Problem and Evidence: One active workload cannot run Compose dependencies, persistent services or a BuildKit worker with application checks.

Approach:

1. Implement the bounded record table and per-record lifecycle transition tests.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-033`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Implement the bounded record table and per-record lifecycle transition tests.

### SPEED-034

Title: Add native exec and bounded live attach/log streams

Description: Implement Docker exec and streaming output for one running native service fixture.

Is blocked by task: SPEED-033.

Acceptance Criteria:

- Use the existing exec/control fixture with matching argv, environment, cwd and supported credentials; preserve stdout/stderr and actual exit status.
- Deliver output before process completion with bounded buffers and backpressure; test slow/disconnected readers, cancellation and overflow reporting.
- Verify container survival after exec failure, multiple bounded exec requests, and cleanup of exec children on container removal.
- Implement only the noninteractive stdin/TTY behavior declared in the fixture contract; reject unsupported options rather than returning synthetic success.

Problem and Evidence: Persistent exec and live output are absent from the native Docker subset and are part of everyday Docker use.

Approach:

1. Add a long-lived native fixture and exec protocol tests before wiring Docker exec endpoints.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-034`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Add a long-lived native fixture and exec protocol tests before wiring Docker exec endpoints.

### SPEED-035

Title: Connect native containers to one private bridge and DNS

Description: Wire the verified guest bridge implementation to native Docker network ownership.

Is blocked by task: SPEED-034.

Acceptance Criteria:

- Run two pinned native containers on a task-owned bridge and resolve one service name to the other; verify DNS and a TCP transaction.
- Expose the required create/connect/disconnect/inspect/remove network operations and aliases; reject unsupported network options.
- Test allocation rollback, address reuse, concurrent cleanup and namespace isolation. Confirm removal of owned veth, routes, addresses and DNS records.
- No legacy networking owner or production interface may satisfy the fixture.

Problem and Evidence: The source bridge research does not yet implement Docker or Compose network ownership on the native endpoint.

Approach:

1. Add a two-container DNS/TCP integration fixture and attach it to the native lifecycle state machine.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-035`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Add a two-container DNS/TCP integration fixture and attach it to the native lifecycle state machine.

### SPEED-036

Title: Publish one native container port on host loopback

Description: Implement a scoped loopback port mapping for the Node/Redis application fixture.

Is blocked by task: SPEED-035.

Acceptance Criteria:

- Map an allocated 127.0.0.1 host TCP port to the native application; verify HTTP response contents and Docker inspect metadata.
- Test bind conflict, refused destination, client disconnect, half-close and container restart/removal; bound connections and buffered bytes.
- After removal, verify listener closure and immediate port reuse. Do not use wildcard binds or change production port mappings.

Problem and Evidence: Compose readiness and host-facing application performance require a real native published-port path.

Approach:

1. Implement the task-owned loopback TCP mapping and teardown fixture.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-036`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Implement the task-owned loopback TCP mapping and teardown fixture.

### SPEED-037

Title: Mount a named volume and an allowlisted ExternalSSD bind

Description: Implement the two storage modes required by the existing storage and Compose fixtures.

Is blocked by task: SPEED-036.

Acceptance Criteria:

- Preserve a checksummed named-volume file across container restart; remove it only on explicit owned-volume deletion.
- Support a read/write and read-only bind beneath the designated ExternalSSD fixture root; verify guest writes on the host and enforced read-only behavior.
- Reject path traversal, symlink escape and unapproved host roots. Test mount failure rollback, busy-volume removal and permission mapping.
- Expose the fixture-required Docker volume/mount metadata without legacy Docker storage; verify no residual mounts after teardown.

Problem and Evidence: Native workloads currently lack persistent volumes and host binds; this blocks realistic Compose and storage comparisons.

Approach:

1. Implement one named-volume fixture, then the allowlisted bind with negative path tests.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-037`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Implement one named-volume fixture, then the allowlisted bind with negative path tests.

### SPEED-038

Title: Run a pinned BuildKit worker on the native engine

Description: Enable the exact BuildKit worker configuration required by the existing Buildx fixture and verify one Rust build/export/run.

Is blocked by task: SPEED-037.

Acceptance Criteria:

- Start the worker with the unmodified Buildx client through the native endpoint; no hidden Docker/containerd daemon or host build fallback.
- Identify its actual build executor and required mount/namespace/security capabilities. Implement narrowly scoped requirements with escape-denial tests; unsupported privileged mode is not a workaround.
- Supply identical verified offline OCI bases to both engines, export/load the result through native image handling, and run its output canary.
- Capture effective worker CPU/memory/I/O limits and verify worker, cache and exported-image cleanup. Leave this task open if native execution of the worker is not proven.

Problem and Evidence: Native launch speed does not imply build acceleration; the current builds use the old engine.

Approach:

1. Probe the pinned worker's exact prerequisites and add individual capability subtasks for any missing native operation.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-038`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Probe the pinned worker's exact prerequisites and add individual capability subtasks for any missing native operation.

### SPEED-039

Title: Run Node and Redis Compose entirely on native

Description: Implement the remaining API semantics required by the existing pinned Compose fixture.

Is blocked by task: SPEED-038.

Acceptance Criteria:

- Run unmodified docker compose up --wait with native-owned Node and Redis; prove backend and effective cgroup limits for each service.
- Pass HTTP transaction, service DNS, health check, log retrieval and persisted Redis-data canaries.
- Pass no-change up, app recreate, scale to two replicas, restart and down --volumes with correct event/state semantics and cleanup.
- Explicitly reject unsupported Compose features and preserve the production context; no legacy fallback for any service.

Problem and Evidence: Prior Compose measurements used Docker/containerd; default-native promotion requires actual multi-service compatibility.

Approach:

1. Replay the frozen Compose client's request transcript against native and implement each missing operation with a regression test.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-039`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Replay the frozen Compose client's request transcript against native and implement each missing operation with a regression test.

### SPEED-040

Title: Qualify release native Docker launch parity

Description: Run the frozen matched API and Docker CLI launch matrix using the completed native owner.

Is blocked by task: SPEED-039.

Acceptance Criteria:

- Build all candidate components in release mode from one source revision; record hashes/settings and validate actual native dispatch for every sample.
- Collect five alternating independent pairs, 2,000 samples per engine/lane/boot and ten warmups for the frozen lifecycle rows; include supported bridge and output/exit scenarios.
- Preserve API acknowledgement versus verified cleanup distinctions, raw failures and per-session distributions. Compare native to Kiri and the frozen prior native baseline.
- Evaluate CLI p50 and p99 parity with paired 95% ratio upper bound <=1.05; report API median advantage and regressions separately. A failed target creates a concrete profiling follow-up, not a fabricated pass.

Problem and Evidence: The new native host and compatibility changes require fresh measurements; old legacy samples cannot qualify them.

Approach:

1. Freeze the release artifact manifest and run diagnostic-free matched launch pairs.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-040`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Freeze the release artifact manifest and run diagnostic-free matched launch pairs.

### SPEED-041

Title: Measure the native-backed Rust Go and Node build matrix

Description: Execute the existing empty/unchanged/source/dependency build cases using the qualified native BuildKit setup.

Is blocked by task: SPEED-040.

Acceptance Criteria:

- Retain the same Dockerfiles, offline bases, clients, cache-state definitions and export/load boundaries used by the recent report.
- Complete five independent pairs with the frozen per-case repetitions and verified artifact execution; record failed artifacts as failed operations.
- Publish the same build latency and worker CPU/peak-memory/read/write tables; identify worker/executor and export/load time separately.
- Attribute every worker container to native and compare cache behavior/effective limits before making a speed claim.

Problem and Evidence: Prior build timings were legacy-host results and cannot establish native build performance.

Approach:

1. Run the Rust cache-state group first, then Go and Node without overlapping timed suites.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-041`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Run the Rust cache-state group first, then Go and Node without overlapping timed suites.

### SPEED-042

Title: Measure native Compose and exec/control workflows

Description: Run the unchanged Compose and persistent exec/control cases against the native candidate and Kiri.

Is blocked by task: SPEED-041.

Acceptance Criteria:

- Complete five independent pairs for the existing readiness/recreate/scale/restart/down and exec/inspect/list/attach/log/event/copy rows at their frozen counts.
- Validate transactions, stdout/stderr, exit statuses, file checksums and effective service limits outside timing as specified; preserve failure records.
- Use the existing per-operation p50/p95/p99 table format and declare unsupported rows explicitly; a required unsupported row blocks native compatibility completion.
- Record all service and exec backend identities and project-scoped cleanup; do not mix old-engine rows into the native series.

Problem and Evidence: Launch parity alone does not establish an improved interactive or multi-service Docker experience.

Approach:

1. Freeze one native Compose/exec series manifest and run its first paired session with canaries.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-042`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Freeze one native Compose/exec series manifest and run its first paired session with canaries.

### SPEED-043

Title: Measure native storage network and service performance

Description: Execute the frozen named-volume, host-bind, writable-layer and network/service workloads on native.

Is blocked by task: SPEED-042.

Acceptance Criteria:

- Verify dataset hashes, durability and mount permissions; report Docker CLI elapsed time separately from guest I/O stages.
- Measure matching DNS/TCP, host published-port transactions and standalone bulk transport with explicit client placement and topology.
- Complete five independent pairs at frozen repetitions and steady-state durations; retain CPU/memory, disk growth, failures and application correctness.
- Preserve the recent storage/network table format and units; record unsupported semantics without substituting host operations.

Problem and Evidence: Native filesystem and network implementations may change performance in either direction and need workload-specific validation.

Approach:

1. Run storage canaries before timed I/O, then the isolated transport and application groups.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-043`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Run storage canaries before timed I/O, then the isolated transport and application groups.

### SPEED-044

Title: Qualify native concurrency pressure and recovery

Description: Run the existing 1/2/4/8 launch sweep and bounded pressure/recovery matrix on the expanded native owner.

Is blocked by task: SPEED-043.

Acceptance Criteria:

- Verify effective guest memory/swap/CPU controls before allocation; preserve active checksummed data while evicting optional prepared state.
- Test queue saturation, cancellation, OOM attribution, client/guest disconnect and task-owned VM termination; reject duplicate starts and verify cleanup inventories.
- Complete five independent matched sweeps where competitor behavior permits. Preserve Kiri timeouts/unknown boundaries and report incomparable pressure cases explicitly.
- Publish the same concurrency/throughput and resource tables. Prepared claim/refill stays separate and cannot hide reserve cost.
- No persistent services, production interruption or unsafe host-wide pressure. Optional energy collection remains separately authorized.

Problem and Evidence: Additional concurrent services and worker capabilities introduce ownership, pressure and recovery risks absent from the single-slot fixture.

Approach:

1. Run native lifecycle fault injection and active-data canaries before the timed concurrency series.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-044`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Run native lifecycle fault injection and active-data canaries before the timed concurrency series.

### SPEED-045

Title: Publish the native-default Docker verdict and promotion audit

Description: Extend the existing detailed report with the complete native-default series and exact compatibility scope.

Is blocked by task: SPEED-044.

Acceptance Criteria:

- Preserve the report's environment/hash, per-pair API/CLI, per-operation, build-resource, concurrency, ratio/95% interval, coverage and evidence tables.
- Audit raw measurements, failures, revisions, effective limits and native backend attribution; retain historical legacy/development tables with their original labels.
- Use per-workload parity/faster/slower/inconclusive/unsupported verdicts. Publish no overall win unless every declared workload supports it; unknown cleanup or energy remains unknown.
- Create narrow follow-up tasks for demonstrated bottlenecks and missing compatibility. Update the release scope to actual supported behavior without marking deferred SPEED-008 passed.
- Review packaged native-default startup, rollback, CI and cleanup evidence before proposing promotion. Independent PR approval and production signing remain required; this task does not itself publish a release.

Problem and Evidence: The current report mixes historical and native evidence by design; the next verdict must make actual native coverage explicit without rewriting history.

Approach:

1. Generate the native-only coverage matrix from SPEED-040 through SPEED-044 raw evidence.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-045`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Generate the native-only coverage matrix from SPEED-040 through SPEED-044 raw evidence.


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
The remote already publishes `conjet-v3.0.0` at `f1df932`, while this branch
still has `VERSION=3.0.0`. An additive release that includes a qualifying
experimental feature would use the next available minor version. The source
Docker adapter does not add a kernel or Core image dependency. The final
package scope and version remain pending independent review and qualification.

Source: [Release process](../release.md), [Homebrew](../homebrew.md),
[repository instructions](../../AGENTS.md).

Review: Pending; verify production artifact readiness, version/tag consistency,
asset compatibility, and evidence supporting every release claim.

Next Action: Set matching version metadata and release notes for the reviewed package scope before tagging an independently approved, qualified revision. Confirm Developer ID and notarization credential availability through the release environment.

## INPROGRESS

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

Problem and Evidence: The matrix implements a bounded Docker launch concurrency sweep and a distinct per-container OOM canary. It requires exit 137, an OOM flag, an unchanged active-data canary in a sibling container and a fresh recovery launch. A unit test injects a native backend disconnect after submission and proves the adapter refuses replay, unverifiable removal and new admission. Guest-wide reclamation, actual runtime process loss and restart, and prepared-slot tests remain separate requirements for this program.

Raw evidence: Fast sequential medians can hide queueing, memory reservation, deferred cleanup and recovery costs.

Approach:

1. Freeze safe resource ceilings and deterministic fault points.
2. Run bounded stress and recovery sessions with canaries and before/after inventories.
3. Analyze scaling, tails, failure rates, resource reclamation and optional energy without discarding adverse sessions.

Evidence: `SPEED-025/pair-1` on `187e1ab` completed all 400 measured launches per engine with zero launch failures. Both observed active data after the pressure attempt and passed isolated recovery and production-preservation checks. `native-product-full-1` on `4da6d3b` passed the injected native pressure/recovery, bounded output, overload, cancellation, active shutdown and stale prior-boot handle canaries. Both native session directories were removed. It recorded 2,000 measured samples per fresh and prepared CLI/API lane. Docker pressure attribution and the remaining independent pairs are open. The [interim results](docker-benchmark-results.md#concurrency-and-recovery) retain both failures and successful rows.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat remaining concurrency pairs and keep the Kiri pressure boundary unresolved. `SPEED-025/pair-2` demonstrated Conjet exit 137 and `OOMKilled=true` with verified 64 MiB memory and disabled swap. The sibling and recovery canaries passed. Kiri reported `MemorySwap=0` instead of the requested 64 MiB, so the guard stopped its pressure workload before allocation. Both engines ran the bounded launch sweep. Preserve pair 1's timeout and OOM attribution failure.
`kiri-effective-swap.log` later observed the requested 64 MiB memory
ceiling and zero swap directly in Kiri's guest despite the inspect
metadata discrepancy. The pressure test still enforces those effective
limits before allocating. `SPEED-025/pair-3` verified both effective limits
for both engines. Conjet attributed exit 137 to OOM and recovered. Kiri's
wait timed out and its OOM flag stayed false despite the matched effective
limits. Both passed survivor, recovery and owner cleanup. Further Kiri
qualification needs a verified termination or OOM witness for this load.

The release-build native static run at `cabbea9` passed 8,000 timings
and the active-data, one-use, expiry, pressure, output, backpressure,
disconnect and shutdown canaries. Both VM directories were removed and
production observations matched. Fresh and prepared API p99 were 4.100
and 3.201 ms, with 3.394 ms refill p99. See raw samples and summary under
`SPEED-025/native-product-release-cabbea9`. The Docker stress matrix
coverage remains open.


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

Problem and Evidence: The matrix implements writable-layer, volume and bind integrity workloads and a sustained Node/Redis service. It times guest DNS, Redis TCP handshake and Redis round-trip separately from the host HTTP transaction window. The storage check exercises sequential and random writes with fsync and verifies the resulting named-volume checksum in a different container. It captures effective service cgroup limits and an owned-service resource snapshot. Paired runtime timing and bulk transport coverage remain open.

Raw evidence: Bridge creation timings do not measure packet performance, and static no-network execution does not establish Docker workload compatibility.

Approach:

1. Reuse existing filesystem/network benchmark utilities with the pinned datasets.
2. Run storage and networking cases independently, then the application load fixture.
3. Verify data integrity and publish topology, throughput, latency and resource observations.

Evidence: `SPEED-024/pair-1` on harness `187e1ab` passed named volume, writable layer, guest transport and sustained transaction checks on both engines. Conjet refused the ExternalSSD host bind before work in all six attempts. Kiri passed it. Both reported matching service cgroup limits and clean session teardown; Conjet completed 2,648 and Kiri 4,776 verified transactions in their respective 60 s windows.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat supported workloads at the remaining pair indices and add standalone bulk transport evidence. Keep the failed Conjet host-bind samples.

### SPEED-023

Title: Benchmark exec, streams and control-plane operations

Description: Measure Docker exec, attach/logs, inspect/list/events and file copy for supported workloads.

Is blocked by task: SPEED-022.

Acceptance Criteria:

- Separate persistent-container docker exec from fresh docker run; measure API and CLI overhead where supported.
- Validate stdout/stderr separation, bounded large output, exit codes, stdin/TTY behavior where supported, and cancellation without deadlocks.
- Measure inspect/list latency with fixed owned-container counts and event delivery/order under churn; do not query or manipulate production containers.
- Measure docker cp in/out with checksummed small-file and large-file sets. Record unsupported native or Kiri behavior without substituting another operation.

Problem and Evidence: The matrix implements persistent CLI exec streams and exit code, bounded output, inspect/list and checksummed file copies. The control fixture adds stdin-driven attach, logs, ordered Docker lifecycle events, TTY and idle attach disconnect recovery. Direct API exec creation, stream demultiplexing, exit inspection and container inspection have executable canaries. Paired runtime evidence remains open.

Raw evidence: Interactive development and tooling depend on control-plane and stream behavior beyond launch latency.

Approach:

1. Add long-lived fixture containers and deterministic stream/file workloads.
2. Run operation-specific latency and throughput cases with correctness assertions.
3. Inspect backpressure, cancellation and cleanup evidence before publishing results.

Evidence: The canceled Conjet half of `SPEED-023/pair-1` retains 274 attempted operations. It confirmed working persistent API and CLI exec, attach, TTY, disconnect/recovery and controlled file copies in the observed repetitions. All 17 observed historical event queries produced empty streams and failed the lifecycle canary. Candidate shutdown removed the private root and production matched its starting snapshot. The bounded stream observer now waits for a complete ordered witness and closes its own client. The corrected `SPEED-023/pair-2` on `7be17a3` completed 100 measured operations per row on each engine, with no operation failures and exact production snapshots. It validated every event lifecycle, both persistent exec boundaries, attach and copy. Four independent pairs remain.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat the corrected control workload at the remaining pair indices.

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

Problem and Evidence: The first Conjet half of `SPEED-021/pair-1` completed all Rust and Go build/export, load and execution canaries. Node failed its first exported image canary in all three repetitions with `MODULE_NOT_FOUND`. npm linked the local package outside the exported dependency directory. The fixture now uses `--install-links` to install the package contents, and build/load rows explicitly fail when the exported image fails its canary. Kiri bootstrapped BuildKit but its worker timed out on Docker Hub HTTPS for all three base preloads. Stage the verified registry manifests and blobs once on ExternalSSD and provide the same offline OCI named contexts to both workers. Preserve pair 1 and rerun the corrected workload with both engines.

Raw evidence: Build performance depends on BuildKit, filesystem behavior and caching; the new native launch service is not itself a build engine.

Approach:

1. Reuse the polyglot fixtures and define private builders with explicit endpoints.
2. Execute the cache matrix serially and validate each output image.
3. Publish per-project and per-cache-state comparisons with builder provenance.

Evidence: `SPEED-021/pair-2` records harness `1253da3`. Both existing engines completed all 36 pinned Buildx build/export and load rows and 36 artifact canaries each. Pair 3 on `b3f0ffc` repeated those results and verified removal of 36 per-case image tags and nine private builders per engine. Raw reports, builder endpoint/driver/version and cleanup witnesses are retained with failed `pair-1`. Compatible independent pairs and the new worker resource observations remain open.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat the verified offline Buildx workload at the remaining pair indices with effective builder resource attribution. Distinct temporary tags identify every case's exported image. The harness now samples cgroup CPU time, current and cumulative peak memory, and block I/O from the verified worker before and after application work, outside the timing window.
`SPEED-021/pair-4` on `25ce7d7` verified all 72 timed operations per engine,
with both BuildKit cgroup views reporting CPU, peak/current memory and
I/O. `builder-counters.json` retains the raw-derived deltas. The report
keeps intervals open until the compatible independent pairs are present.

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

Problem and Evidence: The full fixture uses pinned Node and Redis, real dependency readiness, transactions, scaling, published loopback ports and project cleanup. End-to-end timings are pending.

Raw evidence: Compose includes orchestration, network dependencies and storage behavior absent from the single-container native fixture.

Approach:

1. Create the deterministic application fixture and readiness/data canaries.
2. Run the workflow matrix in alternating engine sessions.
3. Verify application correctness and project-scoped cleanup after every cycle.

Evidence: `SPEED-022/pair-1` contains raw reports from harness `4a6de79`. Both existing engines passed five measured repetitions of each Compose operation and all functional and cleanup canaries. Pair 2 on `b31afde` repeated those results and verified effective memory, PIDs and CPU limits on both engines outside the startup timing window. Pair 1 predates that check and is descriptive. The [interim report](docker-benchmark-results.md#compose-first-pair) records the timings.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat the workload with effective cgroup verification in the other four pair slots.

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

Problem and Evidence: [Interim outcome and coverage audit](docker-benchmark-results.md).
The report separates the first complete lifecycle pair, existing-engine
pilots and native OCI/static timing. The summary tool verifies per-session
counts and refuses a lifecycle paired interval before five complete pairs
or across mixed executable, harness or manifest revisions. It retains setup,
warmup and artifact-verification failures alongside measured rows.
Controlled-registry intervals additionally require complete witnessed config
and layer transfer for every first-pull sample in each accepted pair.
The report generator derives archived bytes per second from the exact saved
artifact size and exposes guest I/O stages independently of Docker CLI time.
The remaining modes and claim review are still in progress.
The local full check retained the default SwiftPM Metal failure and passed
all 440 Swift tests on the documented native build system with two skips.
ARM64 musl strict Clippy exposed two redundant kernel filesystem casts.
The portable comparison passes Clippy and produced the same SHA-256 as
the measured release guest supervisor. Rust workspace tests and formatting
also passed. Logs and the rebuilt hash are in `SPEED-026/final-local`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Keep the published coverage and claim audit current. Complete the
remaining broad-program scenario repetitions only when that scope resumes.
The revised native-first lane has a reviewed local measurement row in
`SPEED-019/native-kiri-release-cabbea9`; independent PR review remains open.

### SPEED-019

Title: Benchmark Docker run and container lifecycle

Description: Measure fresh Docker API and docker run end-to-end against Kiri, retaining native API measurements as a distinct comparison.

Is blocked by task: None for the declared subset. SPEED-018 validated the isolated native route.

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
complete group and keep partial coverage explicit. Pair 2 collected all
2,000 no-network Alpine API samples per existing Docker engine without
failures. Median/p95/p99 were 594.953/819.515/871.010 ms on Conjet and
3.944/4.742/6.988 ms on Kiri. Timing ends at API removal acknowledgement.
Only one of five pairs is complete for this row; source revision and raw
data are in `SPEED-019/alpine-true-none-api-pair-2`.
`SPEED-019/native-oci-full-1` used `4da6d3b` and recorded 2,000 CLI and
2,000 API samples with no failures. Every operation had a distinct native
workload ID and verified guest cleanup. The API p50/p95/p99 was
28.381/33.940/34.537 ms and CLI p50/p95/p99 was 47.900/54.525/59.707 ms.
The opt-in environment rejected excess admission and preserved production.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Preserve the final native-first row and the historical baseline.
Legacy repetitions stopped on the user's direction at pair 3, leaving its
partial report and verified cleanup.
The earlier source adapter runner verifies one-use guest
cleanup on every operation and uses UID/GID 65532. The baseline uses the
image-default user, so their measurements remain distinct.
The full-sample runner handles cancellation through its Docker adapter and
VM ownership cleanup and retains partial rows.
The no-network Alpine `true` CLI series at `eb31229` completed pair 1 with
2,000 samples per engine and no failures. It retained a canceled next boot
with verified cleanup to allow local validation of the hosted CI fix without
overlapping compilation and timing.
Repetition resumed at pair 2 on that same harness under the series'
`remaining` directory. Pair 3 was canceled. Pairs 4 and 5 are outstanding.
The canceled preliminary boot is preserved outside the counted pair set.
Pair 2 retained two exit-127 errors on the existing Conjet path
and zero on Kiri. Both Conjet errors reported Go thread creation failure
under the declared four-PID cap and cleaned up successfully. Investigate
the guest runc startup path using a separate diagnostic and keep the
predeclared limits and failure records in the benchmark.

The serial release pilot from source `98d4148` is retained in
`SPEED-019/{native-default-pilot-3,kiri-native-default-pilot-3}`. Both
engines completed 100 API and 100 CLI samples under matched UID/GID and
limits with zero failures. Native p50/p95/p99 were 34.201/39.674/43.706 ms
(API) and 47.845/52.008/52.984 ms (CLI). Kiri recorded
4.116/4.776/5.204 ms (API) and 21.341/22.796/23.813 ms (CLI).
The native API's median observed adapter sleep was 27.393 ms.
Kiri guest cleanup is unknown.

The adapter now waits for the terminal guest revision in cancellable
100 ms slices. The release pilot in `SPEED-019/native-default-wait-pilot`
completed 100 samples per lane with zero failures. It recorded one Wait
request per operation. Native p50/p95/p99 were 3.185/3.727/4.363 ms
(API) and 22.792/24.618/27.912 ms (CLI). A dedicated timeout test
verified cancellation without resubmitting Launch. The real OCI suite
in `SPEED-018/native-default-wait-live` and the Kiri-first serial
orchestrator pilot in `SPEED-019/native-default-orchestrated-pilot` passed.
The 25 ms host tick remains enabled.

The final five alternating, independent pairs used measurement revision
`cabbea9` and matching release binaries. All 40,000 measurements and 200
warmups passed. The native API p50 ratio to Kiri was 0.841 (95% interval
0.818–0.855); p99 was inconclusive at the practical threshold. Native
CLI p50/p99 ratios were 1.076 and 1.099 and slower at that threshold.
The native witness verified each workload and its cleanup. Production
and owned session cleanup checks passed for all ten boots. See the
[release-build lifecycle results](docker-benchmark-results.md#release-build-native-docker-lifecycle)
and `SPEED-019/native-kiri-release-cabbea9/summary.json`. The matched warm
no-network `true` row is complete. Broader lifecycle coverage remains open.


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

### SPEED-020

Title: Benchmark Docker image and registry operations

Description: Measure pull, local load/save, image inspection and removal with controlled registry and cache conditions.

Is blocked by task: SPEED-019.

Acceptance Criteria:

- Use identical immutable images and architecture; separate manifest lookup, transfer, decompression/unpack and ready-to-run where observable.
- Measure cold and cached pulls using a task-owned local registry when supported; report public-network pulls separately without attributing network variation to the runtime.
- Verify digest and runnable contents after pull/load; measure save/load throughput and disk expansion. Delete only task-owned images and artifacts.
- Record unsupported image-management operations for native-only endpoints; image preparation is included in native readiness cost where relevant.

Problem and Evidence: The first serial image pair completed and verified cleanup.
It produced pinned Node save/load and runnable proofs on both engines
and loopback registry reimports. Kiri's reused Alpine config advertised
the historical index digest while returning the exact pinned ARM64 config
digest. The runner now checks that pinned config digest independently
and retains advertised-manifest status. Registry reimports separately
record observed blob transfers and keep pristine layer cache unknown.
Four fixture tests passed. Retained raw data under ExternalSSD
`SPEED-020/pair-1`; repeat the affected Alpine row and the remaining pairs.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Verified immutable identities, complete transfers, archive/load and execution canaries, pinned participants, five independent pairs, exact cleanup and production snapshots. Pending program review with the SPEED-019 dependency.

Evidence: `SPEED-020/pair-2` passed both image pins, warm save/load and run. Its host timestamp filter missed Conjet registry witnesses. `SPEED-020/pair-3` on `b31afde` observed all expected config and layer bytes for all ten measured first pulls per engine. Both engines passed archive, run and labeled-registry cleanup checks with zero scenario failures. Keep the prior unknown transfer records.
The subsequent private Kiri inventory found 24 owned digest-only registry
images omitted by the earlier repository-filtered listing. Removed their
exact config IDs and verified absence without pruning. The harness now
validates those IDs against the full private image inventory and verifies
their removal. See `SPEED-026/final-local/kiri-image-inventory*.log`.
`SPEED-020/cleanup-qualified` then completed five independent matched pairs
at `20e3a2b` with zero recorded operation failures. It verified 12 digest-only
removals per engine per boot and complete transfers for the first pulls.
`summary.json` records per-session distributions and the paired CIs. Kiri
met the frozen faster threshold for the four controlled pull rows. The supplemental `SPEED-020/backing-observation` captured before/after backing allocations. Per-session archive throughput and inspection distributions are retained.

Next Action: Review the full image evidence with the remaining program results once SPEED-019 is ready.

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

New hosted runs `45101948820` and `45102608771` reproduced separate
image-pulse timing failures. The tests now await the scheduled refresh.
The queued case uses an explicit command gate so the initial container
refresh stays in flight until the deferred event queues. Assertions are
unchanged or stronger. Seven pulse tests passed three consecutive local
runs. The full native SwiftPM suite executed 440 with two skips and zero
failures. The logs and the two hosted failures are kept in
`SPEED-026/final-local`. On `63e9147`, [hosted CI](https://github.com/omega13-engr/conjet/actions/runs/45104363466)
passed Swift, networking, app staging and benchmark checks. Later branch
revisions still require current CI and independent review before merging.

Source: [Qualification policy](speed-engineering-plan.md#verification-and-claim-policy),
[release process](../release.md).

Review: Pending; verify all development gates before opening the PR and all CI
and review requirements before merge.

Next Action: Collect required CI and independent review before merging.

## DONE

### SPEED-018

Title: Qualify Docker-to-native routing before claiming Docker acceleration

Description: Implement and verify the Docker-compatible native route for the explicitly supported subset in the isolated candidate.

Is blocked by task: SPEED-017.

Acceptance Criteria:

- Write a supported Docker operation/option contract and single-owner lifecycle design before implementation. General Alpine/OCI execution requires verified image/rootfs admission and execution support, not a static-binary substitution.
- Support the selected real docker run lifecycle, including API negotiation, create/start, attach/output, actual exit status, wait conditions, inspect and removal. Test event ordering, names/IDs, cancellation and disconnect recovery.
- Record backend selection per container. Reject unsupported requests clearly or route them explicitly to the existing Docker backend before allocation/start; never silently ignore flags or retry after ambiguous execution.
- Verify isolation, bounded resources, image semantics and no leaks on success/failure. The isolated candidate defaults to native with no fallback. Ordinary production routing remains under the installed runtime.
- If integration is not viable within the declared subset, record an unavailable accelerated Docker lane and a reviewed follow-up implementation task. Benchmark existing Docker and native lanes separately; do not claim this benchmark work created Docker acceleration.

Problem and Evidence: [Supported adapter contract](docker-native-adapter.md). The initial
native executable-only profile rejected pinned Alpine's dynamic BusyBox.
The new immutable rootfs path verified the actual Alpine image config and
519-entry rootfs on both engines. Live OCI and unmodified Docker CLI checks
verified argv, env, working directory, UID, both output streams and exit 23,
backend attribution, forced removal, failure on unsupported options,
one-use Start under replay and client disconnect, terminal cleanup and absence
of owned sockets/directories. A separate 20-sample pilot ran each Docker
transport through the new adapter. Rust workspace tests, strict ARM64
guest Clippy, adapter tests and image validation tests passed. Retained
failed experiments and successful proofs are under ExternalSSD `SPEED-018`.
The native-first launcher booted release-optimized CLI, VMM and guest
binaries. `SPEED-018/native-default-build` retains the source revision,
logs and binary digests. The matched pilot verified distinct native workload
handles, guest cleanup, VM reclamation, removal of the private socket and
session directory, and an exact production snapshot match.
A TERM after smoke returned 143 and verified the same cleanup and
production checks in `SPEED-018/native-default-cancel/launcher.json`.
The Python adapter, image admission and benchmark suites passed 29 tests.

Subtasks:
- Validate and stage the pinned rootfs.
- Execute a bounded OCI process in the existing native sandbox.
- Default the isolated candidate to the native Docker owner and verify the actual Docker CLI lifecycle.
- Keep the supported subset explicit and preserve installed production routing.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Verified private peer binding, boot generation, bounded image staging,
container ownership, output and cleanup boundaries. Only the source-operated
no-network Docker subset qualifies. The wider Docker surface is unsupported.

Next Action: Extend measurements for the verified rootfs and option subset.
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
The coordinator can run all five frozen pairs under a single foreground
lock. New session reports record `/info` after VM readiness and probe the
container view of guest memory outside timing. A second verified backing
snapshot exposes allocated disk changes across the complete suite.

The release-build coordinator's cancellation check initially exposed an
inherited ignored SIGINT that prevented TERM from stopping the series. The
worker stopped the task-owned launcher and verified cleanup. The coordinator
now handles TERM directly. The repeated Kiri-first check returned 130,
retained 841 partial API samples, verified unchanged production and released
the daemon, socket and disk holder before a native launcher could start.
Evidence is in `SPEED-019/native-default-matched-kiri-cancel{,-fixed}`.
A post-fix pilot completed both lanes on both engines under
`SPEED-019/native-default-post-cancel-fix-pilot`. Its samples are excluded
from the five-pair series measured at `cabbea9`.

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

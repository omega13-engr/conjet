# One-shot worker: native compatibility, then full release benchmarking

> The user authorized a NEW worker on 2026-11-24 to complete compatibility
> fixes and tests. The previous worker remains paused. Use the checkpoint order in
> [native-compatibility-completion-plan.md](native-compatibility-completion-plan.md)
> while preserving the scope and qualification requirements below.

Execute in /Users/sly/Workspace/Personal/conjet on enhancement/speed-up.
The user authorizes completing remaining native compatibility work and running
full benchmarks against official Kiri only AFTER all required compatibility
tests pass. Continue between ordinary increments without asking to proceed.
This instruction supersedes earlier retained-engine work; it does not remove
production protection, dynamic memory, review or release gates.

## Establish scope and ownership

Read AGENTS.md, applicable nested instructions, task-board.md,
native-engine-v2-plan.md, native-buildkit-executor.md,
native-engine-validation.md, native-latency-diagnostic-results.md,
docker-benchmark-plan.md, speedup-environment.md and benchmarks/README.md.
Inspect actual current HEAD and worker ownership before editing; preserve
unrelated graphify-out changes. Baseline at handoff: 10d36fd. Do not assume
source and measured binary hashes are identical.

Full compatibility here means every required operation/fixture in the frozen
Docker comparison matrix, plus regression coverage for the engine's advertised
capabilities. It is not a claim of every Docker feature or every OCI workload.
Create a machine-readable compatibility manifest from the existing matrix,
recording fixture, required API/CLI behavior, effective policy, expected output,
cleanup witness and owning task. Freeze it BEFORE implementation qualification.
Keep unsupported broader features explicit in the capability table.

## Complete gaps with narrow increments

Start with SPEED-089 and create narrowly scoped child tasks for these observed
gaps before implementation. Reuse existing native code and direct BuildKit
proofs. Preserve their limited scope; do not relabel a standalone canary as
Docker Buildx qualification.

1. Registry/image provisioning: configure the isolated registry store in the
   actual launcher. Support pinned matrix images, required tag/digest and
   platform resolution, shared layers and failure cleanup. Implement required
   tag, inspect, remove, load/save operations where absent. Verify contents
   by digest and runnable output. Test interrupted/corrupt transfers and
   references still held by containers. Do not expose registry credentials.
2. Workload credentials: implement the frozen fixtures' actual image/default
   and explicit UID/GID semantics, including namespace-root where required,
   with deliberate guest mappings and enforced capabilities/seccomp/limits.
   Do not alter stress commands to force UID 65532 and call them equivalent.
   Add negative tests for unmapped IDs and unauthorized privilege expansion.
3. Docker builder path: qualify the PINNED Buildx Docker-container driver,
   worker image/bootstrap, worker cache volume, lifecycle and Docker API calls.
   It requests a privileged worker that is currently rejected. This requires
   an explicit execution-policy design and tests; never silently ignore the
   privileged flag, grant all ordinary containers privilege or expose host
   resources. Bound worker access to the isolated guest and task-owned assets.
   Implement required native runtime semantics without dockerd/containerd/runc
   fallback. If exact semantics cannot be supported, record the failed gate.
   A different builder driver can be a separately versioned matched study on
   both engines; it cannot count as a pass of the original frozen matrix.
4. Build execution: test real Rust, Go and Node builds, required source and
   dependency changes, cache hits/misses, output/export/load, failure exit and
   cancellation. Test POST /build where the manifest requires it, not merely
   the direct guest-local RUN path. Verify the actual native executor identity.
5. Compose: run the original app/Redis fixture and transaction readiness,
   dependency health, logs, restart/recreate, DNS, published ports, persistent
   volume data and down cleanup. Keep the earlier small Compose proof as a
   regression fixture, not a substitute for the original comparison.
6. Complete original image, exec/control, copy, writable-layer, named-volume,
   bind-mount, network and stress/recovery cases. Add missing feature tasks
   rather than weakening assertions. Exercise concurrency 1/2/4/8, cancellation,
   OOM behavior and active-data protection under the specified resource policy.

Each increment: reproduce the gap, implement the smallest coherent native
change, test success and failure paths, review diff, update board/evidence,
commit conventionally and push/verify the remote head. Reconcile stale task
sections. No task is DONE solely because it has a commit or passing pilot.

## Mandatory compatibility gate

Run the ENTIRE compatibility manifest on the exact candidate release binaries.
Produce a machine-readable summary and detailed report with per-case PASS/FAIL,
revision, artifact hashes, commands, logs, expected/actual behavior and cleanup.
A required unsupported, skipped, missing, flaky or failed test fails the gate.
Do not exclude failed attempts or count a successful retry without diagnosis.
The final suite must be rerun after the last behavior-changing fix.

Keep Core dynamic memory enabled in every native runtime. Requalify growth
from 448 MiB (or the recorded configured reduced target) to full capacity,
independent guest pressure with zero containers, active-data integrity during
churn, idle shrink within policy and balloon/page-reporting ownership. Capture
actual target transitions and data checksums. No fixed-RAM performance mode,
permanent pool, relaxed fixture limits or shortened cleanup acknowledgement.
Keep the 25 ms safety tick unless a separate fully validated task resolves it.

Run project-standard Rust formatting, workspace tests, ARM64 guest Clippy,
relevant Swift/Go/C tests and integration checks. Distinguish existing failures
from regressions; do not suppress lints or tests to create a green result.
Screenshot-backed QA applies to affected visible UI; for headless engine
changes state why screenshots are not meaningful and retain runtime evidence.

## Only after compatibility PASS: full optimized benchmark

Freeze source, release-optimized host VMM, native guest, CLI, daemon and Core
helpers plus their hashes and build flags. Verify actual launcher paths and
native execution identities. No temporary test hooks in qualification binaries.
Builds finish before timing. Freeze official Kiri version/hash, client tools,
images, VM resources and benchmark manifest. Use the same host, ExternalSSD,
workload and effective limits; keep production running and guarded.

Run the existing full comparison matrix serially with independent alternating
engine boots. Lifecycle: five pairs per API/CLI lane, 2,000 measured operations
and ten warmups per engine/boot. Other workloads use their existing frozen
counts and cache conditions. Include build cache variants, image acquisition,
Compose readiness/churn, exec/control, storage, networking, concurrency and
recovery. Keep cold/warm, API/CLI, application readiness and guest cleanup
boundaries separate. Do not run tests/builds/another engine during timing.

Use the existing detailed result format: versions/hashes/resources, per-boot
p50/p95/p99, throughput, stages, paired 95% intervals, raw success/failure counts,
CPU/memory/disk, dynamic-memory evidence, coverage and cleanup. Apply the
existing 1.05 parity gate and existing advantage criteria without moving them.
Retain prior missed p99 gates (1.0586 API and 1.0553 CLI). Report the new
outcome even if it fails. Below-5-ms warm API median alone is not full parity.
Kiri guest teardown, second-host and energy gaps remain explicitly disclosed.

If benchmark correctness fails, retain the failed run, fix/requalify affected
compatibility and freeze new hashes before rerunning the affected benchmark
series. Do not combine incompatible revisions into one qualification result.

## Isolation, completion and delivery

All generated artifacts, builds and private test disks use
/Volumes/ExternalSSD/dev_workspace/tmp. Preserve raw evidence; remove disposable
builds/scratch and stop all owned services. Do not change installed production
Conjet, its VM/containers, Docker socket/context, Buildx selector or global SSH
configuration. No persistent service/startup registration. Use explicit private
conjet-speedup endpoints and isolated client configurations for every command.

Continue all feasible authorized work until compatibility and benchmarking
are complete; do not stop after a single gap is fixed. If an actual external
blocker prevents a requirement, finish independent work and report the exact
blocker and remaining failed gate. Never fabricate completion or silently
reduce scope. Keep full benchmark blocked if required compatibility is absent.

Update the existing draft PR #33 with final scope/evidence and CI state.
Prepare release-readiness material only after gates pass; do not bypass
independent review, signing/notarization or publish an unqualified release.
Final report: exact pushed HEAD, compatibility manifest totals, benchmark
results versus Kiri, memory/cleanup proof, unresolved coverage, CI/review and
explicit parity verdict. Historical tests are not proof for the new binaries.

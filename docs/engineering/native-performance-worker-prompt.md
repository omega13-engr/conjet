# One-shot mandate: optimize native Conjet against Kiri

The user explicitly authorizes starting this iteration and continuing through
implementation, tests and measurement without routine permission stops. Work in
`/Users/sly/Workspace/Personal/conjet` on `enhancement/speed-up`. Read AGENTS.md,
the task board, native compatibility completion plan, BuildKit executor design,
Docker benchmark plan, frozen manifests and latest reports before implementation.
This mandate supersedes the previous build-only rerun scope. It does not bypass
release gates or authorize changes to the installed production runtime.

## Objective and truthful completion

Retain Conjet's native engine and full Core dynamic memory. Improve the original
Docker experience, beginning with the measured build bottlenecks. Target Kiri
parity across the frozen matrix and a demonstrated advantage in the optimized
rows. Use the existing predeclared parity and advantage rules, paired confidence
intervals and correctness gates. Do not invent an overall score that hides slow
rows or claim universal superiority. Fast launch alone does not qualify builds,
exec, copies or binds. No fixed-memory mode or dockerd/containerd/runc fallback.

Continue through ordinary increments and failures. Do not end after a pilot or
one improvement when further in-scope work is feasible. If evidence shows an
approach ineffective, revise the hypothesis instead of repeating it. A real
external blocker or exhausted evidence-backed approaches must be reported
honestly with remaining failed criteria; never fabricate a win or run an
unbounded retry loop. No arbitrary deadline or speed guarantee is established.

## Baseline and evidence

At handoff, HEAD is `74923dc`, with measured optimized implementation `16a05e0`.
Inspect current state rather than assuming it. Preserve unrelated graphify-out.
The exact implementation passed 71/71 compatibility and five build pairs.
Evidence is under ExternalSSD `conjet-speedup-evidence/SPEED-065/`:

- `cj-full.lQbpSK-build-rerun-16a05e00d07d/`: latest five passing build pairs.
- `cj-full.lQbpSK-full-d537487f49d3/`: earlier lifecycle/image and failed builds.
- `cj-compat.tMPK1e-comparison-66a8a90-builds-and-services/`: service/control data.

All 15 builders on Conjet reported snapshotter native; all 15 on Kiri reported
overlayfs, with the same BuildKit 0.23.2 image. Across 15 dependency-change Rust
samples the median rounded COPY-stage sum was 14,000 ms on Conjet, zero at log
resolution on Kiri; RUN medians were 6,200 vs 200 ms. These diagnostic medians
are not additive or equivalent to the report's paired per-boot statistics.
Unchanged Rust bypasses COPY/RUN and is much closer. This implicates snapshot
preparation but does not quantify causal savings until an A/B experiment.
Node unchanged export remains slower independently. The prior Rust export spin
was not conclusively attributed; keep its upstream patch outside frozen timing
unless a separately declared matched experiment is justified.

## Execute sequential narrow increments

Maintain existing task IDs where appropriate. Add only non-overlapping concrete
tasks before new implementation, with Title, Description, Is blocked by task,
Acceptance Criteria, Problem and Evidence, Approach, Evidence, Source, Review,
Next Action. Keep one runtime-changing increment under investigation at a time.

1. Record a reproducible stage baseline from the existing sessions: snapshot
   prepare/mount, COPY, process admission/start, compilation, commit/diff,
   compression/export, exec stream and archive load/publication. Add bounded
   diagnostic tracing only where current evidence cannot distinguish stages.
   Keep diagnostics separate from uninstrumented qualification binaries.
2. Implement an isolated OverlayFS BuildKit snapshot path. Start at
   guest/launch-service/src/spec.rs, build_snapshot.rs and build_snapshot/bundle.rs.
   Current validation assumes runc-native directories and an underlying disk
   device/inode. Replace those assumptions with explicit snapshotter-aware,
   descriptor-pinned mount/layer ownership, never a relaxed path check. Verify
   rootless operation in the actual guest kernel, required mount policy,
   UID/GID mapping, capabilities, lower/upper/work ownership and lease lifetime.
   Existing CONFIG_OVERLAY_FS=y is a prerequisite, not proof of compatibility.
3. Verify real Buildx RUN and COPY semantics: copy-up, whiteouts, opaque
   directories, hardlinks, symlinks, metadata, writeback, cache invalidation and
   image output. Exercise cancellation, stale/foreign mounts, worker disconnect,
   crash recovery and active cache removal. No underlying layer may disappear
   while referenced; teardown must drain processes and relays before leases.
4. Run a controlled native-vs-overlay A/B on the original Rust dependency-change
   fixture, changing only the snapshot path. Preserve original resources and
   input digests. Record stage times, bytes copied, CPU, memory, disk and cleanup.
   If there is no meaningful gain, diagnose before promoting the path. Broaden
   to all original Rust/Go/Node cache conditions after this check passes.
5. Profile archive import. archive.rs currently hashes layer extents;
   registry.rs publish_blobs copies new blobs then rereads them for hashing.
   Measure those passes and package/extraction cost separately. Where dominant,
   implement bounded copy-and-hash publication that preserves integrity under
   source mutation, atomic visibility, fsync durability, interruption and
   concurrent imports. Do not trust digest filenames or skip validation merely
   to improve timing. Retain corruption and fault-injection regression tests.
6. Profile Node export independently: layer diff/compression, BuildKit dial-stdio,
   native transport and host archive writes. Optimize only the demonstrated
   bottleneck with bounded backpressure and cancellation. Preserve the requested
   Docker archive format and original export/load boundaries. Do not disguise a
   new direct-load path as the original export-plus-load benchmark.
7. After build improvements, address remaining measured gaps one at a time:
   API exec, 8 MiB copy, ExternalSSD binds and lifecycle tails. First trace each
   original failing/slower row; then implement its smallest causal fix and test
   success, error, disconnect and cleanup. Do not perform speculative rewrites.

## Dynamic memory and isolation are invariants

Core owns memory admission and reclaim throughout. Preserve growth from reduced
capacity, independent guest pressure, active-data integrity, balloon/page-report
ownership and idle shrink. Keep the 25 ms safety tick unless a separately
qualified change justifies replacing it. Disk caches must not require permanently
pinned guest RAM. Bound queues and buffers; verify pressure during active builds.

Use `/Volumes/ExternalSSD/dev_workspace/tmp` for all builds, tests, private disks
and temporary scripts. Use explicit conjet-speedup/Kiri test endpoints and private
client configuration. Never alter production processes, VMs, sockets, containers,
Docker context, global Buildx selection or SSH configuration. No startup jobs or
detached persistent services. All temporary processes remain session-scoped;
verify cleanup on completion, cancellation or pause. Retain evidence, remove
disposable scratch. Run no competing builds or engines during timed sessions.

## Verification, comparison and delivery

Each increment: reproduce, implement, run focused tests and relevant regressions,
review diff, update evidence and board, commit conventionally and push/verify the
remote head. Update graphify after source changes. Preserve prior failed runs.
Run project-standard formatting, Rust workspace tests, ARM64 guest Clippy and
relevant Swift/Go/Core checks. Separate baseline lint diagnostics from new ones.

Before qualification, freeze ONE final optimized executable set and verify all
71 required compatibility cases on it, including Core memory and cleanup. Missing,
skipped, unsupported and failed requirements fail the gate. Then run the FULL
original comparison against pinned official Kiri: five alternating independent
boot pairs per lane, original sample/warmup counts (lifecycle 2,000+10 per
session), unchanged workload/cache/resource semantics. Pin both artifact sets,
clients, manifests and image digests. No old timing samples or mixed revisions.
If correctness fails, retain it, diagnose/fix/requalify and clearly distinguish
new cohorts. Stage diagnostics cannot replace the final exact-artifact gate.

Produce the existing detailed report PLUS readable actual millisecond tables for
both engines (p50/p95/p99), with aggregation method, sample counts, failures,
throughput, paired 95% intervals, resources and dynamic-memory evidence. Report
which rows win, meet parity or lose; retain guest-cleanup, energy and second-host
limits. Do not declare success from point estimates alone or weaken thresholds.
Update draft PR #33 and report exact pushed HEAD, implemented changes, test and
benchmark results, unresolved gaps and cleanup. No merge, release publication,
version bump or bypass of independent review/signing/notarization in this mandate.

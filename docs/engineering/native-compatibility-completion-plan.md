# Native compatibility completion plan

Date: 2026-11-24. Following the planning pause, the user explicitly authorized
a NEW worker to complete compatibility fixes and tests. The previous worker
remains paused; only the new worker owns implementation.

## Outcome and fixed scope

Complete the 71 cases in `benchmarks/scenarios/native-compatibility-v1.json`
on one exact optimized candidate, preserving Core dynamic memory and production
isolation. Then run the existing full Conjet/Kiri comparison, with the existing
detailed report format and acceptance thresholds. Full compatibility means this
frozen scope; it does not mean every Docker feature. No completion date or speed
advantage is established by this plan.

Retain the native Rust engine direction. Do not introduce dockerd, containerd or
runc fallback, change the Buildx driver, substitute fixture images, weaken
security/resource semantics, or change expected results to get a pass.

## Observed checkpoint

Repository HEAD at inspection: `a792b4c`. Uncommitted native snapshot, sandbox,
security, server and fixture changes belong to the paused worker and must be
reviewed before reuse. Do not reset them or treat them as verified implementation.
The worker subsequently confirmed idle at this pushed HEAD. Its latest Node run
reached sandbox setup but `/etc/hosts` mounting returned `EINVAL` before RUN.
The preserved, untested fix prepares detached mounts for `/etc/hosts`,
`/etc/resolv.conf` and the tracing socket. Start checkpoint 1 by reviewing that
diff and reproducing this exact mount failure, then validate source descriptors,
mount flags and destination handling; do not assume the proposed fix is correct.
Evidence: `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-165/node-native-run/launcher/matrix/session.json`.
The pause report confirms runtime exit, private socket removal, both scratch
disks unleased and matching production fingerprints. Two older scratch
directories retain socket files with no live owners found; these were preserved.
The last full gate remains historical: 19 PASS / 52 FAIL. New component evidence
does not establish a new aggregate count.

- Nine digest-verified BuildKit OCI preloads succeeded, including Rust, Go and
  Node. Offline preload does not qualify the public registry path.
- The pinned Docker-container driver boots the native worker. Runtime helpers
  authenticate against its live generation; detached snapshot identity is checked.
- Actual native RUN, snapshot writeback, cancellation and aggregate worker/RUN
  accounting remain open (SPEED-160, SPEED-165, SPEED-168).
- Public registry DNS timed out at `198.18.1.1:53` (SPEED-162).
- Eighteen original cgroup observer calls passed, but worker block-I/O reporting
  remains separate (SPEED-163/164). A hosted backing-rollback failure needs the
  exact error and a focused fix (SPEED-166).

## Architecture to complete, not replace

```text
Unmodified Docker / Buildx / Compose clients
                  |
        isolated Docker-compatible API
                  |
       native lifecycle / exec transport
                  |
       pinned BuildKit worker + owned cache lease
                  |
       authenticated native runtime helper
                  |
       live bundle + descriptor-pinned root/mounts
                  |
       Core admission -> native RUN sandbox
                  |
       output + exit + snapshot writes + verified teardown
                  |
       BuildKit cache/export -> Docker-visible result

Owned build accounting
  aggregate cgroup (enforce original workload budget)
    +-- worker child (BuildKit lifetime)
    +-- RUN child   (one execution generation)

Core dynamic memory owns admission/reclaim throughout.
Cache lease outlives every worker, RUN, mount and output relay using it.
```

Do not assume a detached mount creates a copied filesystem. Prove that RUN writes
are visible in the exact BuildKit snapshot and that teardown never modifies the
worker's live mount. Preserve original credentials, mounts, network and resource
requirements. Unsupported OCI semantics must fail explicitly before execution.

## Sequential execution queue

Use the existing SPEED task IDs. These checkpoints order their completion; they
do not replace acceptance criteria or create another series of overlapping tasks.
Only one implementation checkpoint is INPROGRESS at a time.

| Order | Concrete work and existing owner | Required exit evidence |
| --- | --- | --- |
| 0 | Reconcile paused changes and refresh the compatibility baseline (SPEED-098) | Review each dirty diff; retain verified fixes or isolate unfinished work without deleting it. Build a reproducible candidate, record six executable hashes and source revision. Run every runnable frozen lane once, classify every missing/failed case, and publish a current 71-row summary. Do not retry known blocked builds repeatedly. |
| 1 | Execute one real Node Dockerfile RUN from the pinned Buildx client (SPEED-159/165) | Original bundle admitted; actual credentials/mounts/limits observed; expected output and exit; RUN writes visible to the subsequent build stage; exact-generation process and mount cleanup. No capture helper or direct-RUN substitute. |
| 2 | Account for worker and RUN together (SPEED-168/164) | Aggregate budget includes compiler processes; observer counters cover both children without double counting. Exercise pressure and cancellation while RUN is active. Releasing cache with a live child is rejected. Record actual `io.stat`, or the specific unavailable kernel facility without inventing measurements. |
| 3 | Complete Buildx transport and cancellation (SPEED-153/160) | Original dial-stdio solve, bidirectional EOF/backpressure and separate stderr succeed. Cancel an active RUN; then verify worker, child, socket, mount and lease cleanup, followed by a successful replacement builder. |
| 4 | Repair public registry resolution (SPEED-162) | Trace guest DNS request, response, route and registry TLS/download separately. Fix the demonstrated broken hop. Original public references resolve and transfer verified content through the original worker; corrupt/interrupted transfer cleanup still passes. Offline seeds remain separately labelled diagnostics. |
| 5 | Qualify frozen Node build rows (SPEED-160/161) | Empty cache, unchanged cache, source change and dependency change produce the original artifacts, cache behavior and native executor witnesses. Preserve original build limits and observer calls. |
| 6 | Qualify frozen Go, then Rust build rows (SPEED-160/161/167) | Same four conditions for each language; verify toolchain execution and final outputs, bounded private disk use and offline filesystem health. Do not rerun successful Node rows until a shared behavior changes. |
| 7 | Close build failure, cancellation and POST /build rows (SPEED-089/092/160) | Expected nonzero result, canceled solve cleanup and original Docker API build/export behavior pass. No driver substitution and no success-only fixture. |
| 8 | Fix remaining non-build failures from the refreshed ledger (existing case owners) | Select one observed root cause; implement and run its original failing case plus affected regressions. Cover images, credentials, lifecycle, control/copy, Compose, storage/network and stress. Do not assume previous component canaries qualify these cases. |
| 9 | Close backing rollback CI and requalify Core memory (SPEED-166 and manifest memory owners) | Reproduce the actual hosted error; preserve rollback assertions. Verify reduced-to-full growth, independent guest pressure, active-data checksum through churn and idle shrink with ownership witnesses. Keep the 25 ms safety tick. |
| 10 | Freeze and run the entire release gate (SPEED-098) | All 71 cases PASS on identical candidate artifact hashes; formatting, lint, workspace and relevant integration checks pass. Review changes and confirm production identities/endpoints unchanged and complete task-owned cleanup. |
| 11 | Full optimized comparison and release readiness (SPEED-065 and release owners) | Existing complete benchmark matrix and report, including failures, per-boot percentiles, paired intervals, resources, memory and cleanup. Review/CI and packaging/signing gates must pass before release; no promise of superiority. |

Checkpoint 0 is measurement, not a demand to finish all features before finding
the baseline. A blocked prerequisite remains FAIL with a precise dependency in
the release summary. The diagnostic ledger may distinguish product failure,
environment failure, missing witness and not executed; none count as PASS.

## Evidence and execution discipline

For each checkpoint record: task/case IDs, hypothesis, exact reproduction,
expected/actual result, revision and artifact hashes, diff, focused regression
results, raw evidence path, cleanup, review and next action. Keep this in the
existing task's Evidence/Review/Next Action fields. Reconcile its board section;
a pushed commit alone does not mean DONE.

Maintain a 71-row ledger keyed by the existing case IDs. Each row names its
current failure boundary and owner, not just a broad feature. Inspect
`benchmarks/native-compatibility-gate.py`: it evaluates collected lane evidence;
it does not itself execute the workloads. Use the existing launcher/matrix
commands to collect witnesses before invoking it:

```text
python3 benchmarks/native-compatibility-gate.py \
  --evidence <ExternalSSD candidate evidence root> \
  --revision <full candidate commit SHA>
```

The evidence root must contain `release-sha256.txt` for conjet, conjetd,
jetstream, conjet-launchd, conjet-memd and conjet-reclaimd. The evaluator checks
launcher identity, native backend, dynamic memory and cleanup as well as case
results. Do not splice older successful artifacts into the new candidate.

After two attempts at the same failure without new evidence, stop that retry
loop, capture the exact failing syscall/protocol stage and select a new
testable hypothesis. This is not permission to stop the whole authorized task:
continue independent cases when a true external dependency is unavailable.
Do not keep adding standalone canaries after the real client path is available.
Use canaries only to isolate a specific unresolved boundary.

Run focused checks during fixes. Refresh the affected case ledger after each
checkpoint. Rebuild and run the full gate after the last behavior-changing fix;
avoid full rebuilds and full matrix reruns after every small edit. A change to
shared launch, credential, mount, transport or memory code requires its relevant
cross-feature regressions even if the triggering failure was BuildKit-only.

## Isolation, pause and delivery

All generated builds, private disks, evidence and temporary scripts belong under
`/Volumes/ExternalSSD/dev_workspace/tmp`. Retain raw qualification evidence;
remove disposable scratch. Use explicit isolated `conjet-speedup` endpoints and
client configuration. Do not modify production processes, sockets, contexts,
global Buildx selection or startup registrations. Temporary processes must be
session-scoped and cleaned up on pause, cancellation or completion.

On resume, use `enhancement/speed-up`, conventional incremental commits and
verified ordinary pushes. Preserve unrelated changes. Keep PR #33 draft until
required qualification/review is complete. A 71/71 result permits benchmarking;
it does not itself permit release or prove Kiri parity. Retain the existing
benchmark result format, 1.05 parity threshold, second-host/energy/teardown
limitations and independent review requirements.

While paused, perform no implementation, build, test run, benchmark or worker
restart. This planning change alone does not advance any compatibility task.

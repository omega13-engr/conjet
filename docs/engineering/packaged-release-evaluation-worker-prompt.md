# One-shot: complete packaged native-default release evaluation

The user authorizes resuming the existing worker to finish evaluation end to
end, fixing defects found along the way. Work on enhancement/speed-up. Read
AGENTS.md, docs/release.md, docs/homebrew.md, release workflows, packaging scripts,
the task board and native compatibility manifest. Initial checkpoint is 161411d;
inspect current HEAD and preserve unrelated changes, including graphify-out.
Prior DMG evidence is under ExternalSSD conjet-speedup-evidence/release-readiness/161411d.

## Outcome

Deliver a reviewable, evidence-backed release verdict for the actual packaged
native-default product. Do not substitute the c8cc705 benchmark candidate's
71/71 gate for validation of the packaged revision. Do not stop after another
smoke test. Finish all feasible evaluation, required fixes and revalidation.
This request authorizes evaluation and fixes, not installation over production,
merge, release tags, publication, or bypass of independent review.

## Execute in order

1. Freeze a candidate and inventory the app, menu-bar helper, CLI, daemon,
   Jetstream, guest supervisor, kernel, memory helpers, bundled OCI layout and
   disk template. Record source revision, optimized build flags and hashes.
   Verify current CI and inspect earlier QA for missing evidence. Track each
   gate as PASS, FAIL or BLOCKED with exact evidence; blocked is never passed.
2. Stage the app and DMG using repository scripts. Validate app/helper executable
   resolution, architectures, entitlements, signatures and payload consistency.
   Exercise binaries from the mounted DMG and staged installation paths without
   changing /Applications or production links. Validate both cask and formula
   packaging behavior in isolated staging and verify final artifact checksum.
3. Run fresh-profile setup and ordinary start/status/stop through the bundled
   CLI and daemon. Verify native-docker is actually selected without experiment
   flags, external development assets or benchmark-only launchers. Verify socket
   ownership, client configuration and explicit default resource limits. Test
   missing, corrupted and mismatched bundled assets fail with useful errors.
4. Run the FULL frozen 71-case compatibility manifest through the packaged
   ordinary runtime on the exact binaries. Adapt only launcher/evidence plumbing
   where necessary; preserve test semantics, workloads, limits and pass criteria.
   Pin private Docker 29.10.1, Buildx and Compose copies on ExternalSSD. Do not
   silently switch to the standalone fixture or appliance engine to pass a case.
   Retain setup failures and retries; public transport failure is an incomplete
   gate, not a product pass. Do not relabel offline diagnostics as public tests.
5. Requalify Core memory on the packaged runtime: reduced-to-full growth,
   independent pressure, active data under churn, idle shrink, balloon/page
   reporting ownership, cancellation and recovery. Verify daemon/VM crash and
   restart cleanup, bounded shutdown, socket reacquisition and no stale leases.
6. Exercise persistence and migration explicitly: create volume data and images,
   stop/restart and verify promised persistence. Check boot-scoped writable layers
   and aliases against documentation; do not imply persistent container semantics
   where absent. Rehearse appliance -> native -> appliance using DISPOSABLE
   profiles, preserving inactive disks and checksums and original named-volume
   data. Engine selection must never imply data conversion. Verify startup of
   existing profiles retains their settings and an older-version rollback path.
7. Perform screenshot-backed desktop/menu-bar E2E using an isolated app instance,
   separate home/profile and explicitly scoped IPC. Inspect registration and
   singleton behavior before launching; avoid activating or stopping production.
   Verify runtime status, start/stop, supported operations, restart and error
   messaging. If a safe isolated UI instance is impossible, finish independent
   work and report the exact isolation blocker rather than silently skipping UI.
8. Audit release-facing claims and defaults. Document ARM64 scope, 2-vCPU/2-GiB
   native limits, storage limits, boot-scoped behavior, bind restrictions, registry
   coverage and appliance fallback requirements. Remove obsolete experimental
   labels for qualified native Docker behavior, but retain labels for unrelated
   research commands. A fresh-profile default must not advertise unavailable
   features or silently fall back to another engine. Fix misleading UX/docs.
9. Fix each demonstrated in-scope defect with focused regressions; run standard
   formatting, tests, lint and relevant Swift/Rust/Go/Core checks. Rebuild after
   behavior changes, record new hashes and rerun the full packaged compatibility
   gate on the final candidate plus affected UI/migration/packaging checks. Keep
   benchmark timings labelled with their original revision; no new Kiri run is
   required merely for evaluation unless a changed claim requires measurement.
10. Check signing/notarization readiness without printing secrets. Ad-hoc signing
    proves only the local evaluation artifact. Never describe it as Developer ID
    signed, notarized or production-approved. If credentials or external review
    are unavailable, record those precise remaining gates; do not create new
    credential permissions or publish a release to work around them.
11. Review the final diff; update task board, release scope and an explicit gate
    report with commands, revision/hash mapping, test totals, screenshots,
    migration checks and limitations. Commit/push verified increments with
    conventional messages and verify remote head. Update PR #33 with the final
    scope, CI and evidence. Mark ready for review only when implementation and
    applicable local/CI acceptance are complete; never approve your own work as
    independent review. Select/document a proposed release version, but do not
    tag or publish. Report the release gate status separately from evaluation
    completion. Earlier 81/91 benchmark outcome must remain visible.

## Isolation and completion

All generated builds, test profiles, scripts, disks, screenshots and DMGs go
under /Volumes/ExternalSSD/dev_workspace/tmp. Preserve raw evidence and the
reviewable final artifact; remove disposable scratch. Keep production app,
daemon, VM, containers, sockets, selected contexts and global configuration
unchanged. No persistent jobs, startup registrations or detached survivors.
Temporary processes must be session-scoped. Verify production fingerprints and
cleanup at completion; distinguish retained evidence from leaked resources.

Do not ask routine permission between checkpoints or stop at incremental
success. When an external blocker exists, complete all independent feasible
work and report exactly what requires user/external action. Do not weaken tests,
hide failed attempts or claim release readiness from incomplete evaluation.
Final handoff: exact pushed HEAD; artifact link/checksum; final 71-case totals;
UI, memory, persistence, migration and packaging outcomes; CI/review/signing
status; cleanup evidence; concise remaining blockers. No merge or publication.

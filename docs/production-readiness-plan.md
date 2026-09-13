# Production readiness implementation

Scope: finish the issues established by the September 13 runtime review, preserving
Jetstream HVF and the working dynamic-memory implementation. This is an implementation
and validation track, followed by a conventional commit, push and a major release
when its functional gates are satisfied. It is not a claim of universal Docker
compatibility. The user explicitly selected ad-hoc signing for this release.

1. Repair appliance login readiness and make CLI SSH self-contained without global
   SSH configuration edits. Validate fresh guest boot and the public connection path.
2. Remove the process monitor's twelve-container cap with bounded concurrency,
   deterministic results, cancellation, and visible partial failures.
3. Validate Compose projects before actions; clarify terminal launch records, destructive
   volume actions, host publication failures, and asynchronous VM readiness.
4. Implement live host file sharing with explicit path permissions. Evaluate a maintained
   transport against file/directory mounts, bidirectional changes, rename, symlink,
   read-only and access-denial checks before enabling it by default.
5. Provide durable, narrowly scoped privileged-port authorization with authenticated
   callers, actionable UI state and repair. Actual administrator approval is a live
   validation gate, not something an isolated unprivileged test can establish.
6. Run isolated Docker/Compose, chum-mem, SSH, monitoring, UI and package checks. Keep
   artifacts on the external QA volume, retain concise evidence, and clean scratch
   runtimes/files. Do not restart or replace the installed Conjet runtime.

Release gates include filesystem semantic coverage, authorized low-port E2E, and
documented unsupported network/protocol features. Ad-hoc signing is permitted;
the persistent SMAppService helper remains disabled without a signing team, with
the existing sudo-authorized helper as the fallback. No benchmark or unsupported
performance claim is planned.

## Current result

The implementation and evidence are recorded in [production-readiness.md](production-readiness.md).
Steps 1–3 are implemented with local validation. Step 5 is implemented with
unprivileged protocol/policy and packaging validation; administrative authorization
is not validated. Step 4 remains unimplemented and its new E2E gate fails explicitly.
Step 6 includes a complete rebuilt Core rootfs, fresh boot, packaged app/DMG checks
and screenshots. Fresh-image checks additionally found and fixed fragmented HTTP
readiness parsing and the missing virtio RNG backend/notification feature mismatch.
Broad compatibility gates remain outstanding. Do not mark the full production-
readiness objective complete. After this result was reported, the user explicitly
requested committing, pushing and releasing the current changes. Publication is
now authorized with the known limitations documented in the Conjet 3.0.0 notes;
it does not establish completion of the original readiness objective.

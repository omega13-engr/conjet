# Conjet 2.1.2 release QA

Conjet 2.1.2 carries the host backing-memory fix from `fe3820c`. Production Swift,
Rust, guest, and build-support sources are unchanged from the `conjet-v2.1.1`
tag. Core guest assets remain at 1.3.0. The
[backing-memory QA](../jetstream-backing-2026-09-11/README.md) covers native/HVF
reclamation and ChumMem/Docker workloads.

## Release-blocking test corrections

The 2.1.1 release was not published. Its workflow encountered two existing test
timing failures, retained here with their original assertions. The public tag
was left unchanged; 2.1.2 uses a fresh tag and includes these test-only changes:

- The volume-refresh test no longer assumes that a 200 ms sleep lets a deferred
  refresh finish. `refreshAutomaticallyForTesting()` can queue work behind an
  in-flight refresh and return before the expected commands run. The test waits
  up to five seconds for the observed `volume ls` and `system df` commands, keeps
  its scope assertions, and cancels deferred work on exit.
- The oversized socket-response test gets ten seconds to reach its size limit
  rather than racing a two-second deadline on a shared runner. It still requires
  the same oversized-response error and now includes the actual error in failure
  output. The separate 0.1-second timeout test is unchanged.

The full local Swift suite completed without failures. An isolated scratch
variant delayed every mock command by 500 ms; the corrected volume test completed
in 1.570 seconds. That delay was removed from the scratch source afterward and
was never added to the repository. The retained log records this functional
delay check, not a performance benchmark. No product UI or runtime code changed
for these test corrections.

## Packaging

The 2.1.2 app and read-only DMG were built under the temporary QA root. The DMG
passed integrity and mount checks; app version, deep/strict signature, bundled
CLI/VMM help, and generated Homebrew Ruby syntax were verified. Its local SHA-256
was `136fa1002459289597b2438d10183157d6a77fda27330aae3307fb8c72910b1f`.
GitHub builds its own artifact with a separate published checksum.

The [screenshot](conjet-2.1.2-isolated.png) shows the staged app resolving its
bundled tools using an isolated, offline `CONJET_HOME`. Login-item registration
was disabled, and the QA app was stopped afterward. The installed app and runtime
were not upgraded or interrupted. Local signing was ad-hoc, without notarization.

Selected evidence remains here; temporary builds and artifacts are cleaned after
published-asset verification. No OrbStack or power/throughput benchmark was run.

## Published artifact verification

[Conjet 2.1.2](https://github.com/omega13-engr/conjet/releases/tag/conjet-v2.1.2)
was published from `a51f85fe66a5c636403716c7fcdf0295f1397f99` by successful
[release run 34575638113](https://github.com/omega13-engr/conjet/actions/runs/34575638113).
The downloaded arm64 DMG has SHA-256
`8503672246d67492361e34b79ccb4f461251775293998b70b4306ed855b7ae10`.
The downloaded artifact passed integrity, version, deep/strict signature,
bundled executable, hypervisor entitlement, and Homebrew metadata checks. Its
actual signature is ad-hoc with hardened runtime; it is not notarized.

The [published-app screenshot](conjet-2.1.2-published-isolated.png) verifies that
the downloaded app launches and resolves its bundled tools against a separate,
offline QA home. Background registration was disabled, no runtime was started,
and the exact QA app process was stopped afterward. This launch check does not
replace the earlier native/HVF and Docker memory-reclamation evidence.

[Homebrew PR 29](https://github.com/omega13-engr/conjet/pull/29) was approved and
merged as `056258288095f96c8de7d735a44b1d8236f111de`. The merged formula and cask
are byte-identical to the corresponding release assets.

## Additional CI observations

The separate source CI run `34575638027` stopped producing test output after
`testHVFSmokeResultDecodesOldPayloadWithoutEntitlementStatus` started at
07:47:03 UTC. No assertion or stack trace followed. It was cancelled at
08:01:02 UTC after the Homebrew merge started another main-branch run under the
workflow's cancel-in-progress concurrency policy. This log position alone does
not establish a defect in that decoding test. The release workflow completed
its full Swift suite on the same source commit.

The Homebrew pull-request workflow `34576468267` reported failure without any
jobs or check runs; GitHub supplied no downloadable log. This is retained as an
unexplained workflow-start failure, not a passing test result.

The temporary release QA root was removed after confirming that its app
processes had exited and all QA disk images were detached. The retained
[cleanup record](cleanup.json) identifies the removed root. The installed app
was observed at version 2.1.0 and was not upgraded.

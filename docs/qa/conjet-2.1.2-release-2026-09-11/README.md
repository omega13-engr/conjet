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

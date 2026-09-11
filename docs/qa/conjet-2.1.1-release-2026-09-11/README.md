# Conjet 2.1.1 packaging QA

The release was staged from an isolated source snapshot under `/tmp`. Its
production source matches memory-fix commit `fe3820c`; only documentation and
retained log formatting changed after the snapshot. The Swift suite, optimized
Rust suite, and explicitly entitled optimized HVF regressions completed without
failures. Platform-specific skips remain. The earlier
[host backing QA](../jetstream-backing-2026-09-11/README.md) records the real
ChumMem/Docker memory workload checks.

The ad-hoc signed app passed deep, strict signature verification. Its read-only
DMG passed `hdiutil verify`, mounted successfully, contained the CLI, daemon,
and bundled Jetstream VMM, reported app version 2.1.1, and ran CLI/VMM help.
Both generated Homebrew definitions passed Ruby syntax checks.

The [screenshot](conjet-2.1.1-isolated.png) shows the staged app resolving bundled
tools and the deliberately offline QA `CONJET_HOME`. Login-item registration
was disabled. The QA app was stopped afterward; the installed runtime was not
started, stopped, or upgraded.

The local DMG SHA-256 was
`b0e36b3b20be5a90b44e31b0753fc50af396ae741bf5ee204d7135eeb58bab4c`.
This is a local packaging checksum; GitHub builds and checksums its own release
artifact. The guest asset lane remains Core 1.3.0. Ad-hoc signing does not provide
Apple notarization. No benchmarks were run.

The first [GitHub CI run](https://github.com/omega13-engr/conjet/actions/runs/34570342243)
failed `testPulseConnectedForegroundVolumeRefreshLoadsVisibleResourceInventory`
at assertions on lines 427–428: the recorded commands did not yet contain
`volume ls` or `system df`. The unchanged test uses a fixed 200 ms delay and
passed in the local suite. CI was rerun on the same commit to check the
intermittent failure; the linked run contains both attempts. No test assertion
or application behavior was changed to bypass this failure.

Temporary builds, disks, sockets, and staging directories are removed after
published-asset verification. Selected QA evidence remains in this directory.

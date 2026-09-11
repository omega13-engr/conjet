# Conjet 2.1.0 packaging QA

The release was staged from an isolated working-tree snapshot under `/tmp` with
Conjet 2.1.0 and Core 1.3.0 version files. The Swift suite, Rust suite, native
memory-fixture checks, and memory ownership-ledger checks completed without
failures. The default suites retain their platform-specific skips. Real
Linux/HVF memory validation is documented separately in the
[dynamic-memory E2E report](../../jetstream-memory-e2e.md).

The ad-hoc signed app passed deep, strict signature verification. Its read-only
DMG passed `hdiutil verify`, mounted successfully, contained the bundled CLI and
VMM, reported app version 2.1.0, and ran the CLI help command. Both generated
Homebrew definitions passed Ruby syntax validation.

[The screenshot](conjet-2.1.0-isolated.png) shows the staged app resolving bundled
tools and displaying its deliberately offline, isolated `CONJET_HOME`. Login-item
registration was disabled for QA. The user's runtime was not started or stopped.

The local DMG SHA-256 was
`00d96b91fa487f6c8984fa8520df684b9f5d1080f9cb3d868b82ff8156cffae8`.
This is a local packaging artifact; the published workflow build has its own
checksum. No benchmarks were run. Ad-hoc signing does not provide notarization.

Release preparation corrected two validation issues:

- The minimal Linux builder omitted the newly required `patch` executable.
  Both the local rehearsal and GitHub kernel builder now install it explicitly.
- The reclaim-worker test included libc headers before defining `_GNU_SOURCE`,
  which hid declarations such as `O_CLOEXEC` and `nanosleep` under strict C11 on
  Linux. Defining the feature macro first fixes the test; the regression script
  then completed on Linux and macOS. The production worker already defined it
  before its headers.

The first full rootfs rehearsal also exhausted the disposable builder's root
storage during image zero-filling (`EMPTY: Input/output error`, with loop-device
space-allocation errors). The QEMU test setup had not identified its separate
64 GiB data disk to the guest storage service. The QA-only setup was corrected
to mount that disk at `/var/lib/docker` before retrying the rootfs stage. This
did not change the user's runtime or project storage defaults.

The patched Linux 6.12.86 kernel build completed in the local ARM64 Linux
container. The rootfs retry also completed, producing the Core 1.3.0 ARM64
Docker appliance and its metadata/checksum triplet. Its SHA-512 and gzip
integrity checks passed. GitHub's main CI run
[34557137894](https://github.com/omega13-engr/conjet/actions/runs/34557137894)
completed successfully, including app/DMG and package validation.

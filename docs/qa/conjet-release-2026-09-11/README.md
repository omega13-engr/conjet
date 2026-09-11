# Conjet 2.1.0 packaging QA

The release was staged from an isolated working-tree snapshot under `/tmp` with
Conjet 2.1.0 and Core 1.3.0 version files. The Swift suite, Rust suite, native
memory-fixture checks, and memory ownership-ledger checks completed without
failures. Platform-specific ignored tests are covered separately in the
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

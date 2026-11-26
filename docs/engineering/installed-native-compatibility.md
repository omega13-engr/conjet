# Installed Native Docker compatibility for Conjet 3.1.0

## Exact ad-hoc candidate

| Item | Identity |
| --- | --- |
| Runtime revision | `748c2a7244b4ed83df9a892c230fe2098819d922` |
| Package | `conjet-3.1.0-native-docker-adhoc-arm64.dmg` |
| SHA-256 | `025e97e3bd5e360ad1d58d963b3fc16af694b07cc3e7354eaf330546f9eed321` |
| Test host | Apple M1 Pro, macOS 27.2.1 |
| Pinned clients | Docker 29.10.1, Buildx 0.39.1, Compose 5.8.0, plus the frozen direct BuildKit clients |
| Hosted CI | [Source workflow 45741104193](https://github.com/omega13-engr/conjet/actions/runs/45741104193) |

The repository scripts staged the app with SwiftPM and Cargo release builds.
The Linux guest supervisor, memory helpers, and Conjet Core 1.3.1 kernel match
the verified files from the previous evaluation. The app was copied from
the verified read-only DMG to ExternalSSD. Strict signature verification
and file hashes covered the installed app, its menu helper, the bundled and
loose tools, and the NativeCore payload. The raw inventory and client hashes
are in the evidence archive.

The launcher used the installed `conjet start --json`. It authenticated the
private Docker socket's peer PID, checked the installed daemon and Jetstream
process paths, and verified the ordinary Native Docker selection, two vCPUs,
2 GiB ceiling, 16 GiB volume disk, and Core memory ownership. Each accepted
lane released its disk lease and removed its adapter socket and session.

## Frozen results

| Suite | Pass | Required |
| --- | ---: | ---: |
| Lifecycle | 12 | 12 |
| Images | 7 | 7 |
| Credentials | 3 | 3 |
| Builds | 15 | 15 |
| Compose | 6 | 6 |
| Control | 7 | 7 |
| Storage and network | 4 | 4 |
| Stress | 6 | 6 |
| Core memory | 4 | 4 |
| Regression canaries | 7 | 7 |

All 12 lifecycle groups completed 24,000 measured operations plus 120
warmups. Every row has a verified guest teardown and zero operation
or cleanup errors. The strict packaged verifier returned exit status 0.

## The 13 previously open cases

| Cases | Observed result on the installed package |
| --- | --- |
| Go and Rust Buildx, four cases each | Both cold-store lanes fetched the language image and Alpine over public HTTPS. They verified the original empty-cache, unchanged, source-change, and dependency-change operations. The first Go attempt timed out in Docker Hub preload. The fresh-profile replay used the same installed package and pinned clients. The failed attempt is retained. |
| Registry faults, shared layer, registry regression | The task-owned loopback registry produced the intended digest rejection and interrupted transfer, verified retry and state cleanup, and exercised shared-layer reference counting with the original image deletion guard. |
| Independent memory pressure and active churn | With the normal volume disk mounted, the service fixture grew Core from 448 MiB to 2,048 MiB with zero active containers. Active churn preserved the data checksum while the cgroup high-event count increased from 137 to 171. Core returned to 448 MiB with the verified ledger and free-page reporting. |

The ordinary launcher accepts three explicitly scoped qualification inputs
for these cases. Cold-build and registry tests omit the adapter's host
image seed. The guest still boots from the package's verified OCI layout.
The registry input allowlists the one private loopback fixture port.
The pressure input runs the original service fixture beside the mounted
volume disk. The gate requires the same installed binaries and storage
and checks the original assertions. Five negative tests rejected an unknown
mode, an invalid registry port, prior engine state, a foreign Docker
configuration, and a missing registration-disable setting.

The [earlier packaged evaluation](packaged-native-release-evaluation.md)
recorded 58/71 on source `5e6c44a`. The separate `c8cc705` benchmark
cohort recorded 71/71 compatibility and 81 passing Kiri comparisons out
of 91 attempted. This evaluation collected no new Kiri timings.
[Original benchmark cohort](docker-benchmark-results.md#speed-065-docker-29101-comparison)

## Package and recovery checks

- Relocated formula and cask layouts each started their own bundled VMM
  through a symlinked CLI and ran Alpine. Both rendered definitions passed
  Ruby syntax checks. Missing boot metadata and VMM, a damaged kernel,
  a mismatched OCI blob, and an unsupported CPU setting were rejected
  before a Docker socket appeared.
- After separate forced daemon, VMM, and adapter exits, the first ordinary
  start recovered the private Docker socket. Stop removed the socket and
  session and released the disk lease in each case.
- A named volume and a verified immutable image survived restart. The
  test re-ran the image with pulling disabled and checked the persisted
  receipt. The writable container layer and image alias expired at stop.
- The published 3.0.0 appliance wrote a named volume. The candidate
  read the original bytes, ran Native Docker on its separate disk,
  and switched back to the appliance. The published 3.0.0 CLI then
  started successfully and read the same bytes. SHA-256 stayed stable
  for each engine disk while inactive. Three detached ext4 checks passed.
- The desktop and the bundled menu helper each used their own bundled
  tools and private sockets. Start, Restart with a new daemon PID, and
  Stop passed in both windows. Six screenshots and the launcher receipts
  are in the archive. The system menu item click and Developer ID login
  registration were outside this isolated run.

## Verification and evidence

The exact product source passed the hosted macOS workflow. Local
`swift test` ran 444 tests with two skips and zero failures.
`cargo test --workspace --locked` passed 225 with three ignored.
The host Go helper tests, Rust format, workflow lint, shell syntax,
Python parsing, and diff checks passed. The previous evaluation records
the unchanged strict host Clippy diagnostics and the packaging ShellCheck
findings.

The DMG, SHA-256 sidecar, raw test results, failed Go attempt, qualification
scripts, and UI screenshots are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/release-readiness/748c2a7/`.
The archived gate was checked again with the exact revision.

```sh
python3 benchmarks/native-compatibility-gate.py --packaged \
  --evidence "$archive/verification/frozen" \
  --revision 748c2a7244b4ed83df9a892c230fe2098819d922
```

Production runtime, Docker context, and host configuration fingerprints
matched. The QA runtime processes exited, the mounted DMGs detached, and
the disposable test workspace was removed. The evaluation is suitable for
local use on Apple silicon. Independent review, Developer ID signing,
notarization, stapling, and verification of the resulting production DMG
checksum remain release gates. [PR #33](https://github.com/omega13-engr/conjet/pull/33)

# Packaged Native Docker evaluation

Proposed release version **3.1.0**. The **ad-hoc Apple silicon candidate** is
available for local evaluation. Production promotion remains held.

## Exact package

| Item | Identity |
| --- | --- |
| Runtime source | `5e6c44a96b690d335b04bb4e71bc586a5fb8e98b` |
| Package | `conjet-3.1.0-native-docker-adhoc-arm64.dmg` |
| Package SHA-256 | `8670f40ad8f26dad55fc95d998fd4c48ca736bdac9e130862cc1e39b12818e10` |
| Host | Apple M1 Pro, macOS 27.2.1 |
| Docker clients | Docker 29.10.1, Buildx 0.39.1, Compose 5.8.0 with the frozen executable hashes |
| Hosted source CI | [Run 45644066981](https://github.com/omega13-engr/conjet/actions/runs/45644066981), passed |

The stage script used SwiftPM release, Cargo release, ad-hoc signing, and
the checked-in Conjet Core 1.3.1 Linux 6.12.86 kernel SHA-512. The package
reused the exact Linux supervisor and memory helpers from the
`161411d` package. Their source trees and the Rust lockfile were
identical at both revisions. The app, menu bar helper, and loose CLI
layout carry the same native assets. The artifact inventory hashes the
app executables, CLI, daemon, host VMM, guest supervisor, kernel, both
memory helpers, OCI files, and disk template.

The local test used the read-only mounted DMG and the normal CLI and
daemon, with private homes and Docker configuration under ExternalSSD.
Fresh profiles selected Native Docker without engine flags. The runner
checked two vCPUs, a 2 GiB ceiling, a 16 GiB disk, and the actual kernel
peer PID for the private Docker socket. The packaged boot reported
`experimental: false`.

## Gate results

| Check | Result | Evidence |
| --- | --- | --- |
| DMG, app and staged installer layouts | PASS | Read-only DMG verification, ad-hoc signatures and entitlement checks, ARM64 payload and kernel hash. The cask and formula layout tests launched their own VMM via symlinked tools and ran an Alpine container. Both rendered Homebrew files passed Ruby syntax checks. |
| Packaged defaults and asset failures | PASS | Normal CLI/daemon startup selected native; missing metadata and VMM, damaged kernel, mismatched OCI blob, and unsupported resource overrides failed before a Docker listener appeared. A separately retained absent-blob attempt returned generic filesystem error text. |
| Frozen compatibility | FAIL | 58 of 71 cases passed. All cases retain their original proof requirements. |
| Workload-driven Core memory and crash recovery | PASS | 448 → 2,048 → 448 MiB, a matching active checksum, verified memory ledger and free-page reporting. Forced daemon, VMM and adapter exits recovered on the next ordinary start. Stop removed the private sockets and sessions and released each volume lease. |
| Independent pressure and service churn | BLOCKED | The original test service cgroup stayed empty throughout the mounted-volume boot. |
| Persistence and 3.0.0 rollback | PASS | An explicitly created named volume and an immutable image survived restart. A writable layer and alias expired at the boot boundary. Released 3.0.0 wrote appliance volume bytes. The 3.1.0 candidate read them and switched to native, restored the appliance runtime, and allowed the published 3.0.0 CLI to read the bytes again. SHA-256 matched on each inactive engine disk. Read-only ext4 checks passed. |
| Desktop and menu helper QA | PASS | Isolated app and menu helper windows exercised their own start, status, restart and stop flows. The desktop pulled pinned Alpine and displayed the live-switch error and fixed limits. Eight screenshots are retained. The system status item click and Developer ID login registration remain unverified. |
| Production isolation | PASS | The production app/runtime and Docker/SSH/configuration fingerprints matched, the QA processes exited, and both DMGs detached. |

## Frozen compatibility results

| Suite | Pass | Required |
| --- | ---: | ---: |
| Lifecycle | 12 | 12 |
| Images | 5 | 7 |
| Credentials | 3 | 3 |
| Builds | 7 | 15 |
| Compose | 6 | 6 |
| Control | 7 | 7 |
| Storage and network | 4 | 4 |
| Stress | 6 | 6 |
| Core memory | 2 | 4 |
| Regression canaries | 6 | 7 |

The 12 lifecycle groups completed 24,000 measured operations and 120
warmups with zero failed rows. The original stress attempt hit a Docker
Hub timeout during the OOM setup pull. A fresh session on the same package
completed the frozen stress lane, including the OOM and cancellation
witnesses. Both attempts are retained.

Node, Go and Rust completed their original Buildx invocations, including the
build and executable witnesses. The Go and Rust base-image claims require a
public Alpine transfer. The packaged engine served Alpine from its bundled,
digest-verified cache while it fetched the Go and Rust manifests over public
HTTPS. Their eight rows remain open under the existing gate. The original
deterministic registry fault checks require an explicitly allowlisted
synthetic loopback fixture. The ordinary engine rejected that authority at
its allowlist, and the raw case retains that rejection. The controlled
Docker registry service is a separate frozen workload.

The Core pressure canary sampled an empty service cgroup on the ordinary boot
and timed out before exercising its pressure or churn assertions. Its original
fixture requires a dedicated boot without the mounted volume disk. The
ordinary boot passed workload-driven memory growth and idle reclaim with
authenticated ownership and checksum evidence.

The open cases are the four cache and source variants for each of Go and
Rust, `images/registry-faults`, `images/shared-layer`,
`regression/registry-local`, `memory/pressure`, and `memory/churn`.

The earlier `c8cc705` optimized benchmark artifacts still record
71/71 frozen compatibility cases and 81 passing Kiri comparisons out of 91
attempted pairs. Their results apply to that earlier artifact set.
[Original cohort](docker-benchmark-results.md#speed-065-docker-29101-comparison)

## Engineering changes

- Fresh packages declare the default independently of boot-asset availability.
  Managed Native Docker resolves the VMM from its own package and avoids an
  external fallback when the packaged executable is missing.
- The daemon reaps a previously observed private session directory after
  VMM loss. It verifies containment and ownership and leaves foreign paths and
  symlinks alone.
- The app shows the native resource limits and profile-private binds, handles
  Docker CLI JSON inventory, and rejects a live runtime switch. The Dockerfile
  editor remains available in appliance profiles.
- Managed builds record pinned registry object provenance. The storage
  runner places the original bind fixture in the packaged runtime's private
  bind directory. The frozen manifest, workloads, counts and gate assertions
  are unchanged.

## Verification and custody

The local package and evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/release-readiness/5e6c44a/`.
The package checksum and the eight JPEGs sit beside the verification
directory. The verification directory contains the exact executable hashes,
raw lane and failed-attempt logs, package and profile results, the frozen
case ledger, and the task-owned launcher scripts.

Local `swift test` reported 444 tests, two skips and zero failures.
`cargo test --workspace --locked` passed 225 tests with three ignored.
`go test ./...` in the network helper, Rust format, Bash syntax,
workflow lint and `git diff --check` passed. ShellCheck reported the same
four existing findings in the two packaging scripts. Host Clippy reported
13 errors in unchanged PSCI and HVF FFI files. The hosted source workflow
passed Swift, Rust/host networking, app staging, DMG, Homebrew and the
benchmark package checks.

The frozen verifier was run as recorded below. The exit status was 1 for
the open cases. The compatibility report identifies every case individually.

```sh
python3 benchmarks/native-compatibility-gate.py \
  --evidence "$archive/verification/frozen" \
  --revision 5e6c44a96b690d335b04bb4e71bc586a5fb8e98b
```

The implementation received a self-review focused on the exact diff and
acceptance evidence.

Developer ID signing, notarization, stapling, and independent review remain
production gates. PR #33 stays draft while the frozen gate is incomplete.

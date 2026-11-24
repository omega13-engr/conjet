# Native engine validation

## SPEED-057

The Apple silicon host ran six private `conjet-speedup` boots using the
release host and ARM64 musl guest built from `764aea5` with `cargo build
--locked --release`. The host used the repository debug entitlements for
local HVF execution. Swift sources were unchanged from the pinned SPEED-049
release CLI's branch revision. The Core kernel and Alpine artifacts came from
the frozen fixture. Exact commands and SHA-256 identities are in each
`launcher.json` under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-057/verified-*`.

`run-conjet-speedup.py` checked the VM process executable after the native
session manager authenticated its guest. It read the live initramfs inventory,
matched `/init` to the supplied release supervisor, and verified the 16 MiB
block device was empty. The 532-entry archive exposed only the supervisor at
the guest root and staged the pinned Alpine files under the separate OCI root.
It contained no dockerd, containerd, shim or runc executable. The VM configuration
had no other root, data or swap disk and bound the native launch vsock. The Rust
Docker owner also ran from the verified release VMM executable. The control
fixture authenticated the owner socket, inspected its `Conjet Native OCI`
platform and verified a distinct `jetstream-native-oci` guest cleanup witness
for each of 176 API and CLI lifecycles.

| Capability | Implementation and current release evidence | Boundary |
| --- | --- | --- |
| Fresh lifecycle and OCI staging | `jetstream/src/native/{docker,session}.rs` and `guest/launch-service/src/{fresh_fixture,kernel_fixture}.rs`. Control and concurrency exercised create, start, wait, forced remove, duplicate rejection, exit 0 and exit 23. | Pinned Linux ARM64 Alpine. Concurrency exercised eight container identities. |
| Output and exec | `guest/launch-service/src/{output,exec_fixture}.rs` and the Rust Docker owner. Control, streaming and exec checked separate stdout/stderr, exit reporting, overflow and disconnect handling. | Control includes 65,535 and 65,536 bytes accepted and overflow rejected. Native limits and the existing exec subset still apply. |
| Network and published ports | `guest/launch-service/src/bridge_fixture.rs` and the owner's network and port handlers. The dedicated controls exercised private bridge/DNS and loopback port forwarding. | Only the fixture-backed private bridge and supported TCP publication are qualified. |
| Image, storage, BuildKit and Compose | The pinned image was available by digest. Control rejected bind mounts with HTTP 400 and the build endpoint with HTTP 501. | Registry/import results from earlier work do not qualify this release. Named volumes, durable recovery, BuildKit and Compose remain open. |
| Resource and sandbox controls | `guest/launch-service/src/{spec,cgroups,security}.rs` enforce bounded arguments, user mapping, cgroups, namespaces and seccomp. The matched fixture uses 16 MiB, four PIDs, 0.5 CPU and UID/GID 65532. | The experimental guest allows 16–256 MiB, 1–64 PIDs and 10–1,000 millicores per workload. A small fixture does not establish broad OCI or sandbox compatibility. |
| Core dynamic memory | Shutdown confirmed virtio free-page reporting and zero reclaim failures on every boot. | This boot path disables the Core governor and omits its memory bridge. Growth, pressure response and idle shrink remain SPEED-058 gates. |

Every boot acknowledged guest cleanup, removed the private session and owner
socket, and matched its production fingerprint before and after. These
functional canaries do not qualify performance or compare with Kiri.
Independent evidence review remains pending.

## SPEED-066

The release native memory canary booted the existing Core `conjet-memd` and
`conjet-reclaimd` as trusted static ARM64 executables in the isolated
initramfs. The live archive matched all three guest executables. The guest
only exposed the native and memory bridges and kept daemon and service cgroups
separate from the per-workload cgroups. PID 1 owned the guest memory helper
process group through supervisor restart and shutdown.

The Core endpoint returned known available memory and complete telemetry for
the same service cgroup before, during and after a fresh 16 MiB, four-PID,
0.5-CPU Alpine workload. Active count was 0 → 1 → 0 and container charge was
0 → 131,072 → 0 bytes. The launcher confirmed zero reclaim failures, guest
shutdown, no remaining session or sockets, and matching production
fingerprints. Exact artifact hashes, commands and metric snapshots are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-057/verified-memory-telemetry/`.

The C cgroup regression suite passed, as did `cargo test --locked --workspace`
(171 passed, three ignored). The unmodified Clippy configuration reported
existing 32-bit PSCI enum and raw-pointer FFI lint errors. This increment
keeps Core policy activation gated pending generation-scoped admission. It
verifies telemetry transport and native ownership classification. Balloon
growth, pressure-time integrity and idle shrink remain SPEED-058 work.

## SPEED-067

The isolated native Core governor starts with a private authenticated guest
ledger. A launch stays pending until the exact boot, workload ID and
sequence receive a capacity grant. The VMM grants after the Core target and
actual balloon converge at configured capacity. Loss or expiry of the
observation keeps the controller in its active policy. A workload with
unresolved cleanup continues to count as owned. The matched timing entry
point now requires this dynamic-memory path and both Core helpers.

The live canary shrank from 2,048 MiB to 448 MiB, grew to 2,048 MiB from
that reduced state to launch the canary, then shrank again. It observed
409,600 balloon pages at the reduced target and zero after growth. About
1.56 GiB of balloon-owned backing was released at the first idle target.
A nonzero 4 MiB payload matched its expected SHA-256 before and after 12
independent guest lifecycles. The stale boot, reused workload ID with the
wrong sequence, and duplicate grant each received an explicit rejection.
A 10 ms admission from the reduced target expired without executing or
retaining guest resources.
Workspace tests passed (173 passed, three ignored), including the
missing, invalid and stale observation tests. Earlier canary scripts tried
a shell pipeline that the current syscall policy rejects. The final fixture
uses shell builtins and the supported exec subset at the same limits.

Raw samples and launcher identity are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-057/core-dynamic-final/`.
Independent service pressure and a live fault at the unresolved cleanup
boundary have separate acceptance evidence. Growth from workload demand
alone does not meet the pressure gate.

## SPEED-068

The pressure diagnostic boot enabled a guest-only service in the existing
Core service cgroup. It used the kernel's `memory.high` throttle at 16 MiB,
with a 96 MiB hard bound and a 30-second helper lifetime. The helper is
absent from the normal workload and benchmark boots.

There were no containers when Core grew from a converged 448 MiB to 2,048
MiB. The independent service had generated 153 `memory.high` events and
Core reported one service expansion. The same 4 MiB payload matched its
SHA-256 before and after 12 fresh native launches, with 272 high events and
13.22% guest full PSI average recorded by the end of churn. After both
owners drained, the original PSI guard deferred idle shrink. The guest fell
below the idle PSI thresholds at 86.54 seconds from boot observation, and
the 448 MiB target converged at 105.68 seconds, about 19.1 seconds later.
Both shrink cycles authorized about 3.12 GiB of cumulative balloon-owned
backing release. Ownership violations and reclaim failures remained zero.

Earlier runs retained their failures. One collection predicate counted
only workload expansions, and a shorter observation ended before the
existing PSI threshold and retry interval permitted shrink. The final run
recorded PSI recovery directly with the governor's policy unchanged.
The launcher verified clean guest shutdown, socket and session removal,
and production preservation. Raw evidence and artifact hashes are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-057/core-pressure-final/`.

## SPEED-059

Both release boot pairs ran pinned Alpine ARM64 with UID/GID 65532,
16 MiB, four PIDs, 0.5 CPU and no networking. Each leg passed 200 timed
operations and ten warmups in each API and CLI lane. The initial pair ran
Conjet then official Kiri 0.2.2. The second reversed that order. The native
VMM confirmed the Core governor and backing ledger before and after both
measurement windows. The workload was warm at 2 GiB in those snapshots.
The same release artifacts passed the reduced-capacity pressure diagnostic.

| Pair | Engine | Lane | p50 ms | p95 ms | p99 ms | Verified ops/s |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 1 | Conjet native | API | 77.49 | 86.75 | 97.47 | 12.69 |
| 1 | Kiri | API | 3.67 | 4.27 | 5.47 | 263.98 |
| 1 | Conjet native | CLI | 67.20 | 74.89 | 76.43 | 14.65 |
| 1 | Kiri | CLI | 19.96 | 20.75 | 21.21 | 49.96 |
| 2 | Conjet native | API | 77.15 | 86.93 | 90.40 | 12.68 |
| 2 | Kiri | API | 3.70 | 4.24 | 4.56 | 264.28 |
| 2 | Conjet native | CLI | 68.45 | 76.41 | 79.91 | 14.29 |
| 2 | Kiri | CLI | 20.16 | 21.33 | 27.32 | 48.70 |

Conjet's API medians were 20.85–21.09× Kiri's. CLI medians were 3.37–3.39×.
No boot met the sub-5-ms native API target. The two-pair pilot has no formal
paired 95% bound and establishes no parity. The host API wait median was
75.08–75.58 ms. Create was 0.43–0.44 ms, start 0.35–0.37 ms, and remove
0.94–0.99 ms. These API client spans do not yet attribute guest execution
or the Core admission exchange.

The Conjet VMM finished each leg at about 159 MiB RSS and 5.4–5.5 CPU
seconds. The Docker owner finished around 8.3 MiB and 0.54–0.56 CPU seconds.
Kiri's VM finished at 186 and 230 MiB RSS and 1.69–1.73 CPU seconds.
The longer Conjet windows prevent treating these snapshot totals as a
matched energy comparison. Conjet verified terminal guest cleanup for
each lifecycle. Kiri's guest-level teardown remains unobservable with
this harness. Both launcher pairs verified host cleanup and production
preservation. Independent-host and privileged energy results remain open.

Raw samples, stage data, host observations, launcher commands and hashes
are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-059/`.

## SPEED-060

In the host-only admission trace, VMM observation to approval had a
0.113 ms median. Once approved, the launch grant waited a median 32.99 ms
for the session manager. The grant exchange itself took 0.375 ms. This
identified a delay before grant delivery inside the API wait span. Both
measurements used the VMM's host monotonic clock.

The controller now notifies the session manager when it grants the current
admission. The manager checks the same predicate under the lock to handle
approvals sent before it starts waiting. At 185 accepted grants per
diagnostic, the median approval-to-send interval dropped to 0.012 ms
and p95 dropped from 39.93 ms to 0.021 ms. Observation cadence, the 25 ms
safety tick, stale checks and the guest cleanup boundary remain in use.

| Pair | Mode | API p50 / p95 / p99 (ms) | CLI p50 / p95 / p99 (ms) |
| --- | --- | ---: | ---: |
| 1 | Poll | 76.08 / 87.03 / 93.43 | 67.53 / 76.24 / 79.81 |
| 1 | Event | 40.86 / 68.18 / 75.01 | 35.02 / 54.41 / 64.85 |
| 2 | Event | 39.99 / 65.55 / 77.86 | 35.64 / 51.54 / 57.12 |
| 2 | Poll | 76.04 / 85.24 / 89.35 | 67.49 / 75.91 / 78.28 |

Both alternating pairs used the same release binary, disabled tracing,
and passed 200 timed operations plus ten warmups per lane and leg. Event
mode passed growth, payload, churn, independent pressure, PSI recovery
and idle shrink canaries. The event path is now the default for native
Core admission. This comparison isolates the admission change within
Conjet. Kiri parity and a sub-5-ms API median remain unqualified.

Raw grants, A/B launcher settings, stages and memory evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-060/`.

## SPEED-061

Read-only `e2fsck -fn` on a disposable copy of the archived ext4 disk
reproduced eight zero deletion timestamps and exit 4. The archived guest's
readiness fix required a host time parameter that the recorded boot command
and host boot configuration never supplied. The current initramfs carries a
fixed-size filesystem UUID and trusted host time. PID 1 sets the time before
mounting, then unmounts the verified disk after draining workloads. The VMM
uses a duplicate of the leased descriptor and flushes it before releasing
the lease.

Four dynamic-memory boots used the same private 128 MiB host inode. The first
created eight volumes, two later boots observed the same eight guest inode
and ownership records, and the fourth removed all eight. An offline-seeded
payload retained its SHA-256 after each of the two recovery boots. Offline
`e2fsck -fn` exited 0 after all four boots, including after deletion. Each
launcher verified cleanup, unlocked disk access and unchanged production.
The candidate rejected a second lease, a symlink and an invalid filesystem
before boot. The authenticated registry rejected traversal, a ninth volume
and a stale boot generation.

Workspace tests passed (175 passed, three ignored). Logs, exact commands,
hashes and registry replies are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-061/`.
Container writes, read-only mounts and deletion while a mount is live remain
SPEED-062.

## SPEED-062

The Docker API can create, list, inspect and delete local named volumes on
the leased disk. A container may attach one existing volume to `/data`.
The host refuses removal while a container references it, and the guest
refuses removal while a native workload still owns it. The guest checks
the inode in the workload mount namespace before binding and retains the
workload lease through cgroup and sandbox cleanup.

Release boots passed writable data, replacement container reads, read-only
failure with unchanged bytes, mapped 65532:65532 ownership, mode 0700,
Docker and guest busy-delete rejection, and forced cancellation with exit
137 and complete guest cleanup. The second boot read the guest-written
payload from the same private disk, removed the volume and passed offline
`e2fsck -fn`. Both boots released the disk lease and preserved production.
The saved failure cases show the old cross-namespace bind returning
`EINVAL` and the intermediate identity check using outer IDs in the child.

The supported Docker form is `--mount type=volume,source=NAME,target=/data`
with optional `readonly`. The destination must be absent or empty in the
image. Bind propagation, host binds, anonymous volumes, additional mounts
and custom drivers remain outside this fixture.

Evidence is under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-062/`.

## SPEED-064

Compose 5.8.0 ran the pinned two-service fixture against the private Rust
owner with Core dynamic memory. The diagnostic created the external private
network and named volume before up and removed them after down. The writer
created a file on the volume, and a bounded guest exec healthcheck read its
state before Compose started the dependent reader. A scoped event
subscription observed both starts in dependency order.

The reader resolved the writer to its private bridge address. Compose
returned both service log lines and reported the actual loopback TCP
endpoint. The endpoint returned HTTP 200 with the exact `compose-proof`
payload. The writer's replacement generation became healthy after
`compose restart` and read the same volume bytes. Compose down left no
containers, and the launcher confirmed port closure, verified guest shutdown,
the disk lease release and unchanged production. Offline `e2fsck -fn`
passed. The exec proof disables both TTY and interactive stdin to match
the existing noninteractive exec contract.

Earlier attempts isolated filtered discovery, two DNS aliases, bounded
health, the named-volume short form, filtered event streaming and active
port metadata. Those failures and the successful Compose and Docker API
transcripts are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-064/`.

## SPEED-065 historical release pilot

This pilot predates the pending-demand watch. The latest release pilot
is in the [native latency results](native-latency-diagnostic-results.md#post-change-kiri-pilot).

Two independent release pairs alternated native-first and Kiri-first.
Each VM ran ten warmups and 200 measured operations per API and CLI lane,
for 80 warmups and 1,600 measured operations overall. All operations and
the UID and stream probes passed. The native runs used Core dynamic memory
and were at the 2,048 MiB target before and after timing. Native guest
cleanup and isolated launcher cleanup passed. Kiri guest teardown was
unobservable.

| Pair | Engine | API p50 / p95 / p99 (ms) | CLI p50 / p95 / p99 (ms) |
| --- | --- | --- | --- |
| 1 | Conjet native | 40.35 / 67.77 / 73.13 | 38.80 / 60.06 / 69.01 |
| 1 | Kiri 0.2.2 | 3.82 / 4.48 / 4.88 | 20.75 / 21.86 / 22.39 |
| 2 | Conjet native | 39.53 / 67.13 / 75.10 | 37.94 / 56.64 / 62.93 |
| 2 | Kiri 0.2.2 | 3.87 / 4.51 / 4.80 | 20.88 / 21.83 / 22.17 |

The native API median was 10.2–10.6 times Kiri's. The below-5-ms
native API target failed. The pilot does not satisfy the five-pair
statistical and workload coverage requirements for parity. The measured
OCI lifecycle excluded build snapshots and preceded the isolated
snapshot ID mapping change.

Raw samples, artifact hashes and cleanup reports are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-065/`.

## SPEED-065 release compatibility and frozen matrix preflight

The candidate source was frozen at `909b5bb`. The release native guest was
built without the temporary BuildKit test hook and booted the pinned Core
v1.3.1 kernel. The unchanged release host, Core memory helpers and pinned
Alpine image were reused. Artifact hashes are in
`SPEED-088/final-release-sha256.txt` under the evidence root.

Ten separate native release boots passed. Growth and independent guest
pressure each restored the 448 MiB idle VM to 2,048 MiB. The pressure boot
observed zero active workloads during the independent trigger. The active
data canary retained its checksum through twelve fresh launches. The VM
returned to 448 MiB with consistent Core ownership and zero reclaim
failures. The native endpoint also passed the bridge DNS, loopback port,
concurrency, exec and output streaming canaries. The owned named volume
survived reboot with its checksum, and Compose 5.8.0 passed health
ordering, service DNS, loopback publishing, volume-backed restart and
down. Offline ext4 checks, lease release, isolated teardown and production
fingerprints passed.

An eleventh boot reran the private registry canary with the two
digest-pinned fixtures. Cold and cached pull, inspect, run, shared-layer
retention, image removal and transfer-failure cleanup passed. This
diagnostic used the explicitly configured loopback store.

The frozen broader suites were then preflighted through their existing
fixture runner and pinned client tools against a separate native release
guest. Their individual rows and failures are retained under
`SPEED-065/matrix-preflight/`.

| Frozen suite | Observed boundary |
| --- | --- |
| Buildx | Rust, Go and Node builder creation and removal passed. All three bootstraps stopped on worker image acquisition in the current launcher. A separate API request returned HTTP 400 for `HostConfig.Privileged`, which the pinned Docker-container driver requests. `POST /v1.44/build` returned HTTP 501. [Buildx v0.39.1 worker creation](https://github.com/docker/buildx/blob/v0.39.1/driver/docker-container/driver.go#L144-L163) |
| Images | Staged Alpine pull and inspect worked. Tagging returned an unsupported API response. The Node and registry-image pulls stopped because the native registry store was unconfigured. |
| Compose and storage/network | The frozen Node prepull stopped with the same registry-store error. The smaller pinned native Compose and named-volume canaries passed separately. |
| Stress | All 440 launch attempts across concurrency 1, 2, 4 and 8 were refused because the frozen stress argv did not select the required non-root identity. Pressure prepull also stopped at the unconfigured registry store. The native concurrency canary with the supported identity passed separately. |

The preflight left no owned containers or builders. The direct BuildKit
RUN qualified in SPEED-063 covers a different boundary than the frozen
Docker-container driver. Extending the frozen matrix requires preserving
the source workload and effective resource policy through an explicitly
qualified builder, image and storage path.

## SPEED-065 five-pair release lifecycle

The [matched lifecycle runner](../../benchmarks/README.md#paired-docker-comparison)
compared `909b5bb` against the frozen official Kiri 0.2.2 binary in five
independent alternating pairs. Each engine and boot ran 2,000 measured
operations and ten warmups per API and CLI lane. All 40,000 operations
and 200 warmups passed with the pinned ARM64 Alpine image, UID/GID 65532,
16 MiB, four PIDs, 0.5 CPU and networking disabled. Both output streams
and deliberate exit 23 passed the separate canaries. The native controller
was enabled at 2,048 MiB before and after timing in every boot, with
consistent ownership and zero reclaim failures. The independent 448 MiB
growth, pressure and idle results above are outside the warm timing windows.

API elapsed time spans create, start, wait and removal acknowledgement.
CLI elapsed time ends at Docker process exit. The native per-operation
guest teardown witness is checked after timing and included in session
throughput. Equivalent guest teardown remains unobservable on Kiri.

| Pair | Engine | API p50 / p95 / p99 (ms) | CLI p50 / p95 / p99 (ms) | API / CLI verified ops/s |
| --- | --- | --- | --- | --- |
| 1 | Conjet native | 3.57 / 4.85 / 6.15 | 22.29 / 25.02 / 27.68 | 236.8 / 42.5 |
| 1 | Kiri | 3.67 / 4.37 / 4.85 | 21.16 / 24.51 / 29.29 | 266.3 / 46.1 |
| 2 | Conjet native | 2.69 / 3.61 / 4.36 | 21.72 / 23.89 / 26.95 | 313.7 / 43.9 |
| 2 | Kiri | 3.58 / 4.47 / 6.48 | 21.30 / 24.33 / 27.93 | 266.9 / 46.1 |
| 3 | Conjet native | 2.66 / 3.59 / 4.58 | 21.87 / 25.43 / 29.75 | 316.3 / 43.2 |
| 3 | Kiri | 3.45 / 4.19 / 4.86 | 21.17 / 24.60 / 27.35 | 274.8 / 46.4 |
| 4 | Conjet native | 3.03 / 3.98 / 5.02 | 22.23 / 23.35 / 24.52 | 281.3 / 43.0 |
| 4 | Kiri | 3.36 / 4.10 / 5.38 | 21.08 / 24.21 / 27.80 | 286.6 / 46.7 |
| 5 | Conjet native | 2.84 / 3.63 / 4.43 | 22.16 / 23.23 / 24.38 | 300.7 / 43.2 |
| 5 | Kiri | 3.51 / 4.31 / 6.91 | 21.43 / 22.34 / 22.77 | 272.5 / 46.6 |

Ratios are Conjet/Kiri geometric means across pairs with the frozen 95%
bootstrap interval (10,000 resamples, seed 615026).

| Metric | Ratio | 95% interval |
| --- | ---: | ---: |
| API p50 | 0.8367 | 0.7703–0.9143 |
| API p95 | 0.9114 | 0.8314–1.0230 |
| API p99 | 0.8637 | 0.6996–1.0586 |
| CLI p50 | 1.0388 | 1.0278–1.0499 |
| CLI p95 | 1.0078 | 0.9815–1.0337 |
| CLI p99 | 0.9870 | 0.9231–1.0553 |
| API session throughput | 1.0542 | 0.9548–1.1509 |
| CLI session throughput | 0.9301 | 0.9224–0.9403 |

The native API median met 5 ms in every boot and cleared the 5% median
advantage threshold for this workload and timing boundary. API and CLI
parity both missed the required p99 upper bound of 1.05. Native wait
accounted for 2.30–3.04 ms at p50 and 3.89–5.42 ms at p99 across boots.
The start acknowledgement itself was 0.09–0.13 ms at p50. These host
stages locate the remaining variation within the API sequence. They
cannot attribute an individual tail sample to a guest or VMM cause.

All five native launchers verified guest teardown, production preservation,
and removal of their private sockets and sessions. All five Kiri launchers
verified process and socket cleanup and production preservation. Raw
samples, per-stage timings, launch evidence, executable hashes and
host CPU/RSS observations are under `SPEED-065/final-release-pairs/`.
The hardware, energy, Kiri guest teardown and frozen workload gaps
preclude a general parity or release-readiness claim.

The candidate passed serial Rust workspace tests (184 passed, three
ignored), ARM64 Linux guest Clippy with warnings denied, Swift tests
(440 executed, two skipped, zero failures), and the Go network-helper
tests. The Rust release build and formatting checks passed. Validation
logs are under `SPEED-088/`.

Local app staging, ad-hoc signature verification, DMG checksum and
byte-for-byte checks of both staged guest copies passed. This host
refused the local read-only DMG mount with both `hdiutil` and
`diskutil`. The CI run for `909b5bb` passed release DMG creation,
mounted contents verification and Homebrew package validation.
[Candidate CI](https://github.com/omega13-engr/conjet/actions/runs/45344320151)

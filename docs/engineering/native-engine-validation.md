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

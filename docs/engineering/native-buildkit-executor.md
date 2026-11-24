# Native BuildKit executor boundary

The existing benchmark pins Linux ARM64 BuildKit 0.23.2 manifest
`sha256:771795ae105f698c5a354aecb1a1be2cf1f1c17c97b348c8b19f7cded83fb97c`.
The registry returned the same manifest digest and ARM64 config digest
`sha256:8ff6bca64af355cd0434480a0fd583a7c571211750a5eb806b992017148bab55`.
[Pinned BuildKit image](https://hub.docker.com/layers/moby/buildkit/v0.23.2/images/sha256-771795ae105f698c5a354aecb1a1be2cf1f1c17c97b348c8b19f7cded83fb97c)

The OCI worker's explicit binary setting is passed as its sole runtime
command candidate. BuildKit retains the content store, snapshotter and cache.
The runtime starts the process in the supplied bundle. The worker mounts the
writable snapshot before calling the runtime and unmounts it afterwards.
A Conjet launch that discards private overlay writes would return the wrong
snapshot even if the process exited zero. [OCI worker setup](https://github.com/moby/buildkit/blob/v0.23.2/worker/runc/runc.go#L51-L105), [snapshot mount and release](https://github.com/moby/buildkit/blob/v0.23.2/executor/runcexecutor/executor.go#L195-L230)

| Path | Required runtime boundary |
| --- | --- |
| First noninteractive Dockerfile RUN | Receive the generated bundle, mount and ownership constraints, `run --bundle … --keep ID`, stdin/stdout/stderr and exit status. Keep the snapshot lease until output drains and guest teardown is verified. |
| Cancellation and cleanup | Route `kill ID 9` to the exact active generation, then make `delete ID` release its state only after guest teardown. A process or relay error must leave uncertain ownership visible. |
| Optional Exec | BuildKit checks runtime `state` and the running bundle before invoking `exec` with a process specification and pidfile. This is distinct from the first standalone RUN and needs its own support gate. |

BuildKit 0.23.2 uses go-runc 1.1.0. The wrapper prepends global JSON log
options. The standalone solver RUN has no stdin and no started channel,
and sends separate output writers. The executor itself can also receive
signals, interactive I/O and additional mounts, which require explicit
support decisions before any native backend accepts them. [Pinned dependencies](https://github.com/moby/buildkit/blob/v0.23.2/go.mod#L18-L24), [solver call](https://github.com/moby/buildkit/blob/v0.23.2/solver/llbsolver/ops/exec.go#L465-L470), [worker RUN and exec](https://github.com/moby/buildkit/blob/v0.23.2/executor/runcexecutor/executor_linux.go#L26-L55), [cancellation](https://github.com/moby/buildkit/blob/v0.23.2/executor/runcexecutor/executor.go#L515-L552), [command assembly](https://github.com/containerd/go-runc/blob/v1.1.0/runc.go)

The first fixture can use one private Linux ARM64 snapshot with a noninteractive
process, no network and no extra mounts. Start with a snapshot identity and
lease tied to the authenticated guest boot. Then prove writable output at the
BuildKit snapshot boundary, separate stdout/stderr, cancellation with verified
cleanup, and a cached repeat that does not create a second native workload.
The native Docker endpoint still returns an explicit unsupported response to
`/build`.

## SPEED-070 snapshot canary

A release native guest with Core dynamic memory mounted a private 128 MiB
ext4 disk containing a pre-staged executor bundle. The launch authority
opened a single-component bundle ID beneath the leased mount, checked the
root filesystem device and inode, and gave the sandbox a private writable
bind of that exact root. The fixture wrote a proof file and stayed active
until cancellation. A second launch was rejected while the first held the
lease. Cancellation returned signal 9 and complete cleanup with stdout
drained. A replacement launch with a distinct workload ID reopened the same
snapshot and read the file with exit code 0.

The guest rejected symlinks, traversal, a stale boot, a stale inode, and
combining the snapshot with a named volume. After shutdown the launcher
verified lease release and unchanged production state. Offline `e2fsck -fn`
passed, and `debugfs` read the expected file from the original inode tree.
The canary initially used a pre-staged layout. The actual worker handoff
was captured separately in SPEED-078.

## SPEED-078 actual native snapshot and ownership

The verified BuildKit 0.23.2 Linux ARM64 release binaries ran in a disposable
Core guest with the OCI worker enabled, the containerd worker disabled,
and the native snapshotter. A private capture executable was the sole
runtime candidate. A scratch Dockerfile loaded local content and reached
its noninteractive `RUN --network=none`. The capture executable recorded
the actual `run --bundle … --keep ID` and `delete ID` invocations, then
returned exit 97 before execution. No retained runtime was present.

The live bundle's root was a writable bind from the private ext4 disk at
`worker/runc-native/executor/ID/rootfs`. The same device and inode returned
by the native identity resolver appeared in the worker's mount capture.
The root carried `nosuid,nodev` and allowed execution. Snapshot admission
now checks the pinned layout, exact inode and those mount flags.

A separate Core release canary placed UID/GID 65532 on the disk, which
matches the ownership recorded by a rootful BuildKit worker. Conjet mounted
that inode through the existing workload user namespace's ID map. The
native process saw directory UID/GID 65532, wrote the proof before
cancellation, and a replacement process reopened it after teardown.
Offline `debugfs` confirmed the resulting file on the same disk with
UID/GID 65532. The volume lease was released, `e2fsck -fn` passed and
production was unchanged. [Linux mount ID mappings](https://www.kernel.org/doc/html/latest/filesystems/idmappings.html)

The capture also recorded OCI 1.2.1 process requirements, including
supplementary groups and capability sets, and ten mounts. These include
pseudo-filesystems, worker-owned hosts and resolver files and a tracing
socket. The current native build sandbox can mount the root with the
correct ownership. The generated OCI process and mount contract still
needs handling or explicit rejection in SPEED-079. BuildKit RUN,
BuildKit-driven cancellation and cache hits remain unqualified.

## SPEED-080 guest-local authentication boundary

The isolated build snapshot profile now exposes a guest-local abstract
Unix socket for snapshot identity. The listener checks kernel peer
credentials for guest UID 0 and requires the launch service handshake.
It shares the host-visible boot generation and permits only ping and
snapshot lookup. It admits one connection at a time with a bounded idle
wait and closes with the supervised guest. A separate host connection
retains workload and shutdown authority.

The pinned BuildKit capture process looked up the live mounted root over
the guest-local socket. The response matched its actual device and inode.
A guest UID 65532 peer received EOF without a handshake. The protocol
regression test also verified that an authenticated local client cannot
launch, cancel or shut down the host service. BuildKit still deliberately
stopped before RUN during this capture.

## SPEED-086 verified bundle intake

Three earlier bundles generated by the pinned worker produced the same
canonical policy digest after binding the root and cgroup paths to their
bundle IDs, checking the worker-owned hosts file path, and extracting the
bounded argv, environment and working directory. The remaining policy
includes credentials, namespaces, capabilities, device rules, seccomp and
the ordered list of ten mounts.

The release probe replayed a captured bundle on a private ext4 disk. The
authenticated endpoint opened the config relative to the verified bundle
descriptor, required a regular root-owned file on the leased device,
enforced a 64 KiB bound, and validated the process using normal native
launch limits. The reply included its snapshot identity and policy digest.
Ten variants were refused, covering the root path, a writable mount
change, extra capabilities, a namespace override, a seccomp change,
noncanonical argv, wrong ownership, world write, oversized input and a
symlink. The endpoint performed no launch during this qualification.
The disk lease was released and both offline filesystem checks passed.

This evidence qualifies bounded config intake. Mount and process
enforcement, runtime verbs and actual BuildKit RUN remain separate gates.

## SPEED-087 and SPEED-071/079 native RUN

The opt-in build-snapshot guest profile now accepts a boot-bound runtime
request over its root-only local control socket. The standalone runtime
alias implements the pinned noninteractive `run --bundle … --keep ID`,
`kill ID 9` and `delete ID` forms. Core authorizes the workload under
the same native resource limits and generation ledger used by Docker
workloads. The service retains the build record through output EOF and
verified removal. Delete releases that ownership, and a bounded
boot-local tombstone rejects reuse of the ID.

Stock BuildKit emitted mode `0666` for `config.json` even with the fixture's
`022` umask. The authenticated RUN path can seal an exact `0666`, root-owned,
single-link regular file on the leased filesystem to `0600`, through the
opened descriptor and under the verified root-only worker directory.
Read-only config intake still rejects a writable config. Source file and
socket descriptors are checked by device and inode before mounting. On the
release kernel, direct sysfs creation under mapped user credentials returned
`EPERM`. The single-threaded helper created a detached read-only sysfs in the
child network namespace, restored its own namespace, and passed only the
mount descriptor. The workload created its own read-only cgroup mount and
retained zero effective capabilities, no-new-privileges and the native
seccomp filter. The extra group is limited to the workload's own primary GID.

Two isolated release boots ran the pinned Linux ARM64 BuildKit 0.23.2
`buildkitd` and `buildctl` from archive SHA-256
`6385ff70b2fb4134b50ac3183eea3a0b06c6f6129173940d73178ae0477368f1`.
The fixture ran the OCI worker with the native snapshotter, the containerd
worker disabled, and the Conjet alias as the single runtime. It used
`FROM scratch`, copied a static ARM64 probe and a UID/GID 65532 output
directory, then invoked `RUN --network=none ["/bin/probe", "write"]`
under UID/GID 65532. The probe checked its credentials, proc, devpts,
mqueue, sysfs, cgroup2 and the read-only hosts bind. The worker received
both output streams and exported the probe's write. Fresh and cached
exports both hashed to
`02c2c58c93b103acf14d4d57c17131585ea2baa4a47ce1672cd8d8e55b7e4643`.
The repeat reported the RUN as cached and did not invoke the runtime.
Interrupting a separate build after workload output led to worker
`kill ID 9` and `delete ID`, with signal 9 and complete cleanup on the
exact guest workload. The two solves that executed issued two runs,
two deletes and one kill.

The boots used a temporary supervised test fixture and separate ext4 disks.
Offline checks, lease release, guest cleanup, launcher removal, zero reclaim
failures and unchanged production fingerprints passed. The earlier setup
failure also reached verified removal after closing the parent's copied
helper control descriptor. Evidence is under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-088/`
in `worker-mapped-group`, `worker-final` and `worker-helper-owner`.
The guest staging hook and the fixture wrapper were test scaffolding.

This qualifies the bounded direct RUN milestone in SPEED-063. Worker
provisioning in the native Docker API and the frozen
`buildx --driver docker-container` matrix are still open. The native
profile supports one active build per boot at a time, closes stdin and
rejects interactive exec, extra mounts and policy variants. BuildKit's
stock OOM monitor looks for its original cgroup path, which differs from
the native Core-owned cgroup namespace.

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

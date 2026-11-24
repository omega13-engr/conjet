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
The canary used a pre-staged BuildKit layout. The pinned worker's runtime
invocation, uncached RUN, cancellation, and cache hit remain SPEED-071/063.

# Docker-to-native adapter contract

The isolated `conjet-speedup` launcher defaults to a private Docker adapter
connected to one authenticated Jetstream OCI session. The launcher selects
that socket through private Docker configuration. Installed Conjet, its
Docker socket and its selected context stay under production ownership.
The candidate runs pinned Linux ARM64 OCI images without networking.
The Rust Docker owner admits up to eight independent containers. The
configured boot image must be admitted before the owner advertises readiness.

## Runtime architecture

1. Bind a pinned OCI manifest to the verified config digest and uncompressed
   rootfs layer digests. Stage the bounded image in an immutable guest root.
   Preserve directory permissions and legitimate guest-relative links, and
   reject entries that cannot be represented without weakening isolation.
2. Feed OCI image defaults and supported request overrides into a native
   process spec. Follow image Entrypoint/Cmd composition, pass arguments and
   environment, set cwd and the requested supported UID/GID before exec, and
   allow the interpreter resolved inside the guest root. Document supported
   credentials, hard resource limits and unsupported security overrides.
3. Implement Docker HTTP negotiation with a verified client transcript. Reserve
   names and IDs at create without starting a process. Attach may connect
   before start. Publish separate stream frames, real exit status and the
   selected wait condition. Inspect and event delivery use the same state.
   Release ownership only after verified cleanup and reported removal.
4. Exercise real CLI run, explicit create/start/wait/remove, nonzero exit,
   disconnect and replay. Prove that only the native owner executes the
   workload. A lost start response never triggers a second execution.

The first delivery rejects bind mounts, ports, all networking other than
`none`, privilege expansion, tty and stdin, restart policies and platforms
other than Linux ARM64. Docker build, Compose and persistent exec remain
independent paths. Admission rejects unsupported features before any native
allocation. Docker calls must receive a clear error when a requested feature
is outside the subset.

## Current integration boundary

The pilot copied `/bin/busybox` from the verified Alpine image using Docker.
It is ARM64 ELF with the interpreter `/lib/ld-musl-aarch64.so.1`. A branch-built
Jetstream `serve` with those exact bytes returned
`executable has an interpreter; static linking required` before any VM boot.
At that point the guest copied one executable into `/bin/probe`. Enabling
dynamic linking required a staged image root, default process configuration
and Docker lifecycle ownership.

`benchmarks/oci-image-admission.py` verifies a single-layer Docker-save
archive's pinned config and uncompressed layer digest. Its optional native
package preserves file modes, ownership and symlinks without extracting a
host tree. The Jetstream staging command checks the package hash and validates
every CPIO path before boot. The guest mounts that rootfs as an immutable
overlay lower directory. The native launch request still applies the cgroup
limits, process credentials, namespace permissions and output cap.

The unmodified Docker 29.10.0 CLI exercised `run --rm`, `create`, `start`,
`wait`, `inspect`, and `rm -f` as applicable. The adapter negotiates Docker API
1.44, delivers bounded noninteractive attach frames after cleanup, preserves
actual exit codes, publishes a bounded event snapshot and refuses to replay a
start after its response is lost. The test verifies real Jetstream workload
handles and guest cleanup in terminal event attributes. On an unresolved
backend disposition the session rejects new admission.

## Verified isolated research scope

Use the foreground launcher in the [environment runbook](speedup-environment.md).
In the native research mode, the launcher defaults to the Rust Docker
owner in the release Jetstream binary and uses the OCI-specific boot
and stop commands. This mode uses the native OCI guest for every
admitted workload. Use
`--docker-owner python` to run the reference against the same guest.
The retained Docker path uses dockerd and containerd.
[Current performance plan](native-docker-speed-plan.md)
The workload uses the staged immutable image reference, `--pull never`,
`--network none`, `--user 65532:65532`, `--memory 16m`, `--pids-limit 4`,
and `--cpus 0.5`. It accepts the enforced constraints
`--cap-drop ALL` and `--security-opt no-new-privileges`.
Commands use an absolute executable path. The verified
subset supports inherited OCI Entrypoint, Cmd and Env defaults and the tested
explicit argv, environment and working directory.

`jetstream native docker-stage` verifies a pinned OCI manifest and its
config, compressed layers, and uncompressed diff IDs from an ExternalSSD
content layout. The pinned two-layer fixture covers regular files,
directories, hard links, guest-root-relative symlinks, replacement, deletion
and opaque directories. The guest maps image ownership into the sandbox's
existing ID range. It copies complete linked groups into the private
upper layer so writes through an alias are visible to the other names
while the underlying image remains immutable. The default Docker owner
begins with one pre-staged image. An explicitly configured loopback
registry can supply additional pinned Linux ARM64 OCI images while the
guest is idle. The Rust owner verifies the manifest and every blob, uses
an ExternalSSD content store with shared-layer ownership, and installs
the verified package in the current guest generation. Docker image
inspect exposes the pinned config identity. Removing an image that
is referenced by the boot or any current container returns a conflict.
The registry fixture covers immutable digest pulls. Tag resolution,
manifest lists, remote registries and credentials remain outside the
verified scope.

The Docker control fixture verifies retained-container restart, graceful
SIGTERM stop, escalation after the requested grace, SIGKILL, and removal
after verified cleanup. The candidate is managed from source and general
promotion requires broader compatibility. The Rust owner streams bounded
stdout and stderr through noninteractive attach and `docker logs`, including
follow mode, after the guest captures each chunk. Log filters and timestamps
are outside the verified subset. Noninteractive `docker exec` uses the
running workload's namespaces, cgroup, working directory, environment and
UID/GID 65532. It accepts absolute paths or resolves bare executable names
using the workload's PATH. The candidate admits one active guest exec
with a two-second deadline and 8 KiB combined output. Exec reports the
actual process status and surfaces output overflow explicitly. Interactive
input, TTY, exec context overrides, Compose, build, full event streaming,
guest root credentials and prepared OCI remain outside the verified subset.

The candidate also supports one named internal IPv4 bridge. The
unmodified CLI exercised network create, inspect, remove, connect and
disconnect, including reconnecting an already-running bridged workload,
and resolved one scoped DNS alias per container. The pinned Alpine
workloads completed an HTTP transaction across the bridge. Container
inspection reports the guest address after exec confirmation. Live
connect requires a workload that was started with bridge permissions.
The verified scope uses the fixed private subnet with no guest egress,
custom IPAM or host networking. One bridged container can publish one
TCP port on `127.0.0.1`, with an explicit or OS-assigned host port.
Docker inspect reports the effective mapping after exec confirmation.
It stays reserved across restart and is released on container removal.
The isolated Alpine HTTP fixture passed byte-exact stream delivery
and port reuse. The full Node/Redis Compose fixture is tracked separately.

The retained live test command is:

```sh
python3 benchmarks/test-native-oci-live.py \
  --vmm "$vmm" --kernel "$kernel" --guest "$guest" \
  --package "$native_package" --receipt "$oci_receipt" --image "$pinned_image" \
  --output "$evidence/docker-native"
```

The first rejection and later native and Docker proofs are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-018`.
Small timing pilots remain distinct from qualification.
`--benchmark-lifecycle` selects the frozen per-session CLI and API sample
budgets for the Alpine no-network `true` workload. Every sample verifies
backend attribution, a unique one-use execution and guest cleanup from
the owned event snapshot after the measured operation. Throughput windows
include those verification requests. The ordinary Docker baseline uses
the image-default user. Report the native adapter's UID/GID 65532 lane
separately. The adapter uses the guest terminal wait protocol with a
100 ms per-request budget so cancellation can be checked between waits.
The release-build matched lane uses UID/GID 65532 on both
engines and checks memory, PID, and CPU limits. Use the timing boundaries and
evidence procedures in the [benchmark README](../../benchmarks/README.md).

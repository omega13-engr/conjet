# Docker-to-native adapter contract

The isolated `conjet-speedup` launcher defaults to a private Docker adapter
connected to one authenticated Jetstream OCI session. The launcher selects
that socket through private Docker configuration. Installed Conjet, its
Docker socket and its selected context stay under production ownership.
The candidate subset is one pinned Linux ARM64 OCI image, no network and one
active container. Image content must be admitted before the adapter advertises
readiness.

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

## Supported isolated candidate

Use the foreground launcher in the [environment runbook](speedup-environment.md).
The launcher defaults to the Rust Docker owner in the release Jetstream
binary and uses the OCI-specific boot and stop commands. The candidate
requires no experimental switch and has no containerd fallback. Use
`--docker-owner python` to run the reference against the same guest.
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
still selects one pre-staged image per boot. Registry pull and live image
installation are separate work.

The candidate is managed from source and general promotion requires broader
compatibility. Live streaming, interactive input, Compose, networking, build,
persistent exec, full event streaming, guest root credentials and prepared
OCI are outside the tested route. Native seccomp rejected shell command
substitution that attempted to create a pipe during the release canary.

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

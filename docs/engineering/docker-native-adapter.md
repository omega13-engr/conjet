# Docker-to-native adapter contract

The opt-in adapter requires a separate private Unix socket, explicit identity
and one lifecycle owner. A Docker context must opt into that socket. The
normal Docker endpoint and its containerd owner continue to operate as before.
The candidate subset is one pinned Linux ARM64 OCI image, no network and one
active container. Image content must be admitted before the adapter advertises
readiness.

## Runtime work required

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
The guest currently copies one executable into `/bin/probe` and owns no OCI
loader/preparation lifecycle. Removing the ELF interpreter check alone still
leaves no image root, default process configuration or Docker lifecycle.

`benchmarks/oci-image-admission.py` verifies a single-layer Docker-save
archive's pinned config and uncompressed layer digest, checks its rootfs
metadata and reports OCI process defaults without extracting anything on the
host. This supplies an image admission receipt. The guest staging and Docker
HTTP owner remain implementation prerequisites. No Docker operation uses the
native backend at this revision.

The reproduction is retained at
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-018`.
The existing native static lane keeps its own benchmark boundary.

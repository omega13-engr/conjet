# Conjet Native architecture

Conjet Native is Conjet's Rust container engine and Docker-compatible API,
running Linux containers inside a shared Linux VM on macOS. Swift owns the
application and runtime supervision. Jetstream owns the virtual machine through
Apple Hypervisor.framework (HVF). Linux supplies container isolation primitives.

This overview replaces the [historical retained-Docker architecture](architecture-legacy.md).
The native execution path uses Conjet's guest supervisor instead of the former
`dockerd -> containerd -> runc` chain. BuildKit remains the build scheduler and
Dockerfile implementation; Compose and Buildx remain Docker client tools.

## Scope and qualification status

Architecture snapshot: 2026-11-28. Distinguish the native runtime already in the
repository from the compatibility candidate under active development. The
candidate includes uncommitted fixes in `fix/docker-build-compatibility`; its
focused test results do not qualify the published package or all Docker features.

- Implemented architecture: host Docker API server, Jetstream/HVF VM, Linux guest
  supervisor, native process launch, image handling, BuildKit integration and
  Core dynamic memory.
- Candidate-tested increments: PostgreSQL initialization and named-volume
  persistence across container restart; image aliases across engine restart;
  multiple authorized binds/loopback ports; shell healthchecks; 4 GiB memory
  expansion, reclaim and data-integrity checks.
- Not fully qualified: general public DNS/direct network egress, complete ARTEX
  build and application E2E, persistent container metadata/writable layers,
  restart-policy semantics and the expanded Docker compatibility inventory.

The diagrams are logical component maps, not claims that every Docker endpoint
or configuration field is supported. The active worker must update these status
statements when artifact-matched evidence changes.

## Host and guest boundaries

```text
macOS HOST
=======================================================================

  +-------------------------+     +-----------------------------------+
  | Conjet.app / conjet CLI  |     | Docker CLI / Compose / Buildx     |
  | Swift application tools |     | Docker SDK clients                |
  +------------+------------+     +------------------+----------------+
               |                                    |
               | Conjet control protocol            | Docker HTTP API
               v                                    v
  +-------------------------+     +-----------------------------------+
  | conjetd                 |     | Conjet Native API server          |
  | Swift supervisor        |     | Rust: Core docker-serve process   |
  |                         |     |                                   |
  | configuration           |     | validate requests                 |
  | packaged asset checks   |     | container lifecycle / exec / logs |
  | start / stop / status   |     | image pull / import / export      |
  | process ownership       |     | volumes / binds / ports / health  |
  +------------+------------+     | BuildKit integration               |
               |                  +------------------+----------------+
               | starts and                          |
               | supervises both Core processes      | native protocol
               v                                     |
  +------------------------------------------------------------------+
  | Conjet Core / Jetstream VMM                                       |
  | Rust: Core docker-boot process                                    |
  |                                                                  |
  | +---------------------------+ +--------------------------------+ |
  | | VM execution and devices  | | Core dynamic-memory controller  | |
  | |                           | |                                | |
  | | virtual CPUs / interrupts | | workload admission              | |
  | | guest physical memory     | | expansion / idle reclaim        | |
  | | block / VSOCK / balloon   | | guest telemetry / pressure      | |
  | | kernel and initramfs boot| | backing-memory ownership ledger | |
  | +-------------+-------------+ +---------------+----------------+ |
  |               |                               |                  |
  |       Apple Hypervisor.framework               |                  |
  +---------------+-------------------------------+------------------+
                  |                               |
==================|========= VM BOUNDARY ==========|===================
                  v                               v
LINUX GUEST
=======================================================================
  +------------------------------------------------------------------+
  | Bundled ARM64 Linux kernel                                       |
  | namespaces / cgroups / filesystems / sockets / virtio / balloon    |
  +-------------------------------+----------------------------------+
                                  |
  +-------------------------------v----------------------------------+
  | conjet-launchd: Rust guest supervisor                             |
  |                                                                  |
  | validate authenticated requests and launch ownership             |
  | coordinate memory admission                                      |
  | prepare root filesystem, mounts and isolated network attachment   |
  | clone3 + namespaces + pidfd tracking                              |
  | apply capability, seccomp and resource policy                     |
  | stream input/output; collect exit; verify owned-resource cleanup  |
  +----------------+-----------------------------+-------------------+
                   |                             |
                   v                             v
  +-----------------------------+ +----------------------------------+
  | Ordinary Linux containers   | | BuildKit worker                   |
  |                             | |                                  |
  | A: isolated PID namespace   | | Dockerfile frontend / build graph |
  |    filesystem / mounts      | |               |                  |
  |    resource and net policy  | | Conjet BuildKit runtime adapter   |
  |                             | |               |                  |
  | B: separate isolated state  | | isolated RUN processes            |
  +-----------------------------+ +----------------------------------+
```

`conjetd` owns lifecycle, but Docker requests go to the Rust API endpoint rather
than through Swift's legacy Docker byte-forwarding bridge. Managed profiles use
`<CONJET_HOME>/run/conjetd.sock` for control and
`<CONJET_HOME>/run/docker.sock` for Docker API access. The default home is
`~/.conjet`; isolated tests use separate homes and explicit endpoints.

The API server connects to the owned native VM session; the VMM transports
native messages to the guest over virtio-vsock. Requests carry authenticated
session identity and lifecycle ownership. The two Core roles are separate host
processes, not a single monolithic daemon.

Containers share the VM's Linux kernel. Creating a container does not boot a new
VM or a new kernel. A container's initial process runs as PID 1 in its own PID
namespace; guest PID 1 belongs to the VM's initialization/supervision path.

## Container execution and completion

```text
Docker create/start request
           |
           v
Host API validates supported configuration and image identity
           |
           v
Guest launch request admitted under owned session/generation
           |
           v
Core restores required memory capacity before execution
           |
           v
Guest prepares filesystem + mounts + isolation + resource policy
           |
           v
clone3 / namespaces / pidfd --> exec container process
           |
           +--> stdout/stderr and exit observations --> Docker client
           |
           v
Reap process and clean owned mounts, cgroup and network resources
           |
           v
Report completion / cleanup witness; update lifecycle state
```

API acknowledgement, successful exec, process exit and verified cleanup are
separate boundaries. Benchmarks must name the boundary they measure. A short
launch number must not be presented as complete `docker run` latency.

## Build path

```text
docker compose build / docker buildx build
                 |
                 v
Buildx / Bake client --> Conjet API and BuildKit connection
                 |
                 v
BuildKit worker inside the Linux VM
                 |
                 +--> resolve frontend and base image content
                 |
                 +--> schedule independent stages and cache lookups
                 |
                 +--> prepare OverlayFS build snapshot
                 |          |
                 |          v
                 |     conjet-buildkit-runtime adapter
                 |          |
                 |          v
                 |     guest supervisor --> isolated RUN process
                 |
                 +--> export image --> Conjet host image store
                                            |
                                            v
                                  image inspect / load / run
```

The adapter is selected through BuildKit's OCI worker runtime integration.
Conjet provides the execution and snapshot handling beneath BuildKit; it does
not claim a separately rewritten Dockerfile frontend. OverlayFS build snapshots
combine immutable lower content with a writable upper layer. Their existence
does not establish durable writable layers for ordinary containers.

The candidate grants the verified BuildKit control stream a bounded longer
budget. Ordinary exec limits and client-disconnect cancellation remain separate
contracts. Long-build success also requires correct registry access, streaming,
archive limits and final image ingestion.

## Storage ownership

```text
HOST: profile-private OCI store          GUEST: owned Linux data disk
+-------------------------------+       +-----------------------------+
| verified image descriptors    | ----> | installed image roots       |
| layers / import-export files  |       | BuildKit cache / snapshots  |
| image aliases [candidate]     |       | named volumes               |
+-------------------------------+       +-----------------------------+

Authorized host bind roots <----------> Guest mount targets

Ordinary container metadata + retained writable layers
                       |
                       +--> durability work still pending qualification
```

Image aliases, named volumes, BuildKit cache and container writable layers are
different state classes. Passing a PostgreSQL volume canary or an image-tag
restart test does not prove container metadata and writable-layer recovery.
Host binds remain subject to the implementation's explicit source and target
policy; arbitrary host-path compatibility must be tested separately.

## Core dynamic memory

```text
Workload request
      |
      v
Core admission checks ownership and available capacity
      |
      v
Expand guest capacity / converge balloon state
      |
      v
Permit guest execution
      |
      v
Observe workload, pressure and idle state
      |
      v
Choose a policy target for reclaim
      |
      v
Guest ballooning / free-page reporting
      |
      v
Validate ownership in the host backing-memory ledger
      |
      v
Release eligible host backing; retain data-integrity guarantees
```

Configured guest capacity, balloon target, resident host memory and cumulative
reclaimed bytes are different measurements. Core must not reclaim guest-owned
or pinned pages without the required ownership transition. Admission replay,
expiry, pressure recovery and data canaries are required checks after changes to
networking, storage or lifecycle behavior.

## Networking: existing path and required completion

```text
CANDIDATE BUILD EGRESS VERIFIED FOR PROXY-AWARE CLIENTS

Build process --> guest HTTP/HTTPS proxy endpoint
                         |
                         v
                 authenticated relay --> host socket --> Internet

Local service names --> private bridge DNS --> registered guest peer
Published loopback port --> owned host listener --> guest target


GENERAL NETWORK PATH STILL REQUIRES IMPLEMENTATION / QUALIFICATION

Ordinary build/container client, without proxy-specific configuration
                         |
                         v
             private bridge + local service aliases
                         |
                         +--> bounded public DNS forwarding
                         |
                         v
                 owned guest uplink and routing
                         |
                         v
             existing host-socket network backend
                         |
                         v
                      Internet

Explicit no-network workloads must remain isolated throughout.
```

The existing `conjet-network` helper embeds gvisor-tap-vsock and supplies an
Ethernet-to-host-socket backend for Jetstream's network-device path. It is a
reusable component, not evidence that the native bridge currently has complete
outbound networking. Native airgap mode removes the VM network device and also
controls legacy socket exposure; simply disabling that flag is not a complete
or reviewed networking fix.

The 2026-11-28 ARTEX diagnostic reproduced public DNS failure inside the build
sandbox. Python's proxy-aware client fetched the same static JSON successfully;
blasthttp's default connection and explicit-proxy path failed differently. The
latter failure remains separately unclassified. ARTEX-specific proxy settings
must not be substituted for general Docker networking support.

## Source map and evidence boundaries

| Responsibility | Source |
| --- | --- |
| Managed native process lifecycle | [ManagedNativeDocker.swift](../Sources/ConjetVZ/ManagedNativeDocker.swift) |
| Native VM boot/session | [session.rs](../jetstream/src/native/session.rs) |
| Host Docker API and lifecycle ledger | [docker.rs](../jetstream/src/native/docker.rs) |
| Guest launch ownership and execution | [fresh_fixture.rs](../guest/launch-service/src/fresh_fixture.rs), [kernel_fixture.rs](../guest/launch-service/src/kernel_fixture.rs) |
| Guest isolation and policy | [sandbox_fixture.rs](../guest/launch-service/src/sandbox_fixture.rs), [security.rs](../guest/launch-service/src/security.rs) |
| BuildKit runtime integration | [build_runtime.rs](../guest/launch-service/src/build_runtime.rs), [build_snapshot.rs](../guest/launch-service/src/build_snapshot.rs) |
| Native bridge lifecycle | [bridge_fixture.rs](../guest/launch-service/src/bridge_fixture.rs) |
| Existing host networking backend | [network-helper README](../network-helper/README.md) |
| Dynamic-memory design | [dynamic-memory debugging](dynamic-memory-debugging.md), [host backing reclaim](jetstream-host-backing-reclaim.md) |
| Native engine mandate | [native engine plan](engineering/native-engine-v2-plan.md) |

Some implementation filenames retain `fixture` from their original engineering
harnesses; the names alone do not establish production qualification.

Candidate receipts are retained in the development environment under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-artex-evidence`: `postgres2.json`,
`tags-before.json`, `tags-after.json`, `memory15.json`, `artex-e2e8.json`, and
`egress-diagnostic2.json`. These local artifacts are not bundled with this
architecture document. Tie any published qualification claim to accessible
receipts, source revision and exact installed-package hashes.

The current implementation targets Apple Silicon macOS. Future Linux/KVM or
Windows/WSL2/WHP support would need host-specific supervision, VM, networking,
filesystem and memory integration; this diagram does not claim those ports exist.

A shorter execution chain, Rust implementation or OverlayFS alone is not proof
of lower latency. Report benchmark results only for the actual artifact, cache
state, workload, sample count, failure rate and equivalent completion boundary.

# Native compatibility qualification

The [71-case manifest](../../benchmarks/scenarios/native-compatibility-v1.json)
freezes the required fixtures, operations, effective policy and cleanup
witnesses for SPEED-098. It pins the source scenario and the existing
workload and matrix runners by SHA-256. Qualification uses one exact native
release artifact set. An unsupported, skipped, flaky, missing or failed case
blocks the full paired SPEED-065 benchmark. The earlier matched lifecycle
measurements belong to their earlier source and artifact set.

## SPEED-090 local image tags

The native adapter now tags, inspects, launches and untags staged images
through the ordinary Docker CLI and API. Tags are boot-local and hold a
verified immutable source reference. The adapter normalizes familiar and
fully qualified Docker Hub names and rejects destructive image removal
while a local tag protects its manifest. Alias operations do not contact
a registry or mutate the underlying image.

The first release attempt accepted Docker's tag request but could not
inspect the familiar alias. The normalizing change resolved that request
path. The pinned CLI then tagged and inspected the imported fixture,
launched by that tag, observed guest removal, untagged it, and confirmed
that the immutable manifest remained available. The same boot also passed
corrupt and interrupted transfer checks, cached pull, shared-layer
retention, image-in-use rejection and final blob cleanup. Production
fingerprints, guest shutdown and removal of the candidate endpoint
matched the launcher gates. Raw request and release artifact hashes are
under `SPEED-090/local-tags-normalized-cli/launcher` in the ExternalSSD
evidence root.

The case covers a configured loopback registry and verified staged
images. The ordinary matrix still needs public pinned image
provisioning, mutable registry tag resolution and archive save/load.

The frozen image preflight also found that exact tag inventory was
unavailable during cleanup. The adapter now answers the
`docker image ls --quiet <reference>` lookup. The pinned CLI returned
one image ID for the owned tag and no rows after untagging. The first
inventory attempt exposed a duplicate row when the same image's
registry digest belonged to a different repository. Exact filtering
now returns only the matching reference. Both attempts and the
successful registry regression are in `SPEED-090/exact-tag-*`.

Staging the verified ARM64 layouts independently confirmed an
additional image prerequisite. Alpine staged. Node and Rust exceeded
the 40 MiB layer bounds. Their largest compressed layers are 55,699,454
and 273,147,468 bytes, respectively. The Go layout hit a rejected
PAX extended header before the full image could stage. These results
require a bounded larger-image ingest and extraction design with Core
memory accounting before public image provisioning can qualify.
See `SPEED-098/staging-*.log` and `pinned-layer-descriptors.json`.

## SPEED-099 Docker archives

Docker image load accepts fixed and chunked framing on the dedicated
archive endpoint and spools the bounded request to the private image
store. The loader retains the archive's config bytes, verifies their
digest and verifies every uncompressed layer against the config's
diff IDs through the OCI verifier. An image and its aliases publish
only after validation. Image save exports one image from verified
source layers. A booted root can be exported when its pinned source
OCI layout is supplied through `--native-boot-layout`.

An isolated release boot loaded the exact frozen common archive and
ran its executable. Both the common image and the pinned Alpine
image passed save, tag removal, reload and native execution with
their original config IDs. A corrupt layer failed content verification
and left the blob inventory and aliases unchanged. The ordinary JSON
endpoints retain their existing body limit and reject chunked
framing. Raw CLI, release identity and cleanup evidence is under
`SPEED-099/archive-roundtrip-cli/` on ExternalSSD.

This increment supports one Linux ARM64 image per uncompressed
Docker archive, including compressed layer members. It uses the
existing OCI layer and guest package bounds.

## SPEED-101 and SPEED-102 image provisioning

The OCI verifier accepts bounded local PAX path and link-path fields
on the immediately following archive entry. Existing path, ownership,
mode and link checks still apply. The pinned Go image advanced past
its PAX rejection to the existing size bound.

The isolated launcher can enable `--native-public-images`. The
native store then resolves only the immutable Docker Hub references
from the frozen matrix. It fetches through HTTPS, shares verified
blobs with the existing store, and verifies manifest, config and
layer digests before guest admission. The short-lived registry token
is passed over the curl child's stdin. Curl drops Authorization on
cross-origin redirects. [curl documentation](https://curl.se/docs/manpage.html#--header)

The release canary rejected the wrong digest and platform, fetched
and inspected the pinned Registry image, repeated the cached pull,
verified its executable within a native workload, and removed the
image. A separate attempt to run that Registry binary failed with
EPERM on Go thread creation within the existing syscall policy.
That independent execution gate remains open. The full Node, Go
and Rust images still need larger-image ingest. Raw logs are under
`SPEED-101/` and `SPEED-102/` on ExternalSSD.

## SPEED-104 through SPEED-108 disk-backed OCI ingest

The guest hashes authenticated image chunks into an unlinked transfer file
and checks the final size and digest before installation. The private Core
disk profile places spools and published roots alongside the named-volume
registry on the exclusive ext4 lease. Stale image generations are removed
before the supervisor starts, and clean shutdown removes the current one
before unmounting. Archive execution and offline ext4 checks passed across
both a fresh and a preseeded stale disk.

The disk package keeps validated OCI metadata separate from raw regular-file
extents. The original two-layer image and a separate 80 MiB canary each passed
live transfer, native execution, rollback and removal. The fixed Go and Rust
layouts staged 214,178,773 and 1,042,718,012 byte packages with measured peak
host process RSS of 20.1 and 8.7 MiB. Node and Redis staged after preserving
the verified group inheritance mode on their home directories. The Redis
home reported `2755:999:1000` from an isolated native process after a pinned
public pull. The Node service and Go/Rust build workloads still require their
own qualification.

Evidence is under `SPEED-104/` through `SPEED-108/` on ExternalSSD.

## SPEED-109 large public pulls

The Core disk profile streamed verified registry blobs to the private
ExternalSSD store and installed packed OCI roots through the native Docker
endpoint. The exact Registry, Redis, Node, Go and Rust pins passed pull,
native filesystem execution and removal. Node, Go and Rust also passed
config-identity inspection and cached pull. The complete run measured
13.9, 17.5 and 54.6 seconds for those three pulls. A preceding run had
already completed the Rust pull before its idle HTTP witness connection
closed. The complete run used a fresh connection for each cleanup query.

The loopback registry's corruption and interruption regressions passed.
The large-image run left no image entries in the private host store,
released the lease, passed offline ext4 checks and preserved production.
Evidence is under `SPEED-109/` on ExternalSSD.

## SPEED-110 built-in bridge

The private Docker endpoint provisions the built-in bridge with a separate
guest network namespace, address range and resolver from the custom bridge.
The kernel acknowledged the built-in default route. The isolated candidate
boot has no external uplink. CLI checks verified implicit and explicit
selection, simultaneous endpoint ownership, DNS isolation and cleanup.
All twelve original Alpine and common-static lifecycle combinations passed
one run apiece with their original output and exit assertions and unique
native cleanup witnesses. This lane does not establish full release counts
or performance. Evidence is under `SPEED-110/` on ExternalSSD.

## SPEED-111 native cgroup resources

The native OCI path applies the requested memory, PID and CPU controls
within its supported ranges. Omitted controls leave the individual
workload cgroup uncapped for that resource within the Core guest. This
matches Docker's omitted-resource convention. [Docker resource constraints](https://docs.docker.com/engine/containers/resource_constraints/)

The isolated release read the actual cgroup values for omitted, partial,
lifecycle and service settings. The frozen service settings were
134,217,728 bytes, 64 PIDs and 50,000 microseconds of CPU per 100,000.
The lifecycle settings remained 16,777,216 bytes, four PIDs and the same
CPU quota. Invalid bounds failed before admission. The resource canary
used an absolute sleep executable to isolate resource handling after
the first run surfaced the separate relative-command limitation.
Evidence is under `SPEED-111/` on ExternalSSD.

In the same release profile, the Core memory diagnostics grew from
448 MiB to 2,048 MiB on demand and under independent pressure with no
active workloads. The active-data checksum and ownership checks passed,
and the guest returned to 448 MiB in both runs.

## SPEED-112 sustained native service

The original guest killed or lost a detached workload around its 30-second
running timeout, and the Docker endpoint later reported unresolved cleanup.
The corrected release bounds startup and teardown independently. It kept
the same guest handle for 36 seconds and preserved both the file marker
and the logs. Forced removal verified output drain and guest teardown.
The canary used the frozen explicit lifecycle resource settings.
Evidence is under `SPEED-112/` on ExternalSSD.

## SPEED-113 launch PATH resolution

The OCI launch path and exec share bounded executable lookup. The guest
tries candidates inside the authenticated workload root, after sandbox
and identity setup. Bare `sleep` worked in each resource case. The
original absolute lifecycle canaries passed, and slash-relative
commands were rejected.

The first entrypoint probe hit a Docker Hub timeout. A separate boot from
the verified pinned Redis layout reached line 19 of its declared
entrypoint, where the guest blocked a pipe for command substitution.
That verifies dispatch to the original script. The original Redis
service still requires shell and process support. Evidence is under
`SPEED-113/` on ExternalSSD.

## SPEED-114 Node Docker archive

The disk profile streams archive layer extents between verification,
the local blob store and the Docker tar stream. The pinned Node image
saved 61,165,568 bytes, reloaded with config
`sha256:fd6e7c5e242aaf648004a761573a2b930792eb46b1be852862b595dfdaa11b36`
and exposed the executable in a native workload. The diagnostic removed
the tag and source. Common and Alpine archive round trips and the corrupt
layer regression passed on both profiles. The reloaded Node application
still needs its original execution case. Evidence is under
`SPEED-114/` on ExternalSSD.

## SPEED-115 exec cgroup inheritance

Exec uses the current workload's verified cgroup for both omitted and
explicit Docker resources. In the default, partial, lifecycle and service
cases, the guest kept the same workload handle and limits while the
actual PID count rose from one to three. Exec output and teardown
regressions passed. Evidence is under `SPEED-115/` on ExternalSSD.

## SPEED-116 shell subprocesses

Ordinary native OCI workloads can create pipes and launch children with
bounded fork or vfork flags. The child inherits its sandbox and resource
group. The pinned Redis and Node entrypoints each ran the specified shell
canary, and the Node workload's namespace-creation request still returned
EPERM. These tests cover the entrypoint scripts. Application readiness
and thread startup have separate acceptance. Evidence is under
`SPEED-116/` on ExternalSSD.

## SPEED-103 native threads

The ARM64 filter permits same-process thread creation with the required
shared-state flags. The musl probe verified a second thread under the
original resource ceiling and rejected namespace creation. The pinned
Registry binary advanced from thread-creation EPERM to PID exhaustion
under its four-PID diagnostic. With omitted limits its first failure
moved to epoll initialization. The pinned Node program reached a
libuv initialization assertion in a separate baseline. Evidence is
under `SPEED-103/` on ExternalSSD.

## SPEED-117 complete lifecycle evidence

The preflight can qualify each frozen lifecycle group on an independent
Core boot. It checks every warmup and sample for the original exit,
output and a unique native teardown witness. Incomplete diagnostic
groups remain failed in the release evaluator.

The original common-static built-in-bridge API group passed 2,000
samples and ten warmups. Evaluating that partial evidence attributed
one passing case and left the 71-case release gate failed. Evidence is
under `SPEED-117/` on ExternalSSD.

## SPEED-118 pinned application event loops

The pinned Registry binary reported v2.8.3 after epoll and eventfd
were admitted for ordinary OCI workloads. Node moved past libuv loop
initialization and then failed opening its stdout pipe. A filter for
`FIONBIO` on an owned descriptor let the original Node output canary
run from the reloaded archive with verified teardown. [Pinned Node pipe implementation](https://raw.githubusercontent.com/nodejs/node/v22.23.5/deps/uv/src/unix/pipe.c) · [Pinned libuv descriptor implementation](https://raw.githubusercontent.com/nodejs/node/v22.23.5/deps/uv/src/unix/core.c)

Evidence is under `SPEED-118/` on ExternalSSD.

## SPEED-119 large exec output

Small exec results retain their inline reply. Larger results use
authenticated chunks with a short, connection-owned lease and
256 KiB retention per stream. The release verified both streams,
exit status, bounded overflow, rejected cursors and release on
disconnect. The frozen device-backed exec still requires its
`/dev/zero` check. Evidence is under `SPEED-119/` on ExternalSSD.

## SPEED-120 standard workload devices

Ordinary OCI workloads bind individually verified null and zero
devices. The original `dd if=/dev/zero bs=1024 count=128` exec
returned 131,072 zero bytes. The same session verified null output,
limited device visibility and complete exec and workload cleanup.
Evidence is under `SPEED-120/` on ExternalSSD.

## SPEED-121 noninteractive exec TTY

Docker exec can allocate a slave terminal from a devpts instance owned by
the disposable guest. The original `test -t 1` command returned
`tty-ok` from the raw Docker stream. The non-TTY exec regressions
and clean PTY shutdown passed.

The exact control preflight also passed large output, CLI exec and attach
disconnect recovery. Plain HTTP exec received HTTP 101, archive uploads
were rejected at framing and interactive attach failed at create.
Evidence is under `SPEED-121/` on ExternalSSD.

## SPEED-122 Docker exec transport negotiation

The exec endpoint sends HTTP 200 for an ordinary request and upgrades
to TCP only when the request supplies both upgrade headers. All 110
plain HTTP exec warmups and samples in the frozen control run passed
their output, exit and inspect checks. CLI upgrades and TTY remained
functional. The first workspace test run hit an unrelated macOS VMM
page-accounting assertion. The isolated workspace rerun passed.
Evidence is under `SPEED-122/` on ExternalSSD.

## SPEED-091 mapped OCI credentials

The guest advertises mapped credentials on its OCI handshake. The
adapter uses the staged image's default when Docker omits the user.
An empty image default starts as namespace UID/GID 0. Explicit numeric
UID:GID pairs are limited to the existing 65,536-entry map. Exec inherits
the owned target process's numeric pair. The static and snapshot
fixtures keep their fixed pair. Namespace root still enters exec with
an empty capability set and bounding set, no-new-privileges and the
existing seccomp filter.

The original Alpine invocation with no user failed before the change.
On the isolated release candidate the pinned CLI observed effective
0:0, 1234:4321 and 65532:65532, plus root identity inherited by exec.
The Docker API denied unmapped UID and GID, privileged create and
capability addition. Guest lifecycle witnesses, shutdown and production
fingerprints passed. One earlier credential probe used shell command
substitution and hit the existing pipe syscall policy. The successful
credential probe uses the image's BusyBox ID command directly and keeps
the original syscall policy. The benchmark fixtures were retained.
Raw attempts and binary identities are under `SPEED-091/` on ExternalSSD.

This increment verifies the pinned Alpine default and numeric mappings.
Named-account and single-ID resolution against the image's account
database and the full original lifecycle remain open.

## SPEED-098 fail-closed preflight

The native launcher accepts `--diagnostics compatibility-preflight
--compatibility-suite <suite>`. Run separate owned boots for
`lifecycle`, `images`, `builds`, `compose`, `control`,
`storage_network` and `stress`. It uses the frozen scripts and
Docker, Buildx and Compose pins, requires the native Rust owner and
both Core memory helpers, and writes an operation report beside the
launcher hashes, commands and cleanup. A preflight launcher exit
confirms capture and cleanup. Required assertions still fail when
their operations are missing or unsupported.

Record the SHA-256 of the exact release CLI, daemon, VMM, guest and
two Core helpers in `release-sha256.txt` in the ExternalSSD evidence
root. Run `python3 benchmarks/native-compatibility-gate.py --evidence
"$evidence" --revision "$candidate_revision"` after the native
preflights and regression canaries. Its summary enumerates all 71
cases. It checks evidence against the release identity, Core policy,
production fingerprint, guest shutdown and host removal. An unknown
or unverified case remains failed. A nonzero exit blocks SPEED-065.

The frozen lifecycle runner requires the common image archive. If
that setup fails before any groups run, preflight also probes the eight
independent Alpine cases with the frozen workload function and records
native cleanup for each successful operation. The archive failure
remains in the report. The loopback-free (`none`) Alpine CLI/API
cases passed. The four original default-bridge cases failed because
the native endpoint currently requires an explicitly created private
bridge. The four common-image cases still lack an archive load path.

## SPEED-092 Buildx worker boundary

The pinned Docker-container driver loads a worker image, requests
`Privileged` and `Init`, and attaches a named cache volume at
`/var/lib/buildkit`. Readiness runs `buildctl debug workers`. The
driver then opens a Docker exec connection with stdin, stdout and
stderr for the bidirectional `buildctl dial-stdio` transport.
The local direct RUN canary covers the executor after a worker
exists. It does not exercise these Docker worker or transport calls.
[Worker provisioning](https://github.com/docker/buildx/blob/v0.39.1/driver/docker-container/driver.go#L87-L162).
[Exec transport](https://github.com/docker/buildx/blob/v0.39.1/driver/docker-container/driver.go#L349-L397).
[BuildKit client dial](https://github.com/docker/buildx/blob/v0.39.1/driver/docker-container/driver.go#L481-L514).

The execution policy must bind a builder reservation to the verified
image digest, boot generation, owned worker configuration and cache
inode. A name, label or caller-supplied image string confers no
authority. The worker privilege boundary must be inside the isolated
guest and have no host resources, production sockets or general
privilege route. Worker disk, processes, memory and transport need
their own ownership, cancellation and cleanup. Build workloads still
need the Core admission policy and the pinned native executor.
Qualification requires the original driver, worker readiness, exact
cache path, bidirectional detach and cancellation, denied unrelated
privileged create, scope-limited resource access and verified removal.

The release preflight created and removed all three builder
definitions. Bootstrap failed during pinned worker image provisioning.
Separate negative API checks verified that regular workloads cannot
request privilege or add capabilities. Worker provisioning and
`dial-stdio` remain open.

## Exact release gate result

SPEED-123 and SPEED-124 added single-file Docker copy in both
directions for owned running workloads. The optimized live copy canary
used the frozen 4 KiB and 8 MiB payloads with the pinned CLI and
matched both SHA-256 hashes. The upload uses bounded tar framing, a
generation-scoped staging file inside the private workload mount,
mapped file ownership, and atomic replacement after digest validation.
The final run denied escape paths and symlinks, rejected corrupt
content, preserved the previous bytes after a disconnected write, and
verified native teardown. See `SPEED-124/live-copy-final/` on ExternalSSD.

The subsequent control preflight passed all 110 original attach, log
and lifecycle-event repetitions and all 440 copy operations. It also
passed the original immediate 128 KiB exec, real TTY, and the API and
CLI control assertions. The preceding run reproduced the Darwin
event-subscriber leak at the 32-socket limit and the early exec
startup race. An independent release run verified graceful exit 42,
SIGKILL and escalated exit 137, and three distinct guest generations
with complete cleanup. Raw artifacts are under `SPEED-130/` on
ExternalSSD. This is control qualification evidence ahead of the full
gate rerun on one finished release artifact set.

The frozen storage preflight passed six writable-layer runs, six
named-volume runs with independent readbacks, and six host bind runs.
All paths produced the same 16 MiB SHA-256. The bind lane used a live
FUSE relay over the authenticated guest connection to an owned
ExternalSSD subdirectory. The host checksum and guest mount teardown
were recorded for each bind. The current profile supports bounded
regular-file I/O in the admitted dataset directory. The service
fixture still stopped at Compose network creation. See
`SPEED-135/storage-final/` on ExternalSSD.

Revision `fa1cbad84f30482d08862aee051914a0bd4a8c9b` ran the native
preflights and regressions against a single optimized release artifact
set. Evaluating the 71 requirements produced **19 PASS and 52 FAIL**.
The manifest's 12 Rust, Go and Node variant records were assigned to
the BuildKit task before regenerating the summary. This corrected the
owning task and suite prefix. The operations, pinned workload code,
required count and overall verdict were preserved.

| Surface | Exact release evidence |
| --- | --- |
| Lifecycle | Four Alpine API/CLI no-network cases passed with guest teardown. Default bridge requests returned HTTP 400. Loading the pinned common archive failed at HTTP body framing. |
| Images | The pinned Alpine tag and cleanup inventory worked. Save returned unsupported. Node and registry fixture pulls reached an unconfigured registry store. The exact layouts also reproduced the ingest bounds recorded above. |
| Buildx and Docker build | All three builder bootstraps failed at worker image provisioning, with builder definitions removed. The direct `POST /v1.44/build` canary used a tar context and returned HTTP 501. The earlier guest-local BuildKit RUN is historical for this release gate. |
| Compose, storage and control | Node prepull blocked the original service and storage fixtures. The original control container is created without the resource fields required by the current bounded profile. The pinned small native Compose and volume regressions passed. |
| Stress and Core | The original stress command passed 400 runs and 40 warmups at concurrency 1/2/4/8. Node provisioning blocked the OOM case. Core grew from 448 to 2,048 MiB under workload demand and independent pressure with zero containers. It returned to 448 MiB, preserved the active-data checksum, and reconciled backing ownership with zero reclaim failures. |

Production fingerprints and launch teardown passed. Named-volume and
Compose disk checks passed. Rust workspace tests reported 189 passed
and three ignored. ARM64 guest Clippy passed with warnings denied.
Swift reported 440 tests, two skipped and zero failures, and the Go
network-helper tests passed. This change affects the headless engine
and its fixtures, so logs and structured runtime witnesses are the
acceptance evidence.

The raw artifacts, launch commands, per-case evidence and gate verdict
are under `SPEED-098/exact-release/` in the ExternalSSD evidence root.
The new full Kiri comparison remains blocked by the required failures.
There is no current Kiri parity result. The historical p99 upper bounds
remain 1.0586 for API and 1.0553 for CLI.

## Qualified optimized candidate

Commit `66a8a908e0ce39aa8fec831482fbd083b449334d` passed all **71 frozen
cases** with six checksum-verified optimized executables. The refreshed
`a792b4c` baseline passed 53 of 71. The [task board](task-board.md#speed-098)
records the intermediate candidate and retained attempts.

| Surface | Qualified behavior |
| --- | --- |
| Build clients | Original public Rust, Go and Node builds through pinned Docker-container Buildx, bounded local Docker build API, and pinned standalone BuildKit. The witnesses cover native RUN, cache hits and invalidation, exit 23, active cancellation, executable exports, and builder teardown. |
| Images and credentials | Pinned ARM64 public images, controlled registry, cache and shared-layer handling, verified single-image archives, and Linux image-default and mapped explicit credentials. |
| Runtime and services | Twelve original lifecycle groups, Compose readiness and Redis persistence, persistent exec, attach and copy, writable layer, named volume, authenticated host bind, bridge routing, and concurrency at 1/2/4/8 with cancellation and OOM recovery. |
| Core and isolation | Workload demand and independent guest pressure grew Core from 448 MiB to 2,048 MiB. Active data passed its checksum and idle shrink returned to 448 MiB with verified backing and page-reporting ownership. Production fingerprints, launcher cleanup and detached ext4 checks passed. |

The qualified worker profile is scoped to the pinned identity and its
owned cache and cgroup. Ordinary privileged containers, remote build
contexts and general multi-image archive imports remain outside the
profile. The frozen compatibility gate covers the capabilities listed
in its manifest.

The full ledger, six retained binaries and checksums, commands, launcher
receipts, and checks are in `SPEED-098/cj-compat.tMPK1e-release-66a8a908e0ce/`
under the ExternalSSD evidence root. Redis and BuildKit timed out during
public image acquisition in the initial default-credentials run. The
retry passed all seven public image pins on the same checksummed binaries.
The initial attempt remains in the evidence directory.

Local Rust workspace tests, ARM64 guest Clippy, Swift, Go, Core C and
benchmark-harness tests passed. Strict macOS workspace Clippy reproduced
the baseline diagnostics. The changes affect the headless engine.
Structured native runtime witnesses provide end-to-end evidence.
[Hosted macOS CI](https://github.com/omega13-engr/conjet/actions/runs/45473119435)

## Buildx recovery candidate

Optimized commit `16a05e00d07dce825319b832dd248bdd2a861d05` passed
all **71 frozen compatibility cases**. The optimized host executable
includes authenticated recovery for a lost read-only BuildKit worker
observation. The five other executables matched the qualified
`66a8a90` hashes. The six retained files and checksums, complete 71-case
ledger, launcher witnesses, and detached disk checks are in
`SPEED-098/cj-full.lQbpSK-release-16a05e00d07d/` under the ExternalSSD
evidence root.

The isolated 2.45-second VM delay reproduced the previous build pair's
archive rejection and loss of worker control. The fixed host completed
all twelve Node export, archive load, and execution canaries with the
same injected delay. The public Rust, Go and Node qualification, Docker
build API, and direct BuildKit routes passed on the optimized artifacts.
Core passed both the workload admission and independent pressure
checks with verified data and recovery to 448 MiB. Rust workspace tests,
formatting, ARM64 guest Clippy and hosted macOS checks passed. Strict
host Clippy reproduced the baseline diagnostics.
[Hosted macOS CI](https://github.com/omega13-engr/conjet/actions/runs/45530432842)

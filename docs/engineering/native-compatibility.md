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

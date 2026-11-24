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

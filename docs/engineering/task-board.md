# Conjet speed engineering task board

Architecture: [speed engineering plan](speed-engineering-plan.md).

Current iteration: [native engine implementation plan](native-engine-v2-plan.md).

## New worker handoff and completion order — 2026-11-24

After pausing for replanning, the user authorized a new GPT-6.2-Sol worker
to complete compatibility fixes and tests. The previous worker remains paused.
Follow the [compatibility completion plan](native-compatibility-completion-plan.md)
in the new worker. It orders existing tasks instead of adding overlapping feature
tasks: refresh the 71-case baseline; complete real BuildKit RUN, aggregate
accounting and cancellation; fix public DNS; qualify Node, Go and Rust build
rows; finish remaining original cases; requalify Core memory; run the exact
71-case gate; then benchmark. Existing acceptance criteria remain unchanged.
The historical 19 PASS / 52 FAIL result is not a current capability count.
No task is advanced by this planning-only update.

## Current Docker performance priority

Latency investigation: [native diagnostic plan](native-latency-diagnostic-plan.md).
SPEED-081–083 met the isolated warm median target. SPEED-084–085 reduced
the warm API tail. SPEED-063 passed its bounded direct BuildKit RUN
fixture. SPEED-065 tracks release comparison, and SPEED-089 tracks the
Docker builder gateway needed for the frozen build rows.

The candidate uses Conjet's native Rust engine with full Core dynamic
memory. The current release gate is the 71-case frozen compatibility
manifest on exact optimized artifacts. SPEED-089 and SPEED-092 cover the
Docker builder path, and SPEED-145–148 cover the identified service
startup, publication, DNS and stats work. The full SPEED-065 comparison
follows a complete compatibility pass. The retained-engine SPEED-051/055
failures remain historical evidence. Production remains isolated from
qualification.

## Working rules

- Each task must deliver the artifact or behavior named in Description. Complete
  Approach steps in order and record commands, results, and artifact paths in Evidence.
- Follow implementation dependencies; move a task between sections as its status changes.
- Start implementation when its development prerequisites are DONE with review evidence. Each implementation
  task includes focused automated checks, diff review, and resource cleanup.
- Evidence is pending until actual commands, results, revisions, configurations,
  and artifact links are recorded. Targets are not benchmark results.
- UNDERREVIEW requires an implementation and verification evidence; DONE requires
  acceptance criteria and review to pass. Record blockers and failed experiments.
- On 2026-11-23 the user authorized an opt-in M1 Pro experimental release.
  SPEED-008 remains unresolved and deferred with its revise verdict. SPEED-011
  tracks local acceptance and carries the original comparative research criteria.
  SPEED-009 and SPEED-010 DONE evidence covers the isolated implementation only.
- Preserve the installed runtime and unrelated changes. Use isolated QA resources,
  designated temporary artifact locations, and screenshot evidence where applicable,
  as described in the plan. No persistent prewarming services or startup jobs.

## Branch, increment, PR, and release workflow

- Implementation branch: `enhancement/speed-up`. PR base: `main`.
- Complete one coherent increment at a time. Run its applicable checks, review
  the diff, update this board and evidence, then commit with a conventional
  message containing the task ID and push to `origin/enhancement/speed-up`.
- Record implementation commit IDs and verification artifacts in each task's
  Evidence field. Verify the pushed remote head before starting the next increment.
  Use ordinary pushes; do not force-push or include unrelated working-tree files.
- A failing increment stays INPROGRESS or UNDERREVIEW until fixed. Never mark it
  DONE or claim a passing benchmark because its code was committed or pushed.
- Open the PR to `main` only after audited development, local experimental
  acceptance, Docker compatibility, and final candidate measurement evidence
  pass. Preserve unresolved comparative research under SPEED-008 and SPEED-011.
- Prepare the release only after that gate. Choose the next semantic version
  from the final change scope and current release state; do not bump VERSION or
  publish a release tag during intermediate increments.
- Merge only after PR review and required CI pass. Release from the merged main
  revision after packaging validation, following [release.md](../release.md) and
  [homebrew.md](../homebrew.md). Revalidate affected evidence after merge changes.
- The app and guest Core have separate version lanes. Determine whether the new
  guest service requires a Core release, verify asset compatibility, and order
  those releases accordingly. Production signing, notarization, stapling, final
  DMG checksums, and Homebrew validation remain release gates.

## Release scope audit

| Tasks | Retained result and use in this release |
| --- | --- |
| SPEED-000 | Session-scoped launchers and private endpoints. Candidate Docker isolation was rerun with final source; production observations matched. |
| SPEED-001, SPEED-002 | Distinct exec, readiness, removal and cleanup observations, with the pinned baseline retained. Docker acknowledgement and native verified cleanup use separate boundaries. |
| SPEED-003, SPEED-004 | Bounded authenticated protocol, single-owner contract, v1 framing and generation checks. The product capability adds Inspect and unique operation IDs. |
| SPEED-005, SPEED-006 | Restricted Linux execution path, explicit failure and recovery. Final product canaries reran isolation, output, cancellation, teardown and recovery checks. |
| SPEED-007 | Private bridge fixture retained for research. The product explicitly rejects bridge and removes the guest network device. |
| SPEED-008 | Original revise verdict recorded and unresolved. Comparative requirements deferred. |
| SPEED-009, SPEED-010 | One-slot fixture and backing-ownership evidence retained. SPEED-012 integrates the relevant semantics with the product session. |

## Docker and native benchmark extension

SPEED-015 through SPEED-026 retain the original Docker comparison and
experimental native-launch evidence. Their report verdicts apply to
their recorded binaries and workloads. SPEED-037 through SPEED-045
retain their old acceptance criteria for research provenance.

## Native candidate under review

These tasks have isolated implementation or measurement evidence. They
remain open for independent review.

### SPEED-081

Title: Attribute native pending admission through verified cleanup

Description: Add bounded correlated stage tracing and reproduce the current no-network API baseline.

Is blocked by task: None; freeze current native release.

Acceptance Criteria:

- Run two traced and two untraced alternating boots, 200 operations plus ten warmups each. Join host/guest stages without cross-clock subtraction; quantify observer overhead, pending-discovery latency, setup and cleanup. Report warm-capacity and reduced-capacity behavior separately.

Problem and Evidence: Existing SPEED-060 timing starts after demand observation and leaves discovery unmeasured.

Approach: Instrument existing session, guest lifecycle and Docker wait boundaries; flush bounded trace buffers after timing.

Evidence: Two compact-observer release pairs recorded 420 joined API
operations with zero overflow and median observer overhead of
0.65% and 3.35%. Pending discovery was the largest warm median stage.
See [the latency report](native-latency-diagnostic-results.md#speed-081).

Source: [Native latency diagnostic plan](native-latency-diagnostic-plan.md).

Review: Isolated warm attribution and self-review passed. Independent
review pending.

Next Action: Test discovery cadence independently under SPEED-082.

### SPEED-082

Title: Test native admission discovery cadence sensitivity

Description: Compare 30 ms and 5 ms observation waits without changing Core policy or the safety tick.

Is blocked by task: SPEED-081.

Acceptance Criteria:

- Run two alternating 200-operation release pairs with ten warmups per leg. Record guest pending-discovery duration, lifecycle, idle CPU/wake counts, pressure response and cleanup. Accept or reject the hypothesis explicitly; no production shorter-poll default.

Problem and Evidence: The event-mode manager still waits up to 30 ms between demand observations.

Approach: Change only the diagnostic observation cadence; verify actual configured cadence in artifacts.

Evidence: Two alternating release pairs reduced pending discovery p50
from 25.47–26.09 ms to 3.28–3.48 ms and API p50 from 40.25–40.43 ms to
6.54–6.70 ms. Faster polling more than doubled idle VMM CPU. The
separate pressure, idle, data integrity and cleanup canaries passed
at both cadences. See
[the cadence results](native-latency-diagnostic-results.md#speed-082).

Source: [Native latency diagnostic plan](native-latency-diagnostic-plan.md).

Review: Isolated diagnostic validation passed. The 5 ms cadence is
rejected as a release default. Independent review pending.

Next Action: Keep 30 ms as the periodic default and test authenticated
pending-demand notification under SPEED-083.

### SPEED-083

Title: Select and qualify one native latency correction

Description: Implement the single correction justified by stage attribution; create a narrower child task if the protocol change needs separate increments.

Is blocked by task: SPEED-081 and SPEED-082.

Acceptance Criteria:

- Name the confirmed stage and intervention first. For demand notifications test coalescing, lost wakeups, stale generation, reconnect, cancellation and overload. Preserve memory policy, execution/cleanup boundaries and safety tick. Pass memory gates and two release A/B pairs before accepting; reject non-improving changes.

Problem and Evidence: SPEED-081 and SPEED-082 confirmed pending discovery
as the largest warm median stage and established the cost of faster polling.

Approach: Use the conditional architecture in the diagnostic plan only if supported; otherwise fix the measured dominant stage. Do not bypass admission or weaken cleanup.

Evidence: The authenticated watch reduced untraced API p50 from
37.50–40.22 ms to 2.47–2.51 ms in two alternating pairs. Pending
discovery fell from 24.52 ms to 0.053 ms in the separate trace.
Protocol overload, reconnect, replay, cancellation, pressure growth,
data integrity, idle shrink and cleanup passed. See [the watch
results](native-latency-diagnostic-results.md#speed-083).

Source: [Native latency diagnostic plan](native-latency-diagnostic-plan.md).

Review: Isolated watch validation and self-review passed. Independent
review pending.

Next Action: The default isolated release uses the authenticated watch
on capable guests. The full comparison remains in SPEED-065.


### SPEED-084

Title: Attribute the warm native API p99 outliers

Acceptance Criteria:

- Freeze the SPEED-083 release. Retain per-request wait, admission,
  VMM controller evaluation, setup, output and cleanup stages.
  Compare traced and untraced release boots and identify the dominant
  span in the slowest requests. Separate capacity/pressure holds from
  scheduling delays. Preserve the Core controller and safety tick.

Evidence: The SPEED-083 Kiri pilot reported native API p99 of
18.76–20.13 ms. The two longest operations in its separate trace spent
19.92 and 21.31 ms between host observation publication and approval.
In two 1,000-operation traces, the ten slowest requests per boot spent
12.67–29.97 ms waiting for the first Core evaluation. Approval followed
within 0.01 ms and the accepted observations had no capacity holds.
See [the tail attribution](native-latency-diagnostic-results.md#speed-084).

Review: Isolated attribution passed. Independent review pending.

### SPEED-085

Title: Correct the attributed warm native admission tail

Depends on task: SPEED-084 attribution, passed in isolation.

Acceptance Criteria:

- Change the measured transition, keep the 25 ms safety tick, and
  test stale, empty and coalesced demand. Record the release p50, p95
  and p99 in two untraced A/B pairs. Requalify reduced growth, pressure,
  idle shrink, data integrity and verified cleanup before adoption.

Evidence: Two 1,000-operation A/B pairs reduced API p99 from
12.86–22.33 ms to 4.03–4.35 ms. The explicit wake trace put first
evaluation at 0.064 ms p99. Reduced growth, independent pressure,
payload integrity, idle shrink and verified cleanup passed. See
[the tail correction](native-latency-diagnostic-results.md#speed-085).

Review: Isolated qualification passed. Independent review pending.

### SPEED-057

Title: Audit and boot the native engine without a retained-engine fallback

Description: Produce a source-to-fixture capability table and boot current release host/guest through the private native endpoint.

Is blocked by task: None.

Acceptance Criteria:

- Verify process/executable identities exclude dockerd, containerd and runc from candidate execution; pass create/start/wait/remove, output/exit and unsupported-feature rejection fixtures. Record current resource/security limits and gaps.

Problem and Evidence: 7dd2a95 and existing SPEED-027–036 research.

Approach: Inspect the existing Rust owner and guest launch authority; reuse them. Capture boot identity and actual Docker request routing.

Evidence: Six isolated release boots passed the control, streaming, exec,
network, published-port and concurrency canaries. Control recorded 176 unique
guest lifecycle handles. The live boot archive contained the expected
`conjet-launchd` and pinned Alpine workload, backed by an empty block device.
See [SPEED-057 evidence and capability limits](native-engine-validation.md#speed-057).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: Self-review and isolated validation passed. Independent evidence review pending.

Next Action: Connect the Core memory telemetry and admission contracts in SPEED-058.

### SPEED-058

Title: Connect native workload ownership to Core dynamic memory

Description: Verify and repair the native guest telemetry/controller integration while preserving Core policy.

Is blocked by task: SPEED-057.

Acceptance Criteria:

- Prove growth from a reduced target under pressure, active-data integrity during launch churn, idle shrink within policy deadlines and balloon-owned backing release. No fixed-memory shortcut; add regression tests for missing/stale telemetry and resource-generation reuse.

Problem and Evidence: Native memory RPCs are not proof of complete Core controller integration.

Approach: Map native workload/cgroup lifecycle to existing memory inputs; use actual Core policy and ownership ledger. Start the growth fixture below full capacity.

Evidence: Workload demand and independent service pressure both restored
2,048 MiB from a converged 448 MiB target. Data integrity, idle shrink,
balloon ownership and stale-generation tests passed. See
[SPEED-067](native-engine-validation.md#speed-067) and
[SPEED-068](native-engine-validation.md#speed-068).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: Isolated memory qualification and self-review passed. Independent
evidence review and production qualification remain pending.

Next Action: Start the release pilot and independent volume work.

### SPEED-066

Title: Expose Core memory telemetry from the isolated native guest

Description: Run the existing Core memory helpers in the native initramfs.
Expose native workload cgroups to Core telemetry over the private memory vsock,
with a fixture that samples a live and a removed workload.

Is blocked by task: SPEED-057 validation, complete.

Acceptance Criteria:

- The same Core metrics endpoint returns guest memory and real native
  workload cgroup usage. Verify service cgroup telemetry, workload removal,
  no retained runtime, production preservation and shutdown cleanup.
- Keep controller activation behind verified admission and cleanup ownership.
  This increment does not qualify SPEED-058 or authorize new timing.

Evidence: The release telemetry canary observed 0 → 1 → 0 native cgroups,
131,072 bytes of live cgroup usage and a stable service cgroup identity.
See [SPEED-066 evidence](native-engine-validation.md#speed-066).

Review: Self-review and isolated validation passed. Independent review pending.

### SPEED-067

Title: Gate native launch on generation-scoped Core admission

Description: Publish pending admissions and owned workload records on the
authenticated guest channel. Bind a Core grant to the exact boot and workload
identity. Keep the launch pending until its own grant arrives or it expires.

Is blocked by task: SPEED-066 validation, complete.

Acceptance Criteria:

- Missing, stale or reused ownership cannot authorize a launch or release
  capacity reserved for another workload. Cover timeout, cancellation, clean
  exit and unknown cleanup disposition.
- Core activates only with the memory bridge and an authenticated admission
  authority. Keep admission and guest cleanup authoritative over idle shrink.
  Run the SPEED-058 memory qualification before comparative timing.

Evidence: Release canary verified the 448 → 2,048 → 448 MiB policy path, a
4 MiB payload through 12 launches, old boot and workload-sequence rejection,
and duplicate grant rejection. See
[SPEED-067 evidence](native-engine-validation.md#speed-067).

Review: Self-review and isolated validation complete. Independent review pending.

### SPEED-068

Title: Qualify Core response to independent native guest memory pressure

Description: Use a disposable, bounded guest service cgroup to produce
kernel-observed pressure independently of native launch admission. Verify
the restored target, reclaim ownership, live canary integrity during churn,
and idle shrink once both the service and the workloads are gone.

Is blocked by task: SPEED-067 validation, complete.

Acceptance Criteria:

- Record pressure counters or PSI and configured-capacity convergence after
  starting at a reduced target. Keep the pressure fixture confined to the
  diagnostic boot and preserve production and launch fixture limits.
- A pressure-only run must observe a Core target transition before submitting
  Docker launches. Preserve raw samples and cleanup results.

Evidence: The pressure-only service recorded 153 kernel memory.high events
and growth to 2 GiB while the native workload count was zero. Memory.high
events reached 272 during 12 fresh lifecycles while the 4 MiB payload stayed
intact. After the service and workload drained, the idle target converged
19.1 seconds after the PSI gate cleared, within the existing retry window.
See [SPEED-068 evidence](native-engine-validation.md#speed-068).

Review: Isolated validation and self-review passed. Independent review pending.

### SPEED-059

Title: Measure the current native fresh lifecycle against pinned Kiri

Description: Freeze a release native baseline at the existing API and CLI boundaries.

Is blocked by task: SPEED-058 isolated qualification, complete.

Acceptance Criteria:

- Record identical image/limits/clients, stage spans and two alternating diagnostic boot pairs with 200 timed operations and ten warmups per leg. Verify exit/output/cleanup and dynamic memory. Clearly label this a pilot, not five-pair qualification.

Problem and Evidence: Historical native measurements predate this candidate.

Approach: Use the existing comparison harness and private native owner, with tracing disabled for timings and separate attribution runs.

Evidence: Both alternating release boot pairs passed 200 API and 200 CLI
operations plus ten warmups per lane and leg. Native API p50 was 77.15–77.49
ms versus Kiri 3.67–3.70 ms. Native CLI p50 was 67.20–68.45 ms versus Kiri
19.96–20.16 ms. See [the release pilot](native-engine-validation.md#speed-059).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: Release pilot and self-review complete. Independent evidence review
and five-pair qualification remain pending.

Next Action: Attribute the native wait span before selecting the SPEED-060 change.

### SPEED-060

Title: Remove one measured native lifecycle delay

Description: Implement one attributed launch/event-delivery correction in the existing native path.

Is blocked by task: SPEED-059.

Acceptance Criteria:

- Name the exact delayed transition and clock-local evidence before editing. Preserve readiness, output and cleanup boundaries; add focused failure/race coverage. Run two alternating 200-operation A/B pairs and all affected memory gates; reject a non-improving candidate.

Problem and Evidence: The native API wait step had a 75.08–75.58 ms median
and dominated both boot pairs. Host create, start and remove together
accounted for less than 2 ms of per-stage medians.

Approach: Prefer event completion over measured polling. Use typed ownership, bounded queues and a clone-safe launch boundary; do not perform broad cosmetic rewrites.

Evidence: Host tracing measured 32.99 ms median between Core approval and
grant send. Direct notification reduced it to 0.012 ms. Two alternating
release A/B pairs lowered API p50 from 76.04–76.08 ms to 39.99–40.86 ms
and CLI p50 from 67.49–67.53 ms to 35.02–35.64 ms. Pressure and idle
qualification passed in event mode. See [SPEED-060 evidence](native-engine-validation.md#speed-060).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: Event wake accepted for the isolated candidate. Independent review
and comparative qualification remain required.

Next Action: Keep the 25 ms safety tick, and profile the remaining wait
before changing another mechanism.

### SPEED-061

Title: Repair native volume disk shutdown and filesystem recovery

Description: Recover only the useful volume checkpoint design and fix its documented shutdown/readiness defects.

Is blocked by task: SPEED-058 isolated qualification, complete.

Acceptance Criteria:

- Create eight volumes on an exclusively leased private disk; reboot twice, verify identities/data and clean offline e2fsck. Pass invalid-path, stale-generation and lease-conflict tests with no leaked disk holders.

Problem and Evidence: Archived c60304f failed fsck/readiness acceptance.

Approach: Inspect the archived diff and raw failures; implement a minimal current-tree disk lifecycle with orderly unmount and verified readiness.

Evidence: Four release boots kept the same leased host inode and eight
guest volume identities through two reboots and cleanup. A payload seeded
offline survived both reboots. All offline filesystem checks and lease,
path, capacity and generation negatives passed. See [SPEED-061 evidence](native-engine-validation.md#speed-061).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: Self-review and isolated validation passed. Independent review pending.

Next Action: Attach volumes to containers with generation-scoped ownership in SPEED-062.

### SPEED-062

Title: Attach and release native named volumes with container ownership

Description: Support one named-volume mount per container through the native Docker API.

Is blocked by task: SPEED-057, SPEED-061 and SPEED-069 isolated validation, complete.

Acceptance Criteria:

- Pass writable persistence across container replacement, read-only enforcement, busy-volume delete refusal, UID/GID behavior, cancellation and reboot recovery. Reject unsupported mount options explicitly.

Problem and Evidence: Disk registry alone does not implement container mounts.

Approach: Bind verified guest volume identity into the launch spec; hold ownership through verified cleanup and release it once.

Evidence: Two release boots passed the Docker writable and read-only
mounts, payload persistence, mapped identity, busy deletion, forced
cancellation and clean ext4 recovery. See [SPEED-062 evidence](native-engine-validation.md#speed-062).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: Isolated validation and self-review passed. Independent review pending.

Next Action: Use the qualified named-volume path in the Compose fixture.

### SPEED-069

Title: Bind verified native volume in the workload mount namespace

Description: Open the owned source after namespace creation while using the
inherited guest identity. Validate its inode, bind it to the fixed destination,
then close the source before workload execution.

Acceptance Criteria:

- The workload sees one owned volume and its declared read-only mode.
  A cancelled workload leaves no guest mount or host disk holder. Preserve
  native sandbox credentials and syscall policy.

Evidence: Opening the verified inode in the child mount namespace fixed
the earlier `EINVAL`. The child sees mapped UID/GID while the storage
registry sees the outer IDs. Both live boots passed.

Review: Isolated validation and self-review passed. Independent review pending.


### SPEED-070

Title: Lease a BuildKit writable snapshot to the native launch authority

Acceptance Criteria:

- Verify one task-owned guest-mounted snapshot by identity and retain it
  through cancellation, output and teardown. Return the same writable
  snapshot to BuildKit, preserving data and rejecting unsupported mounts
  before launch.

Evidence: The release native guest rejected an overlapping lease, then
reopened the same writable inode after cancellation and verified cleanup.
Offline filesystem checks and data readback passed. See [the snapshot
canary](native-buildkit-executor.md#speed-070-snapshot-canary).

Review: Isolated pre-staged snapshot validation passed. See SPEED-078 for
the live BuildKit mount and the ID-mapped read/write canary.


### SPEED-078

Title: Qualify the pinned BuildKit filesystem layout and snapshot ownership

Evidence: A live BuildKit 0.23.2 invocation gave the native resolver the
same ext4 device and inode as the pinned worker mount. A native release
canary proved writable UID/GID mapping across cancellation and cleanup,
with clean offline filesystem checks and stable production. See [the
snapshot evidence](native-buildkit-executor.md#speed-078-actual-native-snapshot-and-ownership).

Review: Isolated validation passed. Independent review pending.


### SPEED-086

Title: Bind the pinned BuildKit worker policy to a verified snapshot

Acceptance Criteria:

- On the existing authenticated snapshot endpoint, inspect a bounded
  root-owned config file for one verified bundle. Bind dynamic paths to
  that exact worker and snapshot, validate the process through the
  native launch limits, and reject changes to the captured namespace,
  mount, capability, device and seccomp policy. Return only policy and
  snapshot evidence, with no execution or process environment in the
  reply. Test the pinned config and unsupported variants on an isolated
  release guest.

Evidence: The authenticated release probe accepted the captured ten-mount
policy and refused ten incompatible or unsafe variants. The leased disk
was clean before and after the boot. See [the bundle intake
evidence](native-buildkit-executor.md#speed-086-verified-bundle-intake).

Review: Isolated validation passed. Independent review pending.


### SPEED-080

Title: Authenticate the BuildKit runtime client inside the native guest

Evidence: The pinned worker's capture executable verified the actual
mounted root through the boot-bound local socket. Peer credentials
rejected a guest UID 65532 process. Authenticated connections in this
scope cannot issue workload mutations or stop the host service.

Review: Isolated validation passed. Independent review pending.

### SPEED-064

Title: Qualify a two-service Compose lifecycle on the native engine

Description: Run a pinned two-service Compose project using private bridge DNS, health checks, a named volume and one loopback published port.

Is blocked by task: SPEED-060, SPEED-062 and SPEED-072–077 isolated validation, complete.

Acceptance Criteria:

- Pass up, health dependency, logs, restart, down, persistent data and resource cleanup. Capture real CLI/API transcripts; split unsupported required operations into concrete tasks before implementation.

Problem and Evidence: Individual container fixtures do not establish Compose behavior.

Approach: Use existing network/port research and native owner state; preserve lifecycle ordering and explicit feature errors.

Evidence: Compose 5.8.0 passed the two-service up, ordered health
dependency, private DNS, logs, loopback TCP, restart, persisted payload
and down. The private disk passed offline filesystem verification.
See [SPEED-064 evidence](native-engine-validation.md#speed-064).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: Isolated qualification and self-review passed. Independent review pending.

Next Action: Keep the fixture in release qualification after BuildKit passes.

### SPEED-072

Title: Support bounded Docker discovery for the pinned Compose project

Acceptance Criteria:

- Accept the pinned client's name and label filters on discovery. Reject
  unsupported filters explicitly. Verify that real Compose advances beyond
  discovery without mistaking another project's resources for this one.

Evidence: Release trace progressed through filtered networks, containers
and volumes to the writer create request. The filter regression covers
exact project label matches, missing labels, other projects and unsupported
keys. Transcripts are in SPEED-064 under `compose-volume-discovery`.

### SPEED-073

Title: Preserve two validated native bridge DNS aliases for Compose

Acceptance Criteria:

- A native endpoint can own its instance and service names on the same
  private address, with case-insensitive duplicate rejection, bounded
  aliases and complete removal at guest cleanup.

Evidence: Docker inspected both aliases, resolved the secondary name to
the primary address, completed TCP through the primary name, rejected a
case-insensitive duplicate and observed NXDOMAIN for both names after
removal. See SPEED-064 evidence `network-aliases`.

### SPEED-074

Title: Expose real generation-scoped Docker health checks for Compose

Acceptance Criteria:

- Run the fixture's bounded direct-command health check through guest exec.
  Reflect health in inspect, gate the dependent service, and reset on
  restart. Reject unsupported modes and preserve cancellation.

Evidence: The writer reported a real healthy state before Compose
submitted the reader's start. A second writer generation became healthy
after restart and read the same mounted payload.

### SPEED-075

Title: Accept Compose named-volume short syntax without exposing host binds

Acceptance Criteria:

- Parse one valid named volume at `/data` from HostConfig Binds, with
  optional read-only mode. Reuse the tested native ownership and mount
  path. Reject host paths, alternate destinations and unknown mount flags.

Evidence: The unchanged Compose project created the writer using the
named-volume short form. It started and its guest healthcheck verified
the file in the mounted destination. Host-path and option negatives passed.

### SPEED-076

Title: Supply daemon time and bounded Compose event subscriptions

Acceptance Criteria:

- Return real server time and stream scoped Docker lifecycle events
  without changing the existing unfiltered benchmark snapshot. Preserve
  ordered delivery and stop subscriptions on disconnect or owner drain.
- Verify Compose up, logs, restart and down through the pinned client.

Evidence: The pinned client completed up, logs, restart and down. Its
filtered stream used the daemon's real time. An independent bounded
subscriber observed the writer start before the dependent reader.

### SPEED-077

Title: Report active native loopback ports in Docker container discovery

Acceptance Criteria:

- Report the actual loopback endpoint in the Docker container list used
  by Compose. Verify it against TCP traffic and confirm down removes it.

Evidence: The list and Compose port agreed with the live loopback binding,
which returned the volume-backed payload. The port refused connection
after down.

## BACKLOG

### SPEED-014

Title: Validate and release the next Conjet version

Description: Release the merged speed enhancement through the existing app and,
if required, guest Core release lanes.

Is blocked by task: SPEED-013.

Acceptance Criteria:

- Select semantic versions from final scope and current releases; version metadata
  and release notes identify only verified behavior and performance claims.
- Merged revision passes applicable final checks and isolated app/DMG installation,
  launch, signing, notarization, stapling, and Homebrew validation.
- Required guest Core assets are released and verified compatible before the app
  release depends on them; release tags match their respective version metadata.
- Release workflows succeed, published assets and final checksums are verified,
  and temporary QA processes, mounts, disks, and files are cleaned up.

Problem and Evidence: Runtime performance qualification does not validate packaged
artifacts or app/Core compatibility; the existing project has separate release lanes.

Approach:

1. Inspect current release workflows and versions, select the next versions, and
   land reviewed release metadata through the repository's normal process.
2. Run isolated release simulations and verify the final artifact and guest-asset
   compatibility; resolve all failures before tagging.
3. Publish the appropriate tags from qualified revisions, monitor workflows, and
   verify release assets, Homebrew output, and cleanup.

Evidence: Local rehearsal and Homebrew rendering are recorded under
SPEED-012. The static guest is distributed in the app; the verified Core
v1.3.1 kernel remains compatible, so a separate Core release is unnecessary.
The production workflow fails closed on missing signing and notarization
credentials. Its keychain setup was exercised with the system Bash,
including a retained keychain path containing spaces. The repository
Actions secrets endpoint reports zero
repository secrets and the environments endpoint reports no environments.
Developer ID certificate and Apple notarization credentials must be
configured or their organization-level availability verified before
production publication. Tags, workflow evidence and published assets are pending.
The remote already publishes `conjet-v3.0.0` at `f1df932`, while this branch
still has `VERSION=3.0.0`. An additive release that includes a qualifying
experimental feature would use the next available minor version. The source
Docker adapter does not add a kernel or Core image dependency. The final
package scope and version remain pending independent review and qualification.

Source: [Release process](../release.md), [Homebrew](../homebrew.md),
[repository instructions](../../AGENTS.md).

Review: Pending; verify production artifact readiness, version/tag consistency,
asset compatibility, and evidence supporting every release claim.

Next Action: Set matching version metadata and release notes for the reviewed package scope before tagging an independently approved, qualified revision. Confirm Developer ID and notarization credential availability through the release environment.

## INPROGRESS

### SPEED-065

Title: Qualify native speed and memory against official Kiri

Description: Run the existing full comparison matrix on frozen native release artifacts.

Dependencies: SPEED-058, SPEED-060, SPEED-063 and SPEED-064 passed
their isolated gates. The standalone API/CLI series is complete.
The full comparison requires the exact release compatibility gate in
SPEED-098. The older five-pair lifecycle evidence remains historical
for this gate.

Acceptance Criteria:

- Run five alternating lifecycle pairs per API/CLI lane with 2,000 measured operations and ten warmups per engine/boot; preserve failures. Re-run image, build, Compose, networking/storage and concurrency rows using existing report formats. Pass full dynamic-memory and production-cleanup gates. Apply existing parity/advantage rules and report unsupported coverage and external limitations.

Problem and Evidence: Four lifecycle p99 bounds missed the parity gate.
The current Kiri pressure canary failed in all five boots. Performance
varied by workload.

Approach: Keep native API, Docker API and CLI timers separate; record hashes, p50/p95/p99, throughput, confidence intervals, resource data and exact cleanup boundaries.

Evidence: Five frozen release pairs passed 40,000 measured operations
and 200 warmups. Native API p50 was 2.66–3.57 ms, clearing 5 ms in
every boot. The paired median ratio was 0.8367 (95% CI 0.7703–0.9143).
The API and CLI p99 upper bounds were 1.0586 and 1.0553, above the
1.05 parity gate. Core pressure, idle shrink, data integrity and
isolated cleanup passed. The frozen matrix preflight recorded unsupported
builder provisioning, image tagging, public fixture pulls and stress
credentials. See [release results](native-engine-validation.md#speed-065-five-pair-release-lifecycle).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: The full planned sample counts, engine identities, paired
intervals and cleanup receipts are recorded. Independent review remains
pending.

Next Action: Review the lifecycle p99 misses, slower build and control
rows, and the Kiri pressure boundary before making release claims.

The `21171de` comparison completed all 60 lifecycle pairs and five
image pairs with zero workload failures. Four network-none lifecycle
rows missed the 1.05 p99 upper-bound rule. The upper bounds were 1.0970
and 1.0501 for Alpine true API and CLI, and 1.1440 and 1.0544 for
common-static API and CLI. The first mixed-language build session
reached the host image-store entry cap during Go and Node archive loads
after earlier exports had been untagged. See
`SPEED-065/cj-compat.tMPK1e-comparison-21171de/` for raw sessions,
paired intervals and failure evidence.

The exact `66a8a90` candidate passed SPEED-098 and completed the remaining
25 pairs. Both engines passed Buildx, Compose, control, storage and
network, and the 4,000 combined stress launches. Conjet passed all five
OOM canaries. Kiri timed out on Docker wait and reported no OOM flag in
all five boots at the verified limits. Both engines recovered and released
their private host resources. The untimed Docker Hub failure in build pair
four was retained alongside the passing same-artifact replay. The lifecycle
and image cohorts retain their original `21171de` hashes.
[Current comparison and limits](docker-benchmark-results.md#speed-065-optimized-native-comparison)

The later `d537487` harness rerun of the `66a8a90` source artifacts
completed 60 lifecycle and five image pairs. Its Node pair two and
Rust pair four failures remain in
`SPEED-065/cj-full.lQbpSK-full-d537487f49d3/`. After the authenticated
worker-observation fix, `16a05e0` passed 71/71 and all five fresh
Buildx pairs. Each engine completed 180 solves and exports, 180 loads,
and 180 executable-image canaries. Both prior failures were absent.
The new timing scope is Buildx. The other suites retain their original
artifacts, and full parity remains unqualified.
[Build-only rerun](docker-benchmark-results.md#speed-065-build-only-rerun)

### SPEED-089

Title: Qualify the Docker builder gateway for the frozen matrix

Acceptance Criteria:

- Verify the pinned Buildx driver, builder identity, cache ownership,
  allowed Docker API and resulting OCI export under native isolation.
- Qualify the frozen Rust, Go and Node RUN cases and cache treatments
  without widening the existing native fixture limits or restoring a
  retained runtime. Record unsupported combinations explicitly.

Evidence: The direct RUN canary in SPEED-063 uses a guest-local pinned
BuildKit worker. The frozen comparison uses the Docker API to create a
separate privileged Buildx worker container and its cache volume. The
current API returned HTTP 501 to build and HTTP 400 to a privileged
container create request. Each pinned Buildx worker bootstrap failed at
image provisioning; all three builder definitions were removed. The
constrained native OCI profile has no privileged worker mode.

The opt-in native build endpoint now accepts a bounded local Docker
context archive and uses the pinned Docker-container driver in the
launcher-owned client configuration. The private guest executed the
failure and success Dockerfiles. The API surfaced exit 23, then published
the successful archive under the requested tag and ran its output canary.
Both exact worker/RUN generations and the tag inventory confirmed
cleanup. See `SPEED-089/cj-compat.tMPK1e-unpacked-archive/`.

Child tasks are frozen in the [native compatibility manifest](../../benchmarks/scenarios/native-compatibility-v1.json).
An unsupported, missing, skipped, flaky or failed required case fails
SPEED-098 and gates a new SPEED-065 matrix.

### SPEED-090

Title: Qualify native image provisioning and identity

Acceptance: Boot-private store and pinned Linux ARM64 matrix references,
tag and digest resolution, inspect, load/save, shared layer accounting,
and interrupted/corrupt transfer cleanup. An image referenced by a
container must not be destructively removed.

Evidence: Boot-local Docker tags, inspection, launch by alias, untag
and manifest protection passed with the pinned client on the isolated
release path. The loopback registry's integrity and ownership checks
also passed. Public provisioning, registry tag resolution and
archive save/load remain open. [Compatibility evidence](native-compatibility.md#speed-090-local-image-tags)

### SPEED-099

Title: Load and save Docker image archives on the native endpoint

Acceptance: Accept bounded fixed-size and chunked uploads on the image-load
route. Verify the pinned Docker archive's original config and layer digests,
preserve aliases and runnable output, export an equivalent Docker archive,
and reject invalid framing or corrupt content without publishing partial state.

Evidence: The frozen common archive and pinned Alpine passed load,
save, reload, config identity and native execution. Corrupt content
left the scoped image store unchanged. [Archive evidence](native-compatibility.md#speed-099-docker-archives)

### SPEED-100

Title: Provision and ingest the pinned native matrix images

Acceptance: Resolve approved image references to verified ARM64 manifests,
ingest the frozen larger layers under explicit storage and Core memory bounds,
and exercise PAX metadata, shared blobs, interruption and cleanup without
lowering the fixture acceptance rules.

### SPEED-101

Title: Apply verified OCI PAX path metadata

Acceptance: Interpret the pinned Go layout's local path and link-path
records. Preserve regular entry ownership, mode, root-relative checks
and payload bounds. Reject unsupported extensions before publishing.

Evidence: Local path and link-path validation tests passed, including
duplicate, dangling, unsupported and escaping metadata. The pinned Go
layout advanced past the earlier PAX failure and reached the existing
OCI byte bound. Logs are under `SPEED-101/` on ExternalSSD.

### SPEED-102

Title: Fetch the frozen Docker Hub pins through the native image store

Acceptance: Provision the approved image references through authenticated
HTTPS and verify every manifest, config and layer before admission.
Retain the loopback test registry and confirm unknown repositories or
digests cannot trigger outbound fetches. Keep credentials out of logs
and the process command line.

Evidence: The isolated HTTPS source provisioned and verified the
pinned ARM64 Registry image. Cached pull, unrelated digest and
platform rejection, and cleanup passed. The Registry executable
exposed a separate Go thread-creation failure.

### SPEED-103

Title: Qualify thread creation inside the native OCI sandbox

Acceptance: Admit only same-process threads under the established
namespace, capability, seccomp and PID limits. Reject clone requests
that create a separate process or namespace. Reproduce the observed
Go workload behavior and preserve the evidence for any remaining
resource or syscall failure.

Evidence: A native ARM64 musl probe created a same-process thread under
the four-PID fixture ceiling. Namespace creation was rejected with
EPERM and unchecked clone3 returned ENOSYS. The pinned Registry binary
advanced from EPERM during thread creation to PID exhaustion under the
same four-PID settings. With omitted PID limits it reached its next
failure at epoll initialization, tracked in SPEED-118. Logs are under
`SPEED-103/` on ExternalSSD.

### SPEED-104

Title: Spool native OCI transfers and validate from the owned file

Acceptance: Preserve the existing wire, generation, integrity and
publication rules. Replace full in-memory transfer buffering with
an unlinked private spool and incremental digest, and validate the
package directly from the file. Qualify interruption, rollback and
successful native execution at the existing limits before expanding
the image budgets.

Evidence: The two-layer fixture passed live import, execution, overlap,
removal and rejection checks, including bad digest, offset, abort and
stale generation. The separate common and Alpine archive round trips
also passed. Both Core sessions shut down cleanly and preserved production.
Logs are under `SPEED-104/` on ExternalSSD.

### SPEED-105

Title: Put imported OCI roots on an isolated Core guest disk

Acceptance: Stage and execute the archive fixture from the exclusively
leased ext4 volume with Core dynamic memory enabled. Keep the generation
store separate from named volumes. Clear a stale generation before
starting the next supervisor and clear current imports before shutdown.

Evidence: The pinned CLI passed both archive round trips on ext4, then
passed them again after a stale image generation was planted offline.
Both runs preserved production, removed the private session and released
the disk lease. The offline filesystem checks passed and the image
generation directory was absent. Logs are under `SPEED-105/` on ExternalSSD.

### SPEED-106

Title: Encode native image packages with bounded streaming file extents

Acceptance: Transfer and verify individually bounded raw file extents
in the Core disk image profile. Preserve digest verification, validated
root paths, credentials, hard links, atomic publication and cleanup.
Reject malformed encodings, truncated files and invalid metadata. Retain
the existing JSON small-image package and its limits.

Evidence: The original two-layer fixture passed install, overlapping
execution, exec, removal, abort and integrity checks through the packed
path. A separately identified 80 MiB streaming canary also passed.
Both used the dynamic Core profile, released the private disk and passed
offline ext4 checks. Logs are under `SPEED-106/` on ExternalSSD.

### SPEED-107

Title: Stage large pinned OCI layouts from verified on-disk tar extents

Acceptance: Stream compressed and uncompressed layer verification and
create a packed root under bounded ExternalSSD scratch. Exercise the fixed
Node, Go and Rust layouts, retaining manifest and config identity,
whiteouts, links, metadata validation and atomic publication.

Evidence: The fixed Go and Rust layouts staged 214,178,773 and
1,042,718,012 byte packages with peak process RSS of 20.1 and 8.7 MiB.
The legacy archive regression passed through native execution. Node
reached the mode validator and exposed the directory metadata handled in
SPEED-108. This evidence covers staging. Logs are under `SPEED-107/`
on ExternalSSD.

### SPEED-108

Title: Preserve mapped group inheritance on OCI directories

Acceptance: Preserve the group inheritance mode on the pinned Node and
Redis home directories. Reject set-user-ID on all entries and
set-group-ID on non-directory entries. Verify the directory mode and
mapped ownership without broadening workload credentials.

Evidence: The fixed Node and Redis packages now stage their original
`02755` directories with the pinned IDs. The pinned Redis image returned
`2755:999:1000` in a native workload, with verified cleanup. Set-user-ID
entries and set-group-ID files failed validation in tests. [Directory
mode semantics](https://man7.org/linux/man-pages/man7/inode.7.html)

### SPEED-109

Title: Stream large registry blobs into the private native disk image store

Acceptance: Pull exact frozen public image pins through the real Docker
endpoint. Verify bounded blob downloads and packed guest installation,
old JSON cache entries, shared references, rollback and cleanup. Keep
the private lease and Core dynamic memory.

Evidence: The optimized private endpoint pulled, inspected, cached and
removed the fixed Registry, Redis, Node, Go and Rust images. Node, Go
and Rust required 13.9, 17.5 and 54.6 seconds in the complete verification
run. The guest execution and teardown witnesses passed, and the host image
store and offline ext4 checks verified cleanup. A separate run retained the
loopback interruption and hash rejection results. Logs include the first
idle witness-connection failure under `SPEED-109/` on ExternalSSD.

### SPEED-110

Title: Attach Docker's built-in bridge without joining the custom bridge

Acceptance: Resolve explicit bridge and default Docker network modes to
the built-in network. Verify distinct namespace and address scope
alongside the existing custom internal bridge, default-route metadata
and cleanup. Run the original no-network and bridge lifecycle fixtures
with their existing resources, commands and outputs.

Evidence: Both bridges owned live endpoints simultaneously, with distinct
subnets, resolver addresses and endpoint inventories. The built-in
resolver returned NXDOMAIN for a custom alias. A corrective release
normalized the OCI scope at the helper boundary. All twelve original
API/CLI and network canaries passed once, including exact output,
exit status and unique teardown witnesses. This is a correctness canary.
The private boot has no external uplink. Logs are under `SPEED-110/`.

### SPEED-111

Title: Apply explicit native OCI resources and Docker control defaults

Acceptance: Apply the existing frozen explicit memory, PID and CPU
settings to the workload cgroup. Accept omitted resource options with
the native engine's documented effective policy, and report and verify
the resulting bounds. Preserve static fixture restrictions and Core
admission, pressure recovery and idle shrink.

Evidence: Release diagnostics checked the kernel cgroup and Docker
configuration for omitted limits, partial limits and the frozen lifecycle
and service values. All four workloads had verified teardown. Invalid
limits were rejected before admission. The first run exposed the relative
launch command restriction tracked in SPEED-113. Logs are under
`SPEED-111/` on ExternalSSD.

Core evidence: Workload demand and independent zero-workload pressure
each restored the target from 448 MiB to 2,048 MiB. The active-data and
ownership checks passed and both sessions returned to 448 MiB.

### SPEED-112

Title: Keep admitted Docker services alive through bounded control waits

Acceptance: Verify a detached native service remains available beyond
the current setup tracking deadline. Separate startup, running and
teardown waits. Preserve service cancellation, output draining,
generation ownership and release cleanup.

Evidence: The baseline lost its running guest generation by 36 seconds.
The corrected release kept the same generation, retained its marker data
and returned the original logs at 36 seconds. Forced removal then gave a
verified guest cleanup witness and an empty workload inventory. Logs are
under `SPEED-112/` on ExternalSSD.

### SPEED-113

Title: Resolve named launch commands inside the OCI workload root

Acceptance: Launch the frozen default `sleep` command and pinned image
entrypoints through the workload's configured PATH. Reuse the existing
bounded exec search after chroot and identity setup. Preserve absolute
command behavior, reject ambiguous paths and keep the static guest
fixture restriction.

Evidence: The actual bare `sleep` command passed under the default,
partial, lifecycle and service resource settings, and a relative path
with a slash was rejected. The original absolute lifecycle canaries
passed. The verified Redis boot entered its declared shell script and
the script reached the `umask` command substitution before the pipe
restriction. Shell subprocesses are tracked in SPEED-116. Logs are under
`SPEED-113/` on ExternalSSD.

### SPEED-114

Title: Stream the frozen Node Docker image archive round trip

Acceptance: Save and reload the original Node image tag through the
private disk-profile Docker API with bounded archive reads and verified
layer extents. Preserve the original config and executable contents,
archive framing, rollback and removal. Keep the existing archive profile
limits for boots without the disk-backed store.

Evidence: The frozen Node pin saved a 61,165,568-byte archive. The release
removed the alias, reloaded the archive, confirmed the original config
ID and native executable contents, then removed the alias and source.
The common/Alpine and corrupt archive regressions passed on both
profiles, and the leased disk passed offline ext4 checks. Logs are
under `SPEED-114/` on ExternalSSD.

### SPEED-115

Title: Apply inherited cgroup semantics to native exec

Acceptance: Exercise exec in a workload with omitted Docker resources
and in a workload with the frozen service limits. Join the existing
owned cgroup and retain its credentials and exit behavior.

Evidence: Four resource cases observed the same guest handle and
unchanged kernel limits during exec. `pids.current` rose from one to
three in each owned cgroup. Exec and cleanup passed, as did the native
exec regression. Logs are under `SPEED-115/` on ExternalSSD.

### SPEED-116

Title: Support ordinary shell subprocesses inside the native OCI sandbox

Acceptance: Reproduce the pinned Redis entrypoint's command substitution
and the original Node entrypoint. Admit pipes and ordinary child
creation with cgroup ownership and bounded flags. Keep namespace
creation, process-parent changes, ptrace and privilege changes outside
the workload's authority. Keep thread creation separately qualified by
SPEED-103.

Evidence: The pinned Redis script completed its earlier failing command
substitution. The original Node entrypoint invoked the selected payload
from the reloaded archive. A namespace-creation request failed with
EPERM, and both Node cases had verified native teardown. Logs are under
`SPEED-116/` on ExternalSSD.

### SPEED-117

Title: Qualify full frozen lifecycle groups with native teardown witnesses

Acceptance: Use the frozen runner and counts, require the original
exit and output asserts and a unique guest cleanup witness on every row.
Allow independent private boots per group without accepting shortened,
duplicate, recovered or missing group evidence.

Evidence: The original common-static built-in-bridge API group passed
2,000 measured cases and ten warmups with unique native teardown. The
evaluator counted only that provided group and kept the 71-case result
failed. The frozen source hashes still match. Logs are under
`SPEED-117/` on ExternalSSD.

### SPEED-118

Title: Support descriptor-owned native event polling for pinned applications

Acceptance: Run the original pinned Node command and Registry binary
through their event-loop initialization. Admit the required event
descriptor and poll operations for ordinary OCI only. Preserve existing
resource limits, I/O ownership, seccomp and cleanup.

Evidence: Registry returned its pinned v2.8.3 version. The Node workload
advanced from libuv startup failure to a nonblocking stdout failure.
After adding the descriptor-specific operation, the original
`node -e 'console.log("image-node")'` command returned its exact
output from the reloaded archive with verified guest cleanup. Logs
are under `SPEED-118/` on ExternalSSD.

### SPEED-119

Title: Retain and transfer the full frozen exec output

Acceptance: Deliver both exec streams up to a bounded retention limit
through authenticated chunks. Preserve ordering, exit status,
connection and workload ownership, overflow handling and cleanup.
Exercise the original 128 KiB output case once the approved workload
devices are available.

Evidence: The release returned the exact 128 KiB stdout and 8,200-byte
stderr canary with exit 23. A separate case reached the new bounded
256 KiB retention limit and reported overflow. Foreign and out-of-order
reads failed, connection loss released the transfer and the original
workload remained usable. Logs are under `SPEED-119/` on ExternalSSD.

### SPEED-120

Title: Expose the native null and zero devices through the private workload root

Acceptance: Provide the standard null and zero devices to ordinary OCI
with individually verified device identities and no broader device tree.
Run the frozen Docker exec case that reads 128 KiB from `/dev/zero` and
verify output, teardown and continued workload operation.

Evidence: The exact frozen `dd` command returned 131,072 zero bytes.
Writes to `/dev/null` were discarded. The workload could not see
`/dev/mem` or `/dev/kmsg`, and the exec and owner cleanup checks
passed. Logs are under `SPEED-120/` on ExternalSSD.

### SPEED-121

Title: Allocate an owned PTY for noninteractive Docker exec

Acceptance: Run the original `docker exec -t` workload with a real
slave terminal and raw Docker output. Verify the terminal belongs to the
isolated guest, non-TTY exec still multiplexes streams, and guest
shutdown releases the private PTY mount.

Evidence: The pinned CLI passed the original `exec -t` operation and
its `isatty` and output assertions. The unchanged exec regressions
passed, and clean shutdown released the PTY mount. The full control
preflight also passed the frozen TTY and 128 KiB exec cases. Logs are
under `SPEED-121/` on ExternalSSD.

### SPEED-122

Title: Negotiate Docker exec HTTP streaming and socket upgrade

Acceptance: Return a 200 multiplexed response for a plain exec API
request and preserve HTTP 101 for an explicit TCP upgrade. Verify
original stdout, stderr, exit status and follow-up inspect semantics.

Evidence: The frozen control matrix passed all 110 plain HTTP exec
runs. The same release passed the explicit upgrade, CLI, TTY, stream
and replay checks. Logs are under `SPEED-122/` on ExternalSSD.

### SPEED-123

Title: Read bounded Docker copy archives from an owned running workload

Acceptance: Implement Docker path stat and single-file export from the
verified workload root. Verify the 4 KiB and 8 MiB data paths, bounded
transfer and symlink rejection.

Evidence: The pinned Docker CLI exported both 4 KiB and 8 MiB with
matching SHA-256. A stale file revision, symlink and parent traversal
were rejected. Native teardown passed. See `SPEED-123/export-dedicated-peer/`
on ExternalSSD.

### SPEED-124

Title: Upload bounded Docker copy archives into an owned running workload

Acceptance: Accept the original pinned client's request framing and tar
layout. Stage a single-file upload, verify contents, publish atomically
and prove the frozen round trips by SHA-256. Reject escapes and discard
partial writes.

Evidence: The optimized candidate passed the frozen 4 KiB and 8 MiB
copy round trips with the pinned Docker CLI. The live guest rejected
traversal, a symlink destination, trailing tar data, and an invalid
digest. Reuse after disconnect confirmed partial data was discarded.
See `SPEED-124/live-copy-final/` on ExternalSSD. The full control
preflight also covers the separate interactive attach requirement.

### SPEED-125

Title: Relay attached stdin to an owned native container

Acceptance: Support the frozen interactive create and attach request
through a bounded stdin path. Preserve the original output streams,
exit 23, logs, disconnect recovery and cleanup.

Evidence: The pinned control run passed 110 interactive attach cases,
110 exact log checks and the idle disconnect/recovery assertions.
See `SPEED-130/control-preflight/` on ExternalSSD.

### SPEED-126

Title: Publish the first copy into an absent guest destination

Acceptance: Run the frozen Docker copy fixture from an absent
`/tmp/control` and then replace it. Preserve the guest identity,
digest, atomic publication and cleanup checks for both cases.

Evidence: The first full control preflight reproduced a guest rename
failure only when the target was absent. The mapped, no-replace
publication then passed all 440 original copy operations. The focused
create-and-replace run also passed. See `SPEED-125/control-preflight/`
and `SPEED-127/file-enumeration/` on ExternalSSD.

### SPEED-127

Title: Permit owned directory enumeration and file removal

Acceptance: Verify the ordinary guest can enumerate a nonempty
workload directory and remove its own regular file. Preserve the
existing mount, capability, BuildKit and static fixture policies.

Evidence: The running Alpine workload removed the old file and listed
exactly `control` after round trips. The directory had no retained
upload staging entry. See `SPEED-127/file-enumeration/`.

### SPEED-128

Title: Qualify the frozen control cases with native teardown witnesses

Acceptance: Preserve all original control operations and counts.
Verify persistent identity, every attach and copy result, separate
stop/kill/restart generations, and native teardown on exact release
artifacts before recording any control requirement as passing.

Evidence: The full control run retained the persistent removal witness
and 110 distinct attach teardown witnesses. The separate control
diagnostic verified three generations and graceful stop, SIGKILL, and
timeout escalation. Final gate aggregation still requires all suites
on one exact artifact set.

### SPEED-129

Title: Mount owned named volumes at the frozen workload paths

Acceptance: Bind the verified named-volume inode at the original
dataset and registry targets, preserve the data target, and reject
symlinked ancestors and unsupported targets. Verify healthy removal
and the volume contents after a second mount.

Evidence: The baseline returned HTTP 400 for `/dataset`. The optimized
diagnostic wrote its witness there, remounted the same volume read-only
at `/var/lib/registry` in a second boot, and verified the payload, removal,
and offline ext4 check. This exercised the volume targets independently
of the frozen Node workload. See `SPEED-129/` on ExternalSSD.

### SPEED-130

Title: Release disconnected native Docker stream subscribers on Darwin

Acceptance: Distinguish a client that closed its socket from one
that only closed its write side. Run all original attach cases
beyond the 32-socket endpoint limit and preserve detach recovery.

Evidence: The original run hit the socket limit after 29 successful
attaches. A Darwin socket-pair test reproduced the missing hangup and
verified that the new check preserves a write half-close. All 110
attach cases passed the subsequent release preflight.

### SPEED-131

Title: Resolve immediate exec while the assigned workload is still starting

Acceptance: Retry only the same generation's in-progress startup
within the exec budget. Observe the original immediate large-output
command and keep stopped, removed and failed workloads rejected.

Evidence: The original initial exec failed with `not_running` before
the guest entered its running phase. The release preflight passed the
immediate exact 128 KiB exec canary, all 110 exec API and CLI samples,
and TTY and lifecycle regressions.

### SPEED-132

Title: Admit the exact bounded Node storage program

Acceptance: Run the original 2,121-byte storage program using the
pinned Node image. Verify sequential and random data plus small-file
metadata. Retain total spec size, executable paths, build snapshots
and static argument bounds.

Evidence: All six original writable-layer runs passed with the frozen
Node image and matched the expected 16 MiB trace. The pinned Alpine musl
`pwrite` uses `pwritev2` with `RWF_NOAPPEND`. The guest checks that flag
and keeps the new filesystem calls in the ordinary OCI profile. See
`SPEED-134/storage-frozen/` on ExternalSSD.

### SPEED-133

Title: Preserve Docker labels on native named volumes

Acceptance: The frozen storage and Compose clients can create labeled
local volumes. Inspect and filtered list return the original labels
after another guest boot. Bound the metadata and keep it outside
workload control.

Evidence: Both optimized boots returned the original label by inspect
and exact filter. The frozen Node storage preflight passed all six
labeled creates and removals. Compose progressed past volume creation.
See `SPEED-133/` and `SPEED-132/storage-positional-vector/` on ExternalSSD.

### SPEED-134

Title: Initialize new volumes for the first mapped root workload

Acceptance: The frozen Node workload can write and read back its named
volume using its default identity. Keep legacy volume ownership,
preserve bytes across subsequent mounts, and serialize the first use
of a new volume against competing admissions.

Evidence: All six original named-volume runs and independent readbacks
passed using the default Node identity. The final SHA-256 matched the
writable-layer trace in every run. See `SPEED-134/storage-frozen/`.

### SPEED-135

Title: Serve scoped host bind mounts in the native guest

Acceptance: Use a live filesystem backed by the declared, owned
ExternalSSD source directory. Keep the host and guest views coherent,
verify the original host checksum, and revoke the mount and its
transport on teardown. Deny paths outside the configured share.

Evidence: Six original bind runs agreed with the host's 16 MiB SHA-256
and recorded independent guest and relay teardown. The descriptor
walk denied symlink and parent traversal. The same preflight passed
all writable-layer, named-volume and readback cases, with verified
owned cleanup and an offline ext4 check. See `SPEED-135/storage-final/`.

### SPEED-136

Title: Honor Compose volume removal framing

Acceptance: Accept the pinned client's force query on local removal.
Keep referenced volumes protected and verify scoped teardown.

Evidence: The optimized API returned 409 for forced removal while
the workload held the volume. After another boot, the pinned client
removed it, a repeated forced removal returned 204, and the offline
ext4 check passed. See `SPEED-136/` on ExternalSSD.

### SPEED-137

Title: Mount each workload's real cgroup read-only

Acceptance: Original Docker exec and Node startup can read the live
memory, CPU, PID, and swap fields under `/sys/fs/cgroup`. Keep ancestor
and sibling cgroups outside the workload and reject control writes.

Evidence: The optimized resource canary read the actual controller
files using the pinned Docker CLI for default, partial, lifecycle and
service limits. It rejected writes, verified exec membership in the
same cgroup, and confirmed all teardown. See `SPEED-137/live-cgroup/`.

### SPEED-138

Title: Enforce the frozen swap setting and attribute real cgroup OOM

Acceptance: The pinned Node workload reads its actual 64 MiB and
zero-swap controls, exits 137 after a kernel OOM kill, and reports
OOMKilled. The other workload keeps its data and the survivor and
recovery starts retain their original controls.

Evidence: The frozen stress preflight passed all 400 samples and
40 warmups. The Node process read `67108864 0`, exited 137, and had
`OOMKilled=true` from the kernel counter. The survivor preserved its
bytes and the recovery launch passed. See `SPEED-138/stress-and-oom/`.
The later optimized boot repeated those counts and confirmed distinct
guest cleanup handles for the OOM target, survivor and recovery. The
normalized OOM gate returned true with no operation errors and clean
launcher teardown. See `SPEED-138/final-witness/`.

### SPEED-139

Title: Create the frozen Compose bridge with a routed guest gateway

Acceptance: Preserve the requested internal flag and install the
private guest default route for a non-internal bridge. Keep the
release preflight VM air-gapped, retain DNS and host loopback
publication, and verify network teardown.

Evidence: The routed bridge passed real guest DNS, TCP, reconnect and
teardown, and reported the original `Internal=false` request. The
isolated VM retained its air gap. Both full Compose preflights stopped
at a Docker Hub timeout before network creation. See `SPEED-139/`.

### SPEED-140

Title: Seed exact pinned application images for offline runtime diagnosis

Acceptance: Reuse verified local Node and Redis OCI layouts when
Docker Hub stalls during Compose setup. Authenticate the exact
manifest, config and layer extents before publishing. Keep public
registry acquisition as its own required test.

Evidence: Local Node and Redis layouts passed the pinned manifest and
layer checks. Both Compose prepulls then passed, and setup reached
Redis container creation. Redis's config digest is transitively pinned
by the manifest. No public acquisition pass was recorded. See
`SPEED-140/compose-manifest-config/` on ExternalSSD.

### SPEED-141

Title: Resolve mapped credentials from the verified OCI image

Acceptance: Read the bounded image account files for named users,
groups and numeric primary groups. Retain explicit numeric pairs,
inherit the resolved identity on exec, and reject unknown or
unmapped identities without adding capabilities.

Evidence: The optimized Alpine canary resolved named user and group
selectors and numeric primary groups. An otherwise valid numeric ID
absent from the account file used group zero. Exec inherited the real
resolved UID and GID. Unknown names and unmapped numeric IDs were
rejected before launch. See `SPEED-141/credentials/`.

The isolated qualification in `SPEED-141/frozen-image-identities-cleanup/`
also verified every pinned image's default UID/GID and read its effective
16 MiB memory, four-task and half-CPU limits in the guest. The original
explicit probes and inherited exec passed. All six denied requests left
no container object. The diagnostic used digest-verified offline inputs,
released each nonboot image and left the production session unchanged.

### SPEED-142

Title: Accept the frozen Compose healthcheck retry count

Acceptance: Preserve the pinned fixture's 1-second interval, 2-second
timeout and 12 retries without expanding the healthcheck command scope
or weakening timeout and exhaustion checks.

Evidence: The original fixture progressed past the retry policy and
created both containers. Redis then exited 1 before becoming healthy.
Compose teardown separately exposed its container-removal volume flag.
See `SPEED-142/compose-health-policy/`.

### SPEED-143

Title: Preserve named volumes during Compose container removal

Acceptance: Accept the original Compose container-removal flag for
anonymous volumes. Release the container's named-volume reference and
let the subsequent explicit volume request remove it.

Evidence: The frozen Compose client removed both containers, the
network and the named volume in all six teardown runs. See
`SPEED-145/compose-redis-bootstrap/` on ExternalSSD.

### SPEED-144

Title: Drain owned descendant processes before releasing a workload cgroup

Acceptance: Close the original workload and any in-flight health
exec in its exact cgroup. Confirm empty removal within the cleanup
budget and retain the main process's exit status.

Evidence: The earlier Compose run hit a busy cgroup while Redis and
its health probe were exiting. All six rapid Redis exit and removal
cycles finished cleanly after the bounded cgroup drain. See
`SPEED-145/compose-redis-bootstrap/`.

### SPEED-145

Title: Run the pinned Redis entrypoint with scoped credential transitions

Acceptance: The original Redis entrypoint can transfer its private
data directory and drop to the pinned Redis account. Limit any
additional authority to the verified fixture image and startup
arguments. Preserve the ordinary no-capabilities profile.

Evidence: The isolated optimized release ran the exact entrypoint,
passed the ARM64 copy-on-write self-test, installed the real append-only
journal and became healthy in all six original Compose projects. Four
live PID status reads showed UID 999, GID 1000, empty supplementary and
effective capability sets, and no-new-privileges. Two status probes
collided with the existing health exec slot. Each project completed the
first two persisted transactions before Compose recreation reached its
duplicate-alias gate. Compose's resource observer also requires exec
stdin support. All projects tore down and the launcher reported
complete guest cleanup, zero reclaim failures and unchanged production.
See `SPEED-145/compose-redis-journal/` on ExternalSSD. The public image
downloads were replaced by verified offline seeds for this diagnostic.

### SPEED-146

Title: Publish independent loopback ports for concurrent service replicas

Acceptance: Bind one separately owned loopback endpoint per native
container within the existing workload limit. Verify both serve their
own response, an explicit bind conflict fails, and removing either
replica leaves the other reachable.

Evidence: The isolated optimized published-port diagnostic confirmed
two distinct live loopback listeners, separate response payloads and
explicit conflict rejection. Removing the first listener left the
second serving. Both sockets closed on removal and the guest had zero
active workloads. See `SPEED-146/multi-publish/` on ExternalSSD.

### SPEED-147

Title: Resolve shared Compose service aliases within one project network

Acceptance: Return each running replica's real IPv4 address for its
service name and a single response for each unique instance name.
Reject unrelated duplicate aliases and remove answers when backing
ports detach.

Evidence: Six original Compose projects resolved the service alias to
both live app addresses and each instance alias to one matching
address. Both replicas completed their next persisted transactions.
All six projects tore down with empty inventories. Redis restart
readiness and the service exec resource probe remain separately open.
See `SPEED-147/compose-scale-dns/` on ExternalSSD.

### SPEED-148

Title: Report actual cgroup counters for the frozen service stats check

Acceptance: Read the selected running generation's own CPU, memory and
task counters and expose them through Docker's one-shot stats operation.
Preserve the resource limits and verify the original sustained-service
window, counts and teardown.

Evidence: The optimized storage/network preflight ran for 60.011 s
and verified 4,691 sequential Redis-backed transactions. The native
stats query returned CPU, memory and task counters for both services.
The direct cgroup checks still read 128 MiB, 64 tasks and 500 mCPU.
All storage checks passed. Guest cleanup, ExternalSSD lease release,
production fingerprints and offline ext4 checks passed. See
`SPEED-151/storage-sustained-stats/` and `SPEED-151/disk-check.log`.

### SPEED-149

Title: Support Compose's staged replacement and rename

Acceptance: Admit an owned replacement for the exact existing service
generation. Prevent alias reuse while the old container can serve,
then support the original stop, remove, rename and start sequence.

Evidence: All six original Compose projects passed forced app recreation
and received transaction 3 after the generation change. See
`SPEED-149/compose-recreate/`. The later scale run repeated the result.

### SPEED-150

Title: Preserve finite stdin for native Docker exec without a terminal

Acceptance: Round-trip bounded stdin and EOF through the Docker exec
stream without modifying the caller or treating an attached stream as
empty. Qualify the original Compose cgroup observer.

Evidence: The optimized Docker exec diagnostic round-tripped 4,096
binary bytes and immediate EOF and rejected 4,097 bytes before
starting the command. The same run passed exit-code, TTY, separate
output, active removal and bounded output checks. The six Compose
projects each read the exact Linux limits from both guest cgroups.
See `SPEED-150/exec-stdin/` and `SPEED-151/compose-persisted/`.

### SPEED-151

Title: Preserve bridge neighbor reachability across service restart

Acceptance: Verify a live app can continue using its resolved Redis
endpoint after the earlier network namespace and links are removed.
Preserve both readiness and the next persisted sequence numbers within
the original fixture windows.

Evidence: Stable locally administered MAC addresses now follow the
private bridge and its owned IPv4 slots. After verified detachment,
the replacement had the same IP and MAC and both app replicas became
ready after Redis restart in all six projects. The 12 readiness probes
took 2.34–4.15 ms in this diagnostic, and all projects observed
persisted transactions 6 and 7. See `SPEED-151/compose-persisted/`
on ExternalSSD. The work exercised private seeded image content.

### SPEED-152

Title: Pull through the owned frozen Registry loopback publication

Acceptance: Run the pinned Registry service with the original default
resource request. Scope pulls to its live internal loopback publication,
verify digest and inventory identity, and remove imported fixtures and
the Registry store after each original run.

Evidence: The original pinned service started with the unchanged
default resource request. The optimized diagnostic verified 12
cold config and layer transfers, 12 cache hits with no additional
registry GET, 12 workload launches with distinct complete native
cleanup receipts, and removal of each image and the Registry volume.
See `SPEED-152/registry-full-witness/`. The service image came from the
verified private seed in this run. Separate public runs captured an
initial successful service pull and later Docker Hub timeout failures.

### SPEED-153

Title: Stream the pinned Buildx dial-stdio exec transport

Acceptance: Keep the authenticated native worker exec attached in both
directions while the pinned Buildx client exchanges frames. Preserve
EOF, backpressure, stderr, terminal status, disconnect and cancellation.
Finish guest cleanup before releasing the exact exec owner.

Evidence: The authenticated guest transport emitted output before
receiving input, returned 16,384 binary bytes with separate stderr
and exit 23, rejected an extended budget on an ordinary workload, and
released its slot on disconnect. The Docker gateway ran the real
pinned `buildkitd --version` with stdin open, returned v0.23.2 and
reported exit 0. It read the actual guest ARM64 CPU information. See
`SPEED-156/cache-gateway-cpu-info/`. The worker still must run the
original Buildx `dial-stdio` solve and cancellation.

Build pair four of the subsequent `66a8a90` comparison stalled after
writing the expected number of bytes in a Rust dependency export.
The worker accumulated 648.061 seconds of user CPU, compared with
5.694 to 5.939 seconds for that builder in the preceding three boots.
The upstream missing-cache-record regression timed out inside BuildKit
0.23.2's cache exporter and passed on the same source with the upstream
fix. The original worker stack is unavailable, so its specific loop
remains unconfirmed. The original pin stays in the frozen comparison.
See `SPEED-153/cj-full.lQbpSK-buildkit-exporter/` for the focused
regression and `SPEED-153/cj-full.lQbpSK-rust-export-trace/` for
twelve diagnostic builders that completed without the stall.
[Upstream fix and regression](https://github.com/moby/buildkit/pull/6186)

### SPEED-154

Title: Mount a leased native BuildKit workspace beside the disk image store

Acceptance: Keep the private image and volume stores available to the
Docker adapter while the native build runtime borrows an executable
snapshot. Validate both isolated stores, preserve ordinary mount
restrictions and release the lease after both mounts are closed.

Evidence: The optimized isolated boot enabled both disk profiles and
borrowed the exact snapshot inode. It denied traversal, symlinks, stale
generation and conflicting ownership, cancelled the first workload
with complete cleanup, and reopened the inode to verify the saved
payload. Guest shutdown, disk lease release and offline ext4 checks
passed. The joint mount is a prerequisite for Docker Buildx provisioning.
See `SPEED-154/combined-recovery-mounted/` and `SPEED-154/disk-after.log`.

### SPEED-155

Title: Stage the exact pinned BuildKit image on the no-suid disk store

Acceptance: Preserve the pinned manifest and file metadata for the
BuildKit image. Permit its exact `fusermount3` mode only on the
no-suid disk path. Retain the existing rejection of arbitrary setuid
content, identity mismatch and hard-link aliases.

Evidence: The original ARM64 BuildKit image's verified layers contain
one root-owned setuid entry at `usr/bin/fusermount3`. The optimized
disk importer staged the unchanged config and layers. Inside the
ordinary confined workload, `stat` returned mode 4755. The existing
no-suid mount and no-new-privileges rule still apply. The pinned
Buildx driver reached its requested cache volume after image pull.
See `SPEED-156/pinned-cache-and-gateway/` and
`SPEED-156/frozen-buildx-cache/`.

### SPEED-156

Title: Attach the BuildKit cache at its original named-volume target

Acceptance: Mount an explicitly owned volume at `/var/lib/buildkit`
in the pinned image. Verify it is writable, survives container
replacement as required, and is removed through the original
volume lifecycle. Keep the live worker bootstrap gate separate.

Evidence: Two isolated containers using the pinned image mounted
`/var/lib/buildkit`. The second read the first container's written
bytes. Both generations reported complete native cleanup and the
volume removal passed. See `SPEED-156/cache-gateway-cpu-info/`.

### SPEED-157

Title: Provision and own the frozen Buildx container and state volume

Acceptance: Admit the pinned Docker-container driver's original create
request and the bootstrap config copy. Bind its exact named cache
volume and verify the object and volume are removed on failure.
Ordinary privileged and nonempty configuration requests remain denied.

Evidence: The pinned Docker-container client created the worker and
its exact named cache, uploaded the original empty setup archive and
reached Start for Rust, Go and Node. Start returned the explicit
unavailable worker error. The original builder removal deleted each
container and its cache volume. See
`SPEED-157/frozen-buildx-automatic-cache/`. Worker execution is separate.

### SPEED-158

Title: Boot the pinned BuildKit daemon with Conjet's native executor selected

Acceptance: Bring up the real daemon in the worker's private sandbox,
report its native OCI worker through the original Buildx debug call,
and retain separate task-owned configuration, cache, cgroup and
network leases. Runtime RUN and cancellation remain their own gates.

Evidence: The original Buildx client bootstrapped the pinned v0.23.2
daemon for Rust, Go and Node. All three reported the private
`conjet-speedup` endpoint, `docker-container` driver, Linux ARM64,
native snapshotter and sandbox process mode. The launched argv
explicitly selected Conjet's native runtime binary. The guest exposed a
read-only proc and owned cgroup view. Native admission retained cgroup
authority instead of delegating it to BuildKit's entrypoint.
`SPEED-158/bootstrap-procfs-stat/` records the actual worker output,
removal of all three containers and caches, a released disk and clean
ext4 check. The first solve reached Dockerfile transfer and failed at
timestamp preservation. No build or benchmark passed in this run.

### SPEED-159

Title: Connect the pinned BuildKit executor to the native supervisor

Acceptance: Authenticate the executor as a member of the live worker
generation. Limit the channel to the native build runtime verbs.
Resolve only the requested bundle in that generation's owned cache
and mount namespace. Verify the detached snapshot identity before
admission. Fail stale, foreign and unmounted bundle requests.

Evidence: The original Buildx RUN for Go and Node started Conjet's
runtime helper in six separate builders and authenticated it through a
private, boot-keyed Unix channel. The supervisor verifies the peer's
mapped credentials, PID descriptor and live worker cgroup. It currently
returns the explicit bundle-attachment error before creating a RUN
workload. Rust encountered a separate 4 GiB scratch-volume exhaustion
while copying native snapshots. See `SPEED-159/authenticated-runtime-start/`.

### SPEED-165

Title: Attach a live pinned BuildKit root to native RUN admission

Acceptance: Verify and pin the current worker-owned OCI bundle and
rootfs through kernel descriptors. Apply the original credentials and
network semantics within the native sandbox. Account for compiler
processes in the owned build instead of attributing daemon-only
counters as the whole workload. Prove snapshot writes and teardown for
RUN, kill and delete, including a canceled worker.

Evidence: `SPEED-165/node-owned-volume/` verified the configured
cache's device, inode and mapped root ownership from the live worker.
It opened the bundle without following path symlinks, verified that
the rootfs is a distinct mount on the same leased disk and read its
bounded single-link OCI configuration. The original Node RUN reported
UID/GID 0, eight mounts and six namespaces. The rootless bundle omitted
a cgroup path. The native launch and teardown remain open.

`SPEED-165/node-leased-source/` confirmed that the worker's bind
resolves to the same leased snapshot inode from the supervisor's own
mount namespace. A detached executable view of that inode was created
with `nosuid,nodev`. The live root mount stays private and is never
remounted by this operation.

The pinned Node Docker-container builder completed both original Dockerfile
RUN steps, copied the resulting files into the next stage and exported a
61,172,224-byte Docker archive. The isolated Node run used digest-verified
offline base layouts. The original `docker image load` then returned HTTP 409
because the builder was still active. See
`SPEED-165/cj-compat.tMPK1e-node-final/` for the exact source
patch, release hashes, original client output and cleanup evidence.

The earlier `/etc/hosts` EINVAL stopped after descriptor-pinned detached mount
handoff. A worker probe reproduced export EPERM when a read-only bind remount
omitted the locked `noexec` flag and succeeded when it included that flag.
The pinned exporter uses a dedicated view of the leased BuildKit cache with
`nosuid,nodev`. Its live OCI preset comparison canonicalizes permutations
of the worker's bind flags. Guest shutdown, production fingerprints, socket
removal, the private disk lease and offline ext4 checks all passed.
[Pinned exporter remount](https://github.com/containerd/containerd/blob/v2.1.3/core/mount/mount_linux.go#L178-L231)
[Pinned BuildKit flag collection](https://github.com/moby/buildkit/blob/v0.23.2/util/rootless/mountopts/mountopts_linux.go#L16-L38)

Review: The real Node solve establishes RUN and snapshot writeback.
Aggregate accounting and active cancellation have separate SPEED-168
evidence. Public pulls remain a separate SPEED-162 gate.

### SPEED-168

Title: Account for BuildKit RUN and worker processes together

Acceptance: Keep compiler processes and the BuildKit daemon in the
same owned aggregate cgroup with distinct child lifecycles. Preserve
the original worker resource semantics, Core admission and memory
ownership. Verify worker cancellation drains and removes every owned
RUN before the cache lease is released.

Evidence: A pinned Buildx Node solve allocated 96 MiB inside RUN and
reported the marker after the allocation. Core observed one populated
109,809,664-byte RUN child inside the worker's aggregate cgroup. The
original worker observer read CPU, current and peak memory, and block I/O
from the aggregate. Docker refused active cache removal. Buildx exited 130
after SIGINT, the RUN disappeared from the active ledger and the original
Node solve exported a Docker tarball on that worker. The launcher verified
shutdown, production fingerprints and disk release. Offline ext4 checks
passed. See `SPEED-165/cj-compat.tMPK1e-aggregate-live-proof/`.

The replacement-builder run captured exit signal 9 and complete cleanup
for the exact RUN handle. It removed the first worker and cache, then a
distinct builder bootstrapped and exported the original Node tarball.
The Docker image load gate remains open. See
`SPEED-165/cj-compat.tMPK1e-aggregate-replacement/`.

### SPEED-161

Title: Preserve frozen Dockerfile and base-layer metadata in the worker

Acceptance: Complete the original Buildx preload through the pinned
worker. Preserve filesystem ownership, timestamps and content in the
owned cache. Retain the frozen base digests, and verify cache cleanup and
the original image transfer semantics.

Evidence: The pinned client booted nine workers and completed all nine
digest-verified OCI layout preloads, including native extraction of
Rust, Go and Node base layers. Worker-only timestamp, hardlink and
symlink handling and xattr reads preserve layer metadata. A bounded
256-descriptor and 512 MiB per-file worker budget allowed the pinned
layer processor and largest Rust compiler library. All nine workers
were removed. `SPEED-161/frozen-native-extraction/` retains the
successful preloads and failures in the subsequent RUN and cgroup
observer stages.

### SPEED-162

Title: Resolve the frozen public registry references from the BuildKit worker

Acceptance: Complete preload with the original Docker Hub references
and original Docker-container driver through the isolated worker.
Scope any registry transport to pinned image sources and retain
effective build network limits. Report the public path independently
from the existing digest-verified OCI layout diagnostic.

Evidence: After timestamp handling was fixed, each original Dockerfile
transferred and parsed, then public registry DNS timed out at
`198.18.1.1:53`. See `SPEED-161/worker-timestamps/`. The separate OCI
layout run used the original ARM64 image digests and reached actual
layer extraction. It cannot qualify the public route.

The public worker uses the private built-in bridge listener. The host
downloads the frozen Docker Hub pins over TLS and relays verified
manifest members through authenticated Core transport. Source identity,
object digest and transferred bytes are recorded. The Buildx Dockerfiles
retain their public references and network-none RUN policy. Initial Node
and Go build solves, exports, loads and execution canaries completed
through this route. See
`SPEED-165/cj-compat.tMPK1e-node-witness-retry/` and
`SPEED-165/cj-compat.tMPK1e-public-spawn/go/`.

### SPEED-160

Title: Qualify RUN, cancellation and cache through the original Buildx client

Acceptance: Prove the original Rust, Go and Node build solves execute
RUN in a native workload with verified cleanup and correct artifacts.
Preserve exit and cancellation behavior, cache reuse, and source and
dependency invalidation. Keep the frozen fixture limits and inputs.

The pinned Node client completed all 12 export, load and execution
canaries across three builders and four cache conditions with verified
offline base layouts. Archive load now accepts the active pinned worker.
Archive execution uses a separate authenticated guest connection and
can reclaim inactive cached guest roots on capacity pressure while
keeping verified host images and tags. The original three-root guest
limit stays enforced. The standalone common, Alpine and Node archive
regressions, including corrupt-layer rejection, passed. See
`SPEED-165/cj-compat.tMPK1e-offline-builds/node/` and
`SPEED-165/cj-compat.tMPK1e-archive-regression/`.

The public Node run recorded each worker generation, exact snapshot
identity, RUN exit, archive digest, loaded OCI config, and image teardown.
It verified zero new RUNs for the unchanged build, one RUN for the source
change and two for the dependency change in each repetition. A failing
RUN returned 23. Interrupting the live solve returned client status 130
and guest signal 9 with teardown of the observed RUN generation. See
`SPEED-165/cj-compat.tMPK1e-node-witness-retry/`.

The mixed-language timing run reached the 16-image host cap while
loading new exports. The last tag removal now retires a Buildx import
owned by the private worker session once no container or alias uses
it. The existing image-store limit stays in force. The Go and Node
archive loads that failed in timing passed with the new cleanup witness,
and the common, Alpine and Node archive regression passed. See
`SPEED-160/cj-compat.tMPK1e-mixed-archive-lifetime/` and
`SPEED-160/cj-compat.tMPK1e-archive-lifetime-regression/`.

The mixed regression then passed all 36 canaries and released the image
backing for every builder in one boot. Its worker image and bases came
from verified OCI layouts. The public Go rerun also passed all twelve
canaries after a volume removal acknowledgment outlasted the earlier
two-second channel deadline. The removal request now has a 15-second
budget and still waits for recursive deletion and directory fsync.
See `SPEED-160/cj-compat.tMPK1e-mixed-lifetime-seeded-worker/` and
`SPEED-160/cj-compat.tMPK1e-volume-ack/`.

The exact rerun on the previous artifacts lost control of the Node
builder after the source-change export. The archive load and subsequent
builder cleanup failed. Delaying the isolated VM for 2.45 seconds
reproduced the same sequence and captured a timed-out read-only worker
observation in Docker inspect. The adapter now reconnects that observation
to the same authenticated boot and workload handle, with one recovery
attempt per interruption. The guest resumed and all twelve Node export,
load and execution canaries passed after the same delay. Builder and disk
cleanup passed. See `SPEED-160/cj-full.lQbpSK-node-observation-fault/`
and `SPEED-160/cj-full.lQbpSK-node-observation-fixed/`.

### SPEED-163

Title: Read actual cgroup counters from the pinned BuildKit worker

Acceptance: Complete both unchanged Docker exec cgroup observer calls in
the build fixture and verify zero extra capabilities for the observer.
The host and guest must select the same worker-control policy.

Evidence: All 18 cgroup probes in the nine-builder preload run failed
at host validation because ordinary argv inherited the daemon-only
authority. The host and guest now use the same argv replacement logic.
`SPEED-163/build-worker-observations/` verified all 18 original
observer calls. They reported CPU and memory counters and marked
`io.stat` unavailable.
Those shell observers use the ordinary exec policy, which verifies an
empty capability set before process exec.

### SPEED-164

Title: Attribute BuildKit block I/O to the owned worker cgroup

Acceptance: Record the original observer's `io.stat` from the worker
cgroup hierarchy during the private disk-backed build, or document the
exact kernel capability that prevents collection. Keep VM-wide I/O out
of the worker measurements.

### SPEED-166

Title: Diagnose the Core backing replacement failure in macOS CI

Acceptance: Identify the actual error that precedes the injected
replacement failure and restore the hosted check with its original
rollback and page disposition assertions. Preserve the production
backing ownership guard.

Evidence: CI run `45409876930` on `ee163ae` failed
`failed_replacement_cancels_reusability_before_returning`. The first
assertion was reached with an unexpected error variant. The local ARM64
workspace passed the same check. The next CI attempt reports the
actual returned error without changing the assertion.

CI run `45429655803` and a local workspace run both reproduced the
region-wide assertion reporting one nonreusable page before the injected
failure. The test now brackets the exact four-page range with inaccessible
guard pages, keeping the original zero-count assertion and rollback check.
The local workspace and 100 focused repetitions passed. The production
backing guard and Core memory policy are unchanged.

### SPEED-167

Title: Bound the combined native build workspace for the frozen Rust base

Acceptance: Keep the ordinary volume and image-store disk limits.
Admit a larger canonical private disk only with both native build
workspace and disk image store enabled. Verify the Rust fixture reaches
RUN with its frozen inputs and compute limits, and release the disk.

Evidence: The 4 GiB disk exhausted space while copying the Rust
toolchain into native snapshots. `SPEED-165/live-root-16g/` reached
RUN in all three Rust builders and recorded the separate bundle
verification error. All nine workers were removed and offline ext4
validation passed. The disk lease still enforces owner, permissions,
canonical ExternalSSD path and exclusive locking.

### SPEED-091

Title: Qualify workload credentials and the frozen lifecycle

Acceptance: Preserve default and explicit image credentials under
mapped namespace IDs and enforce the original resources, capabilities,
network policy, seccomp and cleanup. Reject unmapped IDs and privilege
expansion. Exercise each workload, API/CLI boundary and network pair.

Evidence: SPEED-141 covers all seven pinned default identities, explicit
numeric and named selectors, exec inheritance, and rejection without
admission. The complete frozen lifecycle still requires qualification on
the final optimized artifacts.
[Credential evidence](native-compatibility.md#speed-091-mapped-oci-credentials)

The checkpoint run observed correct Rust UID, GID, cgroup limits and exit,
then lost its removal witness because the registry pull outlasted the
idle Docker API connection. The credential runner now opens a fresh
peer-verified connection after each pull. All seven original image
probes verified native teardown and the requested limits in
`SPEED-098/cj-compat.tMPK1e-credentials-fresh-peer/`.

### SPEED-092

Title: Qualify isolated Buildx worker provisioning

Acceptance: Use the pinned Docker-container driver unchanged. Verify
worker privilege policy, owned bootstrap and cache assets, exact
worker identity, API and cleanup. Ordinary workload privilege must
remain unavailable.

### SPEED-093

Title: Qualify native build execution and cache

Acceptance: Run the frozen Rust, Go and Node source/cache variants,
export/load/run the resulting images and verify native executor
ownership. Cover failure and cancellation and the Docker build API.

The standalone v0.23.2 BuildKit client independently solved a scratch
Dockerfile through the native worker at mapped UID/GID 65532. The RUN
verified the mount contract and emitted both output streams. Fresh and
cached exports produced the same proof, with zero RUNs on the cached solve.
An interrupted solve terminated the recorded native generation and
released worker and cache ownership. See
`SPEED-088/cj-compat.tMPK1e-direct-mount-policy/`.

### SPEED-094

Title: Qualify the frozen Node and Redis Compose fixture

Acceptance: Verify health, transaction readiness, DNS, published ports,
service change cases, persistent data and project teardown using the
original fixture.

### SPEED-095

Title: Qualify persistent container control and copy

Acceptance: Verify CLI/API exec, TTY, output extent, attach and
disconnect recovery, stop/kill/restart, and matched copy hashes for
both frozen payload sizes.

### SPEED-096

Title: Qualify frozen storage and service networking

Acceptance: Verify the original writable layer, named volume and
ExternalSSD bind datasets plus Node/Redis DNS, TCP, churn and persistent
data. Inventory all guest and host resources after teardown.

### SPEED-097

Title: Qualify frozen stress, OOM and recovery

Acceptance: Keep the unchanged concurrency 1/2/4/8 workloads,
effective limits, cancellation, guest OOM attribution, active-data
checks and fresh recovery.

Evidence: The original stress runner passed 400 measured fixture
launches and 40 warmups across concurrency 1, 2, 4 and 8 with the
mapped Alpine default. The Node prepull failed before the original
OOM and recovery fixture. Completion remains open.

A later public run passed the unchanged stress and OOM fixtures and
verified seven cancellations among eight simultaneously running
containers. The eighth retained its exact data through cancellation.
All nine workload generations including recovery had native teardown
witnesses. See `SPEED-098/cj-compat.tMPK1e-stress-cancel/`. The
release gate still requires the same evidence on its frozen artifacts.

### SPEED-098

Title: Gate the full comparison on release compatibility

Acceptance: Record all 71 frozen required cases against one exact
native release artifact set, including advertised-feature regressions
and Core dynamic memory. Verify production and disposable cleanup.
Only a complete PASS authorizes a new full SPEED-065 matrix.

Evidence: The native launcher can run the unchanged suite scripts as
isolated preflight canaries and record binary identities and cleanup.
The gate enumerates every case and fails missing or mismatched release
evidence. [Compatibility procedure](native-compatibility.md#speed-098-fail-closed-preflight)

The exact release gate returned 19 PASS and 52 FAIL. The original
Buildx bootstrap, Docker archives, default bridge, frozen Node/Redis
workloads, and broader control and OOM coverage remain open. Core
memory and supported regressions passed. A new full SPEED-065
comparison remains blocked. [Exact release results](native-compatibility.md#exact-release-gate-result)

The refreshed `a792b4c` baseline returned 53 PASS and 18 FAIL on one
recorded release artifact set. The first run returned 41 PASS and 30 FAIL
after a shared lifecycle VM reached its 600 s lifetime cutoff in the final
group. Each of the twelve independent group boots then verified all 2,000
samples, ten warmups and guest cleanup. The 71-row ledger, both summaries,
launcher reports and six binary hashes are under
`SPEED-098/cj-compat.tMPK1e-a792b4c/`.

Commit `21171de` passed all 71 frozen cases on six matching optimized
executables. All twelve lifecycle groups retained 2,000 samples and ten
warmups per group. Buildx public acquisition, Docker build API,
standalone BuildKit, and the non-build suites passed. The Compose and
storage public retries passed after the initial Docker Hub timeouts.
Core verified 448 MiB to 2,048 MiB growth and return to 448 MiB, with
independent guest pressure and matching active data. Launcher identities,
disk checks and production fingerprints passed. Evidence and the
complete ledger are in `SPEED-098/cj-compat.tMPK1e-release-21171def20e0/`.
[Hosted macOS CI](https://github.com/omega13-engr/conjet/actions/runs/45440020877)
passed for the same commit.

The current candidate `66a8a908e0ce39aa8fec831482fbd083b449334d`
passed **71 of 71** after the image lifetime and durable volume removal
fixes. The initial default-credentials lane recorded Docker Hub timeouts
for Redis and BuildKit. The same artifacts passed all seven original image
pins on a fresh public retry. Production checks, native guest teardown,
detached ext4 checks, and all six executable hashes passed. The ledger,
checksums, retained binaries and receipts are in
`SPEED-098/cj-compat.tMPK1e-release-66a8a908e0ce/`.
[Earlier qualification](native-compatibility.md#qualified-optimized-candidate)

The subsequent `16a05e0` BuildKit worker recovery candidate also
passed **71/71**. Its two Core memory lanes qualified growth to
2,048 MiB, active data integrity, and recovery to 448 MiB. The
qualified executable checksums, exact source mapping, witnesses and
detached ext4 checks are in
`SPEED-098/cj-full.lQbpSK-release-16a05e00d07d/`.
[Buildx recovery candidate](native-compatibility.md#buildx-recovery-candidate)


### SPEED-025

Title: Qualify concurrency, pressure, recovery and efficiency

Description: Run the cross-workload stress matrix and quantify whether speed gains persist under realistic contention.

Is blocked by task: SPEED-024.

Acceptance Criteria:

- Sweep declared concurrency levels for launches and representative builds/services; bound queues and report rejected, failed and timed-out work as well as successful latency.
- Exercise CPU and guest-memory pressure, prepared-slot exhaustion/refill and active-data preservation without inducing unsafe host-wide pressure or stopping production.
- Test request cancellation, client disconnect and task-owned runtime crash/restart with leak inventories and explicit recovery outcomes; use only disposable test state.
- Collect host plus attributed guest CPU/memory, idle footprint, disk growth and reclamation with measurement limitations. Run energy sampling separately only when authorized and available; otherwise mark it unavailable.
- Observe cleanup lag and steady-state resource growth independently from API acknowledgement. Unknown Kiri guest teardown remains unknown.

Problem and Evidence: The matrix implements a bounded Docker launch concurrency sweep and a distinct per-container OOM canary. It requires exit 137, an OOM flag, an unchanged active-data canary in a sibling container and a fresh recovery launch. A unit test injects a native backend disconnect after submission and proves the adapter refuses replay, unverifiable removal and new admission. Guest-wide reclamation, actual runtime process loss and restart, and prepared-slot tests remain separate requirements for this program.

Raw evidence: Fast sequential medians can hide queueing, memory reservation, deferred cleanup and recovery costs.

Approach:

1. Freeze safe resource ceilings and deterministic fault points.
2. Run bounded stress and recovery sessions with canaries and before/after inventories.
3. Analyze scaling, tails, failure rates, resource reclamation and optional energy without discarding adverse sessions.

Evidence: `SPEED-025/pair-1` on `187e1ab` completed all 400 measured launches per engine with zero launch failures. Both observed active data after the pressure attempt and passed isolated recovery and production-preservation checks. `native-product-full-1` on `4da6d3b` passed the injected native pressure/recovery, bounded output, overload, cancellation, active shutdown and stale prior-boot handle canaries. Both native session directories were removed. It recorded 2,000 measured samples per fresh and prepared CLI/API lane. Docker pressure attribution and the remaining independent pairs are open. The [interim results](docker-benchmark-results.md#concurrency-and-recovery) retain both failures and successful rows.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat remaining concurrency pairs and keep the Kiri pressure boundary unresolved. `SPEED-025/pair-2` demonstrated Conjet exit 137 and `OOMKilled=true` with verified 64 MiB memory and disabled swap. The sibling and recovery canaries passed. Kiri reported `MemorySwap=0` instead of the requested 64 MiB, so the guard stopped its pressure workload before allocation. Both engines ran the bounded launch sweep. Preserve pair 1's timeout and OOM attribution failure.
`kiri-effective-swap.log` later observed the requested 64 MiB memory
ceiling and zero swap directly in Kiri's guest despite the inspect
metadata discrepancy. The pressure test still enforces those effective
limits before allocating. `SPEED-025/pair-3` verified both effective limits
for both engines. Conjet attributed exit 137 to OOM and recovered. Kiri's
wait timed out and its OOM flag stayed false despite the matched effective
limits. Both passed survivor, recovery and owner cleanup. Further Kiri
qualification needs a verified termination or OOM witness for this load.

The release-build native static run at `cabbea9` passed 8,000 timings
and the active-data, one-use, expiry, pressure, output, backpressure,
disconnect and shutdown canaries. Both VM directories were removed and
production observations matched. Fresh and prepared API p99 were 4.100
and 3.201 ms, with 3.394 ms refill p99. See raw samples and summary under
`SPEED-025/native-product-release-cabbea9`. The Docker stress matrix
coverage remains open.


### SPEED-024

Title: Benchmark filesystem, networking and sustained workloads

Description: Measure storage and network performance plus realistic long-running service throughput.

Is blocked by task: SPEED-023.

Acceptance Criteria:

- Test named volumes, supported host bind mounts and container writable layers separately: metadata/small files, sequential/random I/O, and fsync durability. Keep datasets and backing files on ExternalSSD.
- Measure container-to-container DNS/TCP, published host ports, connection churn, request latency and throughput with identical topology/payload; record unsupported native networking.
- Validate checksums, acknowledged durable writes and application responses. Use task-owned services and ports; record filesystem/cache settings and client placement.
- Run at least one sustained application workload with latency under load and active-data canaries. Capture CPU, memory and disk growth with a declared steady-state interval.
- Keep raw transport throughput, application readiness and launch latency as separate metrics.

Problem and Evidence: The matrix implements writable-layer, volume and bind integrity workloads and a sustained Node/Redis service. It times guest DNS, Redis TCP handshake and Redis round-trip separately from the host HTTP transaction window. The storage check exercises sequential and random writes with fsync and verifies the resulting named-volume checksum in a different container. It captures effective service cgroup limits and an owned-service resource snapshot. Paired runtime timing and bulk transport coverage remain open.

Raw evidence: Bridge creation timings do not measure packet performance, and static no-network execution does not establish Docker workload compatibility.

Approach:

1. Reuse existing filesystem/network benchmark utilities with the pinned datasets.
2. Run storage and networking cases independently, then the application load fixture.
3. Verify data integrity and publish topology, throughput, latency and resource observations.

Evidence: `SPEED-024/pair-1` on harness `187e1ab` passed named volume, writable layer, guest transport and sustained transaction checks on both engines. Conjet refused the ExternalSSD host bind before work in all six attempts. Kiri passed it. Both reported matching service cgroup limits and clean session teardown; Conjet completed 2,648 and Kiri 4,776 verified transactions in their respective 60 s windows.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat supported workloads at the remaining pair indices and add standalone bulk transport evidence. Keep the failed Conjet host-bind samples.

### SPEED-023

Title: Benchmark exec, streams and control-plane operations

Description: Measure Docker exec, attach/logs, inspect/list/events and file copy for supported workloads.

Is blocked by task: SPEED-022.

Acceptance Criteria:

- Separate persistent-container docker exec from fresh docker run; measure API and CLI overhead where supported.
- Validate stdout/stderr separation, bounded large output, exit codes, stdin/TTY behavior where supported, and cancellation without deadlocks.
- Measure inspect/list latency with fixed owned-container counts and event delivery/order under churn; do not query or manipulate production containers.
- Measure docker cp in/out with checksummed small-file and large-file sets. Record unsupported native or Kiri behavior without substituting another operation.

Problem and Evidence: The matrix implements persistent CLI exec streams and exit code, bounded output, inspect/list and checksummed file copies. The control fixture adds stdin-driven attach, logs, ordered Docker lifecycle events, TTY and idle attach disconnect recovery. Direct API exec creation, stream demultiplexing, exit inspection and container inspection have executable canaries. Paired runtime evidence remains open.

Raw evidence: Interactive development and tooling depend on control-plane and stream behavior beyond launch latency.

Approach:

1. Add long-lived fixture containers and deterministic stream/file workloads.
2. Run operation-specific latency and throughput cases with correctness assertions.
3. Inspect backpressure, cancellation and cleanup evidence before publishing results.

Evidence: The canceled Conjet half of `SPEED-023/pair-1` retains 274 attempted operations. It confirmed working persistent API and CLI exec, attach, TTY, disconnect/recovery and controlled file copies in the observed repetitions. All 17 observed historical event queries produced empty streams and failed the lifecycle canary. Candidate shutdown removed the private root and production matched its starting snapshot. The bounded stream observer now waits for a complete ordered witness and closes its own client. The corrected `SPEED-023/pair-2` on `7be17a3` completed 100 measured operations per row on each engine, with no operation failures and exact production snapshots. It validated every event lifecycle, both persistent exec boundaries, attach and copy. Four independent pairs remain.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat the corrected control workload at the remaining pair indices.

### SPEED-021

Title: Benchmark Docker build and BuildKit

Description: Measure real docker build/buildx build workflows and verify resulting images.

Is blocked by task: SPEED-020.

Acceptance Criteria:

- Pin Dockerfiles, source trees, build arguments, BuildKit versions/driver where controllable, CPU/RAM and package dependencies. Record engine-managed differences.
- Measure empty builder cache with base preloaded, unchanged rebuild, source-only change, dependency change and multi-stage build. Separate image pull, build execution and image export/load.
- Use representative small Rust, Go and Node projects with correctness checks and consistent dependency availability. Verify produced binaries or service responses.
- Report build wall time, cache hits, CPU, memory peak, disk I/O and resulting image size. Record whether BuildKit uses the native runtime, Docker/containerd, or another backend.
- No native build speed claim is allowed merely because a native launch microbenchmark is fast; unsupported Kiri build configurations remain explicit.

Problem and Evidence: The first Conjet half of `SPEED-021/pair-1` completed all Rust and Go build/export, load and execution canaries. Node failed its first exported image canary in all three repetitions with `MODULE_NOT_FOUND`. npm linked the local package outside the exported dependency directory. The fixture now uses `--install-links` to install the package contents, and build/load rows explicitly fail when the exported image fails its canary. Kiri bootstrapped BuildKit but its worker timed out on Docker Hub HTTPS for all three base preloads. Stage the verified registry manifests and blobs once on ExternalSSD and provide the same offline OCI named contexts to both workers. Preserve pair 1 and rerun the corrected workload with both engines.

Raw evidence: Build performance depends on BuildKit, filesystem behavior and caching; the new native launch service is not itself a build engine.

Approach:

1. Reuse the polyglot fixtures and define private builders with explicit endpoints.
2. Execute the cache matrix serially and validate each output image.
3. Publish per-project and per-cache-state comparisons with builder provenance.

Evidence: `SPEED-021/pair-2` records harness `1253da3`. Both existing engines completed all 36 pinned Buildx build/export and load rows and 36 artifact canaries each. Pair 3 on `b3f0ffc` repeated those results and verified removal of 36 per-case image tags and nine private builders per engine. Raw reports, builder endpoint/driver/version and cleanup witnesses are retained with failed `pair-1`. Compatible independent pairs and the new worker resource observations remain open.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat the verified offline Buildx workload at the remaining pair indices with effective builder resource attribution. Distinct temporary tags identify every case's exported image. The harness now samples cgroup CPU time, current and cumulative peak memory, and block I/O from the verified worker before and after application work, outside the timing window.
`SPEED-021/pair-4` on `25ce7d7` verified all 72 timed operations per engine,
with both BuildKit cgroup views reporting CPU, peak/current memory and
I/O. `builder-counters.json` retains the raw-derived deltas. The report
keeps intervals open until the compatible independent pairs are present.

### SPEED-022

Title: Benchmark Docker Compose application workflows

Description: Measure a real multi-service Compose application from up through readiness and down.

Is blocked by task: SPEED-021.

Acceptance Criteria:

- Pin the same Compose plugin/file/images and use unique project names, isolated networks, volumes and host ports for each engine.
- Measure pre-pulled up --wait, no-change up, one-service recreate, scale, restart and down; separate build/pull cost from startup. Record unsupported commands.
- Use an app plus database/cache fixture with health checks and a functional transaction; readiness requires working dependencies, not only running containers.
- Validate logs, service DNS, published ports and expected data persistence across restart; separately measure down --volumes using only owned volumes.
- Report critical-path readiness, per-service latency, resources and verified cleanup. Attribute mixed native/legacy execution per service.

Problem and Evidence: The full fixture uses pinned Node and Redis, real dependency readiness, transactions, scaling, published loopback ports and project cleanup. End-to-end timings are pending.

Raw evidence: Compose includes orchestration, network dependencies and storage behavior absent from the single-container native fixture.

Approach:

1. Create the deterministic application fixture and readiness/data canaries.
2. Run the workflow matrix in alternating engine sessions.
3. Verify application correctness and project-scoped cleanup after every cycle.

Evidence: `SPEED-022/pair-1` contains raw reports from harness `4a6de79`. Both existing engines passed five measured repetitions of each Compose operation and all functional and cleanup canaries. Pair 2 on `b31afde` repeated those results and verified effective memory, PIDs and CPU limits on both engines outside the startup timing window. Pair 1 predates that check and is descriptive. The [interim report](docker-benchmark-results.md#compose-first-pair) records the timings.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Repeat the workload with effective cgroup verification in the other four pair slots.

### SPEED-026

Title: Publish the Docker and native comparison verdict

Description: Create docs/engineering/docker-benchmark-results.md with reproducible results and a reviewed claim for each workload.

Is blocked by task: SPEED-025.

Acceptance Criteria:

- Publish exact revisions, hashes, commands, effective resources, cache states, timing boundaries, raw evidence links and per-session results for every planned row.
- Report Kiri versus Conjet Docker API, Docker CLI/build/Compose, and native API as separate comparisons. Distinguish accelerated, legacy, mixed and unsupported paths.
- Compute predeclared confidence intervals from independent sessions; avoid treating repeated operations as independent hardware/session evidence. Report failures and missing coverage alongside speed.
- Use per-workload pass/fail/inconclusive/unsupported verdicts. Task completion means valid measurements and an honest report, not a mandatory Conjet win.
- Scope claims to observed M1 Pro conditions; retain deferred cross-host, energy and guest-teardown requirements. Do not use this report to silently expand the earlier release scope or declare all Docker operations accelerated.
- Review findings, create concrete follow-up tasks for regressions/gaps, verify production and cleanup, and commit/push the report without automatically merging or publishing a release.

Problem and Evidence: [Interim outcome and coverage audit](docker-benchmark-results.md).
The report separates the first complete lifecycle pair, existing-engine
pilots and native OCI/static timing. The summary tool verifies per-session
counts and refuses a lifecycle paired interval before five complete pairs
or across mixed executable, harness or manifest revisions. It retains setup,
warmup and artifact-verification failures alongside measured rows.
Controlled-registry intervals additionally require complete witnessed config
and layer transfer for every first-pull sample in each accepted pair.
The report generator derives archived bytes per second from the exact saved
artifact size and exposes guest I/O stages independently of Docker CLI time.
The remaining modes and claim review are still in progress.
The local full check retained the default SwiftPM Metal failure and passed
all 440 Swift tests on the documented native build system with two skips.
ARM64 musl strict Clippy exposed two redundant kernel filesystem casts.
The portable comparison passes Clippy and produced the same SHA-256 as
the measured release guest supervisor. Rust workspace tests and formatting
also passed. Logs and the rebuilt hash are in `SPEED-026/final-local`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Keep the published coverage and claim audit current. Complete the
remaining broad-program scenario repetitions only when that scope resumes.
The revised native-first lane has a reviewed local measurement row in
`SPEED-019/native-kiri-release-cabbea9`; independent PR review remains open.

### SPEED-019

Title: Benchmark Docker run and container lifecycle

Description: Measure fresh Docker API and docker run end-to-end against Kiri, retaining native API measurements as a distinct comparison.

Is blocked by task: None for the declared subset. SPEED-018 validated the isolated native route.

Acceptance Criteria:

- Measure create/start/wait/removal through HTTP and docker run --rm through the same pinned CLI separately. Validate nonzero exits and output; include true and a small observable application.
- Cover warm-image no-network and supported bridge cases; separate first-use/image acquisition from cached runs. Keep VM cold boot outside warm lifecycle timing.
- Report p50/p95/p99, raw failures, wall time, throughput and per-session distributions. Record API removal and verified guest cleanup separately; do not infer one from the other.
- Compare native fresh/prepared only where workload semantics match; include preparation/refill, missed claims and actual dispatch backend. Do not label a native RPC measurement docker run.
- Exercise create/start of pre-created containers, stop/kill/restart and remove; mark unsupported lifecycle operations explicitly.

Problem and Evidence: The orchestrator exposes the frozen lifecycle counts and allows
one complete network/workload/adapter group per paired session. The
launchers keep API removal acknowledgement separate from cleanup. The
pilot measured 121.6 s for 240 Conjet operations. At that rate the
full frozen 12-group, five-session Conjet matrix alone requires about
17 hours of measured windows. Start with an independently booted,
complete group and keep partial coverage explicit. Pair 2 collected all
2,000 no-network Alpine API samples per existing Docker engine without
failures. Median/p95/p99 were 594.953/819.515/871.010 ms on Conjet and
3.944/4.742/6.988 ms on Kiri. Timing ends at API removal acknowledgement.
Only one of five pairs is complete for this row; source revision and raw
data are in `SPEED-019/alpine-true-none-api-pair-2`.
`SPEED-019/native-oci-full-1` used `4da6d3b` and recorded 2,000 CLI and
2,000 API samples with no failures. Every operation had a distinct native
workload ID and verified guest cleanup. The API p50/p95/p99 was
28.381/33.940/34.537 ms and CLI p50/p95/p99 was 47.900/54.525/59.707 ms.
The opt-in environment rejected excess admission and preserved production.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Pending; verify workload equivalence, backend attribution, correctness,
measurement boundaries, statistical scope, and production preservation.

Next Action: Preserve the final native-first row and the historical baseline.
Legacy repetitions stopped on the user's direction at pair 3, leaving its
partial report and verified cleanup.
The earlier source adapter runner verifies one-use guest
cleanup on every operation and uses UID/GID 65532. The baseline uses the
image-default user, so their measurements remain distinct.
The full-sample runner handles cancellation through its Docker adapter and
VM ownership cleanup and retains partial rows.
The no-network Alpine `true` CLI series at `eb31229` completed pair 1 with
2,000 samples per engine and no failures. It retained a canceled next boot
with verified cleanup to allow local validation of the hosted CI fix without
overlapping compilation and timing.
Repetition resumed at pair 2 on that same harness under the series'
`remaining` directory. Pair 3 was canceled. Pairs 4 and 5 are outstanding.
The canceled preliminary boot is preserved outside the counted pair set.
Pair 2 retained two exit-127 errors on the existing Conjet path
and zero on Kiri. Both Conjet errors reported Go thread creation failure
under the declared four-PID cap and cleaned up successfully. Investigate
the guest runc startup path using a separate diagnostic and keep the
predeclared limits and failure records in the benchmark.

The serial release pilot from source `98d4148` is retained in
`SPEED-019/{native-default-pilot-3,kiri-native-default-pilot-3}`. Both
engines completed 100 API and 100 CLI samples under matched UID/GID and
limits with zero failures. Native p50/p95/p99 were 34.201/39.674/43.706 ms
(API) and 47.845/52.008/52.984 ms (CLI). Kiri recorded
4.116/4.776/5.204 ms (API) and 21.341/22.796/23.813 ms (CLI).
The native API's median observed adapter sleep was 27.393 ms.
Kiri guest cleanup is unknown.

The adapter now waits for the terminal guest revision in cancellable
100 ms slices. The release pilot in `SPEED-019/native-default-wait-pilot`
completed 100 samples per lane with zero failures. It recorded one Wait
request per operation. Native p50/p95/p99 were 3.185/3.727/4.363 ms
(API) and 22.792/24.618/27.912 ms (CLI). A dedicated timeout test
verified cancellation without resubmitting Launch. The real OCI suite
in `SPEED-018/native-default-wait-live` and the Kiri-first serial
orchestrator pilot in `SPEED-019/native-default-orchestrated-pilot` passed.
The 25 ms host tick remains enabled.

The final five alternating, independent pairs used measurement revision
`cabbea9` and matching release binaries. All 40,000 measurements and 200
warmups passed. The native API p50 ratio to Kiri was 0.841 (95% interval
0.818–0.855); p99 was inconclusive at the practical threshold. Native
CLI p50/p99 ratios were 1.076 and 1.099 and slower at that threshold.
The native witness verified each workload and its cleanup. Production
and owned session cleanup checks passed for all ten boots. See the
[release-build lifecycle results](docker-benchmark-results.md#release-build-native-docker-lifecycle)
and `SPEED-019/native-kiri-release-cabbea9/summary.json`. The matched warm
no-network `true` row is complete. Broader lifecycle coverage remains open.


### SPEED-008

Title: Run the fresh-runtime comparison and record the gate decision

Description: Create docs/engineering/fresh-runtime-gate.md linking the baseline and candidate reports and a proceed/revise/stop verdict.

Is blocked by task: SPEED-007.

Acceptance Criteria:

- Measure equivalent no-network and bridge lifecycle scenarios, including cleanup.
- Report latency distributions, sustainable churn, CPU, memory, failures, and uncertainty.
- Attribute observed bottlenecks with traces; do not infer that all savings belong to Jetstream.
- Record a proceed/revise/stop decision and preserve any regression evidence.

Problem and Evidence: The architecture plausibly removes launch overhead, but
neither its performance nor superiority has been measured.

Approach:

1. Run the SPEED-002 scenarios against original Conjet, the candidate, and pinned Kiri with matching cache and network modes.
2. Compare API-visible and cleanup-complete latency, throughput, CPU, memory, and failures; profile the dominant stages.
3. Record which gains are demonstrated, any regressions, and whether prepared-launch work is justified; block it on a revise/stop verdict.

Evidence: The signed native VSOCK diagnostic with 25 ms host ticks
showed a 17.062 ms idle ping p50 and 27.426 ms p99. Without ticks eight
pings returned before the session stopped. The Darwin native socket
watcher now waits on kqueue and wakes the VMM on accept or incoming data.
With the same tick setting, idle ping p50/p99 became 1.610/7.361 ms.
The tick-disabled variant completed 200 pings in both trials, but the
first stalled on a bridge lifecycle. Preserve that failure and keep the
tick-enabled fixture for comparative work. Raw RPCs, commands, hashes,
and matching production snapshots are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/transport`.

The workspace passed 156 Rust tests with three existing opt-in tests
ignored. The focused VSOCK suite passed 29 tests. The branch-built
candidate's separate Docker smoke passed. The [fresh runtime gate](fresh-runtime-gate.md)
records the comparison method and the limited diagnostic results.
The matched image probe used a single pinned static ARM64 executable
and the same requested workload resource limits on original Conjet at
`bbe8019`, the official Kiri 0.2.2 app, and the native candidate. All 240
measurements passed their adapter checks. Native no-network API p50 was
2.156 ms and p99 was 6.997 ms, versus Kiri's 4.074 and 5.025 ms. Native
bridge API p50 was 76.018 ms versus Kiri's 37.155 ms. Native terminal
responses require verified cleanup. The Docker API observations stop at
removal acknowledgement and do not establish equivalent cleanup. This
M1 Pro run remained under production background load and yields no
competitive qualification decision. The reports, hashes, host snapshots,
and launcher verification are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/common-image`.
The Kiri smoke and mid-benchmark cancellation checks verified the official
peer, matching production observations, removed socket, and no residual
VM disk holder. Python compilation, 17 focused Rust tests and strict
macOS and ARM64 Linux Clippy passed.

Six further isolated native boots measured optional guest-local phase
timestamps. Two traced default-kernel runs attributed about 19 ms median
to bridge preparation before child authorization and 40–41 ms median to
verified network teardown after exit. The on/off trials overlapped and do
not resolve trace overhead. Expedited RCU increased bridge latency and
remains a diagnostic flag. All 1,200 measured operations passed fixture
checks. Evidence and passing production comparisons are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/phase-analysis`.

Grouped synchronous removal halved the measured bridge teardown median
from roughly 40 ms to 19 ms. Bridge API p50 fell from 64–68 ms to
42–44 ms. The complete kernel bridge and previous recovery matrices,
800 follow-up measurements, focused Rust tests, and strict ARM64 Clippy
passed. Retained evidence is in `SPEED-008/grouped-teardown`.

Direct peer registration reduced measured bridge preparation from about
19 ms to under 0.4 ms. Two boots measured native bridge API p50 about
20.2 ms and p99 about 44 ms. All 800 operations and the bridge, private
scope, teardown, fault and cancellation regressions passed. The runner
records the timed measurement window in addition to individual operations
and tracks the native VMM and owned networking helper. Reports are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/direct-peer`.

The serial common-image run on `64fe823` captured 4,000 native operations
with verified cleanup, 4,000 Kiri Docker API operations, and 200 original
Conjet Docker API operations. All completed at their adapter's boundary.
The native bridge recorded 20.196 ms p50 and 32.315 ms p99 across 42.352
seconds, while Kiri's API acknowledgement was 33.608 ms p50 and 63.461 ms
p99. Kiri's read-only guest visibility probe saw its own container as
PID 1 and could not verify guest cleanup. Raw timings, launcher
observations, physical footprint, CPU and balloon evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/api-churn`.
The reviewed gate decision is **revise**. Qualification is still pending.

Source: [Delivery gates](speed-engineering-plan.md#incremental-delivery-and-decision-gates),
[verification policy](speed-engineering-plan.md#verification-and-claim-policy).

Review: Reviewed the kqueue callback and queue ownership, guest phase
attribution, grouped link teardown, and direct peer registration. The
revised native path passed the scoped correctness and recovery matrix.
The gate remains unmet because the Docker competitor cleanup endpoint,
second physical host configuration, equivalent network scope, energy,
and full qualification matrix are unverified.

Next Action: Deferred for comparative research. Obtain a second ARM64 host,
a way to observe official Kiri guest teardown, and authorized energy sampling,
then rerun the original matrix. Experimental release proceeds under local
acceptance without changing the SPEED-008 verdict.

## UNDERREVIEW

### SPEED-063

Title: Prove one BuildKit RUN through the native executor

Description: Establish the supported BuildKit OCI-worker execution boundary and run one pinned Dockerfile with one RUN instruction.

Dependencies: SPEED-071, SPEED-079 and the SPEED-070/078 snapshot
ownership work passed in isolation.

Acceptance Criteria:

- Document the exact BuildKit runtime interface from primary source before implementation; split missing runtime verbs into narrow tasks. Prove native execution identity, output/exit, build cancellation and cache-hit behavior. No hidden retained-runtime fallback; unsupported operations fail explicitly.

Problem and Evidence: The candidate cannot claim native builds by falling back to runc/containerd.

Approach: Keep BuildKit as build frontend/cache owner; implement the minimum compatible Conjet executor contract with tests, not a new Dockerfile engine.

Evidence: The pinned worker completed an uncached RUN, exported its
native write, reused that result without launching again, and cancelled
a second RUN through signal 9 and verified deletion. Two isolated release
boots passed. See [the executor evidence](native-buildkit-executor.md#speed-087-and-speed-071079-native-run).

Source: [Native engine plan](native-engine-v2-plan.md) and current native host/guest sources.

Review: Isolated validation and diff review passed. Independent review pending.

Next Action: Qualify the public Docker builder path under SPEED-089.

### SPEED-071

Title: Implement the minimum pinned BuildKit runtime lifecycle

Evidence: Two workers invoked the native run/delete path and the
kill/delete cancellation path. The release guest reported confirmed
exec, exit 0 for the fresh build, and signal 9 with complete cleanup for
cancellation. See [the executor evidence](native-buildkit-executor.md#speed-087-and-speed-071079-native-run).

Review: Isolated validation passed. Independent review pending.

Acceptance Criteria:

- Route the first standalone RUN, kill and delete to the same guest
  generation and return stdout, stderr and status without a retained
  runtime. Check stale IDs and cancellation. Qualify additional exec
  verbs separately before advertising them.

### SPEED-079

Title: Qualify BuildKit's generated OCI process and mount policy

Acceptance Criteria:

- Admit the pinned worker bundle and enforce the declared process and
  mount policy within the existing workload isolation and Core memory
  gates. Verify the supported mounts, ownership, and cleanup. Reject
  unsupported requests explicitly and keep cache, RUN, and lifecycle
  results scoped to observed behavior.

Evidence: The fresh and interrupted builds observed the mapped UID/GID,
primary supplementary GID, empty capabilities, no-new-privileges,
seccomp, private proc, read-only sysfs, and local cgroup mounts.
SPEED-086 passed incompatible bundle rejection, and SPEED-087 passed
the actual mount enforcement. Independent review pending.

### SPEED-087

Title: Apply the pinned mount policy inside the native build sandbox

Evidence: The release Core kernel supported all pseudo-filesystems in the
nested workload probe. Direct sysfs creation under mapped credentials
returned EPERM. A detached read-only sysfs mount created in the child's
network namespace under the single-threaded helper's trusted credentials
attached successfully in the same workload. Both probes preserved the
borrowed disk, data, Core and shutdown boundaries.

Acceptance Criteria:

- Apply only the verified ordered mount recipe to the exact snapshot.
  Keep source and destination resolution beneath owned directories and
  reject symlink and policy changes. Verify the read-only sysfs and
  namespace-local cgroup, process restrictions, and cleanup.

### SPEED-056

Title: Attribute and reduce retained Docker guest start latency

Description: Measure the start request inside a disposable retained Core
guest, then test one change at an observed bottleneck.

Is blocked by task: None for attribution or isolated A/B. SPEED-051 still
gates formal lifecycle qualification.

Acceptance Criteria:

- Join the pinned API starts to containerd, shim, runc, guest scheduling
  and HTTP response witnesses by workload identity. Compare with an
  untraced control. Keep guest and host clock domains separate.
- Measure cgroup accounting and effective CPU, memory and PID limits.
  Identify the expensive stage before selecting a candidate.
- Evaluate a confirmed candidate in alternating independent release A/B
  boots. Preserve the retained engine stack, provisioning and teardown,
  cgroup isolation, dynamic memory, and the recovery tick. Record a
  negative result if the change fails latency or memory acceptance.
- Preserve raw failure witnesses for SPEED-051 and verify private cleanup.
  The archived reclaim variant stays rejected.

Problem and Evidence: SPEED-050 measured 74–77 ms from delivery to dockerd
to the first start response byte. A separate SPEED-051 syscall trace
observed runtime setup in the same path but perturbed its timings.

Approach: Correlate a bounded scoped syscall trace with guest-local
API start requests, containerd task events and cgroup counters. Compare
observer-on and observer-off intervals before testing candidate behavior.

Evidence: [SPEED-056 stage trace](docker-benchmark-results.md#speed-056-retained-guest-start-attribution).
Two observer-order controls located the largest traced interval in
runc create. Guest-local start was 83–88 ms without ptrace. The
systemd scope and controller setup were present in all joined starts.
Two release A/B pairs tested a shorter systemd slice hierarchy.
The variant moved lifecycle p50 by +2.5% and −3.1%. All 920 launches
and the scoped telemetry, data and idle checks passed.

Review: Reject the layout change for lack of repeatable improvement.
Traced timings include substantial observer overhead. The stock guest
did not expose per-process scheduler delay metrics. No speed change
is accepted or qualified.


### SPEED-054

Title: Evaluate persistent ordinary Docker HTTP relay connections

Description: Measure connection churn, then conditionally support sequential HTTP requests on one downstream/upstream connection.

Is blocked by task: SPEED-052 and SPEED-053 decisions; SPEED-050 local/forwarded comparison.

Acceptance Criteria:

- Measure fresh and reused connections separately with guest-local and forwarded controls. If churn is immaterial, record rejection without modifying the relay.
- For an accepted implementation, parse and apply existing create/build cgroup policy on every request. Preserve framing, close semantics and bounded buffering; never multiplex clients onto one upstream connection.
- Pass multiple-request, chunked/trailer, HEAD/no-body, informational response, malformed input, disconnect, attach/upgrade and build-stream tests. Ensure events/idle keep-alive do not pin peak memory.
- Use the unchanged frozen lifecycle harness for two alternating 200-launch release A/B pairs with ten warmups per leg; report reusable-client diagnostics separately. Preserve pressure and idle-memory gates.

Problem and Evidence: handle_docker_proxy creates a dockerd connection per accepted stream and ordinary-response handling forces Connection: close. Removing headers alone would break its one-transaction state model.

Approach: Implement sequential framed ordinary transactions only after measured benefit. Keep streaming/upgraded connections dedicated and update transport phase accounting independently of container lifetime.

Evidence: [Fresh and reuse-intent ping controls](docker-benchmark-results.md#speed-054-http-connection-churn).
Guest-local reuse eliminated timed dials and reduced the untraced
ping medians by roughly 0.03–0.04 ms. The forwarded path reconnected
with both client settings. It has no persistent trial. The observed
connection cost did not justify implementing ordinary HTTP persistence.

Source: `guest/image/conjet-core/src/conjet-netd.c` and the SPEED-050 ping records.

Review: Declined an implementation after the controls. The
frozen qualification client remains the same.

Next Action: Review the bounded decision.

### SPEED-053

Title: Resolve a measured response write-readiness stall

Description: Test conditional writable notification for queued VSOCK response bytes after WouldBlock.

Is blocked by task: SPEED-050 response spans; SPEED-052 accepted or rejected decision.

Acceptance Criteria:

- First show whether final response writes stall after WouldBlock. If absent, document the negative result and make no watcher change.
- If present, arm write readiness only while bytes remain; wake the existing queue owner, disarm after drain and remove stale registrations before descriptor reuse.
- Pass slow-reader, partial-write, EOF/half-close, credit-exhaustion, cancellation and descriptor-reuse tests; retain the 25 ms fallback tick.
- Run two alternating 200-launch release A/B pairs with ten warmups per leg, zero failures, cleanup and unchanged dynamic-memory behavior. Record reject/accept without a parity claim.

Problem and Evidence: NativeEventQueue::watch registers EVFILT_READ; flush_host_output stops on WouldBlock. The frequency and cost in SPEED-049 are unknown.

Approach: Add a bounded writable subscription only if traces establish the stall; preserve single-owner byte movement and existing shutdown framing.

Evidence: [Tagged response write investigation](docker-benchmark-results.md#speed-053-response-write-readiness).
Two traced boots observed all 96 timed tagged lifecycle writes and
48 timed ping writes. Neither boot recorded a client WouldBlock.

Source: `jetstream/src/devices/vsock.rs` and the SPEED-050 tag logs.

Review: Negative finding for these short responses. A writable
watcher was not warranted.

Next Action: Review the bounded negative finding.

### SPEED-052

Title: Test quiet-dwell scheduling for routine stream-triggered reclaim

Description: Implement an isolated A/B candidate that coalesces stream-completion reclaim hints until the existing quiet dwell and guest safety checks.

Is blocked by task: SPEED-050 attribution; SPEED-051 before qualification.

Acceptance Criteria:

- Record current versus candidate reclaim counts and launch timings in two alternating release A/B boot pairs, 200 timed launches and ten warmups per leg.
- Preserve pressure reclaim, balloon growth/shrink, ownership checks and active-data canaries. Demonstrate pressure response during churn and idle convergence within the existing configured deadline.
- Add deterministic tests for generation invalidation, repeated stream completions, pressure bypass, idle submission and cancellation races. No new persistent worker or fixed-RAM mode.
- Accept only with measured improvement and passing dynamic-memory gates; otherwise record rejection and retain current scheduling.

Problem and Evidence: The boot loop requests routine reclaim for completed stream phases and workloads. Source proves scheduling coupling, not that reclaim causes SPEED-049 latency.

Approach: Change only routine hint scheduling in CoreMemoryController/schedule_guest_memory_reclaim; retain one pending hint, existing pressure policy and current quiet dwell. Measure observer-free performance separately from diagnostics.

Evidence: [Two alternating release A/B pairs](docker-benchmark-results.md#speed-052-routine-reclaim-ab).
The variant reduced 26 routine submissions to zero in each timed
window. It failed to improve latency or throughput consistently.
All four runs passed live-data and backing checks and converged to
512 MiB. The allocation held a 512 MiB buffer at full VM capacity.
Independent pressure-driven growth was outside this check.

Source: Temporary patch and raw artifacts in `conjet-speedup-evidence/SPEED-052`.

Review: Rejected after measurement. The production scheduling code
remains at the retained baseline.

Next Action: Review the rejected decision and retain the A/B artifacts.

### SPEED-050

Title: Isolate the retained Docker start and wait scheduling delay

Description: Attribute the remaining start and wait latency on the
pinned no-network Alpine API fixture with event wake enabled.

Is blocked by task: None. Uses the completed API evidence in SPEED-049.

Acceptance Criteria:

- Measure the same 12 timed operations and four warmups in two
  untraced and two bounded diagnostic boots with the 25 ms tick in
  place. Report the observer effect.
- Record guest monotonic receipt and response spans for start and
  wait and host monotonic guest-ring publication and response
  spans. Pair operations by ID and preserve their separate clocks.
- Run the same lifecycle directly against guest `/var/run/docker.sock`
  and through the host endpoint serially; preserve limits, image, operation
  order and removal boundary. Include `_ping` transport controls.
- Capture request delivery, first-byte and complete-response durations on
  each clock independently. Record reclaim activity, memory targets and
  runtime cgroup CPU/PID counter deltas. Do not subtract unrelated medians.
- Identify whether the residual lies inside or outside the guest
  Docker request handler. Retain inconclusive runs and record host
  and guest cleanup evidence. Require attribution before selecting
  an implementation.

Problem and Evidence: [SPEED-050 diagnostic results](docker-benchmark-results.md#speed-050-guest-local-retained-docker-lifecycle).
Two untraced and two traced boots completed with 12 timed operations
and four warmups on each lane. The guest-unforwarded floor was
112–117 ms on the untraced boots. The traces place 74–77 ms of the
start request inside the guest Docker path before its first byte.
Raw records, artifact hashes and resource observations are under
`conjet-speedup-evidence/SPEED-050`.

Source: [SPEED-047](#speed-047), [SPEED-048](#speed-048), [SPEED-049](#speed-049).

Review: Host and guest traces correlated by tag. Dynamic memory and
the 25 ms tick ran throughout. Two supplemental controls used the same
binaries with tracing off and collected the engine cgroup counters.
The traced forwarded medians were 2.4% and 8.8% higher than their
same-binary controls. The separate SPEED-051 syscall evidence
implicates OCI setup, with exact untraced component attribution open.

Next Action: Review the diagnostic and exact deployable attribution
before selecting a runtime change.


### SPEED-049

Title: Compare retained Docker event wake with official Kiri

Description: Measure the frozen no-network Alpine true API and CLI
groups with the scoped ingress candidate and official Kiri 0.2.2.

Is blocked by task: SPEED-051 for CLI requalification. SPEED-048 is complete.

Acceptance Criteria:

- Run five independent alternating pairs per lane with 2,000 timed
  operations and ten warmups per engine and boot.
- Record matched workloads, backend identities, effective limits and
  cleanup. Preserve failures and partial runs.
- Compute the frozen paired 95% intervals from five eligible pairs.
  Evaluate the API separately from the 1.05 CLI parity requirement.

Problem and Evidence: SPEED-048 reduced host ingress publication
delay. The retained Docker API lane remained slower than Kiri.
One Conjet CLI operation exited 127 with a `pthread_create` resource
error. The same signature appears in earlier retained Docker evidence
before the ingress watcher. In a later diagnostic the packaged
runc binary reproduced thread creation failure under four PIDs.

Approach: Run the frozen lifecycle harness with Core 1.3.1 and
release revision `84e29ab446329a2ea379564253f126a86b3cbeff`.
Enable the isolated event wake and keep tracing disabled. Run
the resource and exit canaries outside qualification timing.

Evidence: Ran `benchmarks/docker-comparison.py --mode lifecycle --group
alpine-true/none/{api,cli} --all-pairs --timeout 1800 --retained-event-wake`
with private endpoints and the frozen release paths in each launcher
record. API pair 4 was rerun and pair 5 ran separately after the
preserved guard event. Across 40,000 timed operations and 200 warmups, one CLI operation
failed. The five API pairs produced p50 ratio 102.9228
(95% interval 92.1571–115.4850) and p99 ratio 80.0233
(51.7371–107.6650). Four CLI pairs are eligible. Both canaries and
all final production and host teardown checks passed.
Raw evidence is under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-049`.

Source: [Benchmark contract](docker-benchmark-plan.md),
[qualification report](docker-benchmark-results.md#speed-049-retained-docker-release-lifecycle-against-kiri).

Review: Audited artifacts, timings, fixture identity, limits and boot
cleanup. API measurement is complete with a failed speed target.
CLI qualification remains incomplete on correctness. Independent PR
review is pending.

Next Action: Isolate the four-PID CLI failure in SPEED-051. Preserve
the current measurements and requalify CLI only after a verified fix.

### SPEED-020

Title: Benchmark Docker image and registry operations

Description: Measure pull, local load/save, image inspection and removal with controlled registry and cache conditions.

Is blocked by task: SPEED-019.

Acceptance Criteria:

- Use identical immutable images and architecture; separate manifest lookup, transfer, decompression/unpack and ready-to-run where observable.
- Measure cold and cached pulls using a task-owned local registry when supported; report public-network pulls separately without attributing network variation to the runtime.
- Verify digest and runnable contents after pull/load; measure save/load throughput and disk expansion. Delete only task-owned images and artifacts.
- Record unsupported image-management operations for native-only endpoints; image preparation is included in native readiness cost where relevant.

Problem and Evidence: The first serial image pair completed and verified cleanup.
It produced pinned Node save/load and runnable proofs on both engines
and loopback registry reimports. Kiri's reused Alpine config advertised
the historical index digest while returning the exact pinned ARM64 config
digest. The runner now checks that pinned config digest independently
and retains advertised-manifest status. Registry reimports separately
record observed blob transfers and keep pristine layer cache unknown.
Four fixture tests passed. Retained raw data under ExternalSSD
`SPEED-020/pair-1`; repeat the affected Alpine row and the remaining pairs.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Verified immutable identities, complete transfers, archive/load and execution canaries, pinned participants, five independent pairs, exact cleanup and production snapshots. Pending program review with the SPEED-019 dependency.

Evidence: `SPEED-020/pair-2` passed both image pins, warm save/load and run. Its host timestamp filter missed Conjet registry witnesses. `SPEED-020/pair-3` on `b31afde` observed all expected config and layer bytes for all ten measured first pulls per engine. Both engines passed archive, run and labeled-registry cleanup checks with zero scenario failures. Keep the prior unknown transfer records.
The subsequent private Kiri inventory found 24 owned digest-only registry
images omitted by the earlier repository-filtered listing. Removed their
exact config IDs and verified absence without pruning. The harness now
validates those IDs against the full private image inventory and verifies
their removal. See `SPEED-026/final-local/kiri-image-inventory*.log`.
`SPEED-020/cleanup-qualified` then completed five independent matched pairs
at `20e3a2b` with zero recorded operation failures. It verified 12 digest-only
removals per engine per boot and complete transfers for the first pulls.
`summary.json` records per-session distributions and the paired CIs. Kiri
met the frozen faster threshold for the four controlled pull rows. The supplemental `SPEED-020/backing-observation` captured before/after backing allocations. Per-session archive throughput and inspection distributions are retained.

Next Action: Review the full image evidence with the remaining program results once SPEED-019 is ready.

### SPEED-013

Title: Open and qualify the speed enhancement PR to main

Description: Submit the completed enhancement with its final benchmark and
correctness evidence, then resolve review and CI findings before merging.

Is blocked by task: SPEED-012 and SPEED-011 required experimental checks.

Acceptance Criteria:

- Prior development and required local gates are audited with passing evidence
  and verified pushed commits. SPEED-008 continues to record its revise verdict.
- Final qualification reports identify the tested revision and exact claim scope;
  no required check is skipped or unresolved.
- PR targets main from enhancement/speed-up and links the plan, board, reports,
  compatibility limitations, and rollback procedure.
- Required CI and review pass; changes during review receive applicable validation
  and are pushed as additional increments before merge.

Problem and Evidence: A pushed implementation branch alone does not establish
reviewed integration or release readiness.

Approach:

1. Audit every task and final gate against the remote branch revision.
2. Open the PR with concrete behavior, benchmark results, and validation evidence.
3. Resolve findings, rerun affected checks, push increments, and merge only when
   repository review and CI requirements are satisfied.

Evidence: The final local gate was audited against `cb1f80f` and the
remote enhancement branch matched. [PR #33](https://github.com/omega13-engr/conjet/pull/33)
targets main and discloses the experimental scope, local measurements,
rollback procedure and deferred comparative work. On `d613c87`,
[hosted CI](https://github.com/omega13-engr/conjet/actions/runs/45083820209)
passed the build and host tests, then failed the existing overflow-pulse
app test. Its fixed 220 ms sleep could end before asynchronous inventory
loading recorded any invocations. The test now awaits the scheduled
refresh and retains all five Docker inventory assertions. The application
change only exposes the existing task on its test hook. The 50-test
focused suite and the 440-test full Swift suite passed locally, with two
configuration skips in the full suite. Failure and regression logs are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-013`.
Independent review, passing hosted CI and merge remain pending.

New hosted runs `45101948820` and `45102608771` reproduced separate
image-pulse timing failures. The tests now await the scheduled refresh.
The queued case uses an explicit command gate so the initial container
refresh stays in flight until the deferred event queues. Assertions are
unchanged or stronger. Seven pulse tests passed three consecutive local
runs. The full native SwiftPM suite executed 440 with two skips and zero
failures. The logs and the two hosted failures are kept in
`SPEED-026/final-local`. On `63e9147`, [hosted CI](https://github.com/omega13-engr/conjet/actions/runs/45104363466)
passed Swift, networking, app staging and benchmark checks. Later branch
revisions still require current CI and independent review before merging.

Source: [Qualification policy](speed-engineering-plan.md#verification-and-claim-policy),
[release process](../release.md).

Review: Pending; verify all development gates before opening the PR and all CI
and review requirements before merge.

Next Action: Collect required CI and independent review before merging.

## SUPERSEDED

The following retained-engine tasks remain unresolved historical evidence.

### SPEED-051

Title: Diagnose and correct the retained Docker four-PID CLI failure

Description: Isolate the intermittent CLI exit 127 on the pinned
no-network Alpine true fixture with four PIDs.

Is blocked by task: None. SPEED-049 records the failed operation.

Acceptance Criteria:

- Attribute the thread-creation failure to a guest process or runtime
  stage using the fixed fixture and a bounded diagnostic boot. Preserve
  the four-PID workload, operation output and error on failure.
- Validate a narrow correction at the same effective cgroup limits
  and check cleanup after failure and success.
- Keep this diagnostic separate from the five-pair CLI requalification.

Problem and Evidence: SPEED-049 `cli/pair-5/conjet/session.json`, measured sample
139, and [SPEED-051 live diagnostics](docker-benchmark-results.md#speed-051-four-pid-cli-failure-capture).
The traced boot ran 550 clean launches. The cgroup-observer boot ran
2,000 clean launches and observed runc init inside the intended
four-PID workload scopes. Neither boot reproduced the exit-127
signature. The SPEED-056 allocation-held capture added 256 clean CLI
launches with runc init observed in each workload scope and no
PID event increase. Raw captures are under
`conjet-speedup-evidence/SPEED-051` and `SPEED-056/pid-witness-pressure`.
Production and owned host cleanup checks passed.

Source: [SPEED-049](#speed-049).

Review: Runtime stage narrowed. No failing process was captured and
no fix was validated. The historical failure remains a blocker for
CLI requalification.

Next Action: Capture a failing launch with its process and PID
controller event using the unchanged limits before selecting a fix.

### SPEED-055

Title: Requalify retained Docker lifecycle with dynamic memory enabled

Description: Freeze accepted changes and repeat the existing API and CLI comparison against official pinned Kiri.

Is blocked by task: SPEED-051 fixed; SPEED-050 complete; SPEED-052–054 accepted or rejected with evidence.

Acceptance Criteria:

- Run five independent alternating boot pairs per lane, 2,000 timed operations and ten warmups per engine/boot. Preserve frozen fixture limits and all failures.
- Run normal dynamic memory; pass pressure, active-data, idle-convergence and backing-release gates before timing. No benchmark-only fixed-memory configuration.
- Publish the existing detailed report tables: hashes/resources, per-boot p50/p95/p99, throughput, stage timings, paired 95% intervals, correctness, coverage and cleanup.
- Apply existing CLI parity and API advantage criteria; explicitly report API parity using the declared 1.05 upper-bound rule for both percentiles. Report the below-5-ms median target separately; do not claim a p99 or CLI 5-ms result.
- Leave SPEED-049 historical failure intact. Mark build, Compose and other lanes unqualified for this candidate until their existing matrix tasks are rerun; no release or global superiority claim from this task alone.

Problem and Evidence: [SPEED-055 qualification status](docker-benchmark-results.md#speed-055-qualification-status).
The private retained-engine probe passed 26 compatibility probes
and four API/CLI output canaries. The five-pair candidate series and
full benchmark matrix were held behind the open SPEED-051 gate.

Source: `benchmarks/docker-comparison.py`, the
[benchmark protocol](docker-benchmark-plan.md) and the
[architecture plan](retained-docker-latency-architecture.md).

Review: Formal requalification remains blocked. Historical SPEED-049
API parity failed and CLI parity was inconclusive. The new guest-local
diagnostic missed the below-5-ms target.

Next Action: Resolve and verify the four-PID correctness issue before
freezing a candidate.

### SPEED-037

Title: Mount a named volume and an allowlisted ExternalSSD bind

Description: Implement the two storage modes required by the existing storage and Compose fixtures.

Is blocked by task: SPEED-036 (DONE).

Acceptance Criteria:

- Preserve a checksummed named-volume file across container restart; remove it only on explicit owned-volume deletion.
- Support a read/write and read-only bind beneath the designated ExternalSSD fixture root; verify guest writes on the host and enforced read-only behavior.
- Reject path traversal, symlink escape and unapproved host roots. Test mount failure rollback, busy-volume removal and permission mapping.
- Expose the fixture-required Docker volume/mount metadata without legacy Docker storage; verify no residual mounts after teardown.

Problem and Evidence: Native workloads currently lack persistent volumes and host binds; this blocks realistic Compose and storage comparisons.

Approach:

1. Implement one named-volume fixture, then the allowlisted bind with negative path tests.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-037`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

### SPEED-038

Title: Run a pinned BuildKit worker on the native engine

Description: Enable the exact BuildKit worker configuration required by the existing Buildx fixture and verify one Rust build/export/run.

Is blocked by task: SPEED-037.

Acceptance Criteria:

- Start the worker with the unmodified Buildx client through the native endpoint; no hidden Docker/containerd daemon or host build fallback.
- Identify its actual build executor and required mount/namespace/security capabilities. Implement narrowly scoped requirements with escape-denial tests; unsupported privileged mode is not a workaround.
- Supply identical verified offline OCI bases to both engines, export/load the result through native image handling, and run its output canary.
- Capture effective worker CPU/memory/I/O limits and verify worker, cache and exported-image cleanup. Leave this task open if native execution of the worker is not proven.

Problem and Evidence: Native launch speed does not imply build acceleration; the current builds use the old engine.

Approach:

1. Probe the pinned worker's exact prerequisites and add individual capability subtasks for any missing native operation.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-038`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

### SPEED-039

Title: Run Node and Redis Compose entirely on native

Description: Implement the remaining API semantics required by the existing pinned Compose fixture.

Is blocked by task: SPEED-038.

Acceptance Criteria:

- Run unmodified docker compose up --wait with native-owned Node and Redis; prove backend and effective cgroup limits for each service.
- Pass HTTP transaction, service DNS, health check, log retrieval and persisted Redis-data canaries.
- Pass no-change up, app recreate, scale to two replicas, restart and down --volumes with correct event/state semantics and cleanup.
- Explicitly reject unsupported Compose features and preserve the production context; no legacy fallback for any service.

Problem and Evidence: Prior Compose measurements used Docker/containerd; default-native promotion requires actual multi-service compatibility.

Approach:

1. Replay the frozen Compose client's request transcript against native and implement each missing operation with a regression test.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-039`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

### SPEED-040

Title: Qualify release native Docker launch parity

Description: Run the frozen matched API and Docker CLI launch matrix using the completed native owner.

Is blocked by task: SPEED-039.

Acceptance Criteria:

- Build all candidate components in release mode from one source revision; record hashes/settings and validate actual native dispatch for every sample.
- Collect five alternating independent pairs, 2,000 samples per engine/lane/boot and ten warmups for the frozen lifecycle rows; include supported bridge and output/exit scenarios.
- Preserve API acknowledgement versus verified cleanup distinctions, raw failures and per-session distributions. Compare native to Kiri and the frozen prior native baseline.
- Evaluate CLI p50 and p99 parity with paired 95% ratio upper bound <=1.05; report API median advantage and regressions separately. A failed target creates a concrete profiling follow-up, not a fabricated pass.

Problem and Evidence: The new native host and compatibility changes require fresh measurements; old legacy samples cannot qualify them.

Approach:

1. Freeze the release artifact manifest and run diagnostic-free matched launch pairs.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-040`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

### SPEED-041

Title: Measure the native-backed Rust Go and Node build matrix

Description: Execute the existing empty/unchanged/source/dependency build cases using the qualified native BuildKit setup.

Is blocked by task: SPEED-040.

Acceptance Criteria:

- Retain the same Dockerfiles, offline bases, clients, cache-state definitions and export/load boundaries used by the recent report.
- Complete five independent pairs with the frozen per-case repetitions and verified artifact execution; record failed artifacts as failed operations.
- Publish the same build latency and worker CPU/peak-memory/read/write tables; identify worker/executor and export/load time separately.
- Attribute every worker container to native and compare cache behavior/effective limits before making a speed claim.

Problem and Evidence: Prior build timings were legacy-host results and cannot establish native build performance.

Approach:

1. Run the Rust cache-state group first, then Go and Node without overlapping timed suites.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-041`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

### SPEED-042

Title: Measure native Compose and exec/control workflows

Description: Run the unchanged Compose and persistent exec/control cases against the native candidate and Kiri.

Is blocked by task: SPEED-041.

Acceptance Criteria:

- Complete five independent pairs for the existing readiness/recreate/scale/restart/down and exec/inspect/list/attach/log/event/copy rows at their frozen counts.
- Validate transactions, stdout/stderr, exit statuses, file checksums and effective service limits outside timing as specified; preserve failure records.
- Use the existing per-operation p50/p95/p99 table format and declare unsupported rows explicitly; a required unsupported row blocks native compatibility completion.
- Record all service and exec backend identities and project-scoped cleanup; do not mix old-engine rows into the native series.

Problem and Evidence: Launch parity alone does not establish an improved interactive or multi-service Docker experience.

Approach:

1. Freeze one native Compose/exec series manifest and run its first paired session with canaries.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-042`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

### SPEED-043

Title: Measure native storage network and service performance

Description: Execute the frozen named-volume, host-bind, writable-layer and network/service workloads on native.

Is blocked by task: SPEED-042.

Acceptance Criteria:

- Verify dataset hashes, durability and mount permissions; report Docker CLI elapsed time separately from guest I/O stages.
- Measure matching DNS/TCP, host published-port transactions and standalone bulk transport with explicit client placement and topology.
- Complete five independent pairs at frozen repetitions and steady-state durations; retain CPU/memory, disk growth, failures and application correctness.
- Preserve the recent storage/network table format and units; record unsupported semantics without substituting host operations.

Problem and Evidence: Native filesystem and network implementations may change performance in either direction and need workload-specific validation.

Approach:

1. Run storage canaries before timed I/O, then the isolated transport and application groups.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-043`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

### SPEED-044

Title: Qualify native concurrency pressure and recovery

Description: Run the existing 1/2/4/8 launch sweep and bounded pressure/recovery matrix on the expanded native owner.

Is blocked by task: SPEED-043.

Acceptance Criteria:

- Verify effective guest memory/swap/CPU controls before allocation; preserve active checksummed data while evicting optional prepared state.
- Test queue saturation, cancellation, OOM attribution, client/guest disconnect and task-owned VM termination; reject duplicate starts and verify cleanup inventories.
- Complete five independent matched sweeps where competitor behavior permits. Preserve Kiri timeouts/unknown boundaries and report incomparable pressure cases explicitly.
- Publish the same concurrency/throughput and resource tables. Prepared claim/refill stays separate and cannot hide reserve cost.
- No persistent services, production interruption or unsafe host-wide pressure. Optional energy collection remains separately authorized.

Problem and Evidence: Additional concurrent services and worker capabilities introduce ownership, pressure and recovery risks absent from the single-slot fixture.

Approach:

1. Run native lifecycle fault injection and active-data canaries before the timed concurrency series.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-044`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

### SPEED-045

Title: Publish the native-default Docker verdict and promotion audit

Description: Extend the existing detailed report with the complete native-default series and exact compatibility scope.

Is blocked by task: SPEED-044.

Acceptance Criteria:

- Preserve the report's environment/hash, per-pair API/CLI, per-operation, build-resource, concurrency, ratio/95% interval, coverage and evidence tables.
- Audit raw measurements, failures, revisions, effective limits and native backend attribution; retain historical legacy/development tables with their original labels.
- Use per-workload parity/faster/slower/inconclusive/unsupported verdicts. Publish no overall win unless every declared workload supports it; unknown cleanup or energy remains unknown.
- Create narrow follow-up tasks for demonstrated bottlenecks and missing compatibility. Update the release scope to actual supported behavior without marking deferred SPEED-008 passed.
- Review packaged native-default startup, rollback, CI and cleanup evidence before proposing promotion. Independent PR approval and production signing remain required; this task does not itself publish a release.

Problem and Evidence: The current report mixes historical and native evidence by design; the next verdict must make actual native coverage explicit without rewriting history.

Approach:

1. Generate the native-only coverage matrix from SPEED-040 through SPEED-044 raw evidence.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: Pending commands, revision and release artifact hashes, fixture results,
raw observations and cleanup records under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-045`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Pending; verify acceptance, bounded ownership, actual native execution,
compatibility, measurement scope and unchanged production.

Next Action: Preserve this entry as research history. The retained
Docker path has no dependency on this task.

## PAUSED RESEARCH

### SPEED-037A

Title: Back the native named-volume registry with a private ext4 disk

Description: Allow one explicitly configured isolated VM disk under
ExternalSSD and prove that the guest's named-volume registry survives
orderly boot replacement.

Is blocked by task: SPEED-036 (DONE).

Acceptance Criteria:

- Verify an exclusive host lease, canonical backing path, and an
  ext4 volume identity before boot. Reject a symlink and a busy disk.
- Create eight scoped volumes with the fixture credentials. Reject
  traversal, a stale generation and a ninth volume.
- Recover the registry after a second boot, explicitly delete its
  volumes, and verify a clean filesystem after unmount.

Problem and Evidence: The native candidate used a disposable blank
virtio disk. Its OCI guest had no durable named-volume registry.

Approach: Pass the private disk through the existing second virtio
block device. Identify it in the guest by verified ext4 UUID. Retain
volume directories under a root-owned registry and unmount on
orderly guest shutdown.

Evidence: Unfinished research checkpoint. Built release Jetstream and
ARM64 guest on `de8773b` plus this change. Eight volumes survived a
private reboot with UID/GID 65532 and mode 0700. Stale boot, traversal,
capacity, symlink and host lease negatives passed. `e2fsck -fn` found
zero deletion timestamps on the original disk. A fresh boot with a
guest wall-clock initialization attempt failed readiness and required
forced cleanup of the owned VMM. The session directory was removed and
production snapshots matched. Raw evidence, hashes and commands are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-037A`.

Source: [Volume backing](../../guest/launch-service/src/volume_disk.rs),
[volume disk fixture](../../benchmarks/native-volume-disk.py).

Review: Guest and Jetstream tests and ARM64 Clippy passed before the final
pilot. Its readiness and filesystem acceptance remain unverified.
Container mounts and busy deletion were never implemented. This
checkpoint is research after the retained Docker path decision. The local archive is
`research/native-volume-checkpoint` at `c60304f`. The evidence folder
also contains `research-checkpoint.patch`.

Next Action: Preserve the source and diagnostics. The retained Docker
path has no dependency on this experiment.

## DONE

### SPEED-175

Title: Remove per-chunk RPC delay from bounded Docker archive uploads

Description: Optimize the original Docker copy-in path for regular files
up to the current archive size limit.

Is blocked by task: SPEED-174 passed the immediate copy startup check.

Acceptance Criteria:

- Keep guest staging private, validate the declared bytes and SHA-256,
  and require a correlated commit request before publication. Preserve
  same-mount path checks, owner and mode, atomic replacement, fsync and
  original cleanup. Retain the legacy transfer for older peers.
- Check digest failure, partial or uncommitted disconnect, wrong request
  identity, and destination replacement. Re-run both original sizes with
  the frozen copy checksums and matched diagnostics.

Problem and Evidence: Trace boots charged 170–180 ms to 1,024 upload
RPCs. The latest matched download screen put the unchanged 8 MiB
upload near 240 ms. The measured begin and commit operations were
each below 1 ms in the trace.

Approach: Transfer a bounded binary payload under the existing guest
staging reservation. Use the existing archive publish function after a
correlated commit, exact digest verification and current workload check.

Evidence: Two alternating pairs with the original control setup and
copy checks recorded 100 measured requests and ten warmups per case and
boot. The pooled 8 MiB upload median fell from 231.822 to 79.520 ms.
The pooled 8 MiB download medians were 65.858 and 66.977 ms. Both 4 KiB
paths and all copy checksums passed. The matched data are in
`SPEED-173/cj-perf.LBoyR4-copy-upload-matched-ab/` on ExternalSSD.

Source: `guest/launch-service/src/workload_copy.rs`,
`guest/launch-service/src/fresh_fixture.rs`,
`guest/launch-service/src/server.rs`, `guest/launch-service/src/wire.rs`,
`jetstream/src/native/client.rs`, and
`jetstream/src/native/docker/workload_copy.rs`.

Review: The stream shares the legacy upload reservation and calls the
same commit function. Live verification covered failed digest, partial
and uncommitted disconnect, a mismatched commit identity, destination
replacement, denied staging in a private directory, and 16 MiB
round-trip SHA-256 and mode. Two fixture setup attempts are retained
with the successful repeat in `SPEED-175/cj-perf.LBoyR4-copy-upload/`.
Rust workspace tests, strict ARM64 Clippy and isolated cleanup passed.

Next Action: Check archive download concurrency against the existing
authenticated peer limit, then trace the ExternalSSD bind workload.

### SPEED-174

Title: Wait for an owned workload before an immediate Docker archive copy

Description: Close the startup window between a successful detached
start response and the native workload becoming ready for archive I/O.

Is blocked by task: SPEED-173 passed its scoped download checks.

Acceptance Criteria:

- Immediately submit the existing archive upload after Docker API start.
  Every successful start must support the existing 4 KiB upload and
  exact tar readback. Preserve bounded waits, rejected inactive targets
  and original workload generation checks.
- Keep the startup wait outside the guest ledger lock. Keep any upload
  staging outside an unresolved target and avoid replaying requests.

Problem and Evidence: The first short-copy warmup returned
`not_running` after a successful detached start. Thirty direct
create/start/upload attempts returned 23 guest `not_running` errors
and two host `still preparing` errors. The five accepted attempts
returned the exact tar.

Approach: Wait for the admitted handle on the host. Use the guest's
existing state-change condition and the request's deadline to wait
for an already-starting workload before stat or upload begin.

Evidence: The rebuilt candidate passed all 30 immediate uploads and
tar readbacks with the same byte, filename and mode checks. It rejected
an unstarted workload. The original 4 KiB and 8 MiB CLI round trips also
passed. ExternalSSD retains the input, both exact executable sets'
checksums, API outputs and detached disk checks in
`SPEED-174/cj-perf.LBoyR4-copy-start/`.

Source: `jetstream/src/native/docker/workload_copy.rs` and
`guest/launch-service/src/fresh_fixture.rs`.

Review: The guest condition releases the ledger while waiting and
rechecks the exact handle before upload staging or file access. Rust
workspace, strict ARM64 Clippy and isolated teardown passed.

Next Action: Remove the measured per-chunk RPC cost from 8 MiB uploads.

### SPEED-173

Title: Remove per-chunk RPC delay from bounded Docker archive downloads

Description: Optimize the original Docker copy-out path for regular files
up to the current archive size limit.

Is blocked by task: SPEED-172 passed the original exec canaries.

Acceptance Criteria:

- Preserve guest generation, workload and file identity, byte bounds and
  tar metadata. Withhold the HTTP archive if the guest transfer fails,
  the source changes or the connection closes before acknowledgement.
- Verify copied contents with the original 4 KiB and 8 MiB SHA-256
  round trips. Cover rejection, disconnect and cleanup.

Problem and Evidence: Three original 8 MiB copies each used 1,024
round trips in each direction. Guest RPCs accounted for 1,134 to
2,381 ms of the copy-out stage. The second host tar spool took
32 to 41 ms. Upload RPCs accounted for 170 to 180 ms.

Approach: Stream a descriptor-pinned file over the authenticated
connection into a private tar. Verify the retained source and require
the final correlated acknowledgement before publishing the HTTP body.

Evidence: Two alternating pairs kept the original control startup
canaries, 100 measured copies and ten warmups per case and boot. All
4 KiB and 8 MiB round trips passed their SHA-256 check. The pooled 8 MiB
download median fell from 2,214.733 to 69.903 ms. The paired diagnostics
used one host and swapped only guest support for the download stream.
The original abbreviated screen caught a `not_running` upload response
in its first warmup after detached start. The exact failed attempt is
retained for a separate startup regression. ExternalSSD retains
`SPEED-173/cj-perf.LBoyR4-copy-profile/`,
`SPEED-173/cj-perf.LBoyR4-copy-download-ab/`, and
`SPEED-173/cj-perf.LBoyR4-copy-download-matched-ab/`.

Source: `guest/launch-service/src/workload_copy.rs`,
`guest/launch-service/src/fresh_fixture.rs`,
`guest/launch-service/src/server.rs`, `guest/launch-service/src/wire.rs`,
`jetstream/src/native/client.rs`, and
`jetstream/src/native/docker/workload_copy.rs`.

Review: The guest retains an authenticated workload pidfd, verifies both
the open file and the current path, and releases the transfer on peer
closure. The host keeps the tar private until the final correlated reply.
Rust workspace and strict ARM64 Clippy passed. The live guest passed the
16 MiB SHA-256 round trip, stale request and conflicting-credit rejection,
both in-place and replacement mutation rejection, and disconnect recovery.
The workload file-size cap remained effective. Evidence is in
`SPEED-173/cj-perf.LBoyR4-copy-download/`.

Next Action: Reproduce and close the immediate archive startup race, then
profile the streamed upload candidate against the original two sizes.

### SPEED-172

Title: Reduce latency of native Docker exec process completion

Description: Trace the original CLI and API exec output and exit-code
canaries through the guest supervisor and namespace helper.

Is blocked by task: SPEED-171 passed the native exec streaming checks.

Acceptance Criteria:

- Attribute the cost of observing the wrapper and its command exit.
- Preserve exact stdout, stderr and terminal status. Exercise timeout,
  client disconnect, TTY and workload cancellation with owned cleanup.
- Compare the original exec latency with matched boots and sample budgets.

Problem and Evidence: The prior full control comparison had an API exec
paired median ratio of 17.875. Both guest completion loops currently wait
up to 5 ms after a nonblocking child status check.

Approach: Trace the waits independently with the original control canary.
Use readiness for the owned process if the trace supports a causal change.

Evidence: On the original canary, all six traced commands hit the
helper's 5 ms sleep and the supervisor slept two to four times per
command. Two alternating boots per variant with 100 measured requests
and ten warmups per case and boot passed with no output or exit-code
mismatches. Pooled API exec median fell from 24.232 to 1.637 ms.
CLI median fell from 57.622 to 18.774 ms. API inspect was 0.460 and
0.169 ms respectively. These diagnostic medians do not establish Kiri
parity. ExternalSSD retains `SPEED-172/cj-perf.LBoyR4-exec-wait-profile/`
and `SPEED-172/cj-perf.LBoyR4-exec-readiness-ab/`.

Source: `guest/launch-service/src/exec_fixture.rs`.

Review: Both loops wake on an owned child's pidfd and still reap via
their original wait calls. The outer loop keeps the cancellation and
kill deadline checks. Polling remains available if pidfd readiness is
unavailable. Rust workspace tests, strict ARM64 Clippy and the isolated
live exec checks passed, including timeout, client disconnect, TTY,
signal and active removal cleanup.

Next Action: Profile the original 8 MiB Docker copy-out path.

### SPEED-171

Title: Attribute and reduce cached Node Docker archive export latency

Description: Trace the pinned BuildKit worker's tarball transfer from
guest process output through the native exec relay to Buildx and the
original ExternalSSD archive destination.

Is blocked by task: SPEED-170 passed its scoped archive checks.

Acceptance Criteria:

- Measure the completed transfer and distinguish worker output readiness,
  guest relay, host relay and writer costs. Preserve original format,
  backpressure, cancellation, error streams and terminal status.
- Qualify any change against the original exported-image and cache
  witnesses. Keep timing diagnostics separate from qualification binaries.

Problem and Evidence: Cached Node builds bypass COPY and RUN. The retained
comparison recorded median rounded tarball delivery of 800 ms on Conjet
and 300 ms on Kiri. The optimized archive-load stages address a separate
client boundary.

Approach: Collect numeric stream counts and durations on the exact
BuildKit client path in a trace boot. Optimize the demonstrated cause.

Evidence: The traced cached export transferred about 61 MB in 7,600
guest stdout frames. It spent 590 ms sending the frames, including
socket waits. The host spent 156 ms forwarding stdout to Buildx.
These spans overlap. Two alternating pairs with the original four Node
cache cases and identical pinned BuildKit seeds passed all 48 image
checks. The unchanged-cache build and export median moved from 950.326
to 775.421 ms. The median rounded tarball transfer moved from 750 to
600 ms. The other three build and export medians also fell. The frozen
full comparison supplies the Kiri result. ExternalSSD evidence is in
`SPEED-171/cj-perf.LBoyR4-node-export-profile/eof/` and
`SPEED-171/cj-perf.LBoyR4-node-frame-ab/`.

Source: `guest/launch-service/src/wire.rs`.

Review: Each validated frame now submits its existing header and payload
in one bounded write. The regression verifies the exact framing and
terminal code. Workspace tests, guest lint, and the native live-output
checks passed using the original stream and cleanup expectations.

Next Action: Measure the two process-exit waits on the original exec API
and CLI paths.

### SPEED-170

Title: Attribute archive load and remove redundant blob I/O

Description: Measure the original Buildx export and Docker archive load
boundary on OverlayFS. Optimize verified archive publication where the
measured cost justifies a change.

Is blocked by task: SPEED-169 passed the scoped build and memory checks.

Acceptance Criteria:

- Separate upload spooling, tar extent hashing, blob publication, package
  creation and durability costs in a dedicated diagnostic run.
- Preserve content verification, atomic publication, source mutation
  rejection, limits, cache ownership and durable cleanup. Use unchanged
  archive inputs and output canaries for any follow-on comparison.

Problem and Evidence: The Rust OverlayFS A/B left dependency archive load
at a pooled median of 219.361 ms. The importer hashes archive extents,
writes new content to a temporary blob, reopens it for verification,
and creates a separately verified OCI package.

Approach: Measure the passes inside the actual pinned Docker load path.
Test a single-pass verified write if rereads contribute measurable latency.

Evidence: The scoped import trace recorded 1,973 ms in package creation
and 184 ms in blob rereading during an empty-cache Node load. The macOS
ARM64 adapter now enables RustCrypto's hardware SHA-256 backend. Two
alternating diagnostic pairs measured pooled Node empty-load medians of
2,647.993 and 1,358.796 ms, and Rust dependency-load medians of 234.516
and 147.546 ms. All 96 output checks passed. The archive regression also
passed corruption rejection. Data are in
`SPEED-170/cj-perf.LBoyR4-archive-profile/`,
`SPEED-170/cj-perf.LBoyR4-archive-profile-sha/`, and
`SPEED-170/cj-perf.LBoyR4-archive-sha-ab/` on ExternalSSD.

The publication writer also hashes accepted bytes as it writes new blobs,
decoded layers and the packed OCI output. A source mutation and a partial
write regression passed. The existing archive canaries and corrupt-layer
rejection passed. Two matched-seed diagnostic pairs measured Node empty
load at 1,330.551 and 1,279.151 ms, and Node dependency load at 1,283.225
and 1,233.809 ms. The other rows were mixed. The samples and the separate
public bootstrap failures are in `SPEED-170/cj-perf.LBoyR4-archive-stream-seeded-ab/`
and `SPEED-170/cj-perf.LBoyR4-archive-stream-ab/`.

Source: `jetstream/src/native/docker/archive.rs`,
`jetstream/src/native/docker/registry.rs`, and
`jetstream/src/native/oci_stage.rs`.

Review: The host feature uses the existing SHA-256 implementation on the
macOS ARM64 build. Rust workspace tests, archive regression, and private
teardown passed. The first OverlayFS hosted run failed an existing Darwin
backing-check test. The unchanged test passed 100 local repetitions and
the exact hosted rerun. [Hosted macOS CI](https://github.com/omega13-engr/conjet/actions/runs/45550038700)
[RustCrypto SHA-2 sources](https://docs.rs/crate/sha2/0.10.9/source/CHANGELOG.md)

Next Action: Trace cached Node tarball delivery on the native exec stream.

### SPEED-169

Title: Qualify OverlayFS snapshots for the isolated BuildKit worker

Description: Measure the pinned worker's snapshot cost and qualify an
OverlayFS-backed RUN root through the native executor and cache lease.

Is blocked by task: None. The pinned Buildx path passed SPEED-160 and SPEED-098.

Acceptance Criteria:

- Admit the actual pinned rootless worker on the release guest kernel. Bind
  the root mount and layer descriptors to the authenticated worker and its
  private cache. Preserve the ordinary workload profile and teardown rules.
- Compare the two snapshotters on the original Rust dependency-change build
  with the same digests, bounds, Core policy and correctness checks. Cover
  OverlayFS metadata, copy-up, whiteouts and cleanup before promotion.

Problem and Evidence: Each engine ran 45 builders in the verified five-pair
baseline. Conjet used the native snapshotter and Kiri used OverlayFS. The
15 Rust dependency exports per engine recorded median rounded COPY sums of
14,000 and 0 ms, and RUN sums of 6,200 and 200 ms. The latter sums combine
preparation and execution. Node unchanged export spent 800 versus 300 ms
sending the tarball. That independent boundary remains a later increment.

Approach: Keep the worker identity and resource policy fixed. Qualify
snapshot mount ownership and release before comparing the same fixture with
native and OverlayFS snapshots. Resolve unobserved stage boundaries with
diagnostic builds on separate artifacts.

Evidence: `SPEED-169/cj-perf.LBoyR4-snapshot-ab/` holds the timings,
CPU, I/O, memory and teardown receipts. Public build and pressure
witnesses are under `SPEED-169/cj-perf.LBoyR4-overlay-builds/`.
`SPEED-169/cj-perf.LBoyR4-baseline-16a05e0/` on ExternalSSD
contains the extraction script and 360 per-build rows from the retained raw
progress. Command durations and archive load are directly observed. The
rounded stage sums overlap and cannot isolate snapshot preparation, runtime
admission, commit, compression, transport, or image publication.

Source: [BuildKit executor](native-buildkit-executor.md) and
[performance mandate](native-performance-worker-prompt.md).

Review: The baseline agrees with all worker labels and measured row counts
in the five passing pairs. The two-pair A/B passed 48
exported-image canaries and observed a pooled Rust dependency solve/export
median of 514.647 ms with OverlayFS and 16,494.886 ms with native snapshots.
The scoped public build compatibility predicates, Docker build API, direct
BuildKit, metadata, fsynced writeback, active lease rejection, worker loss
and replacement passed. Native Core admitted the exact RUN while a separate
guest cgroup reported pressure. Formatting, Rust workspace tests and
strict ARM64 guest Clippy passed. Strict host Clippy reproduced the
baseline diagnostic counts.

Next Action: Profile archive import on the OverlayFS candidate.

### SPEED-048

Title: Evaluate event-driven ingress on the retained Docker VSOCK bridge

Description: Wake the existing Jetstream queue owner on private Docker
socket readiness. Retain the current engine and 25 ms fallback tick.

Is blocked by task: SPEED-047 (DONE).

Acceptance Criteria:

- Reuse the existing owned readiness watcher, with an isolated opt-in
  and a rollback to the polling path.
- Preserve ordinary Docker lifecycle results, stream framing, EOF and
  cleanup. Test the listener wake and socket ownership directly.
- Compare release builds with ingress wake off and on in separate
  boots. Measure transport publication and complete workload latency.
  Keep the experiment opt-in if the workload result remains uncertain.

Problem and Evidence: SPEED-047 observed 4.44–8.58 ms of median
start-request delay between host queueing and guest-ring publication
in the host-only traces. The Docker accept loop polls every
10 ms and the initialized guest can wait for the VMM tick.

Approach: Apply the scoped readiness notification used by the
native-launch transport to Docker ingress. Keep the host queue,
credit, Docker engine and guest lifecycle owners intact.

Evidence: DONE. At `e716f8b` plus this change, the same release VMM
ran two alternating untraced pairs. Event-wake medians were 272.374
and 270.252 ms versus polling's 338.245 and 338.693 ms. Separate
host-only traces recorded start queue-to-ring medians of 0.106–0.124
ms with wake and 10.693–14.622 ms with polling. The retained Docker
API and CLI fixture passed all 48 measured operations and 40 warmups
across no-network and bridge cases in `docker-flow-verified`. The
first correctness report was overwritten by the launcher summary,
so the retained raw check was rerun. Commands, hashes and raw results
are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-048`.

Source: [SPEED-047](#speed-047),
[`vsock.rs`](../../jetstream/src/devices/vsock.rs).

Review: The Jetstream suite and direct event-listener test passed.
The optional path uses the same private endpoint and Docker engine.
Each boot verified unchanged production and exact owned cleanup.
The observations support this opt-in candidate. The small pilots
do not qualify a tail or competitive verdict.

Next Action: Run SPEED-049 from the frozen release build.

### SPEED-047

Title: Trace retained Docker start and wait across Jetstream and the guest

Description: Attribute a single pinned no-network API workload to
host transport and guest lifecycle spans before choosing a native
integration boundary.

Is blocked by task: SPEED-046 (DONE).

Acceptance Criteria:

- Capture bounded native Jetstream request/response wakeup spans on
  the host and guest-local dockerd/containerd start and exit events.
- Correlate by owned container identity and keep monotonic clock
  domains separate. Record trace overhead in separate control runs.
- Recommend one controllable optimization only if the trace
  demonstrates a bottleneck and preserves lifecycle ownership.

Problem and Evidence: Start and wait consume most observed API
elapsed time. SPEED-046 establishes the outer boundaries only.

Approach: Reuse host VSOCK observations and guest-local lifecycle
events. Keep the existing engine and the 25 ms VMM tick while
collecting this diagnostic.

Evidence: DONE. At `faf374d` plus this change, built the release host
tools and ran two untraced, two host-only and two combined traced boots.
Each had four warmups and 12 measurements. Every tagged start and wait
had the five host phases. Each combined trace recorded dockerd and
containerd lifecycle events for all 16 workloads by container ID.
Host-only start queue-to-ring medians were 4.44 and 8.58 ms. Combined
tracing changed workload timing materially. Raw logs, controls and
adverse pilots are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-047`.

Source: [SPEED-046 results](docker-benchmark-results.md),
[retained Docker plan](native-docker-speed-plan.md).

Review: All six final boots confirmed unchanged production, closed
handles and exact scratch removal. Rust tests passed. The diagnostic
keeps the VMM monotonic and guest engine wall clock domains separate.
The guest observer runs only in the disposable Core VM, with no
network, no capabilities and an immutable filesystem. The host-only
trace is the basis for the isolated ingress experiment. The combined
trace is causal event evidence and does not qualify a speed claim.

Next Action: Implement and test the optional Docker ingress wake
in SPEED-048.

### SPEED-046

Title: Attribute latency in the retained release Docker path

Description: Profile one isolated release boot using the normal Docker,
containerd and runc path. Evaluate the smallest runtime boundary that
preserves the existing Docker, BuildKit and Compose owners.

Is blocked by task: None.

Acceptance Criteria:

- Verify release CLI, daemon, Jetstream and helper hashes, pinned Core
  identity and an explicit private Docker endpoint.
- Collect host monotonic stage timings or the exact startup blocker.
  Verify production preservation and clean up task-owned resources.
- Select a narrow integration candidate only when the evidence attributes
  a significant cost to a controllable boundary.

Problem and Evidence: The previous retained Docker profile reported long
start and wait stages. Native OCI adapter timings describe a separate
execution path.

Approach: Use the foreground retained-engine launcher and approved
pinned fixture. Measure host API stages and whole CLI elapsed time,
then identify the narrow trace needed to attribute start and wait.

Evidence: DONE. At `de8773b`, ran the foreground launcher with
`--legacy-baseline --benchmark-samples 12` and the pinned ARM64
scenario and archive. Docker Engine 29.1.3, containerd 2.2.1 and
runc 1.3.4 executed 48 measured operations and 40 warmups with zero
failures. Start and wait accounted for 85.6% of no-network and
87.8% of bridge API time by median sample share. The profile,
commands, release hashes and reclamation record are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-046`.

Source: [Retained Docker plan](native-docker-speed-plan.md),
[historical timings](docker-benchmark-results.md).

Review: The release diagnostic verified the private endpoint and
unchanged production. All owned processes, sockets, handles, and
disposable VM files were removed. Guest teardown for each
operation remains unobservable. Host stage timing is insufficient
to attribute delay to Jetstream or select a runtime change.
There is no new Kiri parity verdict. Independent PR review is separate.

Next Action: Use SPEED-047 to resolve transport and guest timing
within the retained stack before proposing any runtime change.

### SPEED-027

Title: Trace the release native Docker CLI critical path

Description: Add diagnostic timing to the current adapter and a single-run transcript collector.

Is blocked by task: SPEED-018 (DONE); uses the frozen release comparison at cabbea9. Does not wait for legacy benchmark completion.

Acceptance Criteria:

- Capture negotiation, create, attach headers, start, native admission, terminal state, output EOF, wait response and client exit for pinned Alpine true and a stdout/stderr exit-23 canary.
- Record request counts, connections, thread handoffs and monotonic host spans; keep guest clocks separate. Compare direct API and CLI traces and quantify tracing overhead.
- Publish a ranked latency attribution with measured spans and unresolved gaps; do not attribute the whole CLI deficit to Python without evidence.

Problem and Evidence: Release API median already leads Kiri, while CLI median trails by 7.6%; the remaining ~1–2 ms is not yet attributed.

Approach:

1. Instrument the existing native Docker handler and collect one diagnostic pair plus untraced controls.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Built the optimized Swift CLI, Jetstream and ARM64 musl guest
with the environment runbook commands from `cf0a94e`. Ran
`python3 build-support/run-conjet-speedup.py --diagnostics {control,trace}`
with the pinned release assets in control/trace/trace/control order, then
`python3 benchmarks/native-docker-diagnostic.py` on the four output folders.
All 704 operations (640 measured, 64 warmups) verified unique native workload
IDs and completed cleanup. Each CLI canary checked exact streams and exit code.
`python3 benchmarks/test-native-docker-adapter.py` passed four tests.
Build logs, artifact hashes, complete command vectors, observations and
cleanup records are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-027`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[diagnostic results](docker-benchmark-results.md#speed-027-native-docker-critical-path-diagnostics),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated runtime checks passed. Trace capture is opt-in,
bounded and flushed after handler shutdown. All four launchers verified unchanged
production and removal of the owned VM session and Docker socket. This is a
headless diagnostic and uses JSON evidence. Independent PR review is separate.

Next Action: Reuse the authenticated connection in SPEED-028 and repeat both
diagnostic canaries to measure the change in handshake count and latency.

### SPEED-028

Title: Reuse a boot-bound authenticated native channel

Description: Change the adapter connection owner to reuse its native channel across sequential Docker launches.

Is blocked by task: SPEED-027.

Acceptance Criteria:

- Authenticate once per verified boot generation; retain operation identity and sequence checks and explicit channel ownership.
- Test idle reuse, guest reboot, disconnect before and after admission, cancellation and timeout. Never resubmit an ambiguous Launch; reconcile or fail closed.
- Compare handshake count and authentication span against SPEED-027 using the same canaries; reject a latency improvement that weakens isolation or increases unbounded resource use.

Problem and Evidence: Native.execute currently connects and authenticates for each launch; the measured authentication span is about 0.45–0.48 ms.

Approach:

1. Implement a bounded connection lease and boot-generation invalidation tests.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Used the `cf0a94e` release artifacts from SPEED-027 with the
updated adapter on `a4c5c8c`. Ran
`python3 build-support/run-conjet-speedup.py --diagnostics trace` three times
with the pinned release assets and summarized with
`python3 benchmarks/native-docker-diagnostic.py`. All 528 operations passed
with one authenticated connection per boot and unique native workload IDs.
The final boot reused the channel after 11 seconds idle. The six tests in
`python3 benchmarks/test-native-docker-adapter.py` passed, including injected
disconnect before reply, disconnect after admission, timeout, different
boot generation, and cancellation without replay. Exact commands, hashes,
observations and cleanup are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-028`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated runtime checks passed. One lease owns the
authenticated socket until shutdown or failure. Any failed exchange closes it
and preserves the pending launch identity. The adapter does not reconnect or
replay. The launcher verified guest cleanup, socket removal, and unchanged
production for all three boots. Fault injection used the adapter transport
boundary. Independent PR review is separate.

Next Action: Add bounded terminal output delivery in SPEED-029. The two
post-cleanup stream requests remain on every launch.

### SPEED-029

Title: Deliver terminal output without redundant round trips

Description: Add one bounded terminal/output delivery contract between the native guest client and Docker owner.

Is blocked by task: SPEED-028.

Acceptance Criteria:

- Reduce separate stdout/stderr fetch requests where terminal metadata or streaming can deliver them safely; include explicit EOF, exit and cleanup fields.
- Verify zero output, mixed streams, 64 KiB boundaries, overflow, slow reader, disconnected attach and nonzero exit.
- Removal remains after verified cleanup; cancellation and capacity reuse do not depend on an attach client consuming bytes. Record request-count and latency changes.

Problem and Evidence: The adapter fetches stdout and stderr after terminal cleanup and only then completes attach; extra requests are confirmed but their cost must be measured.

Approach:

1. Specify bounded terminal/output framing and implement its codec and lifecycle tests.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Rebuilt the release guest and VMM from the SPEED-029
working tree on `7fbc189` and reused the source-identical Swift release CLI.
Ran `python3 build-support/run-conjet-speedup.py --diagnostics trace` twice
with the pinned assets and summarized with
`python3 benchmarks/native-docker-diagnostic.py`. Both boots passed 176 standard
canaries and eight supplemental output and capacity checks each.
Ran `python3 benchmarks/test-native-docker-adapter.py`, guest `cargo test --locked`,
`cargo fmt --check`, and `cargo clippy --locked --target aarch64-unknown-linux-musl -- -D warnings`.
Commands, artifact hashes, tests, raw transcripts and cleanup records are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-029`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and runtime checks passed. Terminal wait carries a bounded
inline prefix and explicit EOF and truncation states. Exact 65,535- and
65,536-byte output passed through the real Docker CLI. Overflow returned an
explicit wait error and retained the observed guest exit. Slow and disconnected
attach clients did not block native teardown, removal or reuse. Both launchers
verified unchanged production and removed their sessions and sockets.
Independent PR review is separate.

Next Action: Port this contract to the Rust host in SPEED-030 while retaining
the Python adapter as the comparison reference.

### SPEED-030

Title: Port the supported Docker owner into the Rust host

Description: Implement the existing supported Docker API contract as a Rust host component, retaining Python as the comparison reference.

Is blocked by task: SPEED-029.

Acceptance Criteria:

- Pass the same request/response fixtures for negotiation, create/start/attach/wait/inspect/remove, errors and duplicate-start prevention.
- Use the persistent channel and terminal contract, bounded connection/admission counts, one lifecycle owner and explicit backend identity; do not add a second VM or legacy fallback.
- Package and launch the Rust owner by default for conjet-speedup without experimental opt-in; verify it needs no Python benchmark modules at runtime.
- Run matched release A/B against the Python reference; preserve timings even if the Rust port is not faster.

Problem and Evidence: The candidate Docker endpoint currently imports Python benchmark code and spawns connection/execution threads; it is not yet a packaged Rust runtime component.

Approach:

1. Create the Rust Docker module and transfer the narrow contract tests before switching the isolated launcher.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Built the release VMM and guest from the SPEED-030 working
tree on `f202be5` and reused the source-identical Swift release CLI. Ran
`python3 build-support/run-conjet-speedup.py --diagnostics control --docker-owner {rust,python}`
in Rust/Python/Python/Rust order with the same pinned release assets. Both
owners passed 176 standard canaries per boot and the shared output, inspect,
unsupported request, capacity, duplicate-start and forced removal checks.
An ordinary launcher smoke selected Rust without diagnostics or an owner
override. Jetstream `cargo test --locked` passed 139 tests with three existing
ignored tests. Rust formatting and Python adapter tests passed. Full
Jetstream Clippy stopped on existing PSCI discriminant and Hypervisor FFI
lints. A diagnostic run allowing those two existing lints completed.
Commands, hashes, initial keep-alive failure, repaired runs, and cleanup
are under `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-030`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and runtime checks passed. The Rust owner binds one
private endpoint, caps admission and request handlers, and holds a single
authenticated guest connection. The launcher confirmed the actual Rust
peer executable and native guest attribution. The default smoke path does
not load benchmark code. All runs verified removal of owned resources
and unchanged production. Independent PR review is separate.

Next Action: Stage a verified two-layer OCI image in SPEED-031.

### SPEED-031

Title: Stage a two-layer OCI image with whiteouts

Description: Extend native image admission from one layer to a pinned two-layer test image.

Is blocked by task: SPEED-030.

Acceptance Criteria:

- Verify manifest/config/compressed and uncompressed layer identities and deterministic layer ordering.
- Test file replacement, deletion whiteouts, opaque directories, symlinks and required hard links; reject traversal, escaping links, malformed archives and unsafe special entries.
- Run a dynamic ARM64 canary from the final immutable root and prove separate writable overlays do not mutate lower layers; failed staging removes owned partial state.

Problem and Evidence: The current single-layer package excludes ordinary multilayer application images needed by builds and Compose.

Approach:

1. Add a deterministic two-layer fixture and negative archive tests, then extend staging.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Built release Jetstream and the ARM64 guest from the SPEED-031
working tree on `4a19b0a`, with source-identical Swift CLI. Generated the
pinned two-layer fixture and ran 14 negative staging cases with
`python3 benchmarks/native-oci-two-layer.py`. Two independent staging runs
produced identical packages. The release launcher with `--diagnostics oci`
verified dynamic execution, inode identity, deletion and opaque whiteouts,
symlinks, writes through hard links, and fresh overlay isolation. Guest and
Jetstream tests, formatting checks, guest Clippy and existing Python
admission tests passed. Full Jetstream Clippy retains the SPEED-030 baseline
errors. Commands, source and artifact identities, failed pilots and verified
live results are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-031`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated runtime checks passed. The archive pipeline
verifies all four digest boundaries and publishes a complete directory
exclusively. Both failed and successful live launchers verified unchanged
production and session cleanup. The final OCI test checked the same inode
for both names, alias mutation within one workload, and original data in
the next workload. The workload retains the existing capability and
syscall restrictions. Independent PR review is separate.

Next Action: Integrate verified root staging with native pull. The current
guest only selects an OCI image at boot. Resolve live image installation
in SPEED-032A before exposing Docker pull.

### SPEED-032A

Title: Install a verified OCI root into an already booted guest

Description: Add a generation-bound, bounded installation path for the pinned
two-layer fixture, with an explicit image identity for launch selection.

Is blocked by task: SPEED-031 (DONE).

Acceptance Criteria:

- On one live native boot, install the staged two-layer fixture through the
  authenticated owner and run its canary with the original boot ID.
- Reject stale boot IDs, invalid offsets, wrong digests, exceeded quotas,
  and removal of a referenced lower root. Verify that interrupted transfers
  create no runnable image and that retries cannot disturb existing roots.
- Preserve original boot image execution, hard-link behavior, independent
  writable overlays, and guest cleanup.

Problem and Evidence: SPEED-031 delivers verified roots at boot. The existing
guest admits exactly one configured digest and uses a fixed OCI lower path.
Docker pull needs a runnable image in an already authenticated guest.

Approach: Add a single bounded transfer lease, verify before publication,
and bind the resulting lower root to the launch image digest.

Evidence: DONE. Rebuilt the release guest and VMM from the working tree on
`0096f36` and reused the source-identical Swift CLI. Ran the private
launcher with `--diagnostics oci-import` and the pinned SPEED-031 fixture.
The Rust installer transferred, verified, and published the package into
the same authenticated boot. The negative cases checked stale generation,
capacity, wrong offset, bad hash, a foreign connection, and disconnect
before commit. Live checks verified referenced-root rejection, removal
after cleanup, rejection of requests for the removed digest without
admission, and original boot-image execution after removal. The imported
fixture's hard-link and writable-overlay canaries passed through Docker.
Formatting, guest and Jetstream tests, guest Clippy, and the Python adapter
tests passed. Jetstream Clippy retains its baseline PSCI and FFI errors.
Exact commands, hashes and launcher evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-032A`.

Source: [Launch service contract](launch-service-contract.md),
[`fresh_fixture.rs`](../../guest/launch-service/src/fresh_fixture.rs),
[`sandbox_fixture.rs`](../../guest/launch-service/src/sandbox_fixture.rs).

Review: Local runtime and diff checks passed. Transfer ownership follows
the authenticated connection and boot generation. Bounds cover image
count, staged bytes, frame size and time. Publication requires a complete
verified package. A lost commit reply requires Inspect rather than replay.
The launchers verified unchanged production and removed their sessions
and sockets. Independent PR review is separate.

Next Action: Integrate this guest protocol with Docker pull and the
ExternalSSD content store in SPEED-032.

### SPEED-032

Title: Implement native image pull, inspect and removal

Description: Connect the native Docker image endpoints to a bounded content-addressed store on ExternalSSD.

Is blocked by task: SPEED-032A.

Acceptance Criteria:

- Pull the pinned small and multilayer fixtures from a task-owned registry; expose verified identity through Docker inspect and launch the pulled image.
- Test cached pull without duplicate extraction, digest mismatch, interrupted download and retry, shared-layer reference counts, and deletion while an image is in use.
- Track image/VM backing paths and remove only unreferenced task-owned content; do not shell out to the existing Docker engine to prepare the candidate image.

Problem and Evidence: Pre-admitted images bypass acquisition; native pull cannot be represented by the historical legacy image timings.

Approach:

1. Implement digest-addressed download/admission and Docker image inspect using the SPEED-031 fixtures.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Built the release Rust owner on `47e7b65` and reused the
source-identical release Swift CLI and guest supervisor. Generated and
verified the pinned registry fixtures with
`python3 benchmarks/native-docker-registry.py`, then ran
`python3 build-support/run-conjet-speedup.py --diagnostics registry`.
Unmodified Docker verified pull, inspect, run and removal for both
fixtures. Corrupted and interrupted transfers retained no partial image.
The cached pull made no registry request and retained the staged package
inode. Pulling and deleting the related image preserved the shared layer,
and deleting the final image freed all fixture blobs. In-use deletion,
mutable references and off-allowlist references were rejected. Jetstream
tests and Rust formatting passed. The existing Clippy errors are recorded
in SPEED-030. Commands, requests, hashes, prior pilot and final evidence
are under `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-032`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated runtime checks passed. Host registry
traffic is confined to the explicit loopback endpoint and the pinned
content is verified before native guest admission. The launcher checked
ExternalSSD backing, native execution, production preservation, and
cleanup of its registry, sockets, guest and image store. The store does
not qualify general registry authorization, tags, or image indexes.
Independent PR review is separate.

Next Action: Separate per-workload guest resource ownership before increasing
admission in SPEED-033.

### SPEED-033A

Title: Give each native OCI workload its own guest resource paths

Description: Scope the writable overlay, cgroup mount and cgroup tree to
one native workload ID before allowing overlapping lifecycle records.

Is blocked by task: SPEED-032 (DONE).

Acceptance Criteria:

- Observe two successive real OCI workloads with different populated
  cgroup and overlay paths derived from their workload IDs.
- Verify complete removal of owned paths after cancellation and failed
  execution. Keep the static fixture's existing recovery paths working.

Problem and Evidence: Until SPEED-032, OCI launches reused the static
fixture's fixed guest overlay directory and cgroup mount and tree.
Overlapping helpers would conflict at those resources.

Approach: Use identity-derived resource paths for native OCI, and assert
their absence before terminal cleanup acknowledges removal.

Evidence: DONE. Rebuilt the release ARM64 guest on `7104f53` and ran
`python3 build-support/run-conjet-speedup.py --diagnostics oci-import`.
The two sequential hold canaries each observed a populated cgroup and
present overlay at their distinct paths, then verified cancellation and
cleanup. A missing executable returned failed exec and completed cleanup.
The subsequent Docker hard-link and writable-overlay canaries passed.
Guest formatting, tests and ARM64 Clippy are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-033A`,
along with launcher commands, hashes, and raw witnesses.

Source: [Launch service contract](launch-service-contract.md),
[`kernel_fixture.rs`](../../guest/launch-service/src/kernel_fixture.rs),
[`sandbox_fixture.rs`](../../guest/launch-service/src/sandbox_fixture.rs).

Review: Local diff and isolated runtime checks passed. Both successful and
recovery paths address the exact workload ID. The launcher verified unchanged
production and removed its guest and socket. The owner still admits one
workload. Independent PR review is separate.

Next Action: Bound independent intent records in SPEED-033B.

### SPEED-033B

Title: Persist an independent OCI intent for each workload ID

Description: Bind the OCI helper's startup and restart recovery to
its own durable intent record.

Is blocked by task: SPEED-033A (DONE).

Acceptance Criteria:

- Retain two independent intents in a bounded inventory and remove
  exactly the one whose owner has confirmed cleanup.
- Fail closed on corrupt or mismatched intent data. Verify the helper
  opens the scoped intent before allocating resources.
- Pass the isolated OCI cancellation, failed-exec and cleanup canaries
  with the scoped intents.

Problem and Evidence: The guest's original one-file intent serialized
all workloads, even after resource paths became independent.

Approach: Qualify OCI intent paths by workload ID, then have the guest
supervisor reconcile the validated inventory after losing its child service.

Evidence: DONE. Ran guest `cargo test --locked`, formatting and ARM64 Clippy.
The inventory test verifies two simultaneous intents and corrupt-record
rejection. Built the release guest on `bc2c1f8` and ran
`python3 build-support/run-conjet-speedup.py --diagnostics oci-import`.
An initial live failure exposed a stale helper lookup of the legacy filename.
The corrected pilot passed launch, cancellation, failed-exec cleanup and
overlay checks. Logs, artifact hashes, and both launcher outcomes are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-033B`.

Source: [Launch service contract](launch-service-contract.md),
[`intent.rs`](../../guest/launch-service/src/intent.rs),
[`recovery_fixture.rs`](../../guest/launch-service/src/recovery_fixture.rs).

Review: Local diff and runtime checks passed. Intent reservation precedes
helper allocation and intent deletion follows owned-resource verification.
Restart inventory reconciliation was reviewed. The OCI live checks did not
kill the supervisor. Production snapshots matched and sessions were removed.
Independent PR review is separate.

Next Action: Qualify simultaneous admission through the guest protocol
in SPEED-033C.

### SPEED-033C

Title: Admit eight independent workloads in the OCI guest supervisor

Description: Replace the guest's single lifecycle slot with a bounded
OCI record table and scope helper recovery to each workload.

Is blocked by task: SPEED-033B (DONE).

Acceptance Criteria:

- Admit 1, 2, 4 and 8 simultaneously populated native workloads with
  distinct resource paths. Reject a ninth without consuming a sequence.
- Preserve exact replay of an admitted operation, reject conflicting
  replays, and cancel each workload without disturbing its siblings.
- Verify complete cleanup for each workload and preserve the guest's
  static fixture and Docker owner admission surfaces.

Problem and Evidence: Unique resource paths and persistent intents
enabled independent ownership. The guest ledger still stored one active
record and assumed a global reaper for failure after helper startup.

Approach: Route updates and protocol calls by native handle, reserve
eight active records and bounded terminal history, and isolate each
native helper's process group for recovery.

Evidence: DONE. Built the release guest and VMM on `063a4aa`. Ran
`python3 build-support/run-conjet-speedup.py --diagnostics oci-import`
with the expanded guest-overlap checks. Observed the full live 1/2/4/8
admission sweep, ninth-request rejection, unchanged sequence on rejection,
exact and conflicting replay, and independent cancellation and cleanup.
The Docker owner subsequently ran the pinned fixture in the same boot.
Guest tests, ARM64 Clippy, formatting and Jetstream tests passed.
Logs and release hashes are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-033C`.

Source: [Launch service contract](launch-service-contract.md),
[`fresh_fixture.rs`](../../guest/launch-service/src/fresh_fixture.rs).

Review: Local diff and isolated checks passed with production unchanged
and owned guest/socket removed. The concurrency sweep exercised the
authenticated guest API. It did not run the Docker lifecycle sweep,
force supervisor failure, or qualify pressure behavior. Independent PR
review is separate.

Next Action: Expose the verified admission capacity through the Rust
Docker owner and implement stop, kill and restart in SPEED-033.

### SPEED-033

Title: Replace the single workload slot with bounded lifecycle records

Description: Implement native create/start/wait/stop/kill/restart/remove for up to eight admitted containers.

Is blocked by task: SPEED-033C (DONE).

Acceptance Criteria:

- Give each workload independent rootfs, cgroup, handle, output and cleanup state; bound metadata retention and return explicit capacity errors.
- Test concurrency 1/2/4/8, name conflicts, create without execution, start replay, stop timeout, kill, restart with a new execution generation and forced removal.
- Reconstruct or safely invalidate records after VM/channel loss without duplicate execution; no mount/cgroup/process leaks and no cross-workload data access.
- Support only fixture-required credential and syscall extensions, with negative privilege tests; never enable unrestricted guest-root execution as a shortcut.

Problem and Evidence: One active workload cannot run Compose dependencies, persistent services or a BuildKit worker with application checks.

Approach:

1. Implement the bounded record table and per-record lifecycle transition tests.
2. Implement only the named capability or measurement group; validate failure paths and native backend attribution.
3. Review the diff and raw evidence, verify owned-resource cleanup and production preservation, then commit and push the validated increment.

Evidence: DONE. Rebuilt the optimized VMM and ARM64 guest on `67889de`.
Ran `python3 build-support/run-conjet-speedup.py --diagnostics concurrency`.
The final run observed 1/2/4/8 simultaneous populated guest workloads,
15 unique launch witnesses, byte-exact CLI output, complete cleanup and
a ninth-create rejection. The earlier seven-workload result exposed the
VMM bridge limit of eight streams including the diagnostic connection.
The control fixture verified create without execution, name and start
replay rejection, SIGTERM exit 42, timeout escalation and SIGKILL exit 137,
restart with the same Docker ID and new native handle, and the prior wait
subscription receiving its original exit status. The separate
`--diagnostics concurrency-loss` run killed only the owned QA VM after
confirmed exec. It verified unresolved wait status 125 and rejected both
replay and new admission. The failed cleanup boundary remains in the
launcher report, with independent exact host-artifact reclamation after
the process stopped. Commands, hashes and raw outcomes are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-033`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local code and runtime review passed. Admission stays serialized
for monotonic request identities. Eight boot-verified leases bound the
workers and reuse idle connections. The Docker owner's retained execution
generations keep wait subscriptions bound through restart. Production
snapshots matched. Abrupt VM loss left guest cleanup unobservable.
Ordinary cancellation and removal checks verified exact cleanup.
Independent PR review is separate.

Next Action: Implement persistent native exec and live attach/log streaming
in SPEED-034.

### SPEED-034A

Title: Publish bounded native output before terminal cleanup

Description: Make captured guest stdout and stderr available by cursor
while the OCI workload is still running.

Is blocked by task: SPEED-033 (DONE).

Acceptance Criteria:

- Observe both streams before terminal EOF on a real running OCI workload.
- Bound idle readers and retention at 64 KiB per stream. Drain overflow
  even when nobody reads, and preserve explicit EOF and cleanup witnesses.

Problem and Evidence: The guest drained both pipes but returned the
captured bytes to the lifecycle record only after helper exit.

Approach: Publish each bounded capture chunk directly to its owning
record and let an authenticated Output follower wait by cursor and deadline.

Evidence: DONE. Ran guest formatting, tests and ARM64 Clippy, built the
release guest on `3d645bc`, and ran the private launcher with
`--diagnostics oci-import`. Both channels returned their expected
bytes while the workload was live, waited for additional output with a
short deadline, and returned EOF after verified cleanup. A separate
unread 65 KiB stream retained 64 KiB, reported 1 KiB dropped, and
completed cleanup. Logs, exact commands, and release hashes are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-034A`.

Source: [Launch service contract](launch-service-contract.md),
[`output.rs`](../../guest/launch-service/src/output.rs).

Review: Local diff and isolated checks passed. Capture memory and
transport wait capacity remain bounded. This verifies the guest
protocol; Docker live attach/log delivery and exec remain open.
Production snapshots matched, with session and endpoint removal.
Independent PR review is separate.

Next Action: Wire bounded live output into the Docker endpoint in SPEED-034B.

### SPEED-034B

Title: Stream native stdout and stderr through Docker attach and logs

Description: Feed bounded guest output to Docker subscribers while the
workload is running, with independent stream cursors and explicit overflow.

Is blocked by task: SPEED-034A (DONE).

Acceptance Criteria:

- Read exact stdout and stderr through unmodified Docker attach and
  `logs --follow` while the workload is still running, then verify exit,
  final bytes and cleanup.
- Return 64 KiB of retained data and an explicit overflow error, and
  demonstrate that a slow or disconnected subscriber cannot prevent cleanup.

Problem and Evidence: Guest capture exposed live bytes after SPEED-034A.
The Docker owner still waited for the complete terminal result before
writing any output to its clients.

Approach: Carry optional cursors in the existing native wait call,
preserve the per-run capture and write Docker frames outside the
lifecycle lock.

Evidence: DONE. Built release guest and Jetstream from the working tree
on `cdf5753`. Ran `python3 build-support/run-conjet-speedup.py
--diagnostics streaming` and `--diagnostics control` in separate boots.
The unmodified CLI received early and late stdout and stderr through
attach and live logs. The attach command returned 23. Log replay retained
exact output, and a 65 KiB fixture returned exactly 64 KiB plus an explicit
failure. The control suite verified empty output, mixed streams, output
boundaries, slow readers and disconnects. Guest tests, ARM64 Clippy,
formatting and Jetstream tests passed. Commands and raw evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-034B`.

Source: [Adapter contract](docker-native-adapter.md),
[`http.rs`](../../jetstream/src/native/docker/http.rs).

Review: Local diff and live checks passed. The host maintains independent
cursors and bounded subscriber writes. Terminal cleanup remains the
condition for successful removal. Both launchers verified unchanged
production and removal of their guests and sockets. Independent PR
review is separate.

Next Action: Implement persistent exec in an already-running OCI workload
and qualify its isolation and exit semantics in SPEED-034.

### SPEED-034

Title: Add native exec and bounded live attach/log streams

Description: Implement Docker exec and streaming output for one running native service fixture.

Is blocked by task: SPEED-034B (DONE).

Acceptance Criteria:

- Use the existing exec/control fixture with matching argv, environment, cwd and supported credentials; preserve stdout/stderr and actual exit status.
- Deliver output before process completion with bounded buffers and backpressure; test slow/disconnected readers, cancellation and overflow reporting.
- Verify container survival after exec failure, multiple bounded exec requests, and cleanup of exec children on container removal.
- Implement only the noninteractive stdin/TTY behavior declared in the fixture contract; reject unsupported options rather than returning synthetic success.

Problem and Evidence: SPEED-034B delivered live attach and logs. Exec
needed a process inside the existing workload namespaces and cgroup.
Removing a workload during exec exposed a zombie in the exec process group.

Approach: Tie Docker exec records to a single container run generation.
The guest uses the live workload's pidfd to join its namespaces and
cgroup. The wrapper applies the inherited execution context and reaps
children in its own process group on forced teardown.

Evidence: DONE for the declared noninteractive exec fixture. Built release
guest and Jetstream from the working tree on `c686267` and ran
`python3 build-support/run-conjet-speedup.py --diagnostics exec`.
The unmodified CLI verified the existing `sh -c` stream and exit-23
command, inherited env and cwd, UID 65532, reads from the live overlay,
and actual exit 127 for a missing binary. A duplicate exec start caused
one side effect. The fixture verified timeout, explicit overflow at an
8 KiB combined bound, container survival, and verified removal during
exec. Live attach, logs, backpressure and disconnect evidence is in
SPEED-034B. Raw results, failed pilots, launcher arguments, and hashes
are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-034`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff and isolated checks passed. One guest exec slot,
bounded host records, and run-identity checks prevent exec replay or
retargeting. The final exec pilot recorded unchanged production, removed
the owned session and socket, and reported no cleanup errors. The
larger control matrix is measured separately in SPEED-042. Independent
PR review remains required.

Next Action: Connect two independently owned OCI workloads to a private
bridge in SPEED-035.

### SPEED-035A

Title: Verify independent peer allocation on a shared guest bridge

Description: Add a bounded guest bridge port owner and prove that two
separate Linux network namespaces can exchange TCP traffic while their
links retain independent ownership.

Is blocked by task: SPEED-034 (DONE).

Acceptance Criteria:

- Exchange exact TCP canaries between two peers on one guest-only bridge.
- Force failure after a veth is created, verify rollback, then allocate
  that address again while a sibling listener remains usable.
- Verify deletion of the bridge and both sets of ports and addresses,
  with no network device on the VM's guest-to-host boundary.

Problem and Evidence: The existing launch fixture attached one peer per
bridge. It used the bridge helper itself as the TCP destination.

Approach: Reuse route netlink requests and keep eight independent slots
with their own interface indices and namespace descriptors. Roll back
partial allocations and verify teardown in both namespaces.

Evidence: DONE. Ran guest format, tests and ARM64 Clippy. Built release
Jetstream and ARM64 guest from the working tree on `51ab17a`.
`python3 benchmarks/native-shared-bridge.py` verified two TCP exchanges,
partial allocation rollback, address reuse, clean PSCI shutdown and
zero virtio network backends. The successful run and initial harness
failure are retained with commands, artifact hashes and cleanup results
under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-035A`.

Source: [Bridge owner and fixture](../../guest/launch-service/src/bridge_fixture.rs),
[isolated proof runner](../../benchmarks/native-shared-bridge.py).

Review: Local diff and live check passed. The proof uses trusted guest
subprocesses and covers the link primitive. Native OCI ownership and
Docker DNS remain in SPEED-035. Production snapshots matched and owned
scratch was removed. Independent PR review remains required.

Next Action: Give each bridge lease a scoped DNS name in SPEED-035B.

### SPEED-035B

Title: Bind private DNS aliases to peer leases

Description: Resolve a service name to a live bridge peer without an
external resolver or DNS forwarding.

Is blocked by task: SPEED-035A (DONE).

Acceptance Criteria:

- Resolve a service alias using UDP from a second guest network namespace
  and connect to the returned address.
- Reject case-insensitive duplicate aliases, malformed questions and
  requests outside the bounded DNS message format.
- Remove the DNS record on detach, including when a replacement reuses
  the address.

Problem and Evidence: The existing single-peer fixture answered only one
hardcoded name with the bridge gateway address.

Approach: Serve authoritative A records from the bounded peer table.
Reserve an alias only once link setup succeeds and answer only requests
from live peers. Return NXDOMAIN for an absent name.

Evidence: DONE. Guest tests cover mixed-case lookups, AAAA with no IPv6
answer, NXDOMAIN and malformed messages. ARM64 Clippy and the release
guest build passed. `python3 benchmarks/native-shared-bridge.py` on
`9249789` plus this change verified mixed-case DNS, TCP via the returned
address and NXDOMAIN for the detached peer after address reuse.
Boot output, commands, artifact hashes and cleanup are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-035B`.

Source: [Guest DNS responder](../../guest/launch-service/src/bridge_dns.rs),
[bridge fixture](../../guest/launch-service/src/bridge_fixture.rs).

Review: Local diff and isolated checks passed. The guest had zero virtio
network backends and powered off cleanly. Production was unchanged and
the launcher removed its owned scratch directory. Docker network
ownership remains open. Independent PR review remains required.

Next Action: Route private bridge peer leases and resolver configuration
through the real OCI workload supervisor in SPEED-035C.

### SPEED-035C

Title: Attach the private bridge to native OCI processes

Description: Launch two pinned Linux ARM64 Alpine workloads through the
authenticated OCI lifecycle and exchange DNS and HTTP traffic.

Is blocked by task: SPEED-035B (DONE).

Acceptance Criteria:

- Resolve a supplied alias and obtain the exact HTTP canary from a
  sibling OCI workload. Reject invalid and duplicate aliases before admission.
- Verify that a no-network workload cannot reach the bridge. Confirm
  terminal link cleanup and NXDOMAIN when the service alias is removed.
- Release all guest bridge resources at orderly session shutdown.

Problem and Evidence: The guest bridge and DNS tests used trusted
subprocesses. The OCI workload supervisor had no shared peer handoff.
The first Alpine tests also exposed the resolver's AD request flag and
musl's use of `recvmsg` to read its UDP answers.

Approach: Pass the new network namespace descriptor from the helper to
the owning supervisor before releasing the OCI start barrier. Bind
each port and resolver alias to the admitted workload identity. Scope
resolver writes to its private overlay and apply socket allowances only
to bridged workloads.

Evidence: DONE. Release build and isolated diagnostics on `5c2488d` plus this
change passed `run-conjet-speedup.py --diagnostics guest-bridge`. Two
transactions returned the same exact fixture body. Invalid and duplicate
aliases consumed no admission sequence. The separate `--diagnostics exec`
regression check passed with the same guest build. A no-network workload was
denied a socket and a later peer received NXDOMAIN for the removed
service. Artifact hashes, adverse pilots, exact commands and verification
logs are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-035C`.

Source: [Launch service contract](launch-service-contract.md),
[guest OCI canary](../../benchmarks/native-oci-bridge.py).

Review: Local diff and isolated checks passed. Workload teardown releases
the scoped link before removal acknowledgement. Orderly shutdown
stops the DNS thread and verifies disposal of the bridge.
Production snapshots matched and the owned VMM, session and Docker
socket were removed. Independent PR review remains required.

Next Action: Expose one named bridge and its attachments through the
Docker API and exercise it with the Docker CLI in SPEED-035.

### SPEED-035

Title: Connect native containers to one private bridge and DNS

Description: Wire the verified guest bridge implementation to native Docker network ownership.

Is blocked by task: SPEED-035C (DONE).

Acceptance Criteria:

- Run two pinned native containers on a task-owned bridge and resolve one service name to the other; verify DNS and a TCP transaction.
- Expose the required create/connect/disconnect/inspect/remove network operations and aliases; reject unsupported network options.
- Test allocation rollback, address reuse, concurrent cleanup and namespace isolation. Confirm removal of owned veth, routes, addresses and DNS records.
- No legacy networking owner or production interface may satisfy the fixture.

Problem and Evidence: SPEED-035C connected real OCI workloads. Docker
still required an explicit network owner and operations for guest teardown.

Approach: Expose one named internal bridge on the Rust Docker owner.
Validate its attachments before container admission. Send live peer
changes to the authenticated guest using the current workload handle.
Return success from network removal only after guest teardown.

Evidence: DONE. Built release guest and Jetstream from the working tree
on `4d4a212`. Ran `run-conjet-speedup.py --diagnostics docker-network`,
`guest-bridge`, and `control` in separate private VM boots. The
unmodified Docker CLI ran the pinned Alpine DNS and HTTP transaction,
inspected a bridge with two live endpoints, disconnected and reconnected
a live peer, observed NXDOMAIN and then address reuse, removed two peers
concurrently, and removed and recreated the network. Malformed options,
a duplicate alias, a second bridge, and removal with attached
containers were rejected. Guest link, address and route checks passed
before teardown. The earlier SPEED-035A failure injection verified
partial allocation rollback. Test logs, commands, artifact hashes and
raw outcomes are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-035`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff, guest and Jetstream tests, ARM64 guest Clippy and
isolated checks passed. The verified Docker scope is one internal IPv4
bridge and one alias per endpoint. Live attach requires a workload
started with bridge permissions. The launchers verified unchanged
production and removed their task-owned processes, sessions and sockets.
Independent PR review remains required.

Next Action: Forward one loopback TCP port to a scoped native target
in SPEED-036A.

### SPEED-036A

Title: Verify a bounded authenticated TCP relay to a native workload

Description: Connect one authenticated native stream to an active
workload's owned bridge endpoint. Preserve bytes and both half-closes.

Is blocked by task: SPEED-035 (DONE).

Acceptance Criteria:

- Deliver a stream to a real pinned OCI listener using its boot and
  workload identity. Reject invalid ports, stale boots and refused targets.
- Preserve byte integrity above the relay's retained memory bound and
  propagate EOF before the guest sends its reply.
- Saturate the two relay slots, close a client, and verify the remaining
  stream and subsequent workload cleanup.

Problem and Evidence: The private guest bridge has no network device
leading to the host. The existing authenticated native control connection
has no workload-scoped TCP byte stream.

Approach: Add a one-way protocol upgrade from an authenticated Dial
request to a bidirectional stream. Resolve the destination from the
workload's live bridge lease. Use a fixed 8 KiB buffer per direction and
bound guest slots, dialing and idle waits.

Evidence: DONE. Guest relay tests passed a 1 MiB half-close transfer and
cancellation and idle checks. ARM64 guest Clippy and the release build
passed. On `234e513` with the release guest change,
`run-conjet-speedup.py --diagnostics tcp-relay` passed a 131,073-byte
round trip after request EOF, invalid port, stale boot, refusal, cap
exhaustion, disconnected client and guest cleanup. Logs, commands and
artifact hashes are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-036A`.

Source: [Launch service contract](launch-service-contract.md),
[bounded relay](../../guest/launch-service/src/relay.rs).

Review: Local diff and isolated checks passed. The destination IP
comes from the current guest lease. The launcher verified unchanged
production and removed its session and Docker socket. Host loopback
listeners and Docker port inspection remain in SPEED-036.
Independent PR review remains required.

Next Action: Bind the loopback listener to Docker lifecycle ownership
and verify publication and teardown in SPEED-036.

### SPEED-036

Title: Publish one native container port on host loopback

Description: Implement a scoped loopback port mapping for the Node/Redis application fixture.

Is blocked by task: SPEED-036A (DONE).

Acceptance Criteria:

- Map an allocated 127.0.0.1 host TCP port to the native application; verify HTTP response contents and Docker inspect metadata.
- Test bind conflict, refused destination, client disconnect, half-close and container restart/removal; bound connections and buffered bytes.
- After removal, verify listener closure and immediate port reuse. Do not use wildcard binds or change production port mappings.

Problem and Evidence: SPEED-036A provided the guest TCP transport.
Docker still needed a scoped host listener, port metadata and restart
ownership.

Approach: Bind one requested or ephemeral IPv4 loopback port to the
container record. Forward to the authenticated guest's current workload
handle after exec confirmation. Revoke that target at exit and wait
for host relay teardown before acknowledging removal.

Evidence: DONE. Built release Jetstream on `74f73cd` plus the host mapping.
`run-conjet-speedup.py --diagnostics published-port` verified the
unmodified CLI, exact HTTP from pinned Alpine after half-close, bind
conflict, wildcard rejection, guest refusal, disconnect, the same
host port across restart, removal during an open stream, closure and
immediate port reuse by a new workload. Docker inspect reported the
effective loopback binding. The separate `docker-network` regression
passed. Commands, revisions, hashes and raw evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-036`.

Source: [Native Docker speed plan](native-docker-speed-plan.md),
[adapter contract](docker-native-adapter.md),
[benchmark contract](docker-benchmark-plan.md),
[detailed result format](docker-benchmark-results.md),
[environment runbook](speedup-environment.md).

Review: Local diff, format, guest and Jetstream tests, focused Jetstream
Clippy, and isolated checks passed. The published path allows one
127.0.0.1 TCP mapping with up to two concurrent streams. The
Node/Redis Compose fixture remains in SPEED-039. Both boots verified
unchanged production, no remaining guest workloads and owned session
and socket removal. Independent PR review remains required.

Next Action: Add the private ExternalSSD block backing required by the
named-volume fixture in SPEED-037A.

### SPEED-018

Title: Qualify Docker-to-native routing before claiming Docker acceleration

Description: Implement and verify the Docker-compatible native route for the explicitly supported subset in the isolated candidate.

Is blocked by task: SPEED-017.

Acceptance Criteria:

- Write a supported Docker operation/option contract and single-owner lifecycle design before implementation. General Alpine/OCI execution requires verified image/rootfs admission and execution support, not a static-binary substitution.
- Support the selected real docker run lifecycle, including API negotiation, create/start, attach/output, actual exit status, wait conditions, inspect and removal. Test event ordering, names/IDs, cancellation and disconnect recovery.
- Record backend selection per container. Reject unsupported requests clearly or route them explicitly to the existing Docker backend before allocation/start; never silently ignore flags or retry after ambiguous execution.
- Verify isolation, bounded resources, image semantics and no leaks on success/failure. The isolated candidate defaults to native with no fallback. Ordinary production routing remains under the installed runtime.
- If integration is not viable within the declared subset, record an unavailable accelerated Docker lane and a reviewed follow-up implementation task. Benchmark existing Docker and native lanes separately; do not claim this benchmark work created Docker acceleration.

Problem and Evidence: [Supported adapter contract](docker-native-adapter.md). The initial
native executable-only profile rejected pinned Alpine's dynamic BusyBox.
The new immutable rootfs path verified the actual Alpine image config and
519-entry rootfs on both engines. Live OCI and unmodified Docker CLI checks
verified argv, env, working directory, UID, both output streams and exit 23,
backend attribution, forced removal, failure on unsupported options,
one-use Start under replay and client disconnect, terminal cleanup and absence
of owned sockets/directories. A separate 20-sample pilot ran each Docker
transport through the new adapter. Rust workspace tests, strict ARM64
guest Clippy, adapter tests and image validation tests passed. Retained
failed experiments and successful proofs are under ExternalSSD `SPEED-018`.
The native-first launcher booted release-optimized CLI, VMM and guest
binaries. `SPEED-018/native-default-build` retains the source revision,
logs and binary digests. The matched pilot verified distinct native workload
handles, guest cleanup, VM reclamation, removal of the private socket and
session directory, and an exact production snapshot match.
A TERM after smoke returned 143 and verified the same cleanup and
production checks in `SPEED-018/native-default-cancel/launcher.json`.
The Python adapter, image admission and benchmark suites passed 29 tests.

Subtasks:
- Validate and stage the pinned rootfs.
- Execute a bounded OCI process in the existing native sandbox.
- Default the isolated candidate to the native Docker owner and verify the actual Docker CLI lifecycle.
- Keep the supported subset explicit and preserve installed production routing.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Verified private peer binding, boot generation, bounded image staging,
container ownership, output and cleanup boundaries. Only the source-operated
no-network Docker subset qualifies. The wider Docker surface is unsupported.

Next Action: Extend measurements for the verified rootfs and option subset.
### SPEED-017

Title: Capture current Docker and native baselines

Description: Run a bounded pilot of the unchanged engines and native product before implementing an accelerated Docker adapter.

Is blocked by task: SPEED-016.

Acceptance Criteria:

- Capture direct Docker API and actual Docker CLI lifecycle on both engines, plus separately labeled native fresh/prepared timings for the same supported payload.
- Probe build, Compose, exec, volumes and networking capabilities; record unsupported/error outcomes explicitly and retain them in coverage.
- Record native preparation/refill and misses separately; retain original data and do not combine pilot samples with final qualification.
- Identify which Docker operations reach Docker/containerd and which, if any, reach the native service using runtime dispatch evidence.

Problem and Evidence: Under ExternalSSD `conjet-speedup-evidence/SPEED-017`, the initial
pair retained 240 measured and 120 warmup lifecycle records per Docker
engine, with zero failures. Both engines observed 16 MiB, 4 PIDs and a
500-millicore CPU quota inside the Alpine canary. Kiri reported VM memory
as zero in /info, so its guest memory total is unknown. Conjet's Docker
engine reported runc on the existing bridged Docker/containerd path;
Kiri reported its own runtime. The Docker API timings end at removal
acknowledgement. Separate native endpoint measurements verified cleanup
and reported fresh/claim/refill/miss separately. The follow-up Compose
probe verified a Redis write/read transaction through service DNS on each
engine. Image save and basic exec, volume and network probes passed.
Conjet's embedded BuildKit built and verified the canary. Kiri started a
private pinned BuildKit container; a build through it remains for SPEED-021.
The initial missing Compose applet error was preserved. Both launchers
verified production and shutdown.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Audited stream canaries, exit 23, cgroup observations, actual
engine identities and cleanup. Keep one-session pilot results out of the
qualifying distributions.

Next Action: Address OCI admission and runtime ownership in SPEED-018.

### SPEED-016

Title: Make the benchmark orchestrator safe and reproducible

Description: Extend the isolated launchers and reporting harness to execute the frozen suite serially with explicit engine identities.

Is blocked by task: SPEED-015.

Acceptance Criteria:

- Use private DOCKER_CONFIG and explicit contexts/endpoints: conjet-speedup for the candidate and kiri-speedup for Kiri. Identify actual binaries, servers, builders and VM disk holders; reject production endpoints.
- Store all images, volumes, build contexts, caches, logs and scratch artifacts on ExternalSSD; verify backing paths. Use unique labels, Compose project names and task-owned builders.
- Alternate engine order between paired sessions; run timing suites without overlapping builds or other benchmark engines. Preserve production and record its contention.
- Exercise interruption, timeout and partial-report recovery. Cleanup only owned resources; no global prune/context switch, persistent jobs or global credential changes. Verify production snapshots and no owned process/disk/socket holders.

Problem and Evidence: The isolated launchers now run the comparison coordinator with
pinned clients, a private context and an endpoint peer check. The serial
preflight passed in Kiri-then-Conjet order, verified that the actual VM
processes held only the designated backing files, and confirmed shutdown
and unchanged production. The first attempt established that Kiri can
answer metadata before its VM boots; the runner now uses an untimed pinned
launch before measuring disks. A one-second timeout stopped the owned Kiri
daemon and removed its socket while retaining partial evidence. Three new
safety tests and the five existing adapter tests passed. Evidence is under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-016`.
The coordinator can run all five frozen pairs under a single foreground
lock. New session reports record `/info` after VM readiness and probe the
container view of guest memory outside timing. A second verified backing
snapshot exposes allocated disk changes across the complete suite.

The release-build coordinator's cancellation check initially exposed an
inherited ignored SIGINT that prevented TERM from stopping the series. The
worker stopped the task-owned launcher and verified cleanup. The coordinator
now handles TERM directly. The repeated Kiri-first check returned 130,
retained 841 partial API samples, verified unchanged production and released
the daemon, socket and disk holder before a native launcher could start.
Evidence is in `SPEED-019/native-default-matched-kiri-cancel{,-fixed}`.
A post-fix pilot completed both lanes on both engines under
`SPEED-019/native-default-post-cancel-fix-pilot`. Its samples are excluded
from the five-pair series measured at `cabbea9`.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Checked mounted storage paths, process and context attribution,
serial pairing, cancellation, partial evidence and lease scope. Builder
execution and effective workload limits are checked by the workload probes.

Next Action: Run the SPEED-017 pilot with the frozen endpoints.

### SPEED-015

Title: Freeze the Docker comparison contract and capability matrix

Description: Create benchmarks/scenarios/docker-comparison-v1.json and docs/engineering/docker-benchmark-plan.md defining the workloads, adapters, timing boundaries, and qualification rules.

Is blocked by task: None; uses completed SPEED-000 through SPEED-012 evidence. Does not wait for SPEED-014.

Acceptance Criteria:

- List four separate lanes: official Kiri Docker API/CLI, existing Conjet Docker API/CLI, native fresh/prepared API, and any verified Docker-to-native adapter. Record supported/unsupported operations per lane; never substitute native execution for docker build or Compose.
- Pin official Kiri version/hash, candidate revision, ARM64 image digests, Docker/Compose/Buildx clients, guest resources, storage placement, network behavior, and cache policies. Record effective limits, not only requested values.
- Predeclare warmups, repetitions, concurrency, timeouts, failure treatment, session ordering and statistics. Lifecycle qualification retains at least 10,000 operations per scenario across five sessions; declare practical independent-session counts for expensive builds/Compose before measuring.
- Scope local conclusions to the M1 Pro. Preserve the deferred second-host, energy and equivalent-teardown requirements; unavailable observability must produce unknown, not pass.

Problem and Evidence: Previous comparisons mixed native and Docker endpoints; the experimental native product cannot yet run general OCI images, bridge workloads, or Docker commands.

Approach:

1. Inventory the existing harnesses and runtime capabilities without changing production.
2. Write the scenario manifest and an ASCII diagram for each execution path; identify integration gaps as separate implementation prerequisites.
3. Review the manifest against each requested Docker operation and freeze the initial measurement policy.

Evidence: [Frozen contract](docker-benchmark-plan.md) and [manifest](../../benchmarks/scenarios/docker-comparison-v1.json). Verified the installed Kiri signature and host client hashes. Resolved Docker Hub ARM64 child manifests through the registry and checked the HTTP digest against each index body. Baseline source is `7e075c0`. No timing samples were taken for this task.

Source: [Benchmark harnesses](../../benchmarks/README.md),
[environment runbook](speedup-environment.md),
[architecture and claim policy](speed-engineering-plan.md),
[experimental scope](speed-release-scope.md),
[prior qualification](speed-qualification.md).

Review: Checked the four execution paths, minimum lifecycle sample budget, paired-session resampling and separate timing boundaries against the previous gates. Unobserved cleanup and effective limits remain unknown.

Next Action: Apply the manifest in SPEED-016.

### SPEED-012

Title: Expose the qualified native launch mode and document release scope

Description: Integrate the passing native API, CLI, and status behavior; deliver E2E evidence, rollback instructions, and an explicit Docker-integration decision.

Is blocked by task: reviewed implementation through SPEED-007 and isolated
SPEED-009/SPEED-010 evidence (available). SPEED-011 local acceptance gates the PR.

Acceptance Criteria:

- Native API/CLI/status surfaces identify runtime owner, fresh/prepared mode,
  preparation costs, misses, and unsupported features clearly.
- Existing Docker/containerd behavior passes relevant regression checks.
- Screenshot-backed E2E validates affected user-visible surfaces using isolated resources.
- Docker routing is enabled only after a separately documented ownership and
  compatibility gate; otherwise retain the existing Docker lane and record follow-up scope.
- Document rollback, evidence-backed claims, remaining limits, and all temporary-resource cleanup.

Problem and Evidence: A fast prototype does not establish product compatibility,
operational readiness, or a safe unified Docker lifecycle.

Approach:

1. Expose runtime owner, launch mode, preparation state, misses, and errors through the selected native surfaces.
2. Run existing Docker regressions and isolated native E2E flows; capture screenshots for affected UI/status surfaces and test rollback.
3. Write docs/engineering/speed-release-scope.md with supported configurations and measured claims; leave Docker routing on its existing engine unless a separate compatibility gate is approved and passed.

Evidence: The 2026-11-23 scope revision separates local product and
release acceptance from the deferred comparative gates. Local and remote
development heads agreed at `3aaf062` before the revision. Reviewed the
original qualification criteria and retained evidence references.

The foreground native session exposes fresh, prepare, claim, status, cancellation,
memory pressure and stop through the authenticated API and `conjet native
--experimental`. Its Linux guest accepts a pinned static ARM64 executable with
no arguments or network. The host creates no Docker or memory socket in this
mode. CLI admission is nonblocking and it never resubmits an indeterminate
execution. The independent Docker lane retains its existing ownership.

M1 Pro validation used `swift test --build-system native` (440 tests, two
skips), `cargo test --locked --workspace` (159 passing, three entitlement
tests excluded from the default run), strict ARM64 Linux Clippy, Python
compilation and formatting. The strict host Clippy diagnostics also
appear on the archived `a9f06d9` baseline. The live product probe
(`benchmarks/native-product.py`) checked no-network isolation, fresh and
prepared execution, concurrent claims, eviction, active memory preservation,
bounded output, disconnect replay/cancellation, expiration and verified
cleanup. Its two guests both negotiated page reporting with zero
reclamation errors. The separate branch-built `conjet-speedup` Docker
smoke passed. Both launchers recorded matching production snapshots.
Logs, partial runs, raw samples, and Docker evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-012`.
The development timings were collected with other builds active. The
source implementation was pushed as `ff1877c`.

The release stage builds and bundles the static Linux guest beside the VMM.
An isolated ARM64 app and DMG built with the repository scripts passed
deep signature validation, byte comparison of the DMG-extracted CLI, VMM
and guest against staging, DMG verification, SHA-256 verification, and
Formula/Cask Ruby validation. `diskutil image attach --readOnly` mounted the
DMG on this macOS host after legacy `hdiutil attach` returned permission
denied. The local artifact used ad-hoc signing for rehearsal only.
Logs are in the SPEED-012 evidence directory. No app was registered or
launched. Final measurements use the packaged CLI and the app-sealed guest.

Source: [Architecture ownership](speed-engineering-plan.md#architecture-and-ownership),
[final recommendation](speed-engineering-plan.md#final-recommendation),
[repository instructions](../../AGENTS.md).

Review: Checked native endpoint ownership and key permissions, operation IDs
and replay, bounded admission and output, expiry, and guest/host cleanup.
Verified staged app and binary signatures, packaged/extracted byte matches
and a successful native run from the DMG layout with default tool resolution.
The changed surface is a JSON CLI and API with no graphical UI screenshot
target. A second mount attempt raised a system prompt, was canceled, and
the owned disk image was ejected. CI covers the mounted DMG contents.

Next Action: Carry the validated experimental runtime and release
documentation into SPEED-013.

### SPEED-011

Title: Run the qualification matrix and publish measured verdicts

Description: Create docs/engineering/speed-qualification.md linking raw reports and pass/fail results for each proposed performance claim.

Is blocked by task: SPEED-012 product path for local acceptance (DONE).
The deferred comparative matrix additionally requires SPEED-008.

Acceptance Criteria:

Required for experimental release: frozen M1 Pro product candidate,
reproducible fresh/prepared API and CLI samples, failures, refill, misses,
churn, CPU and memory observations, pressure and cleanup evidence, and
declared operating limits.

Deferred comparative research criteria:

- Follow the plan's minimum sample/session/hardware matrix and predefined statistical method.
- Report fresh, prepared, CLI, sustained churn, builds, and running-service scenarios separately.
- Include pool misses/refill, CPU, memory, energy, host contention, and memory pressure.
- Prepared sub-1 ms claims meet the declared p99 gate; fresh superiority meets
  equivalent-work latency and throughput gates without correctness regressions.
- Record go/no-go per claim; a missed target is reported honestly rather than concealed.

Problem and Evidence: The 1,000-microsecond budget is a research allowance, not a
measurement; neither fresh nor prepared superiority is established.

Approach:

1. Run the predeclared sample/session/hardware matrix for fresh, prepared, CLI, churn, builds, and services under reclaim.
2. Record preparation/refill, misses, failures, CPU, memory, energy, contention, and pressure; profile and change one demonstrated bottleneck at a time.
3. Evaluate the sub-1 ms prepared p99 gate and equivalent-work fresh superiority independently; document failed targets and uncertainty.

Evidence: The [local qualification report](speed-qualification.md) links
three M1 Pro packaged-candidate sessions, with safety canaries and 2,400
measured operations passing. The report records the exact executable
and kernel hashes, latency, refill, misses, throughput, CPU, RSS,
background contention and raw evidence. The 45-test Swift benchmark package, Go network race suite, and three
separately entitled memory/backing tests passed. The historical 2.478 ms prepared p99 was
recomputed from the retained raw samples. The comparative matrix remains
deferred with its original acceptance criteria and unresolved verdict.

Source: [Latency budget](speed-engineering-plan.md#experimental-latency-budget),
[claim policy](speed-engineering-plan.md#verification-and-claim-policy),
[benchmark package](../../benchmarks/README.md).

Review: Verified per-session nearest-rank results against raw samples,
cleanup boundaries, expected failures, and measured refill throughput.
Comparative work and its independent review are deferred.

Next Action: Carry the scoped evidence into SPEED-013. Resume comparative work when the deferred inputs become available.

### SPEED-010

Title: Connect launch-service cgroups to memory accounting and eviction

Description: Register active workloads and prepared reserves with the memory controller. Deliver pressure-eviction and allocation/free/reuse evidence.

Development prerequisite: SPEED-009 (DONE).

Final qualification prerequisites: SPEED-008 and the applicable SPEED-011 gates.

Acceptance Criteria:

- Controller telemetry distinguishes active workloads, prepared reserve, and empty scopes.
- Pressure destroys unused slots before reclaiming active demand; accounting is bounded.
- Existing ownership, host-granule, backing-release, and service-pressure safeguards remain valid.
- Exercise allocation/free/reuse, data canaries, pool eviction, rebuild, and launch after pressure.
- Measure idle footprint with/without slots and verify cleanup without disturbing installed services.

Problem and Evidence: Unregistered runtime cgroups could be mistaken for idle
capacity; prepared resources consume memory even when launch latency is low.

Approach:

1. Expose separate active and prepared cgroup telemetry with validity indicators; verify idle classification against live workloads.
2. Stop admitting slots and destroy unused slots under pressure; let existing ownership-based reclamation release backing.
3. Run live canaries through allocation/free, eviction, fresh fallback, and preparation rebuild; compare footprint with zero and populated slots.

Evidence: The isolated native controller now reports active and prepared
ownership separately, including sample validity, current cgroup charge,
population, and limit. A claimed reservation becomes active before release
and retains its cgroup until teardown. The authenticated pressure input
evicts unused slots and pauses preparation. The Docker-only idle controller
cannot classify the isolated native mode. Existing page ownership and
backing release paths are unchanged.

Two live boots verified eviction in 1.430 and 1.681 ms through cleanup,
explicit fresh work under pressure, and refill in 2.056 and 1.640 ms.
An active 8 MiB byte canary reported 8,642,560 charged bytes and survived
the pressure signal. The recorded claim/pressure race produced a single
winning claim and verified cleanup. VMM footprint increased by 49,152
and 81,920 bytes between empty and ready observations. The 50-operation
prepared regression, workspace tests, Linux ARM64 Clippy and Python
byte compilation passed. The initial too-large integer canary failures
and successful reruns are preserved under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-010`.
These runs used an authenticated pressure signal. The guest now also
fails closed on missing availability or less than 64 MiB. A separate
512 MiB disposable VM with a 72 MiB balloon target reported 25,894,912
available bytes and rejected preparation automatically while a fresh
workload executed and cleaned up successfully. The low-start test
verified automatic admission. Ready-slot eviction was exercised with
the authenticated pressure signal.

The final baseline, pressure and prepared regressions passed. Three
entitled tests separately exercised Linux free-page reporting and
uncorrupted reuse, partial backing release, and immediate HVF backing
release. The Linux reuse test recorded RSS falling from 137,904,128 to
69,566,464 bytes. Reports and binary identities are in
`SPEED-010/guest-availability` and `SPEED-010/backing-release`.
The experimental scope is one owned workload. Production adaptive policy
integration and competitive qualification remain gated.

Source: [Memory integration](speed-engineering-plan.md#dynamic-memory-integration),
[memory debugging](../dynamic-memory-debugging.md),
[backing reclamation](../jetstream-host-backing-reclaim.md).

Review: Checked accounting through cleanup, active protection at claim,
serialization with pressure, and the opt-in scope of the host guard.

Next Action: Keep local measurements experimental and prepare the final
qualification matrix. The paired preparation trace led to the preclaim sandbox experiment
recorded in SPEED-009.

### SPEED-009

Title: Implement prepare, claim, expire, and destroy for one-use slots

Description: Add explicit prepared-launch API operations and a bounded slot table. Deliver state-machine and isolation tests plus preparation/hit/miss measurements.

Development prerequisite: SPEED-007 (DONE).

Final qualification prerequisites: SPEED-008 and the applicable SPEED-011 gates.

Acceptance Criteria:

- Bind authenticated handles to image/specification digests, ownership, and generation.
- Atomically consume each slot once; executed slots are destroyed rather than recycled.
- Enforce slot count, memory, queue, lifetime, and preparation-concurrency bounds.
- Record preparation, hits, misses, expiry, and replenishment; miss fallback is explicit
  and occurs only before execution.
- Test concurrent claims, invalidation, cancellation, exhaustion, and no cross-run state leakage.

Problem and Evidence: Fresh resource setup may dominate latency; prepared execution
moves that cost earlier but creates memory and stale-state risks.

Approach:

1. Implement specification digest, owner and generation validation, and atomic READY-to-CLAIMED transition.
2. Create a private waiting init without running application code; consume once, then destroy the slot and its resources.
3. Enforce configured limits and expiry; test concurrent claims, stale handles, changed specifications, cancellation, exhaustion, and explicit fresh fallback before execution.

Evidence: The isolated no-network fixture implements authenticated prepare and
claim with one exclusive slot, no queue, a 32 MiB cgroup ceiling, a bounded
lifetime and explicit fallback. Two independent local boots each measured
100 post-warmup prepared launches. Preparation p50/p99 was 1.040/2.755
and 1.033/1.722 ms. Claim-to-exec observation p50/p99 was 1.512/2.709
and 1.500/2.484 ms. Verified cleanup p50/p99 was 2.231/4.421 and
2.126/3.775 ms from claim. Cancel and expiry misses took 0.360–0.470 ms
across the four checks. Preparation is charged again on every refill.

The two live runs verified credential, root and seccomp canaries,
simultaneous claims, replay, stale generation, changed spec, slot exhaustion,
cancellation, expiry and explicit fresh fallback after proven non-execution.
The final run also rejected requests above the experimental reserve limit
and checked distinct handles across refills. Fresh API and CLI regression
passed for both network modes. The 19 focused Rust tests, Linux ARM64
Clippy, Python byte compilation, formatting and diff review passed.
Raw samples, commands, binary hashes and production snapshots are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-009`.
These are local implementation checks. Final qualification remains open.

The follow-up experiment parks the trusted child with the private root
mounted, limits applied, and credentials dropped. Seccomp and exec
remain behind the claim. Two final boots measured 200 operations each.
The traced guest claim-to-exec median fell from 1.080 to 0.768 ms.
Untraced host claim-to-exec p50/p99 was 1.338/2.478 ms, with preparation
p50/p99 of 1.472/3.024 ms. Record the extra preparation cost explicitly.
Both runs passed the prepared safety cases. Fresh API/CLI, live pressure,
and the balloon guard passed on the revised guest. The final workspace
run passed 159 tests. The three ignored-by-default tests ran separately
with the required entitlement in SPEED-010. See
`SPEED-009/preclaim-sandbox` for raw runs and checks.

Source: [Prepared lane](speed-engineering-plan.md#prepared-launch-lane),
[latency budget](speed-engineering-plan.md#experimental-latency-budget).

Review: Checked serialized claim and release, pre-exec isolation, fail-closed
expired or indeterminate claims, verified cleanup, and repeat preparation costs.

Next Action: Wire experimental cgroup telemetry and pressure eviction in SPEED-010.

### SPEED-007

Title: Implement fresh bridge networking with verified teardown

Description: Add one private bridge mode with addresses, DNS, and the explicitly supported port behavior. Deliver network correctness and cleanup tests.

Is blocked by task: SPEED-006.

Acceptance Criteria:

- Implement the declared bridge, addressing, DNS, and port behavior or explicitly
  reject unsupported networking options.
- Verify identity isolation, traffic correctness, address reuse, and teardown under churn.
- API-visible removal and actual network cleanup are independently observable.
- No unbounded deferred cleanup or networking changes to the installed runtime.

Problem and Evidence: A no-network result cannot substantiate a bridge-network
win against Kiri; deferred veth cleanup changes the lifecycle boundary.

Approach:

1. Allocate network identity and interfaces as owned launch resources; unwind every partial failure.
2. Verify DNS, peer isolation, supported port traffic, concurrent address reuse, and rejection of unsupported network options.
3. Observe interface, address, DNS, and port cleanup before declaring cleanup complete; run repeated bridge launches with traffic canaries.

Evidence: The standalone ARM64 kernel fixture opened a new private
network namespace, used checked rtnetlink requests to create an IPv4 bridge
and move a veth peer into a second network namespace, and verified TCP
traffic from the assigned address. It removed the bridge and veth and
confirmed on both sides that their addresses could no longer bind.
Ten consecutive allocations reused the same address pair with no residual
interfaces. The normal host remained unchanged. The pinned musl rebuild,
command, hashes, guest logs and production observations are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-007/network-kernel`.
Strict ARM64 Clippy, 17 focused Rust tests, formatting, and diff checks passed.
The opt-in native bridge now passes authenticated launch and root, DNS,
TCP and teardown canaries. The bridge and peer use a private IPv4 /30
with no uplink. Its test resolver answers one pinned name, and TCP uses
one guest-private port. Host networking and published ports are rejected
before allocation. The no-network mode retains its original seccomp deny
rules. The bridge filter allows IPv4 stream and datagram sockets and
rejects raw sockets and AF_VSOCK. The focused run observed actual workload
exit while network cleanup was pending, then network removal and total
lifecycle removal in separate states. Injected helper failures recovered
after bridge creation, peer attachment, and before link cleanup. Five
complete launch cycles in each mode and the SPEED-006 failure and
cancellation regression matrix passed, with matching production snapshots.
The pinned rebuild, raw RPC, guest logs and verification scripts are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-007/bridge-launch`.
The final native binary probes bridge creation, resolver and TCP socket
binding, and verified removal before advertising its capability. Two
independent kernel bridge scopes in the same guest used the same addresses
and TCP port simultaneously, with separate namespace IDs and different
payload canaries, for five rounds. Native admission still enforces one
active workload. Fifty serial native bridge launches passed in each of the
normal and recovery boots, along with separate exit and network-cleanup
observations and forced recovery. Pinned binary hashes, raw traces, logs,
and passing production comparisons are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-007/bridge-scopes`.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[measurement contract](speed-engineering-plan.md#measurement-contract).

Review: The link proof reviewed the kernel sender and request sequence,
namespace ownership, explicit link deletion and address cleanup. Reviewed
the workload socket filter, fixed guest DNS and port bindings, peer
namespace FD lifetime, the separate network-cleanup state, the
kernel capability probe, and concurrent network identity isolation.
The one-workload fixture rejects host networking, user port maps and
arbitrary DNS. Broader Docker networking remains on its existing owner.

Next Action: Begin SPEED-008 with matching scenarios and a focused
transport timing experiment before claiming any lifecycle speedup.

### SPEED-006

Title: Add lifecycle failure injection and recovery tests

Description: Deliver a deterministic test matrix proving that launch failures, disconnects, and cancellation do not leak resources or duplicate execution.

Is blocked by task: SPEED-005.

Acceptance Criteria:

- Exercise cancellation at each lifecycle stage, malformed specs, exec failure,
  output backpressure, resource exhaustion, disconnects, and supervisor/guest failure.
- Verify isolation and data canaries, child reaping, and absence of resource leaks.
- Restart/recovery reconciles state without re-executing ambiguous requests.
- Relevant automated checks pass; unresolved correctness failures block later tasks.

Problem and Evidence: Direct supervision removes runtime layers whose lifecycle
and cleanup responsibilities must now be implemented by Conjet.

Approach:

1. Inject failure after each resource allocation and at child creation, exec, output handling, and cleanup.
2. Test cancellation before start, during execution, and during cleanup; reconnect using the same request ID and verify no duplicate start.
3. Kill the supervisor or disposable guest at defined stages; reconcile state and compare process, mount, and cgroup inventories before and after repeated runs.

Evidence: The fixture records a single root-private workload intent before
starting its helper. The helper verifies that intent and uses the same ID for
the cgroup leaf. Completion releases the record only after the helper confirms
cleanup. A corrupt or outstanding intent blocks admission on start. Cancellation
does not regress an observed cleanup phase.

`cargo test --locked -p conjet-launch-service` passed 17 tests, including
exclusive intent creation, re-opening a recorded ID, rejection of a different
owner, and preservation of corrupt state. Strict Linux ARM64 Clippy passed.
The pinned ARM64 musl build and live repeat of the fresh lifecycle matrix,
with before/after production observations, are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-006/intent`.
A separate live ARM64 run killed the guest supervisor after the kernel
confirmed workload exec. Guest init pinned the exited leader's PID while
signaling only its process group, reaped the group, and verified removal of
the recorded cgroup and sandbox before restarting the supervisor. The next
authenticated generation rejected the original launch and handle, then ran
a new workload and shut down cleanly. The companion normal boot passed the
same lifecycle checks without crash injection. Both runs verified production
snapshots and are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-006/restart`.
The helper-failure matrix passed after injected loss following sandbox,
mount, cgroup and child creation, exec confirmation, and the exit notification
before cleanup. The live supervisor reconciled each owned workload without
rotating the generation. Tests also verified a kernel exec failure (127),
bounded output (64 KiB per stream with exact dropped-byte counts), and a
memory cgroup kill (signal 9 and `oom_kill 1`). An independent disposable
VMM kill after exec left that outcome ambiguous. A replacement VM rejected
the old launch and handle and completed new work. All three runs preserved
the production snapshots. Commands, raw protocol observations, compiler and
guest logs are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-006/helper-faults`.
The final live matrix paused independently during preparation, with the
child created but before exec authorization, and during cleanup after
application exit. Cancellation before resources returned no exit.
Cancellation at the child barrier returned its actual exit 125 and no
exec confirmation. Cancellation during cleanup preserved the confirmed
exec and exit 0. Exact launch retries kept the same handle at each stage
and the reserved admission quota rejected a different launch. The full
matrix repeated all six helper failures, verified recovery of the owned
processes, cgroup and sandbox before reuse, and passed the normal boot
and disposable VM-loss runs again. This was the restricted one-workload
fixture, on the M1 Pro with production running and matching before/after
snapshots. All 17 focused Rust tests and strict Linux ARM64 Clippy passed.
The pinned rebuild, verification scripts, binary hashes and raw traces are
under `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-006/cancellation`.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[verification policy](speed-engineering-plan.md#verification-and-claim-policy).

Review: Reviewed write-before-helper ordering, deterministic cgroup identity,
and fail-closed admission after an unresolved intent. Reviewed the
guest-only process group, PID pinning, stale generation check before
admission, named cgroup teardown, private root canaries, the authorization
barrier and the distinction between accepting cancellation and finishing
cleanup. The fixture has no production activation path.

Next Action: Begin the private IPv4 bridge and verify its independently
owned link, addressing, DNS and port resources under teardown.

### SPEED-005

Title: Implement one fresh ARM64 no-network container launch

Description: Implement launch, wait, cancel, output, and cleanup for the approved minimal specification. Deliver a working isolated end-to-end fixture.

Is blocked by task: SPEED-004.

Acceptance Criteria:

- Implement private rootfs, namespaces, cgroup limits, credentials, capability
  restrictions, and seccomp for the declared supported configuration.
- Confirm exec separately from application readiness and return actual exit status.
- Supervise children, bound output, cancel safely, and acknowledge complete cleanup.
- Reject unsupported options and avoid duplicate starts on ambiguous disconnections.
- Successful and failed launches leave no orphan process, mount, or cgroup.

Problem and Evidence: The spec increment adds a closed native launch request and
validates the digest, canonical root-relative paths, environment,
credentials, network mode, and resource limits before allocation. The original transport-only service still rejects fresh
execution. A separate, explicitly selected disposable-guest mode advertises
its restricted fresh fixture capability.
Fifteen Rust tests, scoped Clippy, and the Linux ARM64 cross-check passed.
Logs are in `/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-005/spec`.
The kernel fixture created a private cgroup v2 mount in the disposable
ARM64 guest, installed memory, pids and CPU controls on a workload leaf,
created a namespaced child with `clone3` and `CLONE_INTO_CGROUP`, obtained a
pidfd, and reaped the child. It verified that the cgroup was empty and
removed the leaf and mount before guest poweroff. Production observations
matched. The binary was built with the pinned ARM64 musl compiler image.
The first musl attempt caught a signedness mismatch in `statfs.f_type`
that the GNU target had accepted. The corrected native boot report,
commands, hashes and failure log are retained under `SPEED-005`.

The next fixture executed a static ARM64 application in an isolated
namespaced child with the private overlay root, closed stdin, descriptor
closure, bounded resource limits, UID/GID 65532, no supplementary groups,
empty capabilities, no-new-privileges and the ARM64 seccomp allowlist.
The kernel confirmed exec. The executed application verified its
credentials and empty capabilities, could not see an outside canary,
wrote to its private upper layer, and received EPERM creating AF_VSOCK.
The fixture reaped the child and verified that the lower root was
unchanged. The cgroup and mount were removed and the guest powered off.
The isolated ARM64 report and production snapshots are retained in
`SPEED-005/sandbox-fixture`. Prior failures preserve the overlay denial
before switching to mapped setup credentials and the early process
failure before explicitly allowing the fd-poll syscall used at startup.
Linux-target Clippy passed.

The service resolves one root-owned ARM64 fixture manifest and checks its
staged executable's SHA-256 before accepting launches. The fresh mode
supports one active workload and one retained record. Over authenticated
VSOCK it verifies kernel exec independently of application output, returns
the exit code or signal, and reports removal only after the helper has
reaped the child and confirmed cleanup. It rejects unverified executables,
returns the original handle for identical retried requests, and rejects
conflicting and superseded sequences. A disconnected client can reconnect
and cancel the same workload. Tests verify nonzero exit, replay protection,
cleanup, and successful reuse of the workspace after failures.

Evidence: `cargo fmt --all -- --check`, `git diff --check`,
`cargo test --locked -p conjet-launch-service` (16 passed), and
`cargo clippy --locked -p conjet-launch-service --all-targets --target aarch64-unknown-linux-gnu -- -D warnings`
passed with ExternalSSD target directories. The pinned ARM64 musl build,
verified manifest and executable hashes, replay commands, raw VSOCK frames,
serial log, and production observations are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-005/fresh-service`.
Earlier attempts are retained separately, including the raw-clone trace
identity failure and the private cancellation socket reset.

Source: [Fresh lane](speed-engineering-plan.md#fresh-launch-lane),
[guest init](../../guest/init/conjet-init.c).

Review: Reviewed the single-helper ownership path, the identity and isolation
checks applied before exec, exit collection, output limits, and the boundary
between exit and removal. This fixture uses its pinned executable and a
closed no-network workload shape. General OCI image admission, restart
reconciliation, and stage-by-stage cleanup fault coverage remain outside this
fixture's qualified envelope. Production was observed without interaction.

Next Action: Begin SPEED-006 with named resource ownership and recovery tests.

### SPEED-000

Title: Build and prove the isolated conjet-speedup environment

Description: Deliver a session-scoped launcher under build-support/ and
`docs/engineering/speedup-environment.md` with setup, run, benchmark, and cleanup
commands for separate branch-built Conjet, conjetd, and Core processes.

Is blocked by task: None.

Acceptance Criteria:

- Separate CONJET_HOME, speedup profile, private DOCKER_CONFIG, mutable disks,
  locks, logs, sockets, and branch-built executables are verified at runtime.
- The private Docker context is named conjet-speedup; a test container reaches
  its VM and cannot be confused with the production context.
- Production PIDs, health, context endpoint and selected context remain unchanged;
  no app runtime binding, global socket link, builder, DNS, or startup registration changes.
- Launcher rejects executable fallback, production path overlap, endpoint mismatch,
  port collisions, and conflicting inherited Docker endpoint variables.
- Pinned Kiri uses ExternalSSD test data, a private Docker configuration and
  explicit endpoint. Per the user-approved scope, official settings may remain
  in ~/.kiri and official host shares remain; do not claim full filesystem confinement.
- Normal exit, cancellation, and startup failure stop owned processes and remove
  transient sockets/mounts. Retain explicitly managed test data, private contexts,
  and selected evidence for reuse; document their removal separately.
- Smoke comparison records engine identities and production background load;
  final clean benchmark qualification is not inferred from a contaminated run.

Problem and Evidence: CONJET_HOME and CONJET_PROFILE isolate runtime paths, but
CLI startup uses makeCurrent: true for Docker context creation. Shared Docker
configuration or installed-binary fallback could alter the production context.

Approach:

1. Audit startup, executable resolution, configuration persistence, network ports,
   and teardown; implement a fail-closed launcher with a private environment and
   task-owned resource manifest.
2. Build/stage isolated binaries, start separate processes under session ownership,
   create conjet-speedup in private Docker configuration, and prove routing with
   a disposable fixture plus before/after production observations.
3. Verify Kiri isolation and explicit endpoints, run a smoke comparison, exercise
   failure/cancellation cleanup, and document reproducible commands in the runbook.

Evidence: The branch baseline was `8e5144683e3cb9bc89dd60a11d81585ec94ebd98`.
Installed production Docker responded as 29.1.3 and kept its `conjet`
context. The initial candidate boot reached PSCI CPU_ON but failed with
`hv_vcpu_set_pending_interrupt = HV_UNSUPPORTED`; the failure and matching
production snapshots are retained in `initial-hvf-failure/session.json` and its VM logs
under the SPEED-000 evidence root. The local Hypervisor SDK declares this call
unsupported with a GIC. The correction uses the existing GIC SPI and
redistributor injection paths and preserves their error handling.

The corrected candidate ran the pinned ARM64 Alpine no-network fixture at
two vCPUs and 2,048 MiB. `smoke/session.json` records the staged executable
hashes, live process paths, Docker socket peer PID, context endpoint, VM paths,
production before/after observations, and background load. Official Kiri 0.2.2
ran the same pinned Alpine digest separately. Its evidence is retained in
`conjet-speedup-kiri/pinned-smoke-session.json`. No performance gate ran.

The native SwiftPM build and 38 focused Swift tests passed. Jetstream ran 133
tests successfully with three ignored using Apple's system archiver. The
default SwiftPM build failed in SwiftTerm's Metal step, and the GNU archiver
produced an unaligned archive for the Rust test link. Commands and workarounds
are in the [environment runbook](speedup-environment.md). Candidate artifacts
and command logs are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-000`.

SIGTERM during asset import returned 143 and the observed gzip child exited.
SIGTERM during the verified VM session returned 143 and left no staged
processes or sockets. A test VMM that exited 27 during startup produced a
failed session and clean shutdown. A conflicting inherited `DOCKER_HOST`
was rejected before launch. The candidate run left no private mounts.
Disposable session directories and disks were removed after evidence capture.
Verification used machine-readable terminal and daemon evidence for this
headless launcher.

Source: [Isolated environment](speed-engineering-plan.md#isolated-speedup-environment),
[paths](../../Sources/ConjetCore/ConjetPaths.swift),
[environment](../../Sources/ConjetCore/ConjetEnvironment.swift),
[CLI context configuration](../../Sources/ConjetCLI/main.swift).

Review: The launcher uses a fresh private profile, verifies the daemon peer
before sending commands, validates imported asset paths before starting a VM,
and verifies that the candidate VMM owns the Docker socket before invoking the
fixture. Production health, endpoints and fingerprints matched in success,
startup failure, and cancellation. The launcher removes residual socket entries
only after confirming the staged runtime exited.

Next Action: Begin SPEED-001 with process tracing and a post-exec fixture.

### SPEED-001

Title: Correct process-start events and add a readiness fixture

Description: Update the guest event producer and host decoder; add a fixture that signals readiness only after exec. Deliver trace-schema documentation and failure-path tests.

Is blocked by task: SPEED-000.

Acceptance Criteria:

- Current post-fork notification is not reported as successful application execution.
- Missing executable, permission failure, and early process exit produce accurate outcomes.
- End-to-end timing uses one host monotonic clock; guest durations remain separate.
- Trace schema and benchmark methodology document endpoints and instrumentation overhead.

Problem and Evidence: `guest/init/conjet-init.c` reports PROCESS_STARTED after
fork before exec success; the existing timeline labels T6 as first instruction.

Approach:

1. Trace PROCESS_STARTED from guest/init/conjet-init.c through its host decoder and replace the false exec-success interpretation.
2. Add distinct child-created, exec-confirmed, application-ready, and exec-failed outcomes; retain compatibility for existing event consumers.
3. Run a valid executable, missing path, non-executable file, and immediate exit; verify each trace and measure tracing overhead.

Evidence: The active Rust VMM had no receiver for guest-initiated readiness
connections, and the Rust CLI boot command rejected the benchmark's
`--timeline-jsonl` argument. The host increment adds an explicit
`--trace-guest-readiness` flag, bounded v1 VSOCK reception, separate host and
guest timestamps, and labels the legacy event as a launch observation.

Built and signed the branch VMM, then ran `jetstream boot` with the isolated
Core 1.3.1 manifest, two vCPUs, 2,048 MiB, 25 ms host tick,
`--require-docker-ready --hold-after-ready-ms 1000 --trace-guest-readiness
--json`. Docker reached readiness and the host collected `control_ready` and
`legacy_process_started` records with the same guest boot ID and ordered host
offsets. The first decode attempt rejected the appliance producer's
`VMADDR_CID_ANY` envelope. The corrected decoder validates the transport
CID and accepts that existing envelope marker.

Raw reports, production observations, the VMM hash, and Cargo and Swift test
logs are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-001/host-decoder`.
Two Swift StartupTimeline tests and 135 Rust tests passed, with three Rust
tests ignored. The published Docker guest emitted legacy markers only.

Built the static ARM64 Pulse init on the verified candidate Docker endpoint
using Alpine's GCC 14.2.0 and musl. The guest boot fixture proved control,
child creation, exec confirmation, application readiness, and normal exit.
A missing executable returned errno 2 and exit 127. A non-executable file
returned errno 13 and exit 127. An early exit confirmed exec and returned
status 23 with no application readiness. Production observations matched.
The focused Swift guest, initramfs, and timeline suites passed 33 tests.

Ten alternating pairs measured host-monotonic VMM invocation through guest
poweroff, with the same fixture and host collector enabled in both arms.
Guest tracing added a median 0.693 ms, with paired differences from -5.342
to +5.425 ms on this shared host. An initial run had a median of -0.969 ms.
Boot variance prevents a precise estimate of the tracing cost. Raw
reports, compiler details, hashes and the replay scripts are under the
SPEED-001 evidence root in `guest-fixtures` and `initial-guest-fixtures`.
The restored `conjet-bench startup-trace` ran against the isolated
fixture with `--early-console-only --trace-guest-readiness`. It retained
ordered T0, T1, T7 JSONL and a full boot response with all five expected
guest events. Both CLI and benchmark builds passed, and all 45 benchmark
package tests passed. Exact arguments and output are under
`timeline-adapter`. Production observations matched for the final run.

Source: [Measurement contract](speed-engineering-plan.md#measurement-contract),
[guest init](../../guest/init/conjet-init.c),
[timeline](../../Sources/ConjetCore/StartupTimeline.swift).

Review: Host increment reviewed for bounded frames, guest port and stream
validation, legacy event classification, and clock boundaries. The boot
report retains the legacy markers as guest observations. Guest review
confirmed exec from the kernel event and fixture readiness from the
inherited descriptor, and verified errors and early exit in raw reports.
The benchmark adapter uses host monotonic time for CLI intervals and
keeps raw guest timestamps separate. The underlying timed subprocess
boundary is documented. Runtime checks were headless and verified through
raw event streams and process observations.

Next Action: Begin SPEED-002 with a pinned and endpoint-verified fresh
lifecycle harness.

### SPEED-002

Title: Add and run the fresh-lifecycle baseline harness

Description: Extend benchmarks/ with pinned scenarios and explicit runtime endpoints. Deliver baseline JSON and a report for both engines.

Is blocked by task: SPEED-001.

Acceptance Criteria:

- Pin engine revisions, images, kernels, hardware, resources, cache state, and network mode.
- Distinguish API-visible removal from cleanup completion and exclude no failed samples silently.
- Preserve raw samples, stage traces, p50/p95/p99, CPU, footprint, and throughput.
- Record an initial baseline and predeclare comparison margin/statistical method;
  do not claim superiority from unmatched published figures.

Problem and Evidence: Kiri's published 2.55 ms result does not include Conjet;
its exit notification and cleanup boundaries differ.

Approach:

1. Use the SPEED-000 private conjet-speedup and verified Kiri endpoints; add scenario manifests for native ARM64 Alpine true with no-network and bridge modes, using the same image digest and resource limits.
2. Measure API create/start/wait/remove and CLI invocation separately; record API removal and observable cleanup independently.
3. Run isolated baseline sessions and write configuration, raw samples, failures, and percentiles under benchmarks/reports/; mark cleanup unknown if it cannot be observed.

Evidence: `benchmarks/fresh-lifecycle.py` and the pinned scenario ran
100 measured operations and 10 warmups per engine per network and lane,
with zero fixture failures across the completed sessions. The M1 Pro host
ran production Conjet throughout. Both engines used the same ARM64 Alpine
configuration ID, host Docker client and API 1.44. Guest kernels were
`6.12.86-conjet` and `6.18-kiri`. The launchers allocated two vCPUs and a
2,048 MiB ceiling to each engine.

No-network API p50/p99 was 396.837/479.683 ms for Conjet and 3.773/5.058 ms
for Kiri. Bridge API p50/p99 was 493.304/567.220 ms and 34.437/63.064 ms
respectively. The selected report contains both CLI lanes, stage latencies,
throughput, CPU and memory observations, image and binary digests, and all
raw samples. Kiri's initial footprint snapshot covered its Docker peer
only. Its final snapshot also identified the VM process by the private disk.

Report and selected raw captures are under
`benchmarks/reports/speed-002-initial/`. Commands, launcher evidence,
failed attempts, and the report renderer are retained under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-002`.
The initial API 1.41 attempt failed Conjet negotiation. A subsequent slow
candidate run was interrupted and its partial evidence was retained.
The complete run used API 1.44 and reported progress by group.

Five fixture accounting and cleanup tests and Ruff passed. The official
Kiri smoke passed. SIGTERM during the Kiri benchmark retained the partial
report, recovered one labeled fixture, and stopped its VM and daemon.
No socket or disk holder remained. Production observations matched.
This headless benchmark used raw evidence and has no screenshot surface.

Source: [Verification policy](speed-engineering-plan.md#verification-and-claim-policy),
[benchmark methodology](../benchmark-methodology.md),
[Kiri results](https://github.com/libracoder/kiri/blob/0de1837588eed54c945890f955ef861f2da71cc4/bench/results.json).

Review: Endpoint and CLI identities were revalidated, and both engines
completed the same pinned Docker work. The benchmark preserves failure and
abort records. API removal and guest cleanup are explicit separate fields.
Guest cleanup is unknown in this initial baseline, and the single-host
samples do not establish a competitive result. The comparison margin and
paired-session statistical method were declared before the completed runs.

Next Action: Begin SPEED-003 with a native launch protocol and lifecycle
ownership contract.

### SPEED-003

Title: Write the launch-service protocol and lifecycle specification

Description: Create docs/engineering/launch-service-contract.md with the message schema, state transitions, ownership rules, and initial supported options.

Is blocked by task: SPEED-002.

Acceptance Criteria:

- Specify one lifecycle owner, request IDs, cancellation, disconnect/retry behavior,
  recovery, and exactly-once slot consumption without promising exactly-once external side effects.
- Define supported OCI options and reject unsupported configurations before resource creation.
- Define authentication, bounded frames/queues/output, handles, generations, and error semantics.
- Document state transitions, child-creation safety, cgroup layout, and cleanup ownership.
- Keep the existing Docker lane explicit; prohibit silent mixed-engine ownership.

Problem and Evidence: Existing direct-OCI support is limited and lacks the proposed
reusable supervisor; an ambiguous retry could execute user work twice.

Approach:

1. Specify handshake, launch, cancel, status, output, exit, and cleanup messages with request IDs, deadlines, maximum sizes, and errors.
2. Define states from accepted through removed, and behavior for duplicate requests, disconnected clients, and service restart.
3. Specify a native ARM64 no-network feature matrix, cgroup ownership, and a safe child-creation model; reject all other options explicitly.

Evidence: [Launch service contract](launch-service-contract.md) defines
the dedicated VSOCK lane, 16 message types, mutual per-VM authentication,
deadlines and quotas, native ARM64 feature matrix, Linux execution and cleanup,
and recovery across connection and service loss. Verified all local links,
the contiguous message kind assignments, and `git diff --check`. The contract
uses the Linux `clone3`, pidfd and cgroup v2 interfaces documented in its
references.

Source: [Architecture](speed-engineering-plan.md#architecture-and-ownership),
[OCI loader](../../Sources/ConjetCore/ConjetContainerRuntime.swift),
[binary framing](../../Sources/ConjetCore/ConjetBinaryFrame.swift).

Review: Checked that queue and output limits are explicit, that retries
cannot readmit an evicted sequence, and that guest restart reconciles only
native-owned resources. The contract separates exec, application readiness
and cleanup. It binds claims to the declared native scope and leaves Docker
lifecycle ownership with the Docker engine.

Next Action: Begin SPEED-004 with the frame codec, authenticated persistent
VSOCK handshake, and bounded control request loop.

### SPEED-004

Title: Implement the VSOCK service handshake and bounded request loop

Description: Add a Rust guest-service skeleton and native host client using the approved contract. Deliver an isolated round-trip fixture without application execution.

Is blocked by task: SPEED-003.

Acceptance Criteria:

- Versioned, bounded protocol implements handshake, capability discovery, errors,
  deadlines, cancellation, and orderly shutdown.
- Unauthorized, malformed, oversized, disconnected, and saturated requests are tested.
- Guest supervision never runs under VMM device-processing locks.
- Round-trip measurements and service resource costs are recorded without busy polling.
- Disposable QA resources are cleaned up; no installed service registration changes.

Problem and Evidence: Existing VSOCK machinery provides transport, but the proposed
launch protocol and guest supervisor are not implemented.

Approach:

1. Implement version negotiation, capability reporting, request IDs, framing limits, deadlines, and shutdown over persistent VSOCK.
2. Add malformed-frame, unauthorized-client, queue-full, timeout, and disconnect tests.
3. Run the fixture in a disposable VM, record round-trip latency and resource use, then verify shutdown and cleanup.

Evidence: Added a pinned Rust launch-service crate with a 28-byte v1
frame codec, a pre-allocation payload bound, typed JSON, and mutual
HMAC-SHA256 authentication. Seven tests passed via
`cargo test --locked -p conjet-launch-service`, including an independent
HMAC vector, a persistent socket-pair handshake, replay rejection, peer
rejection, oversized frames and truncation. The scoped Clippy command
`cargo clippy --locked -p conjet-launch-service --all-targets -- -D warnings`
passed. Logs are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-004/codec`.
The transport increment added the Linux AF_VSOCK listener on port 2380,
a native Darwin client, an opt-in private Jetstream listener, and bounded
control handling. `cargo test --locked --workspace` passed 149 tests with
three existing opt-in integration tests ignored. Linux ARM64 cross-check
and scoped Clippy passed. The builder compiled a static ARM64 release
binary in the verified candidate using pinned Rust 1.91.1 Alpine and
`--target aarch64-unknown-linux-musl`. The first build failure and the
ad-hoc signing repair are retained alongside successful build logs.

In the isolated 512 MiB, two-vCPU VM, the live host fixture proved wrong
peer rejection, oversized and malformed frames, wait deadlines, full
wait and connection queues, cancellation, disconnect, and authenticated
shutdown. The shutdown acknowledgement was followed by VMM exit and
native socket removal. Production observations matched, and the runtime
roots and ephemeral key were removed. Existing Docker smoke passed with
the updated VMM. Results are in `SPEED-004/transport` under the retained
evidence root. Replay commands identify the kernel, VMM, host client and
guest binary by hash.

Across 100 control pings, p50/p95/p99 were 0.197/0.329/29.171 ms with a
39.349 ms handshake. The prior 100-ping run recorded 0.345/0.427/0.495 ms.
The larger p99 stays in the evidence. The final guest service reported
4.022 ms user CPU, 32.177 ms system CPU, and 472 KiB peak RSS across the
fixture session. VMM footprint was 32,457,520 bytes before the ping loop
and 31,572,784 after it. The measurements cover a transport fixture on
the shared host. The headless fixture produced raw records and no UI.

Source: [Architecture](speed-engineering-plan.md#architecture-and-ownership),
[VSOCK device](../../jetstream/src/devices/vsock.rs).

Review: Frame header and declared length are checked before payload
allocation. The transcript binds both role proofs, version negotiation,
peer nonces and the boot generation. The guest and host reject each other's
invalid proof before lifecycle traffic. Bounded pending waits and connections passed both unit and live tests.
Guest waits block in the kernel. The new host listener uses a wakeable
poll and joins on teardown. The live tests identified and fixed Docker
HTTP inference on native frames, raw EOF propagation, and the shared-VM
state lifetime that initially delayed listener cleanup. Docker retains
its existing bridge path.

Next Action: Begin SPEED-005 with the validated launch spec and the
isolated fresh execution path.

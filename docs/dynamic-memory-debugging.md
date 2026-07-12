# Dynamic Memory Debugging

Dynamic-memory fixes must be tested with cross-layer evidence, not only Activity
Monitor or `top`. The debugging goal is to prove this chain:

```text
Docker/cgroup memory drops
  -> Linux frees pages
  -> virtio-balloon reports disposable pages
  -> Jetstream validates GPA ranges
  -> Jetstream detaches and marks whole balloon-owned host granules reusable
  -> verified idle converts that detached backing to zero-filled host mappings
  -> macOS Conjet Core RSS/footprint drops
```

The correctness question is which bytes moved from `GuestOwned` to
`ReportInFlight` or `BalloonOwned`, then to reusable-detached or hard-zero
backing. Docker, cgroup, PSI, and host pressure signals may explain why reclaim
was requested, but they are never proof that a GPA is disposable.

## Host–Guest Granule Contract

On the supported ARM64 host, the VMM can detach memory only in complete native
host granules while the virtio-balloon protocol uses 4 KiB PFNs. Conjet Core
also uses 4 KiB Linux pages so x86-64 user-mode emulation remains compatible
with runtimes such as V8. A host granule may therefore contain several guest
PFNs.

Jetstream tracks ownership for every 4 KiB subpage and detaches a host granule
only after Linux has transferred every subpage in it. A partly ballooned host
granule remains mapped because detaching it would revoke memory Linux still
owns. After the guest reaches a verified idle target, Jetstream converts only
complete detached, balloon-owned granules to zero backing and restores that
backing before guest ownership returns. This preserves the dynamic-memory
safety contract independently of the guest page size.

## Controller Ownership

Jetstream is the sole owner of balloon-target transitions for the direct-kernel
VMM. macOS-side code only checks the guest and VMM telemetry endpoints; it does
not set a balloon target or run a competing reclaim policy. The production
memory-control socket is metrics-only and rejects legacy target-mutation
requests so an observer cannot desynchronize the automatic controller.

After runtime readiness, Jetstream waits for a quiet dwell and verifies a guest
snapshot. A confirmed empty build and service hierarchy may reach the 448 MiB
stopped-idle floor. A populated service hierarchy instead enters a guarded
running-service state described below. Bulk builds, image load/save, container
archive/export streams, and explicit create/start/restart/unpause lifecycle
requests restore configured capacity immediately. Ordinary ping, list, inspect,
log, and event traffic does not pin a running service at maximum capacity.
After bulk transport becomes quiet, Jetstream queues a guest cache reclaim and
waits a short settle interval before its next memory probe.

A hierarchy the kernel reports as empty releases its cache reserve so a stopped
Docker service cannot keep the VM at an active target. Jetstream defers the
stopped-idle transition while the daemon-scoped build cgroup is populated,
container or service working set is at least 64 MiB, disk-backed swap is in
use, or full memory PSI is elevated. Build workers are sibling scopes beneath
the Docker daemon slice; guest metrics and the reclaimer resolve that location
directly.
The aggregate cgroup workload count is diagnostic rather than an idle
authority because it also observes the resident container-runtime daemon.
The kernel's service-population bit plus measured service and container bytes
remain the fail-closed ownership signal.
For an unpopulated service hierarchy, clean active/inactive file cache and
reclaimable slab are reclaim candidates rather than a live working set. The
stopped-idle safety gate counts only anonymous, shared-memory, socket, mapped,
dirty/writeback, and unreclaimable-slab bytes. This lets the balloon and MGLRU
discard clean cache left by a stopped database without treating those pages as
executing service demand.
When both build and service hierarchies are empty, the guest also lowers the
Docker daemon's clean-cache reserve to a small control-plane floor and retries
that scoped reclaim after a short settle interval. It never reclaims anonymous
daemon memory or uses a global cache drop.
Once the idle target is applied, the controller replaces the normal probe loop
with a one-second lightweight service-population sentinel. This catches a
guest-originated service restart even when no new host Docker request crosses
the bridge; it does not run a second balloon policy.

The 448 MiB target is guest capacity, not an absolute host-process number.
Activity Monitor also charges the VMM executable, Hypervisor framework state,
device queues, and the Linux/Docker idle working set. Validate the target,
page-ledger residency, zero partial granules, and final physical footprint
together rather than treating one displayed number as the guest allocation.

## Running-Service Controller

Low host pressure does not mean cached guest pages are cold. Linux intentionally
keeps file cache when memory is available, and Jetstream may release host
backing only after Linux has transferred ownership through virtio ballooning or
free-page reporting. The controller therefore classifies growth before acting:

```text
anonymous or shared memory growth -> application working set; preserve it
active file growth               -> hot cache; preserve it
clean inactive file growth       -> reclaim candidate, subject to feedback
socket growth                    -> network memory; do not treat as file cache
flat guest usage + host growth   -> investigate VMM backing/page reporting
```

For populated services, Jetstream learns for 30 seconds and then computes a
middle target from the service and daemon working sets:

```text
runtime = service_working_set + daemon_working_set
headroom = max(512 MiB, runtime / 2) + learned_refault_headroom
desired = round_up_128_MiB(448 MiB + runtime + headroom)
desired = clamp(desired, 2048 MiB, configured_capacity)
```

`MemAvailable` adds a second floor so one step never consumes the guest's final
512 MiB reserve. Capacity grows immediately when the measured working set needs
it and shrinks by at most 256 MiB. Jetstream first observes balloon convergence
at a throttled one-second cadence, then waits ten seconds before collecting the
feedback sample. A shrink that cannot converge within 30 seconds restores
configured capacity; an expansion is reasserted after five seconds until it
converges. While a shrink is converging or stabilizing, a separate one-second
watchdog checks urgent pressure, swap, major-fault, cgroup-generation, and
working-set growth signals so the controller can expand before the ordinary
feedback sample is due.

After every shrink, Jetstream checks the guest page size, file-refault delta,
major faults, hierarchical cgroup high/max/OOM events, global and service
memory PSI, disk-backed swap, and container or aggregate compressed swap above
their budgets. Refault of
at least 8 MiB or two percent of
the preceding shrink restores the prior target, raises learned headroom, and
starts a two-minute cooldown. Learned headroom is capped at the smaller of
1 GiB and one quarter of configured capacity, and resets when service cgroup
membership changes. Missing, stale, reset, or incomplete telemetry fails safe:
the controller restores configured capacity. This includes explicit validity
for MemAvailable, total swap, disk-backed swap, and global PSI; a legitimate
zero remains distinguishable from an unreadable or malformed source.

The resident runtime daemon can leave a small amount of cold control-plane
anonymous memory in compressed RAM after the stopped-idle transition. That is
not disk I/O and must not cause a restore loop. Jetstream therefore permits at
most 64 MiB of aggregate compressed control-plane swap and at most 8 MiB in
container cgroups, while still requiring zero disk-backed swap. The smaller
container allowance covers cold startup residue only; any service major fault,
a refault regression, either budget being exceeded, or rising PSI restores
capacity. The live harness samples the whole settle window and enforces the
same bounds.

Running-service feedback keeps service-local PSI stricter than VM-wide PSI.
Service `some`/`full` avg10 limits remain 1.0%/0.05%; the VM-wide safety
ceilings are 5.0%/0.5%. This prevents a short reclaim stall in the Docker
daemon or another control-plane task from pinning configured capacity when the
service cgroup has zero pressure, no fault/refault growth, and adequate
`MemAvailable`. Stopped-idle admission retains the stricter VM-wide limits.

The production kernel enables Multi-Gen LRU so normal cgroup and balloon
reclaim use the kernel's recency and refault model. Debugfs generation controls,
page-owner tracking, idle-PFN scans, and access-monitor-driven pageout are not
production reclaim authority. They may be used in an isolated diagnostic image,
but only virtio ownership transitions authorize host decommit.

This design bounds cold-cache growth without imposing a hard container memory
limit. It cannot safely make a running database's anonymous/shared buffers
disappear, and no controller can guarantee that every evicted cache page will
remain unused. The 512 MiB reserve absorbs ordinary bursts; an abrupt anonymous
allocation larger than that reserve can still encounter reclaim before the
next guest sample. A future guest-originated pressure notification can provide
an immediate expansion path while leaving this guarded loop shrink-only.
Release qualification therefore gates host-footprint slope, pressure/event
counters, and service p95/p99 latency together.

## Current Debug Surface

Use the status snapshot while testing dynamic-memory patches:

```sh
conjet mem inspect --full
conjet mem verify --full
conjet memory status --json
conjet memory trace
```

The Rust VMM status includes the reclaim counters:

```text
reported_free_bytes
reported_free_reclaimed_bytes
soft_reclaimed_bytes
hard_decommitted_bytes
idle_hard_decommitted_bytes
idle_hard_decommit_failures
balloon_owned_reclaimed_bytes
report_inflight_reclaimed_bytes
reclaim_failures
malformed_reports
```

It also includes the host-page-granule page ledger:

```text
guest_visible_bytes
host_granule_bytes
host_granules
resident_bytes
guest_owned_bytes
pinned_bytes
balloon_owned_bytes
report_inflight_bytes
discarded_soft_bytes
discarded_hard_zero_bytes
cumulative_soft_discarded_bytes
cumulative_hard_decommitted_bytes
cumulative_balloon_authorized_bytes
cumulative_report_authorized_bytes
guest_owned_reclaimed_bytes
pinned_reclaimed_bytes
reclaim_without_authority_bytes
report_acked_before_reclaim_bytes
state_sum_mismatch_bytes
ok
```

The human CLI output surfaces these as:

```text
VMM reported free bytes
VMM reported free reclaimed
VMM soft reclaimed
VMM hard decommitted
VMM balloon-owned reclaimed
VMM report-in-flight reclaimed
```

For the current patch level, a good post-build reclaim run should show:

```text
page reporting ready
reported-free bytes rising
report-in-flight reclaimed bytes rising
hard-decommitted or soft-reclaimed bytes rising
reclaim failures and malformed reports staying at 0
host RSS/physical footprint trending down after reclaim
page-ledger invariant status staying `ok`
```

## Page Ledger

Jetstream keeps a host-page-granule ledger that separates reclaim authority
from backing state. This is the low-level safety proof:

```text
authority:
  GuestOwned
  Pinned
  BalloonOwned
  ReportInFlight

backing:
  Resident
  SoftDiscarded
  HardDecommittedZero
```

The current invariant is:

```text
Only BalloonOwned or in-flight ReportInFlight ranges may transition to
SoftDiscarded or HardDecommittedZero.
```

Future work should add a low-overhead ring-buffer event for every transition:

```text
GuestRamMmapReserve
HvMap
HvUnmap
HvRemapZero
MadvFree
BalloonInflate
BalloonDeflate
PageReportReceived
PageReportAccepted
PageReportRejected
PageReportAcked
CgroupReclaimRequested
CgroupReclaimCompleted
ControllerModeChange
RssSample
PsiSample
```

Each event should carry timestamp, GPA, length, old/new page state, current
macOS RSS and physical footprint, selected guest memory/PSI fields, and a short
reason string.

## Planned Commands

These commands are the active debug interface:

```sh
conjet mem inspect --full
conjet mem verify --full
conjet mem trace --json
conjet mem test idle-return --project ~/Workspace/Org/chum-mem --target-idle-rss 900M --target-final-delta 64M --timeout 120
```

`conjet mem verify` should fail loudly if:

```text
Pinned pages are in DiscardedSoft or DiscardedHardZero
GuestOwned pages are detached from the guest mapping
ReportInFlight pages are acked before reclaim completes
detached balloon pages lack a matching restore path
page-report descriptors are acked despite partial invalid ranges
ranges overlap MMIO or device memory
ranges are not host-page aligned
page-state bytes do not sum to guest_visible_ram
```

`conjet mem inspect --full` also attempts read-only host attribution with
`ps` and `vmmap -summary` for the VMM child process. A large virtual size is
not a failure; with sparse guest RAM, the important values are RSS, physical
footprint, and the guest RAM region's resident contribution.

The isolated ChumMem trace also records
`current_partially_owned_host_granules`. A no-cache build should leave this
near zero after the target returns to idle. A large value identifies a
granularity mismatch: the pages are intentionally retained because only part
of each host granule is balloon-owned.

## Build Validation Checklist

For the target behavior:

```text
fresh boot <= observed baseline + target delta
build grows memory
after build returns near baseline
```

Run:

```sh
conjet mem test idle-return \
  --project ~/Workspace/Org/chum-mem \
  --target-idle-rss 900M \
  --target-final-delta 64M \
  --timeout 120
```

The command collects a baseline, peak, post-build, and post-reclaim snapshot
with:

```text
macOS RSS and physical footprint
guest MemAvailable and inactive file
Docker/cgroup working set
PSI memory some/full
page-report received and accepted bytes
soft/reusable and hard-decommitted bytes
balloon-owned and report-in-flight reclaimed bytes
reclaim failures and malformed report counts
```

The pass condition is not just "RSS dropped". The evidence must show Linux
reported disposable pages and Jetstream reclaimed only `BalloonOwned` or
in-flight `ReportInFlight` ranges.

For an isolated no-cache Docker build, use the trace harness with an explicit
idle observation period. It leaves the user runtime untouched and records the
post-build return rather than only the peak:

```sh
build-support/run-chum-mem-memory-trace.sh \
  --manifest /path/to/isolated-manifest.json \
  --import-command 'docker compose build --no-cache' \
  --skip-compose-up \
  --skip-api-forward \
  --pre-import-idle-seconds 20 \
  --post-import-settle-seconds 90 \
  --expect-core-idle-target-mib 448 \
  --expect-core-workload-expansions 1 \
  --require-core-capacity-during-import \
  --max-core-post-idle-probes 1 \
  --max-final-physical-footprint-mib 1024
```

`--require-core-capacity-during-import` is a regression gate for reclaim
thrash: after a Docker workload expands capacity, every import-stage sample
must retain the configured target until the client command exits.

To validate the stopped-service path, let the harness start the isolated
Compose services, then stop them through the same scratch Docker socket:

```sh
build-support/run-chum-mem-memory-trace.sh \
  --manifest /path/to/isolated-manifest.json \
  --import-command true \
  --stop-compose-after-import \
  --skip-api-forward \
  --pre-import-idle-seconds 15 \
  --post-import-settle-seconds 45 \
  --expect-core-idle-target-mib 448 \
  --expect-core-workload-expansions 1 \
  --max-final-physical-footprint-mib 1024
```

For a populated-service run, keep the probe inside the isolated API container.
The host-side API helper itself uses Docker transport and would contaminate the
controller signal:

```sh
build-support/run-chum-mem-memory-trace.sh \
  --manifest /path/to/fresh-isolated-manifest.json \
  --import-command true \
  --skip-api-forward \
  --internal-ready-probe \
  --post-import-settle-seconds 600 \
  --expect-core-workload-expansions 1 \
  --expect-core-service-shrinks 1 \
  --max-final-core-target-mib 3072 \
  --max-final-physical-footprint-mib 3072 \
  --min-ready-probe-samples 540 \
  --max-final-half-footprint-slope-mib-per-min 32 \
  --max-service-pgmajfault-delta 5 \
  --max-service-psi-full-total-delta-us 1000 \
  --require-mglru \
  --memory-mib 8192
```

Compare fresh baseline and candidate disks. Require zero request/OOM failures,
no full-PSI or major-fault regression beyond the explicit budgets, equivalent
tail latency, and a flat final-half physical-footprint slope. The internal `/ready` request is a
database-backed availability and latency canary, not a throughput benchmark;
use a separate representative load for throughput claims. The harness rejects
missing samples, incomplete service telemetry, disabled MGLRU, balloon target
non-convergence, swap/PSI/event regressions, active-service hard decommit, and
configured target, footprint, or latency thresholds. Hierarchical and local
cgroup event counters are checked independently, including group OOM kills;
the live-service window also requires a stable cgroup identity and rejects
counter resets. Major-fault and full-PSI gates compare cumulative counters
across the entire settle window rather than only the final rolling averages.
The example budgets at most five lazy major faults and 1 ms of cumulative full
service stall; tail latency, event counters, and rolling PSI must still pass.

## Runtime Flags

Implemented Jetstream flags:

```text
CONJET_MEM_HARD_DECOMMIT_ONLY=1
CONJET_MEM_DISABLE_HARD_DECOMMIT=1
CONJET_MEM_DISABLE_MADV_FREE=1
CONJET_MEM_DISABLE_BALLOON=1
CONJET_MEM_DISABLE_PAGE_REPORTING=1
CONJET_MEM_DISABLE_CORE_IDLE_CONTROLLER=1
CONJET_MEM_CORE_IDLE_TARGET_MIB=448
CONJET_MEM_CORE_IDLE_DWELL_MS=8000
CONJET_MEM_CORE_SERVICE_MIN_TARGET_MIB=2048
CONJET_MEM_CORE_SERVICE_LEARNING_MS=30000
CONJET_MEM_CORE_SERVICE_PROBE_MS=5000
CONJET_MEM_CORE_SERVICE_SHRINK_STEP_MIB=256
CONJET_MEM_CORE_SERVICE_HEADROOM_MIB=512
```

Use these for focused validation:

```sh
# Exercise the hard-decommit fallback when reusable detached backing is unavailable.
CONJET_MEM_HARD_DECOMMIT_ONLY=1 conjet start

# Prove the mapping-preserving soft-discard fallback still works when hard decommit is disabled.
CONJET_MEM_DISABLE_HARD_DECOMMIT=1 conjet start

# Prove page reporting is required for post-build discard.
CONJET_MEM_DISABLE_PAGE_REPORTING=1 conjet mem test idle-return --project ~/Workspace/Org/chum-mem

# Prove the classic balloon path is required for strong guest pressure reclaim.
CONJET_MEM_DISABLE_BALLOON=1 conjet start
```

Future instrumentation flags that are documented but not implemented yet:

```text
CONJET_MEM_DEBUG=1
CONJET_MEM_TRACE=1
CONJET_MEM_VERIFY=1
CONJET_MEM_POISON=1
CONJET_MEM_DUMP_REJECTS=1
```

## Primary Kernel References

- [Linux 6.12 cgroup v2 memory controller](https://docs.kernel.org/6.12/admin-guide/cgroup-v2.html)
- [Linux pressure stall information](https://docs.kernel.org/accounting/psi.html)
- [Linux 6.12 Multi-Gen LRU](https://docs.kernel.org/6.12/admin-guide/mm/multigen_lru.html)
- [Linux idle-page tracking](https://docs.kernel.org/admin-guide/mm/idle_page_tracking.html)
- [Virtio 1.3 balloon and free-page reporting](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)

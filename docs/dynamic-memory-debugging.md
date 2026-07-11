# Dynamic Memory Debugging

Dynamic-memory fixes must be tested with cross-layer evidence, not only Activity
Monitor or `top`. The debugging goal is to prove this chain:

```text
Docker/cgroup memory drops
  -> Linux frees pages
  -> virtio-balloon reports disposable pages
  -> Jetstream validates GPA ranges
  -> Jetstream detaches and marks whole balloon-owned host granules reusable
  -> macOS Conjet Core RSS/footprint drops
```

The correctness question is which bytes moved from `GuestOwned` to
`ReportInFlight` or `BalloonOwned`, then to reusable-detached or hard-zero
backing. Docker, cgroup, PSI, and host pressure signals may explain why reclaim
was requested, but they are never proof that a GPA is disposable.

## Host–Guest Granule Contract

On the supported ARM64 host, the VMM can detach memory only in native 16 KiB
host granules while the virtio-balloon protocol uses 4 KiB PFNs. A 4 KiB guest
can leave one host granule partly guest-owned after build activity; that page
must remain resident because detaching it would revoke memory Linux still owns.

The Docker and fast direct kernels therefore use 16 KiB ARM64 Linux pages. Each
balloon allocation is reported as four adjacent 4 KiB PFNs, giving the VMM a
whole host granule that it can detach, mark reusable immediately, and restore
before guest ownership is returned. This is a compatibility requirement for
near-baseline idle memory after large builds, not a best-effort reclaim policy.

## Controller Ownership

Jetstream is the sole owner of balloon-target transitions for the direct-kernel
VMM. macOS-side code only checks the guest and VMM telemetry endpoints; it does
not set a balloon target or run a competing reclaim policy.

After runtime readiness, Jetstream waits for a quiet dwell, verifies the guest
snapshot, and then reduces its own target to the 512 MiB idle floor. Workload
start is recognized from Docker API requests, framed TCP payloads, or verified
build-progress output when a client transport does not expose its request path.
Any Docker transport-byte progress also restores configured capacity, so opaque
BuildKit sessions cannot remain at the idle floor while they compile. After
transport becomes quiet, Jetstream queues a guest cache reclaim and waits a
short settle interval before the next quiet-state verification. A populated
service hierarchy retains its hot-cache reserve; a hierarchy the kernel reports
as empty releases that reserve so a stopped Docker service cannot keep the VM
at its active target. It defers a shrink when the daemon-scoped build cgroup is
populated, container or service working set is at least 64 MiB, disk-backed
swap is in use, or full memory PSI is elevated. Build workers are sibling
scopes beneath the Docker daemon slice; the guest metrics and reclaimer resolve
that location directly.
Once the idle target is applied, the controller disarms its probe state until a
new workload is observed.

The 512 MiB target is guest capacity, not an absolute host-process number.
Activity Monitor also charges the VMM executable, Hypervisor framework state,
device queues, and the Linux/Docker idle working set. Validate the target,
page-ledger residency, zero partial granules, and final physical footprint
together rather than treating one displayed number as the guest allocation.

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
  --expect-core-idle-target-mib 512 \
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
  --expect-core-idle-target-mib 512 \
  --expect-core-workload-expansions 1 \
  --max-final-physical-footprint-mib 1024
```

## Runtime Flags

Implemented Jetstream flags:

```text
CONJET_MEM_HARD_DECOMMIT_ONLY=1
CONJET_MEM_DISABLE_HARD_DECOMMIT=1
CONJET_MEM_DISABLE_MADV_FREE=1
CONJET_MEM_DISABLE_BALLOON=1
CONJET_MEM_DISABLE_PAGE_REPORTING=1
CONJET_MEM_DISABLE_CORE_IDLE_CONTROLLER=1
CONJET_MEM_CORE_IDLE_TARGET_MIB=512
CONJET_MEM_CORE_IDLE_DWELL_MS=8000
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

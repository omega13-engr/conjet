# Dynamic Memory Debugging

Dynamic-memory fixes must be tested with cross-layer evidence, not only Activity
Monitor or `top`. The debugging goal is to prove this chain:

```text
Docker/cgroup memory drops
  -> Linux frees pages
  -> virtio-balloon reports disposable pages
  -> Jetstream validates GPA ranges
  -> Jetstream soft-discards or hard-decommits host backing
  -> macOS Conjet Core RSS/footprint drops
```

The correctness question is which bytes moved from `GuestOwned` to
`ReportInFlight` or `BalloonOwned`, then to `DiscardedSoft` or
`DiscardedHardZero`. Docker, cgroup, PSI, and host pressure signals may explain
why reclaim was requested, but they are never proof that a GPA is disposable.

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
GuestOwned pages are hard-decommitted
ReportInFlight pages are acked before reclaim completes
hv_vm_unmap bytes do not match DiscardedHardZero bytes
page-report descriptors are acked despite partial invalid ranges
ranges overlap MMIO or device memory
ranges are not host-page aligned
page-state bytes do not sum to guest_visible_ram
```

`conjet mem inspect --full` also attempts read-only host attribution with
`ps` and `vmmap -summary` for the VMM child process. A large virtual size is
not a failure; with sparse guest RAM, the important values are RSS, physical
footprint, and the guest RAM region's resident contribution.

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
soft-reclaimed and hard-decommitted bytes
balloon-owned and report-in-flight reclaimed bytes
reclaim failures and malformed report counts
```

The pass condition is not just "RSS dropped". The evidence must show Linux
reported disposable pages and Jetstream reclaimed only `BalloonOwned` or
in-flight `ReportInFlight` ranges.

## Runtime Flags

Implemented Jetstream flags:

```text
CONJET_MEM_HARD_DECOMMIT_ONLY=1
CONJET_MEM_DISABLE_HARD_DECOMMIT=1
CONJET_MEM_DISABLE_MADV_FREE=1
CONJET_MEM_DISABLE_BALLOON=1
CONJET_MEM_DISABLE_PAGE_REPORTING=1
```

Use these for focused validation:

```sh
# Prove the hard decommit path is responsible for deterministic RSS drops.
CONJET_MEM_HARD_DECOMMIT_ONLY=1 conjet start

# Prove the soft-discard fallback still works when hard decommit is disabled.
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

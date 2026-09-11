# Host backing reclamation

## Problem and implementation plan

A partial `MAP_FIXED` replacement can reduce both RSS and physical footprint
while neighboring mappings keep the original anonymous VM object alive. Its
unmapped dirty pages can remain resident or compressed. The original immediate
release tests verified task accounting, canaries, and demand-zero reuse, but
missed this backing-object lifetime.

The fix has four parts:

1. Keep the existing guest ownership, host-page alignment, and HVF detach gates.
2. Apply `MADV_FREE_REUSABLE` to the original owned range **before** replacing
   its host mapping. Check the owned pages with `mach_vm_page_range_query`:
   they must be absent or reusable, with no compressed backing. Then install
   fresh anonymous backing at the same address. An advisory success can still
   skip a busy/wired page; an incomplete discard leaves its mapping reachable.
3. If advice or replacement fails, cancel reusability before restoring guest
   access. Failure to cancel it is fatal: ACK must never expose live pages that
   the host can still discard. Reports are remapped before ACK; balloon-owned
   ranges remain detached until deflate.
4. Test the original backing object as well as task RSS/footprint, and expose
   compressed-memory diagnostics for workload observations.

The implementation is in `GuestMemory::replace_backing_at`; both immediate
release and hard-decommit fallback use it. Linux keeps its existing mapping
replacement behavior. No guest image change, dependency, background scanner,
timer, or global cache purge is introduced. Page-state verification uses a
bounded 4096-entry stack buffer, scans only the reclaim range, and never reads
guest contents. There is no retry loop on the device-processing path.

## What macOS releases

Darwin's reusable advice clears the owned pages' dirty state and discards their
compressor slots. Resident pages become clean and reusable by the host. Doing
this before `MAP_FIXED` avoids leaving dirty/compressed backing outside the
process's accounting. The fresh mapping guarantees demand-zero reuse and removes
the reusable lifetime from subsequent guest access.

This follows the `VM_BEHAVIOR_REUSABLE` path in Apple's
[vm_map.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_map.c)
and `deactivate_pages_in_object` in
[vm_object.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_object.c).
`MADV_ZERO` zeros resident pages; it does not itself free their backing. Merely
replacing the mapping loses access to the original range before it is discarded.

**Clean reusable pages can remain physically resident until macOS reuses them.**
This fix makes them disposable without compression or swap preservation; it
does not force every page onto the free list immediately. System memory pressure
also includes other processes, so a fixed percentage cannot be guaranteed.

`hard_decommitted_bytes` describes successfully replaced owned ranges. It is a
cumulative operation counter, not a measurement of physical RAM freed. The
compatibility `disable_free_reusable` switch does not bypass the mandatory
discard preparation inside a hard decommit.

## Diagnostics

The memory-control socket's existing `host_memory` object gains additive fields:

| Field | Meaning |
|---|---|
| `compressed_bytes` | Logical compressed bytes charged to the VMM task |
| `reusable_bytes` | Reusable bytes still mapped into that task |
| `system_compressor_bytes` | Physical compressor storage for the whole Mac |
| `system_compressed_logical_bytes` | Logical data held in the system compressor |

Unavailable readings are `null`. Task compressed bytes are not physical
compressor storage, and task reusable bytes cannot describe backing already
unmapped from the task. System counters provide context and cannot attribute a
change to Conjet. These readings run on existing metrics requests; they add no
polling thread. The temporary Mach host-port right is released after each query.

## Regression checks

The native and entitled HVF tests leave a large, mostly untouched live neighbor
in the original object. `VM_REGION_TOP_INFO` then reveals its nonreusable backing
after the adjacent dirty range is replaced. Its object count subtracts reusable
pages and is capped by mapping size; this is deliberately a test of retained
nonreusable memory, not proof that all physical pages reached the free list.

Coverage includes partial release, repeated allocation/release, live canaries,
demand-zero reuse, fragmented guest access, both report/balloon ownership, invalid
ranges, advisory success with a wired page left undiscarded, and injected
replacement failure with reusability rollback. A scratch
copy with discard preparation removed must fail the backing regression. The
existing guest-executed load/store check covers reuse after an actual vCPU exit.

The Docker E2E runner now requires RSS, footprint, and the sum of resident plus
compressed logical bytes to fall, and retains the new compressor fields in its
trace. Compressing live pages must not be counted as releasing them, but a net
release can coexist with compression of other pages.
The native/HVF backing regression remains necessary: task accounting alone
cannot detect orphaned backing.

All runtime checks use disposable disks and explicit QA sockets. Do not restart
the installed runtime to run them. No OrbStack, latency, throughput, or energy
benchmark is part of this validation. Compressed-slot disposal follows the XNU
path above; a run that never compresses VMM pages does not dynamically validate
that branch. Deliberately pressuring unrelated host applications is unnecessary
for the resident-backing regression.

The [2026-09-11 QA report](qa/jetstream-backing-2026-09-11/README.md) records
native/HVF backing regressions, ChumMem persistence, Docker allocation/build
checks, observed compressed memory, the initial failed test criterion, and the
all-containers-stopped result with Core still alive.

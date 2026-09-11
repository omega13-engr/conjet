# Jetstream dynamic memory E2E — 2026-09-11

**Follow-up:** these original RSS/footprint results did not establish complete
host-backing reclamation. A partial-mapping retention defect was subsequently
reproduced. See [host backing reclamation](jetstream-host-backing-reclaim.md) for
the fix, stronger regression checks, and the distinction between reusable pages
and pages physically returned to the free list.

The current immediate-release VMM, patched Linux kernel, and guest reclaim worker
completed the chum-mem application checks and the native Docker memory fixture
suite. RSS returned while PostgreSQL, the Rust API and worker, and the Node web
service remained running. Allocation canaries, demand-zero reuse, and database
contents remained correct. This was correctness validation, with no benchmarks,
power measurements, or OrbStack comparison.

## Setup and scope

An isolated Jetstream/HVF VM used four vCPUs, 8192 MiB configured RAM, a fresh
verified Conjet Core root image, and a fresh Docker data disk. The effective idle
target was 512 MiB, quiet dwell 1 ms, service shrink step 512 MiB, and kernel
report delay 25 ms. Image and binary hashes are in
[results.json](qa/jetstream-memory-2026-09-11/results.json). These are explicit QA
settings; they do not represent every memory profile or deployed version.

The source was a snapshot of `/Users/sly/Workspace/Org/chum-mem`, including its
existing working-tree changes. The original checkout's Git status remained
unchanged. No personal session import, `.env`, production database, or existing
PostgreSQL/TurboVec volume was used. Every Docker command selected the QA Unix
socket and a separate Docker configuration. Host ports from the original Compose
file were removed, and migrations were baked into the QA PostgreSQL image to
replace its host-directory bind mount.

Direct guest TCP egress timed out, although host HTTPS and guest DHCP/DNS worked.
A temporary loopback HTTP CONNECT proxy, carried over the working Docker/VSOCK
connection, enabled image and package downloads. Node/Corepack initially ignored
the proxy; the QA Dockerfile used `NODE_USE_ENV_PROXY=1` for `pnpm install`, following
[Node's proxy documentation](https://nodejs.org/download/release/latest-v25.x/docs/api/http.html).
The source checkout was not changed for this workaround. The dashboard also used
a temporary localhost-to-container bridge over Docker exec/VSOCK. Consequently,
these results **do not validate normal guest internet access, published-port
forwarding, or host file sharing**. The cause of direct TCP failure remains open.

## Application and memory checks

| Check | Observation |
|---|---|
| Real Compose build/start | PostgreSQL, Rust API, Rust worker, and Node web images built and all four services started |
| Synthetic ingestion | Three sessions, 96 inserted events, and 96 duplicate retries correctly rejected as duplicates |
| Worker processing | 12 completed jobs: derivation, graph build, reconciliation, and TurboVec indexing; no failed jobs |
| Repository graph/search | Four actual source files produced 898 nodes and 4944 edges; MCP initialization, tool discovery, and repository query succeeded |
| UI | Dashboard displayed 24 memories and three sessions; worker queue displayed 12 completed jobs; search returned synthetic PostgreSQL entries |
| Concurrent checks | 167 successful internal API readiness checks and 171 successful PostgreSQL checksum checks; no failures |
| Database canary | 16,384 rows / 64 MiB; checksum `43fbead8523e697d0a2d1b0a505209b2` unchanged after build, release fixtures, and Compose stop/start |
| Restart persistence | Three sessions, 24 memories, 12 completed jobs, repository search, and dashboard contents survived |
| Ownership/OOM | 932 control snapshots, zero ledger violations or sampling errors, and zero observed container OOM/OOM-kill events |

The reusable [Docker fixture](../build-support/docker-memory-e2e/README.md) uses
anonymous `mmap`/`munmap`, reads every newly mapped byte before initialization to
verify demand-zero reuse, and maintains a 64 MiB live canary in each of two
containers. The server blocks on its control socket when idle; health probes do
not scan the canary. No new runtime dependency is required by Conjet.

| Controlled check, alongside chum-mem | RSS before (MiB) | RSS after (MiB) | Observed reduction (MiB) |
|---|---:|---:|---:|
| 512 MiB allocation release, cycle 1 | 1475.38 | 1159.98 | 315.39 |
| 512 MiB allocation release, cycle 2 | 1694.86 | 1176.39 | 518.47 |
| 512 MiB allocation release, cycle 3 | 1676.70 | 1164.23 | 512.47 |
| Build fixture: 512 MiB anonymous allocation plus 512 MiB file | 2481.20 | 1599.30 | 881.91 |

These are individual coarse correctness observations, not latency percentiles or
exact byte attribution: other guest activity can increase or decrease RSS in the
same interval. The suite required at least 256 MiB observable return and verified
live canaries and reuse after each cycle. The build fixture wrote, synced, and
read its temporary file before releasing it. Compiler/dependency layers remained
cached, while a unique build argument reran the allocation stage.

## Failure and remaining limits

The separate final idle-capacity assertion **timed out at 90 seconds**. At that
snapshot, the requested capacity was still 8192 MiB, but RSS was already about
536 MiB. Guest total swap usage was 87,650,304 bytes, above the existing 64 MiB
control-plane zram budget. The controller retained capacity under that safeguard;
its diagnostic called this “guest telemetry incomplete,” even though the reported
telemetry-completeness flags were true. That wording is misleading and should be
separated from the swap-policy reason in a later diagnostic change.

A subsequent observation confirmed target 512 MiB and complete balloon
convergence, with RSS 534.94 MiB and physical footprint 733.71 MiB. The safeguard
was not relaxed to force this check through. Fast physical return and reduction
of guest capacity are distinct behaviors, and the latter still has protective
policy delays. Exact release latency, idle wakeups, energy, warm-cache cost, and
service tail latency remain unmeasured. Long-running fragmentation and supported
hardware coverage also remain release gates.

The initial native macOS fixture compile needed Darwin feature visibility for
`MAP_ANONYMOUS`; that fixture portability issue was fixed. The final native
regressions, Linux Docker build, and full Docker fixture suite passed. No new
memory-corruption, unauthorized-discard, or OOM failure was observed.

## Retained evidence and cleanup

[Result snapshots](qa/jetstream-memory-2026-09-11/results.json) retain the relevant
configuration, hashes, counters, return snapshots, idle timeout, and later idle
observation. The same directory retains short fixture/HVF/Linux result logs and
the kernel build manifest. UI evidence:

- [Completed worker queue](qa/jetstream-memory-2026-09-11/chum-mem-workers.png)
- [Search results](qa/jetstream-memory-2026-09-11/chum-mem-search.png)
- [Dashboard after restart](qa/jetstream-memory-2026-09-11/chum-mem-after-restart.png)

The user requested removal of temporary tests. The QA containers, VM, helper
processes, temporary source copy, disks, raw traces, compiler outputs, and earlier
implementation scratch directory are removed after retaining this evidence.
The installed Conjet runtime and the original chum-mem project remain untouched.

# Host backing reclamation QA — 2026-09-11

This validates the follow-up to Conjet 2.1.0. The patch was not installed or
released during these checks. See [implementation and limitations](../../jetstream-host-backing-reclaim.md).

## Isolation and workload

The signed debug Jetstream executable ran on Apple Silicon with four vCPUs and
4 GiB configured guest RAM. It used a fresh copy of the Core 1.3.0 root archive,
a disposable Docker disk, and explicit Docker/control sockets under a temporary
`/tmp` QA root. The installed runtime and its mutable disks were untouched.
The idle target was explicitly 512 MiB; other memory policy settings were defaults.

ChumMem's existing Dockerfiles and Compose configuration supplied PostgreSQL,
API, worker, and web workloads. Its working tree was copied without secrets or
build output and remained unchanged. Host ports were removed, migrations were
embedded in a QA PostgreSQL image, and fresh named volumes held synthetic data.
The screenshot connection used a temporary loopback bridge through `docker exec`;
this does not validate Conjet's normal published-port routing.

The workload ingested 32 events, rejected 32 duplicate retries, and completed
three worker jobs. A 16,384-row database canary retained checksum
`16384:10b3b8214172d3b698258a128e9c6687` across memory release and Compose stop/start.
Its payload was 64 MiB logically and compressible; that is not a claim of 64 MiB
physical residency. All 97 continuous API readiness and checksum observations
succeeded. The synthetic session and completed jobs are visible in
[the session screenshot](chum-session.png) and [worker screenshot](chum-workers.png).

## Memory observations

The Docker fixture ran three 512 MiB allocation/free/reuse cycles with two live
64 MiB canaries, a build using 512 MiB anonymous memory plus 512 MiB file data,
and container restart checks while ChumMem remained running.

The table reports the first sample meeting the configured 256 MiB return
criterion, not the eventual maximum release. Sampling was for correctness;
these are not latency or throughput benchmarks.

| Phase | RSS decrease (MiB) | Footprint decrease (MiB) | Resident + compressed decrease (MiB) |
|---|---:|---:|---:|
| Allocation cycle 1 | 265.48 | 265.50 | 265.48 |
| Allocation cycle 2 | 382.23 | 382.23 | 382.23 |
| Allocation cycle 3 | 519.14 | 519.19 | 519.17 |
| Docker build | 1565.23 | 1565.95 | 1565.83 |

After all QA containers stopped, Core remained alive and reached its 512 MiB
guest idle target. Task RSS fell from 1450.05 to 523.30 MiB, logical compressed
memory from 526.98 to 203.84 MiB, and footprint from 1973.44 to 723.40 MiB.
The first 30 seconds still showed a safe-capacity deferral while guest telemetry
settled; a later sample confirmed empty services, target 512 MiB, and no policy
error. This is not evidence of instantaneous convergence to the final target.

System compressor storage changed from 2868.23 to 2741.59 MiB over that interval.
That is a whole-Mac observation, not a measurement attributable solely to Conjet.
No fixed system pressure percentage, physical free-list target, power saving,
or OrbStack performance comparison was tested or promised.

The final Docker and idle observations had valid ownership ledgers, no reclaim
or reuse failures, and no unsafe ownership counters. Full before/after readings
and source hashes are in [results.json](results.json); the early idle samples are
in [all-stopped-trace.jsonl](all-stopped-trace.jsonl).

## Regression evidence and failures encountered

The original defect was reproduced in a scratch copy with discard preparation
removed: `partial_decommit_discards_original_nonreusable_backing` failed with
`original backing retains 512 nonreusable pages after partial decommit`.
That expected counterfactual failure is retained in
[regression-before-fix.log](regression-before-fix.log).

The first Docker run failed an experimental fixed 64 MiB limit on compressed
growth. RSS fell about 954 MiB, footprint about 498 MiB, and compression grew
about 456 MiB. This is a genuine net return alongside compression, not a valid
reason to reject the release. The final check requires RSS, footprint, and net
resident-plus-compressed reductions independently, retaining compression growth
as evidence. The failed trial is preserved in
[its log](initial-compression-limit-failure.log) and
[raw readings](initial-compression-limit-failure.json).

The final Rust suite, entitled HVF regressions, Python accounting regressions,
and Docker suite had no remaining failures. The final rollback regression checks
page disposition without assuming that reusable pages stay resident under host
pressure. The Linux-only integration case was not run on this macOS host.
Relevant logs are retained alongside this report. Task compression occurred
naturally, but the tests did not force a particular owned guest range into the
compressor before release; compressed-slot disposal also relies on the reviewed
XNU implementation. Native/HVF object-retention regressions supply evidence that
task accounting alone cannot provide.

The web container exited 137 during explicit Compose stop after its termination
timeout. Running/restart inspections reported no OOM kill, and the checksum and
service checks after restart succeeded.

All temporary QA processes, disks, builds, sockets, and browser tabs are removed
after retaining these selected results. No global host cache purge or artificial
host memory-pressure workload was used.

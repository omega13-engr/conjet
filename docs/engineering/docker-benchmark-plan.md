# Docker comparison contract

SPEED-015 freezes the protocol before any new samples. This is a local study on
the 16 GiB M1 Pro, with the installed Conjet runtime left in service. Each pair
uses the same machine, ExternalSSD and pinned client. The machine-readable
manifest contains image manifest digests for Linux ARM64, exact client hashes
and sample budgets. Preserve measured build and harness commits separately
and record hashes of the actual executables in every report.

[Scenario manifest](../../benchmarks/scenarios/docker-comparison-v1.json)

## Execution paths and capability matrix

```text
Docker CLI or HTTP -> kiri-speedup Unix socket -> official Kiri -> Kiri guest
Docker CLI or HTTP -> conjet-speedup Unix socket -> Jetstream bridge -> guest Docker/containerd
Native CLI or authenticated API -> private native socket -> Jetstream -> Rust launch service
Docker CLI or HTTP -> proposed dedicated socket -> one native Docker owner -> qualified OCI sandbox
```

| Surface | Official Kiri | Existing Conjet Docker | Conjet native | Proposed Docker-to-native |
| --- | --- | --- | --- | --- |
| Docker API and CLI run, inspect, stop, remove | Probe API behavior and flags | Guest Docker/containerd | No Docker endpoint | Unavailable until admitted OCI image and full declared lifecycle are verified |
| OCI image pull/load/save and ready-to-run | Probe digest and load behavior | Guest Docker image store | One pinned executable per boot | Image admission is a prerequisite |
| Build and Buildx | Probe builder and cache placement | Guest Docker builder or BuildKit | Unsupported | Out of minimum route |
| Compose, service discovery, volumes and ports | Probe actual plugin calls and data integrity | Guest Docker; bind mounts and ports require individual probes | Unsupported | Out of minimum route |
| Persistent exec, attach, logs, events and cp | Probe each operation | Guest Docker/containerd | Bounded per-launch streams and native control | Attach, wait and inspect only after explicit verification |
| Fresh and one-use prepared native launch | Unsupported | Separate endpoint | Supported for static ARM64, no network | Only operations proven to dispatch to the same owner |
| Verified guest cleanup | Unknown at Docker acknowledgement | Unknown unless independently verified | Explicit terminal cleanup | Must be independently verified |

Probe means the comparison will test semantics rather than assuming that a
Docker-compatible version string guarantees support. Record requested and
observed VM vCPUs, memory, kernel and runtime backend. Record effective
container resources from inspection and guest probes when available. Unknown
or different resource enforcement limits equivalence conclusions.

## Workloads and boundaries

- Use pinned Alpine for true, pre-created start, stop, kill, restart and removal.
  The observable canary uses Alpine's shell with fixed stdout and stderr
  markers and deliberate exit 23. Validate the streams and real exit status.
- The reusable generated static archive and its executable share byte identity
  with the historical native probe. Native claims are timed separately and
  include ready-slot refill in the throughput window. Never use this payload
  as a substitute for Docker build, Compose, or an ordinary Alpine lifecycle.
- For images, use pinned Alpine and Node (small and multilayer) with a
  task-owned registry where both engines can reach it. Keep public pulls
  separate. Cold requires absence of the manifest and relevant layers in an
  isolated store. Removing only a tag or selecting a fresh VM with a reused
  image store does not establish a cold sample.
- Build real small Rust, Go and Node programs with deterministic output. Use
  the pinned base per language and local versioned dependencies for offline
  dependency mutations. Change only one source or dependency input per case.
  Record builder/driver/version, preload bases before the cold-builder case
  and verify both built output and export/load. If isolating a builder cache
  requires pruning another workload, stop that scenario.
- Compose uses a two-service app and Redis, pinned Alpine and Redis, a
  dedicated project network and named volume. Readiness requires the app to
  perform a write/read transaction through its Redis dependency. Use a unique
  loopback host port only for the publish test. Pre-pull both images.
- Persistent exec/control uses Alpine and hashes deterministic files across
  copies. Storage distinguishes writable layers, named volumes and host
  bind mounts; use verified 4 KiB records and a 16 MiB dataset. Use a 60 s
  service interval to validate DNS, TCP, churn and data persistence. Keep
  host paths, images, build contexts and backing files on ExternalSSD.

Time Docker API at create submission through wait and successful removal
acknowledgement. Record start, exit and removal separately. Time the real
Docker CLI from spawn through process exit, including attach/output as used
by the workload. Check output and the exit result. Record app readiness
separately from HTTP acknowledgement, and verified guest cleanup separately
from API removal. Use monotonic time on the observing host. Exclude VM boot
from warm operation windows. Retain cold acquisition, prep, refill and miss
costs in separate fields.

## Sequencing, statistics and failure rules

Run a pilot separately. Run five paired independent boots with alternating
Docker engine order and the frozen counts in the manifest. Run baseline,
optimized Docker if qualified, and native surfaces serially. Never overlap
a measurement window with builds, VM boots or another benchmark engine.
Use a warm image and resident VM for lifecycle. Each eligible fresh lifecycle
scenario has 2,000 measured operations per session, excluding the ten warmups.
Cache-state suites use independent run counts in the manifest. Include restarts
and recovery in their own rows. The declared concurrency sweep is 1, 2, 4, 8,
with admission limits and timeouts enforced and rejections reported.

Report nearest-rank p50/p95/p99, success and failure counts, and throughput
from complete elapsed windows. A p99 with fewer than 100 observations
describes a session tail only. Compute 95% paired-session percentile-bootstrap
intervals over log ratios of session medians and p99 values, using 10,000
resamples with seed 615026. Report those intervals with the raw five pairs.
Call a lane faster or slower at a timing boundary only if correctness,
matched work and resource evidence pass and the interval clears a 5% effect
in the appropriate direction. Otherwise use inconclusive or unsupported.
No dropped slow samples, no automatic retries, and preserve partial
sessions and failures. Redo a session only after correcting a documented
cause, keeping both reports and their revisions.

The original SPEED-008 comparative verdict remains unresolved. This
contract does not pass its second-host, energy, equivalent Kiri guest
teardown, or sub-1 ms research gates. A result can qualify a measurement
row without establishing general runtime superiority.

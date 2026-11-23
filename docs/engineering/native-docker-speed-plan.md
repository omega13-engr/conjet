# Native Docker speed and compatibility plan

## Decision and scope

The candidate is the release-optimized native Conjet architecture selected by
default in the isolated `conjet-speedup` context. Official Kiri 0.2.2 is the
pinned comparison engine. The installed production context is unchanged.
This plan supersedes further legacy Docker/containerd timing repetitions as
the development priority. Historical results remain valid only for their
recorded binaries, workloads and boundaries.

The purpose is to improve the actual Docker experience: launch, images, exec,
storage, networking, builds and Compose. This requires implementing missing
native capabilities before measuring them. It is not a claim that the current
single-image, non-root, no-network adapter already replaces Docker.

Implementation is deliberately fixture-led. Each task below adds one defined
capability or one measurement group. Unsupported options return an explicit
error before allocation. There is no automatic legacy fallback. A task cannot
claim native execution if a hidden Docker/containerd service executes its work.
Native compatibility is narrower than full Docker compatibility until proven.

## Evidence and initial targets

The five-pair release series at `cabbea9` recorded 40,000 successful operations.
Native-backed Docker API p50 was 3.408–3.587 ms versus Kiri's 4.045–4.494 ms.
Docker CLI p50 was 22.900–23.091 ms versus 21.147–21.740 ms. API median ratio
was 0.841; CLI p50/p99 ratios were 1.076/1.099. API tail superiority was
inconclusive. These are warm no-network Alpine results, not general application
or build results. See [the detailed report](docker-benchmark-results.md).

The immediate goal is Docker CLI parity: the upper endpoint of the paired
95% interval for candidate/Kiri p50 and p99 must be at most 1.05. Preserve
the API median advantage against Kiri and check for regression against the
frozen native baseline. For each later workload, report parity using the same
latency rule and throughput ratio lower endpoint at least 0.95. A superiority
claim uses the report's predeclared 5% practical threshold, not just a lower
point estimate. Inconclusive and slower outcomes remain in the report.

These are proposed engineering targets, not measured promises. They do not
replace SPEED-008's original research criteria. Sub-1 ms p99, second-host
coverage, equivalent Kiri guest cleanup and privileged energy remain deferred.
No overall Docker win may be inferred from one passing operation.

## Architecture

```text
Unmodified Docker / Buildx / Compose clients
                     |
       conjet-speedup private Unix socket
                     |
       Native Docker lifecycle owner (Rust)
       | IDs, image metadata, events, limits |
       | bounded admission, explicit errors |
                     |
       authenticated persistent connection
       boot generation + request/workload IDs
                     |
             Jetstream guest supervisor
          /          |          \
   OCI image root  workload    network/volume
   immutable CAS   lifecycle   resource owners
                     |
           native isolated Linux process

Output ---------> bounded attach/exec stream
Exit -----------> wait / exit status
Cleanup complete -> removal acknowledgement / capacity reuse

Buildx -> pinned BuildKit container managed by native owner
          -> explicitly identified build-executor backend
Compose -> same native owner for every app/database service
```

The guest owns process and resource cleanup. The host owns Docker identities
and client subscriptions. One authority commits each lifecycle transition.
Connection loss never authorizes a second launch. Reconnect inspects the
original operation; unresolved ownership blocks reuse until reconciled.
Do not shorten measurements by changing removal to precede verified cleanup.

The current Python adapter is a compatibility reference, not the final runtime
dependency. Its request traces and negative tests must survive the Rust port.
Do not remove authentication or weaken sandbox controls for speed. Keep the
25 ms host tick until the known tick-disabled stall is independently fixed.

## Narrow implementation sequence

The executable checklist is SPEED-027–045 in the [task board](task-board.md).
SPEED-027 starts from completed SPEED-018 without waiting for legacy benchmark
completion or release credentials. Thereafter follow explicit dependencies.

1. Trace one real Docker run; measure client requests and completion boundaries.
2. Reuse a boot-bound native connection; verify ambiguous-disconnect handling.
3. Reduce terminal/output round trips while preserving completion semantics.
4. Port the verified Docker owner to Rust and compare to its Python reference.
5. Stage a pinned multilayer OCI fixture with correct whiteout handling.
6. Add native pull/inspect/remove using a verified content-addressed image store.
7. Admit bounded concurrent workloads with independent lifecycle ownership.
8. Implement persistent exec and bounded attach/log streaming on the native path.
9. Implement one private bridge and service-name DNS fixture.
10. Implement one loopback published-port fixture and verified teardown.
11. Implement named-volume and explicitly scoped ExternalSSD bind fixtures.
12. Boot the pinned BuildKit worker through native and verify build output.
13. Run the exact Node/Redis Compose fixture through native lifecycle operations.
14. Measure matched API/CLI launch after freezing the compatible candidate.
15. Measure the existing Rust/Go/Node build cache matrix using that candidate.
16. Measure the existing Compose and exec/control scenarios using that candidate.
17. Measure the existing storage/network/service scenarios using that candidate.
18. Measure bounded concurrency, pressure and recovery on the native candidate.
19. Publish the same-format comparison and audit every backend/claim.

BuildKit is a separate execution layer: a native-managed BuildKit container
does not prove its build steps use Conjet's launch service. Record the actual
worker/executor, versions and limits. Use the same supported BuildKit worker
configuration on both engines. No privileged worker shortcut is allowed:
implement the necessary namespaced capability contract with isolation tests,
or leave the build capability blocked and documented. Never substitute host
builds or a legacy Docker daemon. Any additional substantial prerequisite
must become a narrow task with a fixture, not an undocumented workaround.

The non-root fixture cannot justify enabling guest root, arbitrary capabilities,
or unrestricted mounts. Extend credentials and syscalls only for demonstrated
application needs, with negative isolation tests and explicit admission rules.

## Measurement contract and report compatibility

Continue the frozen workload identities and result schema from
[docker-benchmark-plan.md](docker-benchmark-plan.md) and
[docker-comparison-v1.json](../../benchmarks/scenarios/docker-comparison-v1.json).
Version the manifest for native backend requirements and new capabilities;
preserve the prior file and results. Pin the versioned manifest digest before
collecting qualification samples. Reuse the same images, commands, cache
cases, limits, client versions and timing definitions. If a change is necessary,
declare it before timing and rerun both engines; never merge unlike series.

Extend [docker-benchmark-results.md](docker-benchmark-results.md) with a clearly
dated/revisioned native-default series. Keep historical development and legacy
tables intact and labeled. Preserve these table shapes and units:

```text
| Pair | Engine | API p50 / p95 / p99 (ms) | API ops/s | CLI p50 / p95 / p99 (ms) | CLI ops/s |
| Boundary | Percentile | Ratio | 95% interval | Verdict at the declared 5% threshold |
| Operation | Conjet p50 / p95 / p99 (ms) | Kiri p50 / p95 / p99 (ms) |
| Fixture and cache state | Conjet p50 / p95 / p99 (ms) | Kiri p50 / p95 / p99 (ms) |
| Engine and fixture | CPU s | Peak MiB | Read MiB | Written MiB |
| Concurrency | Conjet p50 / p95 / p99 (ms) | Conjet launches/s | Kiri p50 / p95 / p99 (ms) | Kiri launches/s |
| Workload | Executing backend | Coverage and verdict |
| Artifact | Evidence folder |
```

Retain environment/artifact SHA-256 tables, sample and failure counts, image
digests, effective limits, request traces, raw evidence and cleanup witnesses.
Add backend and implementation revision in accompanying metadata rather than
renaming legacy measurements into native results. Preserve fresh/prepared,
refill/miss, first/cached pull and build cache-state distinctions.

Run five independent alternating boot pairs; lifecycle uses 2,000 measured
operations per engine, lane and boot plus ten warmups, matching the recent
series. Other workloads retain the frozen suite repetition counts and five-pair
requirement. Use the existing paired bootstrap method and seed. Profile in
separate diagnostic runs; qualify without diagnostic tracing and include a
trace-overhead check. Failures stay in raw data and denominators.

Build release-optimized CLI, host VMM and guest from the same reviewed source.
Record build commands, optimization settings, hashes and signing identity.
Do not mix a release guest with development host code in a release comparison.
Kiri stays the official pinned binary. Both engines use the same unmodified
Docker client. Align credentials/security options and effective guest controls.

Measure host elapsed time with one monotonic clock. Guest-local spans are
separate; do not subtract unsynchronized host/guest timestamps. Time direct API
and CLI independently; do not infer CLI overhead by subtracting unrelated
medians. Keep Kiri removal acknowledgement and unknown guest teardown explicit.

## Isolation, correctness and completion

Use private Docker configuration, `conjet-speedup` and `kiri-speedup` endpoints,
session-owned foreground services and task-specific resources. All generated
builds, caches, VM disks and evidence belong under ExternalSSD scratch. Avoid
overlapping builds and timed benchmarks. Preserve production and capture
before/after identities and endpoint. No global prune or startup registration.

Every capability requires success, malformed/unsupported input, cancellation,
disconnect, resource exhaustion and cleanup tests appropriate to its scope.
Prepared capacity and active workload accounting remain bounded. Verify data
integrity after pressure and VM memory reclamation. Error responses cannot
silently turn failed work into latency successes.

Completing a measurement task requires accurate coverage, not a manufactured
win. A failed parity target creates a concrete profile-driven follow-up task.
An implementation task remains open if its required capability is unavailable.
Do not call the whole Docker experience native-ready until every declared
operation is supported and verified on the native candidate.

The existing PR, independent review, CI, packaging, signing and notarization
requirements still apply. This document authorizes no production replacement
or publication by itself. Promotion must state the exact supported capability
matrix and retained limitations; the installed production runtime is untouched
throughout development and benchmarking.

# Docker and native comparison results

This report covers the M1 Pro experiments completed to date. It separates
the existing Docker engines, static native API/CLI and the opt-in Docker
adapter backed by native OCI. The program's frozen comparison contract
requires five independent pairs. The retained local data support
descriptive results at the stated boundaries. SPEED-008 remains unresolved.

[Protocol and workload manifest](docker-benchmark-plan.md)
[Supported optimized Docker route](docker-native-adapter.md)

## Existing Docker lifecycle

The baseline runtime was built from `7e075c0`. Conjet used Core Docker with
`runc` and `6.12.86-conjet`; Kiri used the verified official 0.2.2 binary,
Kiri's own runtime and `6.18-kiri`. The client was pinned Docker 29.10.0
with API 1.44. Both guests reported two vCPUs and passed the cgroup canary
with a 16 MiB limit, four PIDs and 500 millicores. Kiri's /info reported
zero memory, so its effective guest total is unknown.

This is pair 2 of five for the Alpine true, no-network API row. Each engine
completed 2,000 samples with no failures. The host monotonic window begins
at create and ends at Docker removal acknowledgement. Verified guest
teardown is unknown on both Docker endpoints.

| Engine | p50 / p95 / p99 (ms) | Successes/s |
| --- | ---: | ---: |
| conjet | 594.953/819.515/871.010 | 1.680 |
| kiri | 3.944/4.742/6.988 | 245.481 |

The Conjet stage medians were 57.924 ms create, 265.928 ms start,
240.407 ms wait and 20.176 ms remove. These are stage medians rather than
components of an individual p50 operation. Start and wait dominate this
observation. The existing Conjet path was slower in this pair. The
comparative verdict remains inconclusive pending the other boot pairs,
matched observability and the predeclared uncertainty analysis.

## Earlier Docker pilot

The pilot ran 20 operations per workload, network and timing boundary on
each engine. It retained zero timing failures. The CLI uses the actual
`docker run --rm` client. The stream canary's API row includes fetching and
validating stdout/stderr after exit. A pilot p99 is a session tail
description. It is outside the qualifying sample set.

| Engine | Payload | Network | Boundary | p50 / p95 / p99 (ms) |
| --- | --- | --- | --- | ---: |
| conjet | alpine-true | none | api | 372.224/430.887/492.325 |
| conjet | alpine-true | none | cli | 475.638/516.578/534.748 |
| conjet | alpine-true | bridge | api | 451.544/487.017/495.637 |
| conjet | alpine-true | bridge | cli | 559.315/585.809/630.800 |
| conjet | alpine-stream-exit | none | api | 406.369/460.264/491.683 |
| conjet | alpine-stream-exit | none | cli | 528.331/575.168/582.538 |
| conjet | alpine-stream-exit | bridge | api | 533.041/570.922/589.077 |
| conjet | alpine-stream-exit | bridge | cli | 616.042/665.127/690.724 |
| conjet | common-static | none | api | 434.726/459.704/470.337 |
| conjet | common-static | none | cli | 528.171/593.384/882.863 |
| conjet | common-static | bridge | api | 512.440/567.635/569.120 |
| conjet | common-static | bridge | cli | 624.042/682.594/690.378 |
| kiri | alpine-true | none | api | 3.966/4.288/4.319 |
| kiri | alpine-true | none | cli | 20.632/21.438/21.500 |
| kiri | alpine-true | bridge | api | 31.063/46.258/50.797 |
| kiri | alpine-true | bridge | cli | 52.292/67.287/72.212 |
| kiri | alpine-stream-exit | none | api | 3.940/4.442/4.898 |
| kiri | alpine-stream-exit | none | cli | 20.707/21.662/23.769 |
| kiri | alpine-stream-exit | bridge | api | 42.574/53.411/55.706 |
| kiri | alpine-stream-exit | bridge | cli | 47.319/68.066/72.062 |
| kiri | common-static | none | api | 3.874/4.232/4.277 |
| kiri | common-static | none | cli | 20.852/21.533/22.619 |
| kiri | common-static | bridge | api | 35.375/60.690/63.595 |
| kiri | common-static | bridge | cli | 48.585/67.928/68.262 |

Both engines passed the separate Redis Compose write/read and DNS probe,
image save/inspect, persistent exec, named-volume persistence, pre-created
start, stop, restart and kill. The embedded BuildKit canary passed on
Conjet. Kiri started a task-owned pinned BuildKit separately. That
bootstrap alone does not measure a build. Both failures of the initial
Compose applet choice and the successful Redis correction were retained.

## Buildx first session

The first Buildx pair used the pinned BuildKit v0.23.2 `docker-container`
driver and a fresh owned build volume for each repetition. On Conjet all
three Rust and Go results per cache state loaded and ran the expected
artifact. The median combined build-and-export times in milliseconds are
descriptive for this session.

| Conjet workload | Empty | Unchanged | Source change | Dependency change |
| --- | ---: | ---: | ---: | ---: |
| Rust | 1556 | 739 | 1122 | 1089 |
| Go | 5165 | 768 | 5368 | 5320 |

All three Conjet Node empty builds exported and loaded, then failed the
execution canary with `MODULE_NOT_FOUND`. Those are failed operations.
Kiri bootstrapped the pinned worker but Docker Hub HTTPS timed out inside
the worker for all three build fixtures. Kiri has no timed rows in this
pair. The correction uses npm's local package install mode and provides
both workers with the same verified OCI bases outside the timing window.

Pair 2 ran the corrected harness at `1253da3`. Both engines completed
36 build/exports and 36 loads on BuildKit v0.23.2. All 36 final images
on each engine passed the artifact canary. Buildx used a fresh guest worker
volume per repetition on both engines. The named OCI contexts were local,
platform-pinned and checked against the original registry manifests.

| Fixture and cache state | Conjet p50 / p95 / p99 (ms, rounded down) | Kiri p50 / p95 / p99 (ms, rounded down) |
| --- | ---: | ---: |
| Rust empty | 1645/1729/1729 | 929/990/990 |
| Rust unchanged | 749/908/908 | 255/255/255 |
| Rust source | 1148/1401/1401 | 851/965/965 |
| Rust dependency | 1129/1744/1744 | 594/937/937 |
| Go empty | 5148/5211/5211 | 4697/5048/5048 |
| Go unchanged | 774/863/863 | 253/259/259 |
| Go source | 5166/5256/5256 | 4439/5760/5760 |
| Go dependency | 5188/5260/5260 | 4706/4875/4875 |
| Node empty | 9653/9765/9765 | 6148/6265/6265 |
| Node unchanged | 4102/4410/4410 | 427/521/521 |
| Node source | 4063/4082/4082 | 595/1082/1082 |
| Node dependency | 9526/9952/9952 | 6283/6405/6405 |

These are three observations per engine per row, timing build plus export.
The separate load and base-preload samples are in the raw files. Kiri's
median was lower for every workload in this pair. The Buildx verdict
remains inconclusive until the remaining compatible pairs and matched
builder resource evidence are available.

## Compose first pair

Both existing Docker engines completed the real Node/Redis workload in
pair 1 on harness `4a6de79`. Each transition had five measured repetitions
and zero failures. The service checked loopback HTTP access, Redis DNS and
persisted writes across recreation, scaling and restart. The project-label
inventories confirmed container, volume and network removal. Recovered
application readiness after restart has two observations per repetition.

| Operation | Conjet p50 / p95 / p99 (ms) | Kiri p50 / p95 / p99 (ms) |
| --- | ---: | ---: |
| Pre-pulled up through readiness | 3862.057/3880.813/3880.813 | 3084.952/3088.987/3088.987 |
| No-change up | 807.818/822.755/822.755 | 568.551/572.975/572.975 |
| Recreate application | 12230.160/12244.529/12244.529 | 11596.764/11603.672/11603.672 |
| Scale application to two replicas | 2036.748/2081.174/2081.174 | 1579.969/1583.479/1583.479 |
| Redis restart acknowledgement | 440.526/486.949/486.949 | 156.248/205.001/205.001 |
| Application readiness after restart | 17.690/41.309/41.309 | 2.670/22.628/22.628 |
| Down through Compose exit | 3125.345/3175.384/3175.384 | 2168.131/2190.062/2190.062 |

This pair observed lower Kiri timings for these scenarios. The Compose
verdict remains inconclusive until the remaining four independent pairs
and effective-resource equivalence checks are available. The native routes
have no Compose implementation.

## Separate native timings

The static workload uses the same pinned payload bytes as the
`common-static` Docker image. Claim/fresh API timing stops at verified
guest cleanup. The host CLI starts a new process and validates output.
Prepared throughput charges slot refill. The raw report includes expiry
and spent-slot misses. The staged native OCI Docker adapter uses ordinary
dynamically linked Alpine and a required explicit UID/GID of 65532. It
also verifies guest cleanup. Docker comparison cases above use their own
image defaults. These native and Docker observations have separate scopes.

| Pilot lane | p50 / p95 / p99 (ms) |
| --- | ---: |
| Static native fresh_api | 2.494/8.538/9.560 |
| Static native prepared_api | 1.957/7.322/7.907 |
| Static native prepared_api refill | 1.216/1.785/7.298 |
| Static native fresh_cli | 23.027/24.285/24.654 |
| Static native prepared_cli | 21.945/24.335/28.818 |
| Static native prepared_cli refill | 21.000/22.381/22.611 |
| Docker-to-native cli | 49.665/73.545/74.066 |
| Docker-to-native api | 28.178/36.373/37.600 |

The 20-sample Docker-to-native pilots used the unmodified Docker client
for CLI and HTTP create/start/wait/removal for API. Terminal Docker event
attributes tied execution to a real Jetstream handle and recorded
verified guest cleanup. No performance claim follows from these pilot
numbers.

## Coverage and retained evidence

The full suite remains underway. Image, builds, Compose, control, storage
and concurrency are separate modes. Their results require scenario-level
validation. The native Docker route supports the documented no-network
fresh OCI subset. Docker build, Compose, persistent exec and service
networking use the existing engine where supported.

Evidence root is
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence`.
It retains actual commands, runtime and harness revisions, binary hashes,
image digests, raw samples, CPU/RSS/footprint, production snapshots,
failed attempts and shutdown checks.

| Artifact | Evidence folder |
| --- | --- |
| Launch, pin and teardown preflights | `SPEED-016` |
| Native and Docker pilots and capability checks | `SPEED-017` |
| Rootfs receipts, backend audit and Docker-to-native pilot | `SPEED-018` |
| Full paired no-network API row | `SPEED-019/alpine-true-none-api-pair-2` |
| First observed image operations and manifest reporting discrepancy | `SPEED-020/pair-1` |
| First Buildx results and retained artifact/egress failures | `SPEED-021/pair-1` |
| Corrected Buildx cache-state matrix and artifact validation | `SPEED-021/pair-2` |
| First Compose pair and transaction/teardown canaries | `SPEED-022/pair-1` |

Production stayed in service throughout. The records preserve unknown
guest teardown, unmeasured energy and observed contention. The original
second-host and sub-1 ms research requirements remain deferred.

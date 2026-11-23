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

Production stayed in service throughout. The records preserve unknown
guest teardown, unmeasured energy and observed contention. The original
second-host and sub-1 ms research requirements remain deferred.

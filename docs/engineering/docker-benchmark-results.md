# Docker and native comparison results

This report covers the M1 Pro experiments completed to date. It separates
the existing Docker engines, static native API/CLI and the opt-in Docker
adapter backed by native OCI. The program's frozen comparison contract
requires five independent pairs. The retained local data support
descriptive results at the stated boundaries. SPEED-008 remains unresolved.

[Protocol and workload manifest](docker-benchmark-plan.md)
[Supported optimized Docker route](docker-native-adapter.md)

## Measured environment

The machine was an Apple M1 Pro with 16 GiB RAM, macOS 27.2.1 (`26B131`)
and an APFS ExternalSSD benchmark root. Production Conjet remained active.
Each launcher recorded process identities, VM backing paths, host load,
CPU time and RSS before and after its measurements. Docker 29.10.0,
Buildx 0.39.1 and Compose 5.8.0 were pinned throughout. The existing
Conjet Docker and opt-in native host binaries were development builds.
The Linux native supervisor was a release build. These timings describe
the measured binaries and host conditions.

| Runtime artifact | SHA-256 |
| --- | --- |
| Conjet baseline VMM | `b7b7b489f6da12a9f048c31800a8acce33cc6cd7f855c026b254b3cd6d17445e` |
| Conjet candidate VMM | `49992b4166bd4692fd8226e29e935046fab3f344dbf1ad89e73980da7e5f13d6` |
| Candidate native supervisor | `6a3839855383e674e59a854fa197e56c2489c09d2594665b702dbcd733f0f42a` |
| Official Kiri daemon | `c5cd8edefc69d3e4de4cf38a8149d07d6c4c4f1d522167c890541c17f2630884` |

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

## Image acquisition and readiness

Pair 2 used harness `8e10fd0` and passed both pinned Alpine and Node config
checks, five timed warm save/load and execution repetitions per image and
owned-registry cleanup. Pinned public pulls have external registry effects.
The private loopback fixture uses digest-bound images uploaded directly via
HTTP before either engine's first pull. Complete config and layer transfer
was observed in all ten measured Kiri first pulls. Conjet's client reported
downloads, while the host timestamp filter produced no registry-side witness
for its first pulls. That transfer boundary remains unknown in this pair.
The next run keys the witness by a unique repository and avoids cross-clock
timestamp filtering.

| Loopback operation | Conjet p50 / p95 / p99 (ms) | Kiri p50 / p95 / p99 (ms) |
| --- | ---: | ---: |
| Small first pull | 175.896/212.253/212.253 | 58.676/74.316/74.316 |
| Small cached pull | 102.292/113.368/113.368 | 34.187/42.566/42.566 |
| Multilayer first pull | 184.644/190.982/190.982 | 68.765/81.037/81.037 |
| Multilayer cached pull | 97.623/107.218/107.218 | 33.614/34.553/34.553 |

After VM readiness, `/info` reported 2,094,825,472 guest bytes for Conjet
and 2,088,570,880 for Kiri. `/proc/meminfo` corroborated live Kiri guest
memory in this run. Earlier sessions that queried metadata before Kiri VM
startup still have unknown guest memory. The image comparison remains
inconclusive pending complete paired transfer and cache-state evidence.

Pair 3 used `b31afde` with unique registry repositories per repetition.
Both engines witnessed the complete config and layer transfer for all ten
measured first pulls. Both passed cached pulls, archive and runnable-image
checks and verified removal of the labeled registry store. Each row has
five timed samples per engine with no failures.

| Loopback operation | Conjet p50 / p95 / p99 (ms) | Kiri p50 / p95 / p99 (ms) |
| --- | ---: | ---: |
| Small first pull | 120.608/152.502/152.502 | 62.603/67.012/67.012 |
| Small cached pull | 94.184/112.049/112.049 | 34.752/42.774/42.774 |
| Multilayer first pull | 171.621/197.132/197.132 | 73.838/76.742/76.742 |
| Multilayer cached pull | 100.036/114.363/114.363 | 32.208/50.546/50.546 |

The later five-pair series froze harness `20e3a2b`. It produced 25 valid
samples per engine for each small and multilayer first-pull and cached-pull
row. All first pulls confirmed transfer of every expected config and layer
byte. Each launcher verified production preservation and removal of all
12 owned registry images, including warmups. These complete pairs pass the
frozen effect threshold for **Kiri faster** at the loopback Docker CLI pull
boundary. This verdict applies to the two controlled fixtures on the M1 Pro.

| Loopback operation | Conjet/Kiri p50 ratio with 95% CI | Conjet/Kiri p99 ratio with 95% CI |
| --- | ---: | ---: |
| Small first pull | 2.129 [1.947, 2.329] | 2.177 [1.910, 2.516] |
| Small cached pull | 2.756 [2.440, 3.055] | 2.512 [2.202, 2.921] |
| Multilayer first pull | 2.471 [2.238, 2.730] | 2.649 [2.329, 3.188] |
| Multilayer cached pull | 2.599 [2.273, 2.985] | 2.849 [2.574, 3.154] |

The p99s are session tail observations from five samples per session. The
intervals resample the five independent paired boots. Median session archive
rates in MiB/s were 14.68 save and 53.42 warm load for Alpine on Conjet,
and 111.16 save and 61.80 warm load on Kiri. For Node they were 16.24 and
91.70 on Conjet, and 497.70 and 267.30 on Kiri. Size derives from the
actual saved archive. Save and load are distinct from registry transfer.

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

Pair 2 on `b31afde` repeated the five measured transitions with zero
failures. Both engines reported the requested effective 128 MiB,
64-PID and 500-millicore limits for each service. Pre-pulled startup p50,
p95 and p99 were 3890.375/4286.321/4286.321 ms for Conjet and
3117.938/3144.268/3144.268 ms for Kiri. All other transition distributions
are in the per-session report. Pair 1 predates the cgroup check, so it is
descriptive alongside pair 2. Three more independent pairs remain, plus a
repeat of the first pair with effective-resource verification.

## Persistent exec and control

Pair 2 used harness `7be17a3` and separate long-lived Alpine containers.
Both engines completed 100 measured operations per row with zero failures.
The direct API exec boundary includes exec create, multiplexed stream read
and exit inspection. Attach verifies stdin, separate stdout and stderr and
exit 23. Event timing stops when the last expected event arrives. The
runner closes the client after that witness. Both engines passed the 128
KiB output canary, TTY check, disconnect/recovery and file-copy SHA-256s.

| Operation | Conjet p50 / p95 / p99 (ms) | Kiri p50 / p95 / p99 (ms) |
| --- | ---: | ---: |
| CLI exec | 204.116/247.242/271.976 | 19.518/26.557/29.205 |
| API exec | 124.726/157.679/168.346 | 1.971/2.373/2.481 |
| CLI inspect | 66.337/90.468/98.080 | 17.495/20.864/23.422 |
| API inspect | 26.973/43.660/48.843 | 0.167/0.226/0.285 |
| CLI list | 67.610/93.181/99.688 | 17.417/20.615/24.271 |
| CLI attach | 171.394/214.125/238.951 | 19.755/22.935/24.301 |
| CLI logs | 87.161/118.353/130.899 | 17.710/20.445/24.672 |
| CLI event witness | 73.962/88.572/92.215 | 16.955/20.978/22.252 |
| Copy in 4 KiB | 111.730/143.656/146.853 | 18.733/22.127/24.333 |
| Copy out 4 KiB | 91.435/107.020/112.752 | 18.237/21.435/25.175 |
| Copy in 8 MiB | 219.933/253.505/277.380 | 50.297/59.938/66.015 |
| Copy out 8 MiB | 382.461/416.609/462.845 | 49.377/59.972/73.634 |

The canceled first Conjet half retained 17 empty historical event streams
and passed shutdown. The corrected run verifies actual bounded event
delivery. Kiri's medians were lower in that pair. The comparison remains
inconclusive pending independent pairs. Native OCI supports its own bounded
noninteractive attach and event snapshots. Persistent exec, TTY, logs and
copy measurements use the existing Docker engines.

## Storage and sustained service

Pair 1 used harness `187e1ab`. Both existing engines passed writable-layer
and named-volume checks, including readback of the fsynced 16 MiB file in
a second container. Kiri also passed the ExternalSSD host bind and host
checksum. Conjet's existing Docker endpoint rejected the host path before
execution on all five samples and the warmup. There is no matched host-bind
timing for this configuration. The native routes provide no equivalent
host bind or service networking.

| Operation | Conjet p50 / p95 / p99 (ms) | Kiri p50 / p95 / p99 (ms) |
| --- | ---: | ---: |
| Writable-layer workload through Docker CLI | 607.414/666.240/666.240 | 138.929/144.456/144.456 |
| Named-volume workload through Docker CLI | 570.061/640.078/640.078 | 132.202/135.301/135.301 |
| ExternalSSD host bind through Docker CLI | Unsupported in the tested Conjet configuration | 243.153/251.763/251.763 |
| Guest Redis DNS | 3.155/8.540/8.540 | 2.800/2.962/2.962 |
| Guest TCP connection | 1.733/1.960/1.960 | 1.602/1.738/1.738 |
| Guest Redis ping after connection | 1.056/5.441/5.441 | 0.965/1.027/1.027 |
| Host HTTP transaction over a fresh connection | 20.825/41.118/63.657 | 2.754/7.595/24.923 |

The last row uses the separate 60 s Node/Redis service window. Conjet
completed 2,648 verified transactions (44.125/s) and Kiri completed
4,776 (79.590/s), with zero failed checks. Both reported matching guest
cgroup quotas for the app and Redis. The end-of-run app memory snapshots
were 75.66 MiB for Conjet and 14.3 MiB for Kiri. They are point-in-time
observations. The raw files separately retain measured guest fsync and I/O
stages, snapshots, throughput windows and teardown. The comparison remains
inconclusive with one pair and no matching host bind.

## Concurrency and recovery

Pair 1 on harness `187e1ab` completed 100 short Docker launches per
engine at each concurrency level. Each launch requested 16 MiB, four
PIDs, 500 millicores and no network, and validated its output. Both
engines had zero launch failures. These are completed CLI operations per
measured window, including the client's process start and output.

| Concurrency | Conjet p50 / p95 / p99 (ms) | Conjet launches/s | Kiri p50 / p95 / p99 (ms) | Kiri launches/s |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 466.385/523.093/531.705 | 2.133 | 20.702/23.656/25.189 | 47.149 |
| 2 | 555.237/641.757/699.436 | 3.477 | 23.770/26.541/29.023 | 79.698 |
| 4 | 716.283/808.878/952.190 | 5.242 | 30.721/37.383/40.443 | 111.789 |
| 8 | 1028.573/1130.959/1148.347 | 7.166 | 50.520/63.729/68.385 | 123.590 |

The separate memory-limit canary did not establish equivalent OOM
attribution. Conjet returned exit 137 while `State.OOMKilled` was false.
Kiri's `docker wait` timed out. Both preserved the running sibling's
data, passed a fresh recovery launch and cleaned up owned resources.
The follow-up fixture verifies the actual guest memory ceiling and
disables swap before imposing pressure. The raw counts above cover launch
concurrency. They do not qualify memory-pressure behavior.

The corrected pressure run in `SPEED-025/pair-2` verified Conjet's
64 MiB memory ceiling and zero swap inside the workload cgroup. Conjet
returned exit 137 with `State.OOMKilled=true`. It preserved the active
sibling's marker and passed the subsequent fresh recovery launch. Kiri's
Docker inspection returned `MemorySwap=0` after the harness requested
64 MiB total memory plus swap. The harness rejected that configuration
before allocating memory. Kiri therefore has no equivalent pressure
measurement with verified limits in this run. The pair still retained
both existing engines' bounded concurrency timings.

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

The later full-budget static product run used harness `4da6d3b` and the
same workload executable. It completed 2,000 measured operations per lane
with no failures. API time begins at admission or claim and ends at
verified cleanup. CLI time covers spawn through exit. Throughput includes
the refill when used, together with harness operations in the measured
window.

| Static native lane | p50 / p95 / p99 (ms) | Full-window successes/s |
| --- | ---: | ---: |
| Fresh API | 2.642/3.867/5.560 | 320.394 |
| Prepared API claim | 1.914/2.532/3.610 | 265.503 |
| Prepared API refill | 1.390/2.056/3.220 | — |
| Fresh CLI | 22.863/26.877/30.774 | 42.758 |
| Prepared CLI claim | 21.965/27.784/33.673 | 22.387 |
| Prepared CLI refill | 21.051/26.627/32.178 | — |

The spent-slot and expired-slot request times were 19.109 and 20.140 ms
respectively through the CLI. Neither includes preparation or expiry
waiting time. The host engine accrued 55.25 s of CPU time during the
sampled boot and had 54.55 MiB RSS at its end. The live checks confirmed
one-use ownership under contention, bounded output, admission backpressure,
expiry, cancellation, preserved active memory under pressure, verified
cleanup with active work at foreground termination and stale-handle
rejection after reboot. Both boots exited cleanly and removed their private
directories. Prepared claims lowered API latency in this session. Refill
reduced measured full-window throughput. This single-session result remains
separate from equivalent Docker and Kiri qualification.

The Docker-to-native source adapter also completed a full-budget session
on `4da6d3b`. Each of the 4,000 measured operations had a unique native
workload ID, exit zero and verified guest cleanup. The live canaries also
passed capacity rejection, force removal and lost Start response handling.
Throughput includes the event verification between operations. The CLI
used the pinned Docker client. The API includes explicit removal. These
operations ran as UID/GID 65532. Existing Docker no-network `true` runs
used the image-default user and measured removal acknowledgement.

| Native OCI Docker lane | Samples | Failures | p50 / p95 / p99 (ms) | Successes/s |
| --- | ---: | ---: | ---: | ---: |
| Docker CLI `run --rm` | 2,000 | 0 | 47.900/54.525/59.707 | 20.411 |
| Docker API lifecycle | 2,000 | 0 | 28.381/33.940/34.537 | 34.063 |

The VMM accrued 26.10 s of CPU time and grew from 146.63 to 152.64 MiB
RSS across the run. The adapter accrued 7.09 s of CPU time, with an
ending RSS of 32.56 MiB. The owned adapter socket and VM session were
removed. This is a separate runtime result with different credentials
and a different cleanup boundary from existing Docker and Kiri.

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
| Full-budget Docker-to-native OCI run with per-operation cleanup witnesses | `SPEED-019/native-oci-full-1` |
| First observed image operations and manifest reporting discrepancy | `SPEED-020/pair-1` |
| Pinned image and loopback registry results with asymmetric transfer proof | `SPEED-020/pair-2` |
| Complete paired registry transfer and labeled-store cleanup | `SPEED-020/pair-3` |
| Five matched image pairs, distribution summary and verified digest cleanup | `SPEED-020/cleanup-qualified`, `SPEED-020/cleanup-qualified/summary.json` |
| First Buildx results and retained artifact/egress failures | `SPEED-021/pair-1` |
| Corrected Buildx cache-state matrix and artifact validation | `SPEED-021/pair-2` |
| First Compose pair and transaction/teardown canaries | `SPEED-022/pair-1` |
| Compose repeat with effective service resource verification | `SPEED-022/pair-2` |
| Canceled historical-event run and corrected paired control matrix | `SPEED-023/pair-1`, `SPEED-023/pair-2` |
| Storage, guest transport and the sustained services | `SPEED-024/pair-1` |
| Launch concurrency, memory attribution and recovery attempts | `SPEED-025/pair-1` |
| Second concurrency pair and corrected Conjet OOM attribution | `SPEED-025/pair-2` |
| Full-budget native static product and active-shutdown canaries | `SPEED-025/native-product-full-1` |

Production stayed in service throughout. The records preserve unknown
guest teardown, unmeasured energy and observed contention. The original
second-host and sub-1 ms research requirements remain deferred.

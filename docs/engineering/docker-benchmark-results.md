# Docker and native comparison results

This report covers the M1 Pro experiments completed to date. It separates
the existing Docker engines, static native API/CLI and the isolated Docker
candidate backed by native OCI. The frozen comparison contract requires five independent pairs
per lane. Each section reports its coverage and verdict at the stated
boundary. SPEED-008 remains unresolved.

[Protocol and workload manifest](docker-benchmark-plan.md)
[Native OCI research scope](docker-native-adapter.md)

## SPEED-065 Docker 29.10.1 comparison

The same optimized `c8cc7059668778a2c54d199d74c2f250ac0b0da4` artifact
set and harness ran all 91 scheduled pairs on the M1 Pro against
official Kiri 0.2.2. Conjet passed the 71-case compatibility gate
before the comparison. The comparison used two vCPUs and a 2,048 MiB
VM configuration. Core dynamic memory remained enabled before and
after timing in all 91 Conjet boots. The six executable SHA-256 hashes
and both engine identities match the raw protocol.
[Exact compatibility and dynamic-memory evidence](native-compatibility.md#docker-29101-optimized-candidate)

| Frozen input | SHA-256 |
| --- | --- |
| Optimized Jetstream | `f1fddf0f5c0e944022db9834aa95731c7fa457da2eb612fb5b8ba2fb77233cb4` |
| Official Kiri 0.2.2 | `c5cd8edefc69d3e4de4cf38a8149d07d6c4c4f1d522167c890541c17f2630884` |
| Docker 29.10.1 | `cb59cf76741a247388e6a84f8defa5054c12dcd5e05d84a3ed8638dac2f34077` |
| Buildx 0.39.1 | `32208f721e053f3cf56741e16c585019f9281e4a1cda9bbbeaee35a32fb0d28f` |
| Compose 5.8.0 | `429abdc8a6c39bb9cdf218203cae37414a38525c70dd7b0bd8c57ead5b552184` |
| Comparison manifest | `2c0875bcd984e256ba25717455ed50360bc7902ed1aa4f7e42794e5279048f68` |

**81 of 91 pairs passed. Full parity and overall superiority remain
unqualified.** All 60 lifecycle pairs passed with 240,000 measured
operations and 1,200 warmups across the two engines, excluding the
pilot. Conjet cleared the 5% advantage threshold at p50 and p99 in
all six API rows and at p50 in all three bridge CLI rows. Ten of the
twelve lifecycle rows met parity. The no-network Alpine output and
common-static CLI p99 upper bounds reached 1.059 and 1.065.

Build pairs 1, 2, 4, and 5 passed for all three languages and all four
cache conditions. In pair 3, the Rust builder timed out pulling the
pinned BuildKit image before its first timed operation. The same
session completed Go and Node. Docker Hub timeouts also blocked the
Node or Redis prepull in Compose pairs 1–4 and the Node prepull for
Conjet's stress OOM check in pair 3. The unchanged failed sessions
remain in the results.

Both engines completed 2,000 measured stress launches each across
concurrency 1/2/4/8. Conjet passed all four OOM checks that reached the
workload, with exit 137 and OOM attribution. Kiri timed out after
20 seconds waiting for exit and reported `OOMKilled=false` in all five
boots. Its Docker and guest limits both showed 64 MiB with zero swap.
The records establish the failed canary and leave the underlying Kiri
cause open.

The tables report medians of per-boot nearest-rank p50, p95 and p99
in milliseconds. Descriptive values include the recorded operations
in partial and unpaired boots. Sample failure counts cover measured
rows and warmups. Setup and verification failures appear separately.
Throughput is the median of complete measured windows. The p99 of
fewer than 100 observations per boot describes a session tail. The
paired ratios use Conjet divided by Kiri and bootstrap the paired log
ratios with 10,000 draws and seed 615026. Five eligible pairs are
required. A timing advantage or disadvantage requires the entire
interval to clear 5%. Parity requires both upper bounds at or below
1.05. Controlled registry pulls have paired estimates. The other
image operations retain their descriptive measurements.

Raw evidence is in `SPEED-065/cj-perf.LBoyR4-full-c8cc70596687/` under
the ExternalSSD evidence root. It includes timestamps, resource
snapshots, all per-boot samples, the aggregation scripts and the
verification of all 182 sessions. The interrupted Docker 29.10.0
cohort remains in `SPEED-065/cj-perf.LBoyR4-full-0e28023a99db/interruption/`.
Every table here uses the Docker 29.10.1 cohort.

### Coverage

| Suite | Passed pairs | Failed pairs |
| --- | ---: | ---: |
| pilot | 1 | 0 |
| lifecycle | 60 | 0 |
| images | 5 | 0 |
| builds | 4 | 1 |
| compose | 1 | 4 |
| control | 5 | 0 |
| storage_network | 5 | 0 |
| stress | 0 | 5 |

### Lifecycle

| Case | Conjet p50/p95/p99 ms | Kiri p50/p95/p99 ms | Samples/failures Conjet, Kiri | Throughput/s Conjet, Kiri | Valid pairs | p50 ratio [95% CI] | p99 ratio [95% CI] | p50, p99, parity |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| alpine-stream-exit/bridge/api | 30.087/47.049/55.908 | 34.815/54.229/61.406 | 10000/0, 10000/0 | 30.42, 28.50 | 5 | 0.863 [0.859–0.869] | 0.909 [0.891–0.924] | faster, faster, met |
| alpine-stream-exit/bridge/cli | 47.313/67.641/75.092 | 51.637/68.109/73.533 | 10000/0, 10000/0 | 19.58, 20.01 | 5 | 0.916 [0.913–0.918] | 1.017 [1.005–1.030] | faster, inconclusive, met |
| alpine-stream-exit/none/api | 3.277/4.134/4.977 | 3.561/4.318/5.689 | 10000/0, 10000/0 | 265.03, 269.99 | 5 | 0.916 [0.913–0.920] | 0.870 [0.784–0.946] | faster, faster, met |
| alpine-stream-exit/none/cli | 21.998/23.143/24.208 | 21.082/21.963/23.098 | 10000/0, 10000/0 | 43.72, 47.25 | 5 | 1.044 [1.040–1.048] | 1.041 [1.017–1.059] | inconclusive, inconclusive, missed |
| alpine-true/bridge/api | 29.889/47.248/55.457 | 34.896/53.051/60.869 | 10000/0, 10000/0 | 30.57, 28.47 | 5 | 0.859 [0.853–0.865] | 0.909 [0.899–0.916] | faster, faster, met |
| alpine-true/bridge/cli | 47.407/67.751/74.846 | 51.668/68.251/72.916 | 10000/0, 10000/0 | 19.53, 20.17 | 5 | 0.918 [0.914–0.922] | 1.020 [0.986–1.046] | faster, inconclusive, met |
| alpine-true/none/api | 2.941/3.741/4.651 | 3.546/4.255/5.276 | 10000/0, 10000/0 | 290.86, 272.55 | 5 | 0.842 [0.823–0.861] | 0.843 [0.736–0.929] | faster, faster, met |
| alpine-true/none/cli | 21.738/22.834/23.947 | 21.034/21.916/23.045 | 10000/0, 10000/0 | 44.25, 47.38 | 5 | 1.035 [1.033–1.039] | 1.042 [1.036–1.048] | inconclusive, inconclusive, met |
| common-static/bridge/api | 30.046/47.108/55.735 | 34.134/52.753/61.069 | 10000/0, 10000/0 | 30.59, 28.65 | 5 | 0.876 [0.866–0.887] | 0.909 [0.896–0.923] | faster, faster, met |
| common-static/bridge/cli | 47.464/67.607/74.804 | 51.139/67.994/72.177 | 10000/0, 10000/0 | 19.49, 20.34 | 5 | 0.931 [0.924–0.940] | 1.029 [1.015–1.043] | faster, inconclusive, met |
| common-static/none/api | 2.978/3.772/4.668 | 3.436/4.172/5.160 | 10000/0, 10000/0 | 288.74, 280.85 | 5 | 0.865 [0.861–0.869] | 0.895 [0.853–0.941] | faster, faster, met |
| common-static/none/cli | 21.919/23.047/24.271 | 21.126/22.118/23.050 | 10000/0, 10000/0 | 43.85, 47.17 | 5 | 1.035 [1.027–1.041] | 1.045 [1.031–1.065] | inconclusive, inconclusive, missed |

### Images

| Case | Conjet p50/p95/p99 ms | Kiri p50/p95/p99 ms | Samples/failures Conjet, Kiri | Throughput/s Conjet, Kiri | Valid pairs | p50 ratio [95% CI] | p99 ratio [95% CI] | p50, p99, parity |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| alpine.cached-public-pull | 17.803/18.086/18.086 | 31.334/38.025/38.025 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| alpine.ready-to-run | 21.801/22.421/22.421 | 21.569/21.951/21.951 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| alpine.remove-tag | 17.692/18.085/18.085 | 31.174/32.576/32.576 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| alpine.save | 48.457/48.931/48.931 | 33.828/37.300/37.300 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| alpine.warm-load | 25.452/26.660/26.660 | 56.500/57.256/57.256 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| node.cached-public-pull | 17.674/18.324/18.324 | 31.393/32.022/32.022 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| node.ready-to-run | 43.603/99.096/99.096 | 41.502/43.439/43.439 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| node.remove-tag | 17.743/18.113/18.113 | 31.803/32.385/32.385 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| node.save | 238.277/243.566/243.566 | 110.476/114.879/114.879 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| node.warm-load | 145.029/150.593/150.593 | 206.518/209.299/209.299 | 25/0, 25/0 | —, — | 0 | — | — | unsupported, unsupported, unsupported |
| registry.multilayer.cached | 18.808/19.052/19.052 | 31.776/31.957/31.957 | 25/0, 25/0 | —, — | 5 | 0.591 [0.582–0.601] | 0.587 [0.536–0.633] | faster, faster, met |
| registry.multilayer.first-pull | 225.645/232.978/232.978 | 67.744/75.526/75.526 | 25/0, 25/0 | —, — | 5 | 3.300 [3.109–3.458] | 3.131 [2.973–3.279] | slower, slower, missed |
| registry.small.cached | 18.251/18.497/18.497 | 31.985/47.833/47.833 | 25/0, 25/0 | —, — | 5 | 0.540 [0.498–0.585] | 0.393 [0.385–0.405] | faster, faster, met |
| registry.small.first-pull | 128.691/168.841/168.841 | 49.656/65.494/65.494 | 25/0, 25/0 | —, — | 5 | 2.511 [2.357–2.665] | 2.300 [1.993–2.566] | slower, slower, missed |

### Buildx

| Case | Conjet p50/p95/p99 ms | Kiri p50/p95/p99 ms | Samples/failures Conjet, Kiri | Throughput/s Conjet, Kiri | Valid pairs | p50 ratio [95% CI] | p99 ratio [95% CI] | p50, p99, parity |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| go.dependency.build-export | 4276.913/4422.330/4422.330 | 4021.053/4176.511/4176.511 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| go.dependency.load | 170.190/173.509/173.509 | 91.902/98.936/98.936 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| go.empty.build-export | 4311.835/4340.489/4340.489 | 4539.403/4648.393/4648.393 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| go.empty.load | 151.638/158.102/158.102 | 90.243/102.833/102.833 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| go.source.build-export | 4308.145/4407.971/4407.971 | 4064.734/4417.206/4417.206 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| go.source.load | 158.430/169.021/169.021 | 88.455/95.788/95.788 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| go.unchanged.build-export | 225.309/234.547/234.547 | 196.207/202.863/202.863 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| go.unchanged.load | 28.808/32.650/32.650 | 90.299/92.479/92.479 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| node.dependency.build-export | 1184.720/1261.991/1261.991 | 6016.257/6115.491/6115.491 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| node.dependency.load | 1188.162/1194.600/1194.600 | 264.207/272.354/272.354 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| node.empty.build-export | 1163.662/1188.345/1188.345 | 6022.931/6128.681/6128.681 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| node.empty.load | 1251.650/1259.323/1259.323 | 253.394/258.655/258.655 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| node.source.build-export | 812.290/836.795/836.795 | 557.828/599.586/599.586 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| node.source.load | 1172.721/1180.380/1180.380 | 238.370/262.379/262.379 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| node.unchanged.build-export | 700.106/721.210/721.210 | 467.139/556.065/556.065 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| node.unchanged.load | 140.837/144.479/144.479 | 222.479/238.969/238.969 | 15/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| rust.dependency.build-export | 516.292/575.724/575.724 | 508.322/547.954/547.954 | 12/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| rust.dependency.load | 144.928/147.012/147.012 | 87.714/88.711/88.711 | 12/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| rust.empty.build-export | 674.337/1199.371/1199.371 | 690.535/927.332/927.332 | 12/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| rust.empty.load | 150.740/153.193/153.193 | 91.371/163.290/163.290 | 12/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| rust.source.build-export | 495.353/552.610/552.610 | 493.666/597.176/597.176 | 12/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| rust.source.load | 145.305/159.669/159.669 | 85.689/145.470/145.470 | 12/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| rust.unchanged.build-export | 223.737/236.448/236.448 | 194.387/200.672/200.672 | 12/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |
| rust.unchanged.load | 26.175/26.674/26.674 | 87.116/135.837/135.837 | 12/0, 15/0 | —, — | 4 | — | — | unsupported, unsupported, unsupported |

### Compose

| Case | Conjet p50/p95/p99 ms | Kiri p50/p95/p99 ms | Samples/failures Conjet, Kiri | Throughput/s Conjet, Kiri | Valid pairs | p50 ratio [95% CI] | p99 ratio [95% CI] | p50, p99, parity |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| compose.down | 2399.595/2414.487/2414.487 | 2126.353/2160.194/2160.194 | 5/0, 25/0 | —, — | 1 | — | — | unsupported, unsupported, unsupported |
| compose.no-change | 570.309/585.549/585.549 | 568.890/570.818/570.818 | 5/0, 25/0 | —, — | 1 | — | — | unsupported, unsupported, unsupported |
| compose.recreate | 10697.188/10710.377/10710.377 | 11620.158/11630.759/11630.759 | 5/0, 25/0 | —, — | 1 | — | — | unsupported, unsupported, unsupported |
| compose.restart | 202.811/246.618/246.618 | 131.899/175.630/175.630 | 5/0, 25/0 | —, — | 1 | — | — | unsupported, unsupported, unsupported |
| compose.restart-ready | 2.816/3.189/3.189 | 2.168/2.565/2.565 | 10/0, 50/0 | —, — | 1 | — | — | unsupported, unsupported, unsupported |
| compose.scale | 582.074/583.500/583.500 | 1578.679/1582.857/1582.857 | 5/0, 25/0 | —, — | 1 | — | — | unsupported, unsupported, unsupported |
| compose.up | 1092.600/1107.051/1107.051 | 3094.126/3105.748/3105.748 | 5/0, 25/0 | —, — | 1 | — | — | unsupported, unsupported, unsupported |

### Control

| Case | Conjet p50/p95/p99 ms | Kiri p50/p95/p99 ms | Samples/failures Conjet, Kiri | Throughput/s Conjet, Kiri | Valid pairs | p50 ratio [95% CI] | p99 ratio [95% CI] | p50, p99, parity |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| attach.stdin-streams | 20.429/33.834/34.895 | 19.731/20.694/21.398 | 500/0, 500/0 | —, — | 5 | 1.034 [1.029–1.040] | 1.625 [1.542–1.682] | inconclusive, slower, missed |
| cp.in.4096 | 19.924/21.090/21.955 | 18.717/19.786/20.588 | 500/0, 500/0 | —, — | 5 | 1.071 [1.060–1.081] | 1.075 [1.028–1.136] | slower, inconclusive, missed |
| cp.in.8388608 | 81.575/88.816/90.046 | 49.887/51.840/52.794 | 500/0, 500/0 | —, — | 5 | 1.677 [1.631–1.731] | 1.712 [1.666–1.746] | slower, slower, missed |
| cp.out.4096 | 19.369/20.244/21.108 | 18.406/19.404/19.923 | 500/0, 500/0 | —, — | 5 | 1.056 [1.046–1.066] | 1.047 [0.987–1.095] | inconclusive, inconclusive, missed |
| cp.out.8388608 | 59.064/61.507/62.425 | 47.902/50.166/51.028 | 500/0, 500/0 | —, — | 5 | 1.233 [1.225–1.241] | 1.210 [1.198–1.223] | slower, slower, missed |
| events.lifecycle | 16.656/17.497/17.922 | 16.883/17.639/17.808 | 500/0, 500/0 | —, — | 5 | 0.986 [0.982–0.989] | 0.975 [0.923–1.010] | inconclusive, inconclusive, met |
| exec.api | 18.226/23.700/26.965 | 1.938/2.316/2.429 | 500/0, 500/0 | —, — | 5 | 9.209 [8.867–9.513] | 11.805 [10.767–13.168] | slower, slower, missed |
| exec.streams | 35.596/44.288/49.220 | 19.655/20.514/21.233 | 500/0, 500/0 | —, — | 5 | 1.805 [1.791–1.816] | 2.271 [2.114–2.440] | slower, slower, missed |
| inspect.api | 0.190/0.260/0.298 | 0.177/0.228/0.242 | 500/0, 500/0 | —, — | 5 | 1.082 [1.050–1.108] | 1.177 [1.108–1.241] | slower, slower, missed |
| inspect.one | 17.929/18.609/19.109 | 17.603/18.328/19.218 | 500/0, 500/0 | —, — | 5 | 1.018 [1.013–1.023] | 1.009 [0.983–1.039] | inconclusive, inconclusive, met |
| list.one | 17.498/18.300/18.670 | 17.449/18.240/18.641 | 500/0, 500/0 | —, — | 5 | 1.005 [1.001–1.009] | 0.994 [0.937–1.053] | inconclusive, inconclusive, missed |
| logs.streams | 17.818/18.531/18.718 | 17.217/18.265/19.291 | 500/0, 500/0 | —, — | 5 | 1.035 [1.032–1.039] | 0.962 [0.912–1.013] | inconclusive, inconclusive, met |

### Storage and networking

| Case | Conjet p50/p95/p99 ms | Kiri p50/p95/p99 ms | Samples/failures Conjet, Kiri | Throughput/s Conjet, Kiri | Valid pairs | p50 ratio [95% CI] | p99 ratio [95% CI] | p50, p99, parity |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| service.guest.dns | 2.719/3.035/3.035 | 2.713/3.070/3.070 | 25/0, 25/0 | —, — | 5 | 1.028 [0.957–1.152] | 1.071 [0.938–1.223] | inconclusive, inconclusive, missed |
| service.guest.redis_ping | 0.987/1.063/1.063 | 0.962/1.098/1.098 | 25/0, 25/0 | —, — | 5 | 0.994 [0.912–1.081] | 1.009 [0.959–1.074] | inconclusive, inconclusive, missed |
| service.guest.tcp_connect | 1.597/1.713/1.713 | 1.565/1.810/1.810 | 25/0, 25/0 | —, — | 5 | 0.994 [0.960–1.035] | 0.966 [0.921–1.013] | inconclusive, inconclusive, met |
| service.transaction | 4.772/7.883/15.645 | 4.576/8.016/14.964 | 24703/0, 24941/0 | 82.32, 83.15 | 5 | 1.040 [1.028–1.054] | 1.032 [0.947–1.111] | inconclusive, inconclusive, missed |
| storage.bind | 1218.837/1496.101/1496.101 | 206.909/217.290/217.290 | 25/0, 25/0 | —, — | 5 | 6.071 [5.752–6.497] | 6.660 [6.157–7.204] | slower, slower, missed |
| storage.bind.guest.random_read | 116.091/146.694/146.694 | 33.824/34.374/34.374 | 25/0, 25/0 | —, — | 5 | 3.557 [3.372–3.921] | 3.946 [3.334–4.364] | slower, slower, missed |
| storage.bind.guest.random_write_fsync | 39.455/43.481/43.481 | 21.875/24.792/24.792 | 25/0, 25/0 | —, — | 5 | 1.842 [1.786–1.906] | 1.750 [1.569–1.935] | slower, slower, missed |
| storage.bind.guest.read_sha256 | 415.239/512.006/512.006 | 22.635/24.315/24.315 | 25/0, 25/0 | —, — | 5 | 19.107 [17.880–20.630] | 19.394 [16.422–22.082] | slower, slower, missed |
| storage.bind.guest.small_file_metadata | 134.346/158.447/158.447 | 38.697/46.235/46.235 | 25/0, 25/0 | —, — | 5 | 3.602 [3.464–3.792] | 3.475 [3.026–3.990] | slower, slower, missed |
| storage.bind.guest.write_fsync | 67.133/77.008/77.008 | 22.704/23.375/23.375 | 25/0, 25/0 | —, — | 5 | 3.031 [2.891–3.190] | 3.308 [3.184–3.488] | slower, slower, missed |
| storage.volume | 119.350/128.054/128.054 | 122.682/135.998/135.998 | 25/0, 25/0 | —, — | 5 | 0.965 [0.949–0.985] | 0.960 [0.926–1.002] | inconclusive, inconclusive, met |
| storage.volume.guest.random_read | 6.089/6.908/6.908 | 5.430/5.939/5.939 | 25/0, 25/0 | —, — | 5 | 1.115 [1.077–1.152] | 0.891 [0.538–1.221] | slower, inconclusive, missed |
| storage.volume.guest.random_write_fsync | 1.584/1.762/1.762 | 14.530/14.881/14.881 | 25/0, 25/0 | —, — | 5 | 0.111 [0.105–0.117] | 0.125 [0.112–0.144] | faster, faster, met |
| storage.volume.guest.read_sha256 | 20.001/21.069/21.069 | 16.936/18.443/18.443 | 25/0, 25/0 | —, — | 5 | 1.169 [1.158–1.181] | 1.060 [0.911–1.193] | slower, inconclusive, missed |
| storage.volume.guest.small_file_metadata | 1.977/2.146/2.146 | 2.025/2.139/2.139 | 25/0, 25/0 | —, — | 5 | 0.997 [0.956–1.046] | 1.019 [0.941–1.105] | inconclusive, inconclusive, missed |
| storage.volume.guest.write_fsync | 21.802/28.744/28.744 | 22.994/23.474/23.474 | 25/0, 25/0 | —, — | 5 | 0.977 [0.854–1.117] | 1.205 [1.166–1.235] | inconclusive, slower, missed |
| storage.writable-layer | 102.941/112.534/112.534 | 126.978/131.044/131.044 | 25/0, 25/0 | —, — | 5 | 0.810 [0.790–0.831] | 0.840 [0.801–0.869] | faster, faster, met |
| storage.writable-layer.guest.random_read | 6.222/6.584/6.584 | 5.941/6.381/6.381 | 25/0, 25/0 | —, — | 5 | 1.028 [0.976–1.077] | 1.040 [0.974–1.104] | inconclusive, inconclusive, missed |
| storage.writable-layer.guest.random_write_fsync | 0.612/0.696/0.696 | 14.748/15.256/15.256 | 25/0, 25/0 | —, — | 5 | 0.042 [0.041–0.044] | 0.046 [0.044–0.048] | faster, faster, met |
| storage.writable-layer.guest.read_sha256 | 20.405/21.078/21.078 | 17.056/18.496/18.496 | 25/0, 25/0 | —, — | 5 | 1.166 [1.118–1.211] | 1.064 [0.892–1.211] | slower, inconclusive, missed |
| storage.writable-layer.guest.small_file_metadata | 1.774/1.853/1.853 | 2.320/2.581/2.581 | 25/0, 25/0 | —, — | 5 | 0.765 [0.719–0.815] | 0.746 [0.678–0.829] | faster, faster, met |
| storage.writable-layer.guest.write_fsync | 2.927/3.565/3.565 | 22.788/27.647/27.647 | 25/0, 25/0 | —, — | 5 | 0.122 [0.107–0.140] | 0.131 [0.108–0.163] | faster, faster, met |

### Stress

| Case | Conjet p50/p95/p99 ms | Kiri p50/p95/p99 ms | Samples/failures Conjet, Kiri | Throughput/s Conjet, Kiri | Valid pairs | p50 ratio [95% CI] | p99 ratio [95% CI] | p50, p99, parity |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| stress.launch.concurrency-1 | 21.773/22.601/24.224 | 21.146/22.108/23.372 | 500/0, 500/0 | 45.47, 46.82 | 4 | — | — | unsupported, unsupported, unsupported |
| stress.launch.concurrency-2 | 24.299/26.089/26.942 | 23.634/25.013/25.700 | 500/0, 500/0 | 79.37, 81.65 | 4 | — | — | unsupported, unsupported, unsupported |
| stress.launch.concurrency-4 | 29.104/32.283/32.916 | 28.659/32.747/33.504 | 500/0, 500/0 | 125.40, 123.11 | 4 | — | — | unsupported, unsupported, unsupported |
| stress.launch.concurrency-8 | 43.796/51.582/53.187 | 43.130/53.209/55.292 | 500/0, 500/0 | 151.11, 146.14 | 4 | — | — | unsupported, unsupported, unsupported |

### Host resources

The table includes all boots with before-and-after host process observations, including attempts that ended during setup or verification. CPU is the elapsed process CPU time, and RSS is the final sample for the recorded engine-specific process set. Disk values describe observed backing-file allocations. Process roles, backing paths, and footprint samples accompany every session.

| Suite | Engine | Complete snapshots | CPU seconds | Final RSS MiB | Allocated disk change MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| builds | conjet | 5 | 207.25 | 598.11 | 39.54 |
| builds | kiri | 5 | 153.15 | 3196.17 | 0.00 |
| compose | conjet | 5 | 7.10 | 391.81 | 0.00 |
| compose | kiri | 5 | 14.31 | 505.41 | 0.00 |
| control | conjet | 5 | 16.35 | 184.05 | 0.00 |
| control | kiri | 5 | 12.97 | 466.52 | 0.00 |
| images | conjet | 5 | 13.41 | 411.25 | 13.52 |
| images | kiri | 5 | 2.30 | 473.75 | 0.00 |
| lifecycle | conjet | 60 | 13.48 | 178.38 | 0.00 |
| lifecycle | kiri | 60 | 12.58 | 437.80 | 0.00 |
| storage_network | conjet | 5 | 53.02 | 497.33 | 0.48 |
| storage_network | kiri | 5 | 32.70 | 1109.80 | 0.00 |
| stress | conjet | 5 | 11.77 | 483.81 | 0.00 |
| stress | kiri | 5 | 31.12 | 672.05 | 0.00 |

### Failures and limits

- Conjet Buildx pair 3 timed out pulling BuildKit for Rust. Go and Node completed.
- Conjet Compose pairs 1–4 timed out pulling Node or Redis. Pair 5 passed.
- Conjet stress pair 3 timed out pulling Node after the measured launch series.
- Kiri failed OOM attribution in stress pairs 1–5. Its launch series passed.
- The isolated native guest cleanup and backing leases closed in all
  Conjet boots. Kiri stopped its private daemon and released its host
  socket and backing. The two native ext4 disks passed detached checks.
  Production fingerprints matched in all 182 sessions.
- Per-workload Kiri guest teardown, second-host replication, energy,
  and the original sub-1 ms research gate remain open.

## SPEED-065 optimized native comparison

The `66a8a90` optimized native candidate passed the [71-case gate](native-compatibility.md#qualified-optimized-candidate)
before timing official Kiri 0.2.2. Both engines used the same M1 Pro,
ExternalSSD, pinned clients and inputs, and a 2-vCPU, 2,048 MiB VM
configuration. Core dynamic memory remained active.

| Suite | Alternating pairs | Result |
| --- | ---: | --- |
| Buildx | 5 | 180 solves/exports, loads and execution canaries per engine passed across Rust, Go and Node. |
| Compose | 5 | 200 measurements per engine passed, including Redis restart and persisted transactions. |
| Control | 5 | 6,000 measurements per engine passed, including independent copy checksums. |
| Storage and network | 5 | Writable layer, volume, ExternalSSD bind and 60-second service windows passed. Conjet completed 24,362 transactions and Kiri completed 24,217. |
| Stress | 5 | Both engines passed 2,000 launches each. Conjet passed all five OOM canaries. Kiri's Docker wait timed out and its OOM flag remained false in all five boots at the verified 64 MiB limit and zero swap. |

Paired Conjet/Kiri median latency ratios included 0.356 for Compose up,
39.734 for Rust dependency solve/export, 17.875 for API exec, and
21.225 for 8 MiB copy out. A Docker Hub timeout interrupted worker
bootstrap before affected build samples in pair four. Its same-artifact
public replay completed, with the initial attempt retained. Per-boot
percentiles, throughput, stages, paired 95% intervals, failure records,
footprint and launcher evidence are in
`SPEED-065/cj-compat.tMPK1e-comparison-66a8a90-builds-and-services/report.md`
under the ExternalSSD evidence root.

The earlier `21171de` artifact cohort completed all 60 lifecycle pairs
and five image acquisition pairs. Four no-network lifecycle rows exceeded
the 1.05 upper paired p99 bound. Alpine true recorded 1.0970 API and 1.0501
CLI. Common static recorded 1.1440 API and 1.0544 CLI. The cohorts retain
separate artifact identities. Full Kiri parity remains unqualified.
Kiri's per-workload guest teardown, second-host replication and energy
remain unmeasured. Production fingerprints and isolated host cleanup
passed.

## SPEED-065 build-only rerun

The `16a05e0` [optimized candidate](native-compatibility.md#buildx-recovery-candidate)
passed the frozen compatibility gate before all five fresh alternating
Buildx pairs against official Kiri 0.2.2. Each engine completed 180
measured solves and exports, 180 archive loads, and 180 executable-image
canaries with zero workload failures. The same digest-pinned BuildKit
0.23.2 worker, clients, input layouts, cache conditions and bounds applied
for every boot. Core dynamic memory remained active. The original Rust
stall did not recur. The upstream fix was verified in a focused source
regression, separate from the timed artifacts.

Selected Conjet/Kiri latency ratios use the five paired boots. With
three measurements per row per boot, nearest-rank p95 and p99 both
represent that boot's maximum.

| Workload | p50 ratio | p99 ratio | 95% paired p99 interval |
| --- | ---: | ---: | ---: |
| Rust dependency change, solve and export | 34.706 | 37.022 | 32.554–43.042 |
| Node source change, solve and export | 6.042 | 5.977 | 4.963–6.979 |
| Node source change, archive load | 11.131 | 10.167 | 9.686–11.006 |
| Go unchanged, solve and export | 1.249 | 1.658 | 1.300–2.209 |

The complete report, per-boot percentiles and resource observations,
all paired intervals, artifact and client hashes, and cleanup receipts
are in `SPEED-065/cj-full.lQbpSK-build-rerun-16a05e00d07d/` under the
ExternalSSD evidence root. Production fingerprints matched, and private
cleanup passed in all ten boots.
The previous lifecycle, image and service measurements retain their
original revisions. Full single-revision Kiri parity remains unqualified.

### Interrupted predecessor

A subsequent run reused the exact `66a8a90` source artifacts with the
`d537487` harness revision and repeated the 71-case gate. It completed
all 60 lifecycle pairs with 240,000 measured operations and 1,200
warmups, plus five image pairs with 100 verified first-pull transfers.
Both suites completed without workload failures. Four network-none
lifecycle p99 upper bounds exceeded 1.05.

| Workload | Path | Upper 95% p99 ratio |
| --- | --- | ---: |
| Alpine stream/exit | CLI | 1.077084 |
| Alpine true | API | 1.070346 |
| Alpine true | CLI | 1.156717 |
| Common static | CLI | 1.108870 |

Build pairs one and three passed. In pair two, Node's source-change
export returned successfully, then the native adapter rejected the
archive and lost worker control. A delayed-VM regression reproduced
that sequence, and `16a05e0` recovered the authenticated observation
and passed the same test. In pair four, the Rust dependency export
reached the expected archive size and hit the 600-second client bound
while the worker accumulated 648.061 seconds of user CPU. The public
BuildKit 0.23.2 regression reproduces a cache-export spin on a missing
cache record. There is no original worker stack to confirm that path.
[Upstream regression and fix](https://github.com/moby/buildkit/pull/6186)

The run stopped after pair four. Its raw timings, failed and partial
runs, production checks and detached-disk checks remain in
`SPEED-065/cj-full.lQbpSK-full-d537487f49d3/` under the ExternalSSD
evidence root.

## SPEED-056 retained guest start attribution

Two disposable Core 1.3.1 boots ran the pinned guest-local API lifecycle
with the tracer detached and attached, reversing the order on the second
boot. Each trial used four warmups and 16 measured operations. All
operations returned the expected status. Each trace joined guest-clock
syscalls to the API request window and container ID. The effective
runtime writes confirmed four PIDs, 16 MiB and 500 millicores in all 32
traced starts. Daemon cgroups showed no CPU throttle or PID-limit counter
increase. Those counters do not resolve per-thread scheduler delay.

| Guest-local boundary | Boot 1 median (ms) | Boot 2 median (ms) |
| --- | ---: | ---: |
| Start request, tracer detached | 87.798 | 83.500 |
| Start request, tracer attached | 286.175 | 307.961 |
| Request to first shim exec | 24.390 | 30.095 |
| Shim exec to containerd task Create | 21.517 | 21.556 |
| Task Create to runc create exec | 19.092 | 23.588 |
| runc create exec to exit | 180.385 | 190.970 |
| Within runc create, systemd scope request to first controller write | 23.192 | 16.280 |
| Within runc create, first controller write to PID limit write | 94.350 | 102.170 |
| runc start exec to exit | 24.237 | 21.656 |
| runc start exit to dockerd response write | 3.988 | 6.707 |
| Response write to guest client completion | 0.168 | 0.179 |

The last two runc intervals have 12–15 joined observations per boot.
The other reported intervals have 16. Namespace mount activity overlaps
the controller-to-limit interval. Tracing substantially increases the
wall times, so the substage magnitudes describe traced executions.
The data locate the largest interval in OCI create and support testing
the cgroup setup within that stage. They do not attribute the interval
to CPU throttling or to systemd alone. The follow-up allocation-held
observer found no CPU-throttle increase in sampled workload scopes.
The shipped guest exposed neither per-process `schedstat` nor the
`sched_schedstats` control, so runnable queue time remains unmeasured.

Raw syscall, request, cgroup, memory, and launcher observations are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-056`.
Both launchers verified teardown and production fingerprints. These
diagnostics use the shipped Core and release host artifacts from SPEED-049.

### Shallow systemd service slices

The experimental layout removed two intermediate slice levels while
retaining `conjet-services.slice` and a distinct leaf per workload or
service. Both arms staged the same release-mode telemetry binary
with support for both paths. The pilot selected the layout with the
Docker create parent. The pinned release VMM and Docker binaries handled
both arms, with tracing disabled. Systemd uses hyphens to encode slice
ancestry. [Systemd cgroup interface](https://systemd.io/CONTROL_GROUP_INTERFACE/)

| Pair and order | Layout | Lifecycle p50 / p95 / p99 (ms) | Start p50 (ms) | Launches/s | Reclaim submissions | Runtime CPU delta (s) | Highest sampled footprint (MiB) | Idle convergence (s) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 first | Existing | 121.173 / 142.038 / 152.477 | 84.539 | 8.266 | 400 | 40.74 | 1491.53 | 10.213 |
| 1 second | Shallow | 124.195 / 141.797 / 152.560 | 85.602 | 8.091 | 24 | 42.24 | 1586.18 | 10.144 |
| 2 first | Shallow | 124.566 / 147.734 / 162.933 | 82.992 | 7.944 | 25 | 42.25 | 1575.21 | 6.097 |
| 2 second | Existing | 128.600 / 151.204 / 159.294 | 86.436 | 7.711 | 25 | 44.23 | 1557.69 | 6.121 |

Each leg timed 200 API lifecycles after ten warmups. A separate phase
held a 512 MiB allocation during 20 launches per leg. All 920 launches
succeeded. The four-PID, 16 MiB and 500-millicore limits were read back
on each layout. Per-service telemetry identified both 64 MiB canaries in
each trial, including during the allocation. Both canaries verified their
data. The allocation verified, released and passed demand-zero reuse.
All boots converged to 512 MiB with no unauthorized backing releases
in the sampled ledgers. The allocation ran with the VM already at
2,048 MiB, so pressure-driven capacity growth was not exercised.

The shallow layout moved median lifecycle latency by +2.5% and −3.1%.
Start and throughput also changed in opposite directions across pairs.
The first existing-layout boot recorded 400 accepted reclaim requests
in the serial window against 24–25 in the other legs. The A/B left the
reclaim policy active, so this remains observed boot variation.
CPU deltas include setup, the held allocation and idle observation.
The slice variant was rejected for lack of a repeatable improvement.

The private telemetry binary SHA-256 was
`39915ceba97815d6b184c0e90df7ddcffa786d3ffc8851df1cb7a0cc5d4cfd63`.
The variant parser regression, both layout witnesses, production and
cleanup snapshots, and raw samples are in the SPEED-056 evidence folder.
The retained layout then passed all 26 existing compatibility probes and
four API/CLI output canaries on a separate stock Core boot. The probes
covered bridge and no-network execution, image, volume, Buildx and Compose.
This series is a Conjet A/B. SPEED-055 still gates formal requalification.

## SPEED-055 qualification status

The SPEED-051 exit-127 attribution and correctness gate remains open.
A retained Docker qualification series for Kiri API or CLI parity
was not started. SPEED-049 remains the latest paired comparison.
It failed API parity and had too few eligible CLI pairs to decide
formal CLI parity. The SPEED-050 guest-local diagnostic missed the
below-5-ms median target on every boot.

One private retained-engine compatibility boot used the SPEED-050
diagnostic VMM with tracing disabled and the shipped Core 1.3.1 guest.
It passed all 26 existing capability probes covering image inspection,
copy and save, network and volume lifecycle, exec and process controls,
effective cgroup witnesses, Buildx build and artifact execution,
and a Compose Redis transaction and teardown. Two API and two CLI
canaries verified exact stdout, stderr and exit 23 on no-network and
bridge workloads. The launcher verified resource cleanup and
production fingerprints. Evidence is in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-055/compatibility`.

These smoke checks do not qualify the full image, build, Compose,
storage, sustained-network or concurrency matrix. Second-host,
privileged energy and equivalent Kiri guest teardown remain open.
Independent review and CI still gate integration. Release signing
and publication remain outside this diagnostic.

## SPEED-053 response write readiness

The two SPEED-050 traced boots recorded 96 tagged measured lifecycle
responses and 48 measured ping responses. The bridge completed every
tagged write and emitted no `client_write_blocked` observation. Start
was dominated by time before the first dockerd response. Wait's longer
first-to-last span also appeared on the guest relay clock. This workload
did not justify a writable watcher. The existing readiness and 25 ms
recovery tick are retained. This decision covers the measured short
responses. [Tagged timings and evidence](#speed-050-guest-local-retained-docker-lifecycle)

## SPEED-054 HTTP connection churn

The SPEED-050 diagnostic client sent 12 timed `_ping` requests per
fresh/reuse-intent variant in each boot after four warmups. Within the
guest, the persistent client dialed zero times during the measured
window, compared with 12 dials for the fresh client. The untraced
guest-local latency medians were 0.150 versus 0.118 ms and 0.123 versus
0.085 ms. Forwarded requests reopened the connection on every operation
with either client setting. The forwarded fresh medians were 1.187 and
2.500 ms, and reuse-intent medians were 1.886 and 1.301 ms. The relay's
ordinary response closes the connection, so none of the forwarded
results measures a genuinely persistent relay. The small local
connection effect and dominant guest start stage did not justify adding
an ordinary HTTP keep-alive state machine. No relay persistence
candidate was selected. [Tagged timings and evidence](#speed-050-guest-local-retained-docker-lifecycle)

## SPEED-052 routine reclaim A/B

Two independent alternating boot pairs compared the SPEED-049
event-wake VMM with a disposable release VMM built from `62c7cde`
plus the preserved experimental patch. The variant coalesces
ordinary stream-triggered reclaim into the existing idle transition.
New classified workload activity invalidates the hint. A
generation-matched guest safety probe must allow the idle target.
The independent pressure and balloon ownership paths remain in the
variant. Tracing was disabled for these boots.

Each leg timed 200 serial API launches after ten warmups on the
pinned four-PID Alpine fixture. Two 64 MiB live-data canaries ran
through the churn. A separate check held the existing 512 MiB
fixture allocation for 20 more launches. All 800 timed launches,
40 warmups and 80 allocation-held launches succeeded.

| Pair and order | VMM | p50 / p95 / p99 (ms) | Launches/s | Reclaim submissions during timed window | Runtime CPU delta (s) | Highest footprint snapshot (MiB) | Idle convergence (s) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 first | Baseline | 124.672 / 158.641 / 182.047 | 7.783 | 26 | 41.70 | 1623.86 | 6.074 |
| 1 second | Variant | 127.559 / 165.586 / 185.936 | 7.687 | 0 | 42.50 | 1637.43 | 6.080 |
| 2 first | Variant | 129.887 / 161.107 / 173.129 | 7.605 | 0 | 41.22 | 1620.96 | 6.100 |
| 2 second | Baseline | 130.251 / 158.651 / 173.173 | 7.613 | 26 | 42.04 | 1622.83 | 6.117 |

Runtime CPU deltas include setup, the allocation fixture and idle
observation. Footprints are discrete samples. All measured windows
started at 2,048 MiB. The canaries verified every retained byte,
verified and released the 512 MiB allocation, and verified demand-zero
reuse. All fixtures exited cleanly. The balloon converged at the
existing 512 MiB idle target in all four boots. Sampled ledgers
reported zero unauthorized backing releases. The entitled partial
and immediate backing-release tests passed. Capacity was already
2,048 MiB during the live allocation. This check did not exercise
an independent low-capacity pressure expansion.

The variant eliminated timed reclaim submissions but produced no
repeatable latency benefit. Both p95 values were higher and
throughput fell in both pairs. The variant was rejected. The sampled
memory checks do not establish full pressure-response qualification.

The baseline VMM SHA-256 was
`518c6f84ce30124e7d79cc69fe191df20c82be070ee568191c4e026e52d9642a`.
The variant VMM SHA-256 was
`4c512a7ff8fa44d44800a2d4b635ed2b46238e6ed76064ec10246888081b14d1`.
Raw samples, results, the patch, memory snapshots and cleanup
witnesses are in
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-052`.

## SPEED-051 four-PID CLI failure capture

Two bounded diagnostics ran the pinned SPEED-049 CLI fixture against
the same release artifacts and unchanged four-PID, 16 MiB and
500-millicore limits. The first attempt to collect tracefs evidence
found the mount absent in the pinned guest. The next attempt followed
the guest containerd process and runtime children with strace. All
550 launches returned exit 0 with empty stdout and stderr. The trace
showed `runc create`, the application of `pids.max=4`, `runc start`,
and the workload exec. It captured no `EAGAIN` or Go thread error.

A separate private boot ran a guest cgroup observer without ptrace.
All 2,000 CLI launches succeeded. The observer read 1,631 PID event
snapshots, all `max 0`. One other read raced scope removal and had
no event data. It saw `runc:[2:INIT]` inside the actual four-PID
workload scopes, including snapshots with up to eight charged tasks.
Linux permits that transient state when processes move into a
cgroup or its limit is applied to existing tasks. New clones
remain subject to the limit. [Linux PID controller](https://docs.kernel.org/admin-guide/cgroup-v2.html#pid)

The two observers narrow the runtime stage but leave the actual
SPEED-049 failure unattributed. The measured operation did not recur,
and the snapshots do not establish which process wrote the original
error. No correction or limit change was selected. Raw process output,
syscalls, cgroup membership and launcher cleanup are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-051`.
Both completed capture boots passed production and host cleanup guards.

The SPEED-056 follow-up ran 256 further pinned CLI launches in one
private boot while the 512 MiB allocation fixture held memory. It
captured runc init in all 256 workload scopes. There were 352 readable
PID event observations with `max 0`, one read during scope removal,
and zero observed throttled scopes. Every CLI launch returned exit 0.
The canary passed before and after the churn, and the balloon returned
to 512 MiB in 6.094 seconds after cleanup. The supplemental process
and controller records are in `SPEED-056/pid-witness-pressure`.

## SPEED-050 guest-local retained Docker lifecycle

Four private boots on the SPEED-049 host used two vCPUs, a 2 GiB ceiling,
Core 1.3.1, Docker 29.1.3, containerd 2.2.1, runc 1.3.4, VMM ingress wake,
and the 25 ms recovery tick. Two supplemental boots used the same
rebuilt relay and VMM as the trace boots, with tracing disabled in both.
The diagnostic client executed API 1.44
create, start, wait and remove, in order, against the guest Docker Unix
socket and the forwarded Unix socket. Each lane used four warmups and
12 measured operations per boot with the pinned ARM64 Alpine config,
`/bin/true`, no networking, 16 MiB, four PIDs, 500 millicores, all
capabilities dropped and no-new-privileges. Both lanes sent the same
per-workload Conjet cgroup parent. The lane order alternated between
boots. All 144 measured lifecycles and 48 warmups succeeded.

| Boot | Guest-local lifecycle median (ms) | Forwarded lifecycle median (ms) | Guest start / wait (ms) | Forwarded start / wait (ms) |
| --- | ---: | ---: | ---: | ---: |
| Control 3 | 112.306 | 152.656 | 78.179 / 22.170 | 99.203 / 34.770 |
| Control 4 | 117.316 | 134.210 | 79.374 / 22.484 | 90.499 / 26.102 |
| Trace 3 | 92.247 | 111.037 | 66.240 / 14.344 | 75.960 / 22.025 |
| Trace 4 | 91.970 | 105.037 | 69.878 / 16.381 | 79.246 / 15.168 |
| Matching control 1 | 92.946 | 102.024 | 71.556 / 17.771 | 72.350 / 16.815 |
| Matching control 2 | 97.576 | 102.612 | 72.531 / 21.025 | 75.609 / 19.415 |

The guest-local retained-engine floor on the shipped, untraced boots was
112–117 ms, with start as the largest stage. The below-5-ms median
target failed for this diagnostic workload, including with transport
bypassed. The supplemental control uses identical diagnostic binaries
and repeats the private relay restart with both trace settings off.
The traced forwarded medians were about 2.4% and 8.8% higher than
these same-binary controls at the corresponding lane orders. The
unforwarded medians also moved between boots. These small samples
bound the observed configuration difference without isolating pure
logging overhead from independent-boot variation. The diagnostic
client and boot budget differ from the frozen SPEED-049 qualification.

All tagged forwarded measurements joined by request ID. Each duration
uses only its own monotonic clock.

| API stage | Host accept → ring publication (ms) | Host ring → first response (ms) | Host first response → final client write (ms) | Guest receipt → dockerd delivery (ms) | Guest delivery → first dockerd response byte (ms) | Guest first byte → response complete (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Create | 0.108–0.133 | 5.232–6.270 | 0.829–0.956 | 0.020–0.031 | 4.646–5.734 | 0.917–1.023 |
| Start | 0.098–0.106 | 74.850–78.047 | 0.908–1.137 | 0.021–0.039 | 74.291–76.879 | 1.024–1.254 |
| Wait | 0.112–0.114 | 6.421–7.933 | 6.394–10.250 | 0.019–0.026 | 5.185–7.421 | 6.541–10.392 |
| Remove | 0.097–0.116 | 1.690–2.125 | 0.647–0.806 | 0.019–0.029 | 1.309–1.642 | 0.712–0.901 |

Host accept-to-ring values come from per-request intervals. The host
logged guest shutdown receipt and client half-close separately.
The guest clock places most start time after delivery to dockerd and
before its first response. The separate SPEED-051 syscall capture
shows guest `runc create` and `runc start` process spans well above
the Alpine payload's exec-to-exit span. Ptrace perturbs the absolute
spans. This evidence identifies OCI setup as an expensive stage but
leaves the untraced per-component dockerd/containerd/runc breakdown
open.

Dynamic memory was enabled, with a 512 MiB idle target and observed
1 ms configured quiet dwell. The before/after snapshots during both
lifecycle lanes reported 2,048 MiB. The untraced forwarded trials
recorded 2 and 3 accepted reclaim requests over the snapshot
intervals. Both traced and both supplemental forwarded trials recorded
34. Those counters
measure submissions and include observer traffic near the windows.
They do not time worker completion or demonstrate a cache drop.
No range bytes were reported. The services slice reported zero PID-limit
and CPU-throttle counter increases at the sampled parent. The supplemental
controls also recorded zero increments for dockerd and containerd
individually. Their observed CPU usage per lifecycle snapshot interval was
147–169 ms and 420–470 ms respectively. Per-container scopes had
disappeared by the after snapshots.

Raw samples, timestamps, checksums, resource counters, failed setup
attempts and the diagnostic client and runner live under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-050`.
`floor-summary.json` identifies `control-{3,4}`, `host-trace-{3,4}` and
`matching-control-{1,2}`.
The diagnostic VMM SHA-256 was
`b104e6d5f9782feecc6df18423e4fef9c21b0fd440ea79a5e2b008e85fe9378b`.
The diagnostic guest relay SHA-256 was
`09a80e58cecb798858c35ebe63d671e945124c1cdb9979d7cbc27152a8531d87`.
Every measured boot verified private process, socket and backing-file
cleanup and production fingerprints. API removal acknowledgement is the
measurement endpoint. Kiri parity was outside this diagnostic.

## SPEED-049 retained Docker release lifecycle against Kiri

This series compares the isolated Conjet event-wake candidate at
`84e29ab446329a2ea379564253f126a86b3cbeff` with official signed Kiri
0.2.2. The measured Conjet backend was Core 1.3.1 with dockerd 29.1.3,
containerd 2.2.1, and runc 1.3.4. Kiri identified its own runtime.
The existing 25 ms VMM tick remained active and trace capture was
disabled. The Swift CLI and daemon, Rust VMM and network helper were
release builds. The pinned guest was the shipped Core release. These
results are separate from the native OCI research and historical
existing-engine results.

| Observed environment | Value |
| --- | --- |
| Host | Apple M1 Pro, 16 GiB RAM, macOS 27.2.1 (26B131) |
| Storage | APFS ExternalSSD, verified VM disk holders in each private boot |
| VM resources | Two vCPUs and 2 GiB configured on both sides |
| Guest | Conjet Linux 6.12.86-conjet, 2,094,825,472 bytes reported. Kiri Linux 6.18-kiri, 2,088,570,880 bytes reported |
| Clients | Docker 29.10.0, Buildx 0.39.1 and Compose 5.8.0 pinned. Only Docker was exercised |
| API and fixture | Docker API 1.44, warm pinned Alpine 3.22 ARM64 config `062964a69725bb96611dae2ac911a5a1ab3f8d32fe6f096f267d77f09e55a99c` |
| Container | `/bin/true`, no network, 16 MiB, four PIDs, 500 millicores, all capabilities dropped and no-new-privileges requested |

| Frozen artifact | SHA-256 |
| --- | --- |
| Conjet CLI | `6a90e3096e1da7ff35a314ae817111a37d0282082703f3995fb7a1be6030ed93` |
| Conjet daemon | `9e6a8f96b8cb3d762a51a5ae442eb7a522dbf3883b0d959a1fa45eaeb63f586f` |
| Jetstream VMM | `518c6f84ce30124e7d79cc69fe191df20c82be070ee568191c4e026e52d9642a` |
| Conjet network helper | `cd23449a68008b4a5d12ab52768ac82a32c5b12dcbc71e82e585b228bb128fb5` |
| Kiri daemon | `c5cd8edefc69d3e4de4cf38a8149d07d6c4c4f1d522167c890541c17f2630884` |
| Docker client | `cd9e0b149e447af504421ac7117044d8e17d695d66846a5c4df1312c417c22a3` |
| Docker comparison manifest v1 | `572fa7ec2ff060d488daa8adaccc0bb5ffeb9ed0adcd6d009873f86f36826d19` |

The frozen v1 workload, client versions, repetition counts and analysis
rules also govern this retained Docker comparison. Each lane has
five alternating independent boot pairs, with ten warmups and 2,000
measured operations per engine and boot. The host monotonic clock
measures API create through removal acknowledgement and unmodified
Docker CLI `run --rm` invocation through process exit. Throughput
uses the full measured serial window. VM boot, pulls and fixture
admission happen outside that window. Per-operation guest teardown
is unobserved on both engines. Separate launcher checks verify owned
host processes, sockets and backing-file handles after each boot.

Both engines reported the same pinned Alpine image config and ARM64
architecture. Untimed canaries on the frozen artifacts confirmed
`memory.max=16777216`, `pids.max=4`, `cpu.max=50000 100000`, zero
effective capabilities and `NoNewPrivs=1`. The canaries delivered both
streams and deliberate exit 23. Each engine passed its shutdown checks.

| Pair | Engine order | Engine | API p50 / p95 / p99 (ms) | API ops/s | CLI p50 / p95 / p99 (ms) | CLI ops/s |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 1 | Conjet → Kiri | Conjet | 429.016 / 657.532 / 690.065 | 2.260 | 458.016 / 658.736 / 697.809 | 2.160 |
| 1 | Conjet → Kiri | Kiri | 4.127 / 4.830 / 5.771 | 236.918 | 20.339 / 21.817 / 23.432 | 48.701 |
| 2 | Kiri → Conjet | Kiri | 4.179 / 4.874 / 6.656 | 231.677 | 20.255 / 21.553 / 22.396 | 48.948 |
| 2 | Kiri → Conjet | Conjet | 419.257 / 623.839 / 661.316 | 2.329 | 455.078 / 665.006 / 693.297 | 2.168 |
| 3 | Conjet → Kiri | Conjet | 429.005 / 650.291 / 1154.469 | 2.213 | 458.790 / 663.470 / 698.849 | 2.157 |
| 3 | Conjet → Kiri | Kiri | 5.036 / 18.913 / 34.303 | 132.675 | 20.130 / 21.010 / 22.025 | 49.416 |
| 4 | Kiri → Conjet | Kiri | 4.206 / 5.138 / 8.408 | 229.417 | 20.164 / 21.114 / 22.231 | 49.315 |
| 4 | Kiri → Conjet | Conjet | 436.181 / 651.971 / 683.821 | 2.201 | 460.878 / 669.166 / 700.198 | 2.150 |
| 5 | Conjet → Kiri | Conjet | 468.607 / 651.826 / 688.853 | 2.167 | 460.429 / 661.119 / 694.062 | 2.160 |
| 5 | Conjet → Kiri | Kiri | 3.739 / 4.502 / 6.826 | 256.751 | 20.073 / 20.975 / 21.957 | 49.563 |

Paired ratios are geometric means with 95% intervals from 10,000
independent boot-pair bootstrap resamples, seeded with 615026. The
CLI requires both upper endpoints to be at most 1.05. The API median
advantage is evaluated separately.

| Lane | Metric | Conjet / Kiri | 95% interval |
| --- | --- | ---: | ---: |
| API | p50 | 102.9228 | 92.1571–115.4850 |
| API | p99 | 80.0233 | 51.7371–107.6650 |
| API | Throughput | 0.0105 | 0.0090–0.0134 |
| CLI | p50 | — | — |
| CLI | p99 | — | — |
| CLI | Throughput | — | — |

The API lane was slower at both percentiles and missed parity. The CLI
was slower in every observed pair, with Conjet p50 of 455–461 ms and
Kiri p50 of 20.07–20.34 ms. Its formal parity result remains
inconclusive because only four pairs qualify for inference. The
fifth Conjet boot had one exit 127 with a Go `pthread_create` resource
error. The per-operation recovery request completed. An earlier retained
Docker binary recorded the same error twice with the same workload
before event wake existed.

A separate diagnostic ran the pinned guest `runc --version` as a
workload under directly read-back PID caps. All 12 runs at four PIDs
failed during Go startup with the same resource error. All 13 runs at
eight PIDs succeeded, including the setup check. This establishes
sensitivity of the packaged binary to the cap in the diagnostic.
The failing qualification operation still lacks a direct guest
process and cgroup witness.

The range below is across the boot medians for each operation. CLI
timing has a single host exit boundary.

| Lane | Engine | Create (ms) | Start (ms) | Wait (ms) | Remove (ms) | CLI exit (ms) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| API | conjet | 8.236–10.288 | 189.529–214.157 | 217.272–228.704 | 4.397–4.831 | — |
| API | kiri | 1.815–2.121 | 1.274–1.945 | 0.090–0.170 | 0.502–0.696 | — |
| CLI | conjet | — | — | — | — | 455.078–460.878 |
| CLI | kiri | — | — | — | — | 20.073–20.339 |

| Lane | Engine | Boots | Timed | Failed | Warmups | Failed warmups | Clean | Recovered |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| API | conjet | 5 | 10000 | 0 | 50 | 0 | 5 | 0 |
| API | kiri | 5 | 10000 | 0 | 50 | 0 | 5 | 0 |
| CLI | conjet | 5 | 10000 | 1 | 50 | 0 | 5 | 0 |
| CLI | kiri | 5 | 10000 | 0 | 50 | 0 | 5 | 0 |

Clean denotes verified host teardown and unchanged production
snapshots. Recovered counts residual labeled containers found by
the final sweep. The CLI failure was recovered by the per-operation
removal path before the sweep. Total measured operations were 40,000,
with one failure and 200 successful warmups.

| Lane | Engine | CPU time delta (s) | Higher RSS snapshot (MiB) | Footprint snapshots (MiB) | Allocated disk delta (MiB) | One-minute load |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| API | conjet | 644.46–696.06 | 891.12–1170.39 | 288.69–471.00 | 1568.73–1684.03 | 2.08–20.73 |
| API | kiri | 9.60–15.08 | 360.89–581.11 | 134.80–396.42 | 0.00–0.00 | 2.30–19.87 |
| CLI | conjet | 668.70–670.71 | 1224.36–1299.08 | 287.61–493.47 | 1580.41–1706.73 | 2.12–4.47 |
| CLI | kiri | 10.74–10.88 | 424.56–450.62 | 241.35–293.71 | 0.00–0.00 | 2.43–5.75 |

Host CPU reflects attributable runtime processes between snapshots.
RSS and physical footprint are point observations. Continuous peak
memory and bytes read or written were unavailable. Allocated backing
file growth describes storage occupancy. Conjet used a disposable
16 GiB guest root and 100 GiB sparse data disk. Kiri reused its
isolated 64 GiB sparse VM data image across boots. Images were warm
in all measured windows.

| Coverage | Result | Evidence under SPEED-049 |
| --- | --- | --- |
| Retained Docker API | Five eligible pairs, zero workload failures | `api/pair-{1..5}` |
| Retained Docker CLI | Five measured pairs, four eligible, one workload failure | `cli/pair-{1..5}` |
| Effective cgroup, privileges, output and exit | Matched guest witnesses | `effective-limits` |
| CLI failure diagnostic | Packaged runc reproduced the thread error under a four-PID cap | `pid-hypothesis` and `pid-hypothesis-missing-library` |
| Production and host cleanup | Both launchers verified all 20 final boot legs and the two canaries | `*-launcher.json` in each pair and canary |
| Adverse preservation check | Earlier API pair 4 and a canceled CLI start retained | `api-adverse-pair-4`, `cli-canceled`, `production-drift.json` |
| Frozen versions, checksums and paired analysis | Host and Kiri executable hashes, Core release SHA-512, raw summary and rendering tools | `sha256.txt`, `core-sha512.txt`, `revision.txt`, `final-summary.json` |
| Build, Compose, image acquisition, control, storage, networking and concurrency | Historical series only | Existing sections below |

An earlier API pair 4 was excluded after the production guard observed
a changed global Buildx selector fingerprint. The production app,
daemon, VM, socket identity and selected Docker context matched.
The selector writer was unobserved. The partial CLI invocation was
canceled and its owned runtime was reclaimed. After checking the
private configuration and stable production observations, API pair 4
was rerun at the same revision and counts. All final boot legs passed
the guard. The excluded and canceled logs are retained.

Raw evidence is under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-049`.
Resolve the four-PID CLI runtime failure before freezing another CLI
series. The API results support a separate start and wait timing
follow-up at the guest relay boundary. Second-host, privileged energy,
equivalent Kiri guest teardown and sub-1 ms research remain deferred.

## SPEED-048 retained Docker ingress wake pilot

The same release Jetstream executable ran with the Docker ingress
watcher off and on. The candidate reused the owned kqueue watcher
to wake the existing VMM queue owner and retained the 25 ms fallback
tick. Docker Engine 29.1.3, containerd 2.2.1, runc and Core 1.3.1
executed the same pinned no-network ARM64 fixture.

| Pair | Polling, lifecycle median (ms) | Event wake, lifecycle median (ms) | Event wake / polling |
| --- | ---: | ---: | ---: |
| A | 338.245 | 272.374 | 0.805 |
| B | 338.693 | 270.252 | 0.798 |

These are untraced release pilots with four warmups and 12 measured
API operations per boot. The following measurements use separate
host-only trace boots and report queue-to-ring intervals.

| Pair | Start polling / event wake (ms) | Wait polling / event wake (ms) |
| --- | ---: | ---: |
| A | 14.622 / 0.124 | 12.431 / 0.099 |
| B | 10.693 / 0.106 | 10.471 / 0.098 |

The code addresses the measured host publication delay. Time after
guest-ring publication remains in the trace and contains several
guest and transport stages. The ingress change is opt-in. These
two-pair pilots have no qualification interval or Kiri verdict.
Release binaries, host-only and untraced observations, and exact
cleanup records are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-048`.

## SPEED-047 retained Docker start and wait trace

The release host tools, Core 1.3.1 and the same pinned ARM64 fixture
ran six private boots. Each boot completed four warmups and 12
measured no-network API lifecycles. The harness opened a fresh
HTTP connection for each request in all modes.

| Trace mode | Lifecycle median, boot 1 / 2 (ms) | Start host queue to guest ring (ms) | Wait host queue to guest ring (ms) |
| --- | ---: | ---: | ---: |
| Disabled | 302.162 / 300.923 | — | — |
| Host only | 335.578 / 309.482 | 8.582 / 4.443 | 2.691 / 3.812 |
| Host plus guest observers | 211.647 / 165.910 | 6.956 / 7.625 | 2.972 / 5.100 |

The tagged traces measured VMM-local socket acceptance, queueing,
guest-ring publication, guest response arrival and host flush attempts.
The probe captured Docker create, start, die and destroy plus
containerd task start and exit by container ID. Containerd task
start-to-exit medians were 1.886 and 2.305 ms within its guest event
clock. The guest event API returned inconsistent wall-clock bounds in
an adverse pilot. The successful runs used live subscriptions. No
elapsed interval subtracts a guest timestamp from a host timestamp.

The observers altered request timing enough to exclude these runs
from qualification. Host-only evidence isolates a reversible
publication delay worth testing in SPEED-048. The interval from
guest-ring publication to the VMM's receipt includes guest dispatch,
daemon work and response scheduling. The trace does not assign that
entire interval to a single component. Production matched before and
after all runs, with observer and launcher cleanup verified. Raw
commands, build logs, stage timestamps and adverse trials are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-047`.

## SPEED-046 retained Docker path diagnostic

One isolated release boot at `de8773b` used Docker Engine 29.1.3,
containerd 2.2.1, runc 1.3.4, Core 1.3.1 and Linux
`6.12.86-conjet` on the M1 Pro. The guest had two vCPUs and
2,048 MiB configured. The pinned ARM64 `/bin/probe` fixture
used 16 MiB, four PIDs and 500 millicores. Each group completed
ten warmups and 12 measured requests. All 88 operations passed.

| Artifact | SHA-256 |
| --- | --- |
| Release Conjet CLI | `e55959513e8a35673b9078c53b32f730cddcca0ae51697be65e6db70bf6b3370` |
| Release conjetd | `ea594282c33b4f77e7059db529be2929b2590a1283e6cbccb36c40f07278e8c3` |
| Release Jetstream | `4948acbbf65e18387d3938e5be46f9dee956e7a8d4cee9757423fdc341608be4` |
| Release network helper | `20ac4c6bf6d5312f07363f96fbc79539d8080c70eda58ebebe597e40905a3732` |
| Docker client | `cd9e0b149e447af504421ac7117044d8e17d695d66846a5c4df1312c417c22a3` |
| Staged workload manifest | `dc9fe4ca74bd748082fa9e1b8328f9545c911116fd4e336a5691a9e9c10b39be` |
| Pinned image archive | `7c634cde03b42a156ac14729ceaa54d3a0f3d5aa590b644f4bfa435048578473` |

| Network | Lane | p50/p95/p99 (ms) | Successes/s |
| --- | --- | ---: | ---: |
| none | API | 281.473 / 357.646 / 357.646 | 3.453 |
| none | CLI | 380.650 / 451.168 / 451.168 | 2.546 |
| bridge | API | 385.612 / 628.732 / 628.732 | 2.447 |
| bridge | CLI | 696.161 / 826.469 / 826.469 | 1.410 |

| Network | Create median (ms) | Start | Wait | Remove | Median start+wait share |
| --- | ---: | ---: | ---: | ---: | ---: |
| none | 20.823 | 97.313 | 149.116 | 18.152 | 85.6% |
| bridge | 28.315 | 123.773 | 216.620 | 19.917 | 87.8% |

The API window ends at removal acknowledgement. CLI time ends at
client exit. Guest cleanup for an individual operation remains
unobservable on these routes. The host timings show where requests
wait and cannot divide the delay among VMM transport, dockerd,
containerd, runc and execution. The reported tail percentiles are
descriptive for 12 samples. This run has no matched Kiri pair or
parity verdict. The historical series below retain their prior
results and boundaries.

The launcher verified the production identities, context and endpoint
before and after the diagnostic. The staged daemon, VMM and network
helper exited. Reclamation verified closure of their sockets and
file handles and removed the exact owned scratch root. Raw timings,
backing paths, host CPU and RSS observations, startup and cleanup
evidence are under
`/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-046`.

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

## Release-build native Docker lifecycle

The private `conjet-speedup` launcher defaults to Jetstream native OCI.
The release-optimized CLI, VMM and guest supervisor were built from
`98d4148380ce3c6cadd4cf1b8b217d9aea76a47e`. The measured harness and
adapter were `cabbea99f1fe1ee18219ff0a9e27245358ef36bf`. The Swift and Rust
sources and lockfiles are identical at these revisions. The VMM used
local QA signing with the hypervisor entitlement.

| Release artifact | SHA-256 |
| --- | --- |
| Conjet CLI | `29a3e4840aa71416c4a56394c26812bd5b6988e60cb9842920ef47c925293d5a` |
| Jetstream VMM | `2279de55d31f4acd5c32d37c25e66c5f64de528e16f2069b9df993e838e3ef05` |
| Conjet native supervisor | `6a3839855383e674e59a854fa197e56c2489c09d2594665b702dbcd733f0f42a` |
| Core 1.3.1 kernel | `efc2fc2150594bcd481b81ee24fe3f2c96360ea7507b4e71a28bbcf077b379b1` |
| Admitted Alpine package | `7e002bd9c01ad6b50c34c1df8c13975ed422fe9484780870e3ac1439548161eb` |
| Docker 29.10.0 client | `cd9e0b149e447af504421ac7117044d8e17d695d66846a5c4df1312c417c22a3` |

The [matched runner](../../benchmarks/README.md#paired-docker-comparison)
used `--all-pairs` with the 2,000-sample budget per engine, transport and
boot, plus ten separate warmups per lane. Both engines used the manifest's
pinned ARM64 Alpine config and `/bin/true`, UID/GID 65532, no network,
16 MiB, four PIDs and 500 millicores, with capabilities dropped and
no-new-privileges requested. A separate canary checked UID, GID, both
streams and deliberate exit 23. Conjet's guest applies the cgroup controls
before exec. Kiri's canary read back the three controls. The guests had two
vCPUs and 2 GiB configured, with kernels `6.12.86-conjet` and `6.18-kiri`.
Both image roots were ready before timing. Kiri's disk was held by its
attributed Virtualization process on ExternalSSD. Jetstream used a
disposable session disk and staged root on ExternalSSD.

API time covers create, start, wait and removal acknowledgement over API
1.44. CLI time covers the unmodified `docker run --rm` client through
process exit. Every Conjet sample had a unique native execution ID and
verified guest cleanup. The witness lookup happens after the measured
operation and is charged to session throughput. Kiri guest cleanup
remains unknown. All 40,000 measured operations and 200 warmups completed
with zero failures.

| Pair | Engine | API p50 / p95 / p99 (ms) | API ops/s | CLI p50 / p95 / p99 (ms) | CLI ops/s |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | Conjet native | 3.443 / 4.633 / 5.626 | 262.2 | 22.900 / 24.901 / 28.989 | 42.2 |
| 1 | Kiri | 4.047 / 4.886 / 5.985 | 240.8 | 21.280 / 22.919 / 25.878 | 46.6 |
| 2 | Kiri | 4.053 / 4.975 / 8.263 | 237.1 | 21.352 / 22.796 / 24.921 | 46.5 |
| 2 | Conjet native | 3.472 / 4.707 / 5.655 | 260.7 | 22.979 / 24.835 / 27.942 | 42.1 |
| 3 | Conjet native | 3.467 / 4.554 / 5.409 | 262.8 | 22.939 / 24.623 / 27.896 | 42.2 |
| 3 | Kiri | 4.052 / 4.871 / 5.555 | 240.6 | 21.147 / 22.801 / 25.533 | 46.8 |
| 4 | Kiri | 4.494 / 5.585 / 7.501 | 216.0 | 21.740 / 24.112 / 27.247 | 45.4 |
| 4 | Conjet native | 3.587 / 4.735 / 5.765 | 253.8 | 23.038 / 25.235 / 27.756 | 41.9 |
| 5 | Conjet native | 3.408 / 4.424 / 5.369 | 265.9 | 23.091 / 24.801 / 28.367 | 41.9 |
| 5 | Kiri | 4.045 / 4.893 / 5.707 | 241.7 | 21.268 / 22.685 / 24.709 | 46.7 |

The geometric mean of paired Conjet/Kiri latency ratios and independent
boot-pair bootstrap intervals use 10,000 resamples with seed 615026.

| Boundary | Percentile | Ratio | 95% interval | Verdict at the declared 5% threshold |
| --- | --- | ---: | ---: | --- |
| Docker API removal acknowledgement | p50 | 0.841 | 0.818–0.855 | Conjet lower |
| Docker API removal acknowledgement | p99 | 0.854 | 0.746–0.954 | Inconclusive |
| Docker CLI process exit | p50 | 1.076 | 1.068–1.084 | Conjet slower |
| Docker CLI process exit | p99 | 1.099 | 1.058–1.132 | Conjet slower |

One-minute host load ranged from 2.95 to 7.07 with production active.
Attributed host CPU across each two-lane session was 21.64–22.18 CPU-s
for Conjet and 21.86–23.47 CPU-s for Kiri. Combined end-of-session RSS
snapshots were 234–398 MiB and 317–450 MiB, respectively. These are
process-level point observations. Guest memory decomposition and energy
are unavailable at equivalent boundaries.

In the 100-sample release pilot before optimization, the adapter spent a
median 27.393 ms sleeping while observing the API workload. The switch to
a bounded terminal wait kept cancellation and cleanup semantics and used
one Wait request in each final operation. Across final API sessions, stage
medians were 0.452–0.478 ms for authentication, 0.166–0.172 ms for admission,
1.751–1.828 ms for terminal observation, and 0.251–0.264 ms for output.
The 25 ms host tick stayed enabled. The legacy repetitions
stopped at the user's direction and remain as historical evidence.
Two earlier canary attempts are retained in
`SPEED-019/native-default-pilot-{1,2}`. The sandbox denied the pipe used
by shell command substitution, and the second canary requested an absent
`/bin/id`. The final probes use the verified BusyBox applet and separate
stream canaries.

A later coordinator fix handles TERM directly when the launching shell
ignores SIGINT. The corrected cancellation run exited 130, preserved 841
partial Kiri API samples, and finished cleanup before the other engine
started. A separate 100-sample-per-lane post-fix pilot passed. The table
above remains tied to the frozen `cabbea9` series.

## SPEED-027 native Docker critical path diagnostics

Four native-only boots used control/trace/trace/control order. The CLI, VMM and
guest were built in release mode from `cf0a94e` with the runbook commands. The
launcher records the instrumented adapter hash, exact VM invocation and release
asset hashes. Each boot ran four warmups and 40 measured operations per lane
and canary. All 704 operations completed, with exact CLI output and exit status,
unique native workload IDs and verified guest cleanup. The native API lane
validated both exit codes through wait and explicit removal. CLI used normal
negotiation with the same pinned Docker executable and ran through process exit.

| Lane and canary | Control 1 median (ms) | Trace 1 median (ms) | Trace 2 median (ms) | Control 2 median (ms) |
| --- | ---: | ---: | ---: | ---: |
| API true | 4.263 | 3.935 | 4.652 | 4.264 |
| API both streams, exit 23 | 4.279 | 4.169 | 4.324 | 4.329 |
| CLI true | 24.996 | 24.377 | 26.207 | 24.836 |
| CLI both streams, exit 23 | 25.002 | 24.617 | 25.274 | 24.665 |

The trace-minus-control differences within the two adjacent boot pairs ranged
from −0.329 to +0.388 ms for API true and −0.619 to +1.371 ms for CLI true.
The both-streams differences ranged from −0.111 to −0.004 ms for API and
−0.385 to +0.609 ms for CLI. Boot variation leaves the cost of tracing
inconclusive. The frozen qualification series remains separate.

Each observed CLI run issued two HEAD pings and one request each for create,
attach, wait and start across three HTTP connections and three handler
threads. Direct API issued create, start, wait and remove across two
connections and two handler threads. Each lane used one launch worker and
one fresh authenticated guest channel per operation. Guest witness retrieval
occurred outside each measured interval.

| Ranked CLI host spans | Range of traced canary medians (ms) |
| --- | ---: |
| Client invocation to first HTTP request | 17.119–18.166 |
| Native worker entry to verified cleanup | 2.874–3.082 |
| Last attach socket close or wait body write to CLI exit | 1.589–1.675 |
| Docker create to start event, including attach and wait handshake | 1.223–1.338 |
| First HTTP request to Docker create | 0.763–0.833 |
| Verified cleanup to owner exit, including two native output reads | 0.325–0.358 |

Within the native worker span, authentication took 0.578–0.596 ms and
admission 0.192–0.222 ms. Admission to verified terminal observation took
2.078–2.190 ms and includes guest execution and cleanup. The guest
boundary is a terminal protocol observation. The trace has no
guest-local decomposition of execution and teardown. Host socket close
witnesses attach EOF generation, while client completion covers its read
and shutdown. The trace does not split Docker startup into process
scheduling, client initialization and context loading, or attribute the
historical Kiri delta to any one span. SPEED-028 targets the measured
per-launch authentication cost and SPEED-029 targets the output reads.

Raw traces, client rows, hashes, commands and launcher cleanup witnesses
are retained under `conjet-speedup-evidence/SPEED-027` on ExternalSSD.
Every launcher verified unchanged production and removal of its native
session and Docker socket.

## SPEED-028 authenticated connection reuse diagnostics

Three isolated traced boots reused the same release artifacts as SPEED-027.
Each boot completed 176 operations and used one authenticated native socket.
The last boot included 11 seconds of idle time between warmup and measurement.
The previous adapter authenticated once per operation in addition to
startup. Per-operation authentication now contributes zero handshakes,
compared with the previous CLI canary medians of 0.578–0.596 ms.

| Diagnostic lane | SPEED-027 traced session medians (ms) | SPEED-028 traced session medians (ms) |
| --- | ---: | ---: |
| API true | 3.935–4.652 | 3.248–3.462 |
| API both streams, exit 23 | 4.169–4.324 | 3.197–3.566 |
| CLI true | 24.377–26.207 | 22.007–23.233 |
| CLI both streams, exit 23 | 24.617–25.274 | 22.084–23.990 |

These diagnostic sessions establish the request-count change. Different boot
and host conditions limit how much of the overall timing difference can be
attributed to connection reuse. Every launcher verified production
preservation and owned-resource cleanup. Trace, client and launcher reports
are under `conjet-speedup-evidence/SPEED-028` on ExternalSSD.

## SPEED-029 terminal output diagnostics

Two traced release boots delivered terminal stdout and stderr inline for
every measured true and mixed-stream canary. Each completed one terminal
wait and zero follow-up native Output requests, down from two follow-up
requests per operation in SPEED-028. The CLI median host span from verified
guest cleanup to completing output collection fell to 0.017 ms, from
about 0.32 ms in SPEED-028. Median CLI true elapsed time ranged from
22.604 to 23.393 ms and mixed-stream elapsed time from 22.229 to
23.025 ms. The run sizes and boot variation support a boundary-level
attribution, with no matched Kiri verdict.

Each boot also verified byte-exact 65,535- and 65,536-byte results over the
unmodified Docker CLI. The 65,537-byte test received a bounded output error
and retained a guest cleanup witness with exit zero. An unread attachment
held 64 KiB per stream while wait, removal and another native launch
completed. A client disconnected before start also left wait, removal and
reuse working. The launcher verified unchanged production and owned-resource
cleanup. Exact commands, hashes, trace and canary results are under
`conjet-speedup-evidence/SPEED-029` on ExternalSSD.

## SPEED-030 Rust and Python owner diagnostics

Two release boots per owner used Rust/Python/Python/Rust order, with the
same Docker client, release guest and VMM, pinned image and effective
controls. Both owners completed the shared diagnostic lifecycle and output
checks, including guest cleanup. The initial Rust pilot failed when an
11-second idle period exceeded its HTTP keep-alive timeout. The repaired
owner preserved idle reuse and a separate bounded request read deadline.

| Diagnostic lane | Rust session medians (ms) | Python session medians (ms) |
| --- | ---: | ---: |
| API true | 2.464–2.493 | 2.932–2.967 |
| API both streams, exit 23 | 2.429–2.535 | 2.933–2.960 |
| CLI true | 21.119–21.454 | 22.205–22.349 |
| CLI both streams, exit 23 | 21.316–22.627 | 21.919–21.922 |

The CLI mixed-stream medians crossed between pairs. The diagnostic budget
supports no practical-threshold or Kiri verdict. Raw measurements,
exact artifact hashes, shared contract results and cleanup witnesses
are under `conjet-speedup-evidence/SPEED-030` on ExternalSSD.

## Release-build static native API and CLI

A separate release-build run used `cabbea9`, the same CLI, VMM, kernel and
guest digests, and the pinned static ARM64 payload. The
[`native-product.py` harness](../../benchmarks/README.md#experimental-product-path)
ran 2,000 operations per lane and retained ten warmups each. Native API
latency ends at verified guest cleanup. CLI latency includes client
startup and output collection. Prepared latency starts at claim and
the throughput window includes each slot refill.

| Lane | Launch p50 / p95 / p99 (ms) | Refill p50 / p95 / p99 (ms) | Completed/s |
| --- | ---: | ---: | ---: |
| Fresh API | 2.017 / 2.938 / 4.100 | — | 440.7 |
| Prepared API | 1.292 / 1.873 / 3.201 | 1.027 / 1.515 / 3.394 | 373.2 |
| Fresh CLI | 20.308 / 22.412 / 26.894 | — | 48.5 |
| Prepared CLI | 19.181 / 20.922 / 24.293 | 18.738 / 20.404 / 22.396 | 26.0 |

All 8,000 measured operations succeeded. The CLI one-use and expired
claim misses took 18.390 and 40.983 ms. The VMM used 34.85 CPU-s across
the timing boot. Its RSS snapshots were 107.9 MiB before and 75.8 MiB
after the measurement. The active-memory preservation canary, slot
eviction, concurrent claim, admission backpressure, bounded output,
disconnect and timeout recovery, and shutdown passed. Both VM directories
were removed and the production observations matched. Kiri has no
corresponding prepared API, so the static native results stand alone.

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

The no-network Alpine true CLI series used harness `eb31229`. Both
engines completed all 2,000 measured samples in pair 1 with zero failures.
The pinned Docker client ran `docker run --rm` for every sample. The
measurement starts at client spawn and ends at client exit. The verified
guest teardown boundary remains unknown for these ordinary Docker routes.

| Engine | p50 / p95 / p99 (ms) | Successes/s |
| --- | ---: | ---: |
| Conjet | 671.800/960.825/1044.558 | 1.446 |
| Kiri | 22.443/28.624/43.052 | 42.410 |

The worker canceled the next private Kiri boot before counting it to run
local validation of the hosted CI fix outside a measurement window. The
complete first pair and the canceled boot's cleanup evidence are retained.

The resumed pair 2 produced 2,000 samples per engine. Conjet retained two
exit-127 failures with Go thread-creation errors under the four-PID cap.
Both recovery removals and fixture inventories passed. Among successful
samples, Conjet p50/p95/p99 was 685.760/914.933/1077.914 ms. Kiri had
zero failures and reported 22.063/27.592/33.850 ms. Pair 2 cannot qualify
for a failure-free paired interval. A runc bootstrap thread hitting the
PID limit is a hypothesis consistent with its upstream diagnostics. The
recorded failure lacks a direct per-container `pids.events` witness.
[Upstream runc thread-limit issue](https://github.com/opencontainers/runc/issues/4083)

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
startup still have unknown guest memory. Pair 2's transfer comparison
remains inconclusive.

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
The median per-session loaded-image inspect p50 for Alpine and Node was
67.031 and 70.735 ms on Conjet and 16.848 and 17.009 ms on Kiri. The
inspection distribution separates already-verified, installed image tags
from image load and run. The supplemental backing observation on `b3f0ffc`
showed a 2,791,784,448-byte increase in allocated Conjet `data.raw` space
with flat `root.raw` allocation, and flat Kiri `data.img` allocation. These
are whole-suite backing-file deltas on APFS. Per-layer decompression and
writeback cost remain unobserved.

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

Pair 3 used `b3f0ffc` with distinct tags for every exported image. Each
engine completed all 72 build/export and load samples, passed 36 runnable
image checks and removed all 36 result tags and nine workers. The empty
build/export medians for Rust, Go and Node were 1.438, 5.159 and 9.720 s
on Conjet and 1.071, 4.464 and 5.985 s on Kiri. `SPEED-021/pair-3/summary.json`
contains the per-session distributions. This adds cleanup evidence. Detailed
worker counters and compatible independent pairs remain open.

Pair 4 on `25ce7d7` verified each worker's cgroup and added CPU, memory
and block I/O observations. Each engine passed all 36 build/export, load
and runnable-image checks. The table shows median counter deltas across
three independent workers per language in this pair and their highest
recorded memory peak. CPU and I/O deltas start after base preload.
Memory peaks include the preceding preload in the same worker.

| Engine and fixture | CPU s | Peak MiB | Read MiB | Written MiB |
| --- | ---: | ---: | ---: | ---: |
| Conjet Rust | 1.60 | 1562.7 | 0.2 | 25.5 |
| Conjet Go | 19.61 | 770.8 | 0.0 | 132.0 |
| Conjet Node | 2.70 | 332.7 | 0.0 | 25.3 |
| Kiri Rust | 1.43 | 1393.6 | 575.4 | 24.7 |
| Kiri Go | 20.76 | 697.1 | 1355.3 | 174.8 |
| Kiri Node | 2.61 | 356.6 | 523.7 | 26.6 |

The VM caches and storage paths can change these guest cgroup counters.
The evidence supports observed resource use for this pair. Equivalent
cross-session builder resource and cache effects remain under review.

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
The follow-up read-only probe showed Kiri's actual `memory.max` was
67,108,864 bytes and `memory.swap.max` was zero for the requested profile.
It also reported no guest swap. This identifies an inspect metadata
discrepancy. In pair 3 on `25ce7d7` both engines verified these effective
values before allocating. Conjet again reported exit 137 and an OOM. On
Kiri, `docker wait` timed out after 20 seconds and the OOM flag remained
false during the bounded inspection window. Both engines preserved sibling
data, passed fresh recovery and cleaned up the owned workloads. Kiri's
termination and attribution boundary is unresolved under this configuration.

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

| Workload | Executing backend | Coverage and verdict |
| --- | --- | --- |
| Docker API and CLI launch | Existing Conjet Docker/containerd and official Kiri | Full no-network API pair and pilot rows. Complete CLI series and remaining API/bridge pairs pending |
| Static fresh and prepared CLI/API | Conjet Rust native guest | Full-budget product session and live correctness. Kiri has no corresponding prepared API |
| No-network Docker OCI | Isolated Conjet native candidate and official Kiri | Five matched release-build pairs. Conjet had lower API p50 and slower CLI p50/p99. Kiri verified guest cleanup remains unknown |
| Controlled registry | Both existing Docker engines | Five complete pairs. Kiri faster for the declared pull boundaries |
| Image save/load/inspect | Both existing Docker engines | Five complete suites with pinned image identities and executable canaries |
| Rust, Go and Node Buildx | Pinned BuildKit worker on each existing engine | Two validated pairs with differing harness versions. Worker resource and comparable repetition evidence pending |
| Node/Redis Compose | Both existing Docker engines | Two measured pairs. One verifies effective quotas. Comparative intervals pending |
| Persistent exec and control | Both existing Docker engines | One complete pair after the event-observation correction |
| Storage and sustained service | Both existing Docker engines | One measured pair. Conjet ExternalSSD bind unsupported in the tested configuration |
| Concurrency and pressure | Both existing Docker engines and separate native product | Three Docker sweeps. Conjet OOM and native-pressure recovery verified. Kiri's wait timeout and absent OOM attribution reproduced under matched limits |

Buildx, Compose, persistent exec and service networking keep the existing
Docker backend where supported. The source adapter uses the declared
no-network OCI operations. Its scope does not provide those measurements.

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
| First full CLI pair and canceled next-boothalf evidence | `SPEED-019/alpine-true-none-cli-series` |
| Resumed CLI pair with retained Conjet startup failures | `SPEED-019/alpine-true-none-cli-series/remaining/pair-2` |
| Historical full-budget Docker-to-native OCI run | `SPEED-019/native-oci-full-1` |
| Release-build native/Kiri pairs, raw samples, production and cleanup evidence, and paired analysis | `SPEED-019/native-kiri-release-cabbea9` |
| First observed image operations and manifest reporting discrepancy | `SPEED-020/pair-1` |
| Pinned image and loopback registry results with asymmetric transfer proof | `SPEED-020/pair-2` |
| Complete paired registry transfer and labeled-store cleanup | `SPEED-020/pair-3` |
| Five matched image pairs, distribution summary and verified digest cleanup | `SPEED-020/cleanup-qualified`, `SPEED-020/cleanup-qualified/summary.json` |
| Image inspect distributions and whole-suite backing allocation | `SPEED-020/cleanup-qualified/inspect-distributions.json`, `SPEED-020/backing-observation` |
| First Buildx results and retained artifact/egress failures | `SPEED-021/pair-1` |
| Corrected Buildx cache-state matrix and artifact validation | `SPEED-021/pair-2` |
| Buildx per-case output-tag and worker cleanup verification | `SPEED-021/pair-3`, `SPEED-021/pair-3/summary.json` |
| Buildx worker CPU, peak-memory and I/O evidence | `SPEED-021/pair-4`, `SPEED-021/pair-4/builder-counters.json` |
| First Compose pair and transaction/teardown canaries | `SPEED-022/pair-1` |
| Compose repeat with effective service resource verification | `SPEED-022/pair-2` |
| Canceled historical-event run and corrected paired control matrix | `SPEED-023/pair-1`, `SPEED-023/pair-2` |
| Storage, guest transport and the sustained services | `SPEED-024/pair-1` |
| Launch concurrency, memory attribution and recovery attempts | `SPEED-025/pair-1` |
| Second concurrency pair and corrected Conjet OOM attribution | `SPEED-025/pair-2` |
| Read-only effective memory and swap validation on Kiri | `SPEED-025/kiri-effective-swap.log` |
| Matched guest pressure limits, successful recovery and reproduced Kiri wait timeout | `SPEED-025/pair-3` |
| Full-budget native static product and active-shutdown canaries | `SPEED-025/native-product-full-1` |
| Release-build static native API/CLI, refill, misses and pressure canaries | `SPEED-025/native-product-release-cabbea9` |

Production stayed in service throughout. The records preserve unknown
guest teardown, unmeasured energy and observed contention. The original
second-host and sub-1 ms research requirements remain deferred.
